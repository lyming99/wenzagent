part of 'agent_impl.dart';

/// 消息相关方法 mixin
mixin _AgentImplMessaging on _AgentImplBase {
  // ===== IAgent: 对话操作 =====

  @override
  Future<String> sendMessage(MessageInput input) async {
    _touch();

    // 等待 warmup 完成：确保全部历史消息已加载，LLM 有完整上下文
    if (_warmupCompleter != null) {
      await _warmupCompleter!.future;
    }

    _AgentImplBase._log.debug(
      'sendMessage: ${input.content.substring(0, input.content.length.clamp(0, 50))}',
    );

    return await _withLock(() async {
      // 关键修复：优先使用 MessageInput.id，避免被 metadata.id 覆盖
      // 这是客户端提供的"真实"消息ID，必须在整个传输链中保持一致
      final clientProvidedId = input.id;

      // 转换为 Map 以便内部处理
      final messageData = input.toMap();

      // 关键：如果客户端提供了ID，强制使用它，覆盖metadata中的id
      if (clientProvidedId != null && clientProvidedId.isNotEmpty) {
        messageData['id'] = clientProvidedId;
        _AgentImplBase._log.debug('使用客户端提供的消息ID: $clientProvidedId (强制覆盖metadata)');
      } else {
        // 客户端没有提供ID，检查messageData中是否有ID（可能来自metadata）
        final existingId = messageData['id'] as String?;
        if (existingId == null || existingId.isEmpty) {
          // 没有任何ID，生成一个新的
          final newMessageId = const Uuid().v4();
          messageData['id'] = newMessageId;
          _AgentImplBase._log.debug('生成新消息ID: $newMessageId');
        } else {
          _AgentImplBase._log.debug('使用metadata中的消息ID: $existingId');
        }
      }

      final finalMessageId = messageData['id'] as String;
      messageData['role'] = 'user';
      messageData['type'] = messageData['type'] as String? ?? 'text';
      messageData['createdAt'] = DateTime.now().toIso8601String();

      // 立即通过 memoryManager 持久化用户消息（分配 seq 并写入 DB），
      // 确保在返回 RPC 响应前消息已持久化，避免同步导致消息被清空
      if (_chatAdapter case final LlmChatAdapter adapter) {
        // 文件消息：使用 ChatMessage.file() 持久化，携带文件元信息
        if (input.type == 'file') {
          final meta = input.metadata ?? {};
          final fileMessage = ChatMessage.file(
            id: finalMessageId,
            employeeId: employeeId,
            role: MessageRole.user,
            fileName: meta['fileName'] as String? ?? input.content,
            fileSize: meta['fileSize'] as int? ?? 0,
            fileId: meta['fileId'] as String? ?? finalMessageId,
            fileHash: meta['sha256'] as String? ?? meta['fileHash'] as String? ?? '',
            filePath: meta['filePath'] as String? ?? '',
            fromDeviceId: meta['fromDeviceId'] as String?,
            mimeType: meta['mimeType'] as String?,
            deviceId: deviceId,
          );
          adapter.memoryManager.addMessage(
            employeeId,
            deviceId,
            fileMessage,
          );
          _AgentImplBase._log.debug('文件消息已提前持久化: $finalMessageId');
          // 文件消息不提交到 LLM 处理器，直接返回
          return finalMessageId;
        }

        final userMessage = ChatMessage.user(
          id: finalMessageId,
          employeeId: employeeId,
          content: input.content,
        );
        adapter.memoryManager.addMessage(
          employeeId,
          deviceId,
          userMessage,
        );
        _AgentImplBase._log.debug('用户消息已提前持久化: $finalMessageId');
      }

      _AgentImplBase._log.debug('提交消息到处理器，最终消息ID: $finalMessageId');
      // 提交到处理器
      await _processor?.submitMessage(finalMessageId, messageData);

      return finalMessageId;
    });
  }

  @override
  Future<String> sendMessageFromMap(Map<String, dynamic> messageData) {
    return sendMessage(MessageInput.fromMap(messageData));
  }

  @override
  Future<void> interrupt() async {
    _touch();
    await _processor?.interruptCurrentTask();
    _callingToolIds.clear();
    _setStatus(AgentStatus.idle);
  }

  // ===== IAgent: 会话管理 =====

  @override
  Future<List<AgentMessage>> getSessionMessages() async {
    return _chatAdapter.getSessionMessages(employeeId);
  }

  @override
  Future<List<AgentMessage>> getSessionMessagesByUserCount({
    int userMessageLimit = 20,
  }) async {
    // 1. 获取所有消息
    final allMessages = await _chatAdapter.getSessionMessages(employeeId);

    if (allMessages.isEmpty) {
      return [];
    }

    // 2. 按时间倒序排列（最新的在前）
    allMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // 3. 统计用户消息，达到限制时停止
    int userMessageCount = 0;
    final selectedMessages = <AgentMessage>[];

    for (final message in allMessages) {
      selectedMessages.add(message);

      // 统计用户消息
      if (message.role == 'user') {
        userMessageCount++;

        // 达到限制时停止
        if (userMessageCount >= userMessageLimit) {
          break;
        }
      }
    }

    // 4. 按时间正序排列返回
    selectedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return selectedMessages;
  }

  @override
  Future<List<AgentMessage>> getSessionMessagesPaged({
    int pageSize = 20,
    int offset = 0,
  }) async {
    // 1. 获取所有消息
    final allMessages = await _chatAdapter.getSessionMessages(employeeId);

    if (allMessages.isEmpty) {
      return [];
    }

    // 2. 按时间倒序排列（最新的在前）
    allMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // 3. 分页获取
    final pagedMessages = allMessages.skip(offset).take(pageSize).toList();

    // 4. 按时间正序排列返回
    pagedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return pagedMessages;
  }

  @override
  Future<List<AgentMessage>> getUnreceivedMessages({
    required String receiverDeviceId,
    int offset = 0,
    int limit = 20,
  }) async {
    // 1. 获取所有消息
    final allMessages = await _chatAdapter.getSessionMessages(employeeId);

    if (allMessages.isEmpty) {
      return [];
    }

    // 2. 过滤出该设备未接收的消息
    final unreceivedMessages = <AgentMessage>[];

    for (final message in allMessages) {
      final messageUpdateTime = _getMessageUpdateTime(message);

      // 检查该设备是否已接收此消息
      final receiveStatus = _messageReceiveStatus[message.id];
      if (receiveStatus == null) {
        // 消息未被任何设备接收过，属于未接收消息
        unreceivedMessages.add(message);
        continue;
      }

      final deviceReceiveTime = receiveStatus[receiverDeviceId];
      if (deviceReceiveTime == null) {
        // 该设备未接收过此消息，属于未接收消息
        unreceivedMessages.add(message);
        continue;
      }

      // 检查消息是否已更新（updateTime比接收时间更新）
      if (messageUpdateTime.isAfter(deviceReceiveTime)) {
        // 消息已更新，需要重新接收
        unreceivedMessages.add(message);
      }
    }

    // 3. 按时间正序排列
    unreceivedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // 4. 分页
    final pagedMessages = unreceivedMessages.skip(offset).take(limit).toList();

    _AgentImplBase._log.debug(
      '查询设备 $receiverDeviceId 的未接收消息，共 ${unreceivedMessages.length} 条，返回第 ${offset + 1}-${offset + pagedMessages.length} 条',
    );
    return pagedMessages;
  }

  @override
  Future<void> markMessagesAsReceived({
    required String receiverDeviceId,
    required List<MessageReceiveInfo> messageReceiveList,
  }) async {
    // 记录消息接收状态
    for (final info in messageReceiveList) {
      // 获取或创建消息的接收状态Map
      _messageReceiveStatus[info.messageId] ??= {};

      // 记录该设备的接收时间
      _messageReceiveStatus[info.messageId]![receiverDeviceId] =
          info.updateTime;
    }

    _AgentImplBase._log.debug(
      '已标记设备 $receiverDeviceId 接收 ${messageReceiveList.length} 条消息',
    );
  }

  @override
  Future<List<AgentMessage>> getMessagesAfterSeq({
    required String employeeId,
    int lastSeq = 0,
    int limit = 20,
  }) async {
    final store = MessageStore(deviceId: deviceId);
    final chatMessages = await store.getMessagesAfterSeq(
      employeeId, lastSeq, deviceId: deviceId, limit: limit,
    );

    final messages = chatMessages.map((cm) {
      final map = cm.toJson();
      // 将 seq、deleted、isRead 注入 metadata，供客户端增量同步使用
      final metadata = Map<String, dynamic>.from(
        (map['metadata'] as Map<String, dynamic>?) ?? {},
      );
      if (cm.seq > 0) metadata['seq'] = cm.seq;
      if (cm.deleted) metadata['deleted'] = 1;
      if (cm.isRead) metadata['isRead'] = true;
      if (cm.updatedAt != null) {
        metadata['updateTime'] = cm.updatedAt!.toIso8601String();
      }
      map['metadata'] = metadata.isNotEmpty ? metadata : null;
      return AgentMessage.fromMap(map);
    }).toList();

    _AgentImplBase._log.debug(
      'getMessagesAfterSeq: employeeId=$employeeId, deviceId=$deviceId, lastSeq=$lastSeq, 返回 ${messages.length} 条',
    );
    return messages;
  }

  @override
  Future<int> getMaxSeq({required String employeeId}) async {
    final store = MessageStore(deviceId: deviceId);
    return store.getMaxSeqForEmployeeAll(employeeId, deviceId: deviceId);
  }

  @override
  Future<int> getMinSeq({required String employeeId}) async {
    final store = MessageStore(deviceId: deviceId);
    final minSeq = store.getMinSeqForEmployee(employeeId, deviceId: deviceId);
    if (minSeq > 0) return minSeq;
    // 无未删除消息时回退到 clear_seq
    final watermarkStore = SyncWatermarkStore(deviceId: deviceId);
    return watermarkStore.getClearSeq(employeeId, deviceId: deviceId) ?? 0;
  }

  @override
  Future<void> markMessagesAsRead({
    required String deviceId,
    required String employeeId,
    List<String>? messageIds,
  }) async {
    _touch();

    // 如果未指定消息ID列表，则标记该员工的所有消息为已读
    final ids = messageIds;
    if (ids != null && ids.isNotEmpty) {
      // 持久化到 DB：逐条标记指定消息为已读
      final store = MessageStore(deviceId: deviceId);
      for (final messageId in ids) {
        store.markAsReadByUuid(messageId);
        _messageReadStatus[messageId] ??= {};
        _messageReadStatus[messageId]![deviceId??''] = DateTime.now();
      }
      _AgentImplBase._log.info('已标记设备 $deviceId 对 ${ids.length} 条消息的已读状态');
    } else {
      // 持久化到 DB：批量标记该员工所有消息为已读
      final store = MessageStore(deviceId: deviceId);
      store.markAsReadByEmployee(employeeId, deviceId: deviceId);

      // 更新内存缓存
      final allMessages = await _chatAdapter.getSessionMessages(employeeId);
      for (final message in allMessages) {
        _messageReadStatus[message.id] ??= {};
        _messageReadStatus[message.id]![deviceId] = DateTime.now();
      }
      _AgentImplBase._log.info('已标记设备 $deviceId 对员工 $employeeId 所有消息的已读状态');
    }

    // 广播已读状态变更事件
    _eventController.add(
      AgentEvent(
        type: AgentEventType.messageReadStatusChanged,
        data: {
          'employeeId': employeeId,
          'readerDeviceId': deviceId,
          'messageIds': ids,
        },
        employeeId: employeeId,
      ),
    );
  }

  @override
  Future<void> markMessagesAsReadBySeq({
    required String readerDeviceId,
    required String employeeId,
    required int readSeq,
  }) async {
    _touch();

    // 1. 持久化到 DB：批量标记 seq <= readSeq 的 assistant 未读消息为已读
    final store = MessageStore(deviceId: deviceId);
    final affected = store.markAsReadBySeq(employeeId, readSeq, deviceId: deviceId);

    // 2. 更新内存缓存：从 DB 已读结果同步，避免全量加载消息
    final now = DateTime.now();
    final readStatusMap = store.getReadStatusMap(employeeId, deviceId: deviceId);
    for (final entry in readStatusMap.entries) {
      if (entry.value) {
        _messageReadStatus[entry.key] ??= {};
        _messageReadStatus[entry.key]![readerDeviceId] ??= now;
      }
    }

    _AgentImplBase._log.info(
      '已按 seq=$readSeq 标记设备 $readerDeviceId 对 $affected 条消息的已读状态（DB 持久化）',
    );

    // 3. 广播已读状态变更事件
    _eventController.add(
      AgentEvent(
        type: AgentEventType.messageReadStatusChanged,
        data: {
          'employeeId': employeeId,
          'readerDeviceId': readerDeviceId,
          'readSeq': readSeq,
        },
        employeeId: employeeId,
      ),
    );
  }

  @override
  Future<MessagesReadStatusResult> getMessagesReadStatus({
    required String deviceId,
    required String employeeId,
  }) async {
    // 优先从 DB 读取已读状态（持久化数据，进程重启后仍有效）
    final store = MessageStore(deviceId: deviceId);
    final dbReadStatus = store.getReadStatusMap(employeeId, deviceId: deviceId);

    // 合并内存缓存（内存中可能有尚未落盘的实时数据）
    final readStatus = <String, bool>{};

    // 先写入 DB 数据
    for (final entry in dbReadStatus.entries) {
      readStatus[entry.key] = entry.value;
    }

    // 再用内存数据补充（DB 中没有但内存中有的消息）
    for (final entry in _messageReadStatus.entries) {
      readStatus[entry.key] =
          entry.value.containsKey(deviceId);
    }

    return MessagesReadStatusResult(
      employeeId: employeeId,
      deviceId: deviceId,
      readStatus: readStatus,
    );
  }

  /// 获取消息的更新时间
  DateTime _getMessageUpdateTime(AgentMessage message) {
    // 优先使用metadata中的updateTime（始终为ISO8601字符串）
    final updateTime = message.metadata?['updateTime'];
    if (updateTime is String) {
      return DateTime.parse(updateTime);
    }

    // 其次使用createdAt
    return message.createdAt;
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessagesAsMap() async {
    final messages = await getSessionMessages();
    return messages.map((m) => m.toMap()).toList();
  }

  @override
  Future<void> revokeMessage(String messageId) async {
    _touch();

    // 如果正在处理的是要删除的消息，先打断
    if (_processor?.currentProcessingMessageId == messageId) {
      _AgentImplBase._log.info('正在处理的消息被删除，打断处理: $messageId');
      await _processor?.interruptCurrentTask();
    } else {
      // 否则只从队列中撤回
      await _processor?.revokeMessage(messageId);
    }

    // 从内存和数据库中删除消息
    if (_chatAdapter case final LlmChatAdapter adapter) {
      await adapter.deleteMessage(messageId);
    } else {
      _chatAdapter.removeMessageFromMemory(messageId);
    }
  }

  @override
  AgentPermissionRequest? getPendingPermissionRequest() {
    // 返回第一个待处理的权限请求
    if (_pendingPermissionRequests.isEmpty) return null;
    return _pendingPermissionRequests.values.first;
  }

  // ===== IAgent: 确认管理 =====

  @override
  Future<void> respondToConfirm(String requestId, String selectedOption) async {
    _touch();
    final completer = _pendingConfirms[requestId];
    if (completer == null || completer.isCompleted) {
      _AgentImplBase._log.warn('respondToConfirm: 未找到待处理的确认请求: $requestId');
      return;
    }

    completer.complete(selectedOption);

    // 广播确认响应事件
    _eventController.add(
      AgentEvent(
        type: AgentEventType.confirmResponse,
        data: {
          'requestId': requestId,
          'selectedOption': selectedOption,
        },
        employeeId: employeeId,
      ),
    );
  }

  @override
  AgentConfirmRequest? getPendingConfirmRequest() {
    // 返回第一个待处理的确认请求
    if (_pendingConfirmRequests.isEmpty) return null;
    return _pendingConfirmRequests.values.first;
  }

  @override
  Future<void> clearCurrentSession() async {
    _touch();
    await _withLock(() async {
      // 如果有正在处理的消息，先打断
      if (_processor?.currentProcessingMessageId != null) {
        _AgentImplBase._log.info('清空会话，打断正在处理的消息');
        await _processor?.interruptCurrentTask();
      }

      await _chatAdapter.clearCurrentSession();

      // 取消所有待处理的权限请求
      for (final completer in _pendingPermissions.values) {
        if (!completer.isCompleted) {
          completer.complete(PermissionDecision.deny);
        }
      }
      _pendingPermissions.clear();
      _pendingPermissionRequests.clear();

      // 取消所有待处理的确认请求
      for (final completer in _pendingConfirms.values) {
        if (!completer.isCompleted) {
          completer.completeError('Session cleared');
        }
      }
      _pendingConfirms.clear();
      _pendingConfirmRequests.clear();
    });

    // 广播会话清空事件，通知所有客户端
    _eventController.add(
      AgentEvent(
        type: AgentEventType.sessionCleared,
        data: {'employeeId': employeeId},
        employeeId: employeeId,
      ),
    );
  }

  @override
  Future<void> removeMessageFromMemory(String messageId) async {
    _touch();
    await _withLock(() async {
      _chatAdapter.removeMessageFromMemory(messageId);
    });
  }

  /// 注入一条 assistant 消息（不触发 LLM）
  ///
  /// 用于定时任务等场景：sub-agent 生成内容后，直接注入到主 agent 会话中。
  /// 消息会被写入 adapter session（内存）和持久化存储（SQLite），
  /// 并通过事件流广播 messageStatusChanged，让 UI 能正常收到。
  Future<void> injectAssistantMessage({
    required String messageId,
    required String content,
  }) async {
    if (_status == AgentStatus.disposed) return;

    // 1. 写入 adapter session + 持久化（等待持久化完成后再广播）
    if (_chatAdapter case final LlmChatAdapter adapter) {
      await adapter.injectAssistantMessage(messageId, content, 'default');
    }

    // 2. 广播 completed 事件（UI 监听此事件渲染消息）
    _broadcasterBroadcastMessageStatusChange(
      messageId: messageId,
      status: AgentMessageStatus.completed,
      extraData: {'role': 'assistant', 'type': 'text', 'content': content},
    );

    _touch();
  }

  /// 触发定时任务（注入 system 消息 + 触发 LLM 处理）
  ///
  /// 1. 将任务内容以 system 消息注入到会话（role=system，持久化）
  /// 2. 发送一条 user 消息触发 LLM 处理（走完整的 streamMessage 流程）
  /// 3. 用户不会看到 system 消息和触发消息，只看到 LLM 的自然回复
  Future<String?> triggerSystemTask({
    required String taskContent,
    String? taskName,
  }) async {
    if (_status == AgentStatus.disposed) return null;
    _touch();

    // 1. 注入 system 消息（role=system，写入 session + 持久化）
    final systemMsgId = const Uuid().v4();
    final systemContent = taskName != null
        ? '【定时任务：$taskName】\n$taskContent'
        : '【定时任务触发】\n$taskContent';

    if (_chatAdapter case final LlmChatAdapter adapter) {
      adapter.injectSystemMessage(
        systemMsgId,
        systemContent,
        'default',
      );
    }

    // 2. 发送 user 消息触发 LLM 处理（metadata 标记 trigger=scheduled_task，
    //    queued 状态会被 device_client 过滤，用户不可见）
    final userMsgId = const Uuid().v4();

    return await _withLock(() async {
      final messageData = {
        'id': userMsgId,
        'role': 'system',
        'type': 'text',
        'content': taskContent,
        'createdAt': DateTime.now().toIso8601String(),
        'metadata': {
          'trigger': 'scheduled_task',
          'scheduledSystemMessageId': systemMsgId,
        },
      };
      await _processor?.submitMessage(userMsgId, messageData);
      return userMsgId;
    });
  }

  /// 注入一条提醒类助手消息（不调用 LLM API）
  ///
  /// 用于定时提醒场景：提醒内容在创建时已预渲染，
  /// 触发时直接写入会话并广播给设备，用户看到的是一条助手消息。
  Future<String?> injectReminderMessage({
    required String content,
    String? taskName,
    String? taskId,
  }) async {
    if (_status == AgentStatus.disposed) return null;
    _touch();

    final msgId = const Uuid().v4();
    final now = DateTime.now();

    // 等待持久化完成后再广播，确保消息已落盘、seq 已分配
    if (_chatAdapter case final LlmChatAdapter adapter) {
      await adapter.injectAssistantMessage(
        msgId,
        content,
        'system',
      );
    }

    // 广播消息状态变更（completed），与正常助手消息完成流程一致
    _broadcasterBroadcastMessageStatusChange(
      messageId: msgId,
      status: AgentMessageStatus.completed,
      extraData: {
        'role': 'assistant',
        'content': content,
        'createdAt': now.toIso8601String(),
        'metadata': {
          'trigger': 'scheduled_reminder',
          'taskName': taskName,
          'taskId': taskId,
        },
      },
    );

    // 强制广播 agentStatusChanged(idle)，触发前端刷新消息列表
    // 与正常助手消息完成后的状态变更流程一致
    // 注入消息时 Agent 本身就是 idle，_setStatus 的 guard 会阻止重复广播，
    // 所以直接通过 controller 推送，绕过 guard
    if (!_stateController.isClosed && !_eventController.isClosed) {
      final snapshot = getStateSnapshot();
      _stateController.add(snapshot);
      _eventController.add(
        AgentEvent(
          type: AgentEventType.agentStatusChanged,
          data: snapshot.toMap(),
          employeeId: employeeId,
        ),
      );
    }

    return msgId;
  }

  // ===== Token 用量 Store 查询 =====

  /// 从 MessageStore 聚合会话级 Token 用量
  ///
  /// 遍历该 employeeId 下所有消息的 input_tokens/output_tokens 并累加。
  /// 用于 Agent 销毁后（内存清空）的历史 Token 查询。
  Future<TokenUsageRecord> getTokenUsageFromStore(String employeeId) async {
    final store = MessageStore(deviceId: deviceId);
    final messages = await store.getMessages(deviceId, employeeId);
    int totalInput = 0;
    int totalOutput = 0;
    for (final msg in messages) {
      totalInput += msg.inputTokens ?? 0;
      totalOutput += msg.outputTokens ?? 0;
    }
    return TokenUsageRecord(
      promptTokens: totalInput,
      completionTokens: totalOutput,
      totalTokens: totalInput + totalOutput,
    );
  }

  /// 从 MessageStore 查询单条消息的 Token 用量
  Future<TokenUsageRecord?> getMessageTokenUsageFromStore(
    String employeeId,
    String messageId,
  ) async {
    final store = MessageStore(deviceId: deviceId);
    final msg = await store.find(deviceId, messageId);
    if (msg == null) return null;

    final input = msg.inputTokens;
    final output = msg.outputTokens;
    if (input == null && output == null) return null;

    return TokenUsageRecord(
      promptTokens: input ?? 0,
      completionTokens: output ?? 0,
      totalTokens: (input ?? 0) + (output ?? 0),
    );
  }
}
