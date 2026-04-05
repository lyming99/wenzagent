/// Agent RPC 方法常量
class AgentRpcConfig {
  // ===== 超时配置 =====

  /// 默认超时时间（30秒）
  static const int defaultTimeout = 30000;

  /// 流式超时时间（120秒）
  static const int streamTimeout = 120000;

  // ===== Agent 对话操作 =====

  static const String methodSendMessage = 'agentSendMessage';
  static const String methodInterrupt = 'agentInterrupt';
  static const String methodRevokeMessage = 'agentRevokeMessage';

  // ===== Agent 会话管理 =====

  static const String methodGetSessionList = 'agentGetSessionList';
  static const String methodGetSessionMessages = 'agentGetSessionMessages';
  static const String methodCreateSession = 'agentCreateSession';
  static const String methodSwitchSession = 'agentSwitchSession';
  static const String methodClearSession = 'agentClearSession';

  // ===== Agent 上下文管理 =====

  static const String methodSetContext = 'agentSetContext';
  static const String methodClearContext = 'agentClearContext';
  static const String methodGetContext = 'agentGetContext';

  // ===== Agent 模型管理 =====

  static const String methodSetProvider = 'agentSetProvider';
  static const String methodGetProvider = 'agentGetProvider';

  // ===== Agent 项目管理 =====

  static const String methodSetProject = 'agentSetProject';
  static const String methodGetProjectUuid = 'agentGetProjectUuid';

  // ===== Agent 工具管理 =====

  static const String methodGetRegisteredTools = 'agentGetRegisteredTools';

  // ===== Agent 权限管理 =====

  static const String methodRespondPermission = 'agentRespondPermission';
  static const String methodGetPendingPermission = 'agentGetPendingPermission';

  // ===== Agent 状态查询 =====

  static const String methodGetState = 'agentGetState';
  static const String methodSubscribeState = 'agentSubscribeState';

  // ===== Agent 生命周期 =====

  static const String methodPing = 'agentPing';
  static const String methodGetOrCreateAgent = 'agentGetOrCreate';
  static const String methodGetEmployeeList = 'agentGetEmployeeList';
  static const String methodGetActiveSummaries = 'agentGetActiveSummaries';
  static const String methodGetMemoryStats = 'agentGetMemoryStats';

  // ===== 错误码 =====

  static const int errorSuccess = 0;
  static const int errorAgentNotFound = 3001;
  static const int errorSessionNotFound = 3002;
  static const int errorAgentDisposed = 3003;
  static const int errorQueueFull = 3004;
  static const int errorPermissionNotFound = 3005;
  static const int errorInvalidParams = 3006;
  static const int errorInternal = 3999;
}
