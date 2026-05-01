import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';
import '../schemas/global_skill_schema.dart';

/// 版本 16: 新增 global_skills 表
///
/// 全局技能库，独立于员工，用于管理可复用的技能模板。
class V16Migration extends Migration {
  @override
  int get version => 16;

  @override
  void onUpgrade(Database db) {
    GlobalSkillSchema.create(db);
  }
}
