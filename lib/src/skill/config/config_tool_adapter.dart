import '../../agent/tool/agent_tool.dart';
import '../../utils/logger.dart';

final _log = Logger('ConfigToolAdapter');

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
  String get name {
    if (_name.trim().isEmpty) {
      _log.warn('Config Skill 工具名称为空, 使用 fallback');
      return 'config_unnamed_${hashCode.toRadixString(36)}';
    }
    return _name;
  }

  @override
  String get description {
    return _description.isEmpty ? 'Config skill tool: $_name' : _description;
  }

  @override
  Map<String, dynamic> get inputJsonSchema {
    // 防御性校验：空 schema 时提供默认空参数 schema
    if (_inputSchema.isEmpty) {
      _log.debug('Config Skill 工具 "$_name" 的 inputSchema 为空, '
          '使用默认空参数 schema');
      return const {'type': 'object', 'properties': <String, dynamic>{}};
    }
    // 防御性校验：确保 schema 有 type 字段
    if (_inputSchema['type'] == null) {
      _log.debug('Config Skill 工具 "$_name" 的 inputSchema 缺少 "type" 字段, '
          '补充为 "object"');
      return {'type': 'object', ..._inputSchema};
    }
    return _inputSchema;
  }

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
