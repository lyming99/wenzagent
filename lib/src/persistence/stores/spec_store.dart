import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/spec_item_entity.dart';

/// Spec 数据存储
///
/// 提供 spec 项的 CRUD 操作，所有操作直接读写 SQLite。
class SpecStore {
  final DatabaseManager _dbManager;

  SpecStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  Database get _db => _dbManager.db;

  // ===== SpecItem 操作 =====

  /// 从数据库行解码为 SpecItemEntity
  SpecItemEntity _rowToItem(Row row) {
    return SpecItemEntity.fromMap({
      'id': row['id'],
      'employeeId': row['employee_id'],
      'title': row['title'],
      'content': row['content'],
      'status': row['status'],
      'priority': row['priority'],
      'tags': row['tags'],
      'sortOrder': row['sort_order'],
      'deleted': row['deleted'],
      'createTime': row['create_time'],
      'updateTime': row['update_time'],
    });
  }

  /// 查询员工的活跃 spec 项（pending + in_progress + draft）
  List<SpecItemEntity> findActiveByEmployee(String employeeId) {
    final resultSet = _db.select(
      "SELECT * FROM spec_items WHERE employee_id = ? AND deleted = 0 AND status IN ('draft', 'pending', 'in_progress') ORDER BY sort_order ASC, create_time ASC",
      [employeeId],
    );
    return resultSet.map(_rowToItem).toList();
  }

  /// 查询员工的已完成 spec 项
  List<SpecItemEntity> findCompletedByEmployee(String employeeId,
      {int limit = 50}) {
    final resultSet = _db.select(
      'SELECT * FROM spec_items WHERE employee_id = ? AND deleted = 0 AND status = ? ORDER BY update_time DESC LIMIT ?',
      [employeeId, 'completed', limit],
    );
    return resultSet.map(_rowToItem).toList();
  }

  /// 按 ID 查询单个 spec 项
  SpecItemEntity? findById(String id) {
    final resultSet = _db.select(
      'SELECT * FROM spec_items WHERE id = ? AND deleted = 0',
      [id],
    );
    for (final row in resultSet) {
      return _rowToItem(row);
    }
    return null;
  }

  /// 保存 spec 项（INSERT OR REPLACE）
  void save(SpecItemEntity item) {
    _db.execute('''
      INSERT OR REPLACE INTO spec_items (
        id, employee_id, title, content, status,
        priority, tags, sort_order, deleted, create_time, update_time
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      item.id,
      item.employeeId,
      item.title,
      item.content,
      item.status,
      item.priority,
      item.tags,
      item.sortOrder,
      item.deleted,
      item.createTime.millisecondsSinceEpoch,
      item.updateTime.millisecondsSinceEpoch,
    ]);
  }

  /// 更新状态
  void updateStatus(String id, String status) {
    _db.execute(
      'UPDATE spec_items SET status = ?, update_time = ? WHERE id = ?',
      [status, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  /// 更新内容
  void updateContent(String id, {String? title, String? content}) {
    if (title != null && content != null) {
      _db.execute(
        'UPDATE spec_items SET title = ?, content = ?, update_time = ? WHERE id = ?',
        [title, content, DateTime.now().millisecondsSinceEpoch, id],
      );
    } else if (title != null) {
      _db.execute(
        'UPDATE spec_items SET title = ?, update_time = ? WHERE id = ?',
        [title, DateTime.now().millisecondsSinceEpoch, id],
      );
    } else if (content != null) {
      _db.execute(
        'UPDATE spec_items SET content = ?, update_time = ? WHERE id = ?',
        [content, DateTime.now().millisecondsSinceEpoch, id],
      );
    }
  }

  /// 软删除
  void softDelete(String id) {
    _db.execute(
      'UPDATE spec_items SET deleted = 1, update_time = ? WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  /// 批量硬删除已完成的项
  void deleteCompletedByEmployee(String employeeId) {
    _db.execute(
      'DELETE FROM spec_items WHERE employee_id = ? AND status = ?',
      [employeeId, 'completed'],
    );
  }

  /// 按状态统计数量
  Map<String, int> countByStatus(String employeeId) {
    final resultSet = _db.select(
      'SELECT status, COUNT(*) as cnt FROM spec_items WHERE employee_id = ? AND deleted = 0 GROUP BY status',
      [employeeId],
    );
    final result = <String, int>{
      'draft': 0,
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
}
