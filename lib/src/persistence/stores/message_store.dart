import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/message_entity.dart';

/// 消息数据存储
///
/// 使用 SQLite 实现，保持与原 Hive 版本完全相同的公共 API。
/// 不再需要 session_messages 索引表，通过 SQL 直接查询。
class MessageStore {
  final DatabaseManager _dbManager;

  MessageStore({DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.instance;

  Database get _db => _dbManager.db;

  /// 从数据库行解码为实体
  AiEmployeeMessageEntity _rowToEntity(Row row) {
    final map = <String, dynamic>{
      'uuid': row['uuid'],
      'employeeId': row['employee_id'],
      'role': row['role'],
      'type': row['type'],
      'content': row['content'],
      'toolCallId': row['tool_call_id'],
      'toolName': row['tool_name'],
      'toolArguments': row['tool_arguments'],
      'toolResult': row['tool_result'],
      'toolCalls': row['tool_calls'],
      'processingStatus': row['processing_status'],
      'processingError': row['processing_error'],
      'inputTokens': row['input_tokens'],
      'outputTokens': row['output_tokens'],
      'isRead': row['is_read'],
      'deleted': row['deleted'],
      'createTime': row['create_time'],
      'updateTime': row['update_time'],
      'jsonData': row['json_data'],
    };
    return AiEmployeeMessageEntity.fromMessageMap(map);
  }

  /// 将实体转换为数据库插入参数
  List<Object?> _entityToParams(AiEmployeeMessageEntity e) {
    return [
      e.uuid,
      e.employeeId,
      e.role,
      e.type,
      e.content,
      e.toolCallId,
      e.toolName,
      e.toolArguments,
      e.toolResult,
      e.toolCalls,
      e.processingStatus,
      e.processingError,
      e.inputTokens,
      e.outputTokens,
      e.isRead,
      e.deleted,
      e.createTime.millisecondsSinceEpoch,
      e.updateTime.millisecondsSinceEpoch,
      e.jsonData,
    ];
  }

  /// 获取会话的消息列表
  Future<List<AiEmployeeMessageEntity>> getMessages(
    String? deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  }) async {
    // 无 offset 有 limit 时，取最后 N 条（与原实现一致）
    if (offset == null && limit != null && limit > 0) {
      return _getLastNMessages(employeeId, limit);
    }

    final conditions = <String>['employee_id = ?', 'deleted = 0'];
    final params = <Object?>[employeeId];

    final where = conditions.join(' AND ');
    String sql = 'SELECT * FROM messages WHERE $where ORDER BY create_time ASC';

    if (limit != null && limit > 0) {
      sql += ' LIMIT ?';
      params.add(limit);
    }
    if (offset != null && offset > 0) {
      sql += ' OFFSET ?';
      params.add(offset);
    }

    return _db.select(sql, params).map(_rowToEntity).toList();
  }

  /// 获取最后 N 条消息
  Future<List<AiEmployeeMessageEntity>> _getLastNMessages(
    String employeeId,
    int limit,
  ) async {
    final resultSet = _db.select(
      'SELECT * FROM messages WHERE employee_id = ? AND deleted = 0 ORDER BY create_time DESC LIMIT ?',
      [employeeId, limit],
    );
    final messages = resultSet.map(_rowToEntity).toList();
    messages.sort((a, b) {
      final timeCompare = a.createTime.compareTo(b.createTime);
      if (timeCompare != 0) return timeCompare;
      return a.uuid.compareTo(b.uuid);
    });
    return messages;
  }

  /// 获取单条消息
  Future<AiEmployeeMessageEntity?> find(String? deviceId, String uuid) async {
    final resultSet = _db.select(
      'SELECT * FROM messages WHERE uuid = ?',
      [uuid],
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 添加消息
  Future<void> add(AiEmployeeMessageEntity entity) async {
    await addWithDeviceId(
      entity.employeeId.split('-').firstOrNull,
      entity,
    );
  }

  /// 使用明确deviceId添加消息
  Future<void> addWithDeviceId(
    String? deviceId,
    AiEmployeeMessageEntity entity,
  ) async {
    _db.execute('''
      INSERT OR REPLACE INTO messages (
        uuid, employee_id, role, type, content,
        tool_call_id, tool_name, tool_arguments, tool_result, tool_calls,
        processing_status, processing_error, input_tokens, output_tokens,
        is_read, deleted, create_time, update_time, json_data
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', _entityToParams(entity));
  }

  /// 更新消息
  Future<void> update(AiEmployeeMessageEntity entity) async {
    await updateWithDeviceId(
      entity.employeeId.split('-').firstOrNull,
      entity,
    );
  }

  /// 使用明确deviceId更新消息
  Future<void> updateWithDeviceId(
    String? deviceId,
    AiEmployeeMessageEntity entity,
  ) async {
    _db.execute('''
      INSERT OR REPLACE INTO messages (
        uuid, employee_id, role, type, content,
        tool_call_id, tool_name, tool_arguments, tool_result, tool_calls,
        processing_status, processing_error, input_tokens, output_tokens,
        is_read, deleted, create_time, update_time, json_data
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', _entityToParams(entity));
  }

  /// 更新消息状态
  Future<void> updateStatus(
    String? deviceId,
    String uuid,
    String status, {
    String? error,
  }) async {
    final msg = await find(deviceId, uuid);
    if (msg != null) {
      final updated = msg.copyWith(
        processingStatus: status,
        processingError: error,
        updateTime: DateTime.now(),
      );
      await updateWithDeviceId(deviceId, updated);
    }
  }

  /// 删除会话的所有消息
  Future<void> deleteBySession(String? deviceId, String employeeId) async {
    _db.execute(
      'DELETE FROM messages WHERE employee_id = ?',
      [employeeId],
    );
  }

  /// 删除单条消息（硬删除）
  Future<void> delete(String? deviceId, String uuid) async {
    _db.execute('DELETE FROM messages WHERE uuid = ?', [uuid]);
  }

  /// 获取最后一条消息
  Future<AiEmployeeMessageEntity?> getLastMessage(
    String? deviceId,
    String employeeId,
  ) async {
    final resultSet = _db.select(
      'SELECT * FROM messages WHERE employee_id = ? AND deleted = 0 ORDER BY create_time DESC LIMIT 1',
      [employeeId],
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 获取消息数量
  Future<int> count(String? deviceId, String employeeId) async {
    final resultSet = _db.select(
      'SELECT COUNT(*) as cnt FROM messages WHERE employee_id = ? AND deleted = 0',
      [employeeId],
    );
    return resultSet.first['cnt'] as int;
  }

  /// 批量更新消息
  ///
  /// 使用事务确保原子性。
  Future<void> batchUpdateWithDeviceId(
    String? deviceId,
    List<AiEmployeeMessageEntity> entities,
  ) async {
    _db.execute('BEGIN');
    try {
      for (final entity in entities) {
        _db.execute('''
          INSERT OR REPLACE INTO messages (
            uuid, employee_id, role, type, content,
            tool_call_id, tool_name, tool_arguments, tool_result, tool_calls,
            processing_status, processing_error, input_tokens, output_tokens,
            is_read, deleted, create_time, update_time, json_data
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', _entityToParams(entity));
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }
}
