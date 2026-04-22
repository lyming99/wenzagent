import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/todo_task_item_entity.dart';
import 'package:wenzagent/src/persistence/entities/todo_topic_entity.dart';
import 'package:wenzagent/src/persistence/stores/todo_store.dart';

int _testCounter = 0;

/// TodoStore 测试
///
/// 验证：
/// - TodoTopic CRUD（保存、查询、更新、按状态过滤、统计）
/// - TodoTopic 删除（软删除、批量硬删除已完成主题）
/// - TodoTaskItem CRUD（保存、查询、更新内容和状态）
/// - TodoTaskItem 软删除
/// - recalculateTopicStatus 状态推导逻辑
void main() {
  late String testDbPath;
  late String deviceId;
  late TodoStore store;
  const employeeId = 'emp-test-1';

  setUp(() async {
    _testCounter++;
    testDbPath = '${Directory.systemTemp.path}/wenzagent_todo_test_$_testCounter';
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
    DateTime? completedAt,
  }) {
    final now = DateTime.now();
    return TodoTopicEntity(
      id: id ?? const Uuid().v4(),
      employeeId: empId ?? employeeId,
      title: title,
      description: description,
      status: status,
      sortOrder: sortOrder,
      createTime: now,
      updateTime: now,
      completedAt: completedAt,
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
      createTime: now,
      updateTime: now,
    );
  }

  // ═══════════════════════════════════════════════════
  // 1. TodoTopic CRUD
  // ═══════════════════════════════════════════════════

  group('TodoTopic CRUD', () {
    test('保存主题 + 按 ID 查询，验证字段完整性（含 completed_at）', () {
      final completedAt = DateTime(2025, 6, 15, 10, 30, 0);
      final topic = createTopic(
        id: 'topic-1',
        title: '主题标题',
        description: '主题描述',
        status: 'completed',
        completedAt: completedAt,
      );

      store.saveTopic(topic);

      final found = store.findTopicById('topic-1');
      expect(found, isNotNull);
      expect(found!.id, equals('topic-1'));
      expect(found.employeeId, equals(employeeId));
      expect(found.title, equals('主题标题'));
      expect(found.description, equals('主题描述'));
      expect(found.status, equals('completed'));
      expect(found.completedAt, isNotNull);
      expect(found.completedAt!.millisecondsSinceEpoch,
          equals(completedAt.millisecondsSinceEpoch));
      expect(found.deleted, equals(0));
    });

    test('completed_at 为 null 时查询返回 null', () {
      final topic = createTopic(id: 'topic-null-completed');
      store.saveTopic(topic);

      final found = store.findTopicById('topic-null-completed');
      expect(found, isNotNull);
      expect(found!.completedAt, isNull);
    });

    test('updateTopicContent 仅更新 title', () {
      final topic = createTopic(id: 'topic-update-title', title: '原标题');
      store.saveTopic(topic);

      store.updateTopicContent('topic-update-title', title: '新标题');

      final found = store.findTopicById('topic-update-title');
      expect(found, isNotNull);
      expect(found!.title, equals('新标题'));
      expect(found.description, equals('测试描述'));
    });

    test('updateTopicContent 仅更新 description', () {
      final topic = createTopic(id: 'topic-update-desc');
      store.saveTopic(topic);

      store.updateTopicContent('topic-update-desc', description: '新描述');

      final found = store.findTopicById('topic-update-desc');
      expect(found, isNotNull);
      expect(found!.title, equals('测试主题'));
      expect(found.description, equals('新描述'));
    });

    test('updateTopicContent 同时更新 title 和 description', () {
      final topic = createTopic(id: 'topic-update-both');
      store.saveTopic(topic);

      store.updateTopicContent(
        'topic-update-both',
        title: '双改标题',
        description: '双改描述',
      );

      final found = store.findTopicById('topic-update-both');
      expect(found, isNotNull);
      expect(found!.title, equals('双改标题'));
      expect(found.description, equals('双改描述'));
    });

    test('findAllTopics 返回所有未删除主题', () {
      store.saveTopic(createTopic(id: 't1', status: 'pending'));
      store.saveTopic(createTopic(id: 't2', status: 'in_progress'));
      store.saveTopic(createTopic(id: 't3', status: 'completed'));

      final all = store.findAllTopics(employeeId);
      expect(all.length, equals(3));
    });

    test('findPendingTopics 返回 pending 主题（不含 in_progress）', () {
      store.saveTopic(createTopic(id: 't-pending', status: 'pending'));
      store.saveTopic(createTopic(id: 't-inprog', status: 'in_progress'));
      store.saveTopic(createTopic(id: 't-completed', status: 'completed'));

      final pending = store.findPendingTopics(employeeId);
      expect(pending.length, equals(1));
      expect(pending.first.status, equals('pending'));
    });

    test('findCurrentTopics 返回 in_progress 主题', () {
      store.saveTopic(createTopic(id: 't-pending', status: 'pending'));
      store.saveTopic(createTopic(id: 't-inprog', status: 'in_progress'));
      store.saveTopic(createTopic(id: 't-completed', status: 'completed'));

      final current = store.findCurrentTopics(employeeId);
      expect(current.length, equals(1));
      expect(current.first.status, equals('in_progress'));
    });

    test('findCompletedTopics 返回 completed 主题', () {
      store.saveTopic(createTopic(id: 't-pending', status: 'pending'));
      store.saveTopic(
        createTopic(
          id: 't-done1',
          status: 'completed',
          completedAt: DateTime(2025, 6, 15),
        ),
      );
      store.saveTopic(
        createTopic(
          id: 't-done2',
          status: 'completed',
          completedAt: DateTime(2025, 6, 16),
        ),
      );

      final completed = store.findCompletedTopics(employeeId);
      expect(completed.length, equals(2));
      // 按 completed_at DESC 排序
      expect(completed.first.id, equals('t-done2'));
    });

    test('findCompletedTopics 支持 limit 参数', () {
      for (var i = 0; i < 5; i++) {
        store.saveTopic(
          createTopic(
            id: 't-done-$i',
            status: 'completed',
            completedAt: DateTime(2025, 6, 10 + i),
          ),
        );
      }

      final completed = store.findCompletedTopics(employeeId, limit: 2);
      expect(completed.length, equals(2));
    });

    test('countTopicsByStatus 按状态统计', () {
      store.saveTopic(createTopic(id: 't1', status: 'pending'));
      store.saveTopic(createTopic(id: 't2', status: 'pending'));
      store.saveTopic(createTopic(id: 't3', status: 'in_progress'));
      store.saveTopic(createTopic(id: 't4', status: 'completed'));

      final counts = store.countTopicsByStatus(employeeId);
      expect(counts['pending'], equals(2));
      expect(counts['in_progress'], equals(1));
      expect(counts['completed'], equals(1));
    });

    test('countTopicsByStatus 无数据时返回全零', () {
      final counts = store.countTopicsByStatus(employeeId);
      expect(counts['pending'], equals(0));
      expect(counts['in_progress'], equals(0));
      expect(counts['completed'], equals(0));
    });

    test('findAllTopics 按 employeeId 过滤', () {
      store.saveTopic(createTopic(id: 't-emp1', empId: 'emp-A'));
      store.saveTopic(createTopic(id: 't-emp2', empId: 'emp-B'));

      final empATopics = store.findAllTopics('emp-A');
      expect(empATopics.length, equals(1));
      expect(empATopics.first.id, equals('t-emp1'));
    });
  });

  // ═══════════════════════════════════════════════════
  // 2. TodoTopic 删除
  // ═══════════════════════════════════════════════════

  group('TodoTopic 删除', () {
    test('softDeleteTopic 软删除主题及关联子项', () {
      final topic = createTopic(id: 'topic-soft-del');
      store.saveTopic(topic);

      store.saveTaskItem(createTaskItem(id: 'item-1', topicId: 'topic-soft-del'));
      store.saveTaskItem(createTaskItem(id: 'item-2', topicId: 'topic-soft-del'));

      store.softDeleteTopic('topic-soft-del');

      // 主题查询不到
      expect(store.findTopicById('topic-soft-del'), isNull);
      // 子项也查不到
      expect(store.findTaskItemById('item-1'), isNull);
      expect(store.findTaskItemById('item-2'), isNull);
      // 不影响其他主题
      final other = createTopic(id: 'topic-other');
      store.saveTopic(other);
      expect(store.findTopicById('topic-other'), isNotNull);
    });

    test('deleteCompletedTopics 批量硬删除已完成主题', () {
      store.saveTopic(
        createTopic(
          id: 'topic-done1',
          status: 'completed',
          completedAt: DateTime.now(),
        ),
      );
      store.saveTopic(
        createTopic(
          id: 'topic-done2',
          status: 'completed',
          completedAt: DateTime.now(),
        ),
      );
      store.saveTopic(createTopic(id: 'topic-pending', status: 'pending'));

      store.saveTaskItem(
        createTaskItem(id: 'item-done', topicId: 'topic-done1'),
      );

      store.deleteCompletedTopics(employeeId);

      // 已完成主题被硬删除
      expect(store.findTopicById('topic-done1'), isNull);
      expect(store.findTopicById('topic-done2'), isNull);
      // pending 主题不受影响
      expect(store.findTopicById('topic-pending'), isNotNull);
    });

    test('deleteCompletedTopics 按 employeeId 过滤', () {
      store.saveTopic(
        createTopic(
          id: 'topic-empA-done',
          empId: 'emp-A',
          status: 'completed',
          completedAt: DateTime.now(),
        ),
      );
      store.saveTopic(
        createTopic(
          id: 'topic-empB-done',
          empId: 'emp-B',
          status: 'completed',
          completedAt: DateTime.now(),
        ),
      );

      store.deleteCompletedTopics('emp-A');

      expect(store.findTopicById('topic-empA-done'), isNull);
      expect(store.findTopicById('topic-empB-done'), isNotNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // 3. TodoTaskItem CRUD
  // ═══════════════════════════════════════════════════

  group('TodoTaskItem CRUD', () {
    test('保存子项 + 按 ID 查询', () {
      final item = createTaskItem(
        id: 'item-1',
        topicId: 'topic-x',
        title: '子项标题',
        content: '子项内容',
      );

      store.saveTaskItem(item);

      final found = store.findTaskItemById('item-1');
      expect(found, isNotNull);
      expect(found!.id, equals('item-1'));
      expect(found.employeeId, equals(employeeId));
      expect(found.topicId, equals('topic-x'));
      expect(found.title, equals('子项标题'));
      expect(found.content, equals('子项内容'));
      expect(found.status, equals('pending'));
      expect(found.deleted, equals(0));
    });

    test('findTaskItemsByTopic 按 topic 查询', () {
      final topicId = 'topic-items';
      store.saveTaskItem(createTaskItem(id: 'i1', topicId: topicId, title: '子项1'));
      store.saveTaskItem(createTaskItem(id: 'i2', topicId: topicId, title: '子项2'));
      store.saveTaskItem(createTaskItem(id: 'i3', topicId: 'other-topic'));

      final items = store.findTaskItemsByTopic(topicId);
      expect(items.length, equals(2));
      final ids = items.map((i) => i.id).toSet();
      expect(ids, containsAll(['i1', 'i2']));
    });

    test('findTaskItemsByTopic 按 sortOrder 排序', () {
      final topicId = 'topic-sort';
      store.saveTaskItem(createTaskItem(id: 'i-last', topicId: topicId, sortOrder: 2));
      store.saveTaskItem(createTaskItem(id: 'i-first', topicId: topicId, sortOrder: 0));
      store.saveTaskItem(createTaskItem(id: 'i-mid', topicId: topicId, sortOrder: 1));

      final items = store.findTaskItemsByTopic(topicId);
      expect(items.map((i) => i.id).toList(), equals(['i-first', 'i-mid', 'i-last']));
    });

    test('updateTaskItemContent 仅更新 title', () {
      store.saveTaskItem(createTaskItem(id: 'item-ut', topicId: 't'));
      store.updateTaskItemContent('item-ut', title: '新标题');

      final found = store.findTaskItemById('item-ut');
      expect(found, isNotNull);
      expect(found!.title, equals('新标题'));
      expect(found.content, equals('测试内容'));
    });

    test('updateTaskItemContent 仅更新 content', () {
      store.saveTaskItem(createTaskItem(id: 'item-uc', topicId: 't'));
      store.updateTaskItemContent('item-uc', content: '新内容');

      final found = store.findTaskItemById('item-uc');
      expect(found, isNotNull);
      expect(found!.title, equals('测试子项'));
      expect(found.content, equals('新内容'));
    });

    test('updateTaskItemContent 同时更新 title 和 content', () {
      store.saveTaskItem(createTaskItem(id: 'item-ub', topicId: 't'));
      store.updateTaskItemContent('item-ub', title: '双改标题', content: '双改内容');

      final found = store.findTaskItemById('item-ub');
      expect(found, isNotNull);
      expect(found!.title, equals('双改标题'));
      expect(found.content, equals('双改内容'));
    });

    test('updateTaskItemStatus 更新状态为 completed 时设置 completedAt', () {
      store.saveTaskItem(createTaskItem(id: 'item-status', topicId: 't'));
      store.updateTaskItemStatus('item-status', 'completed');

      final found = store.findTaskItemById('item-status');
      expect(found, isNotNull);
      expect(found!.status, equals('completed'));
      expect(found.completedAt, isNotNull);
    });

    test('updateTaskItemStatus 更新状态为非 completed 时清空 completedAt', () {
      // 先设为 completed
      store.saveTaskItem(createTaskItem(id: 'item-uncomplete', topicId: 't'));
      store.updateTaskItemStatus('item-uncomplete', 'completed');
      expect(store.findTaskItemById('item-uncomplete')!.completedAt, isNotNull);

      // 再改回 pending
      store.updateTaskItemStatus('item-uncomplete', 'pending');
      final found = store.findTaskItemById('item-uncomplete');
      expect(found, isNotNull);
      expect(found!.status, equals('pending'));
      expect(found.completedAt, isNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // 4. TodoTaskItem 删除
  // ═══════════════════════════════════════════════════

  group('TodoTaskItem 删除', () {
    test('softDeleteTaskItem 软删除', () {
      store.saveTaskItem(createTaskItem(id: 'item-del', topicId: 't'));

      store.softDeleteTaskItem('item-del');

      expect(store.findTaskItemById('item-del'), isNull);
    });

    test('softDeleteTaskItem 不影响同主题其他子项', () {
      store.saveTaskItem(createTaskItem(id: 'item-del', topicId: 't'));
      store.saveTaskItem(createTaskItem(id: 'item-keep', topicId: 't'));

      store.softDeleteTaskItem('item-del');

      expect(store.findTaskItemById('item-del'), isNull);
      expect(store.findTaskItemById('item-keep'), isNotNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // 5. recalculateTopicStatus 状态推导
  // ═══════════════════════════════════════════════════

  group('recalculateTopicStatus', () {
    test('无子项 → pending', () {
      final topic = createTopic(id: 'topic-recalc-empty');
      store.saveTopic(topic);

      store.recalculateTopicStatus('topic-recalc-empty');

      final found = store.findTopicById('topic-recalc-empty');
      expect(found, isNotNull);
      expect(found!.status, equals('pending'));
      expect(found.completedAt, isNull);
    });

    test('有 in_progress 子项 → in_progress', () {
      final topic = createTopic(id: 'topic-recalc-inprog');
      store.saveTopic(topic);
      store.saveTaskItem(
        createTaskItem(id: 'item-inprog', topicId: 'topic-recalc-inprog', status: 'in_progress'),
      );

      store.recalculateTopicStatus('topic-recalc-inprog');

      final found = store.findTopicById('topic-recalc-inprog');
      expect(found, isNotNull);
      expect(found!.status, equals('in_progress'));
    });

    test('全部 completed → completed + 设置 completedAt', () {
      final topic = createTopic(id: 'topic-recalc-done');
      store.saveTopic(topic);
      store.saveTaskItem(
        createTaskItem(id: 'item-done1', topicId: 'topic-recalc-done', status: 'completed'),
      );
      store.saveTaskItem(
        createTaskItem(id: 'item-done2', topicId: 'topic-recalc-done', status: 'completed'),
      );

      store.recalculateTopicStatus('topic-recalc-done');

      final found = store.findTopicById('topic-recalc-done');
      expect(found, isNotNull);
      expect(found!.status, equals('completed'));
      expect(found.completedAt, isNotNull);
    });

    test('部分 pending → pending', () {
      final topic = createTopic(id: 'topic-recalc-partial');
      store.saveTopic(topic);
      store.saveTaskItem(
        createTaskItem(id: 'item-pending1', topicId: 'topic-recalc-partial', status: 'pending'),
      );
      store.saveTaskItem(
        createTaskItem(id: 'item-pending2', topicId: 'topic-recalc-partial', status: 'pending'),
      );

      store.recalculateTopicStatus('topic-recalc-partial');

      final found = store.findTopicById('topic-recalc-partial');
      expect(found, isNotNull);
      expect(found!.status, equals('pending'));
      expect(found.completedAt, isNull);
    });

    test('混合状态：in_progress + pending → in_progress', () {
      final topic = createTopic(id: 'topic-recalc-mix1');
      store.saveTopic(topic);
      store.saveTaskItem(
        createTaskItem(id: 'item-mix-inprog', topicId: 'topic-recalc-mix1', status: 'in_progress'),
      );
      store.saveTaskItem(
        createTaskItem(id: 'item-mix-pending', topicId: 'topic-recalc-mix1', status: 'pending'),
      );

      store.recalculateTopicStatus('topic-recalc-mix1');

      final found = store.findTopicById('topic-recalc-mix1');
      expect(found!.status, equals('in_progress'));
    });

    test('混合状态：completed + pending → pending', () {
      final topic = createTopic(id: 'topic-recalc-mix2');
      store.saveTopic(topic);
      store.saveTaskItem(
        createTaskItem(id: 'item-mix-done', topicId: 'topic-recalc-mix2', status: 'completed'),
      );
      store.saveTaskItem(
        createTaskItem(id: 'item-mix-pend', topicId: 'topic-recalc-mix2', status: 'pending'),
      );

      store.recalculateTopicStatus('topic-recalc-mix2');

      final found = store.findTopicById('topic-recalc-mix2');
      expect(found!.status, equals('pending'));
    });

    test('软删除的子项不计入状态推导', () {
      final topic = createTopic(id: 'topic-recalc-softdel');
      store.saveTopic(topic);
      store.saveTaskItem(
        createTaskItem(id: 'item-softdel', topicId: 'topic-recalc-softdel', status: 'completed'),
      );

      // 先确认有子项时为 completed
      store.recalculateTopicStatus('topic-recalc-softdel');
      expect(store.findTopicById('topic-recalc-softdel')!.status, equals('completed'));

      // 软删除子项
      store.softDeleteTaskItem('item-softdel');

      // 重新推导 → 无有效子项 → pending
      store.recalculateTopicStatus('topic-recalc-softdel');
      final found = store.findTopicById('topic-recalc-softdel');
      expect(found!.status, equals('pending'));
      expect(found.completedAt, isNull);
    });
  });
}
