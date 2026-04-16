import 'package:sqlite3/sqlite3.dart';

import '../schemas/todo_schema.dart';
import 'migration.dart';

/// 版本 13: 重构 Spec 和 Todo 数据模型
///
/// Spec: 去掉分组，扁平化
/// Todo: 分组改为 Topic + TaskItem 模型
class V13Migration extends Migration {
  @override
  int get version => 13;

  @override
  void onUpgrade(Database db) {
    // ===== 1. 重构 spec_items 表（去掉 group_id） =====
    db.execute('''
      CREATE TABLE IF NOT EXISTS spec_items_new (
        id           TEXT PRIMARY KEY,
        employee_id  TEXT NOT NULL,
        title        TEXT NOT NULL,
        content      TEXT DEFAULT '',
        status       TEXT DEFAULT 'pending',
        priority     TEXT DEFAULT 'medium',
        tags         TEXT DEFAULT '',
        sort_order   INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL
      );
    ''');
    db.execute('''
      INSERT OR IGNORE INTO spec_items_new
        (id, employee_id, title, content, status, priority, tags, sort_order, deleted, create_time, update_time)
        SELECT id, employee_id, title, content, status, priority, tags, sort_order, deleted, create_time, update_time
        FROM spec_items
    ''');
    db.execute('DROP TABLE IF EXISTS spec_items');
    db.execute('ALTER TABLE spec_items_new RENAME TO spec_items');
    db.execute('CREATE INDEX IF NOT EXISTS idx_spec_items_employee ON spec_items(employee_id)');

    // ===== 2. 删除 spec_groups 表 =====
    db.execute('DROP TABLE IF EXISTS spec_groups');
    db.execute('DROP INDEX IF EXISTS idx_spec_groups_employee');

    // ===== 3. 创建 todo_topics 表并迁移旧 todo_groups 数据 =====
    TodoTopicSchema.create(db);
    db.execute('''
      INSERT OR IGNORE INTO todo_topics
        (id, employee_id, title, description, status, sort_order, deleted, create_time, update_time, completed_at)
        SELECT id, employee_id, name, '', 'pending', sort_order, deleted, create_time, update_time, NULL
        FROM todo_groups WHERE deleted = 0
    ''');
    db.execute('DROP TABLE IF EXISTS todo_groups');
    db.execute('DROP INDEX IF EXISTS idx_todo_groups_employee');

    // ===== 4. 创建 todo_task_items 表并迁移旧 todo_items 数据 =====
    TodoTaskItemSchema.create(db);
    db.execute('''
      INSERT OR IGNORE INTO todo_task_items
        (id, employee_id, topic_id, title, content, status, sort_order, deleted, create_time, update_time, completed_at)
        SELECT id, employee_id, group_id, content, '', status, sort_order, deleted, create_time, update_time, completed_at
        FROM todo_items WHERE deleted = 0
    ''');
    db.execute('DROP TABLE IF EXISTS todo_items');
    db.execute('DROP INDEX IF EXISTS idx_todo_items_employee');
    db.execute('DROP INDEX IF EXISTS idx_todo_items_group');

    // ===== 5. 推导 todo_topics 的 status =====
    _recalculateTopicStatuses(db);
  }

  void _recalculateTopicStatuses(Database db) {
    // 有 in_progress 子项的 topic
    db.execute('''
      UPDATE todo_topics SET status = 'in_progress'
      WHERE id IN (
        SELECT DISTINCT topic_id FROM todo_task_items
        WHERE status = 'in_progress' AND deleted = 0
      ) AND deleted = 0
    ''');

    // 所有活跃子项都 completed 的 topic
    db.execute('''
      UPDATE todo_topics SET status = 'completed', completed_at = ?
      WHERE id IN (
        SELECT t.topic_id FROM todo_task_items t
        WHERE t.deleted = 0
        GROUP BY t.topic_id
        HAVING COUNT(*) = SUM(CASE WHEN t.status = 'completed' THEN 1 ELSE 0 END)
      ) AND deleted = 0 AND status != 'completed'
    ''', [DateTime.now().millisecondsSinceEpoch]);

    // 其余保持 pending（默认值）
  }
}
