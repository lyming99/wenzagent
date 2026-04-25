import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/file_operation_entity.dart';

/// 文件操作记录数据存储
///
/// 提供文件操作记录的 CRUD 操作，所有操作直接读写 SQLite。
class FileOperationStore {
  final DatabaseManager _dbManager;

  FileOperationStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  Database get _db {
    if (!_dbManager.isInitialized) {
      throw StateError(
        '$runtimeType: DatabaseManager 未初始化，请先调用 initialize()。',
      );
    }
    return _dbManager.db;
  }

  /// 从数据库行解码为 FileOperationEntity
  FileOperationEntity _rowToEntity(Row row) {
    final extraStr = row['extra'] as String?;
    Map<String, dynamic>? extra;
    if (extraStr != null) {
      try {
        extra = jsonDecode(extraStr) as Map<String, dynamic>;
      } catch (_) {
        extra = null;
      }
    }
    return FileOperationEntity.fromMap({
      'id': row['id'],
      'employeeId': row['employee_id'],
      'messageId': row['message_id'],
      'toolCallId': row['tool_call_id'],
      'toolName': row['tool_name'],
      'operationType': row['operation_type'],
      'path': row['path'],
      'fileSize': row['file_size'],
      'extra': extra,
      'success': (row['success'] as int) == 1,
      'errorMessage': row['error_message'],
      'createdAt': row['created_at'],
    });
  }

  /// 保存文件操作记录
  void save(FileOperationEntity entity) {
    _db.execute('''
      INSERT INTO file_operations (
        id, employee_id, message_id, tool_call_id, tool_name,
        operation_type, path, file_size, extra, success,
        error_message, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      entity.id,
      entity.employeeId,
      entity.messageId,
      entity.toolCallId,
      entity.toolName,
      entity.operationType.dbValue,
      entity.path,
      entity.fileSize,
      entity.extra != null ? jsonEncode(entity.extra) : null,
      entity.success ? 1 : 0,
      entity.errorMessage,
      entity.createdAt.millisecondsSinceEpoch,
    ]);
  }

  /// 查询指定员工的文件操作（按时间倒序）
  List<FileOperationEntity> findByEmployee(String employeeId,
      {int limit = 100, int offset = 0}) {
    final resultSet = _db.select(
      'SELECT * FROM file_operations WHERE employee_id = ? ORDER BY created_at DESC LIMIT ? OFFSET ?',
      [employeeId, limit, offset],
    );
    return resultSet.map(_rowToEntity).toList();
  }

  /// 查询指定消息关联的所有文件操作
  List<FileOperationEntity> findByMessageId(String messageId) {
    final resultSet = _db.select(
      'SELECT * FROM file_operations WHERE message_id = ? ORDER BY created_at ASC',
      [messageId],
    );
    return resultSet.map(_rowToEntity).toList();
  }

  /// 查询指定时间范围内的文件操作
  List<FileOperationEntity> findByTimeRange(
    String employeeId, {
    DateTime? since,
    DateTime? until,
    int limit = 100,
  }) {
    final conditions = <String>['employee_id = ?'];
    final params = <Object?>[employeeId];

    if (since != null) {
      conditions.add('created_at >= ?');
      params.add(since.millisecondsSinceEpoch);
    }
    if (until != null) {
      conditions.add('created_at <= ?');
      params.add(until.millisecondsSinceEpoch);
    }

    final where = conditions.join(' AND ');
    params.add(limit);

    final resultSet = _db.select(
      'SELECT * FROM file_operations WHERE $where ORDER BY created_at DESC LIMIT ?',
      params,
    );
    return resultSet.map(_rowToEntity).toList();
  }

  /// 获取指定路径的最新操作记录
  FileOperationEntity? findLatestByPath(String employeeId, String path) {
    final resultSet = _db.select(
      'SELECT * FROM file_operations WHERE employee_id = ? AND path = ? ORDER BY created_at DESC LIMIT 1',
      [employeeId, path],
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 清除指定员工的所有记录
  void deleteByEmployee(String employeeId) {
    _db.execute(
      'DELETE FROM file_operations WHERE employee_id = ?',
      [employeeId],
    );
  }
}
