import 'package:sqlite_async/sqlite_async.dart';

import '../schemas/session_summary_schema.dart';
import 'migration.dart';

/// 版本 14: session_summary 表增加 pending 字段
///
/// 新增列：
/// - pending_permission TEXT: 待处理的权限请求（JSON 序列化）
/// - pending_confirm TEXT: 待处理的确认请求（JSON 序列化）
/// - pending_permission_time INTEGER: 权限请求时间
/// - pending_confirm_time INTEGER: 确认请求时间
class V14Migration extends Migration {
  @override
  int get version => 14;

  @override
  Future<void> onUpgrade(SqliteDatabase db) async {
    // 先确保 session_summary 表存在（V9 创建，但此迁移可能在测试环境独立运行）
    await SessionSummarySchema.create(db);

    // 检查列是否已存在，避免重复 ALTER TABLE 报错
    final columns = await db.getAll('PRAGMA table_info(session_summary)');
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
