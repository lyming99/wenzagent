import 'package:sqlite_async/sqlite_async.dart';

/// global_skills 表 schema
class GlobalSkillSchema {
  static Future<void> create(SqliteDatabase db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS global_skills (
        uuid         TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        description  TEXT,
        skill_type   TEXT DEFAULT 'config',
        config       TEXT,
        enabled      INTEGER DEFAULT 1,
        sort_order   INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        delete_time  INTEGER,
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL
      );
    ''');
  }
}
