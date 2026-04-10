import 'package:sqlite3/sqlite3.dart';

/// skills 表 schema
class SkillSchema {
  static void create(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS skills (
        uuid         TEXT PRIMARY KEY,
        employee_id  TEXT NOT NULL,
        name         TEXT NOT NULL,
        description  TEXT,
        skill_type   TEXT DEFAULT 'mcp',
        config       TEXT,
        enabled      INTEGER DEFAULT 1,
        sort_order   INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_skills_employee
        ON skills(employee_id);
    ''');
  }
}
