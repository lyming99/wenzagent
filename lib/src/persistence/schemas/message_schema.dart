import 'package:sqlite3/sqlite3.dart';

/// messages 表 schema
class MessageSchema {
  static void create(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        uuid              TEXT PRIMARY KEY,
        employee_id       TEXT NOT NULL,
        device_id         TEXT NOT NULL DEFAULT '',
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
        metadata          TEXT,
        deleted           INTEGER DEFAULT 0,
        create_time       INTEGER NOT NULL,
        update_time       INTEGER NOT NULL,
        seq               INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_employee
        ON messages(employee_id, device_id, create_time);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_seq
        ON messages(seq);
    ''');

    // 迁移：为已有数据库增加 metadata 列
    try {
      db.execute('ALTER TABLE messages ADD COLUMN metadata TEXT');
    } catch (_) {
      // 列已存在，忽略
    }
  }
}
