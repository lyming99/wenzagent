import 'package:sqlite_async/sqlite_async.dart';

import 'migration.dart';

/// 版本 2: 去除 space_id 列，统一使用 device_id
///
/// - 将 space_id 列数据迁移到 device_id（仅当 device_id 为空时）
/// - 删除 space_id 列
/// - 删除旧索引 idx_employees_space，创建新索引 idx_employees_device
class V2Migration extends Migration {
  @override
  int get version => 2;

  /// 检查表中是否存在指定列
  Future<bool> _columnExists(
    SqliteWriteContext db,
    String table,
    String column,
  ) async {
    final result = await db.getAll('''
      SELECT count(*) as cnt FROM pragma_table_info('$table')
        WHERE name = '$column'
    ''');
    return (result.first['cnt'] as int) > 0;
  }

  @override
  Future<void> onUpgrade(SqliteWriteContext db) async {
    // 如果 space_id 列不存在，说明已经是 V2 schema，无需迁移
    if (!await _columnExists(db, 'employees', 'space_id')) {
      return;
    }

    // 将 space_id 值迁移到 device_id（仅当 device_id 为空时）
    await db.execute('''
      UPDATE employees SET device_id = space_id
        WHERE (device_id IS NULL OR device_id = '') AND space_id IS NOT NULL
    ''');

    // 删除旧索引
    await db.execute('DROP INDEX IF EXISTS idx_employees_space');

    // SQLite 不支持直接 DROP COLUMN（3.35.0+ 才支持），
    // 创建新表不含 space_id 列，迁移数据后重命名
    await db.execute('''
      CREATE TABLE employees_new (
        uuid             TEXT PRIMARY KEY,
        name             TEXT NOT NULL,
        avatar           TEXT,
        role             TEXT DEFAULT 'assistant',
        status           TEXT DEFAULT 'active',
        description      TEXT,
        system_prompt    TEXT,
        provider         TEXT,
        model            TEXT,
        api_key          TEXT,
        api_base_url     TEXT,
        model_config     TEXT,
        project_uuid     TEXT,
        project_name     TEXT,
        project_context  TEXT,
        work_path        TEXT,
        enable_tools     INTEGER DEFAULT 1,
        enable_mcp       INTEGER DEFAULT 0,
        mcp_config       TEXT,
        permission_config TEXT,
        device_id        TEXT,
        current_device_id TEXT,
        auto_approve     INTEGER DEFAULT 0,
        sort_order       INTEGER DEFAULT 0,
        is_pinned        INTEGER DEFAULT 0,
        deleted          INTEGER DEFAULT 0,
        deleted_time     INTEGER,
        create_time      INTEGER NOT NULL,
        update_time      INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      INSERT INTO employees_new
        SELECT uuid, name, avatar, role, status, description,
               system_prompt, provider, model, api_key, api_base_url, model_config,
               project_uuid, project_name, project_context, work_path,
               enable_tools, enable_mcp, mcp_config, permission_config,
               device_id, current_device_id, auto_approve, sort_order, is_pinned,
               deleted, deleted_time, create_time, update_time
        FROM employees
    ''');

    await db.execute('DROP TABLE employees');
    await db.execute('ALTER TABLE employees_new RENAME TO employees');

    // 创建新索引
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_employees_device
        ON employees(device_id)
    ''');
  }
}
