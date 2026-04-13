import 'dart:convert';
import 'dart:io';

import '../../agent/entity/agent_event.dart';
import '../../agent/entity/agent_message.dart';
import '../../entity/lan_device_info.dart';
import '../../entity/lan_message.dart';
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

  static DeviceMessageHandler getInstance(String deviceId) {
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
      case LanMessageType.agentSessionCleared:
        _handleAgentEvent(msg);
      case LanMessageType.agentMessageReadStatus:
        _handleRemoteReadStatus(msg);
      case LanMessageType.agentUnreceivedMessagesBatch:
        _handleUnreceivedMessagesBatch(msg);
      case LanMessageType.system:
        _handleSystemMessage(msg);
      case LanMessageType.deviceOnline:
      case LanMessageType.deviceOffline:
      case LanMessageType.deviceInfoChanged:
      case LanMessageType.deviceInfoResponse:
        _handleDeviceEventMessage(msg);
      case LanMessageType.deviceMessage:
        break;
      case LanMessageType.deviceInfoRequest:
        _handleDeviceInfoRequest(msg);
        break;
      default:
        break;
    }
  }

  void _handleRpcRequest(LanMessage msg) {
    final rpcServer = _connectionManager.rpcServer;
    if (rpcServer == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? {};
      rpcServer.handleRequest(payload);
    } catch (_) {}
  }

  void _handleRpcResponse(LanMessage msg) {
    final rpcManager = _connectionManager.rpcManager;
    if (rpcManager == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      rpcManager.handleResponse(payload);
    } catch (_) {}
  }

  void _handleRpcError(LanMessage msg) {
    final rpcManager = _connectionManager.rpcManager;
    if (rpcManager == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      rpcManager.handleError(payload);
    } catch (_) {}
  }

  void _handleStreamChunk(LanMessage msg) {
    final rpcManager = _connectionManager.rpcManager;
    if (rpcManager == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      rpcManager.handleStreamChunk(payload);
    } catch (_) {}
  }

  void _handleStreamEnd(LanMessage msg) {
    final rpcManager = _connectionManager.rpcManager;
    if (rpcManager == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      rpcManager.handleStreamEnd(payload);
    } catch (_) {}
  }

  void _handleAgentEvent(LanMessage msg) {
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final eventType = AgentEventType.fromString(content['type'] as String? ?? '');
      final data = content['data'] as Map<String, dynamic>? ?? {};
      final employeeId = content['employeeId'] as String?;
      final fromDeviceId = msg.fromId;

      _stateHolder.eventController.add(AgentEvent(
        type: eventType,
        data: data,
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
      ));

      if (employeeId != null && fromDeviceId != null) {
        if (eventType == AgentEventType.messageStatusChanged) {
          final status = data['status'] as String?;
          final messageId = data['messageId'] as String?;

          if (status == 'completed' && messageId != null) {
            final isLocal = fromDeviceId == _deviceId;
            if (!isLocal) {
              final remoteMsg = AgentMessage(
                id: messageId,
                role: 'assistant',
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
        }

        if (eventType == AgentEventType.agentStatusChanged) {
          final status = data['status'] as String?;
          if (status != null) {
            _stateHolder.notificationHub.onAgentStatusChanged(
              employeeId: employeeId,
              fromDeviceId: fromDeviceId,
              status: status,
            );

            if (status == 'waitingPermission') {
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
            _stateHolder.notificationHub.markAllAsRead(
              employeeId: employeeId,
              fromDeviceId: fromDeviceId,
            );
            // DB 更新后用 SQL 统计修正内存缓存
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
    } catch (_) {}
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
        } catch (_) {
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
    } catch (_) {}
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

  void _handleRemoteReadStatus(LanMessage msg) {
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final employeeId = content['employeeId'] as String?;
      final fromDeviceId = content['fromDeviceId'] as String?;
      final readerDeviceId = content['readerDeviceId'] as String?;
      final global = content['global'] as bool? ?? false;

      if (readerDeviceId == _deviceId) return;

      if (global) {
        _stateHolder.notificationHub.markAllAsReadGlobal();
        _notificationManager.markAllMessagesAsReadGlobal();
      } else {
        if (employeeId == null) return;
        _stateHolder.notificationHub.markAllAsRead(
          employeeId: employeeId,
          fromDeviceId: fromDeviceId,
        );
        // DB 更新后用 SQL 统计修正内存缓存
        _notificationManager.markMessagesAsReadInDb(employeeId, fromDeviceId).then((dbUnreadCount) {
          if (dbUnreadCount >= 0) {
            _stateHolder.notificationHub.restoreUnreadCount(
              employeeId: employeeId,
              count: dbUnreadCount,
            );
          }
        });
      }
    } catch (_) {}
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
    } catch (_) {}
  }
}
