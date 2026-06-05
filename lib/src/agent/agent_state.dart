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

  /// 时间戳
  final DateTime timestamp;

  AgentStateSnapshot({
    required this.status,
    this.currentProcessingMessageId,
    this.queuedMessageIds = const [],
    this.isStreaming = false,
    this.queueLength = 0,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'status': status.name,
      'currentProcessingMessageId': currentProcessingMessageId,
      'queuedMessageIds': queuedMessageIds,
      'isStreaming': isStreaming,
      'queueLength': queueLength,
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
