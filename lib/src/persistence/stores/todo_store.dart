import 'package:sqlite_async/sqlite_async.dart';

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

  SqliteDatabase get _db {
    if (!_dbManager.isInitialized) {
      throw StateError(
        '$runtimeType: DatabaseManager 未初始化，请先调用 initialize()。',
      );
    }
    return _dbManager.db;
  }

  // ===== TodoTopic 操作 =====

  TodoTopicEntity _rowToTopic(Map<String, Object?> row) {
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
  Future<List<TodoTopicEntity>> findCurrentTopics(String employeeId) async {
    final resultSet = await _db.getAll(
      "SELECT * FROM todo_topics WHERE employee_id = ? AND deleted = 0 AND status = 'in_progress' ORDER BY sort_order ASC, create_time ASC",
      [employeeId],
    );
    return resultSet.map(_rowToTopic).toList();
  }

  /// 查询待处理待办主题（pending，不含 in_progress）
  Future<List<TodoTopicEntity>> findPendingTopics(String employeeId) async {
    final resultSet = await _db.getAll(
      "SELECT * FROM todo_topics WHERE employee_id = ? AND deleted = 0 AND status = 'pending' ORDER BY sort_order ASC, create_time ASC",
      [employeeId],
    );
    return resultSet.map(_rowToTopic).toList();
  }

  /// 查询所有待办主题
  Future<List<TodoTopicEntity>> findAllTopics(String employeeId) async {
    final resultSet = await _db.getAll(
      'SELECT * FROM todo_topics WHERE employee_id = ? AND deleted = 0 ORDER BY sort_order ASC, create_time ASC',
      [employeeId],
    );
    return resultSet.map(_rowToTopic).toList();
  }

  /// 查询所有待办主题（含已删除）
  Future<List<TodoTopicEntity>> findAllTopicsIncludingDeleted(String employeeId) async {
    final resultSet = await _db.getAll(
      'SELECT * FROM todo_topics WHERE employee_id = ? ORDER BY sort_order ASC, create_time ASC',
      [employeeId],
    );
    return resultSet.map(_rowToTopic).toList();
  }

  /// 查询已完成主题
  Future<List<TodoTopicEntity>> findCompletedTopics(String employeeId, {int limit = 50}) async {
    final resultSet = await _db.getAll(
      "SELECT * FROM todo_topics WHERE employee_id = ? AND deleted = 0 AND status = 'completed' ORDER BY completed_at DESC LIMIT ?",
      [employeeId, limit],
    );
    return resultSet.map(_rowToTopic).toList();
  }

  /// 按 ID 查询单个主题
  Future<TodoTopicEntity?> findTopicById(String id) async {
    final resultSet = await _db.getAll(
      'SELECT * FROM todo_topics WHERE id = ? AND deleted = 0',
      [id],
    );
    for (final row in resultSet) {
      return _rowToTopic(row);
    }
    return null;
  }

  /// 保存主题
  Future<void> saveTopic(TodoTopicEntity topic) async {
    await _db.execute('''
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
  Future<void> updateTopicContent(String id, {String? title, String? description}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (title != null && description != null) {
      await _db.execute(
        'UPDATE todo_topics SET title = ?, description = ?, update_time = ? WHERE id = ?',
        [title, description, now, id],
      );
    } else if (title != null) {
      await _db.execute(
        'UPDATE todo_topics SET title = ?, update_time = ? WHERE id = ?',
        [title, now, id],
      );
    } else if (description != null) {
      await _db.execute(
        'UPDATE todo_topics SET description = ?, update_time = ? WHERE id = ?',
        [description, now, id],
      );
    }
  }

  /// 软删除主题（同时软删除所有子项）
  Future<void> softDeleteTopic(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.execute(
      'UPDATE todo_task_items SET deleted = 1, update_time = ? WHERE topic_id = ?',
      [now, id],
    );
    await _db.execute(
      'UPDATE todo_topics SET deleted = 1, update_time = ? WHERE id = ?',
      [now, id],
    );
  }

  /// 批量硬删除已完成主题
  Future<void> deleteCompletedTopics(String employeeId) async {
    // 先删除已完成主题下的子项
    await _db.execute('''
      DELETE FROM todo_task_items WHERE topic_id IN (
        SELECT id FROM todo_topics WHERE employee_id = ? AND status = 'completed'
      )
    ''', [employeeId]);
    // 再删除已完成主题
    await _db.execute(
      "DELETE FROM todo_topics WHERE employee_id = ? AND status = 'completed'",
      [employeeId],
    );
  }

  /// 推导主题状态（根据子项状态）
  Future<void> recalculateTopicStatus(String topicId) async {
    final resultSet = await _db.getAll(
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
      await _db.execute(
        "UPDATE todo_topics SET status = 'pending', completed_at = NULL, update_time = ? WHERE id = ?",
        [now, topicId],
      );
    } else if (hasInProgress) {
      await _db.execute(
        "UPDATE todo_topics SET status = 'in_progress', update_time = ? WHERE id = ?",
        [now, topicId],
      );
    } else if (completedCount == totalCount) {
      await _db.execute(
        "UPDATE todo_topics SET status = 'completed', completed_at = ?, update_time = ? WHERE id = ?",
        [now, now, topicId],
      );
    } else {
      await _db.execute(
        "UPDATE todo_topics SET status = 'pending', completed_at = NULL, update_time = ? WHERE id = ?",
        [now, topicId],
      );
    }
  }

  /// 按 ID 查询单个主题（含已删除）
  Future<TodoTopicEntity?> findTopicByIdIncludingDeleted(String id) async {
    final resultSet = await _db.getAll(
      'SELECT * FROM todo_topics WHERE id = ?',
      [id],
    );
    for (final row in resultSet) {
      return _rowToTopic(row);
    }
    return null;
  }

  /// 按 ID 查询单个任务子项（含已删除）
  Future<TodoTaskItemEntity?> findTaskItemByIdIncludingDeleted(String id) async {
    final resultSet = await _db.getAll(
      'SELECT * FROM todo_task_items WHERE id = ?',
      [id],
    );
    for (final row in resultSet) {
      return _rowToTaskItem(row);
    }
    return null;
  }

  /// 按状态统计主题数量
  Future<Map<String, int>> countTopicsByStatus(String employeeId) async {
    final resultSet = await _db.getAll(
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

  /// 统计所有非删除 topic 的总数量（含已完成）
  Future<int> countAllTopics(String employeeId) async {
    final resultSet = await _db.getAll(
      'SELECT COUNT(*) as cnt FROM todo_topics WHERE employee_id = ? AND deleted = 0',
      [employeeId],
    );
    return resultSet.first['cnt'] as int;
  }

  // ===== TodoTaskItem 操作 =====

  TodoTaskItemEntity _rowToTaskItem(Map<String, Object?> row) {
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
  Future<List<TodoTaskItemEntity>> findTaskItemsByTopic(String topicId) async {
    final resultSet = await _db.getAll(
      'SELECT * FROM todo_task_items WHERE topic_id = ? AND deleted = 0 ORDER BY sort_order ASC, create_time ASC',
      [topicId],
    );
    return resultSet.map(_rowToTaskItem).toList();
  }

  /// 按 ID 查询单个任务子项
  Future<TodoTaskItemEntity?> findTaskItemById(String id) async {
    final resultSet = await _db.getAll(
      'SELECT * FROM todo_task_items WHERE id = ? AND deleted = 0',
      [id],
    );
    for (final row in resultSet) {
      return _rowToTaskItem(row);
    }
    return null;
  }

  /// 保存任务子项
  Future<void> saveTaskItem(TodoTaskItemEntity item) async {
    await _db.execute('''
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
  Future<void> updateTaskItemContent(String id, {String? title, String? content}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (title != null && content != null) {
      await _db.execute(
        'UPDATE todo_task_items SET title = ?, content = ?, update_time = ? WHERE id = ?',
        [title, content, now, id],
      );
    } else if (title != null) {
      await _db.execute(
        'UPDATE todo_task_items SET title = ?, update_time = ? WHERE id = ?',
        [title, now, id],
      );
    } else if (content != null) {
      await _db.execute(
        'UPDATE todo_task_items SET content = ?, update_time = ? WHERE id = ?',
        [content, now, id],
      );
    }
  }

  /// 更新任务子项状态，completed 时同时设置 completedAt
  Future<void> updateTaskItemStatus(String id, String status) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (status == 'completed') {
      await _db.execute(
        'UPDATE todo_task_items SET status = ?, completed_at = ?, update_time = ? WHERE id = ?',
        [status, now, now, id],
      );
    } else {
      await _db.execute(
        'UPDATE todo_task_items SET status = ?, completed_at = NULL, update_time = ? WHERE id = ?',
        [status, now, id],
      );
    }
  }

  /// 软删除任务子项
  Future<void> softDeleteTaskItem(String id) async {
    await _db.execute(
      'UPDATE todo_task_items SET deleted = 1, update_time = ? WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  /// 更新主题状态
  Future<void> updateTopicStatus(String id, String status) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (status == 'completed') {
      await _db.execute(
        "UPDATE todo_topics SET status = ?, completed_at = ?, update_time = ? WHERE id = ?",
        [status, now, now, id],
      );
    } else {
      await _db.execute(
        "UPDATE todo_topics SET status = ?, completed_at = NULL, update_time = ? WHERE id = ?",
        [status, now, id],
      );
    }
  }

  /// 批量更新主题排序（事务）
  Future<void> reorderTopics(List<String> topicIds) async {
    await _db.writeTransaction((tx) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (int i = 0; i < topicIds.length; i++) {
        await tx.execute(
          'UPDATE todo_topics SET sort_order = ?, update_time = ? WHERE id = ?',
          [i, now, topicIds[i]],
        );
      }
    });
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
  Future<bool> upsertTopicFromRemote(TodoTopicEntity remote) async {
    final existing = await findTopicByIdIncludingDeleted(remote.id);
    if (existing == null) {
      // 本地不存在 → 直接插入
      await saveTopic(remote);
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
      await saveTopic(base.copyWith(deleted: mergedDeleted));
      return true;
    }
    return false;
  }

  /// 从远程数据 merge 写入单个 TodoTaskItem
  ///
  /// 合并策略同 [upsertTopicFromRemote]
  Future<bool> upsertTaskItemFromRemote(TodoTaskItemEntity remote) async {
    final existing = await findTaskItemByIdIncludingDeleted(remote.id);
    if (existing == null) {
      // 本地不存在 → 直接插入
      await saveTaskItem(remote);
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
      await saveTaskItem(base.copyWith(deleted: mergedDeleted));
      return true;
    }
    return false;
  }

  /// 从远程数据 merge 写入多个 TodoTopic（批量）
  ///
  /// 返回有变化的条数
  Future<int> upsertAllTopicsFromRemote(List<TodoTopicEntity> items) async {
    int changedCount = 0;
    for (final item in items) {
      if (await upsertTopicFromRemote(item)) {
        changedCount++;
      }
    }
    return changedCount;
  }

  /// 从远程数据 merge 写入多个 TodoTaskItem（批量）
  ///
  /// 返回有变化的条数
  Future<int> upsertAllTaskItemsFromRemote(List<TodoTaskItemEntity> items) async {
    int changedCount = 0;
    for (final item in items) {
      if (await upsertTaskItemFromRemote(item)) {
        changedCount++;
      }
    }
    return changedCount;
  }

  /// 批量更新任务子项排序（事务）
  Future<void> reorderTaskItems(List<String> taskItemIds) async {
    await _db.writeTransaction((tx) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (int i = 0; i < taskItemIds.length; i++) {
        await tx.execute(
          'UPDATE todo_task_items SET sort_order = ?, update_time = ? WHERE id = ?',
          [i, now, taskItemIds[i]],
        );
      }
    });
  }
}
