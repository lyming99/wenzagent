/// Agent 事件类型枚举
enum AgentEventType {
  /// Agent 状态变更
  agentStatusChanged,

  /// 消息状态变更（queued/processing/streaming/completed/failed/interrupted/revoked）
  messageStatusChanged,

  /// 消息已读状态变更
  messageReadStatusChanged,

  /// 工具调用开始
  toolCallStart,

  /// 工具调用结果
  toolCallResult,

  /// 工具权限请求
  toolPermissionRequest,

  /// 工具权限响应
  toolPermissionResponse,

  /// 消息被引用回复
  messageReplied,

  /// 消息入队
  messageQueued,

  /// 消息处理中（ChatAdapter 工具回调）
  messageProcessing,

  /// 未知类型（兼容旧数据或外部扩展）
  unknown;

  /// 序列化为字符串（用于 JSON / LAN 传输）
  String get value => name;

  /// 从字符串反序列化
  static AgentEventType fromString(String value) {
    return AgentEventType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AgentEventType.unknown,
    );
  }
}

/// Agent 事件实体
///
/// 统一封装 Agent 运行过程中产生的各类事件，
/// 用于事件流的类型安全传递。
class AgentEvent {
  /// 事件类型
  final AgentEventType type;

  /// 事件携带的数据
  final Map<String, dynamic> data;

  /// 员工 UUID（事件所属的 Agent）
  final String? employeeId;

  /// 事件来源设备 ID（仅设备层转发时填充）
  final String? fromDeviceId;

  const AgentEvent({
    required this.type,
    required this.data,
    this.employeeId,
    this.fromDeviceId,
  });

  factory AgentEvent.fromMap(Map<String, dynamic> map) {
    return AgentEvent(
      type: AgentEventType.fromString(map['type'] as String? ?? ''),
      data: map['data'] as Map<String, dynamic>? ?? {},
      employeeId: map['employeeId'] as String?,
      fromDeviceId:
          map['fromDeviceId'] as String? ?? map['fromId'] as String?,
    );
  }

  /// 转为 Map（用于序列化 / LAN 传输）
  Map<String, dynamic> toMap() {
    return {
      'type': type.value,
      'data': data,
      if (employeeId != null) 'employeeId': employeeId,
      if (fromDeviceId != null) 'fromDeviceId': fromDeviceId,
    };
  }

  @override
  String toString() => 'AgentEvent(type: $type, employeeId: $employeeId)';
}
