import 'entity/entity.dart';

/// Agent 工作状态
enum AgentStatus {
  /// 空闲
  idle,

  /// 正在处理消息
  processing,

  /// 正在流式输出
  streaming,

  /// LLM 调用失败，正在重试
  retrying,

  /// 等待权限确认
  waitingPermission,

  /// 已销毁
  disposed;

  /// 从字符串解析
  static AgentStatus fromString(String value) {
    return AgentStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AgentStatus.idle,
    );
  }
}

/// 消息处理状态
///
/// 注意：保留此枚举以向后兼容，新的代码应该使用 MessageProcessingStatus
@Deprecated(
  'Use MessageProcessingStatus from entity/queued_message.dart instead',
)
enum AgentMessageStatus {
  /// 无状态
  none,

  /// 排队中
  queued,

  /// 处理中
  processing,

  /// LLM 调用重试中
  retrying,

  /// 已完成
  completed,

  /// 处理失败
  failed,

  /// 被打断
  interrupted,

  /// 已撤回
  revoked;

  /// 从字符串解析
  static AgentMessageStatus fromString(String value) {
    return AgentMessageStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AgentMessageStatus.none,
    );
  }
}

/// LLM 重试进度（支持 JSON 序列化）
class AgentRetryProgress {
  /// 当前重试次数（从 1 开始）
  final int attempt;

  /// 最大重试次数
  final int maxRetries;

  /// 最近一次触发重试的错误
  final String? error;

  /// 重试过程中收集到的错误列表
  ///
  /// 按发生顺序记录；[error] 始终表示最后一条错误，用于兼容旧调用方。
  final List<String> errors;

  /// 下一次重试前的等待时间（毫秒）
  final int? delayMs;

  /// 预计下一次重试时间
  final DateTime? nextRetryAt;

  /// 本次重试是否由上下文长度溢出触发
  final bool contextOverflow;

  /// 检测到上下文长度溢出后，是否已经触发过上下文压缩
  final bool contextCompressed;

  /// 更新时间
  final DateTime updatedAt;

  AgentRetryProgress({
    required this.attempt,
    required this.maxRetries,
    this.error,
    this.errors = const [],
    this.delayMs,
    this.nextRetryAt,
    this.contextOverflow = false,
    this.contextCompressed = false,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  /// 重试进度比例，范围 0~1
  double get progress => maxRetries <= 0 ? 1 : attempt / maxRetries;

  Map<String, dynamic> toMap() {
    return {
      'attempt': attempt,
      'maxRetries': maxRetries,
      if (error != null) 'error': error,
      if (errors.isNotEmpty) 'errors': errors,
      if (delayMs != null) 'delayMs': delayMs,
      if (nextRetryAt != null) 'nextRetryAt': nextRetryAt!.toIso8601String(),
      if (contextOverflow) 'contextOverflow': true,
      if (contextCompressed) 'contextCompressed': true,
      'progress': progress,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory AgentRetryProgress.fromMap(Map<String, dynamic> map) {
    final error = map['error'] as String?;
    final errors =
        (map['errors'] as List?)?.cast<String>() ??
        (error != null ? [error] : const <String>[]);
    return AgentRetryProgress(
      attempt: (map['attempt'] as num?)?.toInt() ?? 0,
      maxRetries: (map['maxRetries'] as num?)?.toInt() ?? 0,
      error: error,
      errors: errors,
      delayMs: (map['delayMs'] as num?)?.toInt(),
      nextRetryAt: map['nextRetryAt'] != null
          ? DateTime.parse(map['nextRetryAt'] as String)
          : null,
      contextOverflow: map['contextOverflow'] as bool? ?? false,
      contextCompressed: map['contextCompressed'] as bool? ?? false,
      updatedAt: map['updatedAt'] != null
          ? DateTime.parse(map['updatedAt'] as String)
          : DateTime.now(),
    );
  }
}

/// Agent 状态快照（支持 JSON 序列化）
class AgentStateSnapshot {
  /// Agent 状态
  final AgentStatus status;

  /// 当前处理中的消息ID
  final String? currentProcessingMessageId;

  /// 排队中的消息ID列表
  final List<String> queuedMessageIds;

  /// 是否正在流式输出
  final bool isStreaming;

  /// 排队消息数量
  final int queueLength;

  /// 重试进度（仅 retrying 状态下通常有值）
  final AgentRetryProgress? retryProgress;

  /// 时间戳
  final DateTime timestamp;

  AgentStateSnapshot({
    required this.status,
    this.currentProcessingMessageId,
    this.queuedMessageIds = const [],
    this.isStreaming = false,
    this.queueLength = 0,
    this.retryProgress,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'status': status.name,
      'currentProcessingMessageId': currentProcessingMessageId,
      'queuedMessageIds': queuedMessageIds,
      'isStreaming': isStreaming,
      'queueLength': queueLength,
      if (retryProgress != null) 'retryProgress': retryProgress!.toMap(),
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory AgentStateSnapshot.fromMap(Map<String, dynamic> map) {
    return AgentStateSnapshot(
      status: AgentStatus.fromString(map['status'] as String? ?? 'idle'),
      currentProcessingMessageId: map['currentProcessingMessageId'] as String?,
      queuedMessageIds:
          (map['queuedMessageIds'] as List?)?.cast<String>() ?? [],
      isStreaming: map['isStreaming'] as bool? ?? false,
      queueLength: map['queueLength'] as int? ?? 0,
      retryProgress: map['retryProgress'] is Map<String, dynamic>
          ? AgentRetryProgress.fromMap(
              map['retryProgress'] as Map<String, dynamic>,
            )
          : null,
      timestamp: map['timestamp'] != null
          ? DateTime.parse(map['timestamp'] as String)
          : DateTime.now(),
    );
  }

  /// 创建空闲状态快照
  factory AgentStateSnapshot.idle() {
    return AgentStateSnapshot(status: AgentStatus.idle);
  }
}

/// 权限请求信息（支持 JSON 序列化）
class AgentPermissionRequest {
  /// 请求ID
  final String requestId;

  /// 权限类型
  final String type;

  /// 请求描述
  final String description;

  /// 函数名称
  final String functionName;

  /// 权限模式
  final String? permissionPattern;

  /// 权限类型分类
  final String? permissionType;

  /// 附加数据
  final Map<String, dynamic>? data;

  /// 创建时间
  final DateTime createTime;

  /// 权限检查的参数 key（如 "path", "command"）
  final String? permissionArgKey;

  /// 权限检查的参数值（如 "/path/to/file", "git commit"）
  final String? permissionArgValue;

  /// 自动推导的模式（用于展示"同意 xx.*"选项）
  final String? suggestedPattern;

  AgentPermissionRequest({
    required this.requestId,
    required this.type,
    required this.description,
    required this.functionName,
    this.permissionPattern,
    this.permissionType,
    this.data,
    DateTime? createTime,
    this.permissionArgKey,
    this.permissionArgValue,
    this.suggestedPattern,
  }) : createTime = createTime ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'requestId': requestId,
      'type': type,
      'description': description,
      'functionName': functionName,
      'permissionPattern': permissionPattern,
      'permissionType': permissionType,
      'data': data,
      'createTime': createTime.toIso8601String(),
      if (permissionArgKey != null) 'permissionArgKey': permissionArgKey,
      if (permissionArgValue != null) 'permissionArgValue': permissionArgValue,
      if (suggestedPattern != null) 'suggestedPattern': suggestedPattern,
    };
  }

  factory AgentPermissionRequest.fromMap(Map<String, dynamic> map) {
    return AgentPermissionRequest(
      requestId: map['requestId'] as String,
      type: map['type'] as String,
      description: map['description'] as String? ?? '',
      functionName: map['functionName'] as String? ?? '',
      permissionPattern: map['permissionPattern'] as String?,
      permissionType: map['permissionType'] as String?,
      data: map['data'] as Map<String, dynamic>?,
      createTime: map['createTime'] != null
          ? DateTime.parse(map['createTime'] as String)
          : DateTime.now(),
      permissionArgKey: map['permissionArgKey'] as String?,
      permissionArgValue: map['permissionArgValue'] as String?,
      suggestedPattern: map['suggestedPattern'] as String?,
    );
  }
}

/// 权限决策
enum PermissionDecision {
  /// 允许
  allow,

  /// 拒绝
  deny,

  /// 允许且记住（后续相同权限自动允许）
  allowAlways;

  static PermissionDecision fromString(String value) {
    return PermissionDecision.values.firstWhere(
      (e) => e.name == value,
      orElse: () => PermissionDecision.deny,
    );
  }
}

/// 权限审批范围
///
/// 当用户确认权限请求时，选择授权的范围：
/// - [once] 仅本次允许
/// - [exact] 精确匹配该参数值（持久化 exact 规则）
/// - [pattern] 匹配该参数的正则模式（持久化 regex 规则）
/// - [all] 该权限类型全部允许（持久化 all 规则）
enum PermissionApprovalScope {
  /// 仅本次允许
  once,

  /// 精确匹配该参数值
  exact,

  /// 匹配该参数的正则模式
  pattern,

  /// 该权限类型全部允许
  all;

  static PermissionApprovalScope fromString(String value) {
    return PermissionApprovalScope.values.firstWhere(
      (e) => e.name == value,
      orElse: () => PermissionApprovalScope.once,
    );
  }
}

/// 确认选项
///
/// confirm 工具中用户可选择的一个选项。
class ConfirmOption {
  /// 选项标识符（如 "plan_a", "plan_b"）
  final String key;

  /// 选项显示文本（如 "方案A：使用Docker部署"）
  final String label;

  /// 选项详细描述（可选）
  final String? description;

  const ConfirmOption({
    required this.key,
    required this.label,
    this.description,
  });

  Map<String, dynamic> toMap() {
    return {
      'key': key,
      'label': label,
      if (description != null) 'description': description,
    };
  }

  factory ConfirmOption.fromMap(Map<String, dynamic> map) {
    return ConfirmOption(
      key: map['key'] as String,
      label: map['label'] as String,
      description: map['description'] as String?,
    );
  }
}

/// 确认请求信息（支持 JSON 序列化）
///
/// Agent 通过 confirm 工具向前端发送确认请求，
/// 用户选择一个选项后，Agent 收到选择结果并继续执行。
class AgentConfirmRequest {
  /// 请求ID
  final String requestId;

  /// 确认标题（如"请选择部署方案"）
  final String title;

  /// 详细说明
  final String message;

  /// 选项列表（至少2个）
  final List<ConfirmOption> options;

  /// 默认选项 key
  final String? defaultOption;

  /// 附加数据
  final Map<String, dynamic>? data;

  /// 创建时间
  final DateTime createTime;

  AgentConfirmRequest({
    required this.requestId,
    required this.title,
    required this.message,
    required this.options,
    this.defaultOption,
    this.data,
    DateTime? createTime,
  }) : createTime = createTime ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'requestId': requestId,
      'title': title,
      'message': message,
      'options': options.map((o) => o.toMap()).toList(),
      if (defaultOption != null) 'defaultOption': defaultOption,
      if (data != null) 'data': data,
      'createTime': createTime.toIso8601String(),
    };
  }

  factory AgentConfirmRequest.fromMap(Map<String, dynamic> map) {
    return AgentConfirmRequest(
      requestId: map['requestId'] as String,
      title: map['title'] as String,
      message: map['message'] as String,
      options: (map['options'] as List)
          .map((o) => ConfirmOption.fromMap(o as Map<String, dynamic>))
          .toList(),
      defaultOption: map['defaultOption'] as String?,
      data: map['data'] as Map<String, dynamic>?,
      createTime: map['createTime'] != null
          ? DateTime.parse(map['createTime'] as String)
          : DateTime.now(),
    );
  }
}

/// Agent 运行时摘要
class AgentRuntimeSummary {
  final String employeeId;
  final AgentStatus status;
  final DateTime lastActiveTime;
  final int queueLength;
  final int refCount;

  AgentRuntimeSummary({
    required this.employeeId,
    required this.status,
    required this.lastActiveTime,
    required this.queueLength,
    required this.refCount,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'status': status.name,
      'lastActiveTime': lastActiveTime.toIso8601String(),
      'queueLength': queueLength,
      'refCount': refCount,
    };
  }

  factory AgentRuntimeSummary.fromMap(Map<String, dynamic> map) {
    return AgentRuntimeSummary(
      employeeId: map['employeeId'] as String,
      status: AgentStatus.fromString(map['status'] as String? ?? 'idle'),
      lastActiveTime: map['lastActiveTime'] != null
          ? DateTime.parse(map['lastActiveTime'] as String)
          : DateTime.now(),
      queueLength: map['queueLength'] as int? ?? 0,
      refCount: map['refCount'] as int? ?? 0,
    );
  }
}

// ===== 类型转换扩展（向后兼容） =====

/// AgentMessageStatus 到 MessageProcessingStatus 的转换
extension AgentMessageStatusExtension on AgentMessageStatus {
  /// 转换为 MessageProcessingStatus
  MessageProcessingStatus toMessageProcessingStatus() {
    switch (this) {
      case AgentMessageStatus.none:
        return MessageProcessingStatus.none;
      case AgentMessageStatus.queued:
        return MessageProcessingStatus.queued;
      case AgentMessageStatus.processing:
        return MessageProcessingStatus.processing;
      case AgentMessageStatus.retrying:
        return MessageProcessingStatus.retrying;
      case AgentMessageStatus.completed:
        return MessageProcessingStatus.completed;
      case AgentMessageStatus.failed:
        return MessageProcessingStatus.failed;
      case AgentMessageStatus.interrupted:
        return MessageProcessingStatus.interrupted;
      case AgentMessageStatus.revoked:
        return MessageProcessingStatus.revoked;
    }
  }
}

/// MessageProcessingStatus 到 AgentMessageStatus 的转换（向后兼容）
extension MessageProcessingStatusExtension on MessageProcessingStatus {
  /// 转换为 AgentMessageStatus
  @Deprecated('Use MessageProcessingStatus directly')
  AgentMessageStatus toAgentMessageStatus() {
    switch (this) {
      case MessageProcessingStatus.none:
        return AgentMessageStatus.none;
      case MessageProcessingStatus.queued:
        return AgentMessageStatus.queued;
      case MessageProcessingStatus.processing:
        return AgentMessageStatus.processing;
      case MessageProcessingStatus.retrying:
        return AgentMessageStatus.retrying;
      case MessageProcessingStatus.completed:
        return AgentMessageStatus.completed;
      case MessageProcessingStatus.failed:
        return AgentMessageStatus.failed;
      case MessageProcessingStatus.interrupted:
        return AgentMessageStatus.interrupted;
      case MessageProcessingStatus.revoked:
        return AgentMessageStatus.revoked;
    }
  }
}
