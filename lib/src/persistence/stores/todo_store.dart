import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/todo_topic_entity.dart';
import '../entities/todo_task_item_entity.dart';

/// Todo 数据存储
///
/// 提供 Todo Topic 和 TaskItem 的 CRUD 操作，所有操作直接读写 SQLite。
class TodoStore {
  final DatabaseManager _dbManager;

  TodoStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  Database get _db {
    if (!_dbManager.isInitialized) {
      throw StateError(
        '$runtimeType: DatabaseManager 未初始化，请先调用 initialize()。',
      );
    }
    return _dbManager.db;
  }

  // ===== TodoTopic 操作 =====

  TodoTopicEntity _rowToTopic(Row row) {
    return TodoTopicEntity.fromMap({
      'id': row['id'],
      'employeeId': row['employee_id'],
      'title': row['title'],
      'description': row['description'],
      'status': row['status'],
      'sortOrder': row['sort_order'],
      'deleted': row['deleted'],
      'createTime': row['create_time'],
      'updateTime': row['update_time'],
      'completedAt': row['completed_at'],
    });
  }

  /// 查询当前待办主题（有子项正在进行）
  List<TodoTopicEntity> findCurrentTopics(String employeeId) {
    final resultSet = _db.select(
      "SELECT * FROM todo_topics WHERE employee_id = ? AND deleted = 0 AND status = 'in_progress' ORDER BY sort_order ASC, create_time ASC",
      [employeeId],
    );
    return resultSet.map(_rowToTopic).toList();
  }

  /// 查询待处理待办主题（pending，不含 in_progress）
  List<TodoTopicEntity> findPendingTopics(String employeeId) {
    final resultSet = _db.select(
      "SELECT * FROM todo_topics WHERE employee_id = ? AND deleted = 0 AND status = 'pending' ORDER BY sort_order ASC, create_time ASC",
      [employeeId],
    );
    return resultSet.map(_rowToTopic).toList();
  }

  /// 查询所有待办主题
  List<TodoTopicEntity> findAllTopics(String employeeId) {
    final resultSet = _db.select(
      'SELECT * FROM todo_topics WHERE employee_id = ? AND deleted = 0 ORDER BY sort_order ASC, create_time ASC',
      [employeeId],
    );
    return resultSet.map(_rowToTopic).toList();
  }

  /// 查询所有待办主题（含已删除）
  List<TodoTopicEntity> findAllTopicsIncludingDeleted(String employeeId) {
    final resultSet = _db.select(
      'SELECT * FROM todo_topics WHERE employee_id = ? ORDER BY sort_order ASC, create_time ASC',
      [employeeId],
    );
    return resultSet.map(_rowToTopic).toList();
  }

  /// 查询已完成主题
  List<TodoTopicEntity> findCompletedTopics(String employeeId, {int limit = 50}) {
    final resultSet = _db.select(
      "SELECT * FROM todo_topics WHERE employee_id = ? AND deleted = 0 AND status = 'completed' ORDER BY completed_at DESC LIMIT ?",
      [employeeId, limit],
    );
    return resultSet.map(_rowToTopic).toList();
  }

  /// 按 ID 查询单个主题
  TodoTopicEntity? findTopicById(String id) {
    final resultSet = _db.select(
      'SELECT * FROM todo_topics WHERE id = ? AND deleted = 0',
      [id],
    );
    for (final row in resultSet) {
      return _rowToTopic(row);
    }
    return null;
  }

  /// 保存主题
  void saveTopic(TodoTopicEntity topic) {
    _db.execute('''
      INSERT OR REPLACE INTO todo_topics (
        id, employee_id, title, description, status,
        sort_order, deleted, create_time, update_time, completed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      topic.id,
      topic.employeeId,
      topic.title,
      topic.description,
      topic.status,
      topic.sortOrder,
      topic.deleted,
      topic.createTime.millisecondsSinceEpoch,
      topic.updateTime.millisecondsSinceEpoch,
      topic.completedAt?.millisecondsSinceEpoch,
    ]);
  }

  /// 更新主题内容
  void updateTopicContent(String id, {String? title, String? description}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (title != null && description != null) {
      _db.execute(
        'UPDATE todo_topics SET title = ?, description = ?, update_time = ? WHERE id = ?',
        [title, description, now, id],
      );
    } else if (title != null) {
      _db.execute(
        'UPDATE todo_topics SET title = ?, update_time = ? WHERE id = ?',
        [title, now, id],
      );
    } else if (description != null) {
      _db.execute(
        'UPDATE todo_topics SET description = ?, update_time = ? WHERE id = ?',
        [description, now, id],
      );
    }
  }

  /// 软删除主题（同时软删除所有子项）
  void softDeleteTopic(String id) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'UPDATE todo_task_items SET deleted = 1, update_time = ? WHERE topic_id = ?',
      [now, id],
    );
    _db.execute(
      'UPDATE todo_topics SET deleted = 1, update_time = ? WHERE id = ?',
      [now, id],
    );
  }

  /// 批量硬删除已完成主题
  void deleteCompletedTopics(String employeeId) {
    // 先删除已完成主题下的子项
    _db.execute('''
      DELETE FROM todo_task_items WHERE topic_id IN (
        SELECT id FROM todo_topics WHERE employee_id = ? AND status = 'completed'
      )
    ''', [employeeId]);
    // 再删除已完成主题
    _db.execute(
      "DELETE FROM todo_topics WHERE employee_id = ? AND status = 'completed'",
      [employeeId],
    );
  }

  /// 推导主题状态（根据子项状态）
  void recalculateTopicStatus(String topicId) {
    final resultSet = _db.select(
      'SELECT status, COUNT(*) as cnt FROM todo_task_items WHERE topic_id = ? AND deleted = 0 GROUP BY status',
      [topicId],
    );

    int totalCount = 0;
    int completedCount = 0;
    bool hasInProgress = false;

    for (final row in resultSet) {
      final status = row['status'] as String;
      final cnt = row['cnt'] as int;
      totalCount += cnt;
      if (status == 'completed') completedCount += cnt;
      if (status == 'in_progress') hasInProgress = true;
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    if (totalCount == 0) {
      // 无子项，保持 pending
      _db.execute(
        "UPDATE todo_topics SET status = 'pending', completed_at = NULL, update_time = ? WHERE id = ?",
        [now, topicId],
      );
    } else if (hasInProgress) {
      _db.execute(
        "UPDATE todo_topics SET status = 'in_progress', update_time = ? WHERE id = ?",
        [now, topicId],
      );
    } else if (completedCount == totalCount) {
      _db.execute(
        "UPDATE todo_topics SET status = 'completed', completed_at = ?, update_time = ? WHERE id = ?",
        [now, now, topicId],
      );
    } else {
      _db.execute(
        "UPDATE todo_topics SET status = 'pending', completed_at = NULL, update_time = ? WHERE id = ?",
        [now, topicId],
      );
    }
  }

  /// 按 ID 查询单个主题（含已删除）
  TodoTopicEntity? findTopicByIdIncludingDeleted(String id) {
    final resultSet = _db.select(
      'SELECT * FROM todo_topics WHERE id = ?',
      [id],
    );
    for (final row in resultSet) {
      return _rowToTopic(row);
    }
    return null;
  }

  /// 按 ID 查询单个任务子项（含已删除）
  TodoTaskItemEntity? findTaskItemByIdIncludingDeleted(String id) {
    final resultSet = _db.select(
      'SELECT * FROM todo_task_items WHERE id = ?',
      [id],
    );
    for (final row in resultSet) {
      return _rowToTaskItem(row);
    }
    return null;
  }

  /// 按状态统计主题数量
  Map<String, int> countTopicsByStatus(String employeeId) {
    final resultSet = _db.select(
      'SELECT status, COUNT(*) as cnt FROM todo_topics WHERE employee_id = ? AND deleted = 0 GROUP BY status',
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

  // ===== TodoTaskItem 操作 =====

  TodoTaskItemEntity _rowToTaskItem(Row row) {
    return TodoTaskItemEntity.fromMap({
      'id': row['id'],
      'employeeId': row['employee_id'],
      'topicId': row['topic_id'],
      'title': row['title'],
      'content': row['content'],
      'status': row['status'],
      'sortOrder': row['sort_order'],
      'deleted': row['deleted'],
      'createTime': row['create_time'],
      'updateTime': row['update_time'],
      'completedAt': row['completed_at'],
    });
  }

  /// 查询主题下的所有任务子项
  List<TodoTaskItemEntity> findTaskItemsByTopic(String topicId) {
    final resultSet = _db.select(
      'SELECT * FROM todo_task_items WHERE topic_id = ? AND deleted = 0 ORDER BY sort_order ASC, create_time ASC',
      [topicId],
    );
    return resultSet.map(_rowToTaskItem).toList();
  }

  /// 按 ID 查询单个任务子项
  TodoTaskItemEntity? findTaskItemById(String id) {
    final resultSet = _db.select(
      'SELECT * FROM todo_task_items WHERE id = ? AND deleted = 0',
      [id],
    );
    for (final row in resultSet) {
      return _rowToTaskItem(row);
    }
    return null;
  }

  /// 保存任务子项
  void saveTaskItem(TodoTaskItemEntity item) {
    _db.execute('''
      INSERT OR REPLACE INTO todo_task_items (
        id, employee_id, topic_id, title, content, status,
        sort_order, deleted, create_time, update_time, completed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      item.id,
      item.employeeId,
      item.topicId,
      item.title,
      item.content,
      item.status,
      item.sortOrder,
      item.deleted,
      item.createTime.millisecondsSinceEpoch,
      item.updateTime.millisecondsSinceEpoch,
      item.completedAt?.millisecondsSinceEpoch,
    ]);
  }

  /// 更新任务子项内容
  void updateTaskItemContent(String id, {String? title, String? content}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (title != null && content != null) {
      _db.execute(
        'UPDATE todo_task_items SET title = ?, content = ?, update_time = ? WHERE id = ?',
        [title, content, now, id],
      );
    } else if (title != null) {
      _db.execute(
        'UPDATE todo_task_items SET title = ?, update_time = ? WHERE id = ?',
        [title, now, id],
      );
    } else if (content != null) {
      _db.execute(
        'UPDATE todo_task_items SET content = ?, update_time = ? WHERE id = ?',
        [content, now, id],
      );
    }
  }

  /// 更新任务子项状态，completed 时同时设置 completedAt
  void updateTaskItemStatus(String id, String status) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (status == 'completed') {
      _db.execute(
        'UPDATE todo_task_items SET status = ?, completed_at = ?, update_time = ? WHERE id = ?',
        [status, now, now, id],
      );
    } else {
      _db.execute(
        'UPDATE todo_task_items SET status = ?, completed_at = NULL, update_time = ? WHERE id = ?',
        [status, now, id],
      );
    }
  }

  /// 软删除任务子项
  void softDeleteTaskItem(String id) {
    _db.execute(
      'UPDATE todo_task_items SET deleted = 1, update_time = ? WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  /// 更新主题状态
  void updateTopicStatus(String id, String status) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (status == 'completed') {
      _db.execute(
        "UPDATE todo_topics SET status = ?, completed_at = ?, update_time = ? WHERE id = ?",
        [status, now, now, id],
      );
    } else {
      _db.execute(
        "UPDATE todo_topics SET status = ?, completed_at = NULL, update_time = ? WHERE id = ?",
        [status, now, id],
      );
    }
  }

  /// 批量更新主题排序（事务）
  void reorderTopics(List<String> topicIds) {
    _db.execute('BEGIN TRANSACTION');
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (int i = 0; i < topicIds.length; i++) {
        _db.execute(
          'UPDATE todo_topics SET sort_order = ?, update_time = ? WHERE id = ?',
          [i, now, topicIds[i]],
        );
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ===== 远程同步 merge 方法 =====

  /// 从远程数据 merge 写入单个 TodoTopic
  ///
  /// 合并策略：
  /// - 本地不存在 → INSERT
  /// - 远程 updateTime > 本地 updateTime → UPDATE
  /// - 软删除合并：取 deleted=1 的一方（双方都删除则保留较新的）
  ///
  /// 返回 true 表示数据有变化（新增或更新）
  bool upsertTopicFromRemote(TodoTopicEntity remote) {
    final existing = findTopicByIdIncludingDeleted(remote.id);
    if (existing == null) {
      // 本地不存在 → 直接插入
      saveTopic(remote);
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
      saveTopic(base.copyWith(deleted: mergedDeleted));
      return true;
    }
    return false;
  }

  /// 从远程数据 merge 写入单个 TodoTaskItem
  ///
  /// 合并策略同 [upsertTopicFromRemote]
  bool upsertTaskItemFromRemote(TodoTaskItemEntity remote) {
    final existing = findTaskItemByIdIncludingDeleted(remote.id);
    if (existing == null) {
      // 本地不存在 → 直接插入
      saveTaskItem(remote);
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
      saveTaskItem(base.copyWith(deleted: mergedDeleted));
      return true;
    }
    return false;
  }

  /// 从远程数据 merge 写入多个 TodoTopic（批量）
  ///
  /// 返回有变化的条数
  int upsertAllTopicsFromRemote(List<TodoTopicEntity> items) {
    int changedCount = 0;
    for (final item in items) {
      if (upsertTopicFromRemote(item)) {
        changedCount++;
      }
    }
    return changedCount;
  }

  /// 从远程数据 merge 写入多个 TodoTaskItem（批量）
  ///
  /// 返回有变化的条数
  int upsertAllTaskItemsFromRemote(List<TodoTaskItemEntity> items) {
    int changedCount = 0;
    for (final item in items) {
      if (upsertTaskItemFromRemote(item)) {
        changedCount++;
      }
    }
    return changedCount;
  }

  /// 批量更新任务子项排序（事务）
  void reorderTaskItems(List<String> taskItemIds) {
    _db.execute('BEGIN TRANSACTION');
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (int i = 0; i < taskItemIds.length; i++) {
        _db.execute(
          'UPDATE todo_task_items SET sort_order = ?, update_time = ? WHERE id = ?',
          [i, now, taskItemIds[i]],
        );
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }
}
