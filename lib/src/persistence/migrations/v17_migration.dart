import 'package:sqlite_async/sqlite_async.dart';

import 'migration.dart';
import '../schemas/project_schema.dart';

/// V17 数据库迁移：创建 wenz_projects 等项目相关表
class V17Migration extends Migration {
  @override
  int get version => 17;

  @override
  Future<void> onUpgrade(SqliteDatabase db) async {
    await ProjectSchema.create(db);
  }
}
