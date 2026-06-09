import 'package:sqlite_async/sqlite_async.dart';

import 'migration.dart';

/// 版本 22: 创建上下文压缩元数据表
///
/// 存储会话级别的压缩状态（prune_start_id 消息 UUID、冷却计数）。
/// DB 只记录压缩位置，具体压缩在内存中完成。
class V22Migration implements Migration {
  @override
  int get version => 22;

  @override
  Future<void> onUpgrade(SqliteWriteContext db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS context_compression_meta (
        employee_id   TEXT NOT NULL,
        device_id     TEXT NOT NULL,
        prune_start_id   TEXT NOT NULL DEFAULT '',
        last_compression_time INTEGER NOT NULL DEFAULT 0,
        messages_since_compression INTEGER NOT NULL DEFAULT 0,
        update_time  INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (employee_id, device_id)
      )
    ''');
  }
}
