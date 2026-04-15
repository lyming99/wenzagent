import 'dart:io';

import '../agent_tool.dart';

/// 环境信息工具
///
/// 获取系统环境信息：OS 信息、已安装工具检测、项目信息。
class EnvInfoTool extends AgentTool {
  /// 每个工具检测超时（秒）
  static const int _toolCheckTimeout = 5;

  /// 要检测的开发工具列表
  static const List<_ToolCheck> _toolsToCheck = [
    _ToolCheck('git', 'git'),
    _ToolCheck('node', 'node'),
    _ToolCheck('npm', 'npm'),
    _ToolCheck('python', 'python'),
    _ToolCheck('python3', 'python3'),
    _ToolCheck('pip', 'pip'),
    _ToolCheck('java', 'java'),
    _ToolCheck('dart', 'dart'),
    _ToolCheck('flutter', 'flutter'),
    _ToolCheck('docker', 'docker'),
    _ToolCheck('gcc', 'gcc'),
    _ToolCheck('make', 'make'),
    _ToolCheck('cargo', 'cargo'),
    _ToolCheck('go', 'go'),
    _ToolCheck('rustc', 'rustc'),
    _ToolCheck('dotnet', 'dotnet'),
  ];

  @override
  String get name => 'env_info';

  @override
  String get description =>
      'Get system environment information. '
      'Supports three types of queries:\n\n'
      '- "system": Returns OS type, CPU cores, memory, Dart SDK version, and working directory.\n'
      '- "tools": Detects installed development tools and their versions (git, node, python, dart, flutter, etc.). '
      'Use the "query" parameter to check a specific tool.\n'
      '- "project": Parses current project info from pubspec.yaml, package.json, or Cargo.toml.\n\n'
      'Use this tool to understand the development environment before starting work.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'info_type': {
            'type': 'string',
            'enum': ['system', 'tools', 'project'],
            'description':
                'Type of environment information to retrieve.',
          },
          'query': {
            'type': 'string',
            'description':
                'Specific query within the info_type. '
                'For "tools": check a specific tool name. '
                'For "project": specify a project directory path.',
          },
        },
        'required': ['info_type'],
      };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final infoType = arguments['info_type'] as String?;
    if (infoType == null || infoType.isEmpty) {
      return ToolResult.error('info_type is required');
    }

    final query = arguments['query'] as String?;

    switch (infoType) {
      case 'system':
        return _getSystemInfo();
      case 'tools':
        return await _getToolsInfo(query);
      case 'project':
        return await _getProjectInfo(query);
      default:
        return ToolResult.error(
          'Unknown info_type: $infoType. Use "system", "tools", or "project".',
        );
    }
  }

  /// 获取系统信息
  ToolResult _getSystemInfo() {
    final buffer = StringBuffer('## System Information\n\n');

    buffer.writeln('OS: ${Platform.operatingSystem}');
    buffer.writeln('OS Version: ${Platform.operatingSystemVersion}');
    buffer.writeln('CPU Cores: ${Platform.numberOfProcessors}');
    buffer.writeln('Dart SDK: ${Platform.version}');
    buffer.writeln('Working Directory: ${Directory.current.path}');
    buffer.writeln('Path Separator: "${Platform.pathSeparator}"');
    buffer.writeln('Locale: ${Platform.localeName}');

    // 内存信息（非所有平台都支持，但可以尝试）
    try {
      buffer.writeln('Script: ${Platform.script}');
    } catch (_) {}

    return ToolResult.success(buffer.toString().trim());
  }

  /// 获取工具信息
  Future<ToolResult> _getToolsInfo(String? query) async {
    if (query != null && query.isNotEmpty) {
      // 查询单个工具
      final result = await _checkTool(query);
      return ToolResult.success(
        result != null
            ? '$query: installed (${result.version})'
            : '$query: not found',
      );
    }

    // 检测所有工具
    final buffer = StringBuffer('## Installed Development Tools\n\n');

    final futures = _toolsToCheck.map((t) async {
      final result = await _checkTool(t.command);
      return (t.name, result);
    });

    final results = await Future.wait(futures);

    for (final (name, result) in results) {
      if (result != null) {
        buffer.writeln('- $name: ${result.version}');
      }
    }

    // 列出未找到的
    final notFound = results
        .where((r) => r.$2 == null)
        .map((r) => r.$1)
        .toList();
    if (notFound.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Not found: ${notFound.join(", ")}');
    }

    return ToolResult.success(buffer.toString().trim());
  }

  /// 获取项目信息
  Future<ToolResult> _getProjectInfo(String? projectPath) async {
    final dir = projectPath != null && projectPath.isNotEmpty
        ? Directory(projectPath)
        : Directory.current;

    if (!await dir.exists()) {
      return ToolResult.error('Directory not found: ${dir.path}');
    }

    final buffer = StringBuffer('## Project Information\n\n');
    buffer.writeln('Path: ${dir.path}');

    // 检查 pubspec.yaml (Dart/Flutter)
    final pubspecFile = File('${dir.path}${Platform.pathSeparator}pubspec.yaml');
    if (await pubspecFile.exists()) {
      buffer.writeln('\n### Dart/Flutter Project');
      try {
        final content = await pubspecFile.readAsString();
        _parsePubspec(content, buffer);
      } catch (e) {
        buffer.writeln('Error reading pubspec.yaml: $e');
      }
    }

    // 检查 package.json (Node.js)
    final packageJsonFile = File('${dir.path}${Platform.pathSeparator}package.json');
    if (await packageJsonFile.exists()) {
      buffer.writeln('\n### Node.js Project');
      try {
        final content = await packageJsonFile.readAsString();
        _parsePackageJson(content, buffer);
      } catch (e) {
        buffer.writeln('Error reading package.json: $e');
      }
    }

    // 检查 Cargo.toml (Rust)
    final cargoFile = File('${dir.path}${Platform.pathSeparator}Cargo.toml');
    if (await cargoFile.exists()) {
      buffer.writeln('\n### Rust Project');
      try {
        final content = await cargoFile.readAsString();
        _parseCargoToml(content, buffer);
      } catch (e) {
        buffer.writeln('Error reading Cargo.toml: $e');
      }
    }

    // 列出目录内容
    try {
      final entities = await dir.list().toList();
      final files = entities
          .whereType<File>()
          .map((f) => f.path.split(Platform.pathSeparator).last)
          .toList();
      final dirs = entities
          .whereType<Directory>()
          .map((d) => d.path.split(Platform.pathSeparator).last)
          .toList();

      if (dirs.isNotEmpty) {
        buffer.writeln('\n### Directories');
        buffer.writeln(dirs.take(20).join(', '));
        if (dirs.length > 20) {
          buffer.writeln('... and ${dirs.length - 20} more');
        }
      }
      if (files.isNotEmpty) {
        buffer.writeln('\n### Files');
        buffer.writeln(files.take(20).join(', '));
        if (files.length > 20) {
          buffer.writeln('... and ${files.length - 20} more');
        }
      }
    } catch (e) {
      // Ignore listing errors
    }

    return ToolResult.success(buffer.toString().trim());
  }

  /// 检查单个工具是否安装
  Future<_ToolInfo?> _checkTool(String command) async {
    try {
      // 先查找路径
      final whichResult = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        [command],
        runInShell: true,
      ).timeout(const Duration(seconds: _toolCheckTimeout));

      if (whichResult.exitCode != 0) return null;

      // 获取版本
      final versionResult = await Process.run(
        command,
        ['--version'],
        runInShell: true,
      ).timeout(const Duration(seconds: _toolCheckTimeout));

      final version = versionResult.exitCode == 0
          ? (versionResult.stdout as String).trim().split('\n').first
          : 'installed (version unknown)';

      return _ToolInfo(version: version);
    } catch (e) {
      return null;
    }
  }

  /// 简单解析 pubspec.yaml
  void _parsePubspec(String content, StringBuffer buffer) {
    final lines = content.split('\n');
    String? name;
    String? description;
    String? version;
    final dependencies = <String>[];
    var inDependencies = false;

    for (final line in lines) {
      final trimmed = line.trim();

      if (trimmed.startsWith('name:')) {
        name = trimmed.substring(5).trim();
      } else if (trimmed.startsWith('description:')) {
        description = trimmed.substring(12).trim();
      } else if (trimmed.startsWith('version:')) {
        version = trimmed.substring(8).trim();
      } else if (trimmed == 'dependencies:' || trimmed.startsWith('dependencies:')) {
        inDependencies = true;
      } else if (inDependencies) {
        if (trimmed.isEmpty || (!trimmed.startsWith('  ') && !trimmed.startsWith('\t'))) {
          inDependencies = false;
        } else if (!trimmed.startsWith('#')) {
          final depName = trimmed.split(':').first.trim();
          if (depName.isNotEmpty) dependencies.add(depName);
        }
      }
    }

    if (name != null) buffer.writeln('Name: $name');
    if (description != null) buffer.writeln('Description: $description');
    if (version != null) buffer.writeln('Version: $version');
    if (dependencies.isNotEmpty) {
      buffer.writeln('Dependencies: ${dependencies.take(30).join(", ")}');
      if (dependencies.length > 30) {
        buffer.writeln('... and ${dependencies.length - 30} more');
      }
    }
  }

  /// 简单解析 package.json
  void _parsePackageJson(String content, StringBuffer buffer) {
    try {
      // 简单正则解析，避免引入 json 包（已通过 dart:convert 可用）
      final nameMatch = RegExp(r'"name"\s*:\s*"([^"]*)"').firstMatch(content);
      final versionMatch =
          RegExp(r'"version"\s*:\s*"([^"]*)"').firstMatch(content);
      final descMatch =
          RegExp(r'"description"\s*:\s*"([^"]*)"').firstMatch(content);

      if (nameMatch != null) buffer.writeln('Name: ${nameMatch[1]}');
      if (descMatch != null) buffer.writeln('Description: ${descMatch[1]}');
      if (versionMatch != null) buffer.writeln('Version: ${versionMatch[1]}');
    } catch (e) {
      buffer.writeln('Error parsing: $e');
    }
  }

  /// 简单解析 Cargo.toml
  void _parseCargoToml(String content, StringBuffer buffer) {
    final lines = content.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('name = ')) {
        buffer.writeln('Name: ${trimmed.substring(7).trim()}');
      } else if (trimmed.startsWith('version = ')) {
        buffer.writeln('Version: ${trimmed.substring(10).trim()}');
      } else if (trimmed.startsWith('edition = ')) {
        buffer.writeln('Edition: ${trimmed.substring(10).trim()}');
      }
    }
  }
}

/// 工具检查配置
class _ToolCheck {
  final String name;
  final String command;

  const _ToolCheck(this.name, this.command);
}

/// 工具信息
class _ToolInfo {
  final String version;

  const _ToolInfo({required this.version});
}
