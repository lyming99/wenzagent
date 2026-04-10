import 'dart:async';

import 'agent_state.dart';
import 'entity/entity.dart';
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
  String get employeeId;

  /// 当前状态
  AgentStatus get status;

  /// 是否存活（未销毁）
  bool get isAlive;

  // ===== 生命周期 =====

  /// 初始化 Agent
  ///
  /// [employeeId] 指定员工ID，为 null 则查找或创建新会话
  /// [enableBuiltinTools] 是否注册内置工具
  /// [enableSkills] 是否初始化技能系统（当前由 [warmup] 统一加载）
  ///
  /// 仅加载最近 10 条消息用于快速显示，完整历史由 [warmup] 后台加载。
  Future<void> initialize(
      {String? employeeId, bool enableBuiltinTools = true, bool enableSkills = true,});

  /// 延迟加载完整历史消息和技能系统
  ///
  /// 在 [initialize] 之后后台调用，执行：
  /// - 从数据库加载全部历史消息（替换 initialize 中的最近 10 条）
  /// - 初始化技能系统（MCP / 持久化技能 / 文件夹技能）
  ///
  /// 加载期间 [sendMessage] 会自动排队等待，确保 LLM 拥有完整上下文。
  /// 双重锁：重复调用直接复用首次 Future。
  Future<void> warmup();

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
  /// [input] 消息输入数据，必须包含:
  ///   - `content` (String): 消息内容
  ///   - `employeeId` (String?): 目标会话UUID，为 null 使用当前会话
  ///
  /// 返回消息ID
  Future<String> sendMessage(MessageInput input);

  /// 发送消息（从 Map 创建，向后兼容）
  ///
  /// [messageData] 消息数据 Map
  @Deprecated('Use sendMessage(MessageInput) instead')
  Future<String> sendMessageFromMap(Map<String, dynamic> messageData) {
    return sendMessage(MessageInput.fromMap(messageData));
  }

  /// 中断当前处理
  Future<void> interrupt();

  /// 撤回消息
  ///
  /// [messageId] 要撤回的消息ID
  Future<void> revokeMessage(String messageId);

  // ===== 会话管理 =====

  /// 获取会话消息列表
  ///
  /// 返回当前 Agent 的会话消息列表
  Future<List<AgentMessage>> getSessionMessages();

  /// 根据用户消息计数获取会话消息列表
  ///
  /// 统计用户发送的消息数（role='user'），达到 [userMessageLimit] 条时停止，
  /// 返回该时间段内的所有消息（包括user和assistant）
  ///
  /// [userMessageLimit] 用户消息数量限制，默认20条
  Future<List<AgentMessage>> getSessionMessagesByUserCount({
    int userMessageLimit = 20,
  });

  /// 分页获取会话消息列表
  ///
  /// [pageSize] 每页数量，默认20条
  /// [offset] 偏移量，默认0
  Future<List<AgentMessage>> getSessionMessagesPaged({
    int pageSize = 20,
    int offset = 0,
  });

  /// 获取未接收消息列表
  ///
  /// 查询指定设备的未接收消息（本机deviceId，而非proxy的deviceId）
  ///
  /// [receiverDeviceId] 接收设备的ID（本机设备ID）
  Future<List<AgentMessage>> getUnreceivedMessages({
    required String receiverDeviceId,
  });

  /// 标记消息为已接收
  ///
  /// 更新消息接收状态到服务端，后续查询不会返回已接收消息（除非状态更新）
  ///
  /// [receiverDeviceId] 接收设备的ID（本机设备ID）
  /// [messageReceiveList] 消息接收列表（包含消息ID和更新时间）
  Future<void> markMessagesAsReceived({
    required String receiverDeviceId,
    required List<MessageReceiveInfo> messageReceiveList,
  });

  /// 标记消息为已读
  ///
  /// 当用户打开会话查看消息时，设备通过此方法通知 Agent 消息已读
  /// Agent 记录已读状态后广播给所有设备
  ///
  /// [readerDeviceId] 已读设备ID
  /// [employeeId] 员工ID
  /// [messageIds] 指定消息ID列表，为 null 则标记该员工所有消息
  Future<void> markMessagesAsRead({
    required String readerDeviceId,
    required String employeeId,
    List<String>? messageIds,
  });

  /// 查询消息已读状态
  ///
  /// 设备重新打开时可通过此方法从 Agent 查询哪些消息已读
  ///
  /// [deviceId] 查询设备ID
  /// [employeeId] 员工ID
  Future<Map<String, dynamic>> getMessagesReadStatus({
    required String deviceId,
    required String employeeId,
  });

  /// 获取会话消息列表（返回 Map，向后兼容）
  @Deprecated('Use getSessionMessages() instead')
  Future<List<Map<String, dynamic>>> getSessionMessagesAsMap() async {
    final messages = await getSessionMessages();
    return messages.map((m) => m.toMap()).toList();
  }

  /// 清空当前会话消息
  Future<void> clearCurrentSession();

  /// 从内存中删除指定消息
  ///
  /// 仅从内存中删除消息，不影响数据库
  Future<void> removeMessageFromMemory(String messageId);

  // ===== 上下文管理 =====

  /// 设置上下文
  Future<void> setContext(Map<String, dynamic> contextData);

  /// 清除上下文
  Future<void> clearContext();

  /// 获取当前上下文
  Map<String, dynamic>? getCurrentContext();

  // ===== 模型管理 =====

  /// 切换 AI 模型
  Future<void> setProvider(ProviderConfig providerConfig);

  /// 获取当前模型配置
  ProviderConfig? getProviderConfig();

  // ===== 技能管理 =====

  /// 设置技能配置
  ///
  /// 同步技能实体列表，更新持久化并重载运行时。
  /// [skillMaps] 技能实体的序列化 Map 列表
  Future<void> setSkills(List<Map<String, dynamic>> skillMaps);

  /// 获取当前技能配置
  ///
  /// 返回技能实体的序列化 Map 列表
  List<Map<String, dynamic>> getSkillsConfig();

  // ===== MCP 管理 =====

  /// 设置 MCP 服务器配置
  ///
  /// 同步 MCP 服务器配置列表，更新持久化并重载 MCP 技能。
  /// [mcpConfigMaps] MCP 服务器配置的序列化 Map 列表
  Future<void> setMcpConfigs(List<Map<String, dynamic>> mcpConfigMaps);

  /// 获取当前 MCP 服务器配置
  ///
  /// 返回 MCP 服务器配置的序列化 Map 列表
  List<Map<String, dynamic>> getMcpConfigs();

  // ===== 项目管理 =====

  /// 绑定项目
  Future<void> setProject(ProjectData? projectData);

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
  /// [scope] 授权范围（默认仅本次），决定是否持久化授权规则：
  ///   - [PermissionApprovalScope.once] 仅本次允许
  ///   - [PermissionApprovalScope.exact] 持久化精确匹配规则
  ///   - [PermissionApprovalScope.pattern] 持久化正则模式规则
  ///   - [PermissionApprovalScope.all] 该权限类型全部允许
  Future<void> respondToPermission(
    String requestId,
    PermissionDecision decision, {
    PermissionApprovalScope scope = PermissionApprovalScope.once,
  });

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
