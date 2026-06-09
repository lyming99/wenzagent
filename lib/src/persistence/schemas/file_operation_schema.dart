import 'package:sqlite_async/sqlite_async.dart';

/// file_operations 表 schema
class FileOperationSchema {
  static Future<void> create(SqliteWriteContext db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS file_operations (
        id              TEXT PRIMARY KEY,
        employee_id     TEXT NOT NULL,
        message_id      TEXT,
        tool_call_id    TEXT,
        tool_name       TEXT NOT NULL,
        operation_type  TEXT NOT NULL,
        path            TEXT NOT NULL,
        file_size       INTEGER,
        extra           TEXT,
        success         INTEGER NOT NULL DEFAULT 1,
        error_message   TEXT,
        created_at      INTEGER NOT NULL
      );
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_file_ops_employee
        ON file_operations(employee_id, created_at DESC);
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_file_ops_message
        ON file_operations(message_id);
    ''');
  }
}
