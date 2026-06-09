import 'package:sqlite_async/sqlite_async.dart';

import '../schemas/session_summary_schema.dart';
import 'migration.dart';

/// 版本 9: 新增 session_summary 表
///
/// 会话摘要表，作为未读计数和最新消息的权威数据源。
/// 从 messages 表聚合初始化现有数据。
class V9Migration extends Migration {
  @override
  int get version => 9;

  @override
  Future<void> onUpgrade(SqliteWriteContext db) async {
    await SessionSummarySchema.create(db);
    await _initializeSummaries(db);
  }

  /// 从 messages 表聚合初始化摘要数据
  Future<void> _initializeSummaries(SqliteWriteContext db) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 单条 SQL 从 messages 表聚合初始化
    // 为每个 (employee_id, device_id) 计算未读数和最新消息
    await db.execute(
      '''
      INSERT OR IGNORE INTO session_summary (
        employee_id, device_id, unread_count,
        last_msg_id, last_msg_role, last_msg_content,
        last_msg_time, last_msg_seq, update_time
      )
      SELECT
        m.employee_id,
        m.device_id,
        COALESCE(
          (SELECT COUNT(*) FROM messages sub
           WHERE sub.employee_id = m.employee_id AND sub.device_id = m.device_id
             AND sub.role = 'assistant' AND sub.is_read = 0 AND sub.deleted = 0),
          0
        ),
        latest.uuid,
        latest.role,
        latest.content,
        latest.create_time,
        latest.seq,
        ?
      FROM (SELECT DISTINCT employee_id, device_id FROM messages) m
      LEFT JOIN messages latest ON latest.employee_id = m.employee_id
        AND latest.device_id = m.device_id AND latest.deleted = 0
        AND latest.create_time = (
          SELECT MAX(create_time) FROM messages m2
          WHERE m2.employee_id = m.employee_id AND m2.device_id = m.device_id
            AND m2.deleted = 0
        )
    ''',
      [now],
    );
  }
}
