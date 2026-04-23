import 'package:sqlite3/sqlite3.dart';

import '../../shared/shared.dart';
import '../../utils/logger.dart';
import '../database_manager.dart';

/// 消息数据存储
///
/// 使用 SQLite 实现，所有方法直接返回 [ChatMessage]，
/// 通过 [MessageMapper] 统一处理行数据转换。
/// 消息按 employee_id + device_id 隔离，不同设备上同一员工有独立的消息历史。
class MessageStore {
  static final _log = Logger('MessageStore');

  final DatabaseManager _dbManager;

  MessageStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  Database get _db => _dbManager.db;

  /// 暴露 DatabaseManager，供关联 Store 复用（如 SyncWatermarkStore）
  DatabaseManager get dbManager => _dbManager;

  /// 校验 deviceId 有效性，无效时抛出异常
  ///
  /// 设计约束：所有涉及消息和 seq 写入的操作必须传入有效的 deviceId，
  /// 禁止 null、空字符串、'default'，以便通过日志快速定位问题。
  void _validateDeviceId(String? deviceId, String caller) {
    if (deviceId == null || deviceId.isEmpty || deviceId == 'default') {
      throw StateError(
        '[MessageStore] deviceId 无效 (value="$deviceId"), '
        '调用来源: $caller。'
        'deviceId 不允许为 null、空字符串或 "default"，必须传入真实设备标识。',
      );
    }
  }

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
    _validateDeviceId(deviceId, '_updateWatermarkLastSeq');
    _db.execute('''
      INSERT INTO sync_watermark (employee_id, device_id, last_seq, update_time)
        VALUES (?, ?, ?, ?)
      ON CONFLICT(employee_id, device_id) DO UPDATE SET
        last_seq = MAX(last_seq, excluded.last_seq),
        update_time = excluded.update_time
    ''', [employeeId, deviceId, seq, DateTime.now().millisecondsSinceEpoch]);
  }

  /// 使用明确 deviceId 添加消息（upsert）
  ///
  /// seq 分配策略（修复多设备并发冲突）：
  /// - 如果消息携带有效 seq > 0（来自服务端/远程同步），直接使用该 seq，
  ///   并更新水位线（MAX 语义保证不回退）。
  /// - 如果消息 seq == 0（本地新消息），从本地水位线分配新 seq。
  ///
  /// [updateWatermark] 是否更新同步水位线，默认 true。
  /// 本地临时消息（localOnly）应传 false，避免本地分配的 seq 污染同步水位线。
  Future<void> addWithDeviceId(
    String? deviceId,
    ChatMessage message, {
    bool updateWatermark = true,
  }) async {
    _validateDeviceId(deviceId, 'addWithDeviceId');
    final effDeviceId = deviceId!;

    // seq 分配策略：
    // - 远程同步消息携带有效 seq > 0 → 保留原始 seq（服务端是 seq 的权威来源）
    // - 本地新消息 seq == 0 → 从本地水位线分配新 seq
    final int effectiveSeq;
    if (message.seq > 0) {
      effectiveSeq = message.seq;
    } else {
      effectiveSeq = getNextSeq(deviceId: effDeviceId);
    }
    final msg = message.copyWith(seq: effectiveSeq);

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
        msg = msg.copyWith(seq: getNextSeq(deviceId: effDeviceId));
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
      final newSeq = getNextSeq(deviceId: deviceId ?? '');
      final updated = msg.copyWith(
        status: status,
        processingError: error,
        updatedAt: DateTime.now(),
        seq: newSeq,
      );
      await updateWithDeviceId(deviceId, updated, updateWatermark: updateWatermark);
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
          msg = msg.copyWith(seq: getNextSeq(deviceId: effDeviceId));
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
  /// 按 device_id 隔离，保证不同设备的 seq 独立递增。
  ///
  /// 注意：此方法仅用于本地新消息（seq == 0）的分配。
  /// 远程同步消息应保留其原始 seq，不调用此方法。
  int getNextSeq({required String deviceId}) {
    _validateDeviceId(deviceId, 'getNextSeq');
    final msgResult = _db.select(
      'SELECT COALESCE(MAX(seq), 0) as max_seq FROM messages WHERE device_id = ?',
      [deviceId],
    );
    final msgMaxSeq = msgResult.first['max_seq'] as int;

    final wmResult = _db.select(
      'SELECT COALESCE(MAX(last_seq), 0) as max_seq FROM sync_watermark WHERE device_id = ?',
      [deviceId],
    );
    final wmMaxSeq = wmResult.first['max_seq'] as int;

    final clearSeqResult = _db.select(
      'SELECT COALESCE(MAX(clear_seq), 0) as max_clear FROM sync_watermark WHERE device_id = ?',
      [deviceId],
    );
    final clearMaxSeq = clearSeqResult.first['max_clear'] as int;

    final currentMax = [msgMaxSeq, wmMaxSeq, clearMaxSeq].reduce((a, b) => a > b ? a : b);
    return currentMax + 1;
  }

  /// 获取当前最大 seq（按 device_id 隔离）
  int getMaxSeq({String deviceId = ''}) {
    if (deviceId.isNotEmpty) {
      final result = _db.select(
        'SELECT COALESCE(MAX(seq), 0) as max_seq FROM messages WHERE device_id = ?',
        [deviceId],
      );
      return result.first['max_seq'] as int;
    }
    final result = _db.select('SELECT COALESCE(MAX(seq), 0) as max_seq FROM messages');
    return result.first['max_seq'] as int;
  }

  /// 获取指定 employee 的最大 seq（按 device_id 隔离）
  int getMaxSeqForEmployee(String employeeId, {String deviceId = ''}) {
    if (deviceId.isNotEmpty) {
      final result = _db.select(
        'SELECT COALESCE(MAX(seq), 0) as max_seq FROM messages WHERE employee_id = ? AND device_id = ? AND deleted = 0',
        [employeeId, deviceId],
      );
      return result.first['max_seq'] as int;
    }
    final result = _db.select(
      'SELECT COALESCE(MAX(seq), 0) as max_seq FROM messages WHERE employee_id = ? AND deleted = 0',
      [employeeId],
    );
    return result.first['max_seq'] as int;
  }

  /// 获取指定 employee + device 的最大 seq（含已软删除的消息）
  ///
  /// 用于服务端上报 maxSeq 给客户端增量同步使用。
  int getMaxSeqForEmployeeAll(String employeeId, {String deviceId = ''}) {
    if (deviceId.isNotEmpty) {
      final result = _db.select(
        'SELECT COALESCE(MAX(seq), 0) as max_seq FROM messages WHERE employee_id = ? AND device_id = ?',
        [employeeId, deviceId],
      );
      return result.first['max_seq'] as int;
    }
    final result = _db.select(
      'SELECT COALESCE(MAX(seq), 0) as max_seq FROM messages WHERE employee_id = ?',
      [employeeId],
    );
    return result.first['max_seq'] as int;
  }

  /// 获取指定 employee 的最小 seq（按 device_id 隔离，未删除消息）
  int getMinSeqForEmployee(String employeeId, {String deviceId = ''}) {
    if (deviceId.isNotEmpty) {
      final result = _db.select(
        'SELECT COALESCE(MIN(seq), 0) as min_seq FROM messages WHERE employee_id = ? AND device_id = ? AND deleted = 0',
        [employeeId, deviceId],
      );
      return result.first['min_seq'] as int;
    }
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
    String deviceId = '',
    int limit = 20,
  }) async {
    if (deviceId.isNotEmpty) {
      final resultSet = _db.select(
        'SELECT * FROM messages WHERE employee_id = ? AND device_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?',
        [employeeId, deviceId, lastSeq, limit],
      );
      return resultSet.map(_rowToMessage).toList();
    }
    final resultSet = _db.select(
      'SELECT * FROM messages WHERE employee_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?',
      [employeeId, lastSeq, limit],
    );
    return resultSet.map(_rowToMessage).toList();
  }

  /// 统计指定员工的未读消息数量（assistant 且 is_read=0 且 deleted=0）
  ///
  /// [deviceId] 可选，传入时仅统计指定设备的消息，不传则统计所有设备。
  int getUnreadCount(String employeeId, {String? deviceId}) {
    if (deviceId != null && deviceId.isNotEmpty) {
      final result = _db.select(
        'SELECT COUNT(*) as cnt FROM messages WHERE employee_id = ? AND device_id = ? AND role = ? AND is_read = 0 AND deleted = 0',
        [employeeId, deviceId, 'assistant'],
      );
      return result.first['cnt'] as int;
    }
    final result = _db.select(
      'SELECT COUNT(*) as cnt FROM messages WHERE employee_id = ? AND role = ? AND is_read = 0 AND deleted = 0',
      [employeeId, 'assistant'],
    );
    return result.first['cnt'] as int;
  }

  /// 获取指定员工所有消息的已读状态（按 device_id 隔离）
  ///
  /// 返回 Map<uuid, is_read>，用于 Agent 侧恢复已读状态。
  /// 只返回 assistant 角色且未删除的消息。
  Map<String, bool> getReadStatusMap(String employeeId, {String deviceId = ''}) {
    if (deviceId.isNotEmpty) {
      final resultSet = _db.select(
        'SELECT uuid, is_read FROM messages WHERE employee_id = ? AND device_id = ? AND role = ? AND deleted = 0',
        [employeeId, deviceId, 'assistant'],
      );
      return {
        for (final row in resultSet)
          row['uuid'] as String: (row['is_read'] as int) == 1
      };
    }
    final resultSet = _db.select(
      'SELECT uuid, is_read FROM messages WHERE employee_id = ? AND role = ? AND deleted = 0',
      [employeeId, 'assistant'],
    );
    return {
      for (final row in resultSet)
        row['uuid'] as String: (row['is_read'] as int) == 1
    };
  }

  /// 获取指定员工的未读消息 ID 列表（按 device_id 隔离）
  List<String> getUnreadMessageIds(String employeeId, {String deviceId = ''}) {
    if (deviceId.isNotEmpty) {
      final resultSet = _db.select(
        'SELECT uuid FROM messages WHERE employee_id = ? AND device_id = ? AND role = ? AND is_read = 0 AND deleted = 0 ORDER BY create_time ASC',
        [employeeId, deviceId, 'assistant'],
      );
      return resultSet.map((row) => row['uuid'] as String).toList();
    }
    final resultSet = _db.select(
      'SELECT uuid FROM messages WHERE employee_id = ? AND role = ? AND is_read = 0 AND deleted = 0 ORDER BY create_time ASC',
      [employeeId, 'assistant'],
    );
    return resultSet.map((row) => row['uuid'] as String).toList();
  }

  /// 获取指定员工中仍处于 processing 状态的本地工具调用消息 ID 列表（按 device_id 隔离）
  List<String> getStaleLocalToolCallMessages(String employeeId, {String deviceId = ''}) {
    if (deviceId.isNotEmpty) {
      try {
        _log.debug('getStaleLocalToolCallMessages');
        final resultSet = _db.select(
                "SELECT uuid FROM messages WHERE employee_id = ? AND device_id = ? AND uuid LIKE 'local_toolcall_%' AND processing_status = 'processing' AND deleted = 0",
                [employeeId, deviceId],
              );
        _log.debug('success');
        return resultSet.map((row) => row['uuid'] as String).toList();
      } catch (e) {
        _log.error('unknown error', e);
      }
    }
    final resultSet = _db.select(
      "SELECT uuid FROM messages WHERE employee_id = ? AND uuid LIKE 'local_toolcall_%' AND processing_status = 'processing' AND deleted = 0",
      [employeeId],
    );
    return resultSet.map((row) => row['uuid'] as String).toList();
  }

  /// 按 UUID 标记单条消息为已读
  ///
  /// 用于 Agent 侧按消息 ID 逐条标记已读的场景。
  void markAsReadByUuid(String uuid) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'UPDATE messages SET is_read = 1, update_time = ? WHERE uuid = ? AND is_read = 0 AND deleted = 0',
      [now, uuid],
    );
  }

  /// 批量标记指定员工的消息为已读（SQL 直接更新，返回受影响行数）
  ///
  /// 使用单次 UPDATE 批量标记 is_read=1，不再逐条分配 seq。
  /// 已读状态的跨设备同步通过 DeviceNotificationManager + RPC 广播实现。
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

    // 单次 UPDATE（O(1)），不再逐条分配 seq
    _db.execute(
      'UPDATE messages SET is_read = 1, update_time = ? WHERE $whereClause',
      [now, ...queryParams],
    );

    final result = _db.select('SELECT changes() as affected');
    return result.first['affected'] as int;
  }

  /// 基于 seq 批量标记已读
  ///
  /// 将 seq <= readSeq 的所有 assistant 未读消息标记为已读，返回受影响行数
  int markAsReadBySeq(String employeeId, int readSeq, {String deviceId = ''}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (deviceId.isNotEmpty) {
      _db.execute(
        'UPDATE messages SET is_read = 1, update_time = ? '
        'WHERE employee_id = ? AND device_id = ? AND role = ? AND is_read = 0 AND deleted = 0 AND seq <= ?',
        [now, employeeId, deviceId, 'assistant', readSeq],
      );
    } else {
      _db.execute(
        'UPDATE messages SET is_read = 1, update_time = ? '
        'WHERE employee_id = ? AND role = ? AND is_read = 0 AND deleted = 0 AND seq <= ?',
        [now, employeeId, 'assistant', readSeq],
      );
    }
    final result = _db.select('SELECT changes() as affected');
    return result.first['affected'] as int;
  }

  /// 软删除消息并更新 seq（用于同步场景）
  ///
  /// 将消息标记为 deleted=1，同时将 seq 更新为新的更大值，
  /// 使其能被 getMessagesAfterSeq 增量拉取，从而同步删除状态到 Client。
  Future<void> softDeleteForSync(String uuid, {String deviceId = ''}) async {
    final newSeq = getNextSeq(deviceId: deviceId);
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
      final newSeq = getNextSeq(deviceId: deviceId);
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
  int deleteBeforeSeq(String employeeId, int beforeSeq, {String deviceId = ''}) {
    if (deviceId.isNotEmpty) {
      _db.execute(
        'DELETE FROM messages WHERE employee_id = ? AND device_id = ? AND seq < ?',
        [employeeId, deviceId, beforeSeq],
      );
    } else {
      _db.execute(
        'DELETE FROM messages WHERE employee_id = ? AND seq < ?',
        [employeeId, beforeSeq],
      );
    }
    final result = _db.select('SELECT changes() as affected');
    return result.first['affected'] as int;
  }
}
