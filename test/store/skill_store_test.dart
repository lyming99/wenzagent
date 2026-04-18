import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';

int _testCounter = 0;

/// SkillStore CRUD 测试
///
/// 使用真实 SQLite 数据库，覆盖所有公共 API。
void main() {
  late String testDbPath;
  late String deviceId;
  late SkillStore store;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_skill_store_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    store = SkillStore(deviceId: deviceId);
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════
  // 辅助方法
  // ═══════════════════════════════════════════════════

  AiEmployeeSkillEntity createSkill({
    String? uuid,
    String? employeeId,
    String? deviceId,
    String name = '测试技能',
    String? description,
    String skillType = 'mcp',
    String? config,
    int enabled = 1,
    int sortOrder = 0,
    int deleted = 0,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return AiEmployeeSkillEntity(
      uuid: uuid ?? const Uuid().v4(),
      employeeId: employeeId ?? 'emp-${const Uuid().v4().substring(0, 8)}',
      deviceId: deviceId ?? '',
      name: name,
      description: description,
      skillType: skillType,
      config: config,
      enabled: enabled,
      sortOrder: sortOrder,
      deleted: deleted,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  // ═══════════════════════════════════════════════════
  // 1. saveWithDeviceId + findByEmployeeWithDeviceId 联合查询
  // ═══════════════════════════════════════════════════

  group('saveWithDeviceId + findByEmployeeWithDeviceId', () {
    test('按 deviceId + employeeId 联合查询', () async {
      final empId = 'emp-skill-1';

      final skill = createSkill(employeeId: empId, name: '技能A');
      await store.saveWithDeviceId(deviceId, skill);

      final results =
          await store.findByEmployeeWithDeviceId(deviceId, empId);
      expect(results.length, equals(1));
      expect(results.first.name, equals('技能A'));
      expect(results.first.deviceId, equals(deviceId));
    });

    test('不同 deviceId 的技能互不干扰', () async {
      final empId = 'emp-skill-2';

      final skillA = createSkill(employeeId: empId, name: '技能A');
      final skillB = createSkill(employeeId: empId, name: '技能B');

      await store.saveWithDeviceId('dev-A', skillA);
      await store.saveWithDeviceId('dev-B', skillB);

      final resultsA = await store.findByEmployeeWithDeviceId('dev-A', empId);
      expect(resultsA.length, equals(1));
      expect(resultsA.first.name, equals('技能A'));

      final resultsB = await store.findByEmployeeWithDeviceId('dev-B', empId);
      expect(resultsB.length, equals(1));
      expect(resultsB.first.name, equals('技能B'));
    });

    test('findByEmployeeWithDeviceId 不返回已删除', () async {
      final empId = 'emp-skill-del';

      final skill = createSkill(employeeId: empId, deleted: 1);
      await store.saveWithDeviceId(deviceId, skill);

      final results =
          await store.findByEmployeeWithDeviceId(deviceId, empId);
      expect(results, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════
  // 2. find 按 uuid 查找
  // ═══════════════════════════════════════════════════

  group('find - 按 uuid', () {
    test('find 返回已保存的技能', () async {
      final skill = createSkill(name: '查找技能');
      await store.save(skill);

      final found = await store.find(null, skill.uuid);
      expect(found, isNotNull);
      expect(found!.uuid, equals(skill.uuid));
      expect(found.name, equals('查找技能'));
    });

    test('find 不存在的 uuid 返回 null', () async {
      final found = await store.find(null, 'non-existent');
      expect(found, isNull);
    });

    test('find 不返回已删除的技能', () async {
      final skill = createSkill(deleted: 1);
      await store.save(skill);

      final found = await store.find(null, skill.uuid);
      expect(found, isNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // 3. delete 软删除后 find 返回 null
  // ═══════════════════════════════════════════════════

  group('delete - 软删除', () {
    test('delete 后 find 返回 null', () async {
      final skill = createSkill();
      await store.save(skill);

      // 确认存在
      expect(await store.find(null, skill.uuid), isNotNull);

      await store.delete(null, skill.uuid);

      expect(await store.find(null, skill.uuid), isNull);
    });

    test('delete 后 findByEmployee 不返回', () async {
      final empId = 'emp-del';
      final skill = createSkill(employeeId: empId, deviceId: deviceId);
      await store.save(skill);

      await store.delete(null, skill.uuid);

      final results = await store.findByEmployee(deviceId, empId);
      expect(results, isEmpty);
    });

    test('delete 不存在的 uuid 不报错', () async {
      await store.delete(null, 'non-existent');
    });
  });

  // ═══════════════════════════════════════════════════
  // 4. 多设备隔离
  // ═══════════════════════════════════════════════════

  group('多设备隔离', () {
    test('不同 deviceId 的 skills 互不干扰', () async {
      final empId = 'emp-isolate';

      final skillA = createSkill(
        employeeId: empId,
        deviceId: 'dev-A',
        name: 'A设备技能',
      );
      final skillB = createSkill(
        employeeId: empId,
        deviceId: 'dev-B',
        name: 'B设备技能',
      );

      await store.save(skillA);
      await store.save(skillB);

      final resultsA = await store.findByEmployee('dev-A', empId);
      expect(resultsA.length, equals(1));
      expect(resultsA.first.name, equals('A设备技能'));

      final resultsB = await store.findByEmployee('dev-B', empId);
      expect(resultsB.length, equals(1));
      expect(resultsB.first.name, equals('B设备技能'));
    });

    test('findByEmployee(null) 使用空字符串作为 deviceId', () async {
      final empId = 'emp-null-device';

      final skill = createSkill(employeeId: empId, deviceId: '');
      await store.save(skill);

      // findByEmployee 内部将 null 转为 ''
      final results = await store.findByEmployee(null, empId);
      expect(results.length, equals(1));
    });

    test('删除一个设备的技能不影响另一设备', () async {
      final empId = 'emp-del-isolate';

      final skillA = createSkill(
        employeeId: empId,
        deviceId: 'dev-A',
        name: 'A技能',
      );
      final skillB = createSkill(
        employeeId: empId,
        deviceId: 'dev-B',
        name: 'B技能',
      );

      await store.save(skillA);
      await store.save(skillB);

      // 删除 dev-A 的技能
      await store.delete('dev-A', skillA.uuid);

      // dev-B 的技能不受影响
      final resultsB = await store.findByEmployee('dev-B', empId);
      expect(resultsB.length, equals(1));
      expect(resultsB.first.name, equals('B技能'));
    });
  });

  // ═══════════════════════════════════════════════════
  // 5. SkillEntity 序列化 toMap/fromMap 往返
  // ═══════════════════════════════════════════════════

  group('SkillEntity 序列化往返', () {
    test('toMap/fromMap 所有字段一致', () {
      final now = DateTime(2024, 6, 15, 12, 0, 0);
      final skill = AiEmployeeSkillEntity(
        uuid: 'skill-uuid-123',
        employeeId: 'emp-123',
        deviceId: 'dev-test',
        name: '测试技能',
        description: '技能描述',
        skillType: 'mcp',
        config: '{"server":"test"}',
        enabled: 1,
        sortOrder: 5,
        deleted: 0,
        createTime: now,
        updateTime: now,
      );

      final map = skill.toMap();
      final restored = AiEmployeeSkillEntity.fromMap(map);

      expect(restored.uuid, equals(skill.uuid));
      expect(restored.employeeId, equals(skill.employeeId));
      expect(restored.deviceId, equals(skill.deviceId));
      expect(restored.name, equals(skill.name));
      expect(restored.description, equals(skill.description));
      expect(restored.skillType, equals(skill.skillType));
      expect(restored.config, equals(skill.config));
      expect(restored.enabled, equals(skill.enabled));
      expect(restored.sortOrder, equals(skill.sortOrder));
      expect(restored.deleted, equals(skill.deleted));
      expect(restored.createTime.millisecondsSinceEpoch,
          equals(skill.createTime.millisecondsSinceEpoch));
      expect(restored.updateTime.millisecondsSinceEpoch,
          equals(skill.updateTime.millisecondsSinceEpoch));
    });

    test('null 字段往返保持 null', () {
      final now = DateTime.now();
      final skill = AiEmployeeSkillEntity(
        uuid: 'skill-minimal',
        employeeId: 'emp-minimal',
        name: '最小技能',
        createTime: now,
        updateTime: now,
      );

      final map = skill.toMap();
      final restored = AiEmployeeSkillEntity.fromMap(map);

      expect(restored.description, isNull);
      expect(restored.config, isNull);
      expect(restored.deviceId, equals('')); // 默认值
      expect(restored.skillType, equals('mcp')); // 默认值
      expect(restored.enabled, equals(1)); // 默认值
      expect(restored.sortOrder, equals(0)); // 默认值
      expect(restored.deleted, equals(0)); // 默认值
    });

    test('copyWith 修改字段', () {
      final skill = createSkill(name: '原始', description: '原始描述');

      final modified = skill.copyWith(
        name: '修改名',
        description: '修改描述',
        enabled: 0,
        sortOrder: 10,
      );

      expect(modified.name, equals('修改名'));
      expect(modified.description, equals('修改描述'));
      expect(modified.enabled, equals(0));
      expect(modified.sortOrder, equals(10));
      expect(modified.uuid, equals(skill.uuid)); // 未修改
      expect(modified.employeeId, equals(skill.employeeId)); // 未修改
    });
  });

  // ═══════════════════════════════════════════════════
  // 6. saveWithDeviceId 正确设置 deviceId
  // ═══════════════════════════════════════════════════

  group('saveWithDeviceId', () {
    test('saveWithDeviceId 覆盖原有 deviceId', () async {
      final skill = createSkill(deviceId: '', name: '原始');
      await store.saveWithDeviceId('dev-target', skill);

      final found = await store.find(null, skill.uuid);
      expect(found, isNotNull);
      expect(found!.deviceId, equals('dev-target'));
    });

    test('saveWithDeviceId(null) 使用空字符串', () async {
      final skill = createSkill(deviceId: 'dev-old');
      await store.saveWithDeviceId(null, skill);

      final found = await store.find(null, skill.uuid);
      expect(found, isNotNull);
      expect(found!.deviceId, equals(''));
    });

    test('saveWithDeviceId 不改变其他字段', () async {
      final skill = createSkill(
        name: '技能名',
        description: '描述',
        skillType: 'note',
        config: '{"key":"value"}',
        enabled: 0,
        sortOrder: 3,
      );
      await store.saveWithDeviceId('dev-test', skill);

      final found = await store.find(null, skill.uuid);
      expect(found, isNotNull);
      expect(found!.name, equals('技能名'));
      expect(found.description, equals('描述'));
      expect(found.skillType, equals('note'));
      expect(found.config, equals('{"key":"value"}'));
      expect(found.enabled, equals(0));
      expect(found.sortOrder, equals(3));
    });
  });

  // ═══════════════════════════════════════════════════
  // 7. count 统计
  // ═══════════════════════════════════════════════════

  group('count', () {
    test('count 按 deviceId + employeeId 统计', () async {
      final empId = 'emp-count';

      await store.save(createSkill(employeeId: empId, deviceId: 'dev-A'));
      await store.save(createSkill(employeeId: empId, deviceId: 'dev-A'));
      await store.save(createSkill(employeeId: empId, deviceId: 'dev-B'));

      expect(await store.count('dev-A', empId), equals(2));
      expect(await store.count('dev-B', empId), equals(1));
    });

    test('count 不统计已删除', () async {
      final empId = 'emp-count-del';

      await store.save(createSkill(employeeId: empId, deviceId: deviceId));
      await store.save(
          createSkill(employeeId: empId, deviceId: deviceId, deleted: 1));

      expect(await store.count(deviceId, empId), equals(1));
    });

    test('count 空结果返回 0', () async {
      expect(await store.count('dev-none', 'emp-none'), equals(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // 8. deleteByEmployee 批量软删除
  // ═══════════════════════════════════════════════════

  group('deleteByEmployee', () {
    test('批量软删除指定员工的所有技能', () async {
      final empId = 'emp-batch-del';

      await store.save(createSkill(
          employeeId: empId, deviceId: deviceId, name: '技能1'));
      await store.save(createSkill(
          employeeId: empId, deviceId: deviceId, name: '技能2'));
      await store.save(createSkill(
          employeeId: empId, deviceId: deviceId, name: '技能3'));

      expect(await store.count(deviceId, empId), equals(3));

      await store.deleteByEmployee(deviceId, empId);

      expect(await store.count(deviceId, empId), equals(0));
      // find 也查不到
      final results = await store.findByEmployee(deviceId, empId);
      expect(results, isEmpty);
    });

    test('deleteByEmployee 不影响其他员工', () async {
      final empA = 'emp-A';
      final empB = 'emp-B';

      await store.save(
          createSkill(employeeId: empA, deviceId: deviceId, name: 'A技能'));
      await store.save(
          createSkill(employeeId: empB, deviceId: deviceId, name: 'B技能'));

      await store.deleteByEmployee(deviceId, empA);

      expect(await store.count(deviceId, empA), equals(0));
      expect(await store.count(deviceId, empB), equals(1));
    });

    test('deleteByEmployee 不影响其他设备', () async {
      final empId = 'emp-cross-device';

      await store.save(createSkill(
          employeeId: empId, deviceId: 'dev-A', name: 'A技能'));
      await store.save(createSkill(
          employeeId: empId, deviceId: 'dev-B', name: 'B技能'));

      await store.deleteByEmployee('dev-A', empId);

      expect(await store.count('dev-A', empId), equals(0));
      expect(await store.count('dev-B', empId), equals(1));
    });

    test('deleteByEmployee 不存在的组合不报错', () async {
      await store.deleteByEmployee('dev-none', 'emp-none');
    });
  });

  // ═══════════════════════════════════════════════════
  // 9. hardDelete 彻底删除
  // ═══════════════════════════════════════════════════

  group('hardDelete', () {
    test('hardDelete 后 find 返回 null', () async {
      final skill = createSkill();
      await store.save(skill);

      expect(await store.find(null, skill.uuid), isNotNull);

      await store.hardDelete(null, skill.uuid);

      expect(await store.find(null, skill.uuid), isNull);
    });

    test('hardDelete 已软删除的技能', () async {
      final skill = createSkill();
      await store.save(skill);
      await store.delete(null, skill.uuid);

      // 软删除后 find 返回 null
      expect(await store.find(null, skill.uuid), isNull);

      // 彻底删除
      await store.hardDelete(null, skill.uuid);

      // 仍然返回 null（但数据库中已无记录）
      expect(await store.find(null, skill.uuid), isNull);
    });

    test('hardDelete 不存在的 uuid 不报错', () async {
      await store.hardDelete(null, 'non-existent');
    });

    test('hardDelete 后重新保存同 uuid 可正常工作', () async {
      final skill = createSkill(name: '原始');
      await store.save(skill);
      await store.hardDelete(null, skill.uuid);

      // 重新保存
      final newSkill = skill.copyWith(name: '重新创建');
      await store.save(newSkill);

      final found = await store.find(null, skill.uuid);
      expect(found, isNotNull);
      expect(found!.name, equals('重新创建'));
    });
  });
}
