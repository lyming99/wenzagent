import 'package:sqlite3/sqlite3.dart';

import 'migration.dart';

/// V18: skills 和 global_skills 表增加 delete_time 列
class V18Migration extends Migration {
  @override
  int get version => 18;

  @override
  void onUpgrade(Database db) {
    if (!_columnExists(db, 'skills', 'delete_time')) {
      db.execute('ALTER TABLE skills ADD COLUMN delete_time INTEGER');
    }
    if (!_columnExists(db, 'global_skills', 'delete_time')) {
      db.execute('ALTER TABLE global_skills ADD COLUMN delete_time INTEGER');
    }
  }

  bool _columnExists(Database db, String table, String column) {
    final result = db.select('PRAGMA table_info($table)');
    for (final row in result) {
      if (row['name'] == column) return true;
    }
    return false;
  }
}
