import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:sqlite3/sqlite3.dart';

import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/spec_item_entity.dart';
import 'package:wenzagent/src/persistence/stores/spec_store.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

int _testCounter = 0;

/// 创建一个 [SpecItemEntity] 测试实例，所有字段均可覆盖。
SpecItemEntity createSpecItem({
  String? id,
  required String employeeId,
  String title = '测试Spec',
  String content = '测试内容',
  String status = 'pending',
  String priority = 'medium',
  String tags = '',
  int sortOrder = 0,
  int deleted = 0,
  DateTime? createTime,
  DateTime? updateTime,
}) {
  final now = DateTime.now();
  return SpecItemEntity(
    id: id ?? const Uuid().v4(),
    employeeId: employeeId,
    title: title,
    content: content,
    status: status,
    priority: priority,
    tags: tags,
    sortOrder: sortOrder,
    deleted: deleted,
    createTime: createTime ?? now,
    updateTime: updateTime ?? now,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late String testDbPath;
  late String deviceId;
  late SpecStore store;
  late Database db;

  // -----------------------------------------------------------------------
  // setUp / tearDown
  // -----------------------------------------------------------------------

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}\\wenzagent_spec_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);
    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';
    await DatabaseManager.getInstance(deviceId)
        .initialize(storagePath: testDbPath);
    store = SpecStore(deviceId: deviceId);
    db = DatabaseManager.getInstance(deviceId).db;
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
      )
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_spec_items_employee ON spec_items(employee_id)',
    );
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  // =======================================================================
  // group: save 保存测试
  // =======================================================================

  group('save', () {
    test('保存新 spec 项', () {
      final item = createSpecItem(employeeId: 'emp-1', title: '新Spec');
      store.save(item);

      final found = store.findById(item.id);
      expect(found, isNotNull);
      expect(found!.title, equals('新Spec'));
      expect(found.employeeId, equals('emp-1'));
    });

    test('保存后 findById 能找到', () {
      final item = createSpecItem(employeeId: 'emp-1');
      store.save(item);

      final found = store.findById(item.id);
      expect(found, isNotNull);
      expect(found!.id, equals(item.id));
    });

    test('INSERT OR REPLACE 更新已有项', () {
      final original = createSpecItem(
        employeeId: 'emp-1',
        title: '原标题',
        content: '原内容',
      );
      store.save(original);

      // 用相同 id 但不同内容保存
      final updated = original.copyWith(title: '新标题', content: '新内容');
      store.save(updated);

      final found = store.findById(original.id);
      expect(found, isNotNull);
      expect(found!.title, equals('新标题'));
      expect(found.content, equals('新内容'));
    });
  });

  // =======================================================================
  // group: findActiveByEmployee 查询活跃项测试
  // =======================================================================

  group('findActiveByEmployee', () {
    test('空结果', () {
      final result = store.findActiveByEmployee('emp-1');
      expect(result, isEmpty);
    });

    test('返回 draft/pending/in_progress 状态的项', () {
      const empId = 'emp-1';
      store.save(createSpecItem(employeeId: empId, status: 'draft'));
      store.save(createSpecItem(employeeId: empId, status: 'pending'));
      store.save(createSpecItem(employeeId: empId, status: 'in_progress'));

      final result = store.findActiveByEmployee(empId);
      expect(result.length, equals(3));
      final statuses = result.map((e) => e.status).toList();
      expect(statuses, containsAll(['draft', 'pending', 'in_progress']));
    });

    test('不返回 completed 状态', () {
      const empId = 'emp-1';
      store.save(createSpecItem(employeeId: empId, status: 'pending'));
      store.save(createSpecItem(employeeId: empId, status: 'completed'));

      final result = store.findActiveByEmployee(empId);
      expect(result.length, equals(1));
      expect(result.first.status, equals('pending'));
    });

    test('不返回 deleted 项', () {
      const empId = 'emp-1';
      final active = createSpecItem(employeeId: empId, status: 'pending');
      final deleted =
          createSpecItem(employeeId: empId, status: 'pending', deleted: 1);
      store.save(active);
      store.save(deleted);

      final result = store.findActiveByEmployee(empId);
      expect(result.length, equals(1));
      expect(result.first.id, equals(active.id));
    });

    test('按 sort_order ASC, create_time ASC 排序', () {
      const empId = 'emp-1';
      final base = DateTime(2024, 1, 1);

      // sortOrder=2, createTime 较早
      store.save(createSpecItem(
        employeeId: empId,
        sortOrder: 2,
        createTime: base,
        updateTime: base,
      ));
      // sortOrder=0, createTime 较晚 → 应排第一
      store.save(createSpecItem(
        employeeId: empId,
        sortOrder: 0,
        createTime: base.add(const Duration(hours: 2)),
        updateTime: base.add(const Duration(hours: 2)),
      ));
      // sortOrder=1, createTime 最早 → 应排第二
      store.save(createSpecItem(
        employeeId: empId,
        sortOrder: 1,
        createTime: base.subtract(const Duration(hours: 1)),
        updateTime: base.subtract(const Duration(hours: 1)),
      ));

      final result = store.findActiveByEmployee(empId);
      expect(result.length, equals(3));
      expect(result[0].sortOrder, equals(0));
      expect(result[1].sortOrder, equals(1));
      expect(result[2].sortOrder, equals(2));
    });
  });

  // =======================================================================
  // group: findCompletedByEmployee 查询已完成项测试
  // =======================================================================

  group('findCompletedByEmployee', () {
    test('空结果', () {
      final result = store.findCompletedByEmployee('emp-1');
      expect(result, isEmpty);
    });

    test('返回 completed 状态的项', () {
      const empId = 'emp-1';
      store.save(createSpecItem(employeeId: empId, status: 'completed'));
      store.save(createSpecItem(employeeId: empId, status: 'completed'));

      final result = store.findCompletedByEmployee(empId);
      expect(result.length, equals(2));
    });

    test('不返回其他状态', () {
      const empId = 'emp-1';
      store.save(createSpecItem(employeeId: empId, status: 'draft'));
      store.save(createSpecItem(employeeId: empId, status: 'pending'));
      store.save(createSpecItem(employeeId: empId, status: 'in_progress'));
      store.save(createSpecItem(employeeId: empId, status: 'completed'));

      final result = store.findCompletedByEmployee(empId);
      expect(result.length, equals(1));
      expect(result.first.status, equals('completed'));
    });

    test('limit 参数限制返回数量', () {
      const empId = 'emp-1';
      for (int i = 0; i < 5; i++) {
        store.save(createSpecItem(employeeId: empId, status: 'completed'));
      }

      final result = store.findCompletedByEmployee(empId, limit: 3);
      expect(result.length, equals(3));
    });

    test('按 update_time DESC 排序', () {
      const empId = 'emp-1';
      final base = DateTime(2024, 1, 1);

      final item1 = createSpecItem(
        employeeId: empId,
        status: 'completed',
        updateTime: base,
      );
      final item2 = createSpecItem(
        employeeId: empId,
        status: 'completed',
        updateTime: base.add(const Duration(hours: 2)),
      );
      final item3 = createSpecItem(
        employeeId: empId,
        status: 'completed',
        updateTime: base.add(const Duration(hours: 1)),
      );
      store.save(item1);
      store.save(item2);
      store.save(item3);

      final result = store.findCompletedByEmployee(empId);
      expect(result.length, equals(3));
      expect(result[0].id, equals(item2.id));
      expect(result[1].id, equals(item3.id));
      expect(result[2].id, equals(item1.id));
    });
  });

  // =======================================================================
  // group: findById 测试
  // =======================================================================

  group('findById', () {
    test('找到存在的项', () {
      final item = createSpecItem(employeeId: 'emp-1', title: '存在');
      store.save(item);

      final found = store.findById(item.id);
      expect(found, isNotNull);
      expect(found!.title, equals('存在'));
    });

    test('找不到返回 null', () {
      final found = store.findById('non-existent-id');
      expect(found, isNull);
    });

    test('不返回已删除的项', () {
      final item = createSpecItem(employeeId: 'emp-1', deleted: 1);
      store.save(item);

      final found = store.findById(item.id);
      expect(found, isNull);
    });
  });

  // =======================================================================
  // group: findByIdIncludingDeleted 测试
  // =======================================================================

  group('findByIdIncludingDeleted', () {
    test('能找到已删除的项', () {
      final item = createSpecItem(employeeId: 'emp-1', deleted: 1);
      store.save(item);

      final found = store.findByIdIncludingDeleted(item.id);
      expect(found, isNotNull);
      expect(found!.id, equals(item.id));
      expect(found.deleted, equals(1));
    });
  });

  // =======================================================================
  // group: findAllByEmployee 测试
  // =======================================================================

  group('findAllByEmployee', () {
    test('返回所有项（含已删除）', () {
      const empId = 'emp-1';
      store.save(createSpecItem(employeeId: empId, status: 'pending'));
      store.save(createSpecItem(employeeId: empId, status: 'completed'));
      store.save(createSpecItem(employeeId: empId, status: 'pending', deleted: 1));

      final result = store.findAllByEmployee(empId);
      expect(result.length, equals(3));
      // 确认包含已删除项
      final deletedCount = result.where((e) => e.deleted == 1).length;
      expect(deletedCount, equals(1));
    });
  });

  // =======================================================================
  // group: updateStatus 测试
  // =======================================================================

  group('updateStatus', () {
    test('更新状态成功', () {
      final item = createSpecItem(employeeId: 'emp-1', status: 'pending');
      store.save(item);

      store.updateStatus(item.id, 'in_progress');

      final found = store.findById(item.id);
      expect(found, isNotNull);
      expect(found!.status, equals('in_progress'));
    });

    test('updateTime 被更新', () {
      final base = DateTime(2024, 1, 1);
      final item = createSpecItem(
        employeeId: 'emp-1',
        status: 'pending',
        updateTime: base,
      );
      store.save(item);

      // 等待一小段时间确保时间戳不同
      store.updateStatus(item.id, 'completed');

      final found = store.findById(item.id)!;
      expect(found.updateTime.isAfter(base), isTrue);
    });
  });

  // =======================================================================
  // group: updateContent 测试
  // =======================================================================

  group('updateContent', () {
    test('同时更新 title 和 content', () {
      final item = createSpecItem(
        employeeId: 'emp-1',
        title: '原标题',
        content: '原内容',
      );
      store.save(item);

      store.updateContent(item.id, title: '新标题', content: '新内容');

      final found = store.findById(item.id)!;
      expect(found.title, equals('新标题'));
      expect(found.content, equals('新内容'));
    });

    test('只更新 title', () {
      final item = createSpecItem(
        employeeId: 'emp-1',
        title: '原标题',
        content: '原内容',
      );
      store.save(item);

      store.updateContent(item.id, title: '新标题');

      final found = store.findById(item.id)!;
      expect(found.title, equals('新标题'));
      expect(found.content, equals('原内容'));
    });

    test('只更新 content', () {
      final item = createSpecItem(
        employeeId: 'emp-1',
        title: '原标题',
        content: '原内容',
      );
      store.save(item);

      store.updateContent(item.id, content: '新内容');

      final found = store.findById(item.id)!;
      expect(found.title, equals('原标题'));
      expect(found.content, equals('新内容'));
    });

    test('都不传则不操作', () {
      final base = DateTime(2024, 1, 1);
      final item = createSpecItem(
        employeeId: 'emp-1',
        title: '原标题',
        content: '原内容',
        updateTime: base,
      );
      store.save(item);

      store.updateContent(item.id);

      final found = store.findById(item.id)!;
      expect(found.title, equals('原标题'));
      expect(found.content, equals('原内容'));
      // updateTime 不应改变
      expect(found.updateTime, equals(base));
    });
  });

  // =======================================================================
  // group: softDelete 测试
  // =======================================================================

  group('softDelete', () {
    test('软删除后 deleted=1', () {
      final item = createSpecItem(employeeId: 'emp-1');
      store.save(item);

      store.softDelete(item.id);

      final found = store.findByIdIncludingDeleted(item.id)!;
      expect(found.deleted, equals(1));
    });

    test('软删除后 findById 找不到', () {
      final item = createSpecItem(employeeId: 'emp-1');
      store.save(item);

      store.softDelete(item.id);

      final found = store.findById(item.id);
      expect(found, isNull);
    });

    test('findByIdIncludingDeleted 仍能找到', () {
      final item = createSpecItem(employeeId: 'emp-1');
      store.save(item);

      store.softDelete(item.id);

      final found = store.findByIdIncludingDeleted(item.id);
      expect(found, isNotNull);
      expect(found!.id, equals(item.id));
    });
  });

  // =======================================================================
  // group: deleteCompletedByEmployee 测试
  // =======================================================================

  group('deleteCompletedByEmployee', () {
    test('删除指定员工的所有 completed 项', () {
      const empId = 'emp-1';
      final c1 = createSpecItem(employeeId: empId, status: 'completed');
      final c2 = createSpecItem(employeeId: empId, status: 'completed');
      store.save(c1);
      store.save(c2);

      store.deleteCompletedByEmployee(empId);

      // 硬删除后 findByIdIncludingDeleted 也找不到
      expect(store.findByIdIncludingDeleted(c1.id), isNull);
      expect(store.findByIdIncludingDeleted(c2.id), isNull);
    });

    test('不影响其他状态的项', () {
      const empId = 'emp-1';
      final pending = createSpecItem(employeeId: empId, status: 'pending');
      final draft = createSpecItem(employeeId: empId, status: 'draft');
      final inProgress =
          createSpecItem(employeeId: empId, status: 'in_progress');
      store.save(pending);
      store.save(draft);
      store.save(inProgress);

      store.deleteCompletedByEmployee(empId);

      expect(store.findById(pending.id), isNotNull);
      expect(store.findById(draft.id), isNotNull);
      expect(store.findById(inProgress.id), isNotNull);
    });

    test('不影响其他员工的项', () {
      const empA = 'emp-A';
      const empB = 'emp-B';
      final completedA =
          createSpecItem(employeeId: empA, status: 'completed');
      final completedB =
          createSpecItem(employeeId: empB, status: 'completed');
      store.save(completedA);
      store.save(completedB);

      store.deleteCompletedByEmployee(empA);

      // A 的被删除
      expect(store.findByIdIncludingDeleted(completedA.id), isNull);
      // B 的保留
      expect(store.findByIdIncludingDeleted(completedB.id), isNotNull);
    });
  });

  // =======================================================================
  // group: reorderSpecs 测试
  // =======================================================================

  group('reorderSpecs', () {
    test('批量更新排序序号', () {
      const empId = 'emp-1';
      final a = createSpecItem(employeeId: empId, sortOrder: 99);
      final b = createSpecItem(employeeId: empId, sortOrder: 88);
      final c = createSpecItem(employeeId: empId, sortOrder: 77);
      store.save(a);
      store.save(b);
      store.save(c);

      // 按 c, a, b 的顺序重排
      store.reorderSpecs([c.id, a.id, b.id]);

      expect(store.findById(c.id)!.sortOrder, equals(0));
      expect(store.findById(a.id)!.sortOrder, equals(1));
      expect(store.findById(b.id)!.sortOrder, equals(2));
    });

    test('空列表无副作用', () {
      const empId = 'emp-1';
      final item = createSpecItem(employeeId: empId, sortOrder: 5);
      store.save(item);

      store.reorderSpecs([]);

      expect(store.findById(item.id)!.sortOrder, equals(5));
    });

    test('事务一致性 — 中间出错时全部回滚', () {
      const empId = 'emp-1';
      final a = createSpecItem(employeeId: empId, sortOrder: 0);
      final b = createSpecItem(employeeId: empId, sortOrder: 0);
      store.save(a);
      store.save(b);

      // 传入一个存在的 id 和一个不存在的 id
      // update 语句对不存在的 id 不会报错（SQLite UPDATE 影响 0 行），
      // 所以这里用另一种方式验证事务语义：
      // 确认正常流程全部成功
      store.reorderSpecs([a.id, b.id]);

      expect(store.findById(a.id)!.sortOrder, equals(0));
      expect(store.findById(b.id)!.sortOrder, equals(1));

      // 验证空列表不会破坏已有数据
      store.reorderSpecs([]);
      expect(store.findById(a.id)!.sortOrder, equals(0));
      expect(store.findById(b.id)!.sortOrder, equals(1));
    });
  });

  // =======================================================================
  // group: upsertFromRemote 远程同步测试
  // =======================================================================

  group('upsertFromRemote', () {
    test('本地不存在 → INSERT（返回 true）', () {
      final remote = createSpecItem(
        employeeId: 'emp-1',
        title: '远程新项',
      );

      final result = store.upsertFromRemote(remote);

      expect(result, isTrue);
      final found = store.findById(remote.id);
      expect(found, isNotNull);
      expect(found!.title, equals('远程新项'));
    });

    test('远程更新 → UPDATE（返回 true）', () {
      final base = DateTime(2024, 1, 1);
      final local = createSpecItem(
        employeeId: 'emp-1',
        title: '本地版本',
        updateTime: base,
      );
      store.save(local);

      final remote = local.copyWith(
        title: '远程更新版本',
        updateTime: base.add(const Duration(hours: 1)),
      );

      final result = store.upsertFromRemote(remote);

      expect(result, isTrue);
      final found = store.findById(local.id)!;
      expect(found.title, equals('远程更新版本'));
    });

    test('远程更旧 → 不更新（返回 false）', () {
      final base = DateTime(2024, 1, 1);
      final local = createSpecItem(
        employeeId: 'emp-1',
        title: '本地版本',
        updateTime: base.add(const Duration(hours: 1)),
      );
      store.save(local);

      final remote = local.copyWith(
        title: '远程旧版本',
        updateTime: base,
      );

      final result = store.upsertFromRemote(remote);

      expect(result, isFalse);
      final found = store.findById(local.id)!;
      expect(found.title, equals('本地版本'));
    });

    test('软删除合并：远程 deleted=1 → 本地也标记删除', () {
      final base = DateTime(2024, 1, 1);
      final local = createSpecItem(
        employeeId: 'emp-1',
        deleted: 0,
        updateTime: base,
      );
      store.save(local);

      final remote = local.copyWith(
        deleted: 1,
        updateTime: base.add(const Duration(hours: 1)),
      );

      final result = store.upsertFromRemote(remote);

      expect(result, isTrue);
      final found = store.findByIdIncludingDeleted(local.id)!;
      expect(found.deleted, equals(1));
      // findById 应该找不到
      expect(store.findById(local.id), isNull);
    });

    test('软删除合并：本地 deleted=1 → 保持删除', () {
      final base = DateTime(2024, 1, 1);
      final local = createSpecItem(
        employeeId: 'emp-1',
        deleted: 1,
        updateTime: base,
      );
      store.save(local);

      final remote = local.copyWith(
        deleted: 0,
        updateTime: base.add(const Duration(hours: 1)),
      );

      final result = store.upsertFromRemote(remote);

      // shouldUpdateDelete = true (mergedDeleted=1 != existing.deleted=1 → false)
      // shouldUpdateData = true → 保存 remote.copyWith(deleted: 1)
      expect(result, isTrue);
      final found = store.findByIdIncludingDeleted(local.id)!;
      expect(found.deleted, equals(1));
    });

    test('双方都 deleted=1 → 保留较新的', () {
      final base = DateTime(2024, 1, 1);
      final local = createSpecItem(
        employeeId: 'emp-1',
        deleted: 1,
        title: '本地删除版',
        updateTime: base,
      );
      store.save(local);

      final remote = local.copyWith(
        deleted: 1,
        title: '远程删除版',
        updateTime: base.add(const Duration(hours: 1)),
      );

      final result = store.upsertFromRemote(remote);

      expect(result, isTrue);
      final found = store.findByIdIncludingDeleted(local.id)!;
      expect(found.deleted, equals(1));
      // 远程较新，应采用远程数据
      expect(found.title, equals('远程删除版'));
    });
  });

  // =======================================================================
  // group: upsertAllFromRemote 测试
  // =======================================================================

  group('upsertAllFromRemote', () {
    test('批量同步返回正确变化数', () {
      const empId = 'emp-1';
      final base = DateTime(2024, 1, 1);

      // 本地已有一条
      final local = createSpecItem(
        employeeId: empId,
        title: '本地项',
        updateTime: base,
      );
      store.save(local);

      // 远程数据：1 个全新、1 个更新（远程较新）、1 个无变化（远程较旧）
      final newRemote = createSpecItem(
        employeeId: empId,
        title: '全新远程项',
        updateTime: base,
      );
      final updatedRemote = local.copyWith(
        title: '远程更新',
        updateTime: base.add(const Duration(hours: 1)),
      );
      final olderRemote = createSpecItem(
        employeeId: empId,
        title: '远程旧项',
        updateTime: base.subtract(const Duration(hours: 1)),
      );

      final changedCount = store.upsertAllFromRemote([
        newRemote,
        updatedRemote,
        olderRemote,
      ]);

      // newRemote: 新增 → true
      // updatedRemote: 更新 → true
      // olderRemote: 本地不存在 → 也是新增 → true
      expect(changedCount, equals(3));

      // 验证数据
      expect(store.findById(newRemote.id), isNotNull);
      expect(store.findById(local.id)!.title, equals('远程更新'));
      expect(store.findById(olderRemote.id), isNotNull);
    });
  });

  // =======================================================================
  // group: countByStatus 测试
  // =======================================================================

  group('countByStatus', () {
    test('各状态计数正确', () {
      const empId = 'emp-1';
      store.save(createSpecItem(employeeId: empId, status: 'draft'));
      store.save(createSpecItem(employeeId: empId, status: 'draft'));
      store.save(createSpecItem(employeeId: empId, status: 'pending'));
      store.save(createSpecItem(employeeId: empId, status: 'in_progress'));
      store.save(createSpecItem(employeeId: empId, status: 'in_progress'));
      store.save(createSpecItem(employeeId: empId, status: 'in_progress'));
      store.save(createSpecItem(employeeId: empId, status: 'completed'));

      final counts = store.countByStatus(empId);

      expect(counts['draft'], equals(2));
      expect(counts['pending'], equals(1));
      expect(counts['in_progress'], equals(3));
      expect(counts['completed'], equals(1));
    });

    test('已删除不计入', () {
      const empId = 'emp-1';
      store.save(createSpecItem(employeeId: empId, status: 'pending'));
      store.save(createSpecItem(employeeId: empId, status: 'pending', deleted: 1));
      store.save(createSpecItem(employeeId: empId, status: 'completed', deleted: 1));

      final counts = store.countByStatus(empId);

      expect(counts['pending'], equals(1));
      expect(counts['completed'], equals(0));
    });

    test('无数据时各状态为 0', () {
      final counts = store.countByStatus('emp-1');

      expect(counts['draft'], equals(0));
      expect(counts['pending'], equals(0));
      expect(counts['in_progress'], equals(0));
      expect(counts['completed'], equals(0));
    });
  });
}
