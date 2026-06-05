import 'package:sqlite_async/sqlite_async.dart';

/// device_configs 表 schema
class DeviceConfigSchema {
  static Future<void> create(SqliteDatabase db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS device_configs (
        device_id    TEXT PRIMARY KEY,
        device_info  TEXT NOT NULL DEFAULT '{}',
        env_vars     TEXT NOT NULL DEFAULT '{}',
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL
      );
    ''');
  }
}
