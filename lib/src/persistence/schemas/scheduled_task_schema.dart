import 'package:sqlite3/sqlite3.dart';

/// scheduled_tasks 表 schema
class ScheduledTaskSchema {
  static void create(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS scheduled_tasks (
        uuid                     TEXT PRIMARY KEY,
        employee_id              TEXT,
        name                     TEXT NOT NULL,
        description              TEXT,
        schedule_type            TEXT DEFAULT 'interval',
        schedule_expression      TEXT DEFAULT 'PT1H',
        repeat_type              TEXT DEFAULT 'recurring',
        task_config              TEXT,
        task_type                TEXT DEFAULT 'reminder',
        enabled                  INTEGER DEFAULT 1,
        deleted                  INTEGER DEFAULT 0,
        start_at                 INTEGER,
        end_at                   INTEGER,
        last_executed_at         INTEGER,
        next_execution_at        INTEGER,
        last_execution_result    TEXT,
        last_execution_error     TEXT,
        consecutive_failures     INTEGER DEFAULT 0,
        max_consecutive_failures INTEGER DEFAULT 5,
        sort_order               INTEGER DEFAULT 0,
        create_time              INTEGER NOT NULL,
        update_time              INTEGER NOT NULL,
        created_by_device_id     TEXT
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_employee
        ON scheduled_tasks(employee_id);
    ''');
  }
}
