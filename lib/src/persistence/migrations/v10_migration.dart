import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';

/// 版本 10: 新增 todo_groups 和 todo_items 表
///
/// 内置 Todo 系统持久化，支持分组管理。
///
/// 注意：v13 迁移已将这些表重构为 todo_topics + todo_task_items。
/// 此迁移保留原始 SQL 以便从 v9 直接升级到 v13 时能正确执行中间步骤。
class V10Migration extends Migration {
  @override
  int get version => 10;

  @override
  void onUpgrade(Database db) {
    // 原始 todo_groups 表（v13 中将被迁移为 todo_topics）
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

    // 原始 todo_items 表（v13 中将被迁移为 todo_task_items）
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
