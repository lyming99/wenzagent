import 'dart:convert';

import '../../agent/tool/agent_tool.dart';
import '../../persistence/entities/skill_entity.dart';
import '../skill.dart';
import '../skill_context.dart';
import 'config_tool_adapter.dart';

/// Type 3: Config Skill 实现
///
/// 最轻量的技能类型 —— 一个数据库配置 = 一个工具，无需文件系统。
/// prompt 模板存储在 AiEmployeeSkillEntity.config 字段中，
/// execute 时注入参数并调用 LLM invokeOnce。
class ConfigSkill implements Skill {
  final String _id;
  final String _name;
  final String _description;
  final String _promptTemplate;
  final Map<String, dynamic> _parameters;
  final bool _requiresPermission;

  SkillStatus _status = SkillStatus.uninitialized;
  late ConfigToolAdapter _tool;
  SkillContext? _context;

  ConfigSkill({
    required String id,
    required String name,
    required String description,
    required String promptTemplate,
    Map<String, dynamic> parameters = const {},
    bool requiresPermission = false,
  })  : _id = id,
        _name = name,
        _description = description,
        _promptTemplate = promptTemplate,
        _parameters = parameters,
        _requiresPermission = requiresPermission;

  @override
  String get id => _id;

  @override
  String get name => _name;

  @override
  String get description => _description;

  @override
  SkillType get type => SkillType.config;

  @override
  SkillStatus get status => _status;

  @override
  List<AgentTool> get tools => [_tool];

  /// 设置技能上下文（initialize 之前调用）
  void setContext(SkillContext context) => _context = context;

  @override
  Future<void> initialize() async {
    _status = SkillStatus.initializing;
    _tool = ConfigToolAdapter(
      name: 'cfg_${_id.substring(0, 8)}',
      description: _description,
      inputSchema: _parameters,
      promptTemplate: _promptTemplate,
      requiresPermission: _requiresPermission,
      invokeLlm: _context!.invokeLlm,
    );
    _status = SkillStatus.active;
  }

  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {}

  @override
  Future<void> dispose() async {
    _status = SkillStatus.disposed;
  }

  @override
  Future<bool> healthCheck() async => _status == SkillStatus.active;

  /// 从 AiEmployeeSkillEntity 创建
  ///
  /// config 格式：
  /// ```json
  /// {
  ///   "prompt": "你是一位专业翻译...",
  ///   "parameters": { "type": "object", ... },
  ///   "requires_permission": false
  /// }
  /// ```
  static ConfigSkill fromEntity(AiEmployeeSkillEntity entity) {
    final configMap = entity.config != null && entity.config!.isNotEmpty
        ? jsonDecode(entity.config!) as Map<String, dynamic>
        : <String, dynamic>{};

    return ConfigSkill(
      id: entity.uuid,
      name: entity.name,
      description: entity.description ?? '',
      promptTemplate: configMap['prompt'] as String? ?? '',
      parameters: Map<String, dynamic>.from(configMap['parameters'] ?? {}),
      requiresPermission: configMap['requires_permission'] as bool? ?? false,
    );
  }
}
