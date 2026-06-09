import 'package:sqlite_async/sqlite_async.dart';

import '../schemas/employee_schema.dart';
import '../schemas/session_schema.dart';
import '../schemas/message_schema.dart';
import '../schemas/skill_schema.dart';
import '../schemas/device_config_schema.dart';
import '../schemas/scheduled_task_schema.dart';
import 'migration.dart';

/// 版本 1: 初始 schema（从 Hive 迁移来的完整表结构）
class V1Migration extends Migration {
  @override
  int get version => 1;

  @override
  Future<void> onUpgrade(SqliteWriteContext db) async {
    await EmployeeSchema.create(db);
    await SessionSchema.create(db);
    await MessageSchema.create(db);
    await SkillSchema.create(db);
    await DeviceConfigSchema.create(db);
    await ScheduledTaskSchema.create(db);
  }
}
