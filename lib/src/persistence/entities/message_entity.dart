/// AI员工消息实体（Hive版本）
class AiEmployeeMessageEntity {
  /// 消息UUID
  final String uuid;

  /// 会话UUID
  String employeeId;

  /// 消息角色 (user/assistant/system/tool)
  String role;

  /// 消息类型 (text/functionCall/functionResult)
  String type;

  /// 消息内容
  String? content;

  /// 工具调用ID
  String? toolCallId;

  /// 工具名称
  String? toolName;

  /// 工具参数 (JSON)
  String? toolArguments;

  /// 工具结果
  String? toolResult;

  /// 工具调用列表 (JSON, 用于AI消息包含多个工具调用)
  String? toolCalls;

  /// 处理状态 (none/queued/processing/completed/failed/interrupted)
  String processingStatus;

  /// 处理错误信息
  String? processingError;

  /// 输入token数
  int? inputTokens;

  /// 输出token数
  int? outputTokens;

  /// 是否已读
  int isRead;

  /// 是否已删除
  int deleted;

  /// 创建时间
  DateTime createTime;

  /// 更新时间
  DateTime updateTime;

  AiEmployeeMessageEntity({
    required this.uuid,
    required this.employeeId,
    this.role = 'user',
    this.type = 'text',
    this.content,
    this.toolCallId,
    this.toolName,
    this.toolArguments,
    this.toolResult,
    this.toolCalls,
    this.processingStatus = 'none',
    this.processingError,
    this.inputTokens,
    this.outputTokens,
    this.isRead = 0,
    this.deleted = 0,
    required this.createTime,
    required this.updateTime,
  });

  /// 从Map创建
  factory AiEmployeeMessageEntity.fromMap(Map<String, dynamic> map) {
    return AiEmployeeMessageEntity(
      uuid: map['uuid'] as String,
      employeeId: map['employeeId'] as String,
      role: map['role'] as String? ?? 'user',
      type: map['type'] as String? ?? 'text',
      content: map['content'] as String?,
      toolCallId: map['toolCallId'] as String?,
      toolName: map['toolName'] as String?,
      toolArguments: map['toolArguments'] as String?,
      toolResult: map['toolResult'] as String?,
      toolCalls: map['toolCalls'] as String?,
      processingStatus: map['processingStatus'] as String? ?? 'none',
      processingError: map['processingError'] as String?,
      inputTokens: map['inputTokens'] as int?,
      outputTokens: map['outputTokens'] as int?,
      isRead: map['isRead'] as int? ?? 0,
      deleted: map['deleted'] as int? ?? 0,
      createTime: map['createTime'] is DateTime
          ? map['createTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(map['createTime'] as int? ?? 0),
      updateTime: map['updateTime'] is DateTime
          ? map['updateTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(map['updateTime'] as int? ?? 0),
    );
  }

  /// 转换为Map
  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'employeeId': employeeId,
      'role': role,
      'type': type,
      'content': content,
      'toolCallId': toolCallId,
      'toolName': toolName,
      'toolArguments': toolArguments,
      'toolResult': toolResult,
      'toolCalls': toolCalls,
      'processingStatus': processingStatus,
      'processingError': processingError,
      'inputTokens': inputTokens,
      'outputTokens': outputTokens,
      'isRead': isRead,
      'deleted': deleted,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateTime': updateTime.millisecondsSinceEpoch,
    };
  }

  /// 复制并修改
  AiEmployeeMessageEntity copyWith({
    String? uuid,
    String? employeeId,
    String? role,
    String? type,
    String? content,
    String? toolCallId,
    String? toolName,
    String? toolArguments,
    String? toolResult,
    String? toolCalls,
    String? processingStatus,
    String? processingError,
    int? inputTokens,
    int? outputTokens,
    int? isRead,
    int? deleted,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return AiEmployeeMessageEntity(
      uuid: uuid ?? this.uuid,
      employeeId: employeeId ?? this.employeeId,
      role: role ?? this.role,
      type: type ?? this.type,
      content: content ?? this.content,
      toolCallId: toolCallId ?? this.toolCallId,
      toolName: toolName ?? this.toolName,
      toolArguments: toolArguments ?? this.toolArguments,
      toolResult: toolResult ?? this.toolResult,
      toolCalls: toolCalls ?? this.toolCalls,
      processingStatus: processingStatus ?? this.processingStatus,
      processingError: processingError ?? this.processingError,
      inputTokens: inputTokens ?? this.inputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      isRead: isRead ?? this.isRead,
      deleted: deleted ?? this.deleted,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  @override
  String toString() {
    return 'AiEmployeeMessageEntity(uuid: $uuid, role: $role, type: $type)';
  }
}
