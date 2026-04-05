import 'dart:convert';

import '../entity/lan_message.dart';
import '../lan/lan_host_service.dart';
import 'client_session_manager.dart';

/// 消息路由器
///
/// 负责在Host端路由消息到正确的目标客户端
class MessageRouter {
  final LanHostService _hostService;
  final ClientSessionManager _sessionManager;

  MessageRouter({
    required LanHostService hostService,
    required ClientSessionManager sessionManager,
  })  : _hostService = hostService,
        _sessionManager = sessionManager;

  /// 路由RPC请求
  ///
  /// [fromClientId] 发送方客户端ID
  /// [message] RPC请求消息
  void routeRpcRequest(String fromClientId, LanMessage message) {
    // 解析目标设备ID
    final toDeviceId = message.toDeviceId;

    if (toDeviceId == 'host' || toDeviceId == null || toDeviceId.isEmpty) {
      // Host处理请求（不需要路由）
      return;
    }

    // 转发给目标设备的所有客户端
    final targetClients = _sessionManager.getClientsByDeviceId(toDeviceId);
    for (final client in targetClients) {
      _sendToClient(client.clientId, message);
    }
  }

  /// 路由RPC响应
  ///
  /// [fromClientId] 发送方客户端ID
  /// [message] RPC响应消息
  void routeRpcResponse(String fromClientId, LanMessage message) {
    // 响应通常发回给请求方，通过toDeviceId指定
    final toDeviceId = message.toDeviceId;
    if (toDeviceId == null || toDeviceId.isEmpty) return;

    final targetClients = _sessionManager.getClientsByDeviceId(toDeviceId);
    for (final client in targetClients) {
      _sendToClient(client.clientId, message);
    }
  }

  /// 广播Agent事件
  ///
  /// [employeeUuid] 员工UUID
  /// [event] 事件数据
  /// [excludeClientId] 排除的客户端ID（发送方）
  void broadcastAgentEvent(
    String employeeUuid,
    Map<String, dynamic> event, {
    String? excludeClientId,
  }) {
    // 获取订阅该员工的所有客户端
    final subscribers = _sessionManager.getClientsByEmployee(employeeUuid);

    final msg = LanMessage(
      type: LanMessageType.agentStatusChanged,
      content: jsonEncode({
        'employeeUuid': employeeUuid,
        ...event,
      }),
    );

    for (final client in subscribers) {
      if (client.clientId != excludeClientId) {
        _sendToClient(client.clientId, msg);
      }
    }
  }

  /// 广播会话变更
  ///
  /// [employeeId] 会话UUID
  /// [change] 变更数据
  /// [topic] 主题（可选，用于限定广播范围）
  void broadcastSessionChange(
    String employeeId,
    Map<String, dynamic> change, {
    String? topic,
  }) {
    final msg = LanMessage(
      type: LanMessageType.aiSessionStatus,
      content: jsonEncode({
        'employeeId': employeeId,
        ...change,
      }),
      topic: topic,
    );

    if (topic != null && topic.isNotEmpty) {
      // 广播给同主题的所有客户端
      broadcast(msg, topic: topic);
    } else {
      // 广播给所有客户端
      broadcast(msg);
    }
  }

  /// 广播消息给所有客户端
  ///
  /// [message] 消息
  /// [topic] 主题（可选，限定广播范围）
  /// [excludeClientId] 排除的客户端ID
  void broadcast(
    LanMessage message, {
    String? topic,
    String? excludeClientId,
  }) {
    List<ClientSession> clients;

    if (topic != null && topic.isNotEmpty) {
      clients = _sessionManager.getClientsByTopic(topic);
    } else {
      clients = _sessionManager.getAllClients();
    }

    for (final client in clients) {
      if (client.clientId != excludeClientId) {
        _sendToClient(client.clientId, message);
      }
    }
  }

  /// 发送消息给指定客户端
  void _sendToClient(String clientId, LanMessage message) {
    _hostService.sendToClient(clientId, message);
  }

  /// 发送消息给指定设备
  void sendToDevice(String deviceId, LanMessage message) {
    final clients = _sessionManager.getClientsByDeviceId(deviceId);
    for (final client in clients) {
      _sendToClient(client.clientId, message);
    }
  }

  /// 广播系统消息
  void broadcastSystemMessage(String content, {String? topic}) {
    final msg = LanMessage(
      type: LanMessageType.system,
      content: content,
      topic: topic,
    );
    broadcast(msg, topic: topic);
  }

  /// 通知客户端被踢下线（重复登录）
  void notifyKicked(String clientId) {
    final msg = LanMessage(
      type: LanMessageType.system,
      content: 'kicked:duplicate_login',
    );
    _sendToClient(clientId, msg);
  }
}
