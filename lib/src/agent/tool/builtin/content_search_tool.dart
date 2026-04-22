import 'dart:io';

import '../agent_tool.dart';
import '../../../utils/logger.dart';

/// 搜索工具
///
/// 支持两种搜索模式：
/// - content（默认）：在文件内容中搜索匹配的文本或正则模式（类似 grep）
/// - file：按文件名模式搜索文件（类似 find）
///
/// 输出字符总大小限制 30KB，超出时截断并返回提示。
class ContentSearchTool extends AgentTool {
  static final _log = Logger('ContentSearchTool');

  /// 默认最大匹配行数
  static const int _defaultMaxResults = 100;

  /// 文件搜索最大结果数
  static const int _maxFileResults = 200;

  /// 最大输出字符数（30KB）
  static const int _maxOutputChars = 30 * 1024;
  @override
  String get name => 'content_search';

  @override
  String get description =>
      '搜索工具，支持两种模式：'
      '1) content（默认）- 在文件内容中搜索文本或正则表达式，返回匹配行及文件路径和行号；'
      '2) file - 按文件名模式搜索文件，返回匹配的文件路径列表。';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': '要搜索的文件或目录路径',
      },
      'pattern': {
        'type': 'string',
        'description':
            '搜索模式。'
            'content 模式下为文本或正则表达式；'
            'file 模式下为文件名通配符（如 "*.dart"、"test_*.py"）',
      },
      'searchType': {
        'type': 'string',
        'enum': ['content', 'file'],
        'description':
            '搜索类型。content: 在文件内容中搜索（默认）；file: 按文件名搜索',
      },
      'filePattern': {
        'type': 'string',
        'description':
            '可选的 glob 模式用于过滤文件（如 "*.dart"）。仅 content 模式有效。默认：搜索所有文本文件',
      },
      'maxResults': {
        'type': 'integer',
        'description': '最大返回匹配行数。默认：100',
      },
      'caseSensitive': {
        'type': 'boolean',
        'description': '是否区分大小写。默认：true',
      },
      'recursive': {
        'type': 'boolean',
        'description': '是否递归搜索子目录。默认：true',
      },
    },
    'required': ['path', 'pattern'],
  };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final path = arguments['path'] as String?;
    if (path == null || path.isEmpty) {
      return ToolResult.error('参数错误: path 不能为空');
    }

    final pattern = arguments['pattern'] as String?;
    if (pattern == null || pattern.isEmpty) {
      return ToolResult.error('参数错误: pattern 不能为空');
    }

    final searchType = arguments['searchType'] as String? ?? 'content';

    if (searchType == 'file') {
      // 文件名搜索：path 必须是目录
      final dir = Directory(path);
      if (!await dir.exists()) {
        return ToolResult.error('目录不存在: $path');
      }
      return _searchByFileName(dir, pattern, arguments);
    } else {
      // 内容搜索：path 可以是文件或目录
      final file = File(path);
      if (await file.exists()) {
        return _searchInFile(file, pattern, arguments);
      }
      final dir = Directory(path);
      if (!await dir.exists()) {
        return ToolResult.error('路径不存在: $path');
      }
      return _searchByContent(dir, pattern, arguments);
    }
  }

  /// 在单个文件中搜索内容
  Future<ToolResult> _searchInFile(
    File file,
    String pattern,
    Map<String, dynamic> arguments,
  ) async {
    final maxResults = arguments['maxResults'] as int? ?? _defaultMaxResults;
    final caseSensitive = arguments['caseSensitive'] as bool? ?? true;

    try {
      RegExp regex;
      try {
        regex = RegExp(pattern, caseSensitive: caseSensitive);
      } on FormatException catch (e) {
        return ToolResult.error('正则表达式语法错误: $e');
      }

      final lines = await file.readAsLines();
      final results = <String>[];
      var outputChars = 0;

      for (var i = 0; i < lines.length; i++) {
        if (results.length >= maxResults || outputChars >= _maxOutputChars) break;
        if (regex.hasMatch(lines[i])) {
          final line = '${file.path}:${i + 1}: ${lines[i]}';
          results.add(line);
          outputChars += line.length + 1;
        }
      }

      if (results.isEmpty) {
        return ToolResult.success('在文件 ${file.path} 中未找到匹配 "$pattern" 的内容');
      }

      final result = StringBuffer();
      result.writeln('在文件 ${file.path} 中找到 ${results.length} 个匹配:');
      result.write(results.join('\n'));

      if (results.length >= maxResults) {
        result.writeln();
        result.writeln(
          '[结果已截断] 已达到 $maxResults 行上限。建议: 使用更精确的 pattern 缩小搜索范围。',
        );
      }

      return ToolResult.success(result.toString().trimRight());
    } catch (e) {
      return ToolResult.error('读取文件失败: $e');
    }
  }

  /// 按文件名搜索文件
  Future<ToolResult> _searchByFileName(
    Directory dir,
    String pattern,
    Map<String, dynamic> arguments,
  ) async {
    final recursive = arguments['recursive'] as bool? ?? true;

    try {
      RegExp regex;
      try {
        regex = RegExp(
          _globToRegex(pattern),
          caseSensitive: !Platform.isWindows,
        );
      } on FormatException catch (e) {
        return ToolResult.error('文件名模式语法错误: $e');
      }

      final matches = <String>[];
      var truncated = false;
      await for (final entity in dir.list(
        recursive: recursive,
        followLinks: false,
      )) {
        final baseName = entity.path.split(Platform.pathSeparator).last;
        if (regex.hasMatch(baseName)) {
          matches.add(entity.path);
          if (matches.length >= _maxFileResults) {
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
          '[结果已截断] 已达到 $_maxFileResults 条上限，可能还有更多匹配。'
          '建议: 使用更具体的 pattern 缩小搜索范围。',
        );
      }

      return ToolResult.success(result.toString().trimRight());
    } catch (e) {
      return ToolResult.error('搜索文件失败: $e');
    }
  }

  /// 按文件内容搜索
  Future<ToolResult> _searchByContent(
    Directory dir,
    String pattern,
    Map<String, dynamic> arguments,
  ) async {
    final maxResults = arguments['maxResults'] as int? ?? _defaultMaxResults;
    final caseSensitive = arguments['caseSensitive'] as bool? ?? true;
    final filePattern = arguments['filePattern'] as String?;
    final recursive = arguments['recursive'] as bool? ?? true;

    try {
      RegExp regex;
      try {
        regex = RegExp(pattern, caseSensitive: caseSensitive);
      } on FormatException catch (e) {
        return ToolResult.error('正则表达式语法错误: $e');
      }
      RegExp? fileRegex;
      if (filePattern != null && filePattern.isNotEmpty) {
        fileRegex = RegExp(
          _globToRegex(filePattern),
          caseSensitive: !Platform.isWindows,
        );
      }

      final results = <String>[];
      var fileCount = 0;
      var outputChars = 0;
      var truncatedBySize = false;

      await for (final entity in dir.list(
        recursive: recursive,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        if (results.length >= maxResults || outputChars >= _maxOutputChars) break;

        final baseName = entity.path.split(Platform.pathSeparator).last;

        // 跳过二进制文件等
        if (_isBinaryFile(baseName)) continue;

        // 文件名过滤
        if (fileRegex != null && !fileRegex.hasMatch(baseName)) continue;

        try {
          final lines = await entity.readAsLines();
          var hasMatch = false;
          for (var i = 0; i < lines.length; i++) {
            if (results.length >= maxResults || outputChars >= _maxOutputChars) {
              truncatedBySize = true;
              break;
            }
            if (regex.hasMatch(lines[i])) {
              if (!hasMatch) {
                hasMatch = true;
                fileCount++;
              }
              final line = '${entity.path}:${i + 1}: ${lines[i]}';
              results.add(line);
              outputChars += line.length + 1; // +1 for newline
            }
          }
        } catch (e) {
          // 跳过无法读取的文件（如二进制文件）
          _log.debug('skipping unreadable file: ${entity.path}, error: $e');
        }
      }

      if (results.isEmpty) {
        return ToolResult.success('未找到匹配 "$pattern" 的内容');
      }

      final result = StringBuffer();
      result.writeln('在 $fileCount 个文件中找到 ${results.length} 个匹配:');
      result.write(results.join('\n'));

      if (results.length >= maxResults) {
        result.writeln();
        result.writeln(
          '[结果已截断] 已达到 $maxResults 行上限。'
          '建议: 使用更精确的 pattern 或 filePattern 缩小搜索范围。',
        );
      } else if (truncatedBySize) {
        result.writeln();
        result.writeln(
          '[结果已截断] 输出超过 ${_maxOutputChars ~/ 1024}KB 限制。'
          '建议: 使用更精确的 pattern 或 filePattern 缩小搜索范围。',
        );
      }

      return ToolResult.success(result.toString().trimRight());
    } catch (e) {
      return ToolResult.error('搜索内容失败: $e');
    }
  }

  bool _isBinaryFile(String name) {
    const binaryExtensions = {
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.bmp',
      '.ico',
      '.webp',
      '.mp3',
      '.mp4',
      '.avi',
      '.mov',
      '.wav',
      '.flac',
      '.zip',
      '.tar',
      '.gz',
      '.rar',
      '.7z',
      '.exe',
      '.dll',
      '.so',
      '.dylib',
      '.pdf',
      '.doc',
      '.docx',
      '.xls',
      '.xlsx',
      '.class',
      '.jar',
      '.pyc',
      '.o',
      '.obj',
      '.ttf',
      '.otf',
      '.woff',
      '.woff2',
      '.jks',
      '.wasm',
      '.pdb',
      '.bin',
      '.lock',
    };
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return binaryExtensions.contains(name.substring(dot).toLowerCase());
  }

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
