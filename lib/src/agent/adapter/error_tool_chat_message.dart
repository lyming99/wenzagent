import 'package:langchain_core/chat_models.dart';

/// 支持错误状态标记的工具消息
///
/// 继承 [ToolChatMessage]，额外携带 [isError] 字段，
/// 用于将工具执行错误传播到 LLM API（如 Anthropic 的 tool_result.is_error）。
///
/// 当 [isError] 为 true 时，自定义的 Anthropic ChatModel
/// 会将此标记映射到 API 的 is_error 字段，使 Claude 能正确
/// 识别工具调用失败，避免死循环重试。
class ErrorToolChatMessage extends ToolChatMessage {
  /// 是否为错误结果
  final bool isError;

  ErrorToolChatMessage({
    required super.toolCallId,
    required super.content,
    this.isError = false,
  });
}
