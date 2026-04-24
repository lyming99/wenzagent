part of 'cached_agent_proxy.dart';

/// 事件处理 mixin
mixin _CachedProxyEventHandler on _CachedAgentProxyBase {
  // ===== 事件处理 =====

  /// 处理Agent事件
  void _handleAgentEvent(AgentEvent event) {
    final type = event.type;
    final data = event.data;
    final employeeId = event.employeeId;

    // 只处理当前员工的事件
    if (employeeId != null && employeeId != _employeeId) {
      return;
    }

    _CachedAgentProxyBase._log.debug('收到事件: $type');

    switch (type) {
      case AgentEventType.messageStatusChanged:
        _handleMessageStatusChanged(data);
        break;
      case AgentEventType.agentStatusChanged:
        _handleAgentStatusChanged(data);
        break;
      case AgentEventType.toolCallStart:
      case AgentEventType.toolCallResult:
        _handleToolEvent(type.value, data);
        break;
      case AgentEventType.toolPermissionRequest:
        _handlePermissionRequest(data);
        break;
      case AgentEventType.toolPermissionResponse:
        _handlePermissionResponse(data);
        break;
      case AgentEventType.confirmRequest:
        _handleConfirmRequest(data);
        break;
      case AgentEventType.confirmResponse:
        _handleConfirmResponse(data);
        break;
      case AgentEventType.messageStarted:
        _handleMessageStarted(data);
        break;
      case AgentEventType.streamDelta:
        // 流式增量事件：透传给上层 UI，不修改本地缓存
        // UI 层通过 onEvent 流直接消费此事件实现打字机效果
        break;
      case AgentEventType.thinkingDelta:
        // 思考增量事件：透传给上层 UI，不修改本地缓存
        // UI 层通过 onEvent 流直接消费此事件展示思考过程
        break;
      case AgentEventType.sessionCleared:
        _handleSessionCleared(data);
        break;
      case AgentEventType.sessionSummaryChanged:
        _handleSessionSummaryChanged(data);
        break;
      case AgentEventType.messageReadStatusChanged:
        _handleMessageReadStatusChanged(data);
        break;
      case AgentEventType.configChanged:
        _handleConfigChanged(data);
        break;
      case AgentEventType.todoTopicChanged:
      case AgentEventType.todoTaskItemChanged:
      case AgentEventType.specChanged:
        // 数据变更事件：通知 UI 刷新数据列表
        _notifyMessagesChanged();
        break;
      case AgentEventType.unknown:
        break;
    }
  }

  /// 处理消息状态变更事件
  void _handleMessageStatusChanged(Map<String, dynamic> data) {
    final messageId = data['messageId'] as String?;
    final status = data['status'] as String?;
    final error = data['error'] as String?;

    if (messageId == null || status == null) return;

    _CachedAgentProxyBase._log.debug('消息状态变更: $messageId -> $status${error != null ? ", error: $error" : ""}');

    // 更新本地缓存中的消息状态（包含错误信息）
    _updateMessageStatus(messageId, status, error: error);

    // 如果是失败状态且有错误信息，创建一条错误消息返回给客户端
    if (status == 'failed' && error != null) {
      _createErrorMessage(messageId, error);
    }

    // 如果是完成或失败状态，立即同步远程消息（避免 500ms 去抖延迟）
    if (status == 'completed' || status == 'failed' ||
        status == 'interrupted') {
      // 清除 callingToolIds 缓存（消息处理完成时所有工具调用已结束）
      _callingToolIdsCache = [];

      // 本地模式：从内存缓存移除已完成的工具调用消息
      _inMemoryToolCallMessages.removeWhere((key, _) {
        // 移除所有以该 messageId 相关的工具调用（按 toolCallId 关联）
        return key == messageId ||
            key == messageId.replaceFirst('local_toolcall_', '');
      });
      _syncMessagesFromRemote();
    }
  }

  /// 创建错误消息（当消息处理失败时，生成一条 assistant 类型的错误消息给客户端可见）
  Future<void> _createErrorMessage(String originalMessageId,
      String errorContent) async {
    // 截断过长的错误信息，避免存储和显示问题
    final displayError = errorContent.length > 500
        ? '${errorContent.substring(0, 500)}...'
        : errorContent;

    final errorMessage = AgentMessage(
      id: 'error_$originalMessageId',
      role: 'assistant',
      type: 'error',
      content: '处理失败: $displayError',
      createdAt: DateTime.now(),
      status: 'failed',
      metadata: {
        'error': true,
        'originalMessageId': originalMessageId,
        'updateTime': DateTime.now().toIso8601String(),
      },
    );

    // 添加到缓存
    await _addMessageToCache(errorMessage);

    _CachedAgentProxyBase._log.info('已创建错误消息: ${errorMessage.id}');
  }

  /// 处理Agent状态变更事件
  void _handleAgentStatusChanged(Map<String, dynamic> data) {
    final status = data['status'] as String?;
    _CachedAgentProxyBase._log.debug('Agent状态变更: $status');

    // 更新状态缓存
    if (data.containsKey('currentProcessingMessageId')) {
      _currentProcessingMessageId = data['currentProcessingMessageId'] as String?;
    }
    if (data.containsKey('queuedMessageIds')) {
      _queuedMessageIds = (data['queuedMessageIds'] as List?)?.cast<String>() ?? [];
    }

    // 如果是空闲状态，可能意味着消息处理完成
    if (status == 'idle') {
      _currentProcessingMessageId = null;
      _queuedMessageIds = [];
      // 使用 debounce 避免与 completed/failed 状态的同步重复
      _debouncedSyncMessages(delay: const Duration(milliseconds: 200));
    }
  }

  /// 处理工具事件
  void _handleToolEvent(String eventType, Map<String, dynamic> data) {
    _CachedAgentProxyBase._log.debug('工具事件: $eventType');

    if (eventType == 'toolCallStart') {
      // 工具调用开始：创建工具调用消息
      _createToolCallMessage(data);
      // 更新 callingToolIds 缓存
      final toolCallId = data['toolCallId'] as String?;
      if (toolCallId != null) {
        _callingToolIdsCache = [..._callingToolIdsCache, toolCallId];
      }
    } else if (eventType == 'toolCallResult') {
      // 工具调用完成：更新工具消息
      _updateToolCallMessage(data);
      // 更新 callingToolIds 缓存
      final toolCallId = data['toolCallId'] as String?;
      if (toolCallId != null) {
        _callingToolIdsCache = _callingToolIdsCache.where((id) => id != toolCallId).toList();
      }

      // 使用 debounce 同步消息，避免与 completed/idle 重复
      _debouncedSyncMessages(delay: const Duration(milliseconds: 300));
    }
  }

  /// 创建工具调用消息（本地临时消息，用于实时显示工具调用状态）
  Future<void> _createToolCallMessage(Map<String, dynamic> data) async {
    final toolCallId = data['toolCallId'] as String?;
    final toolName = data['toolName'] as String?;
    final arguments = data['arguments'] as Map<String, dynamic>?;

    if (toolCallId == null || toolName == null) return;

    // 去重检查：避免重复创建相同 toolCallId 的临时消息
    final localId = 'local_toolcall_$toolCallId';
    final exists = await _messageStore.getMessage(_deviceId, localId);
    if (exists != null) {
      _CachedAgentProxyBase._log.debug('工具调用临时消息已存在，跳过: $toolName ($toolCallId)');
      return;
    }

    _CachedAgentProxyBase._log.debug('创建工具调用消息: $toolName ($toolCallId)');

    // 创建工具调用消息：role 为 assistant（functionCall 是 assistant 发出的），
    // ID 使用前缀避免与远程同步的消息 ID 冲突
    final toolMessage = AgentMessage(
      id: localId,
      role: 'assistant',
      type: 'functionCall',
      toolCallId: toolCallId,
      toolName: toolName,
      toolArguments: arguments,
      toolCalls: [
        ToolCall(id: toolCallId, name: toolName, arguments: arguments ?? {})
      ],
      status: 'processing',
      createdAt: DateTime.now(),
      metadata: {'localToolCall': true},
    );

    // 保存到数据库（必须 await，确保 notify 时 DB 已写入）
    await _saveToolCallMessageToDb(toolMessage);

    // 本地模式：将工具调用消息保存到内存缓存
    if (_proxy.isLocalMode) {
      _inMemoryToolCallMessages[toolCallId] = toolMessage;
    }

    _notifyMessagesChanged();
  }

  /// 更新工具调用消息
  Future<void> _updateToolCallMessage(Map<String, dynamic> data) async {
    final toolCallId = data['toolCallId'] as String?;
    final result = data['result'] as String?;
    final isError = data['isError'] as bool? ?? false;

    if (toolCallId == null) return;

    _CachedAgentProxyBase._log.debug('更新工具调用消息: $toolCallId');

    // 根据错误类型确定状态
    String newStatus;
    if (!isError) {
      newStatus = 'completed';
    } else if (result != null && result.contains('权限被拒绝')) {
      newStatus = 'interrupted';
      _CachedAgentProxyBase._log.warn('工具调用被权限打断: $toolCallId');
    } else {
      newStatus = 'failed';
    }

    // 本地模式：从内存缓存更新
    if (_proxy.isLocalMode &&
        _inMemoryToolCallMessages.containsKey(toolCallId)) {
      final existing = _inMemoryToolCallMessages[toolCallId]!;
      _inMemoryToolCallMessages[toolCallId] = existing.copyWith(
        toolResult: result,
        status: newStatus,
        metadata: {
          ...?existing.metadata,
          'isError': isError,
          'updateTime': DateTime.now().toIso8601String(),
        },
      );
      _notifyMessagesChanged();
      return;
    }

    // 远程模式：在数据库中查找本地临时消息
    final localId = 'local_toolcall_$toolCallId';
    final existing = await _messageStore.getMessage(_deviceId, localId);
    if (existing == null) return;

    final updatedMessage = _chatMessageToAgentMessage(existing).copyWith(
      toolResult: result,
      status: newStatus,
      metadata: {
        ...?existing.metadata,
        'isError': isError,
        'updateTime': DateTime.now().toIso8601String(),
      },
    );

    // 先更新数据库，再通知 UI（确保 UI 读到最新状态）
    await _updateToolCallMessageInDb(updatedMessage);
    _notifyMessagesChanged();
  }

  /// 保存工具调用消息到数据库
  ///
  /// 本地模式不持久化临时消息，因为：
  /// - 原始 assistant 消息已包含 toolCalls 数据并持久化
  /// - tool result 消息也会被持久化
  /// - 临时消息持久化会导致前端 _loadMessages 重复创建 functionCall
  @override
  Future<void> _saveToolCallMessageToDb(AgentMessage message) async {
    // 本地模式：DB 不需要临时工具调用消息
    if (_proxy.isLocalMode) return;
    try {
      final chatMsg = _agentMessageToChatMessage(message);
      await _messageStore.addMessage(
          _deviceId, chatMsg, updateWatermark: false);
    } catch (e) {
      _CachedAgentProxyBase._log.error('保存工具调用消息失败', e);
    }
  }

  /// 更新数据库中的工具调用消息
  @override
  Future<void> _updateToolCallMessageInDb(AgentMessage message) async {
    try {
      final chatMsg = _agentMessageToChatMessage(message);
      await _messageStore.updateMessage(_deviceId, chatMsg, updateWatermark: false);
    } catch (e) {
      _CachedAgentProxyBase._log.error('更新工具调用消息失败', e);
    }
  }

  /// 处理权限请求事件
  void _handlePermissionRequest(Map<String, dynamic> data) {
    try {
      final request = AgentPermissionRequest.fromMap(data);
      _pendingPermissionRequests[request.requestId] = request;
      _CachedAgentProxyBase._log.info('收到权限请求: ${request.requestId}, 函数: ${request.functionName}');

      // 通知客户端重新加载消息
      _notifyMessagesChanged();
    } catch (e) {
      _CachedAgentProxyBase._log.error('处理权限请求失败', e);
    }
  }

  /// 处理权限响应事件（其他设备已授权/拒绝，本地需清除缓存）
  ///
  /// 增强：解析 decision 和 scope 字段，记录详细日志。
  /// 如果 scope 为持久化授权（非 once），后续可通过 syncFromRemote
  /// 获取最新的权限配置。
  void _handlePermissionResponse(Map<String, dynamic> data) {
    final requestId = data['requestId'] as String?;
    if (requestId == null) return;

    final decision = data['decision'] as String?;
    final scope = data['scope'] as String?;

    final removed = _pendingPermissionRequests.remove(requestId);
    if (removed != null) {
      _CachedAgentProxyBase._log.info(
        '收到权限响应（其他设备已处理）: $requestId, decision=$decision, scope=$scope');
      _notifyMessagesChanged();
    }
  }

  /// 处理确认请求事件
  void _handleConfirmRequest(Map<String, dynamic> data) {
    try {
      final request = AgentConfirmRequest.fromMap(data);
      _pendingConfirmRequests[request.requestId] = request;
      _CachedAgentProxyBase._log.info('收到确认请求: ${request.requestId}, 标题: ${request.title}');

      // 通知客户端重新加载消息
      _notifyMessagesChanged();
    } catch (e) {
      _CachedAgentProxyBase._log.error('处理确认请求失败', e);
    }
  }

  /// 处理确认响应事件（其他设备已选择，本地需清除缓存）
  void _handleConfirmResponse(Map<String, dynamic> data) {
    final requestId = data['requestId'] as String?;
    if (requestId == null) return;

    final removed = _pendingConfirmRequests.remove(requestId);
    if (removed != null) {
      _CachedAgentProxyBase._log.info('收到确认响应（其他设备已处理）: $requestId');
      _notifyMessagesChanged();
    }
  }

  /// 处理消息开始处理事件
  ///
  /// 当 Agent 从队列中取出消息开始处理时触发，
  /// 更新本地消息状态为 processing，通知 UI 显示"正在输入"。
  void _handleMessageStarted(Map<String, dynamic> data) {
    final messageId = data['messageId'] as String?;

    if (messageId == null) return;

    _CachedAgentProxyBase._log.debug('消息开始处理: $messageId');

    // 更新状态缓存
    _currentProcessingMessageId = messageId;

    // 更新消息状态为 processing
    _updateMessageStatus(messageId, 'processing');
  }

  /// 处理会话清空事件
  ///
  /// 远端某个客户端清空了会话，本地需要同步清空消息和重置水位线。
  Future<void> _handleSessionCleared(Map<String, dynamic> data) async {
    if (_proxy.isLocalMode) return;

    _CachedAgentProxyBase._log.info('收到会话清空事件: employeeId=$_employeeId');

    // 设置清空保护标志，防止 idle 状态触发的 _debouncedSyncMessages 重新同步消息
    _sessionClearPending = true;
    _sessionClearGuardTimer?.cancel();
    _sessionClearGuardTimer = Timer(const Duration(milliseconds: 500), () {
      _sessionClearPending = false;
      _sessionClearGuardTimer = null;
      // 保护期结束后，主动触发一次补偿同步，确保保护期内收到的消息事件被处理
      _CachedAgentProxyBase._log.debug('会话清空保护期结束，触发补偿同步');
      _syncMessagesFromRemote();
    });

    _pendingPermissionRequests.clear();
    _pendingConfirmRequests.clear();

    // 在删除前获取本地 maxSeq，用于设置 clearSeq = lastSeq = maxSeq
    final maxSeq = _messageStore.getMaxSeq(_deviceId, _employeeId);
    await _messageStore.deleteMessages(_deviceId, _employeeId);
    if (maxSeq > 0) {
      _messageStore.resetLastSeq(_deviceId, _employeeId, maxSeq);
    }
    _notifyMessagesChanged();

    _CachedAgentProxyBase._log.info('本地会话已清空，水位线: clearSeq=lastSeq=$maxSeq');
  }

  /// 处理会话摘要变更事件
  ///
  /// 收到远程广播的会话摘要后，触发本地摘要同步，
  /// 确保 UI 能及时更新未读计数和最新消息预览。
  void _handleSessionSummaryChanged(Map<String, dynamic> data) {
    _CachedAgentProxyBase._log.debug('收到会话摘要变更事件');

    // 从远程同步最新摘要，更新本地未读计数和最新消息缓存
    _syncSessionSummaryFromRemote();
  }

  /// 处理消息已读状态变更事件（来自远程 Agent 广播或其他设备）
  void _handleMessageReadStatusChanged(Map<String, dynamic> data) {
    final readSeq = data['readSeq'] as int?;

    if (readSeq != null) {
      // 基于 seq 的批量已读：更新本地 DB
      _messageStore.markAsReadBySeqInDb(_deviceId, _employeeId, readSeq);
    } else {
      // 全部已读：更新本地 DB
      _messageStore.markAsReadInDb(_deviceId, _employeeId);
    }

    // 通知 UI 刷新（不触发远程摘要同步，避免 upsertFromRemote 的 MAX 语义覆盖本地已读状态）
    _notifyMessagesChanged();
  }

  /// 处理配置变更事件
  ///
  /// 收到 configChanged 事件后，解析配置数据并更新 AgentProxy 的远程缓存，
  /// 确保 UI 通过 getProviderConfig()/getCurrentProjectUuid() 等方法获取最新配置。
  void _handleConfigChanged(Map<String, dynamic> data) {
    final configType = data['configType'] as String?;
    final action = data['action'] as String?;
    _CachedAgentProxyBase._log.debug('配置变更: type=$configType, action=$action');

    switch (configType) {
      case 'provider':
        final providerConfigMap = data['providerConfig'] as Map<String, dynamic>?;
        if (providerConfigMap != null) {
          _proxy.updateRemoteCache(providerConfig: providerConfigMap);
          _CachedAgentProxyBase._log.info('远程 Provider 配置已更新: ${providerConfigMap['provider']} · ${providerConfigMap['model']}');
        } else if (action == 'cleared') {
          _proxy.clearRemoteCacheConfig('provider');
        }
        break;
      case 'project':
        final projectData = data['projectData'] as Map<String, dynamic>?;
        if (projectData != null) {
          final projectUuid = projectData['projectUuid'] as String?;
          _proxy.updateRemoteCache(projectUuid: projectUuid);
          _CachedAgentProxyBase._log.info('远程项目已更新: $projectUuid');
        } else if (action == 'cleared') {
          _proxy.clearRemoteCacheConfig('project');
        }
        break;
      case 'context':
        final contextData = data['contextData'] as Map<String, dynamic>?;
        if (contextData != null) {
          _proxy.updateRemoteCache(contextData: contextData);
        } else if (action == 'cleared') {
          _proxy.clearRemoteCacheConfig('context');
        }
        break;
      case 'skills':
        // skills 变更事件不携带完整列表，仅标记变更类型
        // 完整数据需通过 getSkillsConfigAsync() 主动拉取
        _CachedAgentProxyBase._log.debug('远程技能配置变更: action=$action');
        break;
      case 'tools':
        _CachedAgentProxyBase._log.debug('远程工具配置变更: action=$action');
        break;
      default:
        _CachedAgentProxyBase._log.debug('未知配置变更类型: $configType');
        break;
    }

    // 通知 UI 刷新配置显示
    _notifyMessagesChanged();
  }

  /// 处理状态变更
  void _handleStateChange(AgentStateSnapshot state) {
    _CachedAgentProxyBase._log.debug('状态变更: ${state.status}');

    // 更新状态缓存（来自 onStateChanged 流的快照）
    _currentProcessingMessageId = state.currentProcessingMessageId;
    _queuedMessageIds = state.queuedMessageIds;

    // 会话清空保护期内，跳过消息同步
    if (_sessionClearPending) {
      _CachedAgentProxyBase._log.debug('会话清空保护期内，跳过状态变更同步');
      return;
    }

    // 根据状态决定是否触发消息同步
    if (state.status == AgentStatus.idle) {
      // Agent空闲时，使用较短去抖同步消息（避免与 agentStatusChanged 重复）
      _debouncedSyncMessages(delay: const Duration(milliseconds: 200));
    } else if (state.status == AgentStatus.waitingPermission) {
      // Agent等待权限时，查询权限请求和确认请求
      _queryPendingPermission();
      _queryPendingConfirm();
    }
  }
}
