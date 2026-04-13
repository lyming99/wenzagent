import 'package:sqlite3/sqlite3.dart';

/// sync_watermark 表 schema
///
/// 记录每个 employee（会话）的消息同步水位线，
/// 客户端通过 last_seq 知道自己已同步到哪条消息。
class SyncWatermarkSchema {
  static void create(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS sync_watermark (
        employee_id  TEXT PRIMARY KEY,
        last_seq     INTEGER NOT NULL DEFAULT 0,
        clear_seq    INTEGER DEFAULT NULL,
        update_time  INTEGER NOT NULL
      )
    ''');
  }
}
