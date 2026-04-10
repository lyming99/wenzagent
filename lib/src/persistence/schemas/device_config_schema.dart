import 'package:sqlite3/sqlite3.dart';

/// device_configs 表 schema
class DeviceConfigSchema {
  static void create(Database db) {
    db.execute('''
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
