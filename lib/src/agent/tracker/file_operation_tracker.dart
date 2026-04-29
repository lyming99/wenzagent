import 'package:uuid/uuid.dart';

import '../../persistence/entities/file_operation_entity.dart';
import '../../persistence/stores/file_operation_store.dart';

/// 文件操作追踪器
///
/// 监听 Agent 的工具事件回调，自动过滤文件变更类工具，
/// 提取操作信息并持久化到 SQLite。
class FileOperationTracker {
  final FileOperationStore _store;
  final String employeeId;

  /// 需要追踪的工具名称集合
  static const _trackedTools = {
    'file_copy',
    'file_write',
    'file_delete',
    'file_patch',
    'directory_create',
  };

  FileOperationTracker({
    required this.employeeId,
    required FileOperationStore store,
  }) : _store = store;

  /// 处理工具调用结果事件
  ///
  /// 在 Agent 的工具事件回调中调用此方法。
  /// 仅处理 [_trackedTools] 中的工具，其他工具忽略。
  void onToolResult({
    required String toolCallId,
    required String toolName,
    required Map<String, dynamic> arguments,
    required String result,
    required bool isError,
    String? messageId,
  }) {
    if (!_trackedTools.contains(toolName)) return;

    final entity = _buildEntity(
      toolCallId: toolCallId,
      toolName: toolName,
      arguments: arguments,
      result: result,
      isError: isError,
      messageId: messageId,
    );

    if (entity != null) {
      _store.save(entity);
    }
  }

  /// 从工具参数和结果中构建 FileOperationEntity
  FileOperationEntity? _buildEntity({
    required String toolCallId,
    required String toolName,
    required Map<String, dynamic> arguments,
    required String result,
    required bool isError,
    String? messageId,
  }) {
    // 提取文件路径
    final path = arguments['path'] as String?;
    if (path == null || path.isEmpty) return null;

    final operationType = _determineOperationType(
      toolName: toolName,
      arguments: arguments,
      result: result,
    );

    // 提取额外信息
    final extra = <String, dynamic>{};
    if (toolName == 'file_write') {
      final append = arguments['append'] as bool?;
      if (append == true) {
        extra['append'] = true;
      }
    } else if (toolName == 'file_patch') {
      final patches = arguments['patches'];
      if (patches is List) {
        extra['patchCount'] = patches.length;
      }
      final createIfMissing = arguments['create_if_missing'] as bool?;
      if (createIfMissing == true) {
        extra['createIfMissing'] = true;
      }
    } else if (toolName == 'file_copy') {
      final source = arguments['source'] as String?;
      if (source != null) {
        extra['source'] = source;
      }
    } else if (toolName == 'file_delete') {
      final isDirectory = arguments['is_directory'] as bool?;
      if (isDirectory == true) {
        extra['isDirectory'] = true;
      }
    }

    // 提取文件大小（从结果中尝试解析）
    int? fileSize;
    if (!isError) {
      fileSize = _extractFileSize(result);
    }

    return FileOperationEntity(
      id: const Uuid().v4(),
      employeeId: employeeId,
      messageId: messageId,
      toolCallId: toolCallId,
      toolName: toolName,
      operationType: operationType,
      path: path,
      fileSize: fileSize,
      extra: extra.isEmpty ? null : extra,
      success: !isError,
      errorMessage: isError ? result : null,
      createdAt: DateTime.now(),
    );
  }

  /// 根据工具名称和参数判定操作类型
  FileOperationType _determineOperationType({
    required String toolName,
    required Map<String, dynamic> arguments,
    required String result,
  }) {
    switch (toolName) {
      case 'file_write':
        final append = arguments['append'] as bool?;
        if (append == true) return FileOperationType.modified;
        // 如果结果中包含 "created" 或 "new file" 之类的信息，视为创建
        // 默认视为修改
        return FileOperationType.modified;
      case 'file_copy':
        return FileOperationType.created;
      case 'file_delete':
        return FileOperationType.deleted;
      case 'file_patch':
        final createIfMissing = arguments['create_if_missing'] as bool?;
        if (createIfMissing == true &&
            result.toLowerCase().contains('created')) {
          return FileOperationType.created;
        }
        return FileOperationType.modified;
      case 'directory_create':
        return FileOperationType.created;
      default:
        return FileOperationType.modified;
    }
  }

  /// 从工具结果文本中尝试提取文件大小
  int? _extractFileSize(String result) {
    // 尝试匹配 "size: 123" 或 "bytes: 123" 等模式
    final sizePattern = RegExp(r'(?:size|bytes)[^\d]*(\d+)', caseSensitive: false);
    final match = sizePattern.firstMatch(result);
    if (match != null) {
      return int.tryParse(match.group(1) ?? '');
    }
    return null;
  }

  /// 查询文件操作记录
  List<FileOperationEntity> getOperations(
      {int limit = 100, int offset = 0}) {
    return _store.findByEmployee(employeeId, limit: limit, offset: offset);
  }

  /// 查询指定消息的文件操作
  List<FileOperationEntity> getOperationsByMessage(String messageId) {
    return _store.findByMessageId(messageId);
  }

  /// 清除文件操作记录
  void clear() {
    _store.deleteByEmployee(employeeId);
  }
}
