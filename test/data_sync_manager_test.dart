import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/employee_manager.dart';
import 'package:wenzagent/src/service/session_manager.dart';

int _testCounter = 0;

/// DataSyncManager 合并逻辑测试
///
/// 验证 _mergeDeleteTime 和会话/员工合并逻辑的边界情况。
/// 由于 _mergeDeleteTime 是私有方法，这里直接测试合并算法。
void main() {
  late String testDbPath;
  late String deviceId;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_data_sync_manager_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  /// 复制 _mergeDeleteTime 逻辑
  (DateTime?, int) mergeDeleteTime(
    DateTime? localDT, int localD,
    DateTime? remoteDT, int remoteD,
  ) {
    if (localDT == null && remoteDT == null) return (null, 0);
    if (localDT == null) return (remoteDT, remoteD);
    if (remoteDT == null) return (localDT, localD);
    return localDT.isAfter(remoteDT) ? (localDT, localD) : (remoteDT, remoteD);
  }

  group('_mergeDeleteTime 所有边界情况', () {
    test('both null returns null and 0', () {
      final (dt, d) = mergeDeleteTime(null, 0, null, 0);
      expect(dt, isNull);
      expect(d, equals(0));
    });

    test('local null, remote set: returns remote values', () {
      final remoteDT = DateTime(2024, 6, 1);
      final (dt, d) = mergeDeleteTime(null, 0, remoteDT, 1);
      expect(dt, equals(remoteDT));
      expect(d, equals(1));
    });

    test('remote null, local set: returns local values', () {
      final localDT = DateTime(2024, 6, 1);
      final (dt, d) = mergeDeleteTime(localDT, 1, null, 0);
      expect(dt, equals(localDT));
      expect(d, equals(1));
    });

    test('both set, local newer: returns local values', () {
      final localDT = DateTime(2024, 6, 5);
      final remoteDT = DateTime(2024, 6, 3);
      final (dt, d) = mergeDeleteTime(localDT, 1, remoteDT, 1);
      expect(dt, equals(localDT));
      expect(d, equals(1));
    });

    test('both set, remote newer: returns remote values', () {
      final localDT = DateTime(2024, 6, 3);
      final remoteDT = DateTime(2024, 6, 5);
      final (dt, d) = mergeDeleteTime(localDT, 0, remoteDT, 1);
      expect(dt, equals(remoteDT));
      expect(d, equals(1));
    });

    test('both set, equal time: returns remote values (isAfter=false)', () {
      final dt = DateTime(2024, 6, 5);
      final (result, d) = mergeDeleteTime(dt, 0, dt, 1);
      expect(result, equals(dt));
      expect(d, equals(1)); // remote wins when equal
    });

    test('local deleted=1, remote deleted=0: merge decides by time', () {
      final localDT = DateTime(2024, 6, 5);
      final remoteDT = DateTime(2024, 6, 3);
      final (dt, d) = mergeDeleteTime(localDT, 1, remoteDT, 0);
      expect(dt, equals(localDT));
      expect(d, equals(1)); // local time newer -> local deleted=1
    });
  });

  group('_mergeAndSaveSession 合并逻辑', () {
    test('newer remote data + same delete status: updates data only', () async {
      final employeeId = 'emp-${const Uuid().v4().substring(0, 8)}';
      final sessionManager = SessionManager.getInstance(deviceId);

      // 创建本地会话
      final localSession = AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Old Title',
        deleted: 0,
        deleteTime: null,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 2),
      );
      await sessionManager.save(localSession);

      // 远程有更新的数据
      final remoteSession = AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'New Title',
        deleted: 0,
        deleteTime: null,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 3),
      );

      // 模拟合并逻辑
      final existing = await sessionManager.getSession(employeeId);
      final (dt, d) = mergeDeleteTime(
        existing!.deleteTime, existing.deleted,
        remoteSession.deleteTime, remoteSession.deleted,
      );

      final shouldUpdateData = remoteSession.updateTime.isAfter(existing.updateTime);
      final shouldUpdateDelete = dt != existing.deleteTime || d != existing.deleted;

      expect(shouldUpdateData, isTrue);
      expect(shouldUpdateDelete, isFalse);

      if (shouldUpdateData || shouldUpdateDelete) {
        await sessionManager.save(
          (shouldUpdateData ? remoteSession : existing).copyWith(
            deleted: d,
            deleteTime: dt,
          ),
        );
      }

      final result = await sessionManager.getSession(employeeId);
      expect(result!.title, equals('New Title'));
      expect(result.deleted, equals(0));

      SessionManager.removeInstance(deviceId);
    });

    test('older remote data + new delete: updates delete only', () async {
      final employeeId = 'emp-${const Uuid().v4().substring(0, 8)}';
      final sessionManager = SessionManager.getInstance(deviceId);

      // 本地会话（较新数据，未删除）
      await sessionManager.save(AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Local Title',
        deleted: 0,
        deleteTime: null,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 5),
      ));

      // 远程（较旧数据，已删除）
      final remoteSession = AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Remote Title',
        deleted: 1,
        deleteTime: DateTime(2024, 1, 3),
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 2),
      );

      final existing = await sessionManager.getSession(employeeId);
      final (dt, d) = mergeDeleteTime(
        existing!.deleteTime, existing.deleted,
        remoteSession.deleteTime, remoteSession.deleted,
      );

      final shouldUpdateData = remoteSession.updateTime.isAfter(existing.updateTime);
      final shouldUpdateDelete = dt != existing.deleteTime || d != existing.deleted;

      expect(shouldUpdateData, isFalse); // 远程数据更旧
      expect(shouldUpdateDelete, isTrue); // 删除状态变更

      if (shouldUpdateData || shouldUpdateDelete) {
        await sessionManager.save(
          (shouldUpdateData ? remoteSession : existing).copyWith(
            deleted: d,
            deleteTime: dt,
          ),
        );
      }

      final result = await sessionManager.getSession(employeeId);
      expect(result!.title, equals('Local Title')); // 保留本地数据
      expect(result.deleted, equals(1)); // 合并了删除状态
      expect(result.deleteTime, equals(DateTime(2024, 1, 3)));

      SessionManager.removeInstance(deviceId);
    });

    test('no changes needed: skip save', () async {
      final employeeId = 'emp-${const Uuid().v4().substring(0, 8)}';
      final sessionManager = SessionManager.getInstance(deviceId);

      final session = AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Same Title',
        deleted: 0,
        deleteTime: null,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 2),
      );
      await sessionManager.save(session);

      // 完全相同的远程数据
      final remoteSession = AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Same Title',
        deleted: 0,
        deleteTime: null,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 1), // 更旧
      );

      final existing = await sessionManager.getSession(employeeId);
      final (dt, d) = mergeDeleteTime(
        existing!.deleteTime, existing.deleted,
        remoteSession.deleteTime, remoteSession.deleted,
      );

      final shouldUpdateData = remoteSession.updateTime.isAfter(existing.updateTime);
      final shouldUpdateDelete = dt != existing.deleteTime || d != existing.deleted;

      expect(shouldUpdateData, isFalse);
      expect(shouldUpdateDelete, isFalse);

      SessionManager.removeInstance(deviceId);
    });
  });

  group('_mergeAndSaveEmployee 合并逻辑', () {
    test('employee delete merge follows same pattern', () async {
      final employeeManager = EmployeeManager.getInstance(deviceId);

      final uuid = 'emp-${const Uuid().v4().substring(0, 8)}';
      final localDeleteTime = DateTime(2024, 1, 5);

      // 创建本地员工
      final localEmployee = AiEmployeeEntity(
        uuid: uuid,
        name: 'Test Employee',
        deleted: 1,
        deletedTime: localDeleteTime,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 4),
      );
      await employeeManager.saveEmployee(localEmployee);

      // 远程员工（旧删除时间，新数据）
      final remoteEmployee = AiEmployeeEntity(
        uuid: uuid,
        name: 'Updated Employee',
        deleted: 0,
        deletedTime: null,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 6),
      );

      final existing = await employeeManager.getEmployeeIncludingDeleted(uuid);
      expect(existing, isNotNull);

      // 合并 deleteTime
      DateTime? mergedDeleteTime;
      int mergedDeleted;

      if (existing!.deletedTime == null && remoteEmployee.deletedTime == null) {
        mergedDeleteTime = null;
        mergedDeleted = 0;
      } else if (existing.deletedTime == null) {
        mergedDeleteTime = remoteEmployee.deletedTime;
        mergedDeleted = remoteEmployee.deleted;
      } else if (remoteEmployee.deletedTime == null) {
        mergedDeleteTime = existing.deletedTime;
        mergedDeleted = existing.deleted;
      } else {
        if (existing.deletedTime!.isAfter(remoteEmployee.deletedTime!)) {
          mergedDeleteTime = existing.deletedTime;
          mergedDeleted = existing.deleted;
        } else {
          mergedDeleteTime = remoteEmployee.deletedTime;
          mergedDeleted = remoteEmployee.deleted;
        }
      }

      final shouldUpdateData =
          remoteEmployee.updateTime.isAfter(existing.updateTime);
      final shouldUpdateDelete =
          mergedDeleteTime != existing.deletedTime ||
              mergedDeleted != existing.deleted;

      expect(shouldUpdateData, isTrue); // 远程数据更新
      expect(shouldUpdateDelete, isFalse); // 删除状态不变（本地 deleteTime 更大）

      if (shouldUpdateData || shouldUpdateDelete) {
        final base = shouldUpdateData ? remoteEmployee : existing;
        await employeeManager.updateEmployee(base.copyWith(
          deleted: mergedDeleted,
          deletedTime: mergedDeleteTime,
        ));
      }

      final result = await employeeManager.getEmployee(uuid);
      // 员工已删除，getEmployee 不返回
      expect(result, isNull);

      // 包含删除的查询能返回
      final resultWithDeleted =
          await employeeManager.getEmployeeIncludingDeleted(uuid);
      expect(resultWithDeleted, isNotNull);
      expect(resultWithDeleted!.deleted, equals(1));
      expect(resultWithDeleted.deletedTime, equals(localDeleteTime));
      expect(resultWithDeleted.name, equals('Updated Employee'));

      EmployeeManager.removeInstance(deviceId);
    });
  });
}
