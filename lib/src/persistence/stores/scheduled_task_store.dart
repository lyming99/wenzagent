import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/scheduled_task_entity.dart';

/// 定时任务数据存储
///
/// 使用 SQLite 实现，保持与原 Hive 版本完全相同的公共 API。
class ScheduledTaskStore {
  final DatabaseManager _dbManager;

  ScheduledTaskStore({DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.instance;

  Database get _db => _dbManager.db;

  /// 从数据库行解码为实体
  AiScheduledTaskEntity _rowToEntity(Row row) {
    return AiScheduledTaskEntity.fromMap({
      'uuid': row['uuid'],
      'employeeId': row['employee_id'],
      'name': row['name'],
      'description': row['description'],
      'scheduleType': row['schedule_type'],
      'scheduleExpression': row['schedule_expression'],
      'repeatType': row['repeat_type'],
      'taskConfig': row['task_config'],
      'taskType': row['task_type'],
      'enabled': row['enabled'],
      'deleted': row['deleted'],
      'startAt': row['start_at'],
      'endAt': row['end_at'],
      'lastExecutedAt': row['last_executed_at'],
      'nextExecutionAt': row['next_execution_at'],
      'lastExecutionResult': row['last_execution_result'],
      'lastExecutionError': row['last_execution_error'],
      'consecutiveFailures': row['consecutive_failures'],
      'maxConsecutiveFailures': row['max_consecutive_failures'],
      'sortOrder': row['sort_order'],
      'createTime': row['create_time'],
      'updateTime': row['update_time'],
      'createdByDeviceId': row['created_by_device_id'],
    });
  }

  /// 获取所有未删除的任务
  Future<List<AiScheduledTaskEntity>> findAll() async {
    final resultSet = _db.select(
      'SELECT * FROM scheduled_tasks WHERE deleted = 0 ORDER BY sort_order ASC',
    );
    return resultSet.map(_rowToEntity).toList();
  }

  /// 获取指定员工的任务
  Future<List<AiScheduledTaskEntity>> findByEmployee(
      String employeeId) async {
    final resultSet = _db.select(
      'SELECT * FROM scheduled_tasks WHERE employee_id = ? AND deleted = 0 ORDER BY sort_order ASC',
      [employeeId],
    );
    return resultSet.map(_rowToEntity).toList();
  }

  /// 查找单个任务
  Future<AiScheduledTaskEntity?> find(String uuid) async {
    final resultSet = _db.select(
      'SELECT * FROM scheduled_tasks WHERE uuid = ?',
      [uuid],
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 保存任务（INSERT OR REPLACE）
  Future<void> save(AiScheduledTaskEntity entity) async {
    _db.execute('''
      INSERT OR REPLACE INTO scheduled_tasks (
        uuid, employee_id, name, description,
        schedule_type, schedule_expression, repeat_type,
        task_config, task_type, enabled, deleted,
        start_at, end_at, last_executed_at, next_execution_at,
        last_execution_result, last_execution_error,
        consecutive_failures, max_consecutive_failures, sort_order,
        create_time, update_time, created_by_device_id
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      entity.uuid,
      entity.employeeId,
      entity.name,
      entity.description,
      entity.scheduleType,
      entity.scheduleExpression,
      entity.repeatType,
      entity.taskConfig,
      entity.taskType,
      entity.enabled,
      entity.deleted,
      entity.startAt?.millisecondsSinceEpoch,
      entity.endAt?.millisecondsSinceEpoch,
      entity.lastExecutedAt?.millisecondsSinceEpoch,
      entity.nextExecutionAt?.millisecondsSinceEpoch,
      entity.lastExecutionResult,
      entity.lastExecutionError,
      entity.consecutiveFailures,
      entity.maxConsecutiveFailures,
      entity.sortOrder,
      entity.createTime.millisecondsSinceEpoch,
      entity.updateTime.millisecondsSinceEpoch,
      entity.createdByDeviceId,
    ]);
  }

  /// 删除任务（软删除）
  Future<void> delete(String uuid) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'UPDATE scheduled_tasks SET deleted = 1, enabled = 0, update_time = ? WHERE uuid = ?',
      [now, uuid],
    );
  }

  /// 硬删除
  Future<void> hardDelete(String uuid) async {
    _db.execute(
      'DELETE FROM scheduled_tasks WHERE uuid = ?',
      [uuid],
    );
  }

  /// 删除员工的所有任务（软删除）
  Future<void> deleteByEmployee(String employeeId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'UPDATE scheduled_tasks SET deleted = 1, enabled = 0, update_time = ? WHERE employee_id = ?',
      [now, employeeId],
    );
  }

  /// 获取需要执行的任务
  Future<List<AiScheduledTaskEntity>> findDueTasks() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final resultSet = _db.select(
      '''SELECT * FROM scheduled_tasks
         WHERE deleted = 0
           AND enabled = 1
           AND (start_at IS NULL OR start_at <= ?)
           AND (end_at IS NULL OR end_at > ?)
           AND next_execution_at IS NOT NULL
           AND next_execution_at <= ?
         ORDER BY sort_order ASC''',
      [now, now, now],
    );
    return resultSet.map(_rowToEntity).toList();
  }
}
