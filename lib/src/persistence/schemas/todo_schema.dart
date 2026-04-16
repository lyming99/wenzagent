import 'package:sqlite3/sqlite3.dart';

/// todo_topics 表 schema
class TodoTopicSchema {
  static void create(Database db) {
    db.execute('''
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
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_todo_topics_employee
        ON todo_topics(employee_id);
    ''');
  }
}

/// todo_task_items 表 schema
class TodoTaskItemSchema {
  static void create(Database db) {
    db.execute('''
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
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_todo_task_items_employee
        ON todo_task_items(employee_id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_todo_task_items_topic
        ON todo_task_items(topic_id);
    ''');
  }
}
