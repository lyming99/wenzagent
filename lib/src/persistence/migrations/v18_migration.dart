import 'package:sqlite_async/sqlite_async.dart';

import 'migration.dart';

/// V18: skills 和 global_skills 表增加 delete_time 列
class V18Migration extends Migration {
  @override
  int get version => 18;

  @override
  Future<void> onUpgrade(SqliteWriteContext db) async {
    if (!await _columnExists(db, 'skills', 'delete_time')) {
      await db.execute('ALTER TABLE skills ADD COLUMN delete_time INTEGER');
    }
    if (!await _columnExists(db, 'global_skills', 'delete_time')) {
      await db.execute(
        'ALTER TABLE global_skills ADD COLUMN delete_time INTEGER',
      );
    }
  }

  Future<bool> _columnExists(
    SqliteWriteContext db,
    String table,
    String column,
  ) async {
    final result = await db.getAll('PRAGMA table_info($table)');
    for (final row in result) {
      if (row['name'] == column) return true;
    }
    return false;
  }
}
