import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';

/// 标记已读队列数据存储
///
/// 远程模式下，设备标记消息已读的请求会持久化到此队列，
/// 断线重连后自动重新发送，确保已读状态不会因网络中断而丢失。
class MarkReadQueueStore {
  final DatabaseManager _dbManager;

  MarkReadQueueStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  Database get _db => _dbManager.db;

  /// 添加标记已读请求到队列
  ///
  /// [employeeId] 员工ID
  /// [readerDeviceId] 读取设备ID
  /// [messageIds] 指定消息ID列表，为 null 表示标记全部
  void enqueue({
    required String employeeId,
    required String readerDeviceId,
    List<String>? messageIds,
  }) {
    final messageIdsJson = messageIds != null ? jsonEncode(messageIds) : null;
    _db.execute(
      'INSERT INTO mark_read_queue (employee_id, reader_device_id, message_ids, created_at) VALUES (?, ?, ?, ?)',
      [employeeId, readerDeviceId, messageIdsJson, DateTime.now().millisecondsSinceEpoch],
    );
  }

  /// 获取指定员工的待发送标记已读请求
  ///
  /// [employeeId] 员工ID，为 null 则获取所有
  List<MarkReadQueueEntry> getPending({String? employeeId}) {
    final conditions = <String>[];
    final params = <Object?>[];

    if (employeeId != null) {
      conditions.add('employee_id = ?');
      params.add(employeeId);
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final resultSet = _db.select(
      'SELECT * FROM mark_read_queue $where ORDER BY created_at ASC',
      params,
    );

    return resultSet.map((row) => MarkReadQueueEntry(
      id: row['id'] as int,
      employeeId: row['employee_id'] as String,
      readerDeviceId: row['reader_device_id'] as String,
      messageIdsJson: row['message_ids'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    )).toList();
  }

  /// 移除已发送的队列项
  void remove(int id) {
    _db.execute('DELETE FROM mark_read_queue WHERE id = ?', [id]);
  }

  /// 批量移除已发送的队列项
  void removeAll(List<int> ids) {
    if (ids.isEmpty) return;
    final placeholders = ids.map((_) => '?').join(',');
    _db.execute(
      'DELETE FROM mark_read_queue WHERE id IN ($placeholders)',
      ids,
    );
  }

  /// 清空指定员工的队列
  void clear({String? employeeId}) {
    if (employeeId != null) {
      _db.execute('DELETE FROM mark_read_queue WHERE employee_id = ?', [employeeId]);
    } else {
      _db.execute('DELETE FROM mark_read_queue');
    }
  }

  /// 获取指定员工的待处理队列数量
  int count({String? employeeId}) {
    final conditions = <String>[];
    final params = <Object?>[];

    if (employeeId != null) {
      conditions.add('employee_id = ?');
      params.add(employeeId);
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final result = _db.select(
      'SELECT COUNT(*) as cnt FROM mark_read_queue $where',
      params,
    );
    return result.first['cnt'] as int;
  }
}

/// 标记已读队列条目
class MarkReadQueueEntry {
  final int id;
  final String employeeId;
  final String readerDeviceId;
  final String? messageIdsJson;
  final DateTime createdAt;

  MarkReadQueueEntry({
    required this.id,
    required this.employeeId,
    required this.readerDeviceId,
    this.messageIdsJson,
    required this.createdAt,
  });

  /// 解析消息ID列表
  List<String>? get messageIds {
    if (messageIdsJson == null) return null;
    return (jsonDecode(messageIdsJson!) as List).cast<String>();
  }
}
