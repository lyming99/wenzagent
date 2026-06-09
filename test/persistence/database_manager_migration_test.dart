import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite_async/sqlite_async.dart';
import 'package:test/test.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';

void main() {
  test(
    'migrates an existing v21 database to v22 inside the transaction',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'wenzagent_migration_test_',
      );
      final deviceId =
          'migration-test-${DateTime.now().microsecondsSinceEpoch}';

      try {
        final seedDb = SqliteDatabase(
          path: p.join(tempDir.path, 'wenzagent.db'),
        );
        await seedDb.execute('PRAGMA user_version = 21');
        await seedDb.close();

        final manager = DatabaseManager.getInstance(deviceId);
        await manager.initialize(storagePath: tempDir.path);

        expect(manager.databaseVersion, DatabaseManager.currentVersion);

        final table = await manager.db.getOptional(
          "SELECT name FROM sqlite_master "
          "WHERE type = 'table' AND name = 'context_compression_meta'",
        );
        expect(table?['name'], 'context_compression_meta');
      } finally {
        await DatabaseManager.getInstance(deviceId).close();
        DatabaseManager.removeInstance(deviceId);
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    },
  );
}
