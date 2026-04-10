import 'dart:convert';

/// AI员工消息实体
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

  /// 完整消息数据的 JSON 字符串（用于无损持久化，避免字段映射丢失）
  ///
  /// 存储时直接将原始消息 Map jsonEncode，读取时 jsonDecode 还原。
  /// 优先级高于各独立字段。
  String? jsonData;

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
    this.jsonData,
  });

  /// 从原始消息 Map 直接创建实体（统一 JSON 格式存储）
  ///
  /// 将整个 [messageMap] 序列化为 JSON 字符串存入 [jsonData]，
  /// 同时从 map 中提取关键字段填充独立属性，保证兼容性。
  factory AiEmployeeMessageEntity.fromMessageMap(Map<String, dynamic> messageMap) {
    final now = DateTime.now();
    final uuid = (messageMap['uuid'] ?? messageMap['id'] ?? '') as String;
    final employeeId = (messageMap['employeeId'] ?? '') as String;

    // 将整个 map 序列化为 JSON 字符串
    final jsonData = jsonEncode(messageMap);

    // 兼容 createTime / createdAt 两种时间字段
    DateTime createTime;
    final rawTime = messageMap['createTime'] ?? messageMap['createdAt'];
    if (rawTime is DateTime) {
      createTime = rawTime;
    } else if (rawTime is int) {
      createTime = DateTime.fromMillisecondsSinceEpoch(rawTime);
    } else if (rawTime is String) {
      createTime = DateTime.tryParse(rawTime) ?? now;
    } else {
      createTime = now;
    }

    // toolCalls 可能是 List 或 String，统一转为 String
    String? toolCallsStr;
    final rawToolCalls = messageMap['toolCalls'];
    if (rawToolCalls != null) {
      toolCallsStr = rawToolCalls is String ? rawToolCalls : jsonEncode(rawToolCalls);
    }

    // toolArguments 可能是 Map 或 String，统一转为 String
    String? toolArgumentsStr;
    final rawToolArgs = messageMap['toolArguments'];
    if (rawToolArgs != null) {
      toolArgumentsStr = rawToolArgs is String ? rawToolArgs : jsonEncode(rawToolArgs);
    }

    return AiEmployeeMessageEntity(
      uuid: uuid,
      employeeId: employeeId,
      role: (messageMap['role'] as String?) ?? 'user',
      type: (messageMap['type'] as String?) ?? 'text',
      content: messageMap['content'] as String?,
      toolCallId: messageMap['toolCallId'] as String?,
      toolName: messageMap['toolName'] as String?,
      toolArguments: toolArgumentsStr,
      toolResult: messageMap['toolResult'] as String?,
      toolCalls: toolCallsStr,
      processingStatus: (messageMap['processingStatus'] as String?) ?? 'none',
      processingError: messageMap['processingError'] as String?,
      inputTokens: messageMap['inputTokens'] as int?,
      outputTokens: messageMap['outputTokens'] as int?,
      isRead: (messageMap['isRead'] as int?) ?? 0,
      deleted: (messageMap['deleted'] as int?) ?? 0,
      createTime: createTime,
      updateTime: now,
      jsonData: jsonData,
    );
  }

  /// 从Map创建（兼容旧数据，无 jsonData）
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
      jsonData: map['jsonData'] as String?,
    );
  }

  /// 还原为原始消息 Map
  ///
  /// 以 jsonData 为基础还原，然后用实体独立字段覆盖，
  /// 确保 copyWith 更新的字段（如 isRead）能正确反映到输出中。
  Map<String, dynamic> toMessageMap() {
    Map<String, dynamic> baseMap;
    if (jsonData != null && jsonData!.isNotEmpty) {
      try {
        baseMap = Map<String, dynamic>.from(
            jsonDecode(jsonData!) as Map<String, dynamic>);
      } catch (_) {
        baseMap = {};
      }
    } else {
      baseMap = {};
    }

    // 用实体独立字段覆盖，确保 copyWith 的更新生效
    baseMap['uuid'] = uuid;
    baseMap['employeeId'] = employeeId;
    baseMap['role'] = role;
    baseMap['type'] = type;
    baseMap['content'] = content;
    baseMap['toolCallId'] = toolCallId;
    baseMap['toolName'] = toolName;
    baseMap['toolArguments'] = toolArguments;
    baseMap['toolResult'] = toolResult;
    baseMap['toolCalls'] = toolCalls;
    baseMap['processingStatus'] = processingStatus;
    baseMap['processingError'] = processingError;
    baseMap['inputTokens'] = inputTokens;
    baseMap['outputTokens'] = outputTokens;
    baseMap['isRead'] = isRead;
    baseMap['deleted'] = deleted;
    baseMap['createTime'] = createTime.millisecondsSinceEpoch;
    baseMap['updateTime'] = updateTime.millisecondsSinceEpoch;
    baseMap.remove('jsonData');

    return baseMap;
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
      'jsonData': jsonData,
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
    String? jsonData,
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
      jsonData: jsonData ?? this.jsonData,
    );
  }

  @override
  String toString() {
    return 'AiEmployeeMessageEntity(uuid: $uuid, role: $role, type: $type)';
  }
}
