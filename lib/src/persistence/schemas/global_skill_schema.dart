import 'package:sqlite3/sqlite3.dart';

/// global_skills 表 schema
class GlobalSkillSchema {
  static void create(Database db) {
    db.execute('''
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
