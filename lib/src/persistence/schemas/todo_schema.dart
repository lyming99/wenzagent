import 'package:sqlite3/sqlite3.dart';

/// todo_groups 表 schema
class TodoGroupSchema {
  static void create(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS todo_groups (
        id           TEXT PRIMARY KEY,
        employee_id  TEXT NOT NULL,
        name         TEXT NOT NULL,
        sort_order   INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_todo_groups_employee
        ON todo_groups(employee_id);
    ''');
  }
}

/// todo_items 表 schema
class TodoItemSchema {
  static void create(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS todo_items (
        id           TEXT PRIMARY KEY,
        employee_id  TEXT NOT NULL,
        group_id     TEXT,
        content      TEXT NOT NULL,
        status       TEXT DEFAULT 'pending',
        sort_order   INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL,
        completed_at INTEGER
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_todo_items_employee
        ON todo_items(employee_id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_todo_items_group
        ON todo_items(group_id);
    ''');
  }
}
