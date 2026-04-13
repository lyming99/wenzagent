/// RPC 请求参数实体类
///
/// 撤回消息请求
class RevokeMessageRequest {
  final String employeeId;
  final String messageId;

  const RevokeMessageRequest({
    required this.employeeId,
    required this.messageId,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'messageId': messageId,
    };
  }

  factory RevokeMessageRequest.fromMap(Map<String, dynamic> map) {
    return RevokeMessageRequest(
      employeeId: map['employeeId'] as String,
      messageId: map['messageId'] as String,
    );
  }
}

/// 发送消息请求
class SendMessageRequest {
  final String employeeId;
  final Map<String, dynamic> messageData;

  const SendMessageRequest({
    required this.employeeId,
    required this.messageData,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'messageData': messageData,
    };
  }

  factory SendMessageRequest.fromMap(Map<String, dynamic> map) {
    return SendMessageRequest(
      employeeId: map['employeeId'] as String,
      messageData: map['messageData'] as Map<String, dynamic>,
    );
  }
}

/// 中断请求
class InterruptRequest {
  final String employeeId;

  const InterruptRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory InterruptRequest.fromMap(Map<String, dynamic> map) {
    return InterruptRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 获取待处理权限请求
class GetPendingPermissionRequest {
  final String employeeId;

  const GetPendingPermissionRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetPendingPermissionRequest.fromMap(Map<String, dynamic> map) {
    return GetPendingPermissionRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 获取会话消息请求
class GetSessionMessagesRequest {
  final String employeeId;

  const GetSessionMessagesRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetSessionMessagesRequest.fromMap(Map<String, dynamic> map) {
    return GetSessionMessagesRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 根据用户消息计数获取会话消息请求
///
/// 统计用户发送的消息数（role='user'），达到 [userMessageLimit] 条时停止，
/// 返回该时间段内的所有消息（包括user和assistant）
class GetSessionMessagesByUserCountRequest {
  final String employeeId;

  /// 用户消息数量限制（默认20条）
  final int userMessageLimit;

  const GetSessionMessagesByUserCountRequest({
    required this.employeeId,
    this.userMessageLimit = 20,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'userMessageLimit': userMessageLimit,
    };
  }

  factory GetSessionMessagesByUserCountRequest.fromMap(Map<String, dynamic> map) {
    return GetSessionMessagesByUserCountRequest(
      employeeId: map['employeeId'] as String,
      userMessageLimit: map['userMessageLimit'] as int? ?? 20,
    );
  }
}

/// 获取未接收消息请求
///
/// 查询指定设备的未接收消息（本机deviceId，而非proxy的deviceId）
class GetUnreceivedMessagesRequest {
  final String employeeId;

  /// 接收设备的ID（本机设备ID）
  final String receiverDeviceId;

  /// 偏移量（跳过的消息数），默认0
  final int offset;

  /// 每批数量限制，默认20条
  final int limit;

  const GetUnreceivedMessagesRequest({
    required this.employeeId,
    required this.receiverDeviceId,
    this.offset = 0,
    this.limit = 20,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'receiverDeviceId': receiverDeviceId,
      'offset': offset,
      'limit': limit,
    };
  }

  factory GetUnreceivedMessagesRequest.fromMap(Map<String, dynamic> map) {
    return GetUnreceivedMessagesRequest(
      employeeId: map['employeeId'] as String,
      receiverDeviceId: map['receiverDeviceId'] as String,
      offset: map['offset'] as int? ?? 0,
      limit: map['limit'] as int? ?? 20,
    );
  }
}

/// 标记消息为已接收请求
///
/// 更新消息接收状态到服务端，后续查询不会返回已接收消息（除非状态更新）
class MarkMessagesAsReceivedRequest {
  final String employeeId;

  /// 接收设备的ID（本机设备ID）
  final String receiverDeviceId;

  /// 消息接收列表（包含消息ID和更新时间）
  final List<MessageReceiveInfo> messageReceiveList;

  const MarkMessagesAsReceivedRequest({
    required this.employeeId,
    required this.receiverDeviceId,
    required this.messageReceiveList,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'receiverDeviceId': receiverDeviceId,
      'messageReceiveList': messageReceiveList.map((m) => m.toMap()).toList(),
    };
  }

  factory MarkMessagesAsReceivedRequest.fromMap(Map<String, dynamic> map) {
    return MarkMessagesAsReceivedRequest(
      employeeId: map['employeeId'] as String,
      receiverDeviceId: map['receiverDeviceId'] as String,
      messageReceiveList: (map['messageReceiveList'] as List)
          .map((m) => MessageReceiveInfo.fromMap(m as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 消息接收信息
class MessageReceiveInfo {
  final String messageId;
  final DateTime updateTime;

  const MessageReceiveInfo({
    required this.messageId,
    required this.updateTime,
  });

  Map<String, dynamic> toMap() {
    return {
      'messageId': messageId,
      'updateTime': updateTime.toIso8601String(),
    };
  }

  factory MessageReceiveInfo.fromMap(Map<String, dynamic> map) {
    return MessageReceiveInfo(
      messageId: map['messageId'] as String,
      updateTime: DateTime.parse(map['updateTime'] as String),
    );
  }
}

/// 增量拉取消息请求（基于 LSN）
///
/// 客户端通过 lastSeq 获取 seq > lastSeq 的消息
class GetMessagesAfterSeqRequest {
  final String employeeId;

  /// 客户端已同步到的最大 seq
  final int lastSeq;

  /// 每批数量限制，默认20条
  final int limit;

  const GetMessagesAfterSeqRequest({
    required this.employeeId,
    this.lastSeq = 0,
    this.limit = 20,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'lastSeq': lastSeq,
      'limit': limit,
    };
  }

  factory GetMessagesAfterSeqRequest.fromMap(Map<String, dynamic> map) {
    return GetMessagesAfterSeqRequest(
      employeeId: map['employeeId'] as String,
      lastSeq: map['lastSeq'] as int? ?? 0,
      limit: map['limit'] as int? ?? 20,
    );
  }
}

/// 获取最小 seq 请求
///
/// 客户端查询远程最早保留消息的 seq，
/// 用于清理本地过期消息（seq < minSeq 的可以安全删除）
class GetMinSeqRequest {
  final String employeeId;

  const GetMinSeqRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetMinSeqRequest.fromMap(Map<String, dynamic> map) {
    return GetMinSeqRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 更新同步水位线请求
///
/// 客户端同步完成后更新本地水位线
class UpdateSyncWatermarkRequest {
  final String employeeId;

  /// 已同步到的最大 seq
  final int lastSeq;

  const UpdateSyncWatermarkRequest({
    required this.employeeId,
    required this.lastSeq,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'lastSeq': lastSeq,
    };
  }

  factory UpdateSyncWatermarkRequest.fromMap(Map<String, dynamic> map) {
    return UpdateSyncWatermarkRequest(
      employeeId: map['employeeId'] as String,
      lastSeq: map['lastSeq'] as int,
    );
  }
}

/// 分页获取会话消息请求
class GetSessionMessagesPagedRequest {
  final String employeeId;

  /// 每页数量
  final int pageSize;

  /// 偏移量（跳过的消息数）
  final int offset;

  const GetSessionMessagesPagedRequest({
    required this.employeeId,
    this.pageSize = 20,
    this.offset = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'pageSize': pageSize,
      'offset': offset,
    };
  }

  factory GetSessionMessagesPagedRequest.fromMap(Map<String, dynamic> map) {
    return GetSessionMessagesPagedRequest(
      employeeId: map['employeeId'] as String,
      pageSize: map['pageSize'] as int? ?? 20,
      offset: map['offset'] as int? ?? 0,
    );
  }
}

/// 清空会话请求
class ClearSessionRequest {
  final String employeeId;

  const ClearSessionRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory ClearSessionRequest.fromMap(Map<String, dynamic> map) {
    return ClearSessionRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 设置上下文请求
class SetContextRequest {
  final String employeeId;
  final Map<String, dynamic> contextData;

  const SetContextRequest({
    required this.employeeId,
    required this.contextData,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'contextData': contextData,
    };
  }

  factory SetContextRequest.fromMap(Map<String, dynamic> map) {
    return SetContextRequest(
      employeeId: map['employeeId'] as String,
      contextData: map['contextData'] as Map<String, dynamic>,
    );
  }
}

/// 设置提供者请求
class SetProviderRequest {
  final String employeeId;
  final Map<String, dynamic> providerConfig;

  const SetProviderRequest({
    required this.employeeId,
    required this.providerConfig,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'providerConfig': providerConfig,
    };
  }

  factory SetProviderRequest.fromMap(Map<String, dynamic> map) {
    return SetProviderRequest(
      employeeId: map['employeeId'] as String,
      providerConfig: map['providerConfig'] as Map<String, dynamic>,
    );
  }
}

/// 设置项目请求
class SetProjectRequest {
  final String employeeId;
  final Map<String, dynamic>? projectData;

  const SetProjectRequest({
    required this.employeeId,
    this.projectData,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'projectData': projectData,
    };
  }

  factory SetProjectRequest.fromMap(Map<String, dynamic> map) {
    return SetProjectRequest(
      employeeId: map['employeeId'] as String,
      projectData: map['projectData'] as Map<String, dynamic>?,
    );
  }
}

/// 响应权限请求
class RespondPermissionRequest {
  final String employeeId;
  final String requestId;
  final String decision;

  const RespondPermissionRequest({
    required this.employeeId,
    required this.requestId,
    required this.decision,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'requestId': requestId,
      'decision': decision,
    };
  }

  factory RespondPermissionRequest.fromMap(Map<String, dynamic> map) {
    return RespondPermissionRequest(
      employeeId: map['employeeId'] as String,
      requestId: map['requestId'] as String,
      decision: map['decision'] as String,
    );
  }
}

/// 获取状态请求
class GetStateRequest {
  final String employeeId;

  const GetStateRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetStateRequest.fromMap(Map<String, dynamic> map) {
    return GetStateRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 获取上下文请求
class GetContextRequest {
  final String employeeId;

  const GetContextRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetContextRequest.fromMap(Map<String, dynamic> map) {
    return GetContextRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 清空上下文请求
class ClearContextRequest {
  final String employeeId;

  const ClearContextRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory ClearContextRequest.fromMap(Map<String, dynamic> map) {
    return ClearContextRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 获取提供者请求
class GetProviderRequest {
  final String employeeId;

  const GetProviderRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetProviderRequest.fromMap(Map<String, dynamic> map) {
    return GetProviderRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 获取项目UUID请求
class GetProjectUuidRequest {
  final String employeeId;

  const GetProjectUuidRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetProjectUuidRequest.fromMap(Map<String, dynamic> map) {
    return GetProjectUuidRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 检查路径是否存在请求
class CheckPathExistsRequest {
  final String employeeId;
  final String path;

  const CheckPathExistsRequest({required this.employeeId, required this.path});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId, 'path': path};
  }

  factory CheckPathExistsRequest.fromMap(Map<String, dynamic> map) {
    return CheckPathExistsRequest(
      employeeId: map['employeeId'] as String,
      path: map['path'] as String,
    );
  }
}

/// 列出目录内容请求
class ListDirectoryRequest {
  final String employeeId;
  final String path;

  const ListDirectoryRequest({required this.employeeId, required this.path});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId, 'path': path};
  }

  factory ListDirectoryRequest.fromMap(Map<String, dynamic> map) {
    return ListDirectoryRequest(
      employeeId: map['employeeId'] as String,
      path: map['path'] as String,
    );
  }
}

/// 获取文件/目录信息请求
class GetFileInfoRequest {
  final String employeeId;
  final String path;

  const GetFileInfoRequest({required this.employeeId, required this.path});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId, 'path': path};
  }

  factory GetFileInfoRequest.fromMap(Map<String, dynamic> map) {
    return GetFileInfoRequest(
      employeeId: map['employeeId'] as String,
      path: map['path'] as String,
    );
  }
}

/// 创建目录请求
class CreateDirectoryRequest {
  final String employeeId;
  final String path;

  const CreateDirectoryRequest({required this.employeeId, required this.path});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId, 'path': path};
  }

  factory CreateDirectoryRequest.fromMap(Map<String, dynamic> map) {
    return CreateDirectoryRequest(
      employeeId: map['employeeId'] as String,
      path: map['path'] as String,
    );
  }
}

/// 删除文件/目录请求
class DeleteFileRequest {
  final String employeeId;
  final String path;

  const DeleteFileRequest({required this.employeeId, required this.path});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId, 'path': path};
  }

  factory DeleteFileRequest.fromMap(Map<String, dynamic> map) {
    return DeleteFileRequest(
      employeeId: map['employeeId'] as String,
      path: map['path'] as String,
    );
  }
}

/// 重命名/移动文件请求
class RenameFileRequest {
  final String employeeId;
  final String oldPath;
  final String newPath;

  const RenameFileRequest({
    required this.employeeId,
    required this.oldPath,
    required this.newPath,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'oldPath': oldPath,
      'newPath': newPath,
    };
  }

  factory RenameFileRequest.fromMap(Map<String, dynamic> map) {
    return RenameFileRequest(
      employeeId: map['employeeId'] as String,
      oldPath: map['oldPath'] as String,
      newPath: map['newPath'] as String,
    );
  }
}

/// 获取已注册工具请求
class GetRegisteredToolsRequest {
  final String employeeId;

  const GetRegisteredToolsRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetRegisteredToolsRequest.fromMap(Map<String, dynamic> map) {
    return GetRegisteredToolsRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// Ping请求
class PingRequest {
  final String? employeeId;

  const PingRequest({this.employeeId});

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{};
    if (employeeId != null) {
      map['employeeId'] = employeeId!;
    }
    return map;
  }

  factory PingRequest.fromMap(Map<String, dynamic> map) {
    return PingRequest(
      employeeId: map['employeeId'] as String?,
    );
  }
}

/// 获取或创建Agent请求
class GetOrCreateAgentRequest {
  final String employeeId;

  const GetOrCreateAgentRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetOrCreateAgentRequest.fromMap(Map<String, dynamic> map) {
    return GetOrCreateAgentRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 标记消息为已读请求
///
/// 当用户打开会话查看消息时，设备通过此方法通知 Agent 消息已读
class MarkMessagesAsReadRequest {
  final String employeeId;

  /// 已读设备ID
  final String readerDeviceId;

  /// 指定消息ID列表，为 null 则标记该员工所有消息
  final List<String>? messageIds;

  const MarkMessagesAsReadRequest({
    required this.employeeId,
    required this.readerDeviceId,
    this.messageIds,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'readerDeviceId': readerDeviceId,
      if (messageIds != null) 'messageIds': messageIds,
    };
  }

  factory MarkMessagesAsReadRequest.fromMap(Map<String, dynamic> map) {
    return MarkMessagesAsReadRequest(
      employeeId: map['employeeId'] as String,
      readerDeviceId: map['readerDeviceId'] as String,
      messageIds: (map['messageIds'] as List?)?.cast<String>(),
    );
  }
}

/// 查询消息已读状态请求
///
/// 设备重新打开时可通过此方法从 Agent 查询哪些消息已读
class GetMessagesReadStatusRequest {
  final String employeeId;

  /// 查询设备ID
  final String deviceId;

  const GetMessagesReadStatusRequest({
    required this.employeeId,
    required this.deviceId,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'deviceId': deviceId,
    };
  }

  factory GetMessagesReadStatusRequest.fromMap(Map<String, dynamic> map) {
    return GetMessagesReadStatusRequest(
      employeeId: map['employeeId'] as String,
      deviceId: map['deviceId'] as String,
    );
  }
}

/// 设置技能配置请求
///
/// 同步技能实体列表到远程 Agent，更新持久化并重载运行时
class SetSkillsRequest {
  final String employeeId;

  /// 技能实体 Map 列表（AiEmployeeSkillEntity.toMap()）
  final List<Map<String, dynamic>> skills;

  const SetSkillsRequest({
    required this.employeeId,
    required this.skills,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'skills': skills,
    };
  }

  factory SetSkillsRequest.fromMap(Map<String, dynamic> map) {
    return SetSkillsRequest(
      employeeId: map['employeeId'] as String,
      skills: (map['skills'] as List)
          .map((s) => s as Map<String, dynamic>)
          .toList(),
    );
  }
}

/// 获取技能配置请求
class AgentGetSkillsRequest {
  final String employeeId;

  const AgentGetSkillsRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory AgentGetSkillsRequest.fromMap(Map<String, dynamic> map) {
    return AgentGetSkillsRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 设置 MCP 配置请求
///
/// 同步 MCP 服务器配置列表到远程 Agent
class SetMcpConfigsRequest {
  final String employeeId;

  /// MCP 服务器配置 Map 列表（McpServerConfig.toMap()）
  final List<Map<String, dynamic>> mcpConfigs;

  const SetMcpConfigsRequest({
    required this.employeeId,
    required this.mcpConfigs,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'mcpConfigs': mcpConfigs,
    };
  }

  factory SetMcpConfigsRequest.fromMap(Map<String, dynamic> map) {
    return SetMcpConfigsRequest(
      employeeId: map['employeeId'] as String,
      mcpConfigs: (map['mcpConfigs'] as List)
          .map((c) => c as Map<String, dynamic>)
          .toList(),
    );
  }
}

/// 获取 MCP 配置请求
class GetMcpConfigsRequest {
  final String employeeId;

  const GetMcpConfigsRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetMcpConfigsRequest.fromMap(Map<String, dynamic> map) {
    return GetMcpConfigsRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 获取正在调用的工具 callId 列表请求
class GetCallingToolIdsRequest {
  final String employeeId;

  const GetCallingToolIdsRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetCallingToolIdsRequest.fromMap(Map<String, dynamic> map) {
    return GetCallingToolIdsRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

