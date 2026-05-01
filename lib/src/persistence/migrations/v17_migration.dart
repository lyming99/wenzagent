import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';
import '../schemas/project_schema.dart';

/// V17 数据库迁移：创建 wenz_projects 等项目相关表
class V17Migration extends Migration {
  @override
  int get version => 17;

  @override
  void onUpgrade(Database db) {
    ProjectSchema.create(db);
  }
}
