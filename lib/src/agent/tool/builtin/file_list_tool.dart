import 'dart:io';

import '../agent_tool.dart';

/// 文件列表工具
///
/// 列出指定目录下的文件和子目录。
/// 非递归模式最多返回 500 条，递归模式最多返回 200 条。
class FileListTool extends AgentTool {
  /// 非递归模式下最大返回条数
  static const int _maxEntriesNonRecursive = 500;

  /// 递归模式下最大返回条数
  static const int _maxEntriesRecursive = 200;

  @override
  String get name => 'file_list';

  @override
  String get description =>
      '列出指定目录下的文件和子目录，返回条目类型（文件/目录）、名称和大小。非递归模式最多返回 500 条，递归模式最多 200 条。如需精确查找，请使用 content_search 工具（searchType=file）。';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '要列出内容的目录的绝对路径。重要：始终使用绝对路径，不要使用相对路径。',
          },
          'recursive': {
            'type': 'boolean',
            'description': '如果为 true，递归列出子目录内容。默认：false',
          },
          'includeHidden': {
            'type': 'boolean',
            'description':
                '如果为 true，包含隐藏文件（以点号开头）。默认：false',
          },
        },
        'required': ['path'],
      };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final path = arguments['path'] as String?;
    if (path == null || path.isEmpty) {
      return ToolResult.error('参数错误: path 不能为空');
    }

    final dir = Directory(path);
    if (!await dir.exists()) {
      return ToolResult.error('目录不存在: $path');
    }

    final recursive = arguments['recursive'] as bool? ?? false;
    final includeHidden = arguments['includeHidden'] as bool? ?? false;
    final maxEntries =
        recursive ? _maxEntriesRecursive : _maxEntriesNonRecursive;

    try {
      final entries = <String>[];
      var truncated = false;

      await for (final entity in dir.list(
        recursive: recursive,
        followLinks: false,
      )) {
        if (entries.length >= maxEntries) {
          truncated = true;
          break;
        }

        final name = entity.path.replaceFirst(
          '${dir.path}${Platform.pathSeparator}',
          '',
        );

        // 过滤隐藏文件
        if (!includeHidden) {
          final baseName = name.split(Platform.pathSeparator).last;
          if (baseName.startsWith('.')) continue;
        }

        final stat = await entity.stat();
        final type = stat.type == FileSystemEntityType.directory
            ? 'DIR'
            : 'FILE';
        final size = stat.type == FileSystemEntityType.file
            ? ' (${stat.size} bytes)'
            : '';
        entries.add('[$type] $name$size');
      }

      if (entries.isEmpty) {
        return ToolResult.success('目录为空: $path');
      }

      entries.sort();

      final result = StringBuffer();
      result.writeln(entries.join('\n'));

      if (truncated) {
        result.writeln();
        result.writeln(
          '[结果已截断] 列出了 $maxEntries 条，但目录中还有更多内容。'
          '建议: 1) 使用 content_search(searchType=file) 按文件名模式缩小范围; '
          '2) 列出子目录而非递归列出; '
          '3) 指定更具体的路径。',
        );
      }

      return ToolResult.success(result.toString().trimRight());
    } catch (e) {
      return ToolResult.error('列出目录内容失败: $e');
    }
  }
}
