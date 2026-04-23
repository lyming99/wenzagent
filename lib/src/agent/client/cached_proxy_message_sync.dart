part of 'cached_agent_proxy.dart';

/// 消息同步 mixin
mixin _CachedProxyMessageSync on _CachedAgentProxyBase {
  // ===== 消息同步 =====

  /// 去抖同步远程消息（500ms 内只触发一次，避免短时间内多次调用）
  ///
  /// [delay] 去抖延迟时间，默认 500ms。关键事件可传更短延迟。
  @override
  void _debouncedSyncMessages({Duration delay = const Duration(milliseconds: 500)}) {
    // 会话清空保护期内，记录需要补偿同步，不直接丢弃
    if (_sessionClearPending) {
      _CachedAgentProxyBase._log.debug('会话清空保护期内，记录待补偿同步');
      return;
    }
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = Timer(delay, () {
      if (!_sessionClearPending) {
        _syncMessagesFromRemote();
      }
    });
  }

  /// 从远程同步消息（简化版）
  ///
  /// 流程：
  /// 1. 查询服务端 clearSeq，硬删除本地 seq < clearSeq 的消息
  /// 2. 查询本地消息 maxSeq，查询服务端 lastSeq，拉取差量消息直接写入
  @override
  Future<void> _syncMessagesFromRemote() async {
    if (_isDisposed || _proxy.isLocalMode) return;

    try {
      _CachedAgentProxyBase._log.debug('开始从远程同步消息...');

      // 1. 查询服务端 clearSeq，硬删除本地旧消息
      try {
        final remoteClearSeq = await _proxy.getClearSeq();
        if (remoteClearSeq > 0) {
          final deletedCount = _messageStore.deleteMessagesBeforeSeq(
            _deviceId, _employeeId, remoteClearSeq,
          );
          if (deletedCount > 0) {
            _CachedAgentProxyBase._log.info('根据 clearSeq=$remoteClearSeq 删除了 $deletedCount 条本地消息');
            _messageStore.resetLastSeq(_deviceId, _employeeId, remoteClearSeq);
          }
        }
      } catch (e) {
        _CachedAgentProxyBase._log.error('获取远程 clearSeq 失败', e);
      }

      // 2. 查询本地消息 localLastSeq
      final localLastSeq = _messageStore.getLastSeq(_deviceId, _employeeId);

      // 3. 查询服务端 lastSeq
      int remoteLastSeq = -1;
      try {
        remoteLastSeq = await _proxy.getMaxSeq();
      } catch (e) {
        _CachedAgentProxyBase._log.error('获取远程 lastSeq 失败', e);
        return;
      }

      _CachedAgentProxyBase._log.debug('localLastSeq=$localLastSeq, remoteLastSeq=$remoteLastSeq');

      // 4. 增量拉取：远程有更新的消息时，拉取 seq > localMaxSeq 的消息
      if (remoteLastSeq > localLastSeq) {
        const batchSize = 20;
        final allNewMessages = <AgentMessage>[];
        int currentSeq = localLastSeq;

        while (true) {
          final batch = await _proxy.getMessagesAfterSeq(
            lastSeq: currentSeq,
            limit: batchSize,
          );

          if (batch.isEmpty) break;
          allNewMessages.addAll(batch);

          for (final msg in batch) {
            final seq = msg.metadata?['seq'] as int? ?? 0;
            if (seq > currentSeq) currentSeq = seq;
          }

          if (batch.length < batchSize) break;
        }
        // 注意：不在循环后单独更新水位线，由 addMessage 内部逐条更新（MAX 语义），
        // 避免崩溃时水位线已前进但消息未写入的风险窗口

        // 5. 直接写入本地（INSERT OR REPLACE，无需比较）
        if (allNewMessages.isNotEmpty) {
          for (final message in allNewMessages) {
            final deletedRaw = message.metadata?['deleted'];
            final isDeleted = deletedRaw is bool
                ? deletedRaw
                : (deletedRaw is int ? deletedRaw != 0 : false);

            if (isDeleted) {
              try {
                await _messageStore.hardDeleteMessage(
                    _deviceId, message.id);
              } catch (e) {
                _CachedAgentProxyBase._log.debug('hard delete synced deleted message failed: $e');
              }
              continue;
            }

            // 消息始终以未读写入，由打开聊天窗口时 markMessagesAsRead 统一标记已读
            final chatMsg = _agentMessageToChatMessage(
                message, forceRead: false);
            await _messageStore.addMessage(_deviceId, chatMsg);
          }

          // 清理已被远程消息取代的本地工具调用临时消息
          await _cleanupSupersededLocalToolCalls(allNewMessages);

          // 水位线已在 addMessage 内部逐条更新，此处无需重复
          _notifyMessagesChanged();

          _CachedAgentProxyBase._log.info('同步完成: 拉取 ${allNewMessages.length} 条, lastSeq=$currentSeq');
        }
      } else {
        _CachedAgentProxyBase._log.debug('无新消息需要同步');
      }
    } catch (e) {
      _CachedAgentProxyBase._log.error('同步远程消息失败: $e');
    }

    // 清理残留的本地工具调用临时消息
    _cleanupStaleToolCallMessages();

    // 同步远程会话摘要
    await _syncSessionSummaryFromRemote();
  }

  /// 清理已被远程消息取代的本地工具调用临时消息
  ///
  /// 远程同步拉取的消息中包含官方的 assistant 消息（含 toolCalls）和
  /// tool result 消息，与本地创建的 `local_toolcall_*` 临时消息重复。
  /// 此方法提取远程消息中的 toolCallId，删除对应的本地临时消息。
  @override
  Future<void> _cleanupSupersededLocalToolCalls(
      List<AgentMessage> syncedMessages) async {
    if (_proxy.isLocalMode) return;

    final toolCallIds = <String>{};
    for (final msg in syncedMessages) {
      // 从 assistant 消息的 toolCalls 字段提取
      if (msg.toolCalls != null) {
        for (final tc in msg.toolCalls!) {
          if (tc.id.isNotEmpty) toolCallIds.add(tc.id);
        }
      }
      // 从 tool result 消息的 toolCallId 字段提取
      if (msg.toolCallId != null && msg.toolCallId!.isNotEmpty) {
        toolCallIds.add(msg.toolCallId!);
      }
    }

    if (toolCallIds.isEmpty) return;

    int deletedCount = 0;
    for (final toolCallId in toolCallIds) {
      final localId = 'local_toolcall_$toolCallId';
      try {
        await _messageStore.hardDeleteMessage(_deviceId, localId);
        deletedCount++;
      } catch (e) {
        _CachedAgentProxyBase._log.debug('cleanup superseded local tool call failed, message not found: $e');
      }
    }

    if (deletedCount > 0) {
      _CachedAgentProxyBase._log.info('已清理 $deletedCount 条被远程消息取代的本地工具调用临时消息');
    }
  }

  /// 清理残留的本地工具调用临时消息
  ///
  /// 当 agent 被重启或崩溃后，之前发出的工具调用可能永远没有结果返回。
  /// 这些残留的 `local_toolcall_*` 消息会一直处于 processing 状态。
  /// 在每次同步完成后，将这些消息标记为 failed（无结果）。
  @override
  void _cleanupStaleToolCallMessages() {
    if (_proxy.isLocalMode) return;

    final staleIds = _messageStore.getStaleLocalToolCallMessages(_deviceId, _employeeId);
    if (staleIds.isEmpty) return;

    for (final uuid in staleIds) {
      _messageStore.updateMessageStatus(
        _deviceId, uuid, shared.MessageStatus.failed,
        error: '工具调用无结果（agent 可能已重启）',
      );
    }
    _CachedAgentProxyBase._log.info('已清理 ${staleIds.length} 条残留工具调用消息');
  }

  /// 同步远程会话状态和权限请求
  ///
  /// 在初始化时查询远程 Agent 状态，如果正在等待权限，则查询并缓存权限请求。
  /// 同时同步远程的 Provider 配置和项目 UUID 到本地缓存。
  @override
  Future<void> _syncRemoteStateAndPermission() async {
    if (_isDisposed || _proxy.isLocalMode) return;

    try {
      _CachedAgentProxyBase._log.debug('开始同步远程会话状态和权限请求...');

      // 1. 查询远程 Agent 状态
      final stateSnapshot = await _proxy.getStateSnapshotAsync();
      _CachedAgentProxyBase._log.debug('远程 Agent 状态: ${stateSnapshot.status}');

      // 2. 同步远程 Provider 配置
      try {
        final providerConfig = await _proxy.getProviderConfigAsync();
        if (providerConfig != null) {
          _CachedAgentProxyBase._log.debug('远程 Provider 配置: ${providerConfig.provider} · ${providerConfig.model}');
        } else {
          _CachedAgentProxyBase._log.debug('远程无 Provider 配置');
        }
      } catch (e) {
        _CachedAgentProxyBase._log.error('同步远程 Provider 配置失败', e);
      }

      // 3. 同步远程项目 UUID
      try {
        final projectUuid = await _proxy.getCurrentProjectUuidAsync();
        _CachedAgentProxyBase._log.debug('远程项目 UUID: $projectUuid');
      } catch (e) {
        _CachedAgentProxyBase._log.error('同步远程项目 UUID 失败', e);
      }

      // 4. 同步远程技能配置
      try {
        final skills = await _proxy.getSkillsConfigAsync();
        _CachedAgentProxyBase._log.debug('远程技能配置: ${skills.length} 个');
      } catch (e) {
        _CachedAgentProxyBase._log.error('同步远程技能配置失败', e);
      }

      // 5. 同步远程 MCP 配置
      try {
        final mcpConfigs = await _proxy.getMcpConfigsAsync();
        _CachedAgentProxyBase._log.debug('远程 MCP 配置: ${mcpConfigs.length} 个');
      } catch (e) {
        _CachedAgentProxyBase._log.error('同步远程 MCP 配置失败', e);
      }

      // 6. 同步远程 Spec 数据 → 写入本地 SpecStore
      await _syncSpecsFromRemote();

      // 7. 同步远程 Todo 数据 → 写入本地 TodoStore
      await _syncTodosFromRemote();

      _CachedAgentProxyBase._log.info('远程状态同步完成');
    } catch (e) {
      _CachedAgentProxyBase._log.error('同步远程会话状态失败', e);
    }
  }

  /// 从远程同步 Spec 数据并写入本地 SpecStore
  ///
  /// 通过 RPC 查询远程设备的所有 spec 数据（含已删除），
  /// 调用 SpecStore.upsertFromRemote() merge 写入本地 DB。
  Future<void> _syncSpecsFromRemote() async {
    if (_isDisposed || _proxy.isLocalMode) return;
    try {
      final activeResult = await _proxy.getActiveSpecs();
      final completedResult = await _proxy.getCompletedSpecs(limit: 9999);
      final allSpecMaps = <Map<String, dynamic>>[
        ...activeResult,
        ...completedResult,
      ];
      if (allSpecMaps.isEmpty) return;

      final specStore = SpecStore(dbManager: _messageStore.dbManager);
      final specItems = allSpecMaps
          .map((s) => SpecItemEntity.fromMap(s))
          .toList();
      final count = specStore.upsertAllFromRemote(specItems);
      if (count > 0) {
        _CachedAgentProxyBase._log.info('远程 Spec 同步完成: merge 写入 $count 条');
      }
    } catch (e) {
      _CachedAgentProxyBase._log.debug('同步远程 Spec 数据失败: $e');
    }
  }

  /// 从远程同步 Todo 数据并写入本地 TodoStore
  ///
  /// 通过 RPC 查询远程设备的所有 todo 数据（topics + taskItems），
  /// 调用 TodoStore.upsertTopicFromRemote()/upsertTaskItemFromRemote() merge 写入本地 DB。
  Future<void> _syncTodosFromRemote() async {
    if (_isDisposed || _proxy.isLocalMode) return;
    try {
      // 1. 获取所有 topic（pending + in_progress + completed）
      final pendingTopics = await _proxy.getPendingTopics();
      final completedTopics = await _proxy.getCompletedTopics(limit: 9999);
      final allTopicMaps = <Map<String, dynamic>>[
        ...pendingTopics,
        ...completedTopics,
      ];
      if (allTopicMaps.isEmpty) return;

      final todoStore = TodoStore(dbManager: _messageStore.dbManager);
      final topicItems = allTopicMaps
          .map((t) => TodoTopicEntity.fromMap(t))
          .toList();
      final topicCount = todoStore.upsertAllTopicsFromRemote(topicItems);

      // 2. 对每个 topic 获取 taskItems
      int taskItemCount = 0;
      for (final topic in topicItems) {
        try {
          final taskItemMaps = await _proxy.getTaskItemsByTopic(topic.id);
          if (taskItemMaps.isNotEmpty) {
            final taskItems = taskItemMaps
                .map((t) => TodoTaskItemEntity.fromMap(t))
                .toList();
            taskItemCount += todoStore.upsertAllTaskItemsFromRemote(taskItems);
          }
        } catch (e) {
          _CachedAgentProxyBase._log.debug('同步远程 Todo TaskItems 失败 (topic=${topic.id}): $e');
        }
      }

      if (topicCount > 0 || taskItemCount > 0) {
        _CachedAgentProxyBase._log.info('远程 Todo 同步完成: topics=$topicCount, taskItems=$taskItemCount');
      }
    } catch (e) {
      _CachedAgentProxyBase._log.debug('同步远程 Todo 数据失败: $e');
    }
  }

  /// 从服务端同步会话摘要（未读计数 + 最新消息）
  @override
  Future<void> _syncSessionSummaryFromRemote() async {
    if (_isDisposed || _proxy.isLocalMode) return;
    try {
      final result = await _proxy.getSessionSummary();
      if (result != null) {
        // 1. 更新本地 session_summary 表（通过已初始化的 _messageStore）
        final summary = SessionSummaryEntity.fromMap(result);
        _messageStore.upsertSummaryFromRemote(SessionSummaryEntity(
          employeeId: _employeeId,
          deviceId: _deviceId,
          unreadCount: summary.unreadCount,
          lastMsgId: summary.lastMsgId,
          lastMsgRole: summary.lastMsgRole,
          lastMsgContent: summary.lastMsgContent,
          lastMsgTime: summary.lastMsgTime,
          lastMsgSeq: summary.lastMsgSeq,
          updateTime: summary.updateTime,
        ));

        // 2. 通过回调通知 device layer 更新内存缓存 + UI
        onSessionSummaryUpdated?.call(_employeeId, result);

        _CachedAgentProxyBase._log.debug('会话摘要已同步: unreadCount=${summary.unreadCount}');
      }
    } catch (e) {
      _CachedAgentProxyBase._log.debug('同步会话摘要失败: $e');
    }
  }
}
