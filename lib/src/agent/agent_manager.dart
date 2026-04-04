import 'dart:async';

import 'agent_impl.dart';
import 'agent_state.dart';
import 'i_agent.dart';
import 'i_agent_manager.dart';

/// Agent 工厂函数类型
typedef AgentFactory = Future<AgentImpl> Function({
  required String employeeUuid,
  String? sessionUuid,
});

/// Agent 管理服务实现（纯 Dart）
///
/// 实现 [IAgentManager] 接口，负责 Agent 实例的：
/// - 创建与缓存（按 employeeUuid 隔离）
/// - 引用计数与超时清理
/// - 全局查询
class AgentManager implements IAgentManager {
  @override
  final String spaceId;

  /// Agent 工厂函数
  final AgentFactory _agentFactory;

  /// Agent 缓存: employeeUuid -> AgentImpl
  final Map<String, AgentImpl> _agents = {};

  /// 超时时长（默认 30 分钟）
  final Duration timeoutDuration;

  /// 清理定时器
  Timer? _cleanupTimer;

  /// 清理间隔（默认 5 分钟检查一次）
  final Duration cleanupInterval;

  /// 全局查询回调：获取员工列表
  final Future<List<Map<String, dynamic>>> Function()? _getEmployeeList;

  /// 全局查询回调：获取会话列表
  final Future<List<Map<String, dynamic>>> Function(String employeeUuid)?
      _getSessionList;

  /// 全局查询回调：获取会话消息
  final Future<List<Map<String, dynamic>>> Function(String sessionUuid)?
      _getSessionMessages;

  AgentManager({
    required this.spaceId,
    required AgentFactory agentFactory,
    this.timeoutDuration = const Duration(minutes: 30),
    this.cleanupInterval = const Duration(minutes: 5),
    Future<List<Map<String, dynamic>>> Function()? getEmployeeList,
    Future<List<Map<String, dynamic>>> Function(String employeeUuid)?
        getSessionList,
    Future<List<Map<String, dynamic>>> Function(String sessionUuid)?
        getSessionMessages,
  })  : _agentFactory = agentFactory,
        _getEmployeeList = getEmployeeList,
        _getSessionList = getSessionList,
        _getSessionMessages = getSessionMessages {
    _startCleanupTimer();
  }

  // ===== IAgentManager: Agent 生命周期 =====

  @override
  Future<IAgent> getOrCreate({
    required String employeeUuid,
    String? sessionUuid,
  }) async {
    // 检查缓存
    final existing = _agents[employeeUuid];
    if (existing != null && existing.isAlive) {
      // 如果指定了 sessionUuid 且与当前不同，切换会话
      if (sessionUuid != null &&
          existing.currentSessionUuid != sessionUuid) {
        await existing.switchSession(sessionUuid);
      }
      return existing;
    }

    // 缓存中不存在或已销毁，移除旧实例
    if (existing != null) {
      _agents.remove(employeeUuid);
    }

    // 创建新 Agent
    final agent = await _agentFactory(
      employeeUuid: employeeUuid,
      sessionUuid: sessionUuid,
    );

    // 初始化
    await agent.initialize(sessionUuid: sessionUuid);

    // 缓存
    _agents[employeeUuid] = agent;

    return agent;
  }

  @override
  IAgent? get(String employeeUuid) {
    final agent = _agents[employeeUuid];
    if (agent == null || !agent.isAlive) return null;
    return agent;
  }

  @override
  Future<void> remove(String employeeUuid) async {
    final agent = _agents.remove(employeeUuid);
    if (agent != null && agent.isAlive) {
      await agent.dispose();
    }
  }

  @override
  Future<void> removeAll() async {
    final agents = List<AgentImpl>.from(_agents.values);
    _agents.clear();
    for (final agent in agents) {
      if (agent.isAlive) {
        await agent.dispose();
      }
    }
  }

  // ===== IAgentManager: 全局查询 =====

  @override
  Future<List<Map<String, dynamic>>> getEmployeeList() async {
    if (_getEmployeeList != null) {
      return _getEmployeeList();
    }
    return [];
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionList(
      String employeeUuid) async {
    // 优先从活跃 Agent 获取
    final agent = _agents[employeeUuid];
    if (agent != null && agent.isAlive) {
      return agent.getSessionList();
    }

    // 回退到全局查询
    if (_getSessionList != null) {
      return _getSessionList(employeeUuid);
    }
    return [];
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
      String sessionUuid) async {
    if (_getSessionMessages != null) {
      return _getSessionMessages(sessionUuid);
    }
    return [];
  }

  // ===== IAgentManager: 状态查询 =====

  @override
  List<AgentRuntimeSummary> getActiveSummaries() {
    return _agents.values
        .where((agent) => agent.isAlive)
        .map((agent) => AgentRuntimeSummary(
              employeeUuid: agent.employeeUuid,
              sessionUuid: agent.currentSessionUuid,
              status: agent.status,
              lastActiveTime: agent.lastActiveTime,
              queueLength: agent.queueLength,
              refCount: agent.refCount,
            ))
        .toList();
  }

  @override
  Map<String, dynamic> getMemoryStats() {
    final activeAgents =
        _agents.values.where((a) => a.isAlive).toList();
    final totalQueue =
        activeAgents.fold<int>(0, (sum, a) => sum + a.queueLength);

    return {
      'spaceId': spaceId,
      'totalAgents': _agents.length,
      'activeAgents': activeAgents.length,
      'totalQueueLength': totalQueue,
      'agents': activeAgents
          .map((a) => {
                'employeeUuid': a.employeeUuid,
                'status': a.status.name,
                'refCount': a.refCount,
                'queueLength': a.queueLength,
                'lastActiveTime': a.lastActiveTime.toIso8601String(),
              })
          .toList(),
    };
  }

  @override
  int get activeCount =>
      _agents.values.where((a) => a.isAlive).length;

  // ===== IAgentManager: 清理 =====

  @override
  Future<void> cleanup() async {
    final now = DateTime.now();
    final toRemove = <String>[];

    for (final entry in _agents.entries) {
      final agent = entry.value;

      if (!agent.isAlive) {
        toRemove.add(entry.key);
        continue;
      }

      // 无引用 + 超时 → 清理
      if (agent.refCount == 0 &&
          now.difference(agent.lastActiveTime) > timeoutDuration) {
        toRemove.add(entry.key);
      }
    }

    for (final employeeUuid in toRemove) {
      await remove(employeeUuid);
    }
  }

  @override
  Future<void> dispose() async {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    await removeAll();
  }

  // ===== 内部方法 =====

  /// 启动定时清理
  void _startCleanupTimer() {
    _cleanupTimer = Timer.periodic(cleanupInterval, (_) {
      cleanup();
    });
  }
}
