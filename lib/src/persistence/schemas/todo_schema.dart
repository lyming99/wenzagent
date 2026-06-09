import 'package:sqlite_async/sqlite_async.dart';

/// todo_topics 表 schema
class TodoTopicSchema {
  static Future<void> create(SqliteWriteContext db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS todo_topics (
        id           TEXT PRIMARY KEY,
        employee_id  TEXT NOT NULL,
        title        TEXT NOT NULL,
        description  TEXT DEFAULT '',
        status       TEXT DEFAULT 'pending',
        sort_order   INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL,
        completed_at INTEGER
      );
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_todo_topics_employee
        ON todo_topics(employee_id);
    ''');
    // 兼容旧表缺少 completed_at 列的情况
    await _ensureColumn(db, 'todo_topics', 'completed_at', 'INTEGER');
  }

  static Future<void> _ensureColumn(
    SqliteWriteContext db,
    String table,
    String column,
    String type,
  ) async {
    try {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
    } catch (_) {
      // 列已存在，忽略
    }
  }
}

/// todo_task_items 表 schema
class TodoTaskItemSchema {
  static Future<void> create(SqliteWriteContext db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS todo_task_items (
        id           TEXT PRIMARY KEY,
        employee_id  TEXT NOT NULL,
        topic_id     TEXT NOT NULL,
        title        TEXT NOT NULL,
        content      TEXT DEFAULT '',
        status       TEXT DEFAULT 'pending',
        sort_order   INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL,
        completed_at INTEGER
      );
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_todo_task_items_employee
        ON todo_task_items(employee_id);
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_todo_task_items_topic
        ON todo_task_items(topic_id);
    ''');
    // 兼容旧表缺少 completed_at 列的情况
    await TodoTopicSchema._ensureColumn(
      db,
      'todo_task_items',
      'completed_at',
      'INTEGER',
    );
  }
}
