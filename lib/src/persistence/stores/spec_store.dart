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

  Database get _db {
    if (!_dbManager.isInitialized) {
      throw StateError(
        '$runtimeType: DatabaseManager 未初始化，请先调用 initialize()。',
      );
    }
    return _dbManager.db;
  }

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

  /// 按 ID 查询单个 spec 项（不含已删除）
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

  /// 按 ID 查询单个 spec 项（含已删除）
  SpecItemEntity? findByIdIncludingDeleted(String id) {
    final resultSet = _db.select(
      'SELECT * FROM spec_items WHERE id = ?',
      [id],
    );
    for (final row in resultSet) {
      return _rowToItem(row);
    }
    return null;
  }

  /// 查询员工的所有 spec 项（含已删除）
  List<SpecItemEntity> findAllByEmployee(String employeeId) {
    final resultSet = _db.select(
      'SELECT * FROM spec_items WHERE employee_id = ? ORDER BY sort_order ASC, create_time ASC',
      [employeeId],
    );
    return resultSet.map(_rowToItem).toList();
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

  /// 批量更新 spec 排序（事务）
  void reorderSpecs(List<String> specIds) {
    _db.execute('BEGIN TRANSACTION');
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (int i = 0; i < specIds.length; i++) {
        _db.execute(
          'UPDATE spec_items SET sort_order = ?, update_time = ? WHERE id = ?',
          [i, now, specIds[i]],
        );
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ===== 远程同步 merge 方法 =====

  /// 从远程数据 merge 写入单个 spec 项
  ///
  /// 合并策略：
  /// - 本地不存在 → INSERT
  /// - 远程 updateTime > 本地 updateTime → UPDATE
  /// - 软删除合并：取 deleted=1 的一方（双方都删除则保留较新的）
  ///
  /// 返回 true 表示数据有变化（新增或更新）
  bool upsertFromRemote(SpecItemEntity remote) {
    final existing = findByIdIncludingDeleted(remote.id);
    if (existing == null) {
      // 本地不存在 → 直接插入
      save(remote);
      return true;
    }

    // 基于 updateTime 判断是否需要更新数据
    final shouldUpdateData = remote.updateTime.isAfter(existing.updateTime);

    // 软删除合并：deleted=1 优先，双方都为 1 则保留较新的
    int mergedDeleted;
    if (remote.deleted == 1 && existing.deleted == 0) {
      mergedDeleted = 1;
    } else if (existing.deleted == 1 && remote.deleted == 0) {
      mergedDeleted = 1;
    } else {
      // 双方相同（都为 0 或都为 1）
      mergedDeleted = remote.deleted;
    }

    final shouldUpdateDelete = mergedDeleted != existing.deleted;

    if (shouldUpdateData || shouldUpdateDelete) {
      final base = shouldUpdateData ? remote : existing;
      save(base.copyWith(deleted: mergedDeleted));
      return true;
    }
    return false;
  }

  /// 从远程数据 merge 写入多个 spec 项（批量）
  ///
  /// 返回有变化的条数
  int upsertAllFromRemote(List<SpecItemEntity> items) {
    int changedCount = 0;
    for (final item in items) {
      if (upsertFromRemote(item)) {
        changedCount++;
      }
    }
    return changedCount;
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
