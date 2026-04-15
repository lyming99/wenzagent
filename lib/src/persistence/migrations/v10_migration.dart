import 'package:sqlite3/sqlite3.dart';

import '../schemas/todo_schema.dart';
import 'migration.dart';

/// 版本 10: 新增 todo_groups 和 todo_items 表
///
/// 内置 Todo 系统持久化，支持分组管理。
class V10Migration extends Migration {
  @override
  int get version => 10;

  @override
  void onUpgrade(Database db) {
    TodoGroupSchema.create(db);
    TodoItemSchema.create(db);
  }
}
