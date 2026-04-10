import 'dart:io';

import '../agent_tool.dart';

/// 文件写入工具
///
/// 将内容写入指定路径的文件，支持覆盖和追加模式。
class FileWriteTool extends AgentTool {
  @override
  String get name => 'file_write';

  @override
  String get description =>
      'Write content to a file at the specified path. '
      'Creates the file and parent directories if they do not exist. '
      'By default overwrites the file. Set append to true to append instead.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Absolute path to the file to write. IMPORTANT: Always use absolute paths (e.g., /home/user/project/file.txt or D:\\project\\file.txt), never use relative paths.',
      },
      'content': {
        'type': 'string',
        'description': 'The content to write to the file',
      },
      'append': {
        'type': 'boolean',
        'description':
            'If true, append content to the file instead of overwriting. Default: false',
      },
    },
    'required': ['path', 'content'],
  };

  @override
  bool get requiresPermission => true;

  @override
  String get permissionType => 'file_write';

  @override
  String get permissionArgKey => 'path';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final path = arguments['path'] as String?;
    if (path == null || path.isEmpty) {
      return ToolResult.error('参数错误: path 不能为空');
    }

    final content = arguments['content'] as String? ?? '';
    final append = arguments['append'] as bool? ?? false;

    try {
      final file = File(path);

      // 确保父目录存在
      final parent = file.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }

      await file.writeAsString(
        content,
        mode: append ? FileMode.append : FileMode.write,
      );

      final stat = await file.stat();
      return ToolResult.success(
        '文件写入成功: $path (${stat.size} bytes)',
        metadata: {'path': path, 'size': stat.size, 'append': append},
      );
    } catch (e) {
      return ToolResult.error('写入文件失败: $e');
    }
  }
}
