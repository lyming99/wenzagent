import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';

/// 版本 20: skills 表新增 global_skill_id 列
///
/// 员工技能（AiEmployeeSkillEntity）新增 globalSkillId 字段，
/// 用于关联全局技能库中的技能，方便从 global skill 获取技能文件夹数据。
class V20Migration extends Migration {
  @override
  int get version => 20;

  @override
  void onUpgrade(Database db) {
    // 安全添加列（如果已存在则忽略）
    _addColumnIfNotExists(db, 'skills', 'global_skill_id', 'TEXT');
  }

  /// 安全添加列（如果已存在则忽略）
  void _addColumnIfNotExists(
    Database db,
    String table,
    String column,
    String type,
  ) {
    // 检查列是否已存在
    final result = db.select(
      "SELECT name FROM pragma_table_info('$table') WHERE name = ?",
      [column],
    );
    if (result.isEmpty) {
      db.execute('ALTER TABLE $table ADD COLUMN $column $type');
    }
  }
}
