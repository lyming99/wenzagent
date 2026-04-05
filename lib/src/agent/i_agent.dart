import 'dart:async';

import 'agent_state.dart';
import 'tool/agent_tool.dart';

/// Agent 主体接口
///
/// 定义单个 AI Agent 的所有对外操作。
/// 每个 Agent 实例对应一个员工。
///
/// 设计原则：
/// - 纯 Dart 实现，不依赖 Flutter
/// - 所有输入/输出均为 JSON 可序列化数据
/// - 支持本地调用和远程 RPC 调用
/// - 加锁保证多客户端一致性
abstract class IAgent {
  // ===== 基础信息 =====

  /// 员工UUID
  String get employeeUuid;

  /// 当前会话UUID
  String? get currentSessionUuid;

  /// 当前状态
  AgentStatus get status;

  /// 是否存活（未销毁）
  bool get isAlive;

  // ===== 生命周期 =====

  /// 初始化 Agent
  ///
  /// [sessionUuid] 指定会话UUID，为 null 则查找或创建新会话
  Future<void> initialize({String? sessionUuid});

  /// 销毁 Agent，释放所有资源
  Future<void> dispose();

  // ===== 引用计数 =====

  /// UI 绑定（引用计数 +1）
  void attach();

  /// UI 解绑（引用计数 -1）
  void detach();

  /// 当前引用计数
  int get refCount;

  // ===== 对话操作 =====

  /// 发送消息
  ///
  /// [messageData] 消息数据，必须包含:
  ///   - `content` (String): 消息内容
  ///   - `sessionUuid` (String?): 目标会话UUID，为 null 使用当前会话
  ///
  /// 返回消息ID
  Future<String> sendMessage(Map<String, dynamic> messageData);

  /// 中断当前处理
  Future<void> interrupt();

  /// 撤回消息
  ///
  /// [messageId] 要撤回的消息ID
  Future<void> revokeMessage(String messageId);

  // ===== 会话管理 =====

  /// 获取会话列表
  Future<List<Map<String, dynamic>>> getSessionList();

  /// 获取会话消息列表
  Future<List<Map<String, dynamic>>> getSessionMessages(String sessionUuid);

  /// 创建新会话
  ///
  /// 返回新会话的UUID
  Future<String> createSession();

  /// 切换会话
  Future<void> switchSession(String sessionUuid);

  /// 清空当前会话消息
  Future<void> clearCurrentSession();

  // ===== 上下文管理 =====

  /// 设置上下文
  Future<void> setContext(Map<String, dynamic> contextData);

  /// 清除上下文
  Future<void> clearContext();

  /// 获取当前上下文
  Map<String, dynamic>? getCurrentContext();

  // ===== 模型管理 =====

  /// 切换 AI 模型
  Future<void> setProvider(Map<String, dynamic> providerConfig);

  /// 获取当前模型配置
  Map<String, dynamic>? getProviderConfig();

  // ===== 项目管理 =====

  /// 绑定项目
  Future<void> setProject(Map<String, dynamic>? projectData);

  /// 获取当前项目UUID
  String? getCurrentProjectUuid();

  // ===== 工具管理 =====

  /// 注册单个工具
  void registerTool(AgentTool tool);

  /// 批量注册工具
  void registerTools(List<AgentTool> tools);

  /// 注销工具
  void unregisterTool(String name);

  /// 获取已注册工具列表（JSON 序列化）
  List<Map<String, dynamic>> getRegisteredTools();

  // ===== 权限管理 =====

  /// 响应权限请求
  ///
  /// [requestId] 权限请求ID
  /// [decision] 用户的权限决策
  Future<void> respondToPermission(
    String requestId,
    PermissionDecision decision,
  );

  /// 获取当前权限请求（如果有）
  ///
  /// Agent 处于 waitingPermission 状态时返回权限请求信息
  AgentPermissionRequest? getPendingPermissionRequest();

  // ===== 状态查询 =====

  /// 获取状态快照
  AgentStateSnapshot getStateSnapshot();

  /// 状态变更通知流
  Stream<AgentStateSnapshot> get onStateChanged;

  /// 通用事件流（用于 RPC 流式广播）
  Stream<Map<String, dynamic>> get onEvent;

  /// 是否正在发送
  bool get isSending;

  /// 是否正在流式输出
  bool get isStreaming;

  /// 当前处理中的消息ID
  String? get currentProcessingMessageId;

  /// 排队中的消息ID列表
  List<String> get queuedMessageIds;

  /// 消息队列长度
  int get queueLength;

  /// 最后活跃时间
  DateTime get lastActiveTime;
}
