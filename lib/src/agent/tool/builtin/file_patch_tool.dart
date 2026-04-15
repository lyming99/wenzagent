import 'dart:io';

import '../agent_tool.dart';

/// 文件补丁工具
///
/// 支持基于 old_text → new_text 的精确文件修改。
/// 与 file_write（全文件覆写）不同，file_patch 只替换指定文本，
/// 不会丢失未修改的内容。
///
/// 支持多个 patch 一次性应用，所有 patch 成功后才写入文件。
class FilePatchTool extends AgentTool {
  @override
  String get name => 'file_patch';

  @override
  String get description =>
      'Apply precise text patches to a file. Each patch replaces an exact '
      'match of old_text with new_text. Multiple patches can be applied in '
      'a single operation.\n\n'
      'Unlike file_write which overwrites the entire file, this tool only '
      'modifies the specified text segments, preserving all other content.\n\n'
      'Use this tool when you need to:\n'
      '- Make targeted edits to specific parts of a file\n'
      '- Fix a bug in a function without touching the rest\n'
      '- Rename a variable across multiple locations in one file\n'
      '- Update import statements or configuration values\n\n'
      'IMPORTANT: old_text must match exactly (including whitespace and indentation). '
      'If the match fails, the tool returns an error with line number hints.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Absolute path to the target file.',
          },
          'patches': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'old_text': {
                  'type': 'string',
                  'description':
                      'The exact text to find and replace. Must match exactly '
                      'including whitespace and indentation.',
                },
                'new_text': {
                  'type': 'string',
                  'description':
                      'The replacement text.',
                },
              },
              'required': ['old_text', 'new_text'],
            },
            'description': 'List of patches to apply. Each patch has old_text and new_text.',
          },
          'create_if_missing': {
            'type': 'boolean',
            'description':
                'If true, creates the file when it does not exist. '
                'When creating, new_text from the first patch is used as the file content. '
                'Default: false.',
          },
        },
        'required': ['path', 'patches'],
      };

  @override
  bool get requiresPermission => true;

  @override
  String get permissionType => 'file_patch';

  @override
  String? get permissionArgKey => 'path';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final path = arguments['path'] as String?;
    if (path == null || path.isEmpty) {
      return ToolResult.error('path is required');
    }

    final patchesRaw = arguments['patches'] as List?;
    if (patchesRaw == null || patchesRaw.isEmpty) {
      return ToolResult.error('patches is required and must not be empty');
    }

    final createIfMissing = arguments['create_if_missing'] as bool? ?? false;

    // 解析 patches
    final patches = <_Patch>[];
    for (var i = 0; i < patchesRaw.length; i++) {
      final p = patchesRaw[i] as Map<String, dynamic>?;
      if (p == null) {
        return ToolResult.error('Patch $i is not a valid object');
      }
      final oldText = p['old_text'] as String?;
      final newText = p['new_text'] as String?;
      if (oldText == null) {
        return ToolResult.error('Patch $i: old_text is required');
      }
      if (newText == null) {
        return ToolResult.error('Patch $i: new_text is required');
      }
      patches.add(_Patch(oldText: oldText, newText: newText));
    }

    final file = File(path);

    // 文件不存在时的处理
    if (!await file.exists()) {
      if (!createIfMissing) {
        return ToolResult.error('File not found: $path');
      }

      // 创建新文件
      final content = patches.first.newText;
      try {
        // 确保父目录存在
        final parent = file.parent;
        if (!await parent.exists()) {
          await parent.create(recursive: true);
        }
        await file.writeAsString(content);
        return ToolResult.success(
          'File created: $path\n'
          'Content: ${content.length} characters written.',
        );
      } catch (e) {
        return ToolResult.error('Failed to create file: $e');
      }
    }

    // 读取文件内容
    String content;
    try {
      content = await file.readAsString();
    } catch (e) {
      return ToolResult.error('Failed to read file: $e');
    }

    // 应用所有 patches
    final results = <String>[];
    var modified = content;

    for (var i = 0; i < patches.length; i++) {
      final patch = patches[i];
      final index = modified.indexOf(patch.oldText);

      if (index < 0) {
        // 查找失败，提供上下文提示
        final hint = _findClosestMatch(modified, patch.oldText);
        return ToolResult.error(
          'Patch ${i + 1} failed: old_text not found in file.\n'
          '${hint != null ? "Hint: $hint\n" : ""}'
          'File: $path',
        );
      }

      // 检查是否有多个匹配
      final secondIndex = modified.indexOf(patch.oldText, index + 1);
      if (secondIndex >= 0) {
        return ToolResult.error(
          'Patch ${i + 1} failed: old_text matches multiple locations in file. '
          'Please provide more surrounding context to make the match unique.\n'
          'File: $path',
        );
      }

      modified = modified.replaceFirst(patch.oldText, patch.newText);
      final lineNumber = _getLineNumber(content, index);
      results.add(
        'Patch ${i + 1}: applied at line $lineNumber '
        '(${patch.oldText.length} chars → ${patch.newText.length} chars)',
      );
    }

    // 一次性写入文件
    try {
      await file.writeAsString(modified);
    } catch (e) {
      return ToolResult.error('Failed to write file: $e');
    }

    return ToolResult.success(
      'Applied ${patches.length} patch(es) to $path\n\n'
      '${results.join('\n')}',
    );
  }

  /// 获取指定偏移量处的行号
  int _getLineNumber(String content, int offset) {
    var line = 1;
    for (var i = 0; i < offset && i < content.length; i++) {
      if (content[i] == '\n') line++;
    }
    return line;
  }

  /// 查找最接近的匹配位置，返回提示信息
  String? _findClosestMatch(String content, String searchText) {
    // 取 old_text 的第一行作为搜索目标
    final firstLine = searchText.split('\n').first.trim();
    if (firstLine.isEmpty || firstLine.length < 5) return null;

    final index = content.indexOf(firstLine);
    if (index >= 0) {
      final line = _getLineNumber(content, index);
      return 'Found similar text "$firstLine" at line $line. '
          'The surrounding context or whitespace may not match exactly.';
    }

    return null;
  }
}

/// 补丁数据
class _Patch {
  final String oldText;
  final String newText;

  _Patch({required this.oldText, required this.newText});
}
