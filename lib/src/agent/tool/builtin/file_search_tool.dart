import 'dart:io';

import '../agent_tool.dart';

/// 文件搜索工具
///
/// 在目录中按文件名模式搜索文件。
/// 最多返回 200 个匹配结果，超出时返回截断提示。
class FileSearchTool extends AgentTool {
  /// 最大返回结果数量
  static const int _maxResults = 200;
  @override
  String get name => 'file_search';

  @override
  String get description =>
      'Search for files matching a name pattern within a directory. '
      'The pattern supports simple wildcards: * matches any characters, '
      '? matches a single character. '
      'Returns a list of matching file paths.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'directory': {
        'type': 'string',
        'description': 'The root directory to search in',
      },
      'pattern': {
        'type': 'string',
        'description':
            'File name pattern to match (e.g., "*.dart", "test_*.py", "README*")',
      },
      'recursive': {
        'type': 'boolean',
        'description': 'If true, search recursively. Default: true',
      },
    },
    'required': ['directory', 'pattern'],
  };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final directory = arguments['directory'] as String?;
    if (directory == null || directory.isEmpty) {
      return ToolResult.error('参数错误: directory 不能为空');
    }

    final pattern = arguments['pattern'] as String?;
    if (pattern == null || pattern.isEmpty) {
      return ToolResult.error('参数错误: pattern 不能为空');
    }

    final dir = Directory(directory);
    if (!await dir.exists()) {
      return ToolResult.error('目录不存在: $directory');
    }

    final recursive = arguments['recursive'] as bool? ?? true;

    try {
      // 将简单通配符模式转换为正则表达式
      final regexPattern = _globToRegex(pattern);
      final regex = RegExp(regexPattern, caseSensitive: !Platform.isWindows);

      final matches = <String>[];
      var truncated = false;
      await for (final entity in dir.list(
        recursive: recursive,
        followLinks: false,
      )) {
        final baseName = entity.path.split(Platform.pathSeparator).last;
        if (regex.hasMatch(baseName)) {
          matches.add(entity.path);
          if (matches.length >= _maxResults) {
            truncated = true;
            break;
          }
        }
      }

      if (matches.isEmpty) {
        return ToolResult.success('未找到匹配 "$pattern" 的文件');
      }

      matches.sort();
      final result = StringBuffer();
      result.writeln('找到 ${matches.length} 个匹配文件:');
      result.write(matches.join('\n'));

      if (truncated) {
        result.writeln();
        result.writeln(
          '[结果已截断] 已达到 $_maxResults 条上限，可能还有更多匹配。'
          '建议: 使用更具体的 pattern 缩小搜索范围。',
        );
      }

      return ToolResult.success(result.toString().trimRight());
    } catch (e) {
      return ToolResult.error('搜索文件失败: $e');
    }
  }

  /// 将简单的 glob 模式转换为正则表达式
  String _globToRegex(String glob) {
    final buffer = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final char = glob[i];
      switch (char) {
        case '*':
          buffer.write('.*');
          break;
        case '?':
          buffer.write('.');
          break;
        case '.':
        case '(':
        case ')':
        case '[':
        case ']':
        case '{':
        case '}':
        case '+':
        case '^':
        case r'$':
        case '|':
        case r'\':
          buffer.write('\\$char');
          break;
        default:
          buffer.write(char);
      }
    }
    buffer.write(r'$');
    return buffer.toString();
  }
}
