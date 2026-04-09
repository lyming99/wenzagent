import 'dart:io';

import '../../agent/tool/agent_tool.dart';
import '../skill.dart';
import '../skill_context.dart';
import 'folder_tool_adapter.dart';
import 'skill_md_parser.dart';

/// Type 2: Folder Skill 实现
///
/// 基于 SKILL.md 或 skill.yaml 文件定义的技能。
/// prompt 模板存储在文件系统中，execute 时动态读取。
class FolderSkill implements Skill {
  final String _path;
  final String _id;
  String? _pendingName;
  FolderSkillConfig? _config;
  List<AgentTool> _tools = [];
  SkillStatus _status = SkillStatus.uninitialized;
  SkillContext? _context;

  FolderSkill({required String path, required String id, String? name})
      : _path = path,
        _id = id,
        _pendingName = name;

  @override
  String get id => _id;

  @override
  String get name => _config?.name ?? _pendingName ?? _path.split(Platform.pathSeparator).last;

  @override
  String get description => _config?.description ?? '';

  @override
  SkillType get type => SkillType.folder;

  @override
  SkillStatus get status => _status;

  @override
  List<AgentTool> get tools => _tools;

  /// 设置技能上下文（initialize 之前调用）
  void setContext(SkillContext context) => _context = context;

  @override
  Future<void> initialize() async {
    _status = SkillStatus.initializing;
    try {
      final config = await _loadConfig();
      _config = config;
      _tools = config.tools.map((toolDef) => FolderToolAdapter(
            skillPath: _path,
            toolDef: toolDef,
            promptBody: config.promptBody,
            invokeLlm: _context!.invokeLlm,
          )).toList();
      _status = SkillStatus.active;
    } catch (e) {
      _status = SkillStatus.error;
      rethrow;
    }
  }

  /// 加载配置 —— 兼容 SKILL.md、skill.yaml
  Future<FolderSkillConfig> _loadConfig() async {
    final skillMd = File('$_path${Platform.pathSeparator}SKILL.md');
    final skillYaml = File('$_path${Platform.pathSeparator}skill.yaml');

    if (await skillMd.exists()) {
      final content = await skillMd.readAsString();
      final doc = SkillMdParser.parse(content);
      return FolderSkillConfig.fromDocument(doc, _path);
    }
    if (await skillYaml.exists()) {
      final content = await skillYaml.readAsString();
      final doc = SkillMdParser.parse(content);
      return FolderSkillConfig.fromDocument(doc, _path);
    }

    throw FileSystemException('缺少入口文件（SKILL.md 或 skill.yaml）', _path);
  }

  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {}

  @override
  Future<void> dispose() async {
    _tools.clear();
    _status = SkillStatus.disposed;
  }

  @override
  Future<bool> healthCheck() async =>
      await File('$_path${Platform.pathSeparator}SKILL.md').exists() ||
      await File('$_path${Platform.pathSeparator}skill.yaml').exists();
}
