import 'dart:io';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/stores/todo_store.dart';
import 'package:wenzagent/src/persistence/entities/todo_topic_entity.dart';
import 'package:wenzagent/src/persistence/entities/todo_task_item_entity.dart';

int _testCounter = 0;

/// 创建一个测试用 TodoTopicEntity
TodoTopicEntity makeTopic({
  String? id,
  String employeeId = 'emp-001',
  String title = 'Test Topic',
  String description = 'Test Description',
  String status = 'pending',
  int sortOrder = 0,
  int deleted = 0,
  DateTime? createTime,
  DateTime? updateTime,
  DateTime? completedAt,
}) {
  final now = DateTime.now();
  return TodoTopicEntity(
    id: id ?? const Uuid().v4(),
    employeeId: employeeId,
    title: title,
    description: description,
    status: status,
    sortOrder: sortOrder,
    deleted: deleted,
    createTime: createTime ?? now,
    updateTime: updateTime ?? now,
    completedAt: completedAt,
  );
}

/// 创建一个测试用 TodoTaskItemEntity
TodoTaskItemEntity makeTaskItem({
  String? id,
  String employeeId = 'emp-001',
  String? topicId,
  String title = 'Test Task',
  String content = 'Test Content',
  String status = 'pending',
  int sortOrder = 0,
  int deleted = 0,
  DateTime? createTime,
  DateTime? updateTime,
  DateTime? completedAt,
}) {
  final now = DateTime.now();
  return TodoTaskItemEntity(
    id: id ?? const Uuid().v4(),
    employeeId: employeeId,
    topicId: topicId ?? const Uuid().v4(),
    title: title,
    content: content,
    status: status,
    sortOrder: sortOrder,
    deleted: deleted,
    createTime: createTime ?? now,
    updateTime: updateTime ?? now,
    completedAt: completedAt,
  );
}

Future<void> main() async {
  late String testDbPath;
  late String deviceId;
  late TodoStore store;
  late SqliteDatabase db;

  setUp(() async {
    _testCounter++;
    testDbPath = '${Directory.systemTemp.path}/wenzagent_todo_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);
    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';
    await DatabaseManager.getInstance(deviceId)
        .initialize(storagePath: testDbPath);
    store = TodoStore(deviceId: deviceId);
    db = DatabaseManager.getInstance(deviceId).db;
    db.execute('''CREATE TABLE IF NOT EXISTS todo_topics (
      id TEXT PRIMARY KEY, employee_id TEXT NOT NULL, title TEXT NOT NULL,
      description TEXT DEFAULT '', status TEXT DEFAULT 'pending',
      sort_order INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0,
      create_time INTEGER NOT NULL, update_time INTEGER NOT NULL, completed_at INTEGER)''');
    db.execute('''CREATE TABLE IF NOT EXISTS todo_task_items (
      id TEXT PRIMARY KEY, employee_id TEXT NOT NULL, topic_id TEXT NOT NULL, title TEXT NOT NULL,
      content TEXT DEFAULT '', status TEXT DEFAULT 'pending',
      sort_order INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0,
      create_time INTEGER NOT NULL, update_time INTEGER NOT NULL, completed_at INTEGER)''');
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    try {
      Future<await> Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  // ====================================================================
  // group: saveTopic 保存测试
  // ====================================================================
  group('saveTopic', () async {
    test('保存新主题后可通过 findTopicById 查到', () async {
      final topic = makeTopic(id: 'topic-1', title: '新主题');
      await sawait tore.saveTopic(topic);

      final found = await sawait tore.findTopicById('topic-1');
      expect(found, isNotNull);
      expect(found!.id, 'topic-1');
      expect(found.title, '新主题');
      expect(found.employeeId, 'emp-001');
      expect(found.status, 'pending');
      expect(found.deleted, 0);
    });

    test('INSERT OR REPLACE 更新已有主题', () async {
      final now = DateTime.now();
      final original = makeTopic(
        id: 'topic-1',
        title: '原始标题',
        description: '原始描述',
        createTime: now,
        updateTime: now,
      );
      await sawait tore.saveTopic(original);

      final updated = original.copyWith(
        title: '更新标题',
        description: '更新描述',
        status: 'in_progress',
        updateTime: DateTime.now().add(const Duration(hours: 1)),
      );
      await sawait tore.saveTopic(updated);

      final found = await sawait tore.findTopicById('topic-1');
      expect(found, isNotNull);
      expect(found!.title, '更新标题');
      expect(found.description, '更新描述');
      expect(found.status, 'in_progress');
    });
  });

  // ====================================================================
  // group: findTopicById / findTopicByIdIncludingDeleted
  // ====================================================================
  group('findTopicById / findTopicByIdIncludingDeleted', () {
    test('找到存在的主题', () async {
      final topic = makeTopic(id: 'topic-1');
      await sawait tore.saveTopic(topic);

      final found = await sawait tore.findTopicById('topic-1');
      expect(found, isNotNull);
      expect(found!.id, 'topic-1');
    });

    test('找不到返回 null', () async {
      final found = await sawait tore.findTopicById('nonexistent');
      expect(found, isNull);
    });

    test('findTopicById 不含已删除，findTopicByIdIncludingDeleted 含已删除', () async {
      final topic = makeTopic(id: 'topic-1', deleted: 1);
      await sawait tore.saveTopic(topic);

      expect(await sawait tore.findTopicById('topic-1'), isNull);
      expect(await sawait tore.findTopicByIdIncludingDeleted('topic-1'), isNotNull);
      expect((await sawait tore.findTopicByIdIncludingDeleted('topic-1'))!.deleted, 1);
    });
  });

  // ====================================================================
  // group: findCurrentTopics / findPendingTopics / findAllTopics / findCompletedTopics
  // ====================================================================
  group('findCurrentTopics / findPendingTopics / findAllTopics / findCompletedTopics', () {
    test('各方法返回正确状态过滤', () async {
      await sawait tore.saveTopic(makeTopic(id: 't-pending', status: 'pending'));
      await sawait tore.saveTopic(makeTopic(id: 't-progress', status: 'in_progress'));
      await sawait tore.saveTopic(
        makeTopic(id: 't-completed', status: 'completed')
            .copyWith(completedAt: () => DateTime.now()),
      );

      final pending = await sawait tore.findPendingTopics('emp-001');
      final current = await sawait tore.findCurrentTopics('emp-001');
      final completed = await sawait tore.findCompletedTopics('emp-001');
      final all = await sawait tore.findAllTopics('emp-001');

      expect(pending.length, 1);
      expect(pending[0].id, 't-pending');

      expect(current.length, 1);
      expect(current[0].id, 't-progress');

      expect(completed.length, 1);
      expect(completed[0].id, 't-completed');

      expect(all.length, 3);
    });

    test('不返回已删除的主题', () async {
      await sawait tore.saveTopic(makeTopic(id: 't-active', status: 'pending'));
      await sawait tore.saveTopic(makeTopic(id: 't-deleted', status: 'pending', deleted: 1));

      expect((await sawait tore.findPendingTopics('emp-001')).length, 1);
      expect((await sawait tore.findAllTopics('emp-001')).length, 1);
      expect((await sawait tore.findAllTopicsIncludingDeleted('emp-001')).length, 2);
    });

    test('findCompletedTopics 的 limit 参数', () async {
      for (int i = 0; i < 5; i++) {
        await sawait tore.saveTopic(
          makeTopic(id: 't-c$i', status: 'completed')
              .copyWith(
                completedAt: () => DateTime.now().add(Duration(hours: i)),
              ),
        );
      }

      final all5 = await sawait tore.findCompletedTopics('emp-001');
      expect(all5.length, 5);

      final limited = await sawait tore.findCompletedTopics('emp-001', limit: 2);
      expect(limited.length, 2);
    });

    test('排序验证：sort_order ASC, create_time ASC', () async {
      final base = DateTime(2024, 1, 1);
      await sawait tore.saveTopic(makeTopic(
        id: 't-3',
        sortOrder: 2,
        createTime: base.add(const Duration(hours: 1)),
      ));
      await sawait tore.saveTopic(makeTopic(
        id: 't-1',
        sortOrder: 0,
        createTime: base.add(const Duration(hours: 2)),
      ));
      await sawait tore.saveTopic(makeTopic(
        id: 't-2',
        sortOrder: 1,
        createTime: base,
      ));

      final all = await sawait tore.findAllTopics('emp-001');
      expect(all.map((e) => e.id).toList(), ['t-1', 't-2', 't-3']);
    });

    test('findCompletedTopics 按 completed_at DESC 排序', () async {
      await sawait tore.saveTopic(
        makeTopic(id: 't-old', status: 'completed')
            .copyWith(completedAt: () => DateTime(2024, 1, 1)),
      );
      await sawait tore.saveTopic(
        makeTopic(id: 't-new', status: 'completed')
            .copyWith(completedAt: () => DateTime(2024, 6, 1)),
      );
      await sawait tore.saveTopic(
        makeTopic(id: 't-mid', status: 'completed')
            .copyWith(completedAt: () => DateTime(2024, 3, 1)),
      );

      final completed = await sawait tore.findCompletedTopics('emp-001');
      expect(completed.map((e) => e.id).toList(), ['t-new', 't-mid', 't-old']);
    });
  });

  // ====================================================================
  // group: updateTopicContent
  // ====================================================================
  group('updateTopicContent', () {
    test('同时更新 title 和 description', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.updateTopicContent('topic-1', title: '新标题', description: '新描述');

      final found = (await sawait tore.findTopicById('topic-1'))!;
      expect(found.title, '新标题');
      expect(found.description, '新描述');
    });

    test('只更新 title', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1', description: '保留描述'));
      await sawait tore.updateTopicContent('topic-1', title: '新标题');

      final found = (await sawait tore.findTopicById('topic-1'))!;
      expect(found.title, '新标题');
      expect(found.description, '保留描述');
    });

    test('只更新 description', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1', title: '保留标题'));
      await sawait tore.updateTopicContent('topic-1', description: '新描述');

      final found = (await sawait tore.findTopicById('topic-1'))!;
      expect(found.title, '保留标题');
      expect(found.description, '新描述');
    });
  });

  // ====================================================================
  // group: updateTopicStatus
  // ====================================================================
  group('updateTopicStatus', () {
    test('更新为 completed 时 completedAt 被设置', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1', status: 'pending'));
      await sawait tore.updateTopicStatus('topic-1', 'completed');

      final found = (await sawait tore.findTopicById('topic-1'))!;
      expect(found.status, 'completed');
      expect(found.completedAt, isNotNull);
    });

    test('更新为其他状态时 completedAt 为 null', () async {
      await sawait tore.saveTopic(
        makeTopic(id: 'topic-1', status: 'completed')
            .copyWith(completedAt: () => DateTime.now()),
      );
      await sawait tore.updateTopicStatus('topic-1', 'pending');

      final found = (await sawait tore.findTopicById('topic-1'))!;
      expect(found.status, 'pending');
      expect(found.completedAt, isNull);
    });
  });

  // ====================================================================
  // group: softDeleteTopic
  // ====================================================================
  group('softDeleteTopic', () {
    test('软删除主题后 findTopicById 找不到', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.softDeleteTopic('topic-1');

      expect(await sawait tore.findTopicById('topic-1'), isNull);
      expect((await sawait tore.findTopicByIdIncludingDeleted('topic-1'))!.deleted, 1);
    });

    test('级联软删除子项', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-1', topicId: 'topic-1'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-2', topicId: 'topic-1'));

      await sawait tore.softDeleteTopic('topic-1');

      expect(await sawait tore.findTopicById('topic-1'), isNull);
      expect(await sawait tore.findTaskItemById('item-1'), isNull);
      expect(await sawait tore.findTaskItemById('item-2'), isNull);

      expect((await sawait tore.findTopicByIdIncludingDeleted('topic-1'))!.deleted, 1);
      expect((await sawait tore.findTaskItemByIdIncludingDeleted('item-1'))!.deleted, 1);
      expect((await sawait tore.findTaskItemByIdIncludingDeleted('item-2'))!.deleted, 1);
    });
  });

  // ====================================================================
  // group: deleteCompletedTopics
  // ====================================================================
  group('deleteCompletedTopics', () {
    test('删除已完成主题及其子项', () async {
      await sawait tore.saveTopic(
        makeTopic(id: 'topic-done', status: 'completed')
            .copyWith(completedAt: () => DateTime.now()),
      );
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-1', topicId: 'topic-done'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-2', topicId: 'topic-done'));

      await sawait tore.deleteCompletedTopics('emp-001');

      expect(await sawait tore.findTopicByIdIncludingDeleted('topic-done'), isNull);
      expect(await sawait tore.findTaskItemByIdIncludingDeleted('item-1'), isNull);
      expect(await sawait tore.findTaskItemByIdIncludingDeleted('item-2'), isNull);
    });

    test('不影响其他状态的主题', () async {
      await sawait tore.saveTopic(
        makeTopic(id: 'topic-done', status: 'completed')
            .copyWith(completedAt: () => DateTime.now()),
      );
      await sawait tore.saveTopic(makeTopic(id: 'topic-pending', status: 'pending'));
      await sawait tore.saveTopic(makeTopic(id: 'topic-progress', status: 'in_progress'));

      await sawait tore.deleteCompletedTopics('emp-001');

      expect(await sawait tore.findTopicByIdIncludingDeleted('topic-done'), isNull);
      expect(await sawait tore.findTopicById('topic-pending'), isNotNull);
      expect(await sawait tore.findTopicById('topic-progress'), isNotNull);
    });
  });

  // ====================================================================
  // group: recalculateTopicStatus
  // ====================================================================
  group('recalculateTopicStatus', () {
    test('无子项 → pending', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1', status: 'in_progress'));
      await sawait tore.recalculateTopicStatus('topic-1');

      final found = (await sawait tore.findTopicById('topic-1'))!;
      expect(found.status, 'pending');
      expect(found.completedAt, isNull);
    });

    test('有 in_progress 子项 → in_progress', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1', status: 'pending'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-1', topicId: 'topic-1', status: 'in_progress'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-2', topicId: 'topic-1', status: 'completed'));

      await sawait tore.recalculateTopicStatus('topic-1');

      final found = (await sawait tore.findTopicById('topic-1'))!;
      expect(found.status, 'in_progress');
    });

    test('全部 completed → completed', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1', status: 'pending'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-1', topicId: 'topic-1', status: 'completed'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-2', topicId: 'topic-1', status: 'completed'));

      await sawait tore.recalculateTopicStatus('topic-1');

      final found = (await sawait tore.findTopicById('topic-1'))!;
      expect(found.status, 'completed');
      expect(found.completedAt, isNotNull);
    });

    test('部分 completed → pending', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1', status: 'in_progress'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-1', topicId: 'topic-1', status: 'completed'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-2', topicId: 'topic-1', status: 'pending'));

      await sawait tore.recalculateTopicStatus('topic-1');

      final found = (await sawait tore.findTopicById('topic-1'))!;
      expect(found.status, 'pending');
      expect(found.completedAt, isNull);
    });

    test('已删除子项不计入推导', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1', status: 'pending'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-1', topicId: 'topic-1', status: 'completed'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-2', topicId: 'topic-1', status: 'in_progress', deleted: 1));

      // 只有 item-1 (completed) 有效，item-2 已删除不计入
      // 全部有效子项 completed → completed
      await sawait tore.recalculateTopicStatus('topic-1');

      final found = (await sawait tore.findTopicById('topic-1'))!;
      expect(found.status, 'completed');
      expect(found.completedAt, isNotNull);
    });
  });

  // ====================================================================
  // group: reorderTopics / reorderTaskItems
  // ====================================================================
  group('reorderTopics / reorderTaskItems', () {
    test('reorderTopics 批量更新排序', () async {
      await sawait tore.saveTopic(makeTopic(id: 't-1', sortOrder: 99));
      await sawait tore.saveTopic(makeTopic(id: 't-2', sortOrder: 88));
      await sawait tore.saveTopic(makeTopic(id: 't-3', sortOrder: 77));

      await sawait tore.reorderTopics(['t-3', 't-1', 't-2']);

      final all = await sawait tore.findAllTopics('emp-001');
      expect(all[0].id, 't-3');
      expect(all[0].sortOrder, 0);
      expect(all[1].id, 't-1');
      expect(all[1].sortOrder, 1);
      expect(all[2].id, 't-2');
      expect(all[2].sortOrder, 2);
    });

    test('reorderTopics 空列表无副作用', () async {
      await sawait tore.saveTopic(makeTopic(id: 't-1', sortOrder: 5));

      await sawait tore.reorderTopics([]);

      final found = (await sawait tore.findTopicById('t-1'))!;
      expect(found.sortOrder, 5);
    });

    test('reorderTaskItems 批量更新排序', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'i-1', topicId: 'topic-1', sortOrder: 99));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'i-2', topicId: 'topic-1', sortOrder: 88));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'i-3', topicId: 'topic-1', sortOrder: 77));

      await sawait tore.reorderTaskItems(['i-3', 'i-1', 'i-2']);

      final items = await sawait tore.findTaskItemsByTopic('topic-1');
      expect(items[0].id, 'i-3');
      expect(items[0].sortOrder, 0);
      expect(items[1].id, 'i-1');
      expect(items[1].sortOrder, 1);
      expect(items[2].id, 'i-2');
      expect(items[2].sortOrder, 2);
    });

    test('reorderTaskItems 空列表无副作用', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'i-1', topicId: 'topic-1', sortOrder: 5));

      await sawait tore.reorderTaskItems([]);

      final found = (await sawait tore.findTaskItemById('i-1'))!;
      expect(found.sortOrder, 5);
    });
  });

  // ====================================================================
  // group: saveTaskItem / findTaskItemsByTopic / findTaskItemById
  // ====================================================================
  group('saveTaskItem / findTaskItemsByTopic / findTaskItemById', () {
    test('保存子项后可通过 findTaskItemById 查到', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      final item = makeTaskItem(id: 'item-1', topicId: 'topic-1', title: '新子项');
      await sawait tore.saveTaskItem(item);

      final found = await sawait tore.findTaskItemById('item-1');
      expect(found, isNotNull);
      expect(found!.id, 'item-1');
      expect(found.title, '新子项');
      expect(found.topicId, 'topic-1');
    });

    test('按主题查询返回该主题下的子项', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.saveTopic(makeTopic(id: 'topic-2'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-1', topicId: 'topic-1'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-2', topicId: 'topic-1'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-3', topicId: 'topic-2'));

      final items1 = await sawait tore.findTaskItemsByTopic('topic-1');
      final items2 = await sawait tore.findTaskItemsByTopic('topic-2');

      expect(items1.length, 2);
      expect(items1.every((i) => i.topicId == 'topic-1'), isTrue);

      expect(items2.length, 1);
      expect(items2[0].id, 'item-3');
    });

    test('按 ID 查询子项', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-1', topicId: 'topic-1'));

      expect(await sawait tore.findTaskItemById('item-1'), isNotNull);
      expect(await sawait tore.findTaskItemById('nonexistent'), isNull);
    });

    test('findTaskItemById 不含已删除', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-1', topicId: 'topic-1', deleted: 1));

      expect(await sawait tore.findTaskItemById('item-1'), isNull);
      expect(await sawait tore.findTaskItemByIdIncludingDeleted('item-1'), isNotNull);
    });
  });

  // ====================================================================
  // group: updateTaskItemContent / updateTaskItemStatus / softDeleteTaskItem
  // ====================================================================
  group('updateTaskItemContent / updateTaskItemStatus / softDeleteTaskItem', () {
    test('更新子项内容', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-1', topicId: 'topic-1'));
      await sawait tore.updateTaskItemContent('item-1', title: '新标题', content: '新内容');

      final found = (await sawait tore.findTaskItemById('item-1'))!;
      expect(found.title, '新标题');
      expect(found.content, '新内容');
    });

    test('只更新子项 title', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.saveTaskItem(
        makeTaskItem(id: 'item-1', topicId: 'topic-1', content: '保留内容'),
      );
      await sawait tore.updateTaskItemContent('item-1', title: '新标题');

      final found = (await sawait tore.findTaskItemById('item-1'))!;
      expect(found.title, '新标题');
      expect(found.content, '保留内容');
    });

    test('只更新子项 content', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.saveTaskItem(
        makeTaskItem(id: 'item-1', topicId: 'topic-1', title: '保留标题'),
      );
      await sawait tore.updateTaskItemContent('item-1', content: '新内容');

      final found = (await sawait tore.findTaskItemById('item-1'))!;
      expect(found.title, '保留标题');
      expect(found.content, '新内容');
    });

    test('更新子项状态为 completed 时设置 completedAt', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-1', topicId: 'topic-1', status: 'pending'));
      await sawait tore.updateTaskItemStatus('item-1', 'completed');

      final found = (await sawait tore.findTaskItemById('item-1'))!;
      expect(found.status, 'completed');
      expect(found.completedAt, isNotNull);
    });

    test('更新子项状态为非 completed 时 completedAt 为 null', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.saveTaskItem(
        makeTaskItem(id: 'item-1', topicId: 'topic-1', status: 'completed')
            .copyWith(completedAt: () => DateTime.now()),
      );
      await sawait tore.updateTaskItemStatus('item-1', 'pending');

      final found = (await sawait tore.findTaskItemById('item-1'))!;
      expect(found.status, 'pending');
      expect(found.completedAt, isNull);
    });

    test('软删除子项', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      await sawait tore.saveTaskItem(makeTaskItem(id: 'item-1', topicId: 'topic-1'));
      await sawait tore.softDeleteTaskItem('item-1');

      expect(await sawait tore.findTaskItemById('item-1'), isNull);
      expect((await sawait tore.findTaskItemByIdIncludingDeleted('item-1'))!.deleted, 1);
    });
  });

  // ====================================================================
  // group: upsertTopicFromRemote / upsertTaskItemFromRemote
  // ====================================================================
  group('upsertTopicFromRemote', () {
    test('本地不存在 → INSERT，返回 true', () async {
      final remote = makeTopic(id: 'remote-1', title: '远程主题');
      final result = await sawait tore.upsertTopicFromRemote(remote);

      expect(result, isTrue);
      final found = await sawait tore.findTopicById('remote-1');
      expect(found, isNotNull);
      expect(found!.title, '远程主题');
    });

    test('远程更新 → UPDATE，返回 true', () async {
      final now = DateTime(2024, 1, 1);
      final local = makeTopic(id: 'topic-1', title: '本地标题', createTime: now, updateTime: now);
      await sawait tore.saveTopic(local);

      final remote = local.copyWith(
        title: '远程标题',
        updateTime: DateTime(2024, 6, 1),
      );
      final result = await sawait tore.upsertTopicFromRemote(remote);

      expect(result, isTrue);
      final found = (await sawait tore.findTopicById('topic-1'))!;
      expect(found.title, '远程标题');
    });

    test('远程更旧 → 不更新，返回 false', () async {
      final now = DateTime(2024, 1, 1);
      final local = makeTopic(
        id: 'topic-1',
        title: '本地标题',
        createTime: now,
        updateTime: DateTime(2024, 6, 1),
      );
      await sawait tore.saveTopic(local);

      final remote = local.copyWith(
        title: '远程标题',
        updateTime: DateTime(2024, 1, 1),
      );
      final result = await sawait tore.upsertTopicFromRemote(remote);

      expect(result, isFalse);
      final found = (await sawait tore.findTopicById('topic-1'))!;
      expect(found.title, '本地标题');
    });

    test('软删除合并：远程删除本地未删除 → 合并为已删除', () async {
      final now = DateTime(2024, 1, 1);
      final local = makeTopic(id: 'topic-1', deleted: 0, createTime: now, updateTime: now);
      await sawait tore.saveTopic(local);

      final remote = local.copyWith(
        deleted: 1,
        updateTime: DateTime(2024, 6, 1),
      );
      final result = await sawait tore.upsertTopicFromRemote(remote);

      expect(result, isTrue);
      expect((await sawait tore.findTopicByIdIncludingDeleted('topic-1'))!.deleted, 1);
    });

    test('软删除合并：本地删除远程未删除 → 保留已删除', () async {
      final now = DateTime(2024, 1, 1);
      final local = makeTopic(id: 'topic-1', deleted: 1, createTime: now, updateTime: DateTime(2024, 6, 1));
      await sawait tore.saveTopic(local);

      final remote = local.copyWith(
        deleted: 0,
        updateTime: DateTime(2024, 3, 1),
      );
      final result = await sawait tore.upsertTopicFromRemote(remote);

      // 远程更旧不更新数据，但本地已删除，远程未删除 → mergedDeleted=1 != existing.deleted=1 → 不需要更新
      expect(result, isFalse);
      expect((await sawait tore.findTopicByIdIncludingDeleted('topic-1'))!.deleted, 1);
    });
  });

  group('upsertTaskItemFromRemote', () {
    test('本地不存在 → INSERT，返回 true', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      final remote = makeTaskItem(id: 'remote-1', topicId: 'topic-1', title: '远程子项');
      final result = await sawait tore.upsertTaskItemFromRemote(remote);

      expect(result, isTrue);
      expect((await sawait tore.findTaskItemById('remote-1'))!.title, '远程子项');
    });

    test('远程更新 → UPDATE，返回 true', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      final now = DateTime(2024, 1, 1);
      final local = makeTaskItem(id: 'item-1', topicId: 'topic-1', title: '本地标题', createTime: now, updateTime: now);
      await sawait tore.saveTaskItem(local);

      final remote = local.copyWith(
        title: '远程标题',
        updateTime: DateTime(2024, 6, 1),
      );
      final result = await sawait tore.upsertTaskItemFromRemote(remote);

      expect(result, isTrue);
      expect((await sawait tore.findTaskItemById('item-1'))!.title, '远程标题');
    });

    test('远程更旧 → 不更新，返回 false', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      final now = DateTime(2024, 1, 1);
      final local = makeTaskItem(id: 'item-1', topicId: 'topic-1', title: '本地标题', createTime: now, updateTime: DateTime(2024, 6, 1));
      await sawait tore.saveTaskItem(local);

      final remote = local.copyWith(
        title: '远程标题',
        updateTime: DateTime(2024, 1, 1),
      );
      final result = await sawait tore.upsertTaskItemFromRemote(remote);

      expect(result, isFalse);
      expect((await sawait tore.findTaskItemById('item-1'))!.title, '本地标题');
    });

    test('软删除合并：远程删除本地未删除 → 合并为已删除', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      final now = DateTime(2024, 1, 1);
      final local = makeTaskItem(id: 'item-1', topicId: 'topic-1', deleted: 0, createTime: now, updateTime: now);
      await sawait tore.saveTaskItem(local);

      final remote = local.copyWith(
        deleted: 1,
        updateTime: DateTime(2024, 6, 1),
      );
      final result = await sawait tore.upsertTaskItemFromRemote(remote);

      expect(result, isTrue);
      expect((await sawait tore.findTaskItemByIdIncludingDeleted('item-1'))!.deleted, 1);
    });

    test('软删除合并：本地删除远程未删除 → 保留已删除', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      final now = DateTime(2024, 1, 1);
      final local = makeTaskItem(id: 'item-1', topicId: 'topic-1', deleted: 1, createTime: now, updateTime: DateTime(2024, 6, 1));
      await sawait tore.saveTaskItem(local);

      final remote = local.copyWith(
        deleted: 0,
        updateTime: DateTime(2024, 3, 1),
      );
      final result = await sawait tore.upsertTaskItemFromRemote(remote);

      // 远程更旧不更新数据，但本地已删除，远程未删除 → mergedDeleted=1 == existing.deleted=1 → 无需更新
      expect(result, isFalse);
      expect((await sawait tore.findTaskItemByIdIncludingDeleted('item-1'))!.deleted, 1);
    });
  });

  group('upsertAllTopicsFromRemote / upsertAllTaskItemsFromRemote', () {
    test('upsertAllTopicsFromRemote 返回有变化的条数', () async {
      final now = DateTime(2024, 1, 1);
      // 已存在的，远程更新
      final existing = makeTopic(id: 't-1', title: '旧', createTime: now, updateTime: now);
      await sawait tore.saveTopic(existing);

      final remotes = [
        existing.copyWith(title: '新', updateTime: DateTime(2024, 6, 1)), // 更新
        makeTopic(id: 't-2', title: '新增'), // 新增
        makeTopic(id: 't-3', title: '未变', createTime: now, updateTime: now), // 新增
      ];

      final changed = await sawait tore.upsertAllTopicsFromRemote(remotes);
      expect(changed, 3);
      expect((await sawait tore.findTopicById('t-1'))!.title, '新');
      expect(await sawait tore.findTopicById('t-2'), isNotNull);
      expect(await sawait tore.findTopicById('t-3'), isNotNull);
    });

    test('upsertAllTaskItemsFromRemote 返回有变化的条数', () async {
      await sawait tore.saveTopic(makeTopic(id: 'topic-1'));
      final now = DateTime(2024, 1, 1);
      final existing = makeTaskItem(id: 'i-1', topicId: 'topic-1', title: '旧', createTime: now, updateTime: now);
      await sawait tore.saveTaskItem(existing);

      final remotes = [
        existing.copyWith(title: '新', updateTime: DateTime(2024, 6, 1)),
        makeTaskItem(id: 'i-2', topicId: 'topic-1', title: '新增'),
      ];

      final changed = await sawait tore.upsertAllTaskItemsFromRemote(remotes);
      expect(changed, 2);
    });
  });

  // ====================================================================
  // group: countTopicsByStatus
  // ====================================================================
  group('countTopicsByStatus', () {
    test('各状态计数正确', () async {
      await sawait tore.saveTopic(makeTopic(id: 't-p1', status: 'pending'));
      await sawait tore.saveTopic(makeTopic(id: 't-p2', status: 'pending'));
      await sawait tore.saveTopic(makeTopic(id: 't-i1', status: 'in_progress'));
      await sawait tore.saveTopic(makeTopic(id: 't-c1', status: 'completed'));
      await sawait tore.saveTopic(makeTopic(id: 't-c2', status: 'completed'));
      await sawait tore.saveTopic(makeTopic(id: 't-c3', status: 'completed'));

      final counts = await sawait tore.countTopicsByStatus('emp-001');
      expect(counts['pending'], 2);
      expect(counts['in_progress'], 1);
      expect(counts['completed'], 3);
    });

    test('不含已删除的主题', () async {
      await sawait tore.saveTopic(makeTopic(id: 't-p1', status: 'pending'));
      await sawait tore.saveTopic(makeTopic(id: 't-p2', status: 'pending', deleted: 1));
      await sawait tore.saveTopic(makeTopic(id: 't-i1', status: 'in_progress', deleted: 1));

      final counts = await sawait tore.countTopicsByStatus('emp-001');
      expect(counts['pending'], 1);
      expect(counts['in_progress'], 0);
      expect(counts['completed'], 0);
    });

    test('无主题时各状态计数为 0', () async {
      final counts = await sawait tore.countTopicsByStatus('emp-001');
      expect(counts['pending'], 0);
      expect(counts['in_progress'], 0);
      expect(counts['completed'], 0);
    });
  });
}
