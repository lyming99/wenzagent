import 'package:sqlite_async/sqlite_async.dart';

/// sessions 表 schema
class SessionSchema {
  static Future<void> create(SqliteWriteContext db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sessions (
        employee_id  TEXT PRIMARY KEY,
        config       TEXT NOT NULL DEFAULT '{}',
        title        TEXT DEFAULT '新对话',
        is_archived  INTEGER DEFAULT 0,
        is_pinned    INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        delete_time  INTEGER,
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL
      );
    ''');
  }
}
