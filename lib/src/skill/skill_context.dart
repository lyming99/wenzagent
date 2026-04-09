import '../agent/tool/tool_registry.dart';

/// 技能上下文 —— 提供技能运行所需的共享资源
///
/// 通过 [invokeLlm] 将 Type 2/Type 3 的 prompt 交给 LLM 处理。
/// 该回调来自 LangChainChatAdapter.invokeOnce()。
class SkillContext {
  /// 工具注册器
  final ToolRegistry toolRegistry;

  /// 员工ID
  final String employeeId;

  /// 一次性 LLM 调用（不保留对话历史）
  ///
  /// Type 2/Type 3 的工具执行时使用
  final Future<String> Function(String prompt) invokeLlm;

  /// 日志回调
  final void Function(String level, String message) logger;

  SkillContext({
    required this.toolRegistry,
    required this.employeeId,
    required this.invokeLlm,
    required this.logger,
  });
}
