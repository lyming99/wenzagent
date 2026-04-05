/// Agent 工作状态
enum AgentStatus {
  /// 空闲
  idle,

  /// 正在处理消息
  processing,

  /// 正在流式输出
  streaming,

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
enum AgentMessageStatus {
  /// 无状态
  none,

  /// 排队中
  queued,

  /// 处理中
  processing,

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
      currentProcessingMessageId:
          map['currentProcessingMessageId'] as String?,
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

  AgentPermissionRequest({
    required this.requestId,
    required this.type,
    required this.description,
    required this.functionName,
    this.permissionPattern,
    this.permissionType,
    this.data,
    DateTime? createTime,
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

/// Agent 运行时摘要
class AgentRuntimeSummary {
  final String employeeUuid;
  final String? employeeId;
  final AgentStatus status;
  final DateTime lastActiveTime;
  final int queueLength;
  final int refCount;

  AgentRuntimeSummary({
    required this.employeeUuid,
    this.employeeId,
    required this.status,
    required this.lastActiveTime,
    required this.queueLength,
    required this.refCount,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeUuid': employeeUuid,
      'employeeId': employeeId,
      'status': status.name,
      'lastActiveTime': lastActiveTime.toIso8601String(),
      'queueLength': queueLength,
      'refCount': refCount,
    };
  }

  factory AgentRuntimeSummary.fromMap(Map<String, dynamic> map) {
    return AgentRuntimeSummary(
      employeeUuid: map['employeeUuid'] as String,
      employeeId: map['employeeId'] as String?,
      status: AgentStatus.fromString(map['status'] as String? ?? 'idle'),
      lastActiveTime: map['lastActiveTime'] != null
          ? DateTime.parse(map['lastActiveTime'] as String)
          : DateTime.now(),
      queueLength: map['queueLength'] as int? ?? 0,
      refCount: map['refCount'] as int? ?? 0,
    );
  }
}
