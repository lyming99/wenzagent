/// 统一消息模型 —— 全项目单一真相源
///
/// 消除 AgentMessage / QueuedMessage
/// / PendingMessage / MessageWrapper 五种表示，所有层共享同一类型。
library;

import 'dart:convert';

// ──────────────────────────────────────────────
// 枚举
// ──────────────────────────────────────────────

/// 消息角色（强类型替代 String）
enum MessageRole {
  user,
  assistant,
  system,
  tool,
  ;

  /// 兼容旧数据反序列化
  static MessageRole fromString(String value) {
    return MessageRole.values.firstWhere(
      (e) => e.name == value,
      orElse: () => MessageRole.user,
    );
  }
}

/// 消息处理状态（合并 QueuedMessage.MessageProcessingStatus
/// + PendingMessage.PendingMessageStatus）
enum MessageStatus {
  /// 无状态（默认，已确认的持久化消息）
  none,

  /// 排队中
  queued,

  /// 处理中
  processing,

  /// 已完成
  completed,

  /// 失败
  failed,

  /// 被中断
  interrupted,

  /// 已撤回
  revoked,

  /// 待确认（仅 PendingMessage 场景）
  pending,

  /// 发送失败（仅 PendingMessage 场景）
  sendFailed,

  /// 已确认（仅 PendingMessage 场景）
  confirmed,
  ;

  static MessageStatus fromString(String value) {
    return MessageStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => MessageStatus.none,
    );
  }
}

// ──────────────────────────────────────────────
// 工具调用 & 结果
// ──────────────────────────────────────────────

/// 统一的工具调用表示
///
/// 统一的工具调用表示，内部同时保留 Map 和 JSON 字符串形式，
/// 避免运行时反复编解码。
class ToolCall {
  final String id;
  final String name;

  /// 工具参数（Map 形式，业务层使用）
  final Map<String, dynamic> arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  /// 工具参数（JSON 字符串形式，序列化/LLM 层使用）
  String get argumentsJson => jsonEncode(arguments);

  /// 从 Map 创建
  factory ToolCall.fromMap(Map<String, dynamic> map) {
    final args = map['arguments'];
    return ToolCall(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      arguments: args is Map<String, dynamic>
          ? args
          : args is String
              ? (jsonDecode(args) as Map<String, dynamic>)
              : <String, dynamic>{},
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'arguments': arguments,
      };

  /// 从 JSON 字符串列表解析
  static List<ToolCall> parseList(dynamic raw) {
    if (raw == null) return [];
    if (raw is String && raw.isNotEmpty) {
      final list = jsonDecode(raw) as List;
      return list.map((e) => ToolCall.fromMap(e as Map<String, dynamic>)).toList();
    }
    if (raw is List) {
      return raw
          .map((e) => ToolCall.fromMap(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolCall && id == other.id && name == other.name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// 统一的工具执行结果
///
/// 统一的工具执行结果表示。
class ToolResult {
  final String toolCallId;
  final String content;
  final bool isError;
  final String? name;

  const ToolResult({
    required this.toolCallId,
    required this.content,
    this.isError = false,
    this.name,
  });

  /// 创建成功结果
  factory ToolResult.success(String toolCallId, String content, {String? name}) {
    return ToolResult(toolCallId: toolCallId, content: content, name: name);
  }

  /// 创建错误结果
  factory ToolResult.error(String toolCallId, String content, {String? name}) {
    return ToolResult(toolCallId: toolCallId, content: content, isError: true, name: name);
  }

  factory ToolResult.fromMap(Map<String, dynamic> map) {
    return ToolResult(
      toolCallId: map['toolCallId'] as String? ?? '',
      content: map['content'] as String? ?? '',
      isError: map['isError'] as bool? ?? false,
      name: map['name'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
        'toolCallId': toolCallId,
        'content': content,
        if (isError) 'isError': true,
        if (name != null) 'name': name,
      };

  /// 从 JSON 字符串列表解析
  static List<ToolResult> parseList(dynamic raw) {
    if (raw == null) return [];
    if (raw is String && raw.isNotEmpty) {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => ToolResult.fromMap(e as Map<String, dynamic>))
          .toList();
    }
    if (raw is List) {
      return raw
          .map((e) => ToolResult.fromMap(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }
}

// ──────────────────────────────────────────────
// ChatMessage —— 统一消息模型
// ──────────────────────────────────────────────

/// 全项目统一的聊天消息类型
///
/// ### 设计原则
/// - **单一真相源**：同一个概念只在一个地方定义
/// - **强类型**：用枚举替代 String，消除运行时类型检查
/// - **系统字段提升**：原 metadata 中的 seq/deleted/updateTime/deviceId
///   提升为一级字段，metadata 仅存用户自定义数据
/// - **向后兼容**：fromJson 支持旧数据格式（uuid/id/messageId 混用等）
class ChatMessage {
  // ── 核心身份字段 ──

  /// 消息唯一 ID（统一 uuid/id/messageId）
  final String id;

  /// 所属会话/员工 ID
  final String employeeId;

  /// 消息角色
  final MessageRole role;

  /// 消息类型 (text/functionCall/functionResult)
  final String type;

  /// 消息文本内容
  final String? content;

  // ── Extended Thinking 字段 ──

  /// LLM 扩展思考内容（Anthropic Extended Thinking 模式下返回的 thinking）
  ///
  /// 当 assistant 回复包含 thinking 内容时，Anthropic API 要求在下一次请求中
  /// 将完整的 thinking 内容原样回传，否则会报错。
  /// 此字段用于持久化 thinking 内容，确保 tool calling 循环中不丢失。
  final String? thinking;

  // ── 时间字段 ──

  /// 创建时间
  final DateTime createdAt;

  /// 更新时间
  final DateTime? updatedAt;

  // ── 工具相关字段 ──

  /// 单条工具调用 ID（向后兼容单工具调用场景）
  final String? toolCallId;

  /// 单条工具名称
  final String? toolName;

  /// 单条工具参数
  final Map<String, dynamic>? toolArguments;

  /// 单条工具结果
  final String? toolResult;

  /// 多工具调用列表（assistant 消息包含多个 tool_calls）
  final List<ToolCall>? toolCalls;

  /// 分组工具结果（一轮工具调用的多个结果合并）
  final List<ToolResult>? toolResults;

  // ── 处理状态 ──

  /// 消息处理状态
  final MessageStatus status;

  /// 处理错误信息
  final String? processingError;

  // ── 持久化 & 同步字段 ──

  /// 递增序列号（LSN），用于增量同步。仅 DB 层赋值。
  final int seq;

  /// 软删除标记
  final bool deleted;

  /// 是否已读
  final bool isRead;

  /// 输入 token 数
  final int? inputTokens;

  /// 输出 token 数
  final int? outputTokens;

  // ── 设备 & 传输字段 ──

  /// 设备 ID（可选，多设备场景）
  final String? deviceId;

  /// 用户自定义元数据（不再充当垃圾桶）
  final Map<String, dynamic>? metadata;

  const ChatMessage({
    required this.id,
    required this.employeeId,
    required this.role,
    this.type = 'text',
    this.content,
    required this.createdAt,
    this.updatedAt,
    this.toolCallId,
    this.toolName,
    this.toolArguments,
    this.toolResult,
    this.toolCalls,
    this.toolResults,
    this.status = MessageStatus.none,
    this.processingError,
    this.seq = 0,
    this.deleted = false,
    this.isRead = false,
    this.inputTokens,
    this.outputTokens,
    this.deviceId,
    this.metadata,
    this.thinking,
  });

  // ── 便捷构造函数 ──

  factory ChatMessage.user({
    required String id,
    required String employeeId,
    required String content,
    DateTime? createdAt,
    String? deviceId,
    Map<String, dynamic>? metadata,
  }) {
    return ChatMessage(
      id: id,
      employeeId: employeeId,
      role: MessageRole.user,
      content: content,
      createdAt: createdAt ?? DateTime.now(),
      deviceId: deviceId,
      metadata: metadata,
    );
  }

  factory ChatMessage.assistant({
    required String id,
    required String employeeId,
    required String content,
    DateTime? createdAt,
    List<ToolCall>? toolCalls,
    String? deviceId,
    Map<String, dynamic>? metadata,
    String? thinking,
  }) {
    return ChatMessage(
      id: id,
      employeeId: employeeId,
      role: MessageRole.assistant,
      content: content,
      createdAt: createdAt ?? DateTime.now(),
      type: toolCalls != null && toolCalls.isNotEmpty ? 'functionCall' : 'text',
      toolCalls: toolCalls,
      deviceId: deviceId,
      metadata: metadata,
      thinking: thinking,
    );
  }

  factory ChatMessage.system({
    required String id,
    required String employeeId,
    required String content,
    DateTime? createdAt,
    String? deviceId,
  }) {
    return ChatMessage(
      id: id,
      employeeId: employeeId,
      role: MessageRole.system,
      content: content,
      createdAt: createdAt ?? DateTime.now(),
      deviceId: deviceId,
    );
  }

  /// 单条工具结果
  factory ChatMessage.toolResult({
    required String id,
    required String employeeId,
    required String toolCallId,
    required String content,
    DateTime? createdAt,
    bool isError = false,
    String? toolName,
    String? deviceId,
  }) {
    return ChatMessage(
      id: id,
      employeeId: employeeId,
      role: MessageRole.tool,
      type: 'functionResult',
      content: content,
      createdAt: createdAt ?? DateTime.now(),
      toolCallId: toolCallId,
      toolName: toolName,
      toolResult: content,
      metadata: isError ? {'isError': true} : null,
      deviceId: deviceId,
    );
  }

  /// 分组工具结果（一轮调用的多个结果合并为一条消息）
  factory ChatMessage.toolResultGroup({
    required String id,
    required String employeeId,
    required List<ToolResult> results,
    DateTime? createdAt,
    String? deviceId,
  }) {
    return ChatMessage(
      id: id,
      employeeId: employeeId,
      role: MessageRole.tool,
      type: 'functionResult',
      content: results.map((r) => r.content).join('\n'),
      createdAt: createdAt ?? DateTime.now(),
      toolResults: results,
      deviceId: deviceId,
    );
  }

  /// 文件消息
  ///
  /// [role] 区分发送方（user / assistant）。
  /// [type] 固定为 `'file'`，文件元信息存入 [metadata]。
  factory ChatMessage.file({
    required String id,
    required String employeeId,
    required MessageRole role,
    required String fileName,
    required int fileSize,
    required String fileId,
    required String fileHash,
    required String filePath,
    String? fromDeviceId,
    String? mimeType,
    DateTime? createdAt,
    String? deviceId,
  }) {
    return ChatMessage(
      id: id,
      employeeId: employeeId,
      role: role,
      type: 'file',
      content: fileName,
      createdAt: createdAt ?? DateTime.now(),
      deviceId: deviceId,
      metadata: {
        'fileId': fileId,
        'fileName': fileName,
        'fileSize': fileSize,
        'fileHash': fileHash,
        'filePath': filePath,
        if (fromDeviceId != null) 'fromDeviceId': fromDeviceId,
        if (mimeType != null) 'mimeType': mimeType,
      },
    );
  }

  // ── 序列化 ──

  /// 转换为 JSON Map（用于网络传输 / 持久化）
  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'id': id,
      'employeeId': employeeId,
      'role': role.name,
      'type': type,
      if (content != null) 'content': content,
      'createdAt': createdAt.toIso8601String(),
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    };

    // 工具字段
    if (toolCallId != null) map['toolCallId'] = toolCallId;
    if (toolName != null) map['toolName'] = toolName;
    if (toolArguments != null) map['toolArguments'] = toolArguments;
    if (toolResult != null) map['toolResult'] = toolResult;
    if (toolCalls != null && toolCalls!.isNotEmpty) {
      map['toolCalls'] = toolCalls!.map((tc) => tc.toMap()).toList();
    }
    if (toolResults != null && toolResults!.isNotEmpty) {
      map['toolResults'] = toolResults!.map((r) => r.toMap()).toList();
    }

    // 状态字段
    if (status != MessageStatus.none) map['status'] = status.name;
    if (processingError != null) map['processingError'] = processingError;

    // 持久化字段（网络传输时通常不含这些）
    if (seq > 0) map['seq'] = seq;
    if (deleted) map['deleted'] = true;
    if (isRead) map['isRead'] = true;
    if (inputTokens != null) map['inputTokens'] = inputTokens;
    if (outputTokens != null) map['outputTokens'] = outputTokens;

    // 设备 & 元数据
    if (deviceId != null) map['deviceId'] = deviceId;
    if (metadata != null && metadata!.isNotEmpty) map['metadata'] = metadata;

    // Extended Thinking 字段
    if (thinking != null && thinking!.isNotEmpty) map['thinking'] = thinking;

    return map;
  }

  /// 从 JSON Map 创建（兼容旧数据格式）
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    // 兼容多种 ID 字段名
    final id = (json['id'] ?? json['uuid'] ?? json['messageId'] ?? '') as String;
    final employeeId = (json['employeeId'] ?? json['session_id'] ?? '') as String;

    // 兼容多种时间格式
    final createdAt = _parseDateTime(json['createdAt'] ?? json['createTime']);
    final updatedAt = _parseDateTime(json['updatedAt'] ?? json['updateTime']);

    // 兼容 role 为 String 或 MessageRole
    final roleRaw = json['role'];
    final role = roleRaw is MessageRole
        ? roleRaw
        : MessageRole.fromString(roleRaw as String? ?? 'user');

    // 兼容 status 为 String 或 MessageStatus
    final statusRaw = json['status'] ?? json['processingStatus'];
    final status = statusRaw is MessageStatus
        ? statusRaw
        : MessageStatus.fromString(statusRaw as String? ?? 'none');

    // 兼容 deleted 为 int 或 bool
    final deletedRaw = json['deleted'];
    final deleted = deletedRaw is bool
        ? deletedRaw
        : (deletedRaw is int ? deletedRaw != 0 : false);

    // 兼容 isRead 为 int 或 bool
    final isReadRaw = json['isRead'];
    final isRead = isReadRaw is bool
        ? isReadRaw
        : (isReadRaw is int ? isReadRaw != 0 : false);

    // 合并 toolResults：优先取 map 顶层的 toolResults
    Map<String, dynamic>? metadata = json['metadata'] as Map<String, dynamic>?;
    List<ToolResult>? toolResults;
    if (json['toolResults'] != null) {
      toolResults = ToolResult.parseList(json['toolResults']);
      // 如果 metadata 中也有 toolResults，清除（避免重复）
      metadata?.remove('toolResults');
    }

    // 工具调用列表
    List<ToolCall>? toolCalls;
    if (json['toolCalls'] != null) {
      toolCalls = ToolCall.parseList(json['toolCalls']);
    }

    return ChatMessage(
      id: id,
      employeeId: employeeId,
      role: role,
      type: json['type'] as String? ?? 'text',
      content: json['content'] as String?,
      createdAt: createdAt,
      updatedAt: updatedAt,
      toolCallId: json['toolCallId'] as String?,
      toolName: json['toolName'] as String?,
      toolArguments: json['toolArguments'] as Map<String, dynamic>?,
      toolResult: json['toolResult'] as String?,
      toolCalls: toolCalls,
      toolResults: toolResults,
      status: status,
      processingError: json['processingError'] as String?,
      seq: json['seq'] as int? ?? 0,
      deleted: deleted,
      isRead: isRead,
      inputTokens: json['inputTokens'] as int?,
      outputTokens: json['outputTokens'] as int?,
      deviceId: json['deviceId'] as String?,
      metadata: metadata,
      thinking: json['thinking'] as String?,
    );
  }

  /// 深拷贝 + 字段更新
  ChatMessage copyWith({
    String? id,
    String? employeeId,
    MessageRole? role,
    String? type,
    String? content,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? toolCallId,
    String? toolName,
    Map<String, dynamic>? toolArguments,
    String? toolResult,
    List<ToolCall>? toolCalls,
    List<ToolResult>? toolResults,
    MessageStatus? status,
    String? processingError,
    int? seq,
    bool? deleted,
    bool? isRead,
    int? inputTokens,
    int? outputTokens,
    String? deviceId,
    Map<String, dynamic>? metadata,
    String? thinking,
    // 清除 nullable 字段用
    bool clearUpdatedAt = false,
    bool clearToolCallId = false,
    bool clearToolName = false,
    bool clearToolArguments = false,
    bool clearToolResult = false,
    bool clearToolCalls = false,
    bool clearToolResults = false,
    bool clearProcessingError = false,
    bool clearInputTokens = false,
    bool clearOutputTokens = false,
    bool clearDeviceId = false,
    bool clearMetadata = false,
    bool clearThinking = false,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      employeeId: employeeId ?? this.employeeId,
      role: role ?? this.role,
      type: type ?? this.type,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: clearUpdatedAt ? null : (updatedAt ?? this.updatedAt),
      toolCallId: clearToolCallId ? null : (toolCallId ?? this.toolCallId),
      toolName: clearToolName ? null : (toolName ?? this.toolName),
      toolArguments:
          clearToolArguments ? null : (toolArguments ?? this.toolArguments),
      toolResult: clearToolResult ? null : (toolResult ?? this.toolResult),
      toolCalls: clearToolCalls ? null : (toolCalls ?? this.toolCalls),
      toolResults: clearToolResults ? null : (toolResults ?? this.toolResults),
      status: status ?? this.status,
      processingError: clearProcessingError
          ? null
          : (processingError ?? this.processingError),
      seq: seq ?? this.seq,
      deleted: deleted ?? this.deleted,
      isRead: isRead ?? this.isRead,
      inputTokens: clearInputTokens ? null : (inputTokens ?? this.inputTokens),
      outputTokens:
          clearOutputTokens ? null : (outputTokens ?? this.outputTokens),
      deviceId: clearDeviceId ? null : (deviceId ?? this.deviceId),
      metadata: clearMetadata ? null : (metadata ?? this.metadata),
      thinking: clearThinking ? null : (thinking ?? this.thinking),
    );
  }

  // ── 便捷 getter ──

  /// 是否为分组 tool result 消息
  bool get isToolResultGroup =>
      role == MessageRole.tool &&
      toolResults != null &&
      toolResults!.isNotEmpty;

  /// 是否为错误结果
  bool get isError =>
      role == MessageRole.tool &&
      (metadata?['isError'] == true ||
          (processingError != null && processingError!.isNotEmpty));

  /// 是否已软删除
  bool get isDeleted => deleted;

  @override
  String toString() {
    final preview =
        content != null && content!.length > 20
            ? '${content!.substring(0, 20)}...'
            : content;
    return 'ChatMessage(id: $id, role: ${role.name}, status: ${status.name}, content: $preview)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage && id == other.id && seq == other.seq;

  @override
  int get hashCode => Object.hash(id, seq);

  // ── 内部工具 ──

  static DateTime _parseDateTime(dynamic value) {
    if (value is DateTime) return value;
    if (value is String && value.isNotEmpty) return DateTime.parse(value);
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return DateTime.now();
  }
}
