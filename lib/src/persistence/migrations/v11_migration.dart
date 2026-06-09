import 'package:sqlite_async/sqlite_async.dart';

import '../schemas/file_operation_schema.dart';
import 'migration.dart';

/// 版本 11: 新增 file_operations 表
///
/// Agent 文件操作追踪系统，记录所有文件变更操作。
class V11Migration extends Migration {
  @override
  int get version => 11;

  @override
  Future<void> onUpgrade(SqliteWriteContext db) async {
    await FileOperationSchema.create(db);
  }
}
