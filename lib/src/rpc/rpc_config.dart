/// RPC 配置常量
class RpcConfig {
  // ===== 超时配置 =====

  /// 默认超时时间（30秒）
  static const int defaultTimeout = 30000;

  /// 流式超时时间（60秒）
  static const int streamTimeout = 60000;

  // ===== Host 级别方法 =====

  /// 查询在线设备列表
  static const String methodGetOnlineDevices = 'getOnlineDevices';

  /// 查询指定设备的详细信息
  static const String methodGetDeviceInfo = 'getDeviceInfo';

  // ===== Agent 生命周期方法 =====

  /// 创建或获取 Agent
  static const String methodGetOrCreateAgent = 'agentGetOrCreate';

  /// 获取员工列表
  static const String methodGetEmployeeList = 'agentGetEmployeeList';

  /// 获取活跃 Agent 摘要
  static const String methodGetActiveSummaries = 'agentGetActiveSummaries';

  /// 获取内存统计
  static const String methodGetMemoryStats = 'agentGetMemoryStats';

  // ===== Agent 对话操作 =====

  /// 发送消息
  static const String methodSendMessage = 'agentSendMessage';

  /// 中断当前处理
  static const String methodInterrupt = 'agentInterrupt';

  /// 撤回消息
  static const String methodRevokeMessage = 'agentRevokeMessage';

  // ===== Agent 会话管理 =====

  /// 获取会话列表
  static const String methodGetSessionList = 'agentGetSessionList';

  /// 获取会话消息
  static const String methodGetSessionMessages = 'agentGetSessionMessages';

  /// 创建新会话
  static const String methodCreateSession = 'agentCreateSession';

  /// 切换会话
  static const String methodSwitchSession = 'agentSwitchSession';

  /// 清空当前会话
  static const String methodClearSession = 'agentClearSession';

  // ===== Agent 状态查询 =====

  /// 获取状态快照
  static const String methodGetState = 'agentGetState';

  /// 订阅状态变更流
  static const String methodSubscribeState = 'agentSubscribeState';

  /// Ping 检测在线状态
  static const String methodPing = 'agentPing';

  // ===== Agent 权限管理 =====

  /// 获取待处理的权限请求
  static const String methodGetPendingPermission = 'agentGetPendingPermission';

  /// 处理权限决策
  static const String methodHandlePermission = 'agentHandlePermission';

  // ===== Agent 上下文管理 =====

  /// 设置上下文
  static const String methodSetContext = 'agentSetContext';

  /// 清除上下文
  static const String methodClearContext = 'agentClearContext';

  /// 获取当前上下文
  static const String methodGetContext = 'agentGetContext';

  // ===== Agent 模型管理 =====

  /// 设置 Provider
  static const String methodSetProvider = 'agentSetProvider';

  /// 获取 Provider 配置
  static const String methodGetProvider = 'agentGetProvider';

  // ===== Agent 项目管理 =====

  /// 设置项目
  static const String methodSetProject = 'agentSetProject';

  /// 获取当前项目UUID
  static const String methodGetProjectUuid = 'agentGetProjectUuid';

  // ===== 错误码 =====

  /// 成功
  static const int errorCodeSuccess = 0;

  /// Agent 不存在
  static const int errorCodeAgentNotFound = 3001;

  /// 会话不存在
  static const int errorCodeSessionNotFound = 3002;

  /// Agent 已销毁
  static const int errorCodeAgentDisposed = 3003;

  /// 消息队列已满
  static const int errorCodeQueueFull = 3004;

  /// 权限请求不存在
  static const int errorCodePermissionNotFound = 3005;

  /// 参数错误
  static const int errorCodeInvalidParams = 3006;

  /// 方法未注册
  static const int errorCodeMethodNotRegistered = 2001;

  /// 设备未找到
  static const int errorCodeDeviceNotFound = 2003;

  /// 内部错误
  static const int errorCodeInternalError = 1999;
}
