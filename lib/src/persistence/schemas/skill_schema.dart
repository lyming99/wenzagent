import 'package:sqlite_async/sqlite_async.dart';

/// skills 表 schema
///
/// Skill 绑定员工（employeeId），不绑定设备（deviceId）。
/// device_id 保留作为元数据，不建索引，不用于查询过滤。
class SkillSchema {
  static Future<void> create(SqliteWriteContext db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS skills (
        uuid         TEXT PRIMARY KEY,
        employee_id  TEXT NOT NULL,
        device_id    TEXT DEFAULT '',
        name         TEXT NOT NULL,
        description  TEXT,
        skill_type   TEXT DEFAULT 'mcp',
        config       TEXT,
        global_skill_id TEXT,
        origin_name   TEXT,
        enabled      INTEGER DEFAULT 1,
        sort_order   INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        delete_time  INTEGER,
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL
      );
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_skills_employee
        ON skills(employee_id);
    ''');
  }
}
