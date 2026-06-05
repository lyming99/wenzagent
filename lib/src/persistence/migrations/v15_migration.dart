import 'package:sqlite_async/sqlite_async.dart';

import 'migration.dart';

/// 版本 15: 为 messages 表增加 metadata 列
///
/// metadata 列用于存储消息的额外元数据（JSON 格式），
/// 如 localOnly、queuePosition、toolResults 等信息。
///
/// 此列在 MessageSchema（新建数据库）中已定义，但历史迁移（V3/V4）
/// 重建 messages 表时未包含该列，导致从旧版本升级的数据库缺少此列。
class V15Migration extends Migration {
  @override
  int get version => 15;

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
    if (!await _columnExists(db, 'messages', 'metadata')) {
      await db.execute('ALTER TABLE messages ADD COLUMN metadata TEXT');
    }
  }
}
