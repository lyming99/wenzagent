import 'package:sqlite_async/sqlite_async.dart';

/// sync_watermark 表 schema
///
/// 记录每个 employee（会话）的消息同步水位线，
/// 客户端通过 last_seq 知道自己已同步到哪条消息。
class SyncWatermarkSchema {
  static Future<void> create(SqliteDatabase db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_watermark (
        employee_id  TEXT NOT NULL,
        device_id    TEXT NOT NULL DEFAULT '',
        last_seq     INTEGER NOT NULL DEFAULT 0,
        clear_seq    INTEGER DEFAULT NULL,
        update_time  INTEGER NOT NULL,
        PRIMARY KEY (employee_id, device_id)
      )
    ''');
  }
}
