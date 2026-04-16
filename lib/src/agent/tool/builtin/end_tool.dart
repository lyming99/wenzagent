import '../agent_tool.dart';

/// 结束对话工具
///
/// 允许 AI 主动结束工具调用循环，避免无意义的重复调用。
/// 当 AI 认为当前任务已完成、无需继续操作时，应调用此工具。
class EndTool extends AgentTool {
  @override
  String get name => 'end';

  @override
  String get description => '''
结束当前对话循环，并返回结果。

在以下情况调用此工具：
- 任务已完成，无需进一步操作。
- 如果已有执行结果，通过content输出。

''';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'reason': {
        'type': 'string',
        'description': '可选的结束原因说明（例如："任务完成"、"用户问题已回答"）',
      },
      'content': {
        'type': 'string',
        'description': '任务结果，例如方案，任务书，规格书，计划书，用户问题的答案等等',
      },
    },
    'required': [],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final content = arguments['content'] as String? ?? '';
    final reason = arguments['reason'] as String? ?? '';
    final message = content.isNotEmpty ? content : '对话已结束: $reason';
    return ToolResult.success(message);
  }
}
