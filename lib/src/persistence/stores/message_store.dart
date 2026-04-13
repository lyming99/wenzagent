import 'package:sqlite3/sqlite3.dart';

import '../../shared/shared.dart';
import '../database_manager.dart';

/// 消息数据存储
///
/// 使用 SQLite 实现，所有方法直接返回 [ChatMessage]，
/// 通过 [MessageMapper] 统一处理行数据转换。
/// 消息按 employee_id + device_id 隔离，不同设备上同一员工有独立的消息历史。
class MessageStore {
  final DatabaseManager _dbManager;

  MessageStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  Database get _db => _dbManager.db;

  /// 暴露 DatabaseManager，供关联 Store 复用（如 SyncWatermarkStore）
  DatabaseManager get dbManager => _dbManager;

  /// 从数据库行解码为 ChatMessage
  ChatMessage _rowToMessage(Row row) {
    return MessageMapper.fromRow(row);
  }

  /// 将 ChatMessage 转换为数据库插入参数
  List<Object?> _messageToParams(ChatMessage msg, String deviceId) {
    return MessageMapper.toSqlParams(msg, deviceId: deviceId);
  }

  /// 获取会话的消息列表
  Future<List<ChatMessage>> getMessages(
    String? deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  }) async {
    final effDeviceId = deviceId ?? '';
    // 无 offset 有 limit 时，取最后 N 条（与原实现一致）
    if (offset == null && limit != null && limit > 0) {
      return _getLastNMessages(employeeId, effDeviceId, limit);
    }

    final conditions = <String>['employee_id = ?', 'device_id = ?', 'deleted = 0'];
    final params = <Object?>[employeeId, effDeviceId];

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

    return _db.select(sql, params).map(_rowToMessage).toList();
  }

  /// 获取最后 N 条消息
  Future<List<ChatMessage>> _getLastNMessages(
    String employeeId,
    String deviceId,
    int limit,
  ) async {
    final resultSet = _db.select(
      'SELECT * FROM messages WHERE employee_id = ? AND device_id = ? AND deleted = 0 ORDER BY create_time DESC LIMIT ?',
      [employeeId, deviceId, limit],
    );
    final messages = resultSet.map(_rowToMessage).toList();
    messages.sort((a, b) {
      final timeCompare = a.createdAt.compareTo(b.createdAt);
      if (timeCompare != 0) return timeCompare;
      return a.id.compareTo(b.id);
    });
    return messages;
  }

  /// 获取单条消息
  Future<ChatMessage?> find(String? deviceId, String uuid) async {
    final resultSet = _db.select(
      'SELECT * FROM messages WHERE uuid = ?',
      [uuid],
    );
    for (final row in resultSet) {
      return _rowToMessage(row);
    }
    return null;
  }

  /// 添加消息
  Future<void> add(ChatMessage message) async {
    await addWithDeviceId(
      message.employeeId.split('-').firstOrNull,
      message,
    );
  }

  /// 更新 sync_watermark.last_seq（MAX 语义，防止回退）
  void _updateWatermarkLastSeq(String employeeId, int seq, {String deviceId = ''}) {
    _db.execute('''
      INSERT INTO sync_watermark (employee_id, device_id, last_seq, update_time)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(employee_id, device_id) DO UPDATE SET
          last_seq = MAX(last_seq, excluded.last_seq),
          update_time = excluded.update_time
    ''', [employeeId, deviceId, seq, DateTime.now().millisecondsSinceEpoch]);
  }

  /// 使用明确 deviceId 添加消息
  ///
  /// [updateWatermark] 是否更新同步水位线，默认 true。
  /// 本地临时消息（localOnly）应传 false，避免本地分配的 seq 污染同步水位线。
  Future<void> addWithDeviceId(
    String? deviceId,
    ChatMessage message, {
    bool updateWatermark = true,
  }) async {
    final effDeviceId = deviceId ?? '';
    // 如果 seq 为 0，自动分配下一个序列号
    var msg = message;
    if (msg.seq == 0) {
      msg = msg.copyWith(seq: getNextSeq());
    }
    _db.execute('''
      INSERT OR REPLACE INTO messages (
        uuid, employee_id, device_id, role, type, content,
        tool_call_id, tool_name, tool_arguments, tool_result, tool_calls,
        processing_status, processing_error, input_tokens, output_tokens,
        is_read, deleted, create_time, update_time, seq
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', _messageToParams(msg, effDeviceId));
    if (updateWatermark) {
      _updateWatermarkLastSeq(msg.employeeId, msg.seq, deviceId: effDeviceId);
    }
  }

  /// 更新消息
  Future<void> update(ChatMessage message) async {
    await updateWithDeviceId(
      message.employeeId.split('-').firstOrNull,
      message,
    );
  }
  Future<void> updateWithDeviceId(
    String? deviceId,
    ChatMessage message, {
    bool updateWatermark = true,
  }) async {
    final effDeviceId = deviceId ?? '';
    // 更新时保留原有 seq（如果当前 message 的 seq 为 0 则从 DB 读取）
    var msg = message;
    if (msg.seq == 0) {
      final existing = await find(deviceId, msg.id);
      if (existing != null) {
        msg = msg.copyWith(seq: existing.seq);
      } else {
        msg = msg.copyWith(seq: getNextSeq());
      }
    }
    _db.execute('''
      INSERT OR REPLACE INTO messages (
        uuid, employee_id, device_id, role, type, content,
        tool_call_id, tool_name, tool_arguments, tool_result, tool_calls,
        processing_status, processing_error, input_tokens, output_tokens,
        is_read, deleted, create_time, update_time, seq
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', _messageToParams(msg, effDeviceId));
    if (updateWatermark) {
      _updateWatermarkLastSeq(msg.employeeId, msg.seq, deviceId: effDeviceId);
    }
  }

  /// 更新消息状态
  ///
  /// 更新时同时更新 seq，使状态变更可通过增量同步传播到其他设备。
  /// 这确保了工具调用状态等变更能被远程客户端感知。
  Future<void> updateStatus(
    String? deviceId,
    String uuid,
    MessageStatus status, {
    String? error,
    bool updateWatermark = false,
  }) async {
    final msg = await find(deviceId, uuid);
    if (msg != null) {
      // 分配新的 seq，使状态变更能被增量同步拉取
      final newSeq = getNextSeq();
      final updated = msg.copyWith(
        status: status,
        processingError: error,
        updatedAt: DateTime.now(),
        seq: newSeq,
      );
      await updateWithDeviceId(deviceId, updated, updateWatermark: updateWatermark);
      // 确保水位线反映最新的 seq（即使 updateWatermark=false，seq 本身需要更新）
      final effDeviceId = deviceId ?? '';
      _updateWatermarkLastSeq(msg.employeeId, newSeq, deviceId: effDeviceId);
    }
  }

  /// 删除会话的所有消息
  Future<void> deleteBySession(String? deviceId, String employeeId) async {
    _db.execute(
      'DELETE FROM messages WHERE employee_id = ? AND device_id = ?',
      [employeeId, deviceId ?? ''],
    );
  }

  /// 删除单条消息（硬删除）
  Future<void> delete(String? deviceId, String uuid) async {
    _db.execute('DELETE FROM messages WHERE uuid = ?', [uuid]);
  }

  /// 获取最后一条消息
  Future<ChatMessage?> getLastMessage(
    String? deviceId,
    String employeeId,
  ) async {
    final resultSet = _db.select(
      'SELECT * FROM messages WHERE employee_id = ? AND device_id = ? AND deleted = 0 ORDER BY create_time DESC LIMIT 1',
      [employeeId, deviceId ?? ''],
    );
    for (final row in resultSet) {
      return _rowToMessage(row);
    }
    return null;
  }

  /// 获取消息数量
  Future<int> count(String? deviceId, String employeeId) async {
    final resultSet = _db.select(
      'SELECT COUNT(*) as cnt FROM messages WHERE employee_id = ? AND device_id = ? AND deleted = 0',
      [employeeId, deviceId ?? ''],
    );
    return resultSet.first['cnt'] as int;
  }

  /// 批量更新消息
  ///
  /// 使用事务确保原子性。
  Future<void> batchUpdateWithDeviceId(
    String? deviceId,
    List<ChatMessage> messages,
  ) async {
    final effDeviceId = deviceId ?? '';
    _db.execute('BEGIN');
    try {
      for (var msg in messages) {
        if (msg.seq == 0) {
          msg = msg.copyWith(seq: getNextSeq());
        }
        _db.execute('''
          INSERT OR REPLACE INTO messages (
            uuid, employee_id, device_id, role, type, content,
            tool_call_id, tool_name, tool_arguments, tool_result, tool_calls,
            processing_status, processing_error, input_tokens, output_tokens,
            is_read, deleted, create_time, update_time, seq
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', _messageToParams(msg, effDeviceId));
      }
      // 更新 sync_watermark.last_seq
      for (var msg in messages) {
        _updateWatermarkLastSeq(msg.employeeId, msg.seq, deviceId: effDeviceId);
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 获取下一个可用的 seq 值
  ///
  /// 同时从 messages 表、sync_watermark.last_seq 和 sync_watermark.clear_seq 取最大值，
  /// 确保清空消息后 seq 不会重复，也不会小于 clearSeq。
  int getNextSeq() {
    final msgResult = _db.select(
      'SELECT COALESCE(MAX(seq), 0) as max_seq FROM messages',
    );
    final msgMaxSeq = msgResult.first['max_seq'] as int;

    final wmResult = _db.select(
      'SELECT COALESCE(MAX(last_seq), 0) as max_seq FROM sync_watermark',
    );
    final wmMaxSeq = wmResult.first['max_seq'] as int;

    final clearSeqResult = _db.select(
      'SELECT COALESCE(MAX(clear_seq), 0) as max_clear FROM sync_watermark',
    );
    final clearMaxSeq = clearSeqResult.first['max_clear'] as int;

    final currentMax = [msgMaxSeq, wmMaxSeq, clearMaxSeq].reduce((a, b) => a > b ? a : b);
    return currentMax + 1;
  }

  /// 获取当前最大 seq
  int getMaxSeq() {
    final result = _db.select('SELECT COALESCE(MAX(seq), 0) as max_seq FROM messages');
    return result.first['max_seq'] as int;
  }

  /// 获取指定 employee 的最大 seq
  int getMaxSeqForEmployee(String employeeId) {
    final result = _db.select(
      'SELECT COALESCE(MAX(seq), 0) as max_seq FROM messages WHERE employee_id = ? AND deleted = 0',
      [employeeId],
    );
    return result.first['max_seq'] as int;
  }

  /// 获取指定 employee 的最大 seq（含已软删除的消息）
  ///
  /// 用于服务端上报 maxSeq 给客户端增量同步使用。
  int getMaxSeqForEmployeeAll(String employeeId) {
    final result = _db.select(
      'SELECT COALESCE(MAX(seq), 0) as max_seq FROM messages WHERE employee_id = ?',
      [employeeId],
    );
    return result.first['max_seq'] as int;
  }

  /// 获取指定 employee 的最小 seq（未删除消息）
  ///
  /// 用于客户端同步时判断远程最早保留的消息位置，
  /// 本地 seq < minSeq 的消息可以安全删除。
  /// 如果没有消息返回 0。
  int getMinSeqForEmployee(String employeeId) {
    final result = _db.select(
      'SELECT COALESCE(MIN(seq), 0) as min_seq FROM messages WHERE employee_id = ? AND deleted = 0',
      [employeeId],
    );
    return result.first['min_seq'] as int;
  }

  /// 增量拉取：获取 seq > lastSeq 的消息（包含已软删除的，供 Client 同步删除状态）
  ///
  /// 用于客户端增量同步，按 seq 升序返回。
  /// 注意：包含 deleted=1 的消息，Client 端需根据 deleted 字段执行本地删除。
  Future<List<ChatMessage>> getMessagesAfterSeq(
    String employeeId,
    int lastSeq, {
    int limit = 20,
  }) async {
    final resultSet = _db.select(
      'SELECT * FROM messages WHERE employee_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?',
      [employeeId, lastSeq, limit],
    );
    return resultSet.map(_rowToMessage).toList();
  }

  /// 统计指定员工的未读消息数量（assistant 且 is_read=0）
  int getUnreadCount(String employeeId) {
    final result = _db.select(
      'SELECT COUNT(*) as cnt FROM messages WHERE employee_id = ? AND role = ? AND is_read = 0 AND deleted = 0',
      [employeeId, 'assistant'],
    );
    return result.first['cnt'] as int;
  }

  /// 获取指定员工的未读消息 ID 列表（assistant 且 is_read=0 且 deleted=0）
  List<String> getUnreadMessageIds(String employeeId) {
    final resultSet = _db.select(
      'SELECT uuid FROM messages WHERE employee_id = ? AND role = ? AND is_read = 0 AND deleted = 0 ORDER BY create_time ASC',
      [employeeId, 'assistant'],
    );
    return resultSet.map((row) => row['uuid'] as String).toList();
  }

  /// 获取指定员工中仍处于 processing 状态的本地工具调用消息 ID 列表
  ///
  /// 用于清理 agent 重启后残留的临时工具调用消息。
  List<String> getStaleLocalToolCallMessages(String employeeId) {
    final resultSet = _db.select(
      "SELECT uuid FROM messages WHERE employee_id = ? AND uuid LIKE 'local_toolcall_%' AND processing_status = 'processing' AND deleted = 0",
      [employeeId],
    );
    return resultSet.map((row) => row['uuid'] as String).toList();
  }

  /// 批量标记指定员工的消息为已读（SQL 直接更新，返回受影响行数）
  ///
  /// 同时更新每条消息的 seq，使已读状态变更可通过 LSN 增量拉取同步到其他设备。
  int markAsReadByEmployee(String employeeId, {String deviceId = ''}) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 根据 deviceId 是否为空，构建不同的 SQL 条件
    final String whereClause;
    final List<dynamic> queryParams;
    if (deviceId.isNotEmpty) {
      whereClause = 'employee_id = ? AND device_id = ? AND role = ? AND is_read = 0 AND deleted = 0';
      queryParams = [employeeId, deviceId, 'assistant'];
    } else {
      whereClause = 'employee_id = ? AND role = ? AND is_read = 0 AND deleted = 0';
      queryParams = [employeeId, 'assistant'];
    }

    // 查询需要标记已读的消息（用于后续更新 seq）
    final unreadMessages = _db.select(
      'SELECT uuid FROM messages WHERE $whereClause',
      queryParams,
    );

    if (unreadMessages.isEmpty) return 0;

    // 批量更新 is_read
    _db.execute(
      'UPDATE messages SET is_read = 1, update_time = ? WHERE $whereClause',
      [now, ...queryParams],
    );

    // 为每条消息分配新 seq，使已读变更能被增量同步
    int maxSeq = 0;
    for (final row in unreadMessages) {
      final uuid = row['uuid'] as String;
      final newSeq = getNextSeq();
      if (newSeq > maxSeq) maxSeq = newSeq;
      _db.execute(
        'UPDATE messages SET seq = ? WHERE uuid = ?',
        [newSeq, uuid],
      );
    }

    // 更新水位线
    if (maxSeq > 0) {
      _updateWatermarkLastSeq(employeeId, maxSeq, deviceId: deviceId);
    }

    final result = _db.select('SELECT changes() as affected');
    return result.first['affected'] as int;
  }

  /// 软删除消息并更新 seq（用于同步场景）
  ///
  /// 将消息标记为 deleted=1，同时将 seq 更新为新的更大值，
  /// 使其能被 getMessagesAfterSeq 增量拉取，从而同步删除状态到 Client。
  Future<void> softDeleteForSync(String uuid) async {
    final newSeq = getNextSeq();
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'UPDATE messages SET deleted = 1, seq = ?, update_time = ? WHERE uuid = ?',
      [newSeq, now, uuid],
    );
    // 更新 sync_watermark.last_seq（子查询获取 employeeId + device_id）
    _db.execute('''
      INSERT INTO sync_watermark (employee_id, device_id, last_seq, update_time)
        SELECT employee_id, COALESCE(device_id, ''), ?, ? FROM messages WHERE uuid = ?
        ON CONFLICT(employee_id, device_id) DO UPDATE SET
          last_seq = MAX(last_seq, excluded.last_seq),
          update_time = excluded.update_time
    ''', [newSeq, now, uuid]);
  }

  /// 按会话软删除所有消息并更新 seq（用于 clearCurrentSession 同步场景）
  ///
  /// 将指定 employeeId 的所有消息标记为 deleted=1，
  /// 并为每条消息分配新的 seq，使删除事件能被增量拉取。
  Future<void> softDeleteBySessionForSync(String employeeId, {String deviceId = ''}) async {
    final messages = _db.select(
      'SELECT uuid FROM messages WHERE employee_id = ? AND device_id = ? AND deleted = 0',
      [employeeId, deviceId],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    int maxSeq = 0;
    for (final row in messages) {
      final newSeq = getNextSeq();
      if (newSeq > maxSeq) maxSeq = newSeq;
      _db.execute(
        'UPDATE messages SET deleted = 1, seq = ?, update_time = ? WHERE uuid = ?',
        [newSeq, now, row['uuid'] as String],
      );
    }
    if (maxSeq > 0) {
      _updateWatermarkLastSeq(employeeId, maxSeq, deviceId: deviceId);
    }
  }

  /// 删除指定会话中 seq < beforeSeq 的所有消息（硬删除）
  ///
  /// 用于清空水位线场景：服务端设置 clear_seq 后，
  /// 客户端同步时删除本地所有 seq < clearSeq 的消息。
  /// 返回被删除的消息数量。
  int deleteBeforeSeq(String employeeId, int beforeSeq) {
    _db.execute(
      'DELETE FROM messages WHERE employee_id = ? AND seq < ?',
      [employeeId, beforeSeq],
    );
    final result = _db.select('SELECT changes() as affected');
    return result.first['affected'] as int;
  }
}
