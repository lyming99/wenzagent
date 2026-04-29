/// 数据库行映射 + ChatMessage 转换器
///
/// [MessageRecord] 对应 messages 表的一行（不含 jsonData），
/// [MessageMapper] 负责 ChatMessage ↔ MessageRecord 的双向转换，
/// 并提供 ChatMessage ↔ SQLite Row 参数的便捷方法。
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../utils/logger.dart';
import 'chat_message.dart';

final _log = Logger('MessageMapper');

// ──────────────────────────────────────────────
// MessageRecord —— 数据库行 1:1 映射
// ──────────────────────────────────────────────

/// 数据库 messages 表的行表示
///
/// 所有字段类型与 SQLite 列一一对应：
/// - TEXT → String?
/// - INTEGER → int / bool
/// - 不再包含 jsonData（将在 v4 迁移中移除）
///
/// 纯数据容器，不含业务逻辑。
class MessageRecord {
  final String uuid;
  final String employeeId;
  final String role;
  final String type;
  final String? content;
  final String? toolCallId;
  final String? toolName;
  final String? toolArguments; // JSON String
  final String? toolResult;
  final String? toolCalls; // JSON String
  final String processingStatus;
  final String? processingError;
  final int? inputTokens;
  final int? outputTokens;
  final int isRead; // 0 or 1
  final String? metadata; // JSON String
  final int deleted; // 0 or 1
  final int createTime; // millisecondsSinceEpoch
  final int updateTime; // millisecondsSinceEpoch
  final int seq;

  const MessageRecord({
    required this.uuid,
    required this.employeeId,
    required this.role,
    required this.type,
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
    this.metadata,
    this.deleted = 0,
    required this.createTime,
    required this.updateTime,
    this.seq = 0,
  });
}

// ──────────────────────────────────────────────
// MessageMapper —— ChatMessage ↔ DB
// ──────────────────────────────────────────────

/// ChatMessage 与 MessageRecord / SQLite Row 的双向映射器
///
/// 集中所有 DB 层转换逻辑，替代原来分散在 MessageStore、
/// CachedAgentProxy、DeviceAgentManager 中的 ~200 行转换代码。
class MessageMapper {
  // ── ChatMessage → MessageRecord ──

  /// 将 ChatMessage 转换为数据库行表示
  static MessageRecord toRecord(ChatMessage msg) {
    return MessageRecord(
      uuid: msg.id,
      employeeId: msg.employeeId,
      role: msg.role.name,
      type: msg.type,
      content: msg.content,
      toolCallId: msg.toolCallId,
      toolName: msg.toolName,
      toolArguments: msg.toolArguments != null
          ? jsonEncode(msg.toolArguments)
          : null,
      toolResult: msg.toolResult,
      toolCalls: msg.toolCalls != null && msg.toolCalls!.isNotEmpty
          ? jsonEncode(msg.toolCalls!.map((tc) => tc.toMap()).toList())
          : null,
      processingStatus: msg.status.name,
      processingError: msg.processingError,
      inputTokens: msg.inputTokens,
      outputTokens: msg.outputTokens,
      isRead: msg.isRead ? 1 : 0,
      metadata: msg.metadata != null && msg.metadata!.isNotEmpty
          ? jsonEncode(msg.metadata)
          : null,
      deleted: msg.deleted ? 1 : 0,
      createTime: msg.createdAt.millisecondsSinceEpoch,
      updateTime: (msg.updatedAt ?? msg.createdAt).millisecondsSinceEpoch,
      seq: msg.seq,
    );
  }

  /// 将 ChatMessage 转换为 SQL INSERT/REPLACE 参数列表
  ///
  /// 参数顺序与 messages 表列顺序一致（含 device_id）。
  static List<Object?> toSqlParams(ChatMessage msg, {String deviceId = ''}) {
    final record = toRecord(msg);
    return [
      record.uuid,
      record.employeeId,
      deviceId,
      record.role,
      record.type,
      record.content,
      record.toolCallId,
      record.toolName,
      record.toolArguments,
      record.toolResult,
      record.toolCalls,
      record.processingStatus,
      record.processingError,
      record.inputTokens,
      record.outputTokens,
      record.isRead,
      record.metadata,
      record.deleted,
      record.createTime,
      record.updateTime,
      record.seq,
    ];
  }

  // ── MessageRecord / Row → ChatMessage ──

  /// 从 SQLite Row 直接创建 ChatMessage
  static ChatMessage fromRow(Row row) {
    return ChatMessage(
      id: row['uuid'] as String,
      employeeId: row['employee_id'] as String,
      role: MessageRole.fromString(row['role'] as String? ?? 'user'),
      type: row['type'] as String? ?? 'text',
      content: row['content'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          row['create_time'] as int? ?? 0),
      updatedAt: (row['update_time'] as int?) != null
          ? DateTime.fromMillisecondsSinceEpoch(row['update_time'] as int)
          : null,
      toolCallId: row['tool_call_id'] as String?,
      toolName: row['tool_name'] as String?,
      toolArguments: _parseJsonMap(row['tool_arguments']),
      toolResult: row['tool_result'] as String?,
      toolCalls: _parseToolCalls(row['tool_calls']),
      status: MessageStatus.fromString(row['processing_status'] as String? ?? 'none'),
      processingError: row['processing_error'] as String?,
      seq: row['seq'] as int? ?? 0,
      deleted: (row['deleted'] as int? ?? 0) != 0,
      isRead: (row['is_read'] as int? ?? 0) != 0,
      metadata: _parseJsonMap(row['metadata']),
      inputTokens: row['input_tokens'] as int?,
      outputTokens: row['output_tokens'] as int?,
    );
  }

  /// 从 MessageRecord 创建 ChatMessage
  static ChatMessage fromRecord(MessageRecord record) {
    return ChatMessage(
      id: record.uuid,
      employeeId: record.employeeId,
      role: MessageRole.fromString(record.role),
      type: record.type,
      content: record.content,
      createdAt: DateTime.fromMillisecondsSinceEpoch(record.createTime),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(record.updateTime),
      toolCallId: record.toolCallId,
      toolName: record.toolName,
      toolArguments: _parseJsonMap(record.toolArguments),
      toolResult: record.toolResult,
      toolCalls: _parseToolCalls(record.toolCalls),
      status: MessageStatus.fromString(record.processingStatus),
      processingError: record.processingError,
      seq: record.seq,
      deleted: record.deleted != 0,
      isRead: record.isRead != 0,
      metadata: _parseJsonMap(record.metadata),
      inputTokens: record.inputTokens,
      outputTokens: record.outputTokens,
    );
  }

  // ── 内部解析工具 ──

  /// 解析 JSON String → Map，兼容已是 Map 的情况
  static Map<String, dynamic>? _parseJsonMap(dynamic value) {
    if (value == null) return null;
    if (value is Map<String, dynamic>) return value;
    if (value is String && value.isNotEmpty) {
      try {
        return jsonDecode(value) as Map<String, dynamic>;
      } catch (e) {
        _log.debug('parse JSON map failed, returning null: $e');
        return null;
      }
    }
    return null;
  }

  /// 解析 JSON String → [List] of [ToolCall]
  static List<ToolCall>? _parseToolCalls(dynamic value) {
    if (value == null) return null;
    final parsed = ToolCall.parseList(value);
    return parsed.isEmpty ? null : parsed;
  }
}
