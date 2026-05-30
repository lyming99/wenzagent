import 'dart:convert';

import '../agent_tool.dart';

/// 查询对话历史工具
///
/// 让 AI Agent 能够检索和查询之前的对话消息（DB 中的完整原始消息，不受压缩影响）。
/// 所有查询操作通过异步回调由 AgentImpl 注入。
class QueryConversationHistoryTool extends AgentTool {
  // ===== 异步回调（由 AgentImpl 注入） =====

  /// 查询会话消息
  ///
  /// 参数：employeeId, keyword?, role?, limit, offset, beforeSeq?, afterSeq?
  /// 返回：{ messages: [...], total: int, hasMore: bool }
  Future<Map<String, dynamic>> Function({
    required String employeeId,
    String? keyword,
    String? role,
    int limit,
    int offset,
    int? beforeSeq,
    int? afterSeq,
  })? queryMessages;

  /// 当前员工 ID（由 AgentImpl 注入）
  String? employeeId;

  @override
  String get name => 'query_conversation_history';

  @override
  String get description => '查询当前会话的历史对话消息。'
      '返回 DB 中的完整原始消息，不受上下文压缩影响。'
      '支持关键词搜索、角色过滤、时间/seq 范围过滤和分页。';

  @override
  bool get requiresPermission => false;

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'keyword': {
            'type': 'string',
            'description': '关键词搜索，模糊匹配消息内容',
          },
          'role': {
            'type': 'string',
            'enum': ['user', 'assistant', 'tool', 'system'],
            'description': '按消息角色过滤',
          },
          'limit': {
            'type': 'integer',
            'description': '返回条数上限，默认 20，最大 100',
          },
          'offset': {
            'type': 'integer',
            'description': '分页偏移，默认 0',
          },
          'beforeSeq': {
            'type': 'integer',
            'description': '只返回 seq < 此值的消息（查看更早的历史）',
          },
          'afterSeq': {
            'type': 'integer',
            'description': '只返回 seq > 此值的消息',
          },
        },
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    if (employeeId == null || employeeId!.isEmpty) {
      return ToolResult.error('错误: 未设置 employeeId');
    }

    if (queryMessages == null) {
      return ToolResult.error('错误: 查询功能未初始化');
    }

    // 解析参数
    final keyword = arguments['keyword'] as String?;
    final role = arguments['role'] as String?;
    final limit = _parseInt(arguments['limit'], defaultValue: 20, max: 100);
    final offset = _parseInt(arguments['offset'], defaultValue: 0);
    final beforeSeq = arguments['beforeSeq'] as int?;
    final afterSeq = arguments['afterSeq'] as int?;

    try {
      final result = await queryMessages!(
        employeeId: employeeId!,
        keyword: keyword,
        role: role,
        limit: limit,
        offset: offset,
        beforeSeq: beforeSeq,
        afterSeq: afterSeq,
      );

      final messages = result['messages'] as List<dynamic>? ?? [];
      final total = result['total'] as int? ?? 0;
      final hasMore = result['hasMore'] as bool? ?? false;

      if (messages.isEmpty) {
        return ToolResult.success(jsonEncode({
          'messages': [],
          'total': 0,
          'hasMore': false,
          'message': '未找到匹配的历史消息',
        }));
      }

      // 精简返回内容：只保留关键字段
      final simplified = messages.map((msg) {
        final map = msg as Map<String, dynamic>;
        return {
          'seq': map['seq'],
          'role': map['role'],
          'content': _truncateContent(map['content'] as String?, 500),
          'createdAt': map['createdAt'],
        };
      }).toList();

      return ToolResult.success(jsonEncode({
        'messages': simplified,
        'total': total,
        'hasMore': hasMore,
      }));
    } catch (e) {
      return ToolResult.error('查询历史消息失败: $e');
    }
  }

  /// 安全解析整数参数
  static int _parseInt(dynamic value, {required int defaultValue, int? max}) {
    if (value == null) return defaultValue;
    final parsed = value is int ? value : int.tryParse(value.toString());
    if (parsed == null) return defaultValue;
    if (max != null && parsed > max) return max;
    return parsed < 0 ? defaultValue : parsed;
  }

  /// 截断过长内容
  static String? _truncateContent(String? content, int maxLength) {
    if (content == null) return null;
    if (content.length <= maxLength) return content;
    return '${content.substring(0, maxLength)}...';
  }
}
