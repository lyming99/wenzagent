// RPC 请求参数实体类 - Agent 相关请求

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
