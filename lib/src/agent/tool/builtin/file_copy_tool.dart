import 'dart:io';

import '../agent_tool.dart';

/// 文件复制工具
///
/// 复制文件或目录到指定目标路径。支持递归复制整个目录。
class FileCopyTool extends AgentTool {
  @override
  String get name => 'file_copy';

  @override
  String get description =>
      '复制文件或目录到指定目标路径。对于目录，设置 recursive 为 true 可递归复制整个目录（包含内容）。';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'source': {
        'type': 'string',
        'description': '源文件或目录的绝对路径。重要：始终使用绝对路径，不要使用相对路径。',
      },
      'destination': {
        'type': 'string',
        'description': '目标文件或目录的绝对路径。重要：始终使用绝对路径，不要使用相对路径。',
      },
      'recursive': {
        'type': 'boolean',
        'description': '如果为 true，递归复制目录（包含内容）。默认：true',
      },
      'overwrite': {
        'type': 'boolean',
        'description': '如果为 true，当目标文件已存在时覆盖。默认：false',
      },
    },
    'required': ['source', 'destination'],
  };

  @override
  bool get requiresPermission => true;

  @override
  String get permissionType => 'file_write';

  @override
  String? get permissionArgKey => 'destination';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final source = arguments['source'] as String?;
    final destination = arguments['destination'] as String?;

    if (source == null || source.isEmpty) {
      return ToolResult.error('参数错误: source 不能为空');
    }
    if (destination == null || destination.isEmpty) {
      return ToolResult.error('参数错误: destination 不能为空');
    }

    final recursive = arguments['recursive'] as bool? ?? true;
    final overwrite = arguments['overwrite'] as bool? ?? false;

    try {
      final sourceType = await FileSystemEntity.type(source);

      if (sourceType == FileSystemEntityType.notFound) {
        return ToolResult.error('源路径不存在: $source');
      }

      if (sourceType == FileSystemEntityType.directory) {
        return await _copyDirectory(source, destination, recursive, overwrite);
      } else {
        return await _copyFile(source, destination, overwrite);
      }
    } catch (e) {
      return ToolResult.error('复制失败: $e');
    }
  }

  /// 复制单个文件
  Future<ToolResult> _copyFile(
    String source,
    String destination,
    bool overwrite,
  ) async {
    final destFile = File(destination);

    if (await destFile.exists()) {
      if (!overwrite) {
        return ToolResult.error('目标文件已存在: $destination（设置 overwrite: true 可覆盖）');
      }
    }

    // 确保目标目录存在
    final destDir = destFile.parent;
    if (!await destDir.exists()) {
      await destDir.create(recursive: true);
    }

    await File(source).copy(destination);

    final size = await File(destination).length();
    return ToolResult.success(
      '文件已复制: $source -> $destination (${_formatSize(size)})',
    );
  }

  /// 复制目录
  Future<ToolResult> _copyDirectory(
    String source,
    String destination,
    bool recursive,
    bool overwrite,
  ) async {
    if (!recursive) {
      return ToolResult.error(
        '复制目录需要设置 recursive: true（递归复制整个目录内容）',
      );
    }

    final sourceDir = Directory(source);
    final destDir = Directory(destination);

    if (await destDir.exists()) {
      if (!overwrite) {
        return ToolResult.error('目标目录已存在: $destination（设置 overwrite: true 可覆盖）');
      }
    }

    int fileCount = 0;
    int dirCount = 0;

    await _copyDirectoryRecursive(sourceDir, destDir, overwrite, (type) {
      if (type == FileSystemEntityType.file) {
        fileCount++;
      } else {
        dirCount++;
      }
    });

    return ToolResult.success(
      '目录已复制: $source -> $destination ($fileCount 个文件, $dirCount 个子目录)',
    );
  }

  /// 递归复制目录内容
  Future<void> _copyDirectoryRecursive(
    Directory source,
    Directory destination,
    bool overwrite,
    void Function(FileSystemEntityType) onCopied,
  ) async {
    if (!await destination.exists()) {
      await destination.create(recursive: true);
    }

    await for (final entity in source.list()) {
      final newPath =
          '${destination.path}${Platform.pathSeparator}${entity.path.split(Platform.pathSeparator).last}';

      if (entity is File) {
        final newFile = File(newPath);
        if (await newFile.exists()) {
          if (!overwrite) continue;
        }
        await entity.copy(newPath);
        onCopied(FileSystemEntityType.file);
      } else if (entity is Directory) {
        final newDir = Directory(newPath);
        await _copyDirectoryRecursive(entity, newDir, overwrite, onCopied);
        onCopied(FileSystemEntityType.directory);
      }
    }
  }

  /// 格式化文件大小
  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
