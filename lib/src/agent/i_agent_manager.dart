import 'agent_state.dart';
import 'i_agent.dart';

/// Agent 管理服务接口
///
/// 负责 Agent 实例的创建、缓存、查询和清理。
abstract class IAgentManager {
  /// 空间ID
  String get spaceId;

  // ===== Agent 生命周期 =====

  /// 获取或创建 Agent
  ///
  /// [employeeUuid] 员工UUID
  /// [sessionUuid] 会话UUID（可选）
  Future<IAgent> getOrCreate({
    required String employeeUuid,
    String? sessionUuid,
  });

  /// 获取 Agent
  IAgent? get(String employeeUuid);

  /// 移除 Agent
  Future<void> remove(String employeeUuid);

  /// 移除所有 Agent
  Future<void> removeAll();

  // ===== 全局查询 =====

  /// 获取员工列表
  Future<List<Map<String, dynamic>>> getEmployeeList();

  /// 获取指定员工的会话列表
  Future<List<Map<String, dynamic>>> getSessionList(String employeeUuid);

  /// 获取指定会话的消息列表
  Future<List<Map<String, dynamic>>> getSessionMessages(String sessionUuid);

  // ===== 状态查询 =====

  /// 获取活跃 Agent 摘要列表
  List<AgentRuntimeSummary> getActiveSummaries();

  /// 获取内存统计
  Map<String, dynamic> getMemoryStats();

  /// 活跃 Agent 数量
  int get activeCount;

  // ===== 清理 =====

  /// 清理超时无引用的 Agent
  Future<void> cleanup();

  /// 释放所有资源
  Future<void> dispose();
}
