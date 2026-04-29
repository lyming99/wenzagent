import '../../persistence/entities/file_operation_entity.dart';

/// 构建子 Agent 的对话上下文摘要
///
/// 从主 Agent 的文件操作记录和当前消息历史中提取关键信息，
/// 生成紧凑的 Markdown 摘要，注入到子 Agent 的首条用户消息中，
/// 帮助子 Agent 避免重复已完成的工作。
class ConversationContextBuilder {
  static const int maxContextLength = 4000;
  static const int maxFileOperations = 30;
  static const int maxRecentMessages = 20;
  static const int maxToolResultLength = 200;

  /// 文件操作类工具名称（这些工具的结果已在文件操作段落中体现）
  static const _fileToolNames = {
    'file_copy',
    'file_write',
    'file_delete',
    'file_patch',
    'directory_create',
  };

  /// 构建上下文摘要
  ///
  /// [fileOperations] 文件操作记录列表
  /// [currentMessages] 当前对话消息列表（ChatMessage.toJson() 格式）
  String buildContext({
    required List<FileOperationEntity> fileOperations,
    required List<Map<String, dynamic>> currentMessages,
  }) {
    final sections = <String>[];

    // 1. 文件操作
    final fileSection = _buildFileOperationsSection(fileOperations);
    if (fileSection.isNotEmpty) {
      sections.add(fileSection);
    }

    // 2. 工具活动
    final toolSection = _buildToolActivitySection(currentMessages);
    if (toolSection.isNotEmpty) {
      sections.add(toolSection);
    }

    // 3. 对话高亮
    final convSection = _buildConversationHighlightsSection(currentMessages);
    if (convSection.isNotEmpty) {
      sections.add(convSection);
    }

    if (sections.isEmpty) return '';

    var result = sections.join('\n\n');

    // 按 token 预算截断
    if (result.length > maxContextLength) {
      result = '${result.substring(0, maxContextLength)}\n\n[...context truncated]';
    }

    return result;
  }

  /// 构建文件操作段落
  String _buildFileOperationsSection(List<FileOperationEntity> operations) {
    if (operations.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('### File Operations');
    buffer.writeln('| Action | Path | Status |');
    buffer.writeln('|--------|------|--------|');

    final ops = operations.length > maxFileOperations
        ? operations.sublist(operations.length - maxFileOperations)
        : operations;

    for (final op in ops) {
      final status = op.success ? 'OK' : 'FAIL';
      buffer.writeln('| ${op.operationType.name} | ${_escapeMarkdown(op.path)} | $status |');
    }

    return buffer.toString().trimRight();
  }

  /// 构建工具活动段落
  ///
  /// 扫描 assistant 消息的 toolCalls 和后续 tool result 消息，
  /// 排除文件操作类工具（已在文件操作段落中体现）。
  String _buildToolActivitySection(List<Map<String, dynamic>> messages) {
    final buffer = StringBuffer();
    buffer.writeln('### Tool Activity');

    // 收集 assistant 消息中的 toolCalls，并查找对应的 tool result
    final toolCallIdToResult = <String, String>{};

    // 先扫描 tool 消息收集结果
    for (final msg in messages) {
      final role = msg['role'] as String?;
      if (role != 'tool') continue;

      final toolResults = msg['toolResults'] as List<dynamic>?;
      if (toolResults != null) {
        for (final tr in toolResults) {
          final map = tr as Map<String, dynamic>;
          final callId = map['toolCallId'] as String?;
          final content = map['content'] as String?;
          if (callId != null && content != null) {
            toolCallIdToResult[callId] = content;
          }
        }
      } else {
        // 兼容旧格式：单 tool result
        final callId = msg['toolCallId'] as String?;
        final content = msg['content'] as String?;
        if (callId != null && content != null) {
          toolCallIdToResult[callId] = content;
        }
      }
    }

    // 从最近的 assistant 消息中提取 toolCalls（倒序，取最近的）
    final entries = <_ToolEntry>[];
    for (var i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      final role = msg['role'] as String?;
      if (role != 'assistant') continue;

      final toolCalls = msg['toolCalls'] as List<dynamic>?;
      if (toolCalls == null) continue;

      for (final tc in toolCalls) {
        final map = tc as Map<String, dynamic>;
        final name = map['name'] as String? ?? '';
        final args = map['arguments'] as Map<String, dynamic>? ?? {};
        final id = map['id'] as String? ?? '';

        // 跳过文件操作类工具
        if (_fileToolNames.contains(name)) continue;

        final result = toolCallIdToResult[id];
        entries.add(_ToolEntry(
          name: name,
          args: args,
          result: result,
        ));
      }
    }

    if (entries.isEmpty) {
      // 没有非文件工具活动，返回空
      return '';
    }

    // 取最近的若干条
    final recentEntries = entries.length > 10 ? entries.sublist(0, 10) : entries;

    for (final entry in recentEntries) {
      final argsSummary = _summarizeArgs(entry.args);
      if (entry.result != null) {
        final resultSummary = _summarizeResult(entry.result!);
        buffer.writeln('- `${entry.name}`($argsSummary) → $resultSummary');
      } else {
        buffer.writeln('- `${entry.name}`($argsSummary)');
      }
    }

    return buffer.toString().trimRight();
  }

  /// 构建对话高亮段落
  ///
  /// 取最近 2-3 轮用户消息和助手纯文本回复。
  String _buildConversationHighlightsSection(List<Map<String, dynamic>> messages) {
    final buffer = StringBuffer();
    buffer.writeln('### Conversation Highlights');

    // 收集最近的消息对（用户 + 助手文本）
    final highlights = <String>[];
    int roundCount = 0;
    final maxRounds = 3;

    for (var i = messages.length - 1; i >= 0 && roundCount < maxRounds; i--) {
      final msg = messages[i];
      final role = msg['role'] as String?;

      if (role == 'user') {
        final content = msg['content'] as String?;
        if (content != null && content.trim().isNotEmpty) {
          final truncated = content.length > 200
              ? '${content.substring(0, 200)}...'
              : content;
          highlights.add('**User**: $truncated');
        }
      } else if (role == 'assistant') {
        final content = msg['content'] as String?;
        final toolCalls = msg['toolCalls'] as List<dynamic>?;
        // 只取纯文本回复（有文本内容且没有 toolCalls 的）
        if (content != null && content.trim().isNotEmpty && (toolCalls == null || toolCalls.isEmpty)) {
          final truncated = content.length > 300
              ? '${content.substring(0, 300)}...'
              : content;
          highlights.add('**Assistant**: $truncated');
          roundCount++;
        }
      }
    }

    if (highlights.isEmpty) return '';

    // highlights 是倒序收集的，需要反转
    for (final h in highlights.reversed) {
      buffer.writeln(h);
    }

    return buffer.toString().trimRight();
  }

  /// 摘要工具参数
  String _summarizeArgs(Map<String, dynamic> args) {
    if (args.isEmpty) return '';
    // 取前 2 个关键参数
    final parts = <String>[];
    for (final entry in args.entries.take(2)) {
      final value = entry.value;
      if (value is String) {
        parts.add('${entry.key}=${value.length > 50 ? '${value.substring(0, 50)}...' : value}');
      } else {
        final str = value.toString();
        parts.add('${entry.key}=${str.length > 50 ? '${str.substring(0, 50)}...' : str}');
      }
    }
    return parts.join(', ');
  }

  /// 摘要工具结果
  String _summarizeResult(String result) {
    if (result.isEmpty) return '(empty)';
    // 去掉多余空白
    final trimmed = result.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.length <= maxToolResultLength) return trimmed;
    return '${trimmed.substring(0, maxToolResultLength)}...';
  }

  /// 转义 Markdown 表格中的特殊字符
  String _escapeMarkdown(String text) {
    return text.replaceAll('|', '\\|');
  }
}

/// 内部数据类，用于暂存工具调用条目
class _ToolEntry {
  final String name;
  final Map<String, dynamic> args;
  final String? result;

  const _ToolEntry({required this.name, required this.args, this.result});
}
