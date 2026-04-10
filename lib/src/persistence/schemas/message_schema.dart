import 'package:sqlite3/sqlite3.dart';

/// messages 表 schema
class MessageSchema {
  static void create(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        uuid              TEXT PRIMARY KEY,
        employee_id       TEXT NOT NULL,
        role              TEXT DEFAULT 'user',
        type              TEXT DEFAULT 'text',
        content           TEXT,
        tool_call_id      TEXT,
        tool_name         TEXT,
        tool_arguments    TEXT,
        tool_result       TEXT,
        tool_calls        TEXT,
        processing_status TEXT DEFAULT 'none',
        processing_error  TEXT,
        input_tokens      INTEGER,
        output_tokens     INTEGER,
        is_read           INTEGER DEFAULT 0,
        deleted           INTEGER DEFAULT 0,
        create_time       INTEGER NOT NULL,
        update_time       INTEGER NOT NULL,
        json_data         TEXT
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_employee
        ON messages(employee_id, create_time);
    ''');
  }
}
