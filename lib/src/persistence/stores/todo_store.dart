import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/todo_group_entity.dart';
import '../entities/todo_item_entity.dart';

/// Todo 数据存储
///
/// 提供 todo 项和分组的 CRUD 操作，所有操作直接读写 SQLite。
class TodoStore {
  final DatabaseManager _dbManager;

  TodoStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  Database get _db => _dbManager.db;

  // ===== TodoItem 操作 =====

  /// 从数据库行解码为 TodoItemEntity
  TodoItemEntity _rowToItem(Row row) {
    return TodoItemEntity.fromMap({
      'id': row['id'],
      'employeeId': row['employee_id'],
      'groupId': row['group_id'],
      'content': row['content'],
      'status': row['status'],
      'sortOrder': row['sort_order'],
      'deleted': row['deleted'],
      'createTime': row['create_time'],
      'updateTime': row['update_time'],
      'completedAt': row['completed_at'],
    });
  }

  /// 查询员工的活跃 todo 项（pending + in_progress）
  List<TodoItemEntity> findActiveByEmployee(String employeeId) {
    final resultSet = _db.select(
      "SELECT * FROM todo_items WHERE employee_id = ? AND deleted = 0 AND status IN ('pending', 'in_progress') ORDER BY sort_order ASC, create_time ASC",
      [employeeId],
    );
    return resultSet.map(_rowToItem).toList();
  }

  /// 查询员工的已完成 todo 项（历史 todo）
  List<TodoItemEntity> findCompletedByEmployee(String employeeId,
      {int limit = 50}) {
    final resultSet = _db.select(
      'SELECT * FROM todo_items WHERE employee_id = ? AND deleted = 0 AND status = ? ORDER BY completed_at DESC LIMIT ?',
      [employeeId, 'completed', limit],
    );
    return resultSet.map(_rowToItem).toList();
  }

  /// 查询指定分组下的所有活跃项
  List<TodoItemEntity> findByGroup(String groupId) {
    final resultSet = _db.select(
      "SELECT * FROM todo_items WHERE group_id = ? AND deleted = 0 AND status IN ('pending', 'in_progress') ORDER BY sort_order ASC, create_time ASC",
      [groupId],
    );
    return resultSet.map(_rowToItem).toList();
  }

  /// 按 ID 查询单个 todo 项
  TodoItemEntity? findById(String id) {
    final resultSet = _db.select(
      'SELECT * FROM todo_items WHERE id = ? AND deleted = 0',
      [id],
    );
    for (final row in resultSet) {
      return _rowToItem(row);
    }
    return null;
  }

  /// 保存 todo 项（INSERT OR REPLACE）
  void save(TodoItemEntity item) {
    _db.execute('''
      INSERT OR REPLACE INTO todo_items (
        id, employee_id, group_id, content, status,
        sort_order, deleted, create_time, update_time, completed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      item.id,
      item.employeeId,
      item.groupId,
      item.content,
      item.status,
      item.sortOrder,
      item.deleted,
      item.createTime.millisecondsSinceEpoch,
      item.updateTime.millisecondsSinceEpoch,
      item.completedAt?.millisecondsSinceEpoch,
    ]);
  }

  /// 更新状态，completed 时同时设置 completedAt
  void updateStatus(String id, String status) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (status == 'completed') {
      _db.execute(
        'UPDATE todo_items SET status = ?, completed_at = ?, update_time = ? WHERE id = ?',
        [status, now, now, id],
      );
    } else {
      _db.execute(
        'UPDATE todo_items SET status = ?, update_time = ? WHERE id = ?',
        [status, now, id],
      );
    }
  }

  /// 更新内容
  void updateContent(String id, String content) {
    _db.execute(
      'UPDATE todo_items SET content = ?, update_time = ? WHERE id = ?',
      [content, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  /// 移动到分组（groupId 可为 null 表示移出分组）
  void moveToGroup(String id, String? groupId) {
    _db.execute(
      'UPDATE todo_items SET group_id = ?, update_time = ? WHERE id = ?',
      [groupId, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  /// 软删除
  void softDelete(String id) {
    _db.execute(
      'UPDATE todo_items SET deleted = 1, update_time = ? WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  /// 批量硬删除已完成的项
  void deleteCompletedByEmployee(String employeeId) {
    _db.execute(
      'DELETE FROM todo_items WHERE employee_id = ? AND status = ?',
      [employeeId, 'completed'],
    );
  }

  /// 按状态统计数量
  Map<String, int> countByStatus(String employeeId) {
    final resultSet = _db.select(
      'SELECT status, COUNT(*) as cnt FROM todo_items WHERE employee_id = ? AND deleted = 0 GROUP BY status',
      [employeeId],
    );
    final result = <String, int>{
      'pending': 0,
      'in_progress': 0,
      'completed': 0,
    };
    for (final row in resultSet) {
      final status = row['status'] as String;
      final cnt = row['cnt'] as int;
      result[status] = cnt;
    }
    return result;
  }

  // ===== TodoGroup 操作 =====

  /// 从数据库行解码为 TodoGroupEntity
  TodoGroupEntity _rowToGroup(Row row) {
    return TodoGroupEntity.fromMap({
      'id': row['id'],
      'employeeId': row['employee_id'],
      'name': row['name'],
      'sortOrder': row['sort_order'],
      'deleted': row['deleted'],
      'createTime': row['create_time'],
      'updateTime': row['update_time'],
    });
  }

  /// 查询员工的所有分组
  List<TodoGroupEntity> findGroupsByEmployee(String employeeId) {
    final resultSet = _db.select(
      'SELECT * FROM todo_groups WHERE employee_id = ? AND deleted = 0 ORDER BY sort_order ASC',
      [employeeId],
    );
    return resultSet.map(_rowToGroup).toList();
  }

  /// 按 ID 查询单个分组
  TodoGroupEntity? findGroupById(String id) {
    final resultSet = _db.select(
      'SELECT * FROM todo_groups WHERE id = ? AND deleted = 0',
      [id],
    );
    for (final row in resultSet) {
      return _rowToGroup(row);
    }
    return null;
  }

  /// 按名称查找分组（用于 add 时自动关联）
  TodoGroupEntity? findGroupByName(String employeeId, String name) {
    final resultSet = _db.select(
      'SELECT * FROM todo_groups WHERE employee_id = ? AND name = ? AND deleted = 0',
      [employeeId, name],
    );
    for (final row in resultSet) {
      return _rowToGroup(row);
    }
    return null;
  }

  /// 保存分组（INSERT OR REPLACE）
  void saveGroup(TodoGroupEntity group) {
    _db.execute('''
      INSERT OR REPLACE INTO todo_groups (
        id, employee_id, name, sort_order, deleted, create_time, update_time
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
    ''', [
      group.id,
      group.employeeId,
      group.name,
      group.sortOrder,
      group.deleted,
      group.createTime.millisecondsSinceEpoch,
      group.updateTime.millisecondsSinceEpoch,
    ]);
  }

  /// 软删除分组（同时将该分组下的 todo 项的 groupId 置 null）
  void softDeleteGroup(String id) {
    final now = DateTime.now().millisecondsSinceEpoch;
    // 先将该分组下的 todo 项移至未分组
    _db.execute(
      'UPDATE todo_items SET group_id = NULL, update_time = ? WHERE group_id = ?',
      [now, id],
    );
    // 软删除分组
    _db.execute(
      'UPDATE todo_groups SET deleted = 1, update_time = ? WHERE id = ?',
      [now, id],
    );
  }

  /// 重命名分组
  void renameGroup(String id, String name) {
    _db.execute(
      'UPDATE todo_groups SET name = ?, update_time = ? WHERE id = ?',
      [name, DateTime.now().millisecondsSinceEpoch, id],
    );
  }
}
