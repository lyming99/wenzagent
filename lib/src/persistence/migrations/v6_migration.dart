import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';

/// 版本 6: 创建标记已读队列表
///
/// 远程模式下，设备标记消息已读的请求需要持久化，
/// 断线重连后自动重新发送，确保已读状态不会因网络中断而丢失。
class V6Migration extends Migration {
  @override
  int get version => 6;

  @override
  void onUpgrade(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS mark_read_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id TEXT NOT NULL,
        reader_device_id TEXT NOT NULL,
        message_ids TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
  }
}
