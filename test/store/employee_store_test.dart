import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';

int _testCounter = 0;

/// EmployeeStore CRUD 测试
///
/// 使用真实 SQLite 数据库，覆盖所有公共 API。
void main() {
  late String testDbPath;
  late String deviceId;
  late EmployeeStore store;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_employee_store_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    store = EmployeeStore(deviceId: deviceId);
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

  AiEmployeeEntity createEmployee({
    String? uuid,
    String? name,
    String? deviceId,
    String? description,
    String? systemPrompt,
    String? provider,
    String? model,
    String status = 'active',
    int deleted = 0,
    DateTime? deletedTime,
    int isPinned = 0,
    int sortOrder = 0,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return AiEmployeeEntity(
      uuid: uuid ?? const Uuid().v4(),
      name: name ?? '测试员工',
      deviceId: deviceId,
      description: description,
      systemPrompt: systemPrompt,
      provider: provider,
      model: model,
      status: status,
      deleted: deleted,
      deletedTime: deletedTime,
      isPinned: isPinned,
      sortOrder: sortOrder,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  // ═══════════════════════════════════════════════════
  // 1. save + find 基本读写
  // ═══════════════════════════════════════════════════

  group('save + find', () {
    test('save 后 find 返回相同数据', () async {
      final emp = createEmployee(
        name: '张三',
        description: '测试描述',
        provider: 'openai',
        model: 'gpt-4',
      );
      await store.save(emp);

      final found = await store.find(null, emp.uuid);
      expect(found, isNotNull);
      expect(found!.uuid, equals(emp.uuid));
      expect(found.name, equals('张三'));
      expect(found.description, equals('测试描述'));
      expect(found.provider, equals('openai'));
      expect(found.model, equals('gpt-4'));
    });

    test('find 不存在的 uuid 返回 null', () async {
      final found = await store.find(null, 'non-existent-uuid');
      expect(found, isNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // 2. save 覆盖更新（同 uuid，INSERT OR REPLACE）
  // ═══════════════════════════════════════════════════

  group('save 覆盖更新', () {
    test('同 uuid 保存两次，后者覆盖前者', () async {
      final emp = createEmployee(name: '原始名', description: '原始描述');
      await store.save(emp);

      final updated = emp.copyWith(name: '更新名', description: '更新描述');
      await store.save(updated);

      final found = await store.find(null, emp.uuid);
      expect(found, isNotNull);
      expect(found!.name, equals('更新名'));
      expect(found.description, equals('更新描述'));
    });

    test('覆盖后只有一条记录', () async {
      final emp = createEmployee(name: '唯一');
      await store.save(emp);
      await store.save(emp.copyWith(name: '覆盖'));

      final all = await store.findAll(null);
      final matching = all.where((e) => e.uuid == emp.uuid).toList();
      expect(matching.length, equals(1));
      expect(matching.first.name, equals('覆盖'));
    });
  });

  // ═══════════════════════════════════════════════════
  // 3. findAll(deviceId) 只返回该设备的员工
  // ═══════════════════════════════════════════════════

  group('findAll - deviceId 隔离', () {
    test('findAll(deviceId) 只返回该设备的员工', () async {
      await store.save(createEmployee(deviceId: 'dev-A', name: 'A员工1'));
      await store.save(createEmployee(deviceId: 'dev-B', name: 'B员工'));
      await store.save(createEmployee(deviceId: 'dev-A', name: 'A员工2'));

      final resultA = await store.findAll('dev-A');
      expect(resultA.length, equals(2));
      expect(resultA.every((e) => e.deviceId == 'dev-A'), isTrue);

      final resultB = await store.findAll('dev-B');
      expect(resultB.length, equals(1));
      expect(resultB.first.name, equals('B员工'));
    });

    test('findAll(不存在的 deviceId) 返回空列表', () async {
      await store.save(createEmployee(deviceId: 'dev-A'));
      final result = await store.findAll('dev-NONEXISTENT');
      expect(result, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════
  // 4. findAll(null) 返回所有设备员工
  // ═══════════════════════════════════════════════════

  group('findAll - null 返回全部', () {
    test('findAll(null) 返回所有设备的员工', () async {
      await store.save(createEmployee(deviceId: 'dev-A', name: 'A'));
      await store.save(createEmployee(deviceId: 'dev-B', name: 'B'));
      await store.save(createEmployee(deviceId: 'dev-C', name: 'C'));

      final result = await store.findAll(null);
      expect(result.length, equals(3));
    });
  });

  // ═══════════════════════════════════════════════════
  // 5. delete 软删除后 find 返回 null
  // ═══════════════════════════════════════════════════

  group('delete - 软删除', () {
    test('delete 后 find 返回 null', () async {
      final emp = createEmployee(name: '待删除');
      await store.save(emp);

      expect(await store.exists(null, emp.uuid), isTrue);

      await store.delete(null, emp.uuid);

      final found = await store.find(null, emp.uuid);
      expect(found, isNull);
      expect(await store.exists(null, emp.uuid), isFalse);
    });

    test('delete 设置 deletedTime', () async {
      final emp = createEmployee();
      await store.save(emp);

      await store.delete(null, emp.uuid);

      final deleted = await store.findIncludingDeleted(emp.uuid);
      expect(deleted, isNotNull);
      expect(deleted!.deleted, equals(1));
      expect(deleted.deletedTime, isNotNull);
    });

    test('delete 不存在的 uuid 不报错', () async {
      // 应该静默无操作
      await store.delete(null, 'non-existent-uuid');
    });
  });

  // ═══════════════════════════════════════════════════
  // 6. findIncludingDeleted 软删除后仍可查到
  // ═══════════════════════════════════════════════════

  group('findIncludingDeleted', () {
    test('软删除后 findIncludingDeleted 返回 deleted=1', () async {
      final emp = createEmployee(name: '已删除员工');
      await store.save(emp);

      await store.delete(null, emp.uuid);

      final found = await store.findIncludingDeleted(emp.uuid);
      expect(found, isNotNull);
      expect(found!.deleted, equals(1));
      expect(found.name, equals('已删除员工'));
    });

    test('直接保存 deleted=1 后 findIncludingDeleted 可查', () async {
      final emp = createEmployee(
        deleted: 1,
        deletedTime: DateTime(2024, 6, 1),
      );
      await store.save(emp);

      final found = await store.findIncludingDeleted(emp.uuid);
      expect(found, isNotNull);
      expect(found!.deleted, equals(1));
    });

    test('findIncludingDeleted 不存在返回 null', () async {
      final found = await store.findIncludingDeleted('non-existent');
      expect(found, isNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // 7. count 统计正确
  // ═══════════════════════════════════════════════════

  group('count', () {
    test('count 按 deviceId 统计', () async {
      await store.save(createEmployee(deviceId: 'dev-A'));
      await store.save(createEmployee(deviceId: 'dev-A'));
      await store.save(createEmployee(deviceId: 'dev-B'));

      expect(await store.count('dev-A'), equals(2));
      expect(await store.count('dev-B'), equals(1));
    });

    test('count(null) 统计所有', () async {
      await store.save(createEmployee(deviceId: 'dev-A'));
      await store.save(createEmployee(deviceId: 'dev-B'));

      expect(await store.count(null), equals(2));
    });

    test('count 不统计已删除', () async {
      await store.save(createEmployee());
      await store.save(createEmployee(deleted: 1));

      expect(await store.count(null), equals(1));
    });

    test('count 按 status 过滤', () async {
      await store.save(createEmployee(status: 'active'));
      await store.save(createEmployee(status: 'active'));
      await store.save(createEmployee(status: 'inactive'));

      expect(await store.count(null, status: 'active'), equals(2));
      expect(await store.count(null, status: 'inactive'), equals(1));
    });

    test('count 空数据库返回 0', () async {
      expect(await store.count(null), equals(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // 8. exists 判断正确
  // ═══════════════════════════════════════════════════

  group('exists', () {
    test('exists - 存在返回 true', () async {
      final emp = createEmployee();
      await store.save(emp);

      expect(await store.exists(null, emp.uuid), isTrue);
    });

    test('exists - 不存在返回 false', () async {
      expect(await store.exists(null, 'non-existent'), isFalse);
    });

    test('exists - 已删除返回 false', () async {
      final emp = createEmployee(deleted: 1);
      await store.save(emp);

      expect(await store.exists(null, emp.uuid), isFalse);
    });

    test('exists - 软删除后返回 false', () async {
      final emp = createEmployee();
      await store.save(emp);
      await store.delete(null, emp.uuid);

      expect(await store.exists(null, emp.uuid), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════
  // 9. findAll keyword 过滤
  // ═══════════════════════════════════════════════════

  group('findAll - keyword 过滤', () {
    test('keyword 按 name 模糊搜索', () async {
      await store.save(createEmployee(name: '张三'));
      await store.save(createEmployee(name: '李四'));
      await store.save(createEmployee(name: '张三丰'));

      final result = await store.findAll(null, keyword: '张');
      expect(result.length, equals(2));
      expect(result.every((e) => e.name.contains('张')), isTrue);
    });

    test('keyword 按 description 模糊搜索', () async {
      await store.save(createEmployee(
        name: '员工A',
        description: '前端开发工程师',
      ));
      await store.save(createEmployee(
        name: '员工B',
        description: '后端开发工程师',
      ));
      await store.save(createEmployee(
        name: '员工C',
        description: '产品经理',
      ));

      final result = await store.findAll(null, keyword: '开发');
      expect(result.length, equals(2));
    });

    test('keyword 空字符串返回全部', () async {
      await store.save(createEmployee(name: 'A'));
      await store.save(createEmployee(name: 'B'));

      final result = await store.findAll(null, keyword: '');
      expect(result.length, equals(2));
    });

    test('keyword null 返回全部', () async {
      await store.save(createEmployee(name: 'A'));
      await store.save(createEmployee(name: 'B'));

      final result = await store.findAll(null, keyword: null);
      expect(result.length, equals(2));
    });

    test('keyword 无匹配返回空', () async {
      await store.save(createEmployee(name: '张三'));

      final result = await store.findAll(null, keyword: '不存在的关键词');
      expect(result, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════
  // 10. findAll status 过滤
  // ═══════════════════════════════════════════════════

  group('findAll - status 过滤', () {
    test('status 过滤', () async {
      await store.save(createEmployee(status: 'active'));
      await store.save(createEmployee(status: 'inactive'));
      await store.save(createEmployee(status: 'active'));

      final active = await store.findAll(null, status: 'active');
      expect(active.length, equals(2));

      final inactive = await store.findAll(null, status: 'inactive');
      expect(inactive.length, equals(1));
    });

    test('status + keyword 联合过滤', () async {
      await store.save(createEmployee(
        name: '张三',
        status: 'active',
      ));
      await store.save(createEmployee(
        name: '李四',
        status: 'active',
      ));
      await store.save(createEmployee(
        name: '张三丰',
        status: 'inactive',
      ));

      final result = await store.findAll(null, keyword: '张', status: 'active');
      expect(result.length, equals(1));
      expect(result.first.name, equals('张三'));
    });
  });

  // ═══════════════════════════════════════════════════
  // 11. findAll includeDeleted=true 包含已删除
  // ═══════════════════════════════════════════════════

  group('findAll - includeDeleted', () {
    test('includeDeleted=false 不包含已删除', () async {
      await store.save(createEmployee(name: '正常'));
      await store.save(createEmployee(name: '已删除', deleted: 1));

      final result = await store.findAll(null, includeDeleted: false);
      expect(result.length, equals(1));
      expect(result.first.name, equals('正常'));
    });

    test('includeDeleted=true 包含已删除', () async {
      await store.save(createEmployee(name: '正常'));
      await store.save(createEmployee(name: '已删除', deleted: 1));

      final result = await store.findAll(null, includeDeleted: true);
      expect(result.length, equals(2));
    });

    test('软删除后 includeDeleted=true 包含', () async {
      final emp = createEmployee(name: '软删除');
      await store.save(emp);
      await store.delete(null, emp.uuid);

      final withoutDeleted = await store.findAll(null, includeDeleted: false);
      expect(withoutDeleted.length, equals(0));

      final withDeleted = await store.findAll(null, includeDeleted: true);
      expect(withDeleted.length, equals(1));
      expect(withDeleted.first.deleted, equals(1));
    });
  });

  // ═══════════════════════════════════════════════════
  // 12. 排序：is_pinned DESC, sort_order ASC
  // ═══════════════════════════════════════════════════

  group('findAll - 排序', () {
    test('is_pinned DESC, sort_order ASC', () async {
      await store.save(
          createEmployee(name: '普通1', isPinned: 0, sortOrder: 2));
      await store.save(
          createEmployee(name: '置顶1', isPinned: 1, sortOrder: 1));
      await store.save(
          createEmployee(name: '普通2', isPinned: 0, sortOrder: 1));
      await store.save(
          createEmployee(name: '置顶2', isPinned: 1, sortOrder: 2));

      final result = await store.findAll(null);
      // 置顶在前（按 sortOrder 升序），普通在后（按 sortOrder 升序）
      expect(result[0].name, equals('置顶1'));
      expect(result[1].name, equals('置顶2'));
      expect(result[2].name, equals('普通2'));
      expect(result[3].name, equals('普通1'));
    });

    test('全部置顶时按 sortOrder 排序', () async {
      await store.save(
          createEmployee(name: 'C', isPinned: 1, sortOrder: 3));
      await store.save(
          createEmployee(name: 'A', isPinned: 1, sortOrder: 1));
      await store.save(
          createEmployee(name: 'B', isPinned: 1, sortOrder: 2));

      final result = await store.findAll(null);
      expect(result[0].name, equals('A'));
      expect(result[1].name, equals('B'));
      expect(result[2].name, equals('C'));
    });

    test('全部普通时按 sortOrder 排序', () async {
      await store.save(
          createEmployee(name: 'C', isPinned: 0, sortOrder: 3));
      await store.save(
          createEmployee(name: 'A', isPinned: 0, sortOrder: 1));
      await store.save(
          createEmployee(name: 'B', isPinned: 0, sortOrder: 2));

      final result = await store.findAll(null);
      expect(result[0].name, equals('A'));
      expect(result[1].name, equals('B'));
      expect(result[2].name, equals('C'));
    });
  });
}
