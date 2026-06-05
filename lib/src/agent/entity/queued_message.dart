import '../../shared/chat_message.dart';
import 'agent_message.dart';

/// 消息处理状态
enum MessageProcessingStatus {
  none, // 无状态
  queued, // 排队中
  processing, // 处理中
  retrying, // LLM 调用重试中
  completed, // 已完成
  failed, // 失败
  interrupted, // 被中断
  revoked, // 已撤回
}

/// 队列消息
///
/// 用于 MessageQueueItem 和 TrackedMessage
/// 包含消息处理状态信息
class QueuedMessage extends AgentMessage {
  /// 消息处理状态
  final MessageProcessingStatus processingStatus;

  /// 处理错误信息（如果有）
  final String? processingError;

  /// 入队时间
  final DateTime enqueuedAt;

  /// 开始处理时间（可选）
  final DateTime? startedAt;

  /// 完成时间（可选）
  final DateTime? completedAt;

  const QueuedMessage({
    required super.id,
    super.role,
    super.type,
    super.content,
    required super.createdAt,
    super.toolCallId,
    super.toolName,
    super.toolArguments,
    super.toolResult,
    super.toolCalls,
    super.metadata,
    this.processingStatus = MessageProcessingStatus.queued,
    this.processingError,
    required this.enqueuedAt,
    this.startedAt,
    this.completedAt,
  });

  /// 从 Map 创建
  factory QueuedMessage.fromMap(Map<String, dynamic> map) {
    return QueuedMessage(
      id: map['id'] as String,
      role: map['role'] as String? ?? 'user',
      type: map['type'] as String? ?? 'text',
      content: map['content'] as String?,
      createdAt: AgentMessage.parseDateTime(map['createdAt']),
      toolCallId: map['toolCallId'] as String?,
      toolName: map['toolName'] as String?,
      toolArguments: map['toolArguments'] as Map<String, dynamic>?,
      toolResult: map['toolResult'] as String?,
      toolCalls: map['toolCalls'] != null
          ? (map['toolCalls'] as List)
              .map((tc) => ToolCall.fromMap(tc as Map<String, dynamic>))
              .toList()
          : null,
      metadata: map['metadata'] as Map<String, dynamic>?,
      processingStatus: MessageProcessingStatus.values.firstWhere(
        (e) => e.name == (map['processingStatus'] as String? ?? 'queued'),
        orElse: () => MessageProcessingStatus.queued,
      ),
      processingError: map['processingError'] as String?,
      enqueuedAt: AgentMessage.parseDateTime(map['enqueuedAt'] ?? map['createdAt']),
      startedAt: map['startedAt'] != null
          ? AgentMessage.parseDateTime(map['startedAt'])
          : null,
      completedAt: map['completedAt'] != null
          ? AgentMessage.parseDateTime(map['completedAt'])
          : null,
    );
  }

  @override
  Map<String, dynamic> toMap() {
    final map = super.toMap();
    return {
      ...map,
      'processingStatus': processingStatus.name,
      if (processingError != null) 'processingError': processingError,
      'enqueuedAt': enqueuedAt.toIso8601String(),
      if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
      if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
    };
  }

  /// 更新处理状态
  QueuedMessage updateStatus(
    MessageProcessingStatus status, {
    String? error,
  }) {
    return copyWith(
      processingStatus: status,
      processingError: error,
      startedAt: status == MessageProcessingStatus.processing
          ? DateTime.now()
          : startedAt,
      completedAt: status == MessageProcessingStatus.completed ||
              status == MessageProcessingStatus.failed ||
              status == MessageProcessingStatus.interrupted
          ? DateTime.now()
          : completedAt,
    );
  }

  @override
  QueuedMessage copyWith({
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
    MessageProcessingStatus? processingStatus,
    String? processingError,
    DateTime? enqueuedAt,
    DateTime? startedAt,
    DateTime? completedAt,
  }) {
    return QueuedMessage(
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
      processingStatus: processingStatus ?? this.processingStatus,
      processingError: processingError ?? this.processingError,
      enqueuedAt: enqueuedAt ?? this.enqueuedAt,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  /// 是否排队中
  bool get isQueued => processingStatus == MessageProcessingStatus.queued;

  /// 是否处理中
  bool get isProcessing => processingStatus == MessageProcessingStatus.processing;

  /// 是否重试中
  bool get isRetrying => processingStatus == MessageProcessingStatus.retrying;

  /// 是否已完成
  bool get isCompleted => processingStatus == MessageProcessingStatus.completed;

  /// 是否失败
  bool get isFailed => processingStatus == MessageProcessingStatus.failed;

  @override
  String toString() {
    return 'QueuedMessage(id: $id, status: $processingStatus, content: ${content?.substring(0, content!.length.clamp(0, 20))})';
  }
}

/// Map 扩展方法
extension QueuedMessageMapExtension on Map<String, dynamic> {
  /// 转换为 QueuedMessage
  QueuedMessage toQueuedMessage() => QueuedMessage.fromMap(this);
}
