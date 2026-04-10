import 'package:sqlite3/sqlite3.dart';

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
  void onUpgrade(Database db) {
    EmployeeSchema.create(db);
    SessionSchema.create(db);
    MessageSchema.create(db);
    SkillSchema.create(db);
    DeviceConfigSchema.create(db);
    ScheduledTaskSchema.create(db);
  }
}
