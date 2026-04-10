import 'dart:io';

import '../agent_tool.dart';

/// 文件读取工具
///
/// 读取指定路径文件的内容，支持行偏移和行数限制。
/// 文件大小超过限制时将返回提示，建议使用 offset/limit 分段读取。
class FileReadTool extends AgentTool {
  /// 默认最大读取字节数（50KB）
  static const int _defaultMaxBytes = 50 * 1024;

  /// 最大允许的 maxBytes 参数值（200KB）
  static const int _absoluteMaxBytes = 200 * 1024;

  @override
  String get name => 'file_read';

  @override
  String get description =>
      'Read the contents of a file at the specified path. '
      'Returns the file content as text. '
      'Optionally specify offset (line number to start from, 0-based) '
      'and limit (maximum number of lines to read). '
      'Default max file size: 50KB. Use offset and limit to read large files in chunks.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Absolute path to the file to read. IMPORTANT: Always use absolute paths (e.g., /home/user/project/file.txt or D:\\project\\file.txt), never use relative paths.',
          },
          'offset': {
            'type': 'integer',
            'description':
                'Line number to start reading from (0-based). Default: 0',
          },
          'limit': {
            'type': 'integer',
            'description':
                'Maximum number of lines to read. Default: read all lines',
          },
          'maxBytes': {
            'type': 'integer',
            'description':
                'Maximum file size in bytes to read. Default: 51200 (50KB), max: 204800 (200KB)',
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

    final file = File(path);
    if (!await file.exists()) {
      return ToolResult.error('文件不存在: $path');
    }

    try {
      final stat = await file.stat();
      final fileSize = stat.size;

      // 确定最大读取字节数
      final requestedMaxBytes = arguments['maxBytes'] as int?;
      final maxBytes = (requestedMaxBytes != null
              ? requestedMaxBytes.clamp(0, _absoluteMaxBytes)
              : _defaultMaxBytes);

      // 检查文件大小
      if (fileSize > maxBytes) {
        // 尝试按行读取部分内容，至少返回开头
        final lines = await file.readAsLines();
        final lineCount = lines.length;
        final hintLines = <String>[];

        hintLines.add(
          '[文件过大] 文件大小: ${_formatBytes(fileSize)}，超过限制: ${_formatBytes(maxBytes)}',
        );
        hintLines.add('文件共 $lineCount 行。');
        hintLines.add('建议使用 offset 和 limit 参数分段读取，例如:');
        hintLines.add('  - 读取前 200 行: offset=0, limit=200');
        hintLines.add('  - 读取第 200-400 行: offset=200, limit=200');
        hintLines.add(
          '  - 如确需读取更多内容，可设置 maxBytes=$_absoluteMaxBytes',
        );

        return ToolResult.error(hintLines.join('\n'));
      }

      final content = await file.readAsString();
      final offset = arguments['offset'] as int? ?? 0;
      final limit = arguments['limit'] as int?;

      if (offset > 0 || limit != null) {
        final lines = content.split('\n');
        final start = offset.clamp(0, lines.length);
        final end = limit != null
            ? (start + limit).clamp(start, lines.length)
            : lines.length;
        final sliced = lines.sublist(start, end);
        final remaining = lines.length - end;
        // 添加行号
        final numbered = <String>[];
        for (var i = 0; i < sliced.length; i++) {
          numbered.add('${start + i + 1}\t${sliced[i]}');
        }
        if (remaining > 0) {
          numbered.add(
            '\n[还有 $remaining 行未显示，使用 offset=$end 继续读取]',
          );
        }
        return ToolResult.success(numbered.join('\n'));
      }

      return ToolResult.success(content);
    } catch (e) {
      return ToolResult.error('读取文件失败: $e');
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
