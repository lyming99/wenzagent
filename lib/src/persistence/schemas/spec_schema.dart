import 'package:sqlite3/sqlite3.dart';

/// spec_items 表 schema
class SpecItemSchema {
  static void create(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS spec_items (
        id           TEXT PRIMARY KEY,
        employee_id  TEXT NOT NULL,
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
  }
}
