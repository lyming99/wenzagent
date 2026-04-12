/// Agent 消息基类
///
/// 所有 Agent 相关消息的统一基类，提供标准字段和序列化方法
class AgentMessage {
  /// 消息唯一ID
  final String id;

  /// 消息角色 (user/assistant/system/tool)
  final String role;

  /// 消息类型 (text/functionCall/functionResult)
  final String type;

  /// 消息内容
  final String? content;

  /// 创建时间
  final DateTime createdAt;

  /// 工具调用ID（可选）
  final String? toolCallId;

  /// 工具名称（可选）
  final String? toolName;

  /// 工具参数（可选）
  final Map<String, dynamic>? toolArguments;

  /// 工具结果（可选）
  final String? toolResult;

  /// 工具调用列表（可选，用于多条工具调用）
  final List<ToolCall>? toolCalls;

  /// 元数据（可选，用于存储自定义字段）
  final Map<String, dynamic>? metadata;

  /// 消息状态 (none/queued/processing/completed/failed/interrupted)
  final String? status;

  const AgentMessage({
    required this.id,
    this.role = 'user',
    this.type = 'text',
    this.content,
    required this.createdAt,
    this.toolCallId,
    this.toolName,
    this.toolArguments,
    this.toolResult,
    this.toolCalls,
    this.metadata,
    this.status,
  });

  /// 从 Map 创建
  factory AgentMessage.fromMap(Map<String, dynamic> map) {
    // 确保 metadata 不为 null，并将 map 顶层的 toolResults 合并到 metadata
    Map<String, dynamic> metadata = (map['metadata'] as Map<String, dynamic>?) ?? {};
    // 如果 map 顶层有 toolResults（分组 tool result），合并到 metadata 中
    if (map['toolResults'] != null && !metadata.containsKey('toolResults')) {
      metadata = {...metadata, 'toolResults': map['toolResults']};
    }

    return AgentMessage(
      id: map['id'] as String,
      role: map['role'] as String? ?? 'user',
      type: map['type'] as String? ?? 'text',
      content: map['content'] as String?,
      createdAt: parseDateTime(map['createdAt']),
      toolCallId: map['toolCallId'] as String?,
      toolName: map['toolName'] as String?,
      toolArguments: map['toolArguments'] as Map<String, dynamic>?,
      toolResult: map['toolResult'] as String?,
      toolCalls: map['toolCalls'] != null
          ? (map['toolCalls'] as List)
              .map((tc) => ToolCall.fromMap(tc as Map<String, dynamic>))
              .toList()
          : null,
      metadata: metadata.isNotEmpty ? metadata : null,
      status: map['status'] as String?,
    );
  }

  /// 转换为 Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'role': role,
      'type': type,
      if (content != null) 'content': content,
      'createdAt': createdAt.toIso8601String(),
      if (toolCallId != null) 'toolCallId': toolCallId,
      if (toolName != null) 'toolName': toolName,
      if (toolArguments != null) 'toolArguments': toolArguments,
      if (toolResult != null) 'toolResult': toolResult,
      if (toolCalls != null)
        'toolCalls': toolCalls!.map((tc) => tc.toMap()).toList(),
      if (metadata != null) 'metadata': metadata,
      if (status != null) 'status': status,
    };
  }

  /// 复制并修改
  AgentMessage copyWith({
    String? id,
    String? role,
    String? type,
    String? content,
    DateTime? createdAt,
    String? toolCallId,
    String? toolName,
    Map<String, dynamic>? toolArguments,
    String? toolResult,
    List<ToolCall>? toolCalls,
    Map<String, dynamic>? metadata,
    String? status,
  }) {
    return AgentMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      type: type ?? this.type,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      toolCallId: toolCallId ?? this.toolCallId,
      toolName: toolName ?? this.toolName,
      toolArguments: toolArguments ?? this.toolArguments,
      toolResult: toolResult ?? this.toolResult,
      toolCalls: toolCalls ?? this.toolCalls,
      metadata: metadata ?? this.metadata,
      status: status ?? this.status,
    );
  }

  /// 解析 DateTime（公共方法，供子类使用）
  static DateTime parseDateTime(dynamic value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.parse(value);
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return DateTime.now();
  }

  @override
  String toString() {
    return 'AgentMessage(id: $id, role: $role, type: $type, content: ${content?.substring(0, content!.length.clamp(0, 20))})';
  }
}

/// 工具调用
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  factory ToolCall.fromMap(Map<String, dynamic> map) {
    return ToolCall(
      id: map['id'] as String,
      name: map['name'] as String,
      arguments: Map<String, dynamic>.from(map['arguments'] as Map),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'arguments': arguments,
    };
  }
}

/// Map 扩展方法
extension AgentMessageMapExtension on Map<String, dynamic> {
  /// 转换为 AgentMessage
  AgentMessage toAgentMessage() => AgentMessage.fromMap(this);
}
