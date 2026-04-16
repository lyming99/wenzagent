import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';

/// 版本 12: 新增 spec_items 和 spec_groups 表
///
/// 规格说明管理系统，支持 AI 员工在对话中管理项目/员工的规格文档。
///
/// 注意：v13 迁移已去掉 spec_groups 表，将 spec_items 扁平化。
/// 此迁移保留原始 SQL 以便从 v11 直接升级到 v13 时能正确执行中间步骤。
class V12Migration extends Migration {
  @override
  int get version => 12;

  @override
  void onUpgrade(Database db) {
    // 原始 spec_groups 表（v13 中将被删除）
    db.execute('''
      CREATE TABLE IF NOT EXISTS spec_groups (
        id           TEXT PRIMARY KEY,
        employee_id  TEXT NOT NULL,
        name         TEXT NOT NULL,
        sort_order   INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_spec_groups_employee
        ON spec_groups(employee_id);
    ''');

    // 原始 spec_items 表（v13 中将去掉 group_id 列）
    db.execute('''
      CREATE TABLE IF NOT EXISTS spec_items (
        id           TEXT PRIMARY KEY,
        employee_id  TEXT NOT NULL,
        group_id     TEXT,
        title        TEXT NOT NULL,
        content      TEXT DEFAULT '',
        status       TEXT DEFAULT 'pending',
        priority     TEXT DEFAULT 'medium',
        tags         TEXT DEFAULT '',
        sort_order   INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        create_time  INTEGER NOT NULL,
        update_time  INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_spec_items_employee
        ON spec_items(employee_id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_spec_items_group
        ON spec_items(group_id);
    ''');
  }
}
