import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/todo_task_item_entity.dart';
import 'package:wenzagent/src/persistence/entities/todo_topic_entity.dart';
import 'package:wenzagent/src/persistence/stores/todo_store.dart';

int _testCounter = 0;

/// TodoStore 远程同步 merge 逻辑测试
///
/// 验证：
/// - upsertTopicFromRemote 合并策略（4 种场景）
/// - upsertTaskItemFromRemote 合并策略（4 种场景）
/// - upsertAllTopicsFromRemote / upsertAllTaskItemsFromRemote 批量 merge
/// - 双方都软删除时的合并行为
/// - reorderTopics / reorderTaskItems
Future<void> main() async {
  late String testDbPath;
  late String deviceId;
  late TodoStore store;
  const employeeId = 'emp-merge-test';

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_todo_merge_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    store = TodoStore(deviceId: deviceId);
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

  TodoTopicEntity createTopic({
    String? id,
    String? empId,
    String title = '测试主题',
    String description = '测试描述',
    String status = 'pending',
    int sortOrder = 0,
    int deleted = 0,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return TodoTopicEntity(
      id: id ?? const Uuid().v4(),
      employeeId: empId ?? employeeId,
      title: title,
      description: description,
      status: status,
      sortOrder: sortOrder,
      deleted: deleted,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  TodoTaskItemEntity createTaskItem({
    String? id,
    String? empId,
    required String topicId,
    String title = '测试子项',
    String content = '测试内容',
    String status = 'pending',
    int sortOrder = 0,
    int deleted = 0,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return TodoTaskItemEntity(
      id: id ?? const Uuid().v4(),
      employeeId: empId ?? employeeId,
      topicId: topicId,
      title: title,
      content: content,
      status: status,
      sortOrder: sortOrder,
      deleted: deleted,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  // ═══════════════════════════════════════════════════
  // 1. upsertTopicFromRemote 合并策略
  // ═══════════════════════════════════════════════════

  group('upsertTopicFromRemote 合并策略', () {
    test('本地不存在 → 直接插入', () async {
      final remote = createTopic(id: 'topic-new', title: '远程新主题');
      final changed = await sawait tore.upsertTopicFromRemote(remote);

      expect(changed, isTrue);
      final found = await sawait tore.findTopicById('topic-new');
      expect(found, isNotNull);
      expect(found!.title, equals('远程新主题'));
    });

    test('远程更新 → 本地更新（remote updateTime 更新）', () async {
      final local = createTopic(
        id: 'topic-merge',
        title: '本地标题',
        updateTime: DateTime(2025, 6, 1),
      );
      await sawait tore.saveTopic(local);

      final remote = createTopic(
        id: 'topic-merge',
        title: '远程标题',
        updateTime: DateTime(2025, 6, 2),
      );
      final changed = await sawait tore.upsertTopicFromRemote(remote);

      expect(changed, isTrue);
      final found = await sawait tore.findTopicById('topic-merge');
      expect(found!.title, equals('远程标题'));
    });

    test('本地更新 → 不覆盖（local updateTime 更新）', () async {
      final local = createTopic(
        id: 'topic-local-newer',
        title: '本地标题',
        updateTime: DateTime(2025, 6, 3),
      );
      await sawait tore.saveTopic(local);

      final remote = createTopic(
        id: 'topic-local-newer',
        title: '远程标题',
        updateTime: DateTime(2025, 6, 2),
      );
      final changed = await sawait tore.upsertTopicFromRemote(remote);

      expect(changed, isFalse);
      final found = await sawait tore.findTopicById('topic-local-newer');
      expect(found!.title, equals('本地标题'));
    });

    test('时间相同 → 不覆盖', () async {
      final time = DateTime(2025, 6, 1, 12, 0, 0);
      final local = createTopic(
        id: 'topic-same-time',
        title: '本地标题',
        updateTime: time,
      );
      await sawait tore.saveTopic(local);

      final remote = createTopic(
        id: 'topic-same-time',
        title: '远程标题',
        updateTime: time,
      );
      final changed = await sawait tore.upsertTopicFromRemote(remote);

      expect(changed, isFalse);
    });

    test('软删除合并：远程已删除 → 本地也标记删除', () async {
      final local = createTopic(
        id: 'topic-remote-del',
        title: '本地标题',
        updateTime: DateTime(2025, 6, 1),
      );
      await sawait tore.saveTopic(local);

      final remote = createTopic(
        id: 'topic-remote-del',
        title: '远程标题',
        deleted: 1,
        updateTime: DateTime(2025, 6, 1),
      );
      final changed = await sawait tore.upsertTopicFromRemote(remote);

      expect(changed, isTrue);
      expect(await sawait tore.findTopicById('topic-remote-del'), isNull);
      expect((await sawait tore.findTopicByIdIncludingDeleted('topic-remote-del'))!.deleted,
          equals(1));
    });

    test('软删除合并：本地已删除 → 远程未删除也保留删除', () async {
      final local = createTopic(
        id: 'topic-local-del',
        deleted: 1,
        updateTime: DateTime(2025, 6, 1),
      );
      await sawait tore.saveTopic(local);

      final remote = createTopic(
        id: 'topic-local-del',
        deleted: 0,
        updateTime: DateTime(2025, 6, 1),
      );
      final changed = await sawait tore.upsertTopicFromRemote(remote);

      // mergedDeleted=1 == existing.deleted=1 → shouldUpdateDelete=false
      // remote updateTime 不比 local 新 → shouldUpdateData=false
      expect(changed, isFalse);
      expect((await sawait tore.findTopicByIdIncludingDeleted('topic-local-del'))!.deleted,
          equals(1));
    });

    test('双方都已删除 → 远程更新时间更新时合并', () async {
      final local = createTopic(
        id: 'topic-both-del',
        deleted: 1,
        updateTime: DateTime(2025, 6, 1),
      );
      await sawait tore.saveTopic(local);

      final remote = createTopic(
        id: 'topic-both-del',
        deleted: 1,
        title: '远程标题',
        updateTime: DateTime(2025, 6, 2),
      );
      final changed = await sawait tore.upsertTopicFromRemote(remote);

      expect(changed, isTrue);
      final found = await sawait tore.findTopicByIdIncludingDeleted('topic-both-del');
      expect(found!.deleted, equals(1));
      expect(found.title, equals('远程标题'));
    });

    test('双方都已删除且时间相同 → 不变', () async {
      final time = DateTime(2025, 6, 1);
      final local = createTopic(
        id: 'topic-both-del-same',
        deleted: 1,
        updateTime: time,
      );
      await sawait tore.saveTopic(local);

      final remote = createTopic(
        id: 'topic-both-del-same',
        deleted: 1,
        updateTime: time,
      );
      final changed = await sawait tore.upsertTopicFromRemote(remote);

      expect(changed, isFalse);
    });

    test('远程更新且远程已删除 → 合并数据和删除标记', () async {
      final local = createTopic(
        id: 'topic-update-del',
        title: '本地标题',
        updateTime: DateTime(2025, 6, 1),
      );
      await sawait tore.saveTopic(local);

      final remote = createTopic(
        id: 'topic-update-del',
        title: '远程已删除',
        deleted: 1,
        updateTime: DateTime(2025, 6, 2),
      );
      final changed = await sawait tore.upsertTopicFromRemote(remote);

      expect(changed, isTrue);
      final found = await sawait tore.findTopicByIdIncludingDeleted('topic-update-del');
      expect(found!.deleted, equals(1));
      expect(found.title, equals('远程已删除'));
    });
  });

  // ═══════════════════════════════════════════════════
  // 2. upsertTaskItemFromRemote 合并策略
  // ═══════════════════════════════════════════════════

  group('upsertTaskItemFromRemote 合并策略', () {
    test('本地不存在 → 直接插入', () async {
      final remote =
          createTaskItem(id: 'item-new', topicId: 'topic-x', title: '远程新项');
      final changed = await sawait tore.upsertTaskItemFromRemote(remote);

      expect(changed, isTrue);
      final found = await sawait tore.findTaskItemById('item-new');
      expect(found, isNotNull);
      expect(found!.title, equals('远程新项'));
    });

    test('远程更新 → 本地更新', () async {
      final local = createTaskItem(
        id: 'item-merge',
        topicId: 'topic-x',
        title: '本地标题',
        updateTime: DateTime(2025, 6, 1),
      );
      await sawait tore.saveTaskItem(local);

      final remote = createTaskItem(
        id: 'item-merge',
        topicId: 'topic-x',
        title: '远程标题',
        updateTime: DateTime(2025, 6, 2),
      );
      final changed = await sawait tore.upsertTaskItemFromRemote(remote);

      expect(changed, isTrue);
      expect((await sawait tore.findTaskItemById('item-merge'))!.title, equals('远程标题'));
    });

    test('本地更新 → 不覆盖', () async {
      final local = createTaskItem(
        id: 'item-local-newer',
        topicId: 'topic-x',
        title: '本地标题',
        updateTime: DateTime(2025, 6, 3),
      );
      await sawait tore.saveTaskItem(local);

      final remote = createTaskItem(
        id: 'item-local-newer',
        topicId: 'topic-x',
        title: '远程标题',
        updateTime: DateTime(2025, 6, 2),
      );
      final changed = await sawait tore.upsertTaskItemFromRemote(remote);

      expect(changed, isFalse);
      expect(
          (await sawait tore.findTaskItemById('item-local-newer'))!.title, equals('本地标题'));
    });

    test('软删除合并：远程已删除 → 本地也标记删除', () async {
      final local = createTaskItem(
        id: 'item-remote-del',
        topicId: 'topic-x',
        updateTime: DateTime(2025, 6, 1),
      );
      await sawait tore.saveTaskItem(local);

      final remote = createTaskItem(
        id: 'item-remote-del',
        topicId: 'topic-x',
        deleted: 1,
        updateTime: DateTime(2025, 6, 1),
      );
      final changed = await sawait tore.upsertTaskItemFromRemote(remote);

      expect(changed, isTrue);
      expect(await sawait tore.findTaskItemById('item-remote-del'), isNull);
      expect(
          (await sawait tore.findTaskItemByIdIncludingDeleted('item-remote-del'))!.deleted,
          equals(1));
    });

    test('软删除合并：本地已删除 → 远程未删除也保留删除', () async {
      final local = createTaskItem(
        id: 'item-local-del',
        topicId: 'topic-x',
        deleted: 1,
        updateTime: DateTime(2025, 6, 1),
      );
      await sawait tore.saveTaskItem(local);

      final remote = createTaskItem(
        id: 'item-local-del',
        topicId: 'topic-x',
        deleted: 0,
        updateTime: DateTime(2025, 6, 1),
      );
      final changed = await sawait tore.upsertTaskItemFromRemote(remote);

      expect(changed, isFalse);
    });

    test('双方都已删除 → 远程更新时间更新时合并', () async {
      final local = createTaskItem(
        id: 'item-both-del',
        topicId: 'topic-x',
        deleted: 1,
        updateTime: DateTime(2025, 6, 1),
      );
      await sawait tore.saveTaskItem(local);

      final remote = createTaskItem(
        id: 'item-both-del',
        topicId: 'topic-x',
        deleted: 1,
        title: '远程标题',
        updateTime: DateTime(2025, 6, 2),
      );
      final changed = await sawait tore.upsertTaskItemFromRemote(remote);

      expect(changed, isTrue);
      final found = await sawait tore.findTaskItemByIdIncludingDeleted('item-both-del');
      expect(found!.deleted, equals(1));
      expect(found.title, equals('远程标题'));
    });
  });

  // ═══════════════════════════════════════════════════
  // 3. 批量 merge
  // ═══════════════════════════════════════════════════

  group('批量 merge', () {
    test('upsertAllTopicsFromRemote 返回变化数量', () async {
      final items = [
        createTopic(id: 'batch-t1', title: '新主题1'),
        createTopic(id: 'batch-t2', title: '新主题2'),
        createTopic(id: 'batch-t3', title: '新主题3'),
      ];

      final changed = await sawait tore.upsertAllTopicsFromRemote(items);
      expect(changed, equals(3));
    });

    test('upsertAllTopicsFromRemote 混合新旧数据', () async {
      await sawait tore.saveTopic(createTopic(
        id: 'batch-t-old',
        title: '旧标题',
        updateTime: DateTime(2025, 6, 1),
      ));

      final items = [
        createTopic(
          id: 'batch-t-old',
          title: '新标题',
          updateTime: DateTime(2025, 6, 2),
        ),
        createTopic(id: 'batch-t-new', title: '全新主题'),
      ];

      final changed = await sawait tore.upsertAllTopicsFromRemote(items);
      expect(changed, equals(2));
      expect((await sawait tore.findTopicById('batch-t-old'))!.title, equals('新标题'));
    });

    test('upsertAllTaskItemsFromRemote 返回变化数量', () async {
      final items = [
        createTaskItem(id: 'batch-i1', topicId: 't1', title: '新项1'),
        createTaskItem(id: 'batch-i2', topicId: 't1', title: '新项2'),
      ];

      final changed = await sawait tore.upsertAllTaskItemsFromRemote(items);
      expect(changed, equals(2));
    });

    test('upsertAllTaskItemsFromRemote 混合新旧数据', () async {
      await sawait tore.saveTaskItem(createTaskItem(
        id: 'batch-i-old',
        topicId: 't1',
        title: '旧标题',
        updateTime: DateTime(2025, 6, 1),
      ));

      final items = [
        createTaskItem(
          id: 'batch-i-old',
          topicId: 't1',
          title: '新标题',
          updateTime: DateTime(2025, 6, 2),
        ),
        createTaskItem(id: 'batch-i-new', topicId: 't1', title: '全新项'),
      ];

      final changed = await sawait tore.upsertAllTaskItemsFromRemote(items);
      expect(changed, equals(2));
      expect((await sawait tore.findTaskItemById('batch-i-old'))!.title, equals('新标题'));
    });

    test('批量 merge 无变化时返回 0', () async {
      final time = DateTime(2025, 6, 1);
      await sawait tore.saveTopic(createTopic(
        id: 'batch-noop',
        title: '标题',
        updateTime: time,
      ));

      final items = [
        createTopic(
          id: 'batch-noop',
          title: '标题',
          updateTime: time,
        ),
      ];

      final changed = await sawait tore.upsertAllTopicsFromRemote(items);
      expect(changed, equals(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // 4. reorderTopics / reorderTaskItems
  // ═══════════════════════════════════════════════════

  group('reorder', () {
    test('reorderTopics 更新排序序号', () async {
      await sawait tore.saveTopic(createTopic(id: 'rt-a', sortOrder: 0));
      await sawait tore.saveTopic(createTopic(id: 'rt-b', sortOrder: 1));
      await sawait tore.saveTopic(createTopic(id: 'rt-c', sortOrder: 2));

      await sawait tore.reorderTopics(['rt-c', 'rt-b', 'rt-a']);

      final all = await sawait tore.findAllTopics(employeeId);
      final orderMap = {for (var t in all) t.id: t.sortOrder};
      expect(orderMap['rt-c'], equals(0));
      expect(orderMap['rt-b'], equals(1));
      expect(orderMap['rt-a'], equals(2));
    });

    test('reorderTaskItems 更新排序序号', () async {
      await sawait tore.saveTaskItem(
          createTaskItem(id: 'ri-a', topicId: 't', sortOrder: 0));
      await sawait tore.saveTaskItem(
          createTaskItem(id: 'ri-b', topicId: 't', sortOrder: 1));

      await sawait tore.reorderTaskItems(['ri-b', 'ri-a']);

      final items = await sawait tore.findTaskItemsByTopic('t');
      final orderMap = {for (var i in items) i.id: i.sortOrder};
      expect(orderMap['ri-b'], equals(0));
      expect(orderMap['ri-a'], equals(1));
    });
  });

  // ═══════════════════════════════════════════════════
  // 5. 综合场景：Topic + TaskItem 联动 merge
  // ═══════════════════════════════════════════════════

  group('综合场景', () {
    test('Topic merge 后关联 TaskItem 仍可查询', () async {
      // 1. 本地创建 topic + taskItem
      await sawait tore.saveTopic(createTopic(
        id: 'comp-topic',
        title: '本地主题',
        updateTime: DateTime(2025, 6, 1),
      ));
      await sawait tore.saveTaskItem(createTaskItem(
        id: 'comp-item',
        topicId: 'comp-topic',
        title: '本地子项',
      ));

      // 2. 远程更新 topic
      final remoteTopic = createTopic(
        id: 'comp-topic',
        title: '远程主题',
        updateTime: DateTime(2025, 6, 2),
      );
      await sawait tore.upsertTopicFromRemote(remoteTopic);

      // 3. topic 标题已更新
      expect((await sawait tore.findTopicById('comp-topic'))!.title, equals('远程主题'));

      // 4. taskItem 仍可查询
      expect(await sawait tore.findTaskItemById('comp-item'), isNotNull);
      expect((await sawait tore.findTaskItemById('comp-item'))!.topicId, equals('comp-topic'));
    });

    test('软删除 Topic 后远程 TaskItem merge 保留删除标记', () async {
      // 使用明确的时间戳避免 softDeleteTaskItem 内部 DateTime.now() 干扰
      final baseTime = DateTime(2025, 1, 1, 0, 0, 0);
      final remoteTime = DateTime(2030, 1, 1, 0, 0, 0); // 远大于 now()

      await sawait tore.saveTopic(createTopic(
        id: 'del-topic',
        updateTime: baseTime,
      ));
      await sawait tore.saveTaskItem(createTaskItem(
        id: 'del-item',
        topicId: 'del-topic',
        updateTime: baseTime,
      ));

      // 手动设置软删除
      await sawait tore.softDeleteTaskItem('del-item');
      expect(await sawait tore.findTaskItemById('del-item'), isNull);

      // 确认本地 item 的 deleted=1
      final localItem = await sawait tore.findTaskItemByIdIncludingDeleted('del-item');
      expect(localItem!.deleted, equals(1));

      // 远程 taskItem merge 进来（远程未删除，时间戳远大于本地）
      final remoteItem = createTaskItem(
        id: 'del-item',
        topicId: 'del-topic',
        title: '远程版本',
        deleted: 0,
        updateTime: remoteTime, // 远大于 softDelete 的时间
      );
      final changed = await sawait tore.upsertTaskItemFromRemote(remoteItem);

      // 远程 updateTime 远大于本地 → shouldUpdateData=true
      // 合并策略：本地 deleted=1 + 远程 deleted=0 → mergedDeleted=1
      // shouldUpdateDelete = (1 != 1) = false
      // shouldUpdateData = true → changed = true
      expect(changed, isTrue);
      final found = await sawait tore.findTaskItemByIdIncludingDeleted('del-item');
      expect(found, isNotNull);
      expect(found!.deleted, equals(1)); // 删除标记保留
      expect(found.title, equals('远程版本')); // 数据已更新
    });
  });
}
