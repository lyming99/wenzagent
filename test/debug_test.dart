import 'dart:io';
import 'package:test/test.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/employee_manager.dart';

void main() {
  late String testDbPath;
  late String deviceId;
  late EmployeeStore store;
  late EmployeeManager manager;

  setUp(() async {
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_debug_test_${DateTime.now().millisecondsSinceEpoch}';
    await Directory(testDbPath).create(recursive: true);
    deviceId = 'dev-debug';

    await DatabaseManager.getInstance(deviceId).initialize(storagePath: testDbPath);
    store = EmployeeStore(deviceId: deviceId);
    manager = EmployeeManager.getInstance(deviceId);
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    EmployeeManager.removeInstance(deviceId);
    try { await Directory(testDbPath).delete(recursive: true); } catch (_) {}
  });

  test('debug: store.save with deleted=1 then getEmployeeIncludingDeleted', () async {
    final localDT = DateTime(2024, 1, 5);
    final local = AiEmployeeEntity(
      uuid: 'test-uuid-1',
      name: 'Test',
      deleted: 1,
      deletedTime: localDT,
      updateTime: DateTime(2024, 1, 4),
      createTime: DateTime(2024, 1, 1),
    );

    // Save via store.save
    await store.save(local);

    final existing = await manager.getEmployeeIncludingDeleted('test-uuid-1');
    print('existing is null: ${existing == null}');
    if (existing != null) {
      print('existing.deleted: ${existing.deleted}');
      print('existing.deletedTime: ${existing.deletedTime}');
      print('existing.deletedTime ms: ${existing.deletedTime?.millisecondsSinceEpoch}');
      print('localDT ms: ${localDT.millisecondsSinceEpoch}');
      print('deletedTime == localDT: ${existing.deletedTime == localDT}');
      print('deletedTime ms == localDT ms: ${existing.deletedTime?.millisecondsSinceEpoch == localDT.millisecondsSinceEpoch}');
    }
  });

  test('debug: simulateMerge with deleted employee', () async {
    final localDT = DateTime(2024, 1, 6);
    final local = AiEmployeeEntity(
      uuid: 'test-uuid-2',
      name: 'Local',
      deleted: 1,
      deletedTime: localDT,
      updateTime: DateTime(2024, 1, 2),
      createTime: DateTime(2024, 1, 1),
    );

    await store.save(local);

    // Simulate remote (from copyWith - not from DB)
    final remote = local.copyWith(
      name: 'Remote',
      deleted: 0,
      deletedTime: null,
      updateTime: DateTime(2024, 1, 5),
    );

    print('remote.deleted: ${remote.deleted}');
    print('remote.deletedTime: ${remote.deletedTime}');

    final existing = await manager.getEmployeeIncludingDeleted('test-uuid-2');
    print('existing: deleted=${existing?.deleted}, deletedTime=${existing?.deletedTime}');

    // Now simulate merge
    final (dt, d) = (
      existing!.deletedTime != null && remote.deletedTime == null
        ? (existing.deletedTime, existing.deleted)
        : remote.deletedTime != null && existing.deletedTime == null
          ? (remote.deletedTime, remote.deleted)
          : existing.deletedTime != null && remote.deletedTime != null
            ? existing.deletedTime!.isAfter(remote.deletedTime!)
              ? (existing.deletedTime, existing.deleted)
              : (remote.deletedTime, remote.deleted)
            : (null, 0)
    );

    print('merge result: dt=$dt, d=$d');
    print('dt ms: ${dt?.millisecondsSinceEpoch}');
    print('localDT ms: ${localDT.millisecondsSinceEpoch}');

    final shouldUpdateData = remote.updateTime.isAfter(existing.updateTime);
    print('shouldUpdateData: $shouldUpdateData');

    final shouldUpdateDelete =
        dt?.millisecondsSinceEpoch != existing.deletedTime?.millisecondsSinceEpoch || d != existing.deleted;
    print('shouldUpdateDelete: $shouldUpdateDelete');

    print('dt?.ms=${dt?.millisecondsSinceEpoch} existing.deletedTime?.ms=${existing.deletedTime?.millisecondsSinceEpoch} same=${dt?.millisecondsSinceEpoch == existing.deletedTime?.millisecondsSinceEpoch}');
    print('d=$d existing.deleted=${existing.deleted} same=${d == existing.deleted}');
  });
}
