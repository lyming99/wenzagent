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

  /// 标记消息为已读
  Future<Map<String, dynamic>> markMessagesAsRead(
    MarkMessagesAsReadRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodMarkMessagesAsRead, request.toMap());
  }

  /// 查询消息已读状态
  Future<Map<String, dynamic>> getMessagesReadStatus(
    GetMessagesReadStatusRequest request,
  ) async {
    return _rpcCall(AgentRpcConfig.methodGetMessagesReadStatus, request.toMap());
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

  // ===== Agent 项目管理 =====

  /// 设置项目
  Future<Map<String, dynamic>> setProject(SetProjectRequest request) async {
    return _rpcCall(AgentRpcConfig.methodSetProject, request.toMap());
  }

  /// 获取当前项目UUID
  Future<Map<String, dynamic>> getProjectUuid(GetProjectUuidRequest request) async {
    return _rpcCall(AgentRpcConfig.methodGetProjectUuid, request.toMap());
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
}
