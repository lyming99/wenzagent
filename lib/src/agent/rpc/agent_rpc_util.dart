import '../entity/entity.dart';
import 'agent_rpc_config.dart';

/// Agent RPC 调用工具类
///
/// 提供统一的RPC调用封装，所有参数都使用entity封装
class AgentRpcUtil {
  /// RPC 调用回调
  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic> params,
  ) _rpcCall;

  AgentRpcUtil(this._rpcCall);

  // ===== Agent 对话操作 =====

  /// 发送消息
  Future<Map<String, dynamic>> sendMessage(SendMessageRequest request) async {
    return _rpcCall(AgentRpcConfig.methodSendMessage, request.toMap());
  }

  /// 中断当前处理
  Future<Map<String, dynamic>> interrupt(InterruptRequest request) async {
    return _rpcCall(AgentRpcConfig.methodInterrupt, request.toMap());
  }

  /// 撤回消息
  Future<Map<String, dynamic>> revokeMessage(RevokeMessageRequest request) async {
    return _rpcCall(AgentRpcConfig.methodRevokeMessage, request.toMap());
  }

  // ===== Agent 会话管理 =====

  /// 获取会话消息
  Future<Map<String, dynamic>> getSessionMessages(
    GetSessionMessagesRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetSessionMessages, request.toMap());
  }

  /// 根据用户消息计数获取会话消息
  Future<Map<String, dynamic>> getSessionMessagesByUserCount(
    GetSessionMessagesByUserCountRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetSessionMessagesByUserCount, request.toMap());
  }

  /// 分页获取会话消息
  Future<Map<String, dynamic>> getSessionMessagesPaged(
    GetSessionMessagesPagedRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetSessionMessagesPaged, request.toMap());
  }

  /// 获取未接收消息
  Future<Map<String, dynamic>> getUnreceivedMessages(
    GetUnreceivedMessagesRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetUnreceivedMessages, request.toMap());
  }

  /// 标记消息为已接收
  Future<Map<String, dynamic>> markMessagesAsReceived(
    MarkMessagesAsReceivedRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodMarkMessagesAsReceived, request.toMap());
  }

  /// 增量拉取消息（基于 LSN）
  Future<Map<String, dynamic>> getMessagesAfterSeq(
    GetMessagesAfterSeqRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetMessagesAfterSeq, request.toMap());
  }

  /// 更新同步水位线
  Future<Map<String, dynamic>> updateSyncWatermark(
    UpdateSyncWatermarkRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodUpdateSyncWatermark, request.toMap());
  }

  /// 获取最大 seq
  Future<Map<String, dynamic>> getMaxSeq(
    GetSessionMessagesRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetMaxSeq, request.toMap());
  }

  /// 获取最小 seq
  Future<Map<String, dynamic>> getMinSeq(
    GetMinSeqRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetMinSeq, request.toMap());
  }

  /// 获取清空水位线
  Future<Map<String, dynamic>> getClearSeq(
    GetClearSeqRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetClearSeq, request.toMap());
  }

  /// 标记消息为已读
  Future<Map<String, dynamic>> markMessagesAsRead(
    MarkMessagesAsReadRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodMarkMessagesAsRead, request.toMap());
  }

  /// 基于 seq 批量标记消息为已读
  Future<Map<String, dynamic>> markMessagesAsReadBySeq(
    MarkMessagesAsReadBySeqRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodMarkMessagesAsReadBySeq, request.toMap());
  }

  /// 查询消息已读状态
  Future<Map<String, dynamic>> getMessagesReadStatus(
    GetMessagesReadStatusRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetMessagesReadStatus, request.toMap());
  }

  /// 获取会话摘要（未读计数 + 最新消息）
  Future<Map<String, dynamic>> getSessionSummary(
    GetSessionSummaryRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetSessionSummary, request.toMap());
  }

  /// 清空当前会话
  Future<Map<String, dynamic>> clearSession(ClearSessionRequest request) async {
    return _rpcCall(AgentRpcConfig.methodClearSession, request.toMap());
  }

  // ===== Agent 上下文管理 =====

  /// 设置上下文
  Future<Map<String, dynamic>> setContext(SetContextRequest request) async {
    return _rpcCall(AgentRpcConfig.methodSetContext, request.toMap());
  }

  // ===== Agent 模型管理 =====

  /// 设置提供者
  Future<Map<String, dynamic>> setProvider(SetProviderRequest request) async {
    return _rpcCall(AgentRpcConfig.methodSetProvider, request.toMap());
  }

  /// 获取提供者配置
  Future<Map<String, dynamic>> getProvider(GetProviderRequest request) async {
    return _rpcCall(AgentRpcConfig.methodGetProvider, request.toMap());
  }

  // ===== Agent 技能管理 =====

  /// 设置技能配置
  Future<Map<String, dynamic>> setSkills(SetSkillsRequest request) async {
    return _rpcCall(AgentRpcConfig.methodSetSkills, request.toMap());
  }

  /// 获取技能配置
  Future<Map<String, dynamic>> getSkills(AgentGetSkillsRequest request) async {
    return _rpcCall(AgentRpcConfig.methodGetSkills, request.toMap());
  }

  // ===== Agent MCP 管理 =====

  /// 设置 MCP 配置
  Future<Map<String, dynamic>> setMcpConfigs(SetMcpConfigsRequest request) async {
    return _rpcCall(AgentRpcConfig.methodSetMcpConfigs, request.toMap());
  }

  /// 获取 MCP 配置
  Future<Map<String, dynamic>> getMcpConfigs(GetMcpConfigsRequest request) async {
    return _rpcCall(AgentRpcConfig.methodGetMcpConfigs, request.toMap());
  }

  // ===== Agent 项目管理 =====

  /// 设置项目
  Future<Map<String, dynamic>> setProject(SetProjectRequest request) async {
    return _rpcCall(AgentRpcConfig.methodSetProject, request.toMap());
  }

  /// 获取当前项目UUID
  Future<Map<String, dynamic>> getProjectUuid(GetProjectUuidRequest request) async {
    return _rpcCall(AgentRpcConfig.methodGetProjectUuid, request.toMap());
  }

  /// 检查路径是否存在
  Future<Map<String, dynamic>> checkPathExists(CheckPathExistsRequest request) async {
    return _rpcCall(AgentRpcConfig.methodCheckPathExists, request.toMap());
  }

  /// 列出目录内容
  Future<Map<String, dynamic>> listDirectory(ListDirectoryRequest request) async {
    return _rpcCall(AgentRpcConfig.methodListDirectory, request.toMap());
  }

  /// 获取文件/目录信息
  Future<Map<String, dynamic>> getFileInfo(GetFileInfoRequest request) async {
    return _rpcCall(AgentRpcConfig.methodGetFileInfo, request.toMap());
  }

  /// 创建目录
  Future<Map<String, dynamic>> createDirectory(CreateDirectoryRequest request) async {
    return _rpcCall(AgentRpcConfig.methodCreateDirectory, request.toMap());
  }

  /// 删除文件/目录
  Future<Map<String, dynamic>> deleteFile(DeleteFileRequest request) async {
    return _rpcCall(AgentRpcConfig.methodDeleteFile, request.toMap());
  }

  /// 重命名/移动文件
  Future<Map<String, dynamic>> renameFile(RenameFileRequest request) async {
    return _rpcCall(AgentRpcConfig.methodRenameFile, request.toMap());
  }

  // ===== Agent 权限管理 =====

  /// 响应权限请求
  Future<Map<String, dynamic>> respondPermission(
    RespondPermissionRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodRespondPermission, request.toMap());
  }

  /// 获取待处理权限请求
  Future<Map<String, dynamic>> getPendingPermission(
    GetPendingPermissionRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetPendingPermission, request.toMap());
  }

  // ===== Agent 状态查询 =====

  /// 获取状态快照
  Future<Map<String, dynamic>> getState(GetStateRequest request) async {
    return _rpcCall(AgentRpcConfig.methodGetState, request.toMap());
  }

  /// 获取正在调用的工具 callId 列表
  Future<Map<String, dynamic>> getCallingToolIds(
    GetCallingToolIdsRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetCallingToolIds, request.toMap());
  }

  // ===== Agent Todo 管理 =====

  /// 获取活跃 todo 项
  Future<Map<String, dynamic>> getActiveTodos(
    GetActiveTodosRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetActiveTodos, request.toMap());
  }

  /// 获取已完成 todo 项
  Future<Map<String, dynamic>> getCompletedTodos(
    GetCompletedTodosRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetCompletedTodos, request.toMap());
  }

  /// 获取 todo 分组
  Future<Map<String, dynamic>> getTodoGroups(
    GetTodoGroupsRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetTodoGroups, request.toMap());
  }

  /// 获取 todo 统计
  Future<Map<String, dynamic>> getTodoStats(
    GetTodoStatsRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetTodoStats, request.toMap());
  }

  // ===== Agent Todo 写操作 =====

  /// 更新 todo 状态
  Future<Map<String, dynamic>> updateTodoStatus(
    UpdateTodoStatusRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodUpdateTodoStatus, request.toMap());
  }

  /// 更新 todo 内容
  Future<Map<String, dynamic>> updateTodoContent(
    UpdateTodoContentRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodUpdateTodoContent, request.toMap());
  }

  /// 删除 todo
  Future<Map<String, dynamic>> deleteTodo(
    DeleteTodoRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodDeleteTodo, request.toMap());
  }

  /// 清除已完成 todo
  Future<Map<String, dynamic>> clearCompletedTodos(
    ClearCompletedTodosRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodClearCompletedTodos, request.toMap());
  }

  /// 移动 todo 到分组
  Future<Map<String, dynamic>> moveTodoToGroup(
    MoveTodoToGroupRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodMoveTodoToGroup, request.toMap());
  }
}
