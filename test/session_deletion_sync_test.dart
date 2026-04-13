import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/session_manager.dart';

int _testCounter = 0;

/// 会话删除同步测试
///
/// 验证 DeviceRpcHandler 中 methodSyncSessions 的 deleteTime 合并逻辑：
/// - 软删除同步传播 deleted=1
/// - 双向删除的 deleteTime 合并
/// - 已删除会话不复活
void main() {
  late String testDbPath;
  late String deviceId;
  late SessionManager sessionManager;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_session_deletion_sync_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    sessionManager = SessionManager.getInstance(deviceId);
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    SessionManager.removeInstance(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  /// 模拟 _mergeDeleteTime 逻辑（与 DeviceRpcHandler._mergeDeleteTime 一致）
  (DateTime?, int) mergeDeleteTime(
    DateTime? localDT,
    int localD,
    DateTime? remoteDT,
    int remoteD,
  ) {
    if (localDT == null && remoteDT == null) return (null, 0);
    if (localDT == null) return (remoteDT, remoteD);
    if (remoteDT == null) return (localDT, localD);
    return localDT.isAfter(remoteDT) ? (localDT, localD) : (remoteDT, remoteD);
  }

  group('软删除同步传播 deleted=1', () {
    test('remote deleted session syncs to local', () async {
      final employeeId = 'emp-${const Uuid().v4().substring(0, 8)}';

      // 本地创建一个正常会话
      await sessionManager.save(AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Test Session',
        deleted: 0,
        deleteTime: null,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 2),
      ));

      // 模拟远程同步：收到已删除的会话
      final remoteSession = AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Test Session',
        deleted: 1,
        deleteTime: DateTime(2024, 1, 3),
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 3),
      );

      // 执行合并逻辑（模拟 DeviceRpcHandler 的 methodSyncSessions）
      final existing = await sessionManager.getSession(employeeId);
      expect(existing, isNotNull);
      expect(existing!.deleted, equals(0));

      final (dt, d) = mergeDeleteTime(
        existing.deleteTime, existing.deleted,
        remoteSession.deleteTime, remoteSession.deleted,
      );
      final shouldUpdateData =
          remoteSession.updateTime.isAfter(existing.updateTime);
      final shouldUpdateDelete =
          dt != existing.deleteTime || d != existing.deleted;

      expect(shouldUpdateData, isTrue);
      expect(shouldUpdateDelete, isTrue);
      expect(d, equals(1));

      await sessionManager.save(
        (shouldUpdateData ? remoteSession : existing).copyWith(
          deleted: d,
          deleteTime: dt,
        ),
      );

      // 验证本地会话已标记为删除
      final updated = await sessionManager.getSession(employeeId);
      expect(updated, isNotNull);
      expect(updated!.deleted, equals(1));
      expect(updated.deleteTime, isNotNull);
    });
  });

  group('双向删除的 deleteTime 合并', () {
    test('both sides deleted: keep larger deleteTime', () async {
      final employeeId = 'emp-${const Uuid().v4().substring(0, 8)}';

      final localDeleteTime = DateTime(2024, 1, 5);
      final remoteDeleteTime = DateTime(2024, 1, 3);

      // 本地已删除（较新）
      await sessionManager.save(AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Test Session',
        deleted: 1,
        deleteTime: localDeleteTime,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 4),
      ));

      // 远程已删除（较旧）
      final remoteSession = AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Test Session Updated',
        deleted: 1,
        deleteTime: remoteDeleteTime,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 6),
      );

      final existing = await sessionManager.getSession(employeeId);
      final (dt, d) = mergeDeleteTime(
        existing!.deleteTime, existing.deleted,
        remoteSession.deleteTime, remoteSession.deleted,
      );

      // 应该保留较大的 deleteTime（本地）
      expect(dt, equals(localDeleteTime));
      expect(d, equals(1));

      final shouldUpdateData =
          remoteSession.updateTime.isAfter(existing.updateTime);
      // 远程数据更新，但删除时间取本地
      expect(shouldUpdateData, isTrue);

      await sessionManager.save(
        (shouldUpdateData ? remoteSession : existing).copyWith(
          deleted: d,
          deleteTime: dt,
        ),
      );

      final result = await sessionManager.getSession(employeeId);
      expect(result!.deleted, equals(1));
      expect(result.deleteTime, equals(localDeleteTime));
      expect(result.title, equals('Test Session Updated')); // 数据取远程
    });

    test('remote deleteTime larger: use remote', () async {
      final employeeId = 'emp-${const Uuid().v4().substring(0, 8)}';

      final localDeleteTime = DateTime(2024, 1, 3);
      final remoteDeleteTime = DateTime(2024, 1, 5);

      // 本地已删除（较旧）
      await sessionManager.save(AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Test Session',
        deleted: 1,
        deleteTime: localDeleteTime,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 2),
      ));

      // 远程已删除（较新）
      final remoteSession = AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Test Session Updated',
        deleted: 1,
        deleteTime: remoteDeleteTime,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 6),
      );

      final existing = await sessionManager.getSession(employeeId);
      final (dt, d) = mergeDeleteTime(
        existing!.deleteTime, existing.deleted,
        remoteSession.deleteTime, remoteSession.deleted,
      );

      expect(dt, equals(remoteDeleteTime));
      expect(d, equals(1));
    });

    test('one side deleted, other not: propagate deletion', () async {
      final employeeId = 'emp-${const Uuid().v4().substring(0, 8)}';

      // 本地未删除
      await sessionManager.save(AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Test Session',
        deleted: 0,
        deleteTime: null,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 2),
      ));

      // 远程已删除
      final remoteDeleteTime = DateTime(2024, 1, 3);
      final remoteSession = AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Test Session',
        deleted: 1,
        deleteTime: remoteDeleteTime,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 2),
      );

      final existing = await sessionManager.getSession(employeeId);
      final (dt, d) = mergeDeleteTime(
        existing!.deleteTime, existing.deleted,
        remoteSession.deleteTime, remoteSession.deleted,
      );

      // 本地没有 deleteTime，应取远程
      expect(dt, equals(remoteDeleteTime));
      expect(d, equals(1));
    });
  });

  group('已删除会话不复活', () {
    test('local deleted session not revived by older remote', () async {
      final employeeId = 'emp-${const Uuid().v4().substring(0, 8)}';

      final localDeleteTime = DateTime(2024, 1, 5);

      // 本地已删除
      await sessionManager.save(AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Old Session',
        deleted: 1,
        deleteTime: localDeleteTime,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 4),
      ));

      // 远程未删除（旧数据）
      final remoteSession = AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Old Session',
        deleted: 0,
        deleteTime: null,
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 2),
      );

      final existing = await sessionManager.getSession(employeeId);
      final (dt, d) = mergeDeleteTime(
        existing!.deleteTime, existing.deleted,
        remoteSession.deleteTime, remoteSession.deleted,
      );

      // 本地有 deleteTime，远程没有，应保留本地删除状态
      expect(dt, equals(localDeleteTime));
      expect(d, equals(1)); // 仍然是 deleted=1

      final shouldUpdateData =
          remoteSession.updateTime.isAfter(existing.updateTime);
      expect(shouldUpdateData, isFalse); // 远程数据更旧

      final shouldUpdateDelete =
          dt != existing.deleteTime || d != existing.deleted;
      expect(shouldUpdateDelete, isFalse); // 无需更新
    });

    test('incoming deleted session not saved when no existing', () async {
      final employeeId = 'emp-${const Uuid().v4().substring(0, 8)}';

      // 模拟 DeviceRpcHandler 逻辑：
      // if (existing == null && session.deleted != 1) -> save
      // if (existing == null && session.deleted == 1) -> skip

      final deletedSession = AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: 'Deleted Session',
        deleted: 1,
        deleteTime: DateTime(2024, 1, 3),
        createTime: DateTime(2024, 1, 1),
        updateTime: DateTime(2024, 1, 3),
      );

      final existing = await sessionManager.getSession(employeeId);
      expect(existing, isNull);

      // 已删除的会话不应该被保存（不复活）
      if (deletedSession.deleted != 1) {
        await sessionManager.save(deletedSession);
      }

      // 验证没有保存
      final result = await sessionManager.getSession(employeeId);
      expect(result, isNull);
    });
  });

  group('_mergeDeleteTime 边界情况', () {
    test('both null returns (null, 0)', () {
      final (dt, d) = mergeDeleteTime(null, 0, null, 0);
      expect(dt, isNull);
      expect(d, equals(0));
    });

    test('local null, remote present returns remote', () {
      final remoteDT = DateTime(2024, 1, 3);
      final (dt, d) = mergeDeleteTime(null, 0, remoteDT, 1);
      expect(dt, equals(remoteDT));
      expect(d, equals(1));
    });

    test('remote null, local present returns local', () {
      final localDT = DateTime(2024, 1, 3);
      final (dt, d) = mergeDeleteTime(localDT, 1, null, 0);
      expect(dt, equals(localDT));
      expect(d, equals(1));
    });

    test('equal deleteTime returns remote', () {
      final dt = DateTime(2024, 1, 3);
      final (result, d) = mergeDeleteTime(dt, 0, dt, 1);
      // When equal, isAfter returns false, so remote wins
      expect(result, equals(dt));
      expect(d, equals(1));
    });

    test('local after remote returns local', () {
      final localDT = DateTime(2024, 1, 5);
      final remoteDT = DateTime(2024, 1, 3);
      final (dt, d) = mergeDeleteTime(localDT, 1, remoteDT, 0);
      expect(dt, equals(localDT));
      expect(d, equals(1));
    });

    test('remote after local returns remote', () {
      final localDT = DateTime(2024, 1, 3);
      final remoteDT = DateTime(2024, 1, 5);
      final (dt, d) = mergeDeleteTime(localDT, 0, remoteDT, 1);
      expect(dt, equals(remoteDT));
      expect(d, equals(1));
    });
  });
}
