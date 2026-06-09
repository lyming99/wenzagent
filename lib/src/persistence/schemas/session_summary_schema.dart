import 'package:sqlite_async/sqlite_async.dart';

/// session_summary 表 schema
///
/// 会话摘要表，作为未读计数和最新消息的权威数据源。
/// 通过 UPSERT 原子操作维护，O(1) 读写。
class SessionSummarySchema {
  static Future<void> create(SqliteWriteContext db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS session_summary (
        employee_id      TEXT    NOT NULL,
        device_id        TEXT    NOT NULL DEFAULT '',
        unread_count     INTEGER NOT NULL DEFAULT 0,
        last_msg_id      TEXT,
        last_msg_role    TEXT,
        last_msg_content TEXT,
        last_msg_time    INTEGER,
        last_msg_seq     INTEGER,
        update_time      INTEGER NOT NULL,
        PRIMARY KEY (employee_id, device_id)
      )
    ''');

    // 全局未读查询优化：只扫描有未读的行
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_summary_unread
        ON session_summary(unread_count) WHERE unread_count > 0
    ''');

    // 会话列表排序优化：按最新消息时间倒序
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_summary_last_msg_time
        ON session_summary(last_msg_time DESC)
    ''');

    // v14: pending 字段（CREATE TABLE 时直接包含，避免 ALTER TABLE）
    // 注意：如果表已存在且缺少这些列，需要通过 v14_migration 的 ALTER TABLE 添加
    // 此处 CREATE TABLE IF NOT EXISTS 不会重建已有表，所以 ALTER TABLE 仍需保留
  }

  /// 确保 pending 字段存在（v14 新增列）
  ///
  /// 在 CREATE TABLE 之后调用，处理表已存在但缺少 pending 列的情况。
  /// ALTER TABLE ADD COLUMN 对已存在的列是安全的（SQLite 会忽略）。
  static Future<void> ensurePendingColumns(SqliteWriteContext db) async {
    // 检查 pending_permission 列是否已存在
    final columns = await db.getAll("PRAGMA table_info(session_summary)");
    final columnNames = columns.map((row) => row['name'] as String).toSet();

    if (!columnNames.contains('pending_permission')) {
      await db.execute(
        'ALTER TABLE session_summary ADD COLUMN pending_permission TEXT',
      );
    }
    if (!columnNames.contains('pending_confirm')) {
      await db.execute(
        'ALTER TABLE session_summary ADD COLUMN pending_confirm TEXT',
      );
    }
    if (!columnNames.contains('pending_permission_time')) {
      await db.execute(
        'ALTER TABLE session_summary ADD COLUMN pending_permission_time INTEGER',
      );
    }
    if (!columnNames.contains('pending_confirm_time')) {
      await db.execute(
        'ALTER TABLE session_summary ADD COLUMN pending_confirm_time INTEGER',
      );
    }

    // 查询有 pending 请求的摘要优化索引
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_summary_pending_permission
        ON session_summary(pending_permission) WHERE pending_permission IS NOT NULL
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_summary_pending_confirm
        ON session_summary(pending_confirm) WHERE pending_confirm IS NOT NULL
    ''');
  }
}
