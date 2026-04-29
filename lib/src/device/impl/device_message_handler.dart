import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../../agent/entity/agent_event.dart';
import '../../agent/entity/agent_message.dart';
import '../../agent/entity/file_meta_message.dart';
import '../../entity/lan_device_info.dart';
import '../../entity/lan_message.dart';
import '../../persistence/persistence.dart';
import '../../service/service.dart';
import '../../utils/logger.dart';
import '../app_context.dart';
import '../device_client.dart';
import 'device_agent_manager.dart';
import 'device_connection_manager.dart';
import 'device_notification_manager.dart';
import 'device_registry.dart';
import 'device_state_holder.dart';
import 'employee_online_tracker.dart';

/// LAN 消息处理器
///
/// 负责接收 LAN 消息并分发到对应的处理器。
class DeviceMessageHandler {
  static final _log = Logger('DeviceMessageHandler');

  final String _deviceId;
  String? _deviceName;
  String? _topic;
  late final DeviceConnectionManager _connectionManager = DeviceConnectionManager.getInstance(_deviceId);
  late final DeviceStateHolder _stateHolder = DeviceStateHolder.getInstance(_deviceId);
  late final DeviceNotificationManager _notificationManager = DeviceNotificationManager.getInstance(_deviceId);
  late final DeviceAgentManager _agentManager = DeviceAgentManager.getInstance(_deviceId);
  late final DeviceRegistry _deviceRegistry = DeviceRegistry.getInstance(_deviceId);
  late final EmployeeOnlineTracker _onlineTracker = EmployeeOnlineTracker.getInstance(_deviceId);

  DeviceMessageHandler._({required String deviceId, String? deviceName, String? topic})
      : _deviceId = deviceId,
        _deviceName = deviceName,
        _topic = topic;

  // ===== 单例管理 =====

  static final Map<String, DeviceMessageHandler> _instances = {};

  /// 从 [AppContext] 获取实例，不存在则回退到独立创建
  static DeviceMessageHandler getInstance(String deviceId) {
    final ctx = AppContext.get(deviceId);
    if (ctx != null) return ctx.messageHandler;
    return _instances.putIfAbsent(
      deviceId,
      () => DeviceMessageHandler._(deviceId: deviceId),
    );
  }

  /// 初始化配置
  void initialize({String? deviceName, String? topic}) {
    updateConfig(deviceName: deviceName, topic: topic);
  }

  static void removeInstance(String deviceId) {
    _instances.remove(deviceId);
  }

  // ===== 配置 =====

  void updateConfig({String? deviceName, String? topic}) {
    if (deviceName != null) _deviceName = deviceName;
    if (topic != null) _topic = topic;
  }

  /// 处理接收到的 LAN 消息
  void handleMessage(LanMessage msg) {
    // 广播到LAN消息流
    _stateHolder.lanMessageController.add(msg);

    // 调用外部处理器
    _stateHolder.lanMessageHandler?.call(msg);

    // 处理内部消息
    switch (msg.type) {
      case LanMessageType.rpcRequest:
        _handleRpcRequest(msg);
      case LanMessageType.rpcResponse:
        _handleRpcResponse(msg);
      case LanMessageType.rpcError:
        _handleRpcError(msg);
      case LanMessageType.rpcStreamChunk:
        _handleStreamChunk(msg);
      case LanMessageType.rpcStreamEnd:
        _handleStreamEnd(msg);
      case LanMessageType.agentStatusChanged:
      case LanMessageType.agentMessageStatusChanged:
      case LanMessageType.agentMessageReadStatusChanged:
      case LanMessageType.toolCallStart:
      case LanMessageType.toolCallResult:
      case LanMessageType.agentPermissionChanged:
      case LanMessageType.agentSessionCleared:
      case LanMessageType.agentConfirmChanged:
      case LanMessageType.agentTodoChanged:
      case LanMessageType.agentSpecChanged:
      case LanMessageType.agentConfigChanged:
      case LanMessageType.agentTokenUsageUpdated:
        _handleAgentEvent(msg);
      case LanMessageType.agentMessageReadStatus:
      case LanMessageType.agentSessionSummaryChanged:
        _handleSessionSummaryChanged(msg);
      case LanMessageType.agentUnreceivedMessagesBatch:
        _handleUnreceivedMessagesBatch(msg);
      case LanMessageType.system:
        _handleSystemMessage(msg);
      case LanMessageType.deviceOnline:
      case LanMessageType.deviceOffline:
      case LanMessageType.deviceInfoChanged:
      case LanMessageType.deviceInfoResponse:
        _handleDeviceEventMessage(msg);
      case LanMessageType.file:
        _handleFileMessage(msg);
      case LanMessageType.deviceMessage:
        break;
      case LanMessageType.deviceInfoRequest:
        _handleDeviceInfoRequest(msg);
        break;
      default:
        break;
    }
  }

  /// 处理接收到的文件元信息消息
  ///
  /// 解析元信息、记录日志，并持久化到本地 DB（当 [FileMetaMessage.role]
  /// 和 [FileMetaMessage.employeeId] 存在时）。
  /// 上层（wenzflow UI）通过监听 lanMessage 流获取元信息后决定是否下载。
  Future<void> _handleFileMessage(LanMessage msg) async {
    try {
      final content = msg.content;
      if (content == null || content.isEmpty) return;

      final metaMap = jsonDecode(content) as Map<String, dynamic>;
      // 确保 fromDeviceId 使用 msg.fromId（可信来源）
      metaMap['fromDeviceId'] ??= msg.fromId;

      final meta = FileMetaMessage.fromJson(metaMap);

      _log.info('收到文件元信息: ${meta.fileName} '
          '(${meta.fileSize} bytes) from ${msg.fromId} '
          'role=${meta.role} employeeId=${meta.employeeId}');

      // 持久化到本地 DB（仅当发送方携带了 role 和 employeeId 时）
      if (meta.role != null && meta.employeeId != null) {
        try {
          final chatMsg = ChatMessage.file(
            id: msg.id ?? const Uuid().v4(),
            employeeId: meta.employeeId!,
            role: MessageRole.fromString(meta.role!),
            fileName: meta.fileName,
            fileSize: meta.fileSize,
            fileId: meta.fileId,
            fileHash: meta.sha256,
            filePath: meta.filePath,
            fromDeviceId: meta.fromDeviceId,
            mimeType: meta.mimeType,
            deviceId: _deviceId,
          );
          final store = MessageStoreService.getInstance(_deviceId);
          await store.addMessage(_deviceId, chatMsg);
          _log.debug('文件消息已持久化: ${meta.fileName}');
        } catch (e) {
          _log.warn('文件消息持久化失败: $e');
        }
      }
    } catch (e) {
      _log.warn('解析文件元信息失败: $e');
    }
  }

  void _handleRpcRequest(LanMessage msg) {
    final rpcServer = _connectionManager.rpcServer;
    if (rpcServer == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? {};
      rpcServer.handleRequest(payload);
    } catch (e) {
      _log.debug('handleRpcRequest failed: $e');
    }
  }

  void _handleRpcResponse(LanMessage msg) {
    final rpcManager = _connectionManager.rpcManager;
    if (rpcManager == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      rpcManager.handleResponse(payload);
    } catch (e) {
      _log.debug('handleRpcResponse failed: $e');
    }
  }

  void _handleRpcError(LanMessage msg) {
    final rpcManager = _connectionManager.rpcManager;
    if (rpcManager == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      rpcManager.handleError(payload);
    } catch (e) {
      _log.debug('handleRpcError failed: $e');
    }
  }

  void _handleStreamChunk(LanMessage msg) {
    final rpcManager = _connectionManager.rpcManager;
    if (rpcManager == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      rpcManager.handleStreamChunk(payload);
    } catch (e) {
      _log.debug('handleStreamChunk failed: $e');
    }
  }

  void _handleStreamEnd(LanMessage msg) {
    final rpcManager = _connectionManager.rpcManager;
    if (rpcManager == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      rpcManager.handleStreamEnd(payload);
    } catch (e) {
      _log.debug('handleStreamEnd failed: $e');
    }
  }

  void _handleAgentEvent(LanMessage msg) {
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final eventType = AgentEventType.fromString(content['type'] as String? ?? '');
      final data = content['data'] as Map<String, dynamic>? ?? {};
      final employeeId = content['employeeId'] as String?;
      final fromDeviceId = msg.fromId;

      // 广播事件到本地 AgentEvent 流（本地和远程事件都需要广播）
      _stateHolder.eventController.add(AgentEvent(
        type: eventType,
        data: data,
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
      ));

      if (employeeId != null && fromDeviceId != null) {
        // 判断是否为远程设备发来的 LAN 广播事件
        final isRemote = fromDeviceId != _deviceId;

        // 更新远程 CachedAgentProxy 的工具调用 ID 缓存
        if (eventType == AgentEventType.toolCallStart) {
          final toolCallId = data['toolCallId'] as String?;
          if (toolCallId != null) {
            final proxy = _agentManager.getAgentProxy(employeeId);
            proxy?.addRemoteCallingToolId(toolCallId);
          }
        }
        if (eventType == AgentEventType.toolCallResult) {
          final toolCallId = data['toolCallId'] as String?;
          if (toolCallId != null) {
            final proxy = _agentManager.getAgentProxy(employeeId);
            proxy?.removeRemoteCallingToolId(toolCallId);
          }
        }

        if (eventType == AgentEventType.messageStatusChanged) {
          final status = data['status'] as String?;
          final messageId = data['messageId'] as String?;

          if (status == 'completed' && messageId != null) {
            if (isRemote) {
              final remoteMsg = AgentMessage(
                id: messageId,
                role: data['role'] as String? ?? 'assistant',
                type: data['type'] as String? ?? 'text',
                content: data['content'] as String?,
                createdAt: DateTime.now(),
                status: status,
                metadata: Map<String, dynamic>.from(data),
              );
              _stateHolder.notificationHub.onRemoteMessage(
                message: remoteMsg,
                fromDeviceId: fromDeviceId,
                toDeviceId: _deviceId,
                employeeId: employeeId,
              );
              _notificationManager.updateLatestMessageCache(employeeId, fromDeviceId, remoteMsg);
            }
          }

          // 远程设备发送消息时，更新最新消息缓存，让会话列表实时显示
          if (status == 'queued' && messageId != null) {
            if (isRemote) {
              final content = data['content'] as String?;
              if (content != null && content.isNotEmpty) {
                final remoteMsg = AgentMessage(
                  id: messageId,
                  role: data['role'] as String? ?? 'user',
                  type: data['type'] as String? ?? 'text',
                  content: content,
                  createdAt: DateTime.now(),
                  status: status,
                  metadata: Map<String, dynamic>.from(data),
                );
                // 通知 notificationHub，让会话列表实时更新最新消息
                _stateHolder.notificationHub.onRemoteMessage(
                  message: remoteMsg,
                  fromDeviceId: fromDeviceId,
                  toDeviceId: _deviceId,
                  employeeId: employeeId,
                );
                _notificationManager.updateLatestMessageCache(employeeId, fromDeviceId, remoteMsg);
              }
            }
          }
        }

        if (eventType == AgentEventType.agentStatusChanged) {
          final status = data['status'] as String?;
          if (status != null) {
            // 构建 extra，携带 requestId 等额外信息
            final extra = <String, dynamic>{};
            if (data.containsKey('requestId')) {
              extra['requestId'] = data['requestId'];
            }
            if (data.containsKey('description')) {
              extra['description'] = data['description'];
            }
            _stateHolder.notificationHub.onAgentStatusChanged(
              employeeId: employeeId,
              fromDeviceId: fromDeviceId,
              status: status,
              extra: extra.isNotEmpty ? extra : null,
            );

            // 更新远程 CachedAgentProxy 的状态缓存
            final proxy = _agentManager.getAgentProxy(employeeId);
            if (proxy != null) {
              if (status == 'idle') {
                proxy.updateRemoteStateCache(
                  clearProcessing: true,
                  clearQueued: true,
                );
              } else {
                proxy.updateRemoteStateCache(
                  currentProcessingMessageId: data['currentProcessingMessageId'] as String?,
                  queuedMessageIds: (data['queuedMessageIds'] as List?)?.cast<String>(),
                );
              }
            }

            if (status == 'waitingPermission' && isRemote) {
              final requestId = data['requestId'] as String?;
              final permMessageId = requestId != null
                  ? 'perm_$requestId'
                  : 'perm_${DateTime.now().millisecondsSinceEpoch}';
              final permMsg = AgentMessage(
                id: permMessageId,
                role: 'assistant',
                type: 'permission',
                content: data['description'] as String? ?? '等待权限确认',
                createdAt: DateTime.now(),
                metadata: {
                  'isPermissionRequest': true,
                  'permissionRequest': data,
                },
              );
              _stateHolder.notificationHub.onRemoteMessage(
                message: permMsg,
                fromDeviceId: fromDeviceId,
                toDeviceId: _deviceId,
                employeeId: employeeId,
              );
              _notificationManager.updateLatestMessageCache(employeeId, fromDeviceId, permMsg);
            }
          }
        }

        if (eventType == AgentEventType.messageReadStatusChanged) {
          final readerDeviceId = data['readerDeviceId'] as String?;
          if (readerDeviceId != null && readerDeviceId != _deviceId) {
            final readSeq = data['readSeq'] as int?;
            if (readSeq != null) {
              // 基于 seq 的批量已读
              final messageStore = MessageStoreService.getInstance(_deviceId);
              messageStore.markAsReadBySeqInDb(_deviceId, employeeId, readSeq);
              // 刷新 summary
              final summaryStore = SessionSummaryStore(deviceId: _deviceId);
              summaryStore.markAsReadBySeq(employeeId, readSeq, deviceId: _deviceId);
              // 用 DB 统计修正内存缓存
              final dbUnreadCount = messageStore.getUnreadCount(_deviceId, employeeId);
              _stateHolder.notificationHub.restoreUnreadCount(
                employeeId: employeeId,
                count: dbUnreadCount,
              );
            } else {
              // 全部已读（原有逻辑）
              _stateHolder.notificationHub.markAllAsRead(
                employeeId: employeeId,
                fromDeviceId: fromDeviceId,
              );
              _notificationManager.markMessagesAsReadInDb(employeeId, fromDeviceId).then((dbUnreadCount) {
                if (dbUnreadCount >= 0) {
                  _stateHolder.notificationHub.restoreUnreadCount(
                    employeeId: employeeId,
                    count: dbUnreadCount,
                  );
                }
              });
            }
          }
        }

        if (eventType == AgentEventType.sessionSummaryChanged && isRemote) {
          final summaryData = data['summary'] as Map<String, dynamic>?;
          if (summaryData != null) {
            final summary = SessionSummaryEntity.fromMap(summaryData);
            final localSummary = SessionSummaryEntity(
              employeeId: employeeId,
              deviceId: _deviceId,
              unreadCount: summary.unreadCount,
              lastMsgId: summary.lastMsgId,
              lastMsgRole: summary.lastMsgRole,
              lastMsgContent: summary.lastMsgContent,
              lastMsgTime: summary.lastMsgTime,
              lastMsgSeq: summary.lastMsgSeq,
              updateTime: summary.updateTime,
            );
            final summaryStore = SessionSummaryStore(deviceId: _deviceId);
            summaryStore.upsertFromRemote(localSummary);
            // 仅在内存无精确追踪时才修正未读计数，避免远程旧值覆盖本地精确值
            _stateHolder.notificationHub.adjustUnreadCountFromDb(
              employeeId: employeeId,
              count: summary.unreadCount,
            );

            // 处理 pending 字段：恢复远程设备的 pending 通知
            if (summary.hasPendingPermission) {
              _stateHolder.notificationHub.onPermissionPending(
                employeeId: employeeId,
                fromDeviceId: fromDeviceId,
                permissionJson: summary.pendingPermission!,
              );
            }
            if (summary.hasPendingConfirm) {
              _stateHolder.notificationHub.onConfirmPending(
                employeeId: employeeId,
                fromDeviceId: fromDeviceId,
                confirmJson: summary.pendingConfirm!,
              );
            }
          }
        }

        // 会话清空事件：清除未读计数、最新消息缓存，并同步消息（清除本地消息）
        if (eventType == AgentEventType.sessionCleared && isRemote) {
          _stateHolder.notificationHub.markAllAsRead(
            employeeId: employeeId,
          );
          _notificationManager.clearLatestMessageCache(employeeId);
          // 触发增量同步，清除本地消息并更新水位线
          _syncAfterSessionCleared(employeeId, fromDeviceId);
        }

        // 配置变更事件：将远程配置写入本地 SessionStore（仅远程）
        if (eventType == AgentEventType.configChanged && isRemote) {
          _handleConfigChangedEvent(employeeId, fromDeviceId, data);
        }

        // Spec 数据变更事件：将远程 spec 写入本地 SpecStore（仅远程）
        if (eventType == AgentEventType.specChanged && isRemote) {
          _handleSpecChangedEvent(employeeId, fromDeviceId, data);
        }

        // Todo 数据变更事件：将远程 todo 写入本地 TodoStore（仅远程）
        if (eventType == AgentEventType.todoTopicChanged && isRemote) {
          _handleTodoTopicChangedEvent(employeeId, fromDeviceId, data);
        }
        if (eventType == AgentEventType.todoTaskItemChanged && isRemote) {
          _handleTodoTaskItemChangedEvent(employeeId, fromDeviceId, data);
        }
      }
    } catch (e) {
      _log.debug('handleAgentEvent failed: $e');
    }
  }

  void _handleSystemMessage(LanMessage msg) {
    final content = msg.content ?? '';

    if (content == 'kicked:duplicate_login') {
      _stateHolder.stateController.add(DeviceConnectionState.disconnected);
      return;
    }

    if (content.contains('重连成功')) {
      _stateHolder.stateController.add(DeviceConnectionState.connected);
      _deviceRegistry.sendDeviceRegistration();
      // 先刷新设备列表到缓存，再基于缓存刷新员工在线状态
      () async {
        try {
          await _deviceRegistry.refreshDeviceList();
          _onlineTracker.refreshEmployeeOnlineStates();
        } catch (e) {
          _log.debug('refreshDeviceList failed, falling back to refreshEmployeeOnlineStates: $e');
          _onlineTracker.refreshEmployeeOnlineStates();
        }
      }();
    }
  }

  void _handleDeviceEventMessage(LanMessage msg) {
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final device = LanDeviceInfo.fromMap(content);

      DeviceEventType eventType;
      switch (msg.type) {
        case LanMessageType.deviceOnline:
          eventType = DeviceEventType.online;
          _deviceRegistry.updateDeviceCache(device.id, device.copyWith(status: 'online'));
          _onlineTracker.refreshEmployeeOnlineStates();
          break;
        case LanMessageType.deviceOffline:
          eventType = DeviceEventType.offline;
          _deviceRegistry.removeDeviceCache(device.id);
          _onlineTracker.markDeviceEmployeesOffline(device.id);
          break;
        case LanMessageType.deviceInfoChanged:
        case LanMessageType.deviceInfoResponse:
          eventType = DeviceEventType.infoChanged;
          final existing = _deviceRegistry.getDeviceCache(device.id);
          _deviceRegistry.updateDeviceCache(device.id, device.copyWith(
            status: existing?.status ?? 'online',
          ));
          break;
        default:
          return;
      }

      _stateHolder.deviceEventController.add(DeviceEvent(
        type: eventType,
        device: device.copyWith(
          status: eventType == DeviceEventType.offline
              ? 'offline'
              : (device.status ?? 'online'),
        ),
        timestamp: msg.timestamp,
      ));
    } catch (e) {
      _log.debug('handleDeviceEventMessage failed: $e');
    }
  }

  void _handleDeviceInfoRequest(LanMessage msg) {
    final lanClient = _connectionManager.lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    String? os, deviceType;
    if (Platform.isAndroid) {
      os = 'android';
      deviceType = 'mobile';
    } else if (Platform.isIOS) {
      os = 'ios';
      deviceType = 'mobile';
    } else if (Platform.isWindows) {
      os = 'windows';
      deviceType = 'desktop';
    } else if (Platform.isMacOS) {
      os = 'macos';
      deviceType = 'desktop';
    } else if (Platform.isLinux) {
      os = 'linux';
      deviceType = 'desktop';
    }

    final responseInfo = LanDeviceInfo(
      id: _deviceId,
      name: _deviceName,
      type: deviceType,
      os: os,
      platform: deviceType,
      status: 'online',
    );

    final response = LanMessage(
      type: LanMessageType.deviceInfoResponse,
      fromId: _deviceId,
      fromName: _deviceName,
      toDeviceId: msg.fromId,
      content: jsonEncode(responseInfo.toMap()),
      topic: _topic,
    );

    lanClient.sendLanMessage(response);
  }

  void _handleSessionSummaryChanged(LanMessage msg) {
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final employeeId = content['employeeId'] as String?;
      final fromDeviceId = msg.fromId;

      if (employeeId == null || fromDeviceId == null) return;
      if (fromDeviceId == _deviceId) return;

      final readerDeviceId = content['readerDeviceId'] as String?;
      if (readerDeviceId != null && readerDeviceId == _deviceId) return;

      final summaryData = content['summary'] as Map<String, dynamic>?;
      if (summaryData == null) return;

      final summary = SessionSummaryEntity.fromMap(summaryData);

      // 保留远程摘要的原始 deviceId（employeeId + deviceId 隔离）
      final summaryStore = SessionSummaryStore(deviceId: _deviceId);
      summaryStore.upsertFromRemote(summary);

      // 通知内存层更新未读计数（仅在内存无精确追踪时才覆盖，避免远程旧值覆盖本地精确值）
      _stateHolder.notificationHub.adjustUnreadCountFromDb(
        employeeId: employeeId,
        count: summary.unreadCount,
      );

      // 通知 UI 最新消息更新（使用本地内存中的未读计数，而非远程的）
      if (summary.hasLatestMessage) {
        final agentMsg = _notificationManager.summaryToAgentMessage(summary);
        final localUnreadCount = _stateHolder.notificationHub.getUnreadCount(
          employeeId: employeeId,
          fromDeviceId: fromDeviceId,
        );
        _stateHolder.notificationHub.onLatestMessageUpdated(
          message: agentMsg,
          employeeId: employeeId,
          fromDeviceId: fromDeviceId,
          unreadCount: localUnreadCount,
        );
      }

      // 处理 pending 字段：恢复远程设备的 pending 通知
      if (summary.hasPendingPermission) {
        _stateHolder.notificationHub.onPermissionPending(
          employeeId: employeeId,
          fromDeviceId: summary.deviceId,
          permissionJson: summary.pendingPermission!,
        );
      }
      if (summary.hasPendingConfirm) {
        _stateHolder.notificationHub.onConfirmPending(
          employeeId: employeeId,
          fromDeviceId: summary.deviceId,
          confirmJson: summary.pendingConfirm!,
        );
      }

      _log.debug('收到会话摘要广播: employeeId=$employeeId, unread=${summary.unreadCount}');
    } catch (e) {
      _log.debug('handleSessionSummaryChanged failed: $e');
    }
  }

  /// 会话清空后，触发增量同步以清除本地消息并更新水位线
  void _syncAfterSessionCleared(String employeeId, String fromDeviceId) {
    Future(() async {
      try {
        final messageStore = MessageStoreService.getInstance(_deviceId);

        // 在删除消息前获取 maxSeq，用于设置水位线
        final maxSeq = messageStore.getMaxSeq(_deviceId, employeeId);

        // 删除本地消息
        await messageStore.deleteMessages(_deviceId, employeeId);
        // 重置水位线为清空前 maxSeq，确保后续增量同步不会拉回已清空的消息
        if (maxSeq > 0) {
          messageStore.resetLastSeq(_deviceId, employeeId, maxSeq);
        }
        _log.info('会话清空后本地消息已清除，水位线已重置为 $maxSeq: employeeId=$employeeId');

        // 尝试通过已有的 AgentProxy 增量同步（拉取远程最新状态）
        var proxy = _agentManager.getAgentProxy(employeeId);
        if (proxy != null) {
          await proxy.syncWithRemote();
          _log.info('会话清空后增量同步完成(已有proxy): employeeId=$employeeId');
        }
      } catch (e) {
        _log.error('会话清空后增量同步失败: employeeId=$employeeId', e);
      }
    });
  }

  void _handleUnreceivedMessagesBatch(LanMessage msg) {
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final employeeId = content['employeeId'] as String?;
      final messagesData = content['messages'] as List?;

      if (employeeId == null || messagesData == null || messagesData.isEmpty) return;

      final messageMaps = messagesData
          .map((m) => m as Map<String, dynamic>)
          .toList();

      // 委托给 DeviceAgentManager 处理
      _agentManager.onUnreceivedMessagesBatch(
        employeeId: employeeId,
        fromDeviceId: msg.fromId ?? '',
        messageMaps: messageMaps,
      );
    } catch (e) {
      _log.debug('handleUnreceivedMessagesBatch failed: $e');
    }
  }

  /// 处理远程配置变更事件，将配置写入本地 SessionStore
  ///
  /// 当 A 设备修改配置后，B 设备通过 LAN 广播收到 configChanged 事件，
  /// 将 providerConfig 写入本地 SessionManager 的设备配置中。
  ///
  /// 注意：调用方已在 _handleAgentEvent 入口处过滤了本地事件，此处无需再检查 fromDeviceId。
  void _handleConfigChangedEvent(
    String employeeId,
    String? fromDeviceId,
    Map<String, dynamic> data,
  ) {
    final configType = data['configType'] as String?;
    _log.debug('处理远程配置变更: employeeId=$employeeId, configType=$configType, fromDevice=$fromDeviceId');

    try {
      final sessionManager = SessionManager.getInstance(_deviceId);

      switch (configType) {
        case 'provider':
          final providerConfigMap = data['providerConfig'] as Map<String, dynamic>?;
          if (providerConfigMap != null) {
            // 将 ProviderConfig 序列化为 JSON 字符串存储到 SessionStore
            final providerConfigJson = jsonEncode(providerConfigMap);
            sessionManager.updateDeviceConfig(
              employeeId,
              fromDeviceId ?? _deviceId,
              providerConfig: providerConfigJson,
            );
            _log.info('远程 Provider 配置已写入本地 SessionStore: employeeId=$employeeId');
          }
          break;
        case 'project':
          // project 配置变更不需要写入 SessionStore（projectUuid 由 Agent 运行时维护）
          _log.debug('远程项目配置变更，由 CachedAgentProxy 缓存处理');
          break;
        case 'context':
          // context 配置变更不需要写入 SessionStore（由 Agent 运行时维护）
          _log.debug('远程上下文配置变更，由 CachedAgentProxy 缓存处理');
          break;
        default:
          _log.debug('远程配置变更类型 $configType 不需要写入 SessionStore');
          break;
      }
    } catch (e) {
      _log.debug('处理远程配置变更失败: $e');
    }
  }

  /// 处理远程 Spec 数据变更事件，将 spec 数据写入本地 SpecStore
  ///
  /// 当 A 设备创建/修改/删除 spec 后，B 设备通过 LAN 广播收到 specChanged 事件，
  /// 解析事件 data 中的 spec 数据，调用 SpecStore.upsertFromRemote() merge 写入本地 DB。
  ///
  /// 注意：调用方已在 _handleAgentEvent 入口处过滤了本地事件，此处无需再检查 fromDeviceId。
  void _handleSpecChangedEvent(
    String employeeId,
    String? fromDeviceId,
    Map<String, dynamic> data,
  ) {
    final action = data['action'] as String?;
    _log.debug('处理远程 Spec 变更: employeeId=$employeeId, action=$action, fromDevice=$fromDeviceId');

    try {
      final specData = data['spec'] as Map<String, dynamic>?;
      if (specData != null) {
        final specItem = SpecItemEntity.fromMap(specData);
        final specStore = SpecStore(deviceId: _deviceId);
        specStore.upsertFromRemote(specItem);
        _log.info('远程 Spec 数据已写入本地: specId=${specItem.id}, action=$action');
      } else {
        // 事件中无完整 spec 数据（如 cleared/reordered），仅记录日志
        _log.debug('远程 Spec 变更事件无完整 spec 数据: action=$action');
      }
    } catch (e) {
      _log.debug('处理远程 Spec 变更失败: $e');
    }
  }

  /// 处理远程 TodoTopic 变更事件，将 todo topic 数据写入本地 TodoStore
  ///
  /// 当 A 设备创建/修改/删除 todo topic 后，B 设备通过 LAN 广播收到 todoTopicChanged 事件，
  /// 解析事件 data 中的 topic 数据，调用 TodoStore.upsertTopicFromRemote() merge 写入本地 DB。
  ///
  /// 注意：调用方已在 _handleAgentEvent 入口处过滤了本地事件，此处无需再检查 fromDeviceId。
  void _handleTodoTopicChangedEvent(
    String employeeId,
    String? fromDeviceId,
    Map<String, dynamic> data,
  ) {
    final action = data['action'] as String?;
    _log.debug('处理远程 TodoTopic 变更: employeeId=$employeeId, action=$action, fromDevice=$fromDeviceId');

    try {
      final topicData = data['topic'] as Map<String, dynamic>?;
      if (topicData != null) {
        final topic = TodoTopicEntity.fromMap(topicData);
        final todoStore = TodoStore(deviceId: _deviceId);
        todoStore.upsertTopicFromRemote(topic);
        _log.info('远程 TodoTopic 数据已写入本地: topicId=${topic.id}, action=$action');
      } else {
        // 事件中无完整 topic 数据（如 cleared/reordered），仅记录日志
        _log.debug('远程 TodoTopic 变更事件无完整 topic 数据: action=$action');
      }
    } catch (e) {
      _log.debug('处理远程 TodoTopic 变更失败: $e');
    }
  }

  /// 处理远程 TodoTaskItem 变更事件，将 todo task item 数据写入本地 TodoStore
  ///
  /// 当 A 设备创建/修改/删除 todo task item 后，B 设备通过 LAN 广播收到 todoTaskItemChanged 事件，
  /// 解析事件 data 中的 task item 数据，调用 TodoStore.upsertTaskItemFromRemote() merge 写入本地 DB。
  ///
  /// 注意：调用方已在 _handleAgentEvent 入口处过滤了本地事件，此处无需再检查 fromDeviceId。
  void _handleTodoTaskItemChangedEvent(
    String employeeId,
    String? fromDeviceId,
    Map<String, dynamic> data,
  ) {
    final action = data['action'] as String?;
    _log.debug('处理远程 TodoTaskItem 变更: employeeId=$employeeId, action=$action, fromDevice=$fromDeviceId');

    try {
      final taskItemData = data['taskItem'] as Map<String, dynamic>?;
      if (taskItemData != null) {
        final taskItem = TodoTaskItemEntity.fromMap(taskItemData);
        final todoStore = TodoStore(deviceId: _deviceId);
        todoStore.upsertTaskItemFromRemote(taskItem);
        _log.info('远程 TodoTaskItem 数据已写入本地: taskId=${taskItem.id}, action=$action');
      } else {
        // 事件中无完整 task item 数据（如 reordered），仅记录日志
        _log.debug('远程 TodoTaskItem 变更事件无完整 task item 数据: action=$action');
      }
    } catch (e) {
      _log.debug('处理远程 TodoTaskItem 变更失败: $e');
    }
  }
}
