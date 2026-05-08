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
  static const String methodGetSessionMessagesByUserCount = 'agentGetSessionMessagesByUserCount';
  static const String methodGetSessionMessagesPaged = 'agentGetSessionMessagesPaged';
  static const String methodGetUnreceivedMessages = 'agentGetUnreceivedMessages';
  static const String methodMarkMessagesAsReceived = 'agentMarkMessagesAsReceived';
  static const String methodGetMessagesAfterSeq = 'agentGetMessagesAfterSeq';
  static const String methodUpdateSyncWatermark = 'agentUpdateSyncWatermark';
  static const String methodGetMaxSeq = 'agentGetMaxSeq';
  static const String methodGetMinSeq = 'agentGetMinSeq';
  static const String methodGetClearSeq = 'agentGetClearSeq';
  static const String methodClearClearSeq = 'agentClearClearSeq';
  static const String methodMarkMessagesAsRead = 'agentMarkMessagesAsRead';
  static const String methodMarkAllMessagesAsRead = 'agentMarkAllMessagesAsRead';
  static const String methodMarkMessagesAsReadBySeq = 'agentMarkMessagesAsReadBySeq';
  static const String methodGetMessagesReadStatus = 'agentGetMessagesReadStatus';
  static const String methodGetSessionSummary = 'agentGetSessionSummary';
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
  static const String methodCheckPathExists = 'agentCheckPathExists';

  // ===== Agent 文件操作 =====

  static const String methodListDirectory = 'agentListDirectory';
  static const String methodGetFileInfo = 'agentGetFileInfo';
  static const String methodCreateDirectory = 'agentCreateDirectory';
  static const String methodDeleteFile = 'agentDeleteFile';
  static const String methodRenameFile = 'agentRenameFile';

  // ===== Agent 远程文件读写 =====

  static const String methodReadFile = 'agentReadFile';
  static const String methodWriteFile = 'agentWriteFile';
  static const String methodDownloadFile = 'agentDownloadFile';
  static const String methodUploadFile = 'agentUploadFile';

  /// 流式读取文件（用于大文件下载，通过二进制 WebSocket 传输）
  static const String methodReadFileStream = 'agentReadFileStream';

  // ===== Agent 技能管理 =====

  static const String methodSetSkills = 'agentSetSkills';
  static const String methodGetSkills = 'agentGetSkills';

  // ===== Agent MCP 管理 =====

  static const String methodSetMcpConfigs = 'agentSetMcpConfigs';
  static const String methodGetMcpConfigs = 'agentGetMcpConfigs';

  // ===== Agent 工具管理 =====

  static const String methodGetRegisteredTools = 'agentGetRegisteredTools';

  // ===== Agent 权限管理 =====

  static const String methodRespondPermission = 'agentRespondPermission';
  static const String methodGetPendingPermission = 'agentGetPendingPermission';

  // ===== Agent 确认管理 =====

  static const String methodRespondConfirm = 'agentRespondConfirm';
  static const String methodGetPendingConfirm = 'agentGetPendingConfirm';

  // ===== Agent 状态查询 =====

  static const String methodGetState = 'agentGetState';
  static const String methodGetCallingToolIds = 'agentGetCallingToolIds';
  static const String methodSubscribeState = 'agentSubscribeState';
  static const String methodGetTokenUsage = 'agentGetTokenUsage';

  // ===== Agent Todo Topic 管理 =====

  static const String methodGetCurrentTopics = 'agentGetCurrentTopics';
  static const String methodGetPendingTopics = 'agentGetPendingTopics';
  static const String methodGetAllTopics = 'agentGetAllTopics';
  static const String methodGetCompletedTopics = 'agentGetCompletedTopics';
  static const String methodGetTodoStats = 'agentGetTodoStats';

  // ===== Agent Todo 写操作 =====

  static const String methodUpdateTopicContent = 'agentUpdateTopicContent';
  static const String methodDeleteTopic = 'agentDeleteTopic';
  static const String methodUpdateTopicStatus = 'agentUpdateTopicStatus';
  static const String methodReorderTopics = 'agentReorderTopics';
  static const String methodClearCompletedTopics = 'agentClearCompletedTopics';

  // ===== Agent Todo TaskItem 管理 =====

  static const String methodGetTaskItemsByTopic = 'agentGetTaskItemsByTopic';
  static const String methodUpdateTaskItemStatus = 'agentUpdateTaskItemStatus';
  static const String methodUpdateTaskItemContent = 'agentUpdateTaskItemContent';
  static const String methodDeleteTaskItem = 'agentDeleteTaskItem';
  static const String methodReorderTaskItems = 'agentReorderTaskItems';

  // ===== Agent Spec 管理 =====

  static const String methodGetActiveSpecs = 'agentGetActiveSpecs';
  static const String methodGetCompletedSpecs = 'agentGetCompletedSpecs';
  static const String methodGetSpecStats = 'agentGetSpecStats';

  // ===== Agent Spec 写操作 =====

  static const String methodUpdateSpecStatus = 'agentUpdateSpecStatus';
  static const String methodUpdateSpecContent = 'agentUpdateSpecContent';
  static const String methodDeleteSpec = 'agentDeleteSpec';
  static const String methodClearCompletedSpecs = 'agentClearCompletedSpecs';
  static const String methodReorderSpecs = 'agentReorderSpecs';

  // ===== Agent 文件操作追踪 =====

  static const String methodGetFileOperations = 'agentGetFileOperations';
  static const String methodGetFileOperationsByMessage = 'agentGetFileOperationsByMessage';
  static const String methodClearFileOperations = 'agentClearFileOperations';

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
