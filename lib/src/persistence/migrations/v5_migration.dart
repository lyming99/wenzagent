import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';

/// 版本 5: 为 sync_watermark 表增加清空水位线列
///
/// clear_seq 用于标记一次清空操作：当客户端同步时检测到此值，
/// 应删除本地所有 seq < clearSeq 的消息，然后清除此标记。
/// 此机制允许服务端通知客户端进行批量消息清理。
class V5Migration extends Migration {
  @override
  int get version => 5;

  /// 检查表中是否存在指定列
  bool _columnExists(Database db, String table, String column) {
    final result = db.select('''
      SELECT count(*) as cnt FROM pragma_table_info('$table')
        WHERE name = '$column'
    ''');
    return (result.first['cnt'] as int) > 0;
  }

  @override
  void onUpgrade(Database db) {
    if (!_columnExists(db, 'sync_watermark', 'clear_seq')) {
      db.execute(
        'ALTER TABLE sync_watermark ADD COLUMN clear_seq INTEGER DEFAULT NULL',
      );
    }
  }
}
