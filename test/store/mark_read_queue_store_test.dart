import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/stores/mark_read_queue_store.dart';

int _testCounter = 0;

void main() {
  late String testDbPath;
  late String deviceId;
  late MarkReadQueueStore store;
  late Database db;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_mark_read_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);
    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';
    await DatabaseManager.getInstance(deviceId)
        .initialize(storagePath: testDbPath);
    store = MarkReadQueueStore(deviceId: deviceId);
    db = DatabaseManager.getInstance(deviceId).db;
    db.execute('''
      CREATE TABLE IF NOT EXISTS mark_read_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id TEXT NOT NULL,
        reader_device_id TEXT NOT NULL,
        message_ids TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  // =========================================================================
  // group: enqueue 入队测试
  // =========================================================================
  group('enqueue', () {
    test('入队一条不带 messageIds 的记录（标记全部已读）', () {
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
      );

      final pending = store.getPending();
      expect(pending, hasLength(1));
      expect(pending.first.employeeId, 'emp001');
      expect(pending.first.readerDeviceId, 'reader-dev-01');
      expect(pending.first.messageIdsJson, isNull);
      expect(pending.first.messageIds, isNull);
    });

    test('入队一条带 messageIds 列表的记录（标记指定消息已读）', () {
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001', 'msg-002', 'msg-003'],
      );

      final pending = store.getPending();
      expect(pending, hasLength(1));
      expect(pending.first.messageIdsJson, isNotNull);
      expect(
        pending.first.messageIds,
        equals(['msg-001', 'msg-002', 'msg-003']),
      );
    });

    test('入队多条记录，验证自增 id 和 created_at 时间戳', () {
      final beforeEnqueue = DateTime.now();

      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
      );

      // 确保两条记录的 created_at 不同
      Future.delayed(const Duration(milliseconds: 10)).then((_) {
        store.enqueue(
          employeeId: 'emp002',
          readerDeviceId: 'reader-dev-02',
          messageIds: ['msg-001'],
        );
      });

      // 等待延迟执行完成
      return Future.delayed(const Duration(milliseconds: 50)).then((_) {
        final pending = store.getPending();
        expect(pending, hasLength(2));

        // 验证自增 id
        expect(pending[0].id, lessThan(pending[1].id));

        // 验证 created_at 时间戳合理
        final afterEnqueue = DateTime.now();
        for (final entry in pending) {
          expect(
            entry.createdAt.millisecondsSinceEpoch,
            greaterThanOrEqualTo(beforeEnqueue.millisecondsSinceEpoch),
          );
          expect(
            entry.createdAt.millisecondsSinceEpoch,
            lessThanOrEqualTo(afterEnqueue.millisecondsSinceEpoch),
          );
        }

        // 验证按 created_at ASC 排序
        expect(
          pending[0].createdAt.millisecondsSinceEpoch,
          lessThanOrEqualTo(pending[1].createdAt.millisecondsSinceEpoch),
        );
      });
    });
  });

  // =========================================================================
  // group: getPending 获取待发送项测试
  // =========================================================================
  group('getPending', () {
    test('空队列返回空列表', () {
      final pending = store.getPending();
      expect(pending, isEmpty);
    });

    test('获取所有待发送项，按 created_at ASC 排序', () async {
      // 依次入队，确保时间顺序
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001'],
      );
      await Future.delayed(const Duration(milliseconds: 10));
      store.enqueue(
        employeeId: 'emp002',
        readerDeviceId: 'reader-dev-02',
        messageIds: ['msg-002'],
      );
      await Future.delayed(const Duration(milliseconds: 10));
      store.enqueue(
        employeeId: 'emp003',
        readerDeviceId: 'reader-dev-03',
        messageIds: ['msg-003'],
      );

      final pending = store.getPending();
      expect(pending, hasLength(3));

      // 验证按 created_at ASC 排序
      for (int i = 1; i < pending.length; i++) {
        expect(
          pending[i - 1].createdAt.millisecondsSinceEpoch,
          lessThanOrEqualTo(pending[i].createdAt.millisecondsSinceEpoch),
        );
      }

      expect(pending[0].employeeId, 'emp001');
      expect(pending[1].employeeId, 'emp002');
      expect(pending[2].employeeId, 'emp003');
    });

    test('按 employeeId 过滤获取待发送项', () {
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001'],
      );
      store.enqueue(
        employeeId: 'emp002',
        readerDeviceId: 'reader-dev-02',
        messageIds: ['msg-002'],
      );
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-03',
        messageIds: ['msg-003'],
      );

      final pending = store.getPending(employeeId: 'emp001');
      expect(pending, hasLength(2));
      for (final entry in pending) {
        expect(entry.employeeId, 'emp001');
      }

      final pendingEmp002 = store.getPending(employeeId: 'emp002');
      expect(pendingEmp002, hasLength(1));
      expect(pendingEmp002.first.employeeId, 'emp002');
    });

    test('验证返回的 MarkReadQueueEntry 字段正确', () {
      final beforeEnqueue = DateTime.now();
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001', 'msg-002'],
      );

      final pending = store.getPending();
      expect(pending, hasLength(1));
      final entry = pending.first;

      // id 应为正整数
      expect(entry.id, greaterThan(0));

      // 字段值正确
      expect(entry.employeeId, 'emp001');
      expect(entry.readerDeviceId, 'reader-dev-01');
      expect(entry.messageIdsJson, isNotNull);

      // created_at 在合理范围内
      final afterEnqueue = DateTime.now();
      expect(
        entry.createdAt.millisecondsSinceEpoch,
        greaterThanOrEqualTo(beforeEnqueue.millisecondsSinceEpoch),
      );
      expect(
        entry.createdAt.millisecondsSinceEpoch,
        lessThanOrEqualTo(afterEnqueue.millisecondsSinceEpoch),
      );
    });

    test('验证 messageIds getter 正确解析 JSON', () {
      // messageIds 为 null 的情况
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
      );

      // messageIds 为空列表的情况
      store.enqueue(
        employeeId: 'emp002',
        readerDeviceId: 'reader-dev-02',
        messageIds: [],
      );

      // messageIds 为非空列表的情况
      store.enqueue(
        employeeId: 'emp003',
        readerDeviceId: 'reader-dev-03',
        messageIds: ['a', 'b', 'c'],
      );

      final pending = store.getPending();
      expect(pending, hasLength(3));

      // null messageIds
      expect(pending[0].messageIds, isNull);

      // 空列表
      expect(pending[1].messageIds, isNotNull);
      expect(pending[1].messageIds, isEmpty);

      // 非空列表
      expect(pending[2].messageIds, equals(['a', 'b', 'c']));
    });
  });

  // =========================================================================
  // group: remove 移除测试
  // =========================================================================
  group('remove', () {
    test('移除存在的项，验证队列减少', () {
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001'],
      );
      store.enqueue(
        employeeId: 'emp002',
        readerDeviceId: 'reader-dev-02',
        messageIds: ['msg-002'],
      );

      expect(store.count(), equals(2));

      final pending = store.getPending();
      expect(pending, hasLength(2));
      final idToRemove = pending[0].id;

      store.remove(idToRemove);
      expect(store.count(), equals(1));

      final remaining = store.getPending();
      expect(remaining, hasLength(1));
      expect(remaining.first.id, isNot(equals(idToRemove)));
    });

    test('移除不存在的 id 无副作用', () {
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001'],
      );

      expect(store.count(), equals(1));

      // 移除一个不存在的 id
      store.remove(99999);

      expect(store.count(), equals(1));
      final pending = store.getPending();
      expect(pending, hasLength(1));
    });
  });

  // =========================================================================
  // group: removeAll 批量移除测试
  // =========================================================================
  group('removeAll', () {
    test('批量移除多个存在的 id', () {
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001'],
      );
      store.enqueue(
        employeeId: 'emp002',
        readerDeviceId: 'reader-dev-02',
        messageIds: ['msg-002'],
      );
      store.enqueue(
        employeeId: 'emp003',
        readerDeviceId: 'reader-dev-03',
        messageIds: ['msg-003'],
      );

      expect(store.count(), equals(3));

      final pending = store.getPending();
      final idsToRemove = pending.map((e) => e.id).toList();

      store.removeAll(idsToRemove);
      expect(store.count(), equals(0));
      expect(store.getPending(), isEmpty);
    });

    test('空列表调用无副作用', () {
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001'],
      );

      expect(store.count(), equals(1));

      store.removeAll([]);

      expect(store.count(), equals(1));
    });

    test('混合存在和不存在的 id，只移除存在的', () {
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001'],
      );
      store.enqueue(
        employeeId: 'emp002',
        readerDeviceId: 'reader-dev-02',
        messageIds: ['msg-002'],
      );

      expect(store.count(), equals(2));

      final pending = store.getPending();
      final existingId = pending[0].id;

      // 混合存在的和不存在的 id
      store.removeAll([existingId, 99998, 99999]);

      expect(store.count(), equals(1));
      final remaining = store.getPending();
      expect(remaining.first.id, isNot(equals(existingId)));
    });
  });

  // =========================================================================
  // group: clear 清空测试
  // =========================================================================
  group('clear', () {
    test('清空所有队列', () {
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001'],
      );
      store.enqueue(
        employeeId: 'emp002',
        readerDeviceId: 'reader-dev-02',
        messageIds: ['msg-002'],
      );

      expect(store.count(), equals(2));

      store.clear();

      expect(store.count(), equals(0));
      expect(store.getPending(), isEmpty);
    });

    test('按 employeeId 过滤清空，其他不受影响', () {
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001'],
      );
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-02',
        messageIds: ['msg-002'],
      );
      store.enqueue(
        employeeId: 'emp002',
        readerDeviceId: 'reader-dev-03',
        messageIds: ['msg-003'],
      );

      expect(store.count(), equals(3));

      store.clear(employeeId: 'emp001');

      expect(store.count(), equals(1));
      final remaining = store.getPending();
      expect(remaining, hasLength(1));
      expect(remaining.first.employeeId, 'emp002');
    });

    test('空队列清空无副作用', () {
      expect(store.count(), equals(0));

      store.clear();

      expect(store.count(), equals(0));
      expect(store.getPending(), isEmpty);
    });
  });

  // =========================================================================
  // group: count 计数测试
  // =========================================================================
  group('count', () {
    test('空队列计数为 0', () {
      expect(store.count(), equals(0));
    });

    test('入队后计数正确', () {
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
      );
      expect(store.count(), equals(1));

      store.enqueue(
        employeeId: 'emp002',
        readerDeviceId: 'reader-dev-02',
      );
      expect(store.count(), equals(2));

      store.enqueue(
        employeeId: 'emp003',
        readerDeviceId: 'reader-dev-03',
      );
      expect(store.count(), equals(3));
    });

    test('按 employeeId 过滤计数', () {
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001'],
      );
      store.enqueue(
        employeeId: 'emp002',
        readerDeviceId: 'reader-dev-02',
        messageIds: ['msg-002'],
      );
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-03',
        messageIds: ['msg-003'],
      );

      expect(store.count(), equals(3));
      expect(store.count(employeeId: 'emp001'), equals(2));
      expect(store.count(employeeId: 'emp002'), equals(1));
      expect(store.count(employeeId: 'emp999'), equals(0));
    });

    test('移除后计数减少', () {
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001'],
      );
      store.enqueue(
        employeeId: 'emp002',
        readerDeviceId: 'reader-dev-02',
        messageIds: ['msg-002'],
      );
      store.enqueue(
        employeeId: 'emp003',
        readerDeviceId: 'reader-dev-03',
        messageIds: ['msg-003'],
      );

      expect(store.count(), equals(3));

      final pending = store.getPending();
      store.remove(pending[0].id);
      expect(store.count(), equals(2));

      store.removeAll([pending[1].id, pending[2].id]);
      expect(store.count(), equals(0));
    });
  });

  // =========================================================================
  // group: 综合场景测试
  // =========================================================================
  group('综合场景', () {
    test('模拟断线重连场景：入队 → 获取待发送 → 发送成功后移除 → 队列为空',
        () async {
      // 1. 断线期间，多次标记已读请求入队
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
        messageIds: ['msg-001', 'msg-002'],
      );
      await Future.delayed(const Duration(milliseconds: 5));
      store.enqueue(
        employeeId: 'emp001',
        readerDeviceId: 'reader-dev-01',
      ); // 标记全部已读
      await Future.delayed(const Duration(milliseconds: 5));
      store.enqueue(
        employeeId: 'emp002',
        readerDeviceId: 'reader-dev-02',
        messageIds: ['msg-003'],
      );

      expect(store.count(), equals(3));

      // 2. 重连后，获取所有待发送项
      final pending = store.getPending();
      expect(pending, hasLength(3));

      // 3. 模拟发送成功，批量移除
      final ids = pending.map((e) => e.id).toList();
      store.removeAll(ids);

      // 4. 队列应为空
      expect(store.count(), equals(0));
      expect(store.getPending(), isEmpty);
    });

    test('多员工并发入队场景', () {
      const employees = ['emp-A', 'emp-B', 'emp-C', 'emp-D', 'emp-E'];
      const readers = [
        'reader-01',
        'reader-02',
        'reader-03',
      ];

      // 多个员工从不同设备标记已读
      for (int i = 0; i < employees.length; i++) {
        store.enqueue(
          employeeId: employees[i],
          readerDeviceId: readers[i % readers.length],
          messageIds: ['msg-${i * 10 + 1}', 'msg-${i * 10 + 2}'],
        );
      }

      // 每个员工再追加一个"标记全部已读"
      for (final emp in employees) {
        store.enqueue(
          employeeId: emp,
          readerDeviceId: 'reader-master',
        );
      }

      // 总共应有 10 条记录
      expect(store.count(), equals(10));

      // 每个员工应有 2 条记录
      for (final emp in employees) {
        expect(store.count(employeeId: emp), equals(2));
      }

      // 获取所有待发送项，验证按时间排序
      final pending = store.getPending();
      expect(pending, hasLength(10));
      for (int i = 1; i < pending.length; i++) {
        expect(
          pending[i - 1].createdAt.millisecondsSinceEpoch,
          lessThanOrEqualTo(pending[i].createdAt.millisecondsSinceEpoch),
        );
      }

      // 模拟按员工逐个处理
      for (final emp in employees) {
        final empPending = store.getPending(employeeId: emp);
        expect(empPending, hasLength(2));
        final ids = empPending.map((e) => e.id).toList();
        store.removeAll(ids);
        expect(store.count(employeeId: emp), equals(0));
      }

      // 全部处理完毕后队列应为空
      expect(store.count(), equals(0));
    });
  });
}
