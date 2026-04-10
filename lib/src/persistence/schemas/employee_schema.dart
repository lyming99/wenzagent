import 'package:sqlite3/sqlite3.dart';

/// employees 表 schema
class EmployeeSchema {
  static void create(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS employees (
        uuid             TEXT PRIMARY KEY,
        space_id         TEXT,
        name             TEXT NOT NULL,
        avatar           TEXT,
        role             TEXT DEFAULT 'assistant',
        status           TEXT DEFAULT 'active',
        description      TEXT,
        system_prompt    TEXT,
        provider         TEXT,
        model            TEXT,
        api_key          TEXT,
        api_base_url     TEXT,
        model_config     TEXT,
        project_uuid     TEXT,
        project_name     TEXT,
        project_context  TEXT,
        work_path        TEXT,
        enable_tools     INTEGER DEFAULT 1,
        enable_mcp       INTEGER DEFAULT 0,
        mcp_config       TEXT,
        permission_config TEXT,
        device_id        TEXT,
        current_device_id TEXT,
        auto_approve     INTEGER DEFAULT 0,
        sort_order       INTEGER DEFAULT 0,
        is_pinned        INTEGER DEFAULT 0,
        deleted          INTEGER DEFAULT 0,
        deleted_time     INTEGER,
        create_time      INTEGER NOT NULL,
        update_time      INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_employees_space
        ON employees(space_id);
    ''');
  }
}
