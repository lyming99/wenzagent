import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/entities.dart';
import 'package:wenzagent/src/persistence/stores/employee_store.dart';
import 'package:wenzagent/src/persistence/stores/session_store.dart';
import 'package:wenzagent/src/persistence/stores/message_store.dart';
import 'package:wenzagent/src/persistence/stores/skill_store.dart';
import 'package:wenzagent/src/persistence/stores/device_config_store.dart';
import 'package:wenzagent/src/persistence/stores/scheduled_task_store.dart';

/// 数据库 CRUD 测试
///
/// 覆盖全部 6 个 Store 的增删改查操作。
/// 使用临时文件数据库，测试结束后自动清理。
void main() {
  late DatabaseManager dbManager;
  late String dbDir;

  setUpAll(() {
    dbDir = p.join(Directory.systemTemp.path,
        'wenzagent_test_${DateTime.now().millisecondsSinceEpoch}');
    Directory(dbDir).createSync(recursive: true);
  });

  tearDownAll(() async {
    await dbManager.close();
    final dir = Directory(dbDir);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  setUp(() async {
    final instance = DatabaseManager.instance;
    if (instance.isInitialized) await instance.close();
    await instance.initialize(storagePath: dbDir);
    dbManager = instance;
    // 清空所有表数据，确保测试间数据隔离
    dbManager.db.execute('DELETE FROM scheduled_tasks');
    dbManager.db.execute('DELETE FROM device_configs');
    dbManager.db.execute('DELETE FROM messages');
    dbManager.db.execute('DELETE FROM skills');
    dbManager.db.execute('DELETE FROM sessions');
    dbManager.db.execute('DELETE FROM employees');
  });

  // ================================================================
  // EmployeeStore
  // ================================================================
  group('EmployeeStore', () {
    late EmployeeStore store;

    setUp(() {
      store = EmployeeStore(dbManager: dbManager);
    });

    test('增: save + find', () async {
      final now = DateTime.now();
      final entity = AiEmployeeEntity(
        uuid: 'emp-001',
        name: '测试员工',
        provider: 'openai',
        model: 'gpt-4',
        createTime: now,
        updateTime: now,
      );

      await store.save(entity);
      final result = await store.find(null, 'emp-001');

      expect(result, isNotNull);
      expect(result!.uuid, equals('emp-001'));
      expect(result.name, equals('测试员工'));
      expect(result.provider, equals('openai'));
      expect(result.model, equals('gpt-4'));
    });

    test('查: findAll + keyword 过滤', () async {
      final now = DateTime.now();
      for (var i = 1; i <= 3; i++) {
        await store.save(AiEmployeeEntity(
          uuid: 'emp-find-$i',
          name: '员工$i',
          status: 'active',
          createTime: now,
          updateTime: now,
        ));
      }

      final all = await store.findAll(null);
      expect(all.length, equals(3));

      final filtered = await store.findAll(null, keyword: '员工1');
      expect(filtered.length, equals(1));
      expect(filtered.first.name, equals('员工1'));
    });

    test('改: save 更新 + 验证', () async {
      final now = DateTime.now();
      await store.save(AiEmployeeEntity(
        uuid: 'emp-update',
        name: '原名',
        createTime: now,
        updateTime: now,
      ));

      // 更新
      await store.save(AiEmployeeEntity(
        uuid: 'emp-update',
        name: '新名',
        provider: 'claude',
        createTime: now,
        updateTime: DateTime.now(),
      ));

      final result = await store.find(null, 'emp-update');
      expect(result!.name, equals('新名'));
      expect(result.provider, equals('claude'));
    });

    test('删: 软删除 + findAll 过滤', () async {
      final now = DateTime.now();
      await store.save(AiEmployeeEntity(
        uuid: 'emp-del',
        name: '待删除',
        createTime: now,
        updateTime: now,
      ));

      await store.delete(null, 'emp-del');

      // findAll 不应包含已删除的
      final all = await store.findAll(null);
      expect(all.any((e) => e.uuid == 'emp-del'), isFalse);
    });

    test('count + exists', () async {
      final now = DateTime.now();
      await store.save(AiEmployeeEntity(
        uuid: 'emp-cnt',
        name: '计数',
        createTime: now,
        updateTime: now,
      ));

      expect(await store.count(null), equals(1));
      expect(await store.exists(null, 'emp-cnt'), isTrue);
      expect(await store.exists(null, 'nonexistent'), isFalse);
    });

    test('findAll 按 status 过滤', () async {
      final now = DateTime.now();
      await store.save(AiEmployeeEntity(
        uuid: 'emp-s1', name: 'A', status: 'active',
        createTime: now, updateTime: now,
      ));
      await store.save(AiEmployeeEntity(
        uuid: 'emp-s2', name: 'B', status: 'inactive',
        createTime: now, updateTime: now,
      ));

      final active = await store.findAll(null, status: 'active');
      expect(active.length, equals(1));
      expect(active.first.uuid, equals('emp-s1'));
    });
  });

  // ================================================================
  // SessionStore
  // ================================================================
  group('SessionStore', () {
    late SessionStore store;
    late String employeeId;

    setUp(() {
      store = SessionStore(dbManager: dbManager);
      employeeId = 'session-test-${DateTime.now().millisecondsSinceEpoch}';
    });

    test('增: save + find', () async {
      final now = DateTime.now();
      final session = AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: '测试会话',
        createTime: now,
        updateTime: now,
      );

      await store.save(session);
      final result = await store.find(employeeId);

      expect(result, isNotNull);
      expect(result!.title, equals('测试会话'));
      expect(result.employeeId, equals(employeeId));
    });

    test('查: findAll + 过滤', () async {
      final now = DateTime.now();
      await store.save(AiEmployeeSessionEntity(
        employeeId: '$employeeId-1',
        title: '会话1',
        isArchived: 0,
        createTime: now,
        updateTime: now,
      ));
      await store.save(AiEmployeeSessionEntity(
        employeeId: '$employeeId-2',
        title: '会话2',
        isArchived: 1,
        createTime: now,
        updateTime: now,
      ));

      final all = await store.findAll(includeArchived: true);
      expect(all.length, equals(2));

      final notArchived = await store.findAll(includeArchived: false);
      expect(notArchived.length, equals(1));
      expect(notArchived.first.employeeId, equals('$employeeId-1'));
    });

    test('改: update title', () async {
      final now = DateTime.now();
      await store.save(AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: '原标题',
        createTime: now,
        updateTime: now,
      ));

      await store.save(AiEmployeeSessionEntity(
        employeeId: employeeId,
        title: '新标题',
        createTime: now,
        updateTime: DateTime.now(),
      ));

      final result = await store.find(employeeId);
      expect(result!.title, equals('新标题'));
    });

    test('删: 软删除 + hardDelete', () async {
      final now = DateTime.now();
      await store.save(AiEmployeeSessionEntity(
        employeeId: employeeId,
        createTime: now,
        updateTime: now,
      ));

      await store.delete(employeeId);
      final deleted = await store.find(employeeId);
      expect(deleted!.deleted, equals(1));

      await store.hardDelete(employeeId);
      final gone = await store.find(employeeId);
      expect(gone, isNull);
    });

    test('getOrCreate', () async {
      final result = await store.getOrCreate(employeeId);
      expect(result.employeeId, equals(employeeId));
      expect(result.deleted, equals(0));

      // 再次调用应返回已有记录
      final result2 = await store.getOrCreate(employeeId);
      expect(result2.employeeId, equals(employeeId));
    });

    test('count', () async {
      final now = DateTime.now();
      await store.save(AiEmployeeSessionEntity(
        employeeId: '$employeeId-a',
        createTime: now,
        updateTime: now,
      ));
      await store.save(AiEmployeeSessionEntity(
        employeeId: '$employeeId-b',
        createTime: now,
        updateTime: now,
      ));

      expect(await store.count(), greaterThanOrEqualTo(2));
    });
  });

  // ================================================================
  // MessageStore
  // ================================================================
  group('MessageStore', () {
    late MessageStore store;
    late String employeeId;

    setUp(() {
      store = MessageStore(dbManager: dbManager);
      employeeId = 'msg-test-${DateTime.now().millisecondsSinceEpoch}';
    });

    AiEmployeeMessageEntity createMessage(String uuid, String role, String content,
        {DateTime? time}) {
      final now = time ?? DateTime.now();
      return AiEmployeeMessageEntity(
        uuid: uuid,
        employeeId: employeeId,
        role: role,
        type: 'text',
        content: content,
        createTime: now,
        updateTime: now,
      );
    }

    test('增: add + find', () async {
      final msg = createMessage('msg-001', 'user', '你好');
      await store.add(msg);

      final result = await store.find(null, 'msg-001');
      expect(result, isNotNull);
      expect(result!.role, equals('user'));
      expect(result.content, equals('你好'));
    });

    test('查: getMessages 分页', () async {
      for (var i = 1; i <= 10; i++) {
        final msg = createMessage(
          'msg-page-$i',
          'user',
          '消息$i',
          time: DateTime(2026, 1, 1, 0, i),
        );
        await store.add(msg);
      }

      // offset=0, limit=5 → 前5条（ASC排序）
      final first5 = await store.getMessages(null, employeeId, limit: 5, offset: 0);
      expect(first5.length, equals(5));
      expect(first5.first.content, equals('消息1'));

      // offset=5, limit=5 → 第6~10条
      final last5 = await store.getMessages(null, employeeId, limit: 5, offset: 5);
      expect(last5.length, equals(5));
      expect(last5.first.content, equals('消息6'));
    });

    test('查: getMessages 最后N条', () async {
      for (var i = 1; i <= 5; i++) {
        await store.add(createMessage(
          'msg-last-$i', 'user', '消息$i',
          time: DateTime(2026, 1, 1, 0, i),
        ));
      }

      // 无 offset, limit=3 → 取最后3条
      final last3 = await store.getMessages(null, employeeId, limit: 3);
      expect(last3.length, equals(3));
      expect(last3.first.content, equals('消息3'));
      expect(last3.last.content, equals('消息5'));
    });

    test('改: update + updateStatus', () async {
      await store.add(createMessage('msg-upd', 'user', '原文'));
      await store.update(createMessage('msg-upd', 'user', '已更新'));

      final result = await store.find(null, 'msg-upd');
      expect(result!.content, equals('已更新'));

      await store.updateStatus(null, 'msg-upd', 'completed', error: null);
      final updated = await store.find(null, 'msg-upd');
      expect(updated!.processingStatus, equals('completed'));
    });

    test('删: delete 单条 + deleteBySession', () async {
      await store.add(createMessage('msg-del1', 'user', 'A'));
      await store.add(createMessage('msg-del2', 'user', 'B'));

      await store.delete(null, 'msg-del1');
      expect(await store.find(null, 'msg-del1'), isNull);

      await store.deleteBySession(null, employeeId);
      final remaining = await store.getMessages(null, employeeId);
      expect(remaining.length, equals(0));
    });

    test('count + getLastMessage', () async {
      await store.add(createMessage(
        'msg-cnt-1', 'user', '第一条',
        time: DateTime(2026, 1, 1),
      ));
      await store.add(createMessage(
        'msg-cnt-2', 'assistant', '最后一条',
        time: DateTime(2026, 1, 1, 1),
      ));

      expect(await store.count(null, employeeId), equals(2));

      final last = await store.getLastMessage(null, employeeId);
      expect(last, isNotNull);
      expect(last!.role, equals('assistant'));
    });

    test('batchUpdateWithDeviceId 事务', () async {
      final entities = List.generate(
        5,
        (i) => createMessage('msg-batch-$i', 'user', '批量$i'),
      );
      await store.batchUpdateWithDeviceId(null, entities);

      expect(await store.count(null, employeeId), equals(5));
    });

    test('addWithDeviceId + updateWithDeviceId', () async {
      await store.addWithDeviceId('device-1',
          createMessage('msg-did', 'user', '通过deviceId添加'));
      final found = await store.find('device-1', 'msg-did');
      expect(found, isNotNull);

      await store.updateWithDeviceId('device-1',
          createMessage('msg-did', 'user', '通过deviceId更新'));
      final updated = await store.find('device-1', 'msg-did');
      expect(updated!.content, equals('通过deviceId更新'));
    });
  });

  // ================================================================
  // SkillStore
  // ================================================================
  group('SkillStore', () {
    late SkillStore store;
    late String employeeId;

    setUp(() {
      store = SkillStore(dbManager: dbManager);
      employeeId = 'skill-test-${DateTime.now().millisecondsSinceEpoch}';
    });

    AiEmployeeSkillEntity createSkill(String uuid, String name) {
      final now = DateTime.now();
      return AiEmployeeSkillEntity(
        uuid: uuid,
        employeeId: employeeId,
        name: name,
        skillType: 'mcp',
        config: '{"server": "test"}',
        createTime: now,
        updateTime: now,
      );
    }

    test('增: save + find', () async {
      await store.save(createSkill('sk-001', '搜索'));
      final result = await store.find(null, 'sk-001');

      expect(result, isNotNull);
      expect(result!.name, equals('搜索'));
      expect(result.config, equals('{"server": "test"}'));
    });

    test('查: findByEmployee', () async {
      await store.save(createSkill('sk-e1', '技能A'));
      await store.save(createSkill('sk-e2', '技能B'));

      final skills = await store.findByEmployee(null, employeeId);
      expect(skills.length, equals(2));
    });

    test('改: save 更新', () async {
      await store.save(createSkill('sk-upd', '旧名'));
      await store.save(AiEmployeeSkillEntity(
        uuid: 'sk-upd',
        employeeId: employeeId,
        name: '新名',
        skillType: 'file',
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));

      final result = await store.find(null, 'sk-upd');
      expect(result!.name, equals('新名'));
      expect(result.skillType, equals('file'));
    });

    test('删: 软删除 + hardDelete', () async {
      await store.save(createSkill('sk-del', '待删除'));
      await store.delete(null, 'sk-del');

      final result = await store.find(null, 'sk-del');
      expect(result, isNull); // find 过滤 deleted=0

      // 软删除后的数据还在
      final all = await store.findByEmployee(null, employeeId);
      expect(all.any((s) => s.uuid == 'sk-del'), isFalse);

      // hardDelete
      await store.save(createSkill('sk-hdel', '硬删除'));
      await store.hardDelete(null, 'sk-hdel');
      expect(await store.find(null, 'sk-hdel'), isNull);
    });

    test('deleteByEmployee 批量软删除', () async {
      await store.save(createSkill('sk-b1', 'A'));
      await store.save(createSkill('sk-b2', 'B'));

      await store.deleteByEmployee(null, employeeId);
      final remaining = await store.findByEmployee(null, employeeId);
      expect(remaining.length, equals(0));
    });

    test('count', () async {
      await store.save(createSkill('sk-cnt', '计数'));
      expect(await store.count(null, employeeId), equals(1));
    });
  });

  // ================================================================
  // DeviceConfigStore
  // ================================================================
  group('DeviceConfigStore', () {
    late DeviceConfigStore store;

    setUp(() {
      store = DeviceConfigStore(dbManager: dbManager);
    });

    test('增: save + find', () async {
      final now = DateTime.now();
      final config = DeviceConfigEntity(
        deviceId: 'dev-001',
        deviceInfo: DeviceInfoConfig(
          name: '测试设备',
          type: 'desktop',
          os: 'Windows',
        ),
        environmentVariables: {'KEY1': 'VALUE1'},
        createTime: now,
        updateTime: now,
      );

      await store.save(config);
      final result = await store.find('dev-001');

      expect(result, isNotNull);
      expect(result!.deviceInfo.name, equals('测试设备'));
      expect(result.deviceInfo.type, equals('desktop'));
      expect(result.environmentVariables['KEY1'], equals('VALUE1'));
    });

    test('查: findAll + count', () async {
      final now = DateTime.now();
      await store.save(DeviceConfigEntity(
        deviceId: 'dev-c1',
        createTime: now,
        updateTime: now,
      ));
      await store.save(DeviceConfigEntity(
        deviceId: 'dev-c2',
        createTime: now,
        updateTime: now,
      ));

      final all = await store.findAll();
      expect(all.length, greaterThanOrEqualTo(2));
      expect(await store.count(), greaterThanOrEqualTo(2));
    });

    test('改: updateDeviceInfo', () async {
      await store.save(DeviceConfigEntity(
        deviceId: 'dev-upd',
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));

      await store.updateDeviceInfo('dev-upd', DeviceInfoConfig(
        name: '新设备名',
        os: 'Linux',
      ));

      final result = await store.find('dev-upd');
      expect(result!.deviceInfo.name, equals('新设备名'));
      expect(result.deviceInfo.os, equals('Linux'));
    });

    test('改: setEnvironmentVariable + deleteEnvironmentVariable', () async {
      await store.save(DeviceConfigEntity(
        deviceId: 'dev-env',
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));

      await store.setEnvironmentVariable('dev-env', 'API_KEY', 'sk-123');
      var result = await store.find('dev-env');
      expect(result!.environmentVariables['API_KEY'], equals('sk-123'));

      await store.deleteEnvironmentVariable('dev-env', 'API_KEY');
      result = await store.find('dev-env');
      expect(result!.environmentVariables.containsKey('API_KEY'), isFalse);
    });

    test('删: delete', () async {
      await store.save(DeviceConfigEntity(
        deviceId: 'dev-del',
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));

      await store.delete('dev-del');
      expect(await store.find('dev-del'), isNull);
    });

    test('getOrCreate', () async {
      final result = await store.getOrCreate('dev-new');
      expect(result.deviceId, equals('dev-new'));

      final result2 = await store.getOrCreate('dev-new');
      expect(result2.deviceId, equals('dev-new'));
    });
  });

  // ================================================================
  // ScheduledTaskStore
  // ================================================================
  group('ScheduledTaskStore', () {
    late ScheduledTaskStore store;

    AiScheduledTaskEntity createTask(String uuid, String name,
        {DateTime? nextExecutionAt}) {
      final now = DateTime.now();
      return AiScheduledTaskEntity(
        uuid: uuid,
        name: name,
        description: '测试任务',
        scheduleType: 'interval',
        scheduleExpression: 'PT1H',
        nextExecutionAt: nextExecutionAt ?? now.add(const Duration(hours: 1)),
        createTime: now,
        updateTime: now,
      );
    }

    setUp(() {
      store = ScheduledTaskStore(dbManager: dbManager);
    });

    test('增: save + find', () async {
      final task = createTask('task-001', '每日提醒');
      await store.save(task);

      final result = await store.find('task-001');
      expect(result, isNotNull);
      expect(result!.name, equals('每日提醒'));
      expect(result.scheduleType, equals('interval'));
    });

    test('查: findAll + findByEmployee', () async {
      await store.save(createTask('task-a1', '任务A',
        nextExecutionAt: DateTime.now().add(const Duration(hours: 1)),
      ));
      await store.save(AiScheduledTaskEntity(
        uuid: 'task-a2',
        employeeId: 'emp-001',
        name: '任务B',
        nextExecutionAt: DateTime.now().add(const Duration(hours: 2)),
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));

      final all = await store.findAll();
      expect(all.length, greaterThanOrEqualTo(2));

      final byEmp = await store.findByEmployee('emp-001');
      expect(byEmp.length, equals(1));
      expect(byEmp.first.uuid, equals('task-a2'));
    });

    test('改: save 更新', () async {
      await store.save(createTask('task-upd', '原名'));
      await store.save(AiScheduledTaskEntity(
        uuid: 'task-upd',
        name: '新名',
        enabled: 0,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));

      final result = await store.find('task-upd');
      expect(result!.name, equals('新名'));
      expect(result.enabled, equals(0));
    });

    test('删: 软删除 + hardDelete + deleteByEmployee', () async {
      await store.save(createTask('task-del', '待删除'));
      await store.delete('task-del');

      final all = await store.findAll();
      expect(all.any((t) => t.uuid == 'task-del'), isFalse);

      // hardDelete
      await store.save(createTask('task-hdel', '硬删除'));
      await store.hardDelete('task-hdel');
      final found = await store.find('task-hdel');
      expect(found, isNull);

      // deleteByEmployee
      final empId = 'emp-del-test';
      await store.save(AiScheduledTaskEntity(
        uuid: 'task-bdel-1',
        employeeId: empId,
        name: 'B1',
        nextExecutionAt: DateTime.now().add(const Duration(hours: 1)),
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));
      await store.save(AiScheduledTaskEntity(
        uuid: 'task-bdel-2',
        employeeId: empId,
        name: 'B2',
        nextExecutionAt: DateTime.now().add(const Duration(hours: 1)),
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));

      await store.deleteByEmployee(empId);
      final remaining = await store.findByEmployee(empId);
      expect(remaining.length, equals(0));
    });

    test('findDueTasks', () async {
      final past = DateTime.now().subtract(const Duration(hours: 1));
      final future = DateTime.now().add(const Duration(hours: 1));

      // 到期任务（nextExecutionAt <= now）
      await store.save(createTask('task-due', '已到期',
        nextExecutionAt: past,
      ));

      // 未到期任务
      await store.save(createTask('task-future', '未到期',
        nextExecutionAt: future,
      ));

      // 已禁用任务
      await store.save(AiScheduledTaskEntity(
        uuid: 'task-disabled',
        name: '已禁用',
        enabled: 0,
        nextExecutionAt: past,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));

      final due = await store.findDueTasks();
      expect(due.length, greaterThanOrEqualTo(1));
      expect(due.any((t) => t.uuid == 'task-due'), isTrue);
      expect(due.any((t) => t.uuid == 'task-future'), isFalse);
      expect(due.any((t) => t.uuid == 'task-disabled'), isFalse);
    });
  });
}
