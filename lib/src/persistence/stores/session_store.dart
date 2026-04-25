import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/session_entity.dart';

/// 会话数据存储
///
/// 使用 SQLite 实现，保持与原 Hive 版本完全相同的公共 API。
/// 主键：employeeId（一个员工只有一个会话）。
class SessionStore {
  final DatabaseManager _dbManager;

  SessionStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  Database get _db {
    if (!_dbManager.isInitialized) {
      throw StateError(
        '$runtimeType: DatabaseManager 未初始化，请先调用 initialize()。',
      );
    }
    return _dbManager.db;
  }

  /// 从数据库行解码为实体
  AiEmployeeSessionEntity _rowToEntity(Row row) {
    Map<String, DeviceSessionConfig> configMap = {};
    final configStr = row['config'] as String?;
    if (configStr != null && configStr.isNotEmpty) {
      final raw = jsonDecode(configStr) as Map<String, dynamic>;
      configMap = raw.map((key, value) => MapEntry(
          key,
          DeviceSessionConfig.fromMap(value as Map<String, dynamic>)));
    }

    return AiEmployeeSessionEntity(
      employeeId: row['employee_id'] as String,
      config: configMap,
      title: (row['title'] as String?) ?? '新对话',
      isArchived: (row['is_archived'] as int?) ?? 0,
      isPinned: (row['is_pinned'] as int?) ?? 0,
      deleted: (row['deleted'] as int?) ?? 0,
      deleteTime: row['delete_time'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['delete_time'] as int)
          : null,
      createTime: DateTime.fromMillisecondsSinceEpoch(
          row['create_time'] as int),
      updateTime: DateTime.fromMillisecondsSinceEpoch(
          row['update_time'] as int),
    );
  }

  /// 获取Session（主键查找）
  Future<AiEmployeeSessionEntity?> find(String employeeId) async {
    final resultSet = _db.select(
      'SELECT * FROM sessions WHERE employee_id = ?',
      [employeeId],
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 获取或创建Session
  ///
  /// 如果会话处于已删除状态，自动复活（清除 deleted 和 deleteTime）
  Future<AiEmployeeSessionEntity> getOrCreate(String employeeId) async {
    var session = await find(employeeId);
    if (session != null) {
      if (session.deleted == 1) {
        session = session.copyWith(
          deleted: 0,
          deleteTime: null,
          updateTime: DateTime.now(),
        );
        await save(session);
      }
      return session;
    }

    final now = DateTime.now();
    session = AiEmployeeSessionEntity(
      employeeId: employeeId,
      createTime: now,
      updateTime: now,
    );

    await save(session);
    return session;
  }

  /// 保存Session（INSERT OR REPLACE）
  Future<void> save(AiEmployeeSessionEntity session) async {
    _db.execute('''
      INSERT OR REPLACE INTO sessions (
        employee_id, config, title, is_archived, is_pinned,
        deleted, delete_time, create_time, update_time
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      session.employeeId,
      jsonEncode(session.config.map((k, v) => MapEntry(k, v.toMap()))),
      session.title,
      session.isArchived,
      session.isPinned,
      session.deleted,
      session.deleteTime?.millisecondsSinceEpoch,
      session.createTime.millisecondsSinceEpoch,
      session.updateTime.millisecondsSinceEpoch,
    ]);
  }

  /// 获取所有Session（会话列表）
  Future<List<AiEmployeeSessionEntity>> findAll({
    bool includeArchived = false,
    bool includeDeleted = false,
  }) async {
    final conditions = <String>[];
    final params = <Object?>[];

    if (!includeDeleted) {
      // 只排除真正软删除的会话（deleted == 1）
      conditions.add('deleted != 1');
    }
    if (!includeArchived) {
      conditions.add('is_archived != 1');
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final sql =
        'SELECT * FROM sessions $where ORDER BY is_pinned DESC, update_time DESC';

    return _db.select(sql, params).map(_rowToEntity).toList();
  }

  /// 删除Session（软删除，记录 deleteTime）
  Future<void> delete(String employeeId) async {
    final session = await find(employeeId);
    if (session != null) {
      final now = DateTime.now();
      await save(session.copyWith(
        deleted: 1,
        deleteTime: now,
        updateTime: now,
      ));
    }
  }

  /// 硬删除Session
  Future<void> hardDelete(String employeeId) async {
    _db.execute('DELETE FROM sessions WHERE employee_id = ?', [employeeId]);
  }

  /// 获取会话数量
  Future<int> count() async {
    final sessions = await findAll();
    return sessions.length;
  }
}
