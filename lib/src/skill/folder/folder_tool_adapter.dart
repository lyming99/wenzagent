import 'dart:io';

import '../../agent/tool/agent_tool.dart';
import 'skill_md_parser.dart';

/// Folder Skill 工具定义
class FolderToolDef {
  final String name;
  final String description;
  final String? promptFile;
  final String? resourceFile;
  final bool requiresPermission;
  final Map<String, dynamic> parameters;

  const FolderToolDef({
    required this.name,
    required this.description,
    this.promptFile,
    this.resourceFile,
    this.requiresPermission = false,
    this.parameters = const {},
  });

  factory FolderToolDef.fromMap(Map<String, dynamic> map) {
    return FolderToolDef(
      name: map['name'] as String? ?? '',
      description: map['description'] as String? ?? '',
      promptFile: map['prompt_file'] as String? ?? map['prompt'] as String?,
      resourceFile:
          map['resource_file'] as String? ?? map['resource'] as String?,
      requiresPermission:
          map['requires_permission'] as bool? ?? map['requiresPermission'] as bool? ?? false,
      parameters: Map<String, dynamic>.from(map['parameters'] ?? {}),
    );
  }
}

/// Folder Skill 配置
class FolderSkillConfig {
  final String name;
  final String description;
  final List<FolderToolDef> tools;
  final String promptBody;

  const FolderSkillConfig({
    required this.name,
    required this.description,
    required this.tools,
    this.promptBody = '',
  });

  /// 从解析后的 SKILL.md 文档创建
  factory FolderSkillConfig.fromDocument(SkillMdDocument doc, String folderPath) {
    final fm = doc.frontmatter;

    // 纯 Markdown：自动推断
    if (doc.isRawMarkdown) {
      final dirName = folderPath.replaceAll('\\', '/').split('/').last;
      final lines = doc.body.split('\n');
      final firstHeading = lines
          .where((l) => l.trimLeft().startsWith('#'))
          .firstOrNull
          ?.replaceFirst(RegExp(r'^\s*#+\s*'), '')
          .trim();
      final description = firstHeading ?? lines.firstOrNull?.trim() ?? dirName;

      return FolderSkillConfig(
        name: dirName,
        description: description,
        tools: [
          FolderToolDef(
            name: dirName,
            description: description,
            parameters: {
              'type': 'object',
              'properties': {'content': {'type': 'string'}},
              'required': ['content'],
            },
          ),
        ],
        promptBody: doc.body,
      );
    }

    // 有 frontmatter：解析工具列表
    final name = fm['name'] as String? ?? folderPath.replaceAll('\\', '/').split('/').last;
    final description = fm['description'] as String? ?? '';
    final toolsList = fm['tools'];

    List<FolderToolDef> tools;
    if (toolsList is List) {
      tools = toolsList
          .map((t) => FolderToolDef.fromMap(t as Map<String, dynamic>))
          .toList();
    } else {
      // 无 tools 定义：创建默认工具
      tools = [
        FolderToolDef(
          name: name,
          description: description.isNotEmpty ? description : name,
          parameters: {
            'type': 'object',
            'properties': {'content': {'type': 'string'}},
            'required': ['content'],
          },
        ),
      ];
    }

    return FolderSkillConfig(
      name: name,
      description: description,
      tools: tools,
      promptBody: doc.body,
    );
  }
}

/// Folder Skill 工具适配器
///
/// 将 Type 2 Folder Skill 的 prompt 文件包装为 [AgentTool]。
/// execute 时动态读取 prompt 文件，注入参数并调用 LLM invokeOnce。
class FolderToolAdapter extends AgentTool {
  final String _skillPath;
  final FolderToolDef _toolDef;
  final String _promptBody;
  final Future<String> Function(String) _invokeLlm;

  // 缓存
  String? _cachedPrompt;
  DateTime? _cachedAt;
  static const _cacheTtlSeconds = 30;

  FolderToolAdapter({
    required String skillPath,
    required FolderToolDef toolDef,
    required String promptBody,
    required Future<String> Function(String) invokeLlm,
  })  : _skillPath = skillPath,
        _toolDef = toolDef,
        _promptBody = promptBody,
        _invokeLlm = invokeLlm;

  @override
  String get name => _toolDef.name;

  @override
  String get description => _toolDef.description;

  @override
  Map<String, dynamic> get inputJsonSchema => _toolDef.parameters;

  @override
  bool get requiresPermission => _toolDef.requiresPermission;

  @override
  String get permissionType => 'folder_skill';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    try {
      final prompt = await _resolvePrompt(arguments);
      final result = await _invokeLlm(prompt);
      return ToolResult.success(result);
    } catch (e) {
      return ToolResult.error('技能执行失败: $e');
    }
  }

  /// 解析最终 prompt
  ///
  /// 优先级：
  /// 1. 独立 prompt 文件 (prompt/xxx.md)
  /// 2. SKILL.md 正文
  /// 3. 工具描述（兜底）
  Future<String> _resolvePrompt(Map<String, dynamic> arguments) async {
    String prompt;

    // 优先级 1：独立 prompt 文件
    if (_toolDef.promptFile != null) {
      prompt = await _loadCachedFile('$_skillPath${Platform.pathSeparator}prompt${Platform.pathSeparator}${_toolDef.promptFile}');
    }
    // 优先级 2：SKILL.md 正文
    else if (_promptBody.isNotEmpty) {
      prompt = _promptBody;
    }
    // 优先级 3：兜底描述
    else {
      prompt = _toolDef.description;
    }

    // 注入参数 {{变量}}
    for (final entry in arguments.entries) {
      prompt = prompt.replaceAll('{{${entry.key}}}', entry.value.toString());
    }

    // 注入资源文件
    if (_toolDef.resourceFile != null) {
      final resource = await _loadCachedFile(
        '$_skillPath${Platform.pathSeparator}resources${Platform.pathSeparator}${_toolDef.resourceFile}',
      );
      if (resource.isNotEmpty) {
        prompt = '$prompt\n\n---\n参考资料:\n$resource';
      }
    }

    return prompt;
  }

  /// 带缓存的文件读取
  Future<String> _loadCachedFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return '';

    // 检查缓存
    if (_cachedPrompt != null && _cachedAt != null) {
      if (DateTime.now().difference(_cachedAt!).inSeconds < _cacheTtlSeconds) {
        return _cachedPrompt!;
      }
    }

    _cachedPrompt = await file.readAsString();
    _cachedAt = DateTime.now();
    return _cachedPrompt!;
  }
}
