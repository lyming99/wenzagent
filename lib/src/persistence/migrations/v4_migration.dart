import 'package:sqlite_async/sqlite_async.dart';

import 'migration.dart';

/// 版本 4: 移除 messages 表的 json_data 冗余列
///
/// json_data 列在 v1 中用于存储完整的消息 JSON 快照（双重写入），
/// Phase 1/2 重构后所有字段已扁平化到独立列，json_data 不再被使用。
/// 此迁移通过表重建模式移除该列。
class V4Migration extends Migration {
  @override
  int get version => 4;

  /// 检查表中是否存在指定列
  Future<bool> _columnExists(
    SqliteDatabase db,
    String table,
    String column,
  ) async {
    final result = await db.getAll('''
      SELECT count(*) as cnt FROM pragma_table_info('$table')
        WHERE name = '$column'
    ''');
    return (result.first['cnt'] as int) > 0;
  }

  @override
  Future<void> onUpgrade(SqliteDatabase db) async {
    // 如果 json_data 列不存在，说明已经是 V4 schema，无需迁移
    if (!await _columnExists(db, 'messages', 'json_data')) {
      return;
    }

    // 创建新表（不含 json_data 列）
    await db.execute('''
      CREATE TABLE messages_new (
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
        seq               INTEGER NOT NULL
      )
    ''');

    // 迁移数据（排除 json_data）
    await db.execute('''
      INSERT INTO messages_new (
        uuid, employee_id, role, type, content,
        tool_call_id, tool_name, tool_arguments, tool_result, tool_calls,
        processing_status, processing_error, input_tokens, output_tokens,
        is_read, deleted, create_time, update_time, seq
      )
      SELECT
        uuid, employee_id, role, type, content,
        tool_call_id, tool_name, tool_arguments, tool_result, tool_calls,
        processing_status, processing_error, input_tokens, output_tokens,
        is_read, deleted, create_time, update_time, seq
      FROM messages
    ''');

    await db.execute('DROP TABLE messages');
    await db.execute('ALTER TABLE messages_new RENAME TO messages');

    // 重建索引
    await db.execute('DROP INDEX IF EXISTS idx_messages_employee');
    await db.execute('DROP INDEX IF EXISTS idx_messages_seq');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_employee
        ON messages(employee_id, create_time)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_seq
        ON messages(seq)
    ''');
  }
}
