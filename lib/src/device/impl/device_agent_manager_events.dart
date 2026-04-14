part of 'device_agent_manager.dart';

// ===== 事件处理 / 广播 =====

extension DeviceAgentManagerEvents on DeviceAgentManager {
  void _subscribeAgentEvents(String employeeId, IAgent agent) {
    final subscription = agent.onEvent.listen((event) {
      // 始终广播到 LAN
      broadcastAgentEvent(employeeId, event);

      // 始终添加到本地 eventController，确保本地 UI 能接收到所有事件
      _stateHolder.eventController.add(
        AgentEvent(
          type: event.type,
          data: event.data,
          employeeId: employeeId,
          fromDeviceId: _deviceId,
        ),
      );

      final type = event.type;
      final data = event.data;

      if (type != AgentEventType.messageStatusChanged) return;
      final status = data['status'] as String?;
      final messageId = data['messageId'] as String?;

      if (status == 'queued' && messageId != null) {
        final metadata = data['metadata'] as Map<String, dynamic>?;
        final isScheduledTrigger = metadata?['trigger'] == 'scheduled_task';
        if (!isScheduledTrigger) {
          final content = data['content'] as String?;
          if (content != null && content.isNotEmpty) {
            final msg = AgentMessage(
              id: messageId,
              role: data['role'] as String? ?? 'user',
              type: data['type'] as String? ?? 'text',
              content: content,
              createdAt: DateTime.now(),
              status: status,
              metadata: Map<String, dynamic>.from(data)
                ..['deviceId'] = _deviceId,
            );
            _stateHolder.notificationHub.onLocalMessage(
              message: msg,
              employeeId: employeeId,
            );
            _notificationManager.updateLatestMessageCache(
              employeeId,
              _deviceId,
              msg,
            );
          }
        }
      }

      if (status == 'completed') {
        agent
            .getSessionMessagesByUserCount(userMessageLimit: 1)
            .then((messages) {
              if (messages.isEmpty) return;
              final lastAssistant = messages.lastWhere(
                (m) => m.role == 'assistant',
                orElse: () => messages.last,
              );
              final msg = AgentMessage(
                id: lastAssistant.id,
                role: lastAssistant.role,
                type: lastAssistant.type,
                content: lastAssistant.content,
                createdAt: lastAssistant.createdAt,
                status: status,
                metadata: Map<String, dynamic>.from(data)
                  ..['deviceId'] = _deviceId,
              );
              final autoRead =
                  _stateHolder.notificationHub.shouldAutoMarkAsReadCallback
                      ?.call(employeeId: employeeId, fromDeviceId: _deviceId) ??
                  false;
              _stateHolder.notificationHub.onLocalMessage(
                message: msg,
                employeeId: employeeId,
                markUnread: !autoRead,
                autoRead: autoRead,
              );
              _notificationManager.updateLatestMessageCache(
                employeeId,
                _deviceId,
                msg,
              );

              // 将助手完成消息广播到 LAN，让远端设备能收到完整内容
              final lanClient = _connectionManager.lanClient;
              if (lanClient != null && lanClient.isConnected) {
                final completedData = Map<String, dynamic>.from(data);
                completedData['role'] = msg.role;
                completedData['content'] = msg.content;
                completedData['type'] = msg.type;
                final lanMsg = LanMessage(
                  type: LanMessageType.agentMessageStatusChanged,
                  fromId: _deviceId,
                  content: jsonEncode({
                    'employeeId': employeeId,
                    'type': AgentEventType.messageStatusChanged.value,
                    'data': completedData,
                  }),
                  topic: _topic,
                );
                lanClient.sendLanMessage(lanMsg);
              }
            })
            .catchError((e) {
              DeviceAgentManager._log.debug('getSessionMessagesByUserCount failed: $e');
            });
      }
    });
    _agentEventSubscriptions[employeeId] = subscription;
  }

  /// 广播 Agent 事件到 LAN
  void broadcastAgentEvent(String employeeId, AgentEvent event) {
    final lanClient = _connectionManager.lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    final type = event.type;
    final data = event.data;

    LanMessageType msgType;
    switch (type) {
      case AgentEventType.agentStatusChanged:
        msgType = LanMessageType.agentStatusChanged;
      case AgentEventType.messageStatusChanged:
        msgType = LanMessageType.agentMessageStatusChanged;
      case AgentEventType.messageReadStatusChanged:
        msgType = LanMessageType.agentMessageReadStatusChanged;
      case AgentEventType.toolCallStart:
        msgType = LanMessageType.toolCallStart;
      case AgentEventType.toolCallResult:
        msgType = LanMessageType.toolCallResult;
      case AgentEventType.toolPermissionRequest:
      case AgentEventType.toolPermissionResponse:
        msgType = LanMessageType.agentPermissionChanged;
      case AgentEventType.sessionCleared:
        msgType = LanMessageType.agentSessionCleared;
      default:
        return;
    }

    final msg = LanMessage(
      type: msgType,
      fromId: _deviceId,
      content: jsonEncode({
        'employeeId': employeeId,
        'type': type.value,
        'data': data,
      }),
      topic: _topic,
    );

    lanClient.sendLanMessage(msg);
  }

  /// 广播已读状态到 LAN
  void _broadcastReadStatus({
    required String employeeId,
    String? fromDeviceId,
  }) {
    final lanClient = _connectionManager.lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    final msg = LanMessage(
      type: LanMessageType.agentMessageReadStatus,
      fromId: _deviceId,
      content: jsonEncode({
        'employeeId': employeeId,
        'fromDeviceId': fromDeviceId,
        'readerDeviceId': _deviceId,
      }),
      topic: _topic,
    );

    lanClient.sendLanMessage(msg);
  }

  /// 处理收到的广播消息（客户端侧）
  ///
  /// 收到广播消息后：
  /// 1. 更新通知状态（未读计数 + UI 事件）
  /// 2. 触发基于水位线的 LSN 增量拉取
  /// 3. 由增量拉取统一处理消息存储和水位线更新
  Future<void> onUnreceivedMessagesBatch({
    required String employeeId,
    required String fromDeviceId,
    required List<Map<String, dynamic>> messageMaps,
  }) async {
    if (messageMaps.isEmpty) return;

    DeviceAgentManager._log.info(
      '收到来自设备 $fromDeviceId 的广播消息通知'
      '（员工: $employeeId, ${messageMaps.length} 条）',
    );

    final messages = messageMaps.map((m) => AgentMessage.fromMap(m)).toList();

    // 1. 更新通知状态（未读追踪 + UI 事件）
    for (final message in messages) {
      if (message.role == 'assistant') {
        _stateHolder.notificationHub.onRemoteMessage(
          message: message,
          fromDeviceId: fromDeviceId,
          toDeviceId: _deviceId,
          employeeId: employeeId,
        );
      }
    }

    // 2. 更新最新消息缓存
    if (messages.isNotEmpty) {
      final latestMsg = messages.reduce(
        (a, b) => a.createdAt.isAfter(b.createdAt) ? a : b,
      );
      _notificationManager.updateLatestMessageCache(
        employeeId,
        fromDeviceId,
        latestMsg,
      );
    }

    // 3. 触发基于水位线的增量拉取，统一处理消息存储和水位线更新
    final proxy = getAgentProxy(employeeId);
    if (proxy != null) {
      try {
        await proxy.syncWithRemote();
        DeviceAgentManager._log.debug('增量同步完成: employeeId=$employeeId');
      } catch (e) {
        DeviceAgentManager._log.debug('增量同步失败: employeeId=$employeeId, $e');
      }
    } else {
      DeviceAgentManager._log.debug('未找到代理，跳过增量同步: employeeId=$employeeId');
    }
  }

  Future<void> _backgroundSyncRemoteProxy(
    String cacheKey,
    String employeeId,
    String targetDeviceId,
    CachedAgentProxy cachedProxy,
  ) async {
    if (_syncingRemoteKeys.contains(cacheKey)) return;
    _syncingRemoteKeys.add(cacheKey);

    try {
      await _dataSyncManager.syncEmployeeToDevice(
        employeeId: employeeId,
        targetDeviceId: targetDeviceId,
      );
      await cachedProxy.syncFromRemote();
    } catch (e) {
      DeviceAgentManager._log.debug('后台同步远程代理失败: $e');
    } finally {
      _syncingRemoteKeys.remove(cacheKey);
    }
  }
}
