import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';

/// 版本 21: skills 表新增 origin_name 列
///
/// 记录 skill 原始文件夹名称，用于从 LAN 同步时定位远端文件夹。
/// 当员工 skill 的 name 与源 skill 的文件夹名不一致时，通过此字段定位正确的文件夹。
class V21Migration implements Migration {
  @override
  int get version => 21;

  @override
  void onUpgrade(Database db) {
    // 先检查列是否已存在，防止因历史部分迁移导致 duplicate column 错误
    final result = db.select(
      "SELECT count(*) AS cnt FROM pragma_table_info('skills') WHERE name = 'origin_name'",
    );
    final exists = (result.first['cnt'] as int) > 0;
    if (!exists) {
      db.execute('ALTER TABLE skills ADD COLUMN origin_name TEXT');
    }
  }
}
