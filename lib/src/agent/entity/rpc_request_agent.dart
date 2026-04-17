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

/// 获取待处理确认请求
class GetPendingConfirmRequest {
  final String employeeId;

  const GetPendingConfirmRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetPendingConfirmRequest.fromMap(Map<String, dynamic> map) {
    return GetPendingConfirmRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 响应确认请求
class RespondConfirmRequest {
  final String employeeId;
  final String requestId;
  final String selectedOption;

  const RespondConfirmRequest({
    required this.employeeId,
    required this.requestId,
    required this.selectedOption,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'requestId': requestId,
      'selectedOption': selectedOption,
    };
  }

  factory RespondConfirmRequest.fromMap(Map<String, dynamic> map) {
    return RespondConfirmRequest(
      employeeId: map['employeeId'] as String,
      requestId: map['requestId'] as String,
      selectedOption: map['selectedOption'] as String,
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

  /// 授权范围（"once" | "exact" | "pattern" | "all"）
  final String? scope;

  /// 自定义正则模式（仅当 scope="pattern" 时有效）
  final String? customPattern;

  const RespondPermissionRequest({
    required this.employeeId,
    required this.requestId,
    required this.decision,
    this.scope,
    this.customPattern,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'requestId': requestId,
      'decision': decision,
      if (scope != null) 'scope': scope,
      if (customPattern != null) 'customPattern': customPattern,
    };
  }

  factory RespondPermissionRequest.fromMap(Map<String, dynamic> map) {
    return RespondPermissionRequest(
      employeeId: map['employeeId'] as String,
      requestId: map['requestId'] as String,
      decision: map['decision'] as String,
      scope: map['scope'] as String?,
      customPattern: map['customPattern'] as String?,
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

/// 获取会话摘要请求
class GetSessionSummaryRequest {
  final String employeeId;

  const GetSessionSummaryRequest({required this.employeeId});

  Map<String, dynamic> toMap() => {'employeeId': employeeId};

  factory GetSessionSummaryRequest.fromMap(Map<String, dynamic> map) {
    return GetSessionSummaryRequest(employeeId: map['employeeId'] as String);
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

// ===== Todo Topic 管理 =====

/// 获取当前待办主题请求
class GetCurrentTopicsRequest {
  final String employeeId;
  const GetCurrentTopicsRequest({required this.employeeId});
  Map<String, dynamic> toMap() => {'employeeId': employeeId};
  factory GetCurrentTopicsRequest.fromMap(Map<String, dynamic> map) {
    return GetCurrentTopicsRequest(employeeId: map['employeeId'] as String);
  }
}

/// 获取未完成待办主题请求
class GetPendingTopicsRequest {
  final String employeeId;
  const GetPendingTopicsRequest({required this.employeeId});
  Map<String, dynamic> toMap() => {'employeeId': employeeId};
  factory GetPendingTopicsRequest.fromMap(Map<String, dynamic> map) {
    return GetPendingTopicsRequest(employeeId: map['employeeId'] as String);
  }
}

/// 获取所有待办主题请求
class GetAllTopicsRequest {
  final String employeeId;
  const GetAllTopicsRequest({required this.employeeId});
  Map<String, dynamic> toMap() => {'employeeId': employeeId};
  factory GetAllTopicsRequest.fromMap(Map<String, dynamic> map) {
    return GetAllTopicsRequest(employeeId: map['employeeId'] as String);
  }
}

/// 获取已完成主题请求
class GetCompletedTopicsRequest {
  final String employeeId;
  final int limit;
  const GetCompletedTopicsRequest({required this.employeeId, this.limit = 50});
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'limit': limit};
  factory GetCompletedTopicsRequest.fromMap(Map<String, dynamic> map) {
    return GetCompletedTopicsRequest(
      employeeId: map['employeeId'] as String,
      limit: map['limit'] as int? ?? 50,
    );
  }
}

/// 获取待办统计请求
class GetTodoStatsRequest {
  final String employeeId;
  const GetTodoStatsRequest({required this.employeeId});
  Map<String, dynamic> toMap() => {'employeeId': employeeId};
  factory GetTodoStatsRequest.fromMap(Map<String, dynamic> map) {
    return GetTodoStatsRequest(employeeId: map['employeeId'] as String);
  }
}

// ===== Todo 写操作请求 =====

/// 更新主题内容请求
class UpdateTopicContentRequest {
  final String employeeId;
  final String topicId;
  final String? title;
  final String? description;
  const UpdateTopicContentRequest({
    required this.employeeId,
    required this.topicId,
    this.title,
    this.description,
  });
  Map<String, dynamic> toMap() => {
    'employeeId': employeeId,
    'topicId': topicId,
    if (title != null) 'title': title,
    if (description != null) 'description': description,
  };
  factory UpdateTopicContentRequest.fromMap(Map<String, dynamic> map) {
    return UpdateTopicContentRequest(
      employeeId: map['employeeId'] as String,
      topicId: map['topicId'] as String,
      title: map['title'] as String?,
      description: map['description'] as String?,
    );
  }
}

/// 删除主题请求
class DeleteTopicRequest {
  final String employeeId;
  final String topicId;
  const DeleteTopicRequest({required this.employeeId, required this.topicId});
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'topicId': topicId};
  factory DeleteTopicRequest.fromMap(Map<String, dynamic> map) {
    return DeleteTopicRequest(
      employeeId: map['employeeId'] as String,
      topicId: map['topicId'] as String,
    );
  }
}

/// 清除已完成主题请求
class ClearCompletedTopicsRequest {
  final String employeeId;
  const ClearCompletedTopicsRequest({required this.employeeId});
  Map<String, dynamic> toMap() => {'employeeId': employeeId};
  factory ClearCompletedTopicsRequest.fromMap(Map<String, dynamic> map) {
    return ClearCompletedTopicsRequest(employeeId: map['employeeId'] as String);
  }
}

/// 更新主题状态请求
class UpdateTopicStatusRequest {
  final String employeeId;
  final String topicId;
  final String status;
  const UpdateTopicStatusRequest({
    required this.employeeId,
    required this.topicId,
    required this.status,
  });
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'topicId': topicId, 'status': status};
  factory UpdateTopicStatusRequest.fromMap(Map<String, dynamic> map) {
    return UpdateTopicStatusRequest(
      employeeId: map['employeeId'] as String,
      topicId: map['topicId'] as String,
      status: map['status'] as String,
    );
  }
}

/// 批量更新主题排序请求
class ReorderTopicsRequest {
  final String employeeId;
  final List<String> topicIds;
  const ReorderTopicsRequest({
    required this.employeeId,
    required this.topicIds,
  });
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'topicIds': topicIds};
  factory ReorderTopicsRequest.fromMap(Map<String, dynamic> map) {
    return ReorderTopicsRequest(
      employeeId: map['employeeId'] as String,
      topicIds: (map['topicIds'] as List).cast<String>(),
    );
  }
}

// ===== Todo TaskItem 管理请求 =====

/// 获取主题下的任务子项请求
class GetTaskItemsByTopicRequest {
  final String employeeId;
  final String topicId;
  const GetTaskItemsByTopicRequest({required this.employeeId, required this.topicId});
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'topicId': topicId};
  factory GetTaskItemsByTopicRequest.fromMap(Map<String, dynamic> map) {
    return GetTaskItemsByTopicRequest(
      employeeId: map['employeeId'] as String,
      topicId: map['topicId'] as String,
    );
  }
}

/// 更新任务子项状态请求
class UpdateTaskItemStatusRequest {
  final String employeeId;
  final String taskId;
  final String status;
  const UpdateTaskItemStatusRequest({
    required this.employeeId,
    required this.taskId,
    required this.status,
  });
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'taskId': taskId, 'status': status};
  factory UpdateTaskItemStatusRequest.fromMap(Map<String, dynamic> map) {
    return UpdateTaskItemStatusRequest(
      employeeId: map['employeeId'] as String,
      taskId: map['taskId'] as String,
      status: map['status'] as String,
    );
  }
}

/// 更新任务子项内容请求
class UpdateTaskItemContentRequest {
  final String employeeId;
  final String taskId;
  final String? title;
  final String? content;
  const UpdateTaskItemContentRequest({
    required this.employeeId,
    required this.taskId,
    this.title,
    this.content,
  });
  Map<String, dynamic> toMap() => {
    'employeeId': employeeId,
    'taskId': taskId,
    if (title != null) 'title': title,
    if (content != null) 'content': content,
  };
  factory UpdateTaskItemContentRequest.fromMap(Map<String, dynamic> map) {
    return UpdateTaskItemContentRequest(
      employeeId: map['employeeId'] as String,
      taskId: map['taskId'] as String,
      title: map['title'] as String?,
      content: map['content'] as String?,
    );
  }
}

/// 删除任务子项请求
class DeleteTaskItemRequest {
  final String employeeId;
  final String taskId;
  const DeleteTaskItemRequest({required this.employeeId, required this.taskId});
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'taskId': taskId};
  factory DeleteTaskItemRequest.fromMap(Map<String, dynamic> map) {
    return DeleteTaskItemRequest(
      employeeId: map['employeeId'] as String,
      taskId: map['taskId'] as String,
    );
  }
}

/// 批量更新任务子项排序请求
class ReorderTaskItemsRequest {
  final String employeeId;
  final List<String> taskItemIds;
  const ReorderTaskItemsRequest({
    required this.employeeId,
    required this.taskItemIds,
  });
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'taskItemIds': taskItemIds};
  factory ReorderTaskItemsRequest.fromMap(Map<String, dynamic> map) {
    return ReorderTaskItemsRequest(
      employeeId: map['employeeId'] as String,
      taskItemIds: (map['taskItemIds'] as List).cast<String>(),
    );
  }
}

// ===== Spec 管理请求 =====

/// 获取活跃 spec 项请求
class GetActiveSpecsRequest {
  final String employeeId;
  const GetActiveSpecsRequest({required this.employeeId});
  Map<String, dynamic> toMap() => {'employeeId': employeeId};
  factory GetActiveSpecsRequest.fromMap(Map<String, dynamic> map) {
    return GetActiveSpecsRequest(employeeId: map['employeeId'] as String);
  }
}

/// 获取已完成 spec 项请求
class GetCompletedSpecsRequest {
  final String employeeId;
  final int limit;
  const GetCompletedSpecsRequest({required this.employeeId, this.limit = 50});
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'limit': limit};
  factory GetCompletedSpecsRequest.fromMap(Map<String, dynamic> map) {
    return GetCompletedSpecsRequest(
      employeeId: map['employeeId'] as String,
      limit: map['limit'] as int? ?? 50,
    );
  }
}

/// 获取 spec 统计请求
class GetSpecStatsRequest {
  final String employeeId;
  const GetSpecStatsRequest({required this.employeeId});
  Map<String, dynamic> toMap() => {'employeeId': employeeId};
  factory GetSpecStatsRequest.fromMap(Map<String, dynamic> map) {
    return GetSpecStatsRequest(employeeId: map['employeeId'] as String);
  }
}

// ===== Spec 写操作请求 =====

/// 更新 spec 状态请求
class UpdateSpecStatusRequest {
  final String employeeId;
  final String specId;
  final String status;
  const UpdateSpecStatusRequest({
    required this.employeeId,
    required this.specId,
    required this.status,
  });
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'specId': specId, 'status': status};
  factory UpdateSpecStatusRequest.fromMap(Map<String, dynamic> map) {
    return UpdateSpecStatusRequest(
      employeeId: map['employeeId'] as String,
      specId: map['specId'] as String,
      status: map['status'] as String,
    );
  }
}

/// 更新 spec 内容请求
class UpdateSpecContentRequest {
  final String employeeId;
  final String specId;
  final String content;
  const UpdateSpecContentRequest({
    required this.employeeId,
    required this.specId,
    required this.content,
  });
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'specId': specId, 'content': content};
  factory UpdateSpecContentRequest.fromMap(Map<String, dynamic> map) {
    return UpdateSpecContentRequest(
      employeeId: map['employeeId'] as String,
      specId: map['specId'] as String,
      content: map['content'] as String,
    );
  }
}

/// 删除 spec 请求
class DeleteSpecRequest {
  final String employeeId;
  final String specId;
  const DeleteSpecRequest({required this.employeeId, required this.specId});
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'specId': specId};
  factory DeleteSpecRequest.fromMap(Map<String, dynamic> map) {
    return DeleteSpecRequest(
      employeeId: map['employeeId'] as String,
      specId: map['specId'] as String,
    );
  }
}

/// 清除已完成 spec 请求
class ClearCompletedSpecsRequest {
  final String employeeId;
  const ClearCompletedSpecsRequest({required this.employeeId});
  Map<String, dynamic> toMap() => {'employeeId': employeeId};
  factory ClearCompletedSpecsRequest.fromMap(Map<String, dynamic> map) {
    return ClearCompletedSpecsRequest(employeeId: map['employeeId'] as String);
  }
}

/// 批量更新 spec 排序请求
class ReorderSpecsRequest {
  final String employeeId;
  final List<String> specIds;
  const ReorderSpecsRequest({
    required this.employeeId,
    required this.specIds,
  });
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'specIds': specIds};
  factory ReorderSpecsRequest.fromMap(Map<String, dynamic> map) {
    return ReorderSpecsRequest(
      employeeId: map['employeeId'] as String,
      specIds: (map['specIds'] as List).cast<String>(),
    );
  }
}

/// 获取文件操作记录请求
class GetFileOperationsRequest {
  final String employeeId;
  final int limit;
  final int offset;

  const GetFileOperationsRequest({
    required this.employeeId,
    this.limit = 100,
    this.offset = 0,
  });

  Map<String, dynamic> toMap() => {
        'employeeId': employeeId,
        'limit': limit,
        'offset': offset,
      };

  factory GetFileOperationsRequest.fromMap(Map<String, dynamic> map) {
    return GetFileOperationsRequest(
      employeeId: map['employeeId'] as String,
      limit: map['limit'] as int? ?? 100,
      offset: map['offset'] as int? ?? 0,
    );
  }
}

/// 获取指定消息的文件操作记录请求
class GetFileOperationsByMessageRequest {
  final String employeeId;
  final String messageId;

  const GetFileOperationsByMessageRequest({
    required this.employeeId,
    required this.messageId,
  });

  Map<String, dynamic> toMap() => {
        'employeeId': employeeId,
        'messageId': messageId,
      };

  factory GetFileOperationsByMessageRequest.fromMap(Map<String, dynamic> map) {
    return GetFileOperationsByMessageRequest(
      employeeId: map['employeeId'] as String,
      messageId: map['messageId'] as String,
    );
  }
}

/// 清除文件操作记录请求
class ClearFileOperationsRequest {
  final String employeeId;

  const ClearFileOperationsRequest({required this.employeeId});

  Map<String, dynamic> toMap() => {'employeeId': employeeId};

  factory ClearFileOperationsRequest.fromMap(Map<String, dynamic> map) {
    return ClearFileOperationsRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}
