/// RPC 请求参数实体类
///
/// 为所有RPC方法提供类型安全的参数封装

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

