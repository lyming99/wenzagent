import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/entities.dart';
import 'package:wenzagent/src/persistence/stores/employee_store.dart';
import 'package:wenzagent/src/persistence/stores/session_store.dart';
import 'package:wenzagent/src/service/employee_manager.dart';
import 'package:wenzagent/src/service/session_manager.dart';

/// 局域网同步场景测试
///
/// 模拟两个设备（deviceA, deviceB）的 Manager 实例共享同一个数据库，
/// 测试员工和会话在同步前后的数据一致性以及 deviceId 相关 bug。
///
/// 关键测试点：
/// 1. createEmployee 不覆盖已有 deviceId
/// 2. saveEmployee 保留原始 deviceId（同步场景）
/// 3. 不同 deviceId 的 Manager 通过 deviceId 过滤看不到对方数据
/// 4. 同步后两端都能看到数据
void main() {
  late DatabaseManager dbManager;
  late String dbDir;

  setUpAll(() {
    dbDir = p.join(Directory.systemTemp.path,
        'sync_test_${DateTime.now().millisecondsSinceEpoch}');
    Directory(dbDir).createSync(recursive: true);
  });

  tearDownAll(() async {
    await dbManager.close();
    final dir = Directory(dbDir);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  setUp(() async {
    final instance = DatabaseManager.getInstance('test');
    if (instance.isInitialized) await instance.close();
    await instance.initialize(storagePath: dbDir);
    dbManager = instance;
    dbManager.db.execute('DELETE FROM scheduled_tasks');
    dbManager.db.execute('DELETE FROM device_configs');
    dbManager.db.execute('DELETE FROM messages');
    dbManager.db.execute('DELETE FROM skills');
    dbManager.db.execute('DELETE FROM sessions');
    dbManager.db.execute('DELETE FROM employees');
  });

  EmployeeManagerImpl createManager(String deviceId) {
    return EmployeeManagerImpl(
      store: EmployeeStore(dbManager: dbManager),
      deviceId: deviceId,
    );
  }

  SessionManagerImpl createSessionManager() {
    return SessionManagerImpl(
      sessionStore: SessionStore(dbManager: dbManager),
    );
  }

  AiEmployeeEntity createTestEmployee({
    required String uuid,
    required String name,
    String? deviceId,
  }) {
    final now = DateTime.now();
    return AiEmployeeEntity(
      uuid: uuid,
      deviceId: deviceId,
      name: name,
      provider: 'openai',
      model: 'gpt-4',
      createTime: now,
      updateTime: now,
    );
  }

  // ================================================================
  // 员工同步测试
  // ================================================================
  group('员工同步 - deviceId Bug 修复验证', () {
    test('createEmployee 在 deviceId 为空时自动填充 deviceId', () async {
      final manager = createManager('device-A');
      final created = await manager.createEmployee(
        createTestEmployee(uuid: 'emp-auto', name: '自动填充'),
      );
      expect(created.deviceId, equals('device-A'));
    });

    test('createEmployee 不覆盖已有的 deviceId（Bug修复）', () async {
      final manager = createManager('device-A');
      final created = await manager.createEmployee(
        createTestEmployee(
          uuid: 'emp-keep',
          name: '保留deviceId',
          deviceId: 'original-space',
        ),
      );
      expect(created.deviceId, equals('original-space'));
    });

    test('不同 deviceId 的 Manager 看不到对方的数据（deviceId隔离）', () async {
      final managerA = createManager('device-A');
      final managerB = createManager('device-B');

      // A创建员工
      await managerA.createEmployee(
        createTestEmployee(uuid: 'emp-isolated', name: 'A的员工'),
      );

      // B查不到
      final listB = await managerB.getEmployees();
      expect(listB.length, equals(0));

      // A查得到
      final listA = await managerA.getEmployees();
      expect(listA.length, equals(1));
    });

    test('saveEmployee 保留原始 deviceId（同步场景，核心修复）', () async {
      final managerA = createManager('device-A');
      final managerB = createManager('device-B');

      // 设备A创建员工，deviceId = device-A
      final employee = await managerA.createEmployee(
        createTestEmployee(uuid: 'emp-sync', name: '同步员工'),
      );
      expect(employee.deviceId, equals('device-A'));

      // 模拟同步到设备B：使用 saveEmployee
      await managerB.saveEmployee(employee);

      // 关键验证：设备B中 deviceId 保持 device-A（不被覆盖为 device-B）
      final store = EmployeeStore(dbManager: dbManager);
      final raw = await store.find(null, 'emp-sync');
      expect(raw, isNotNull);
      expect(raw!.deviceId, equals('device-A'));
    });

    test('同步后两端通过不同方式都能查到（模拟 findAll 不带 deviceId）', () async {
      final managerA = createManager('device-A');
      final managerB = createManager('device-B');

      // A创建
      final empA = await managerA.createEmployee(
        createTestEmployee(uuid: 'emp-both', name: '两端可见'),
      );

      // 同步到B
      await managerB.saveEmployee(empA);

      // A通过 getEmployees 能查到（deviceId = device-A）
      final listA = await managerA.getEmployees();
      expect(listA.any((e) => e.uuid == 'emp-both'), isTrue);

      // B通过 getEmployees 查不到（deviceId = device-A，B 过滤 device-B）
      // 这是预期行为：因为 deviceId 不同
      // 但 getEmployee(uuid) 通过 uuid 查，能查到
      final fromB = await managerB.getEmployee('emp-both');
      expect(fromB, isNotNull);
      expect(fromB!.name, equals('两端可见'));

      // 通过 Store.findAll(null) 不过滤 deviceId，能查到全部
      final store = EmployeeStore(dbManager: dbManager);
      final all = await store.findAll(null);
      expect(all.any((e) => e.uuid == 'emp-both'), isTrue);
    });

    test('saveEmployee 触发变更事件', () async {
      final manager = createManager('device-A');
      final events = <EmployeeChangeEvent>[];
      manager.onEmployeeChanged.listen(events.add);

      final employee = createTestEmployee(uuid: 'emp-event', name: '事件');
      await manager.saveEmployee(employee);

      // 等待事件流交付
      await Future.delayed(const Duration(milliseconds: 50));

      // 新员工应该触发 created 事件
      expect(events.length, equals(1));
      expect(events.first.type, equals(EmployeeChangeType.created));
      expect(events.first.employeeId, equals('emp-event'));

      // 再次保存（已存在）应触发 updated
      await manager.saveEmployee(employee.copyWith(name: '更新'));
      await Future.delayed(const Duration(milliseconds: 50));
      expect(events.length, equals(2));
      expect(events.last.type, equals(EmployeeChangeType.updated));
    });

    test('双向同步：A创建→同步到B，B创建→同步到A', () async {
      final managerA = createManager('device-A');
      final managerB = createManager('device-B');

      // A创建
      final empA = await managerA.createEmployee(
        createTestEmployee(uuid: 'emp-a', name: 'A创建'),
      );

      // B创建
      final empB = await managerB.createEmployee(
        createTestEmployee(uuid: 'emp-b', name: 'B创建'),
      );

      // A→B 同步
      await managerB.saveEmployee(empA);

      // B→A 同步
      await managerA.saveEmployee(empB);

      // Store 中应有2条
      final store = EmployeeStore(dbManager: dbManager);
      final all = await store.findAll(null);
      expect(all.length, equals(2));

      // deviceId 各自保留
      final rawA = all.firstWhere((e) => e.uuid == 'emp-a');
      final rawB = all.firstWhere((e) => e.uuid == 'emp-b');
      expect(rawA.deviceId, equals('device-A'));
      expect(rawB.deviceId, equals('device-B'));
    });

    test('软删除同步：删除状态正确传播', () async {
      final managerA = createManager('device-A');
      final managerB = createManager('device-B');

      // A创建并同步到B
      final emp = await managerA.createEmployee(
        createTestEmployee(uuid: 'emp-del', name: '待删除'),
      );
      await managerB.saveEmployee(emp);

      // A删除
      await managerA.deleteEmployee('emp-del');

      // 从数据库直接读取删除后的状态（store.find 过滤 deleted=0）
      final resultSet = dbManager.db.select(
        'SELECT * FROM employees WHERE uuid = ?', ['emp-del'],
      );
      expect(resultSet.isNotEmpty, isTrue);
      final row = resultSet.first;
      expect(row['deleted'] as int, equals(1));

      // 构建 entity 用于同步
      final rawDeleted = AiEmployeeEntity.fromMap({
        'uuid': row['uuid'],
        'deviceId': row['device_id'],
        'name': row['name'],
        'deleted': row['deleted'],
        'deletedTime': row['deleted_time'],
        'createTime': row['create_time'],
        'updateTime': row['update_time'],
      });

      // 同步删除状态到B
      await managerB.saveEmployee(rawDeleted);

      // B的 getEmployees 查不到
      final listB = await managerB.getEmployees();
      expect(listB.any((e) => e.uuid == 'emp-del'), isFalse);
    });

    test('更新同步：新数据覆盖旧数据', () async {
      final managerA = createManager('device-A');
      final managerB = createManager('device-B');

      // A创建
      var emp = await managerA.createEmployee(
        createTestEmployee(uuid: 'emp-upd', name: '原名'),
      );

      // 同步到B
      await managerB.saveEmployee(emp);

      // A更新
      emp = emp.copyWith(name: '新名字', description: '新描述');
      await managerA.updateEmployee(emp);

      // 同步更新到B（使用 saveEmployee 保留原始字段）
      final updated = await managerA.getEmployee('emp-upd');
      expect(updated, isNotNull);
      await managerB.saveEmployee(updated!);

      final onB = await managerB.getEmployee('emp-upd');
      expect(onB!.name, equals('新名字'));
      expect(onB.description, equals('新描述'));
    });
  });

  // ================================================================
  // 会话同步测试
  // ================================================================
  group('会话同步', () {
    test('创建会话后可查询', () async {
      final manager = createSessionManager();
      final session = await manager.getOrCreateSession('emp-session-1');

      expect(session.employeeId, equals('emp-session-1'));
      expect(session.deleted, equals(0));

      final all = await manager.getAllSessions();
      expect(all.length, equals(1));
    });

    test('软删除 + 同步', () async {
      final managerA = createSessionManager();
      final managerB = createSessionManager();

      // A创建
      final session = await managerA.getOrCreateSession('emp-session-del');
      await managerB.save(session);

      // A删除
      await managerA.deleteSession('emp-session-del');

      // 同步删除状态到B
      final deleted = (await managerA.getSession('emp-session-del'))!;
      expect(deleted.deleted, equals(1));
      await managerB.save(deleted);

      // B的列表不包含已删除
      final listB = await managerB.getAllSessions();
      expect(listB.any((s) => s.employeeId == 'emp-session-del'), isFalse);
    });

    test('会话复活同步', () async {
      final managerA = createSessionManager();
      final managerB = createSessionManager();

      // A创建并删除
      await managerA.getOrCreateSession('emp-resurrect');
      await managerA.deleteSession('emp-resurrect');

      // 同步删除状态到B
      final deletedSession = (await managerA.getSession('emp-resurrect'))!;
      expect(deletedSession.deleted, equals(1));
      await managerB.save(deletedSession);
      expect((await managerB.getAllSessions()).length, equals(0));

      // A复活
      final resurrected = await managerA.getOrCreateSession('emp-resurrect');
      expect(resurrected.deleted, equals(0));

      // 同步复活到B
      await managerB.save(resurrected);
      final listB = await managerB.getAllSessions();
      expect(listB.length, equals(1));
    });

    test('updateTime 冲突解决', () async {
      final managerA = createSessionManager();
      final managerB = createSessionManager();

      // A创建并同步到B
      final session = await managerA.getOrCreateSession('emp-conflict');
      await managerB.save(session);

      // 两端各自更新
      await managerA.updateDeviceConfig('emp-conflict', 'device-A',
        providerConfig: '{"temperature": 0.7}',
      );
      await Future.delayed(const Duration(milliseconds: 10));
      await managerB.updateDeviceConfig('emp-conflict', 'device-B',
        providerConfig: '{"temperature": 0.9}',
      );

      // 模拟冲突解决：取 updateTime 更新的一方
      final sA = (await managerA.getSession('emp-conflict'))!;
      final sB = (await managerB.getSession('emp-conflict'))!;
      if (sB.updateTime.isAfter(sA.updateTime)) {
        await managerA.save(sB);
      } else {
        await managerB.save(sA);
      }

      // 两端一致
      final finalA = (await managerA.getSession('emp-conflict'))!;
      final finalB = (await managerB.getSession('emp-conflict'))!;
      expect(finalA.updateTime, equals(finalB.updateTime));
    });

    test('设备配置按 deviceId 隔离', () async {
      final manager = createSessionManager();

      await manager.updateDeviceConfig('emp-config', 'device-A',
        providerConfig: '{"temperature": 0.5}',
      );
      await manager.updateDeviceConfig('emp-config', 'device-B',
        providerConfig: '{"temperature": 0.9}',
      );

      final session = (await manager.getSession('emp-config'))!;
      expect(session.config.containsKey('device-A'), isTrue);
      expect(session.config.containsKey('device-B'), isTrue);
      expect(session.config['device-A']!.providerConfig,
          equals('{"temperature": 0.5}'));
      expect(session.config['device-B']!.providerConfig,
          equals('{"temperature": 0.9}'));
    });

    test('归档同步', () async {
      final managerA = createSessionManager();
      final managerB = createSessionManager();

      final session = await managerA.getOrCreateSession('emp-archive');
      await managerB.save(session);

      await managerA.archiveSession('emp-archive', true);
      final archived = (await managerA.getSession('emp-archive'))!;
      expect(archived.isArchived, equals(1));

      await managerB.save(archived);

      expect(
        (await managerB.getAllSessions(includeArchived: false))
            .any((s) => s.employeeId == 'emp-archive'),
        isFalse,
      );
      expect(
        (await managerB.getAllSessions(includeArchived: true))
            .any((s) => s.employeeId == 'emp-archive'),
        isTrue,
      );
    });
  });

  // ================================================================
  // 员工+会话联合同步
  // ================================================================
  group('员工+会话联合同步', () {
    test('完整流程：创建→同步→验证', () async {
      final empManagerA = createManager('device-A');
      final empManagerB = createManager('device-B');
      final sessionManagerA = createSessionManager();
      final sessionManagerB = createSessionManager();

      // A创建员工
      final employee = await empManagerA.createEmployee(
        createTestEmployee(uuid: 'emp-full', name: '全流程'),
      );

      // A创建会话
      await sessionManagerA.getOrCreateSession('emp-full');
      await sessionManagerA.updateDeviceConfig('emp-full', 'device-A',
        providerConfig: '{"temperature": 0.8}',
      );

      // 同步员工到B
      await empManagerB.saveEmployee(employee);

      // 同步会话到B
      final updatedSession = (await sessionManagerA.getSession('emp-full'))!;
      await sessionManagerB.save(updatedSession);

      // 验证B
      final empOnB = await empManagerB.getEmployee('emp-full');
      expect(empOnB, isNotNull);
      expect(empOnB!.deviceId, equals('device-A'));

      final sessionOnB = (await sessionManagerB.getSession('emp-full'))!;
      expect(sessionOnB.deleted, equals(0));
      expect(sessionOnB.config.containsKey('device-A'), isTrue);
    });
  });
}
