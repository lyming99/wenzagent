import '../../agent/tool/agent_tool.dart';

/// Config Skill 工具适配器
///
/// 将 Type 3 Config Skill 的 prompt 模板包装为 [AgentTool]。
/// execute 时注入参数并调用 LLM invokeOnce。
class ConfigToolAdapter extends AgentTool {
  final String _name;
  final String _description;
  final Map<String, dynamic> _inputSchema;
  final bool _requiresPermission;
  final String _promptTemplate;
  final Future<String> Function(String) _invokeLlm;

  ConfigToolAdapter({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required String promptTemplate,
    bool requiresPermission = false,
    required Future<String> Function(String) invokeLlm,
  })  : _name = name,
        _description = description,
        _inputSchema = inputSchema,
        _promptTemplate = promptTemplate,
        _requiresPermission = requiresPermission,
        _invokeLlm = invokeLlm;

  @override
  String get name => _name;

  @override
  String get description => _description;

  @override
  Map<String, dynamic> get inputJsonSchema => _inputSchema;

  @override
  bool get requiresPermission => _requiresPermission;

  @override
  String get permissionType => 'config_skill';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    try {
      var prompt = _promptTemplate;
      for (final entry in arguments.entries) {
        prompt = prompt.replaceAll('{{${entry.key}}}', entry.value.toString());
      }
      final result = await _invokeLlm(prompt);
      return ToolResult.success(result);
    } catch (e) {
      return ToolResult.error('配置技能执行失败: $e');
    }
  }
}
