import 'dart:async';

import '../agent_state.dart';
import '../i_agent_manager.dart';

/// Agent RPC 状态广播器（纯 Dart）
///
/// 负责将 Agent 状态变更事件通过 RPC 推送给远程客户端。
class AgentRpcBroadcaster {
  final IAgentManager _agentManager;

  /// 发送事件到远程客户端
  final void Function(String employeeUuid, Map<String, dynamic> eventMap)?
      onBroadcast;

  /// 已订阅的 Agent -> 订阅取消器
  final Map<String, StreamSubscription<AgentStateSnapshot>> _subscriptions =
      {};

  AgentRpcBroadcaster({
    required IAgentManager agentManager,
    this.onBroadcast,
  }) : _agentManager = agentManager;

  /// 开始监听指定 Agent 的状态变更
  void subscribe(String employeeUuid) {
    if (_subscriptions.containsKey(employeeUuid)) return;

    final agent = _agentManager.get(employeeUuid);
    if (agent == null) return;

    final subscription = agent.onStateChanged.listen((snapshot) {
      _broadcastEvent(
        employeeUuid,
        _serializeStatusChange(
          employeeUuid: employeeUuid,
          snapshot: snapshot,
          sessionUuid: agent.currentSessionUuid,
        ),
      );
    });

    _subscriptions[employeeUuid] = subscription;
  }

  /// 停止监听指定 Agent
  void unsubscribe(String employeeUuid) {
    _subscriptions[employeeUuid]?.cancel();
    _subscriptions.remove(employeeUuid);
  }

  /// 主动广播当前快照（用于初始同步）
  void broadcastCurrentState(String employeeUuid) {
    final agent = _agentManager.get(employeeUuid);
    if (agent == null) return;

    _broadcastEvent(
      employeeUuid,
      _serializeSnapshot(
        agent.getStateSnapshot(),
        employeeUuid: employeeUuid,
        sessionUuid: agent.currentSessionUuid,
      ),
    );
  }

  /// 发送事件
  void _broadcastEvent(
    String employeeUuid,
    Map<String, dynamic> eventMap,
  ) {
    if (onBroadcast == null) return;

    try {
      onBroadcast!(employeeUuid, eventMap);
    } catch (_) {}
  }

  /// 释放所有资源
  Future<void> dispose() async {
    for (final sub in _subscriptions.values) {
      await sub.cancel();
    }
    _subscriptions.clear();
  }

  // ===== 序列化方法 =====

  Map<String, dynamic> _serializeStatusChange({
    required String employeeUuid,
    required AgentStateSnapshot snapshot,
    String? sessionUuid,
  }) {
    return {
      'type': 'agentStatusChanged',
      'data': {
        'employeeUuid': employeeUuid,
        'sessionUuid': sessionUuid,
        ...snapshot.toMap(),
      },
    };
  }

  Map<String, dynamic> _serializeSnapshot(
    AgentStateSnapshot snapshot, {
    required String employeeUuid,
    String? sessionUuid,
  }) {
    return {
      'type': 'agentStatusChanged',
      'data': {
        'employeeUuid': employeeUuid,
        'sessionUuid': sessionUuid,
        ...snapshot.toMap(),
      },
    };
  }
}
