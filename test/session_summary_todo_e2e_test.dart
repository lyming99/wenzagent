import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/session_summary_entity.dart';
import 'package:wenzagent/src/persistence/entities/todo_task_item_entity.dart';
import 'package:wenzagent/src/persistence/entities/todo_topic_entity.dart';
import 'package:wenzagent/src/persistence/stores/session_summary_store.dart';
import 'package:wenzagent/src/persistence/stores/todo_store.dart';

int _testCounter = 0;

/// 会话列表状态同步(Session Summary) 端到端测试
///
/// 场景：先创建 todo，再执行（模拟 Agent 工作流中 todo_manage → 执行 → 消息产出 → session summary 更新）
///
/// 同步路径1：event（LAN 广播 + event）> update store
///   - Device A 创建 todo topic + task items
///   - Device A 执行 todo（更新 task item 状态）
///   - 执行过程中产生 assistant 消息 → 更新 session summary
///   - 广播 session summary 到 Device B → Device B upsertFromRemote
///
/// 同步路径2：query > update store
///   - Device B 上线后主动查询 Device A 的 session summaries
///   - Device B 将查询结果 upsertFromRemote 到本地 store
///
/// primary key: employeeId + deviceId
Future<void> main() async {
  late String testDbPathA;
  late String testDbPathB;
  late String deviceA;
  late String deviceB;
  late SessionSummaryStore summaryStoreA;
  late SessionSummaryStore summaryStoreB;
  late TodoStore todoStoreA;
  late TodoStore todoStoreB;

  const employeeId = 'emp-agent-001';

  setUp(() async {
    _testCounter++;
    final base =
        '${Directory.systemTemp.path}/wenzagent_summary_todo_e2e_$_testCounter';

    testDbPathA = '$base/device_a';
    testDbPathB = '$base/device_b';
    await Directory(testDbPathA).create(recursive: true);
    await Directory(testDbPathB).create(recursive: true);

    deviceA = 'dev-a-${const Uuid().v4().substring(0, 8)}';
    deviceB = 'dev-b-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceA).initialize(
      storagePath: testDbPathA,
    );
    await DatabaseManager.getInstance(deviceB).initialize(
      storagePath: testDbPathB,
    );

    summaryStoreA = SessionSummaryStore(deviceId: deviceA);
    summaryStoreB = SessionSummaryStore(deviceId: deviceB);
    todoStoreA = TodoStore(deviceId: deviceA);
    todoStoreB = TodoStore(deviceId: deviceB);

    await summaryStoreA.ensureTable();
    await summaryStoreB.ensureTable();
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceA).close();
    await DatabaseManager.getInstance(deviceB).close();
    DatabaseManager.removeInstance(deviceA);
    DatabaseManager.removeInstance(deviceB);
    try {
      await Directory(testDbPathA).delete(recursive: true);
      await Directory(testDbPathB).delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════
  // 辅助方法
  // ═══════════════════════════════════════════════════

  /// 创建 todo topic
  TodoTopicEntity createTopic({
    String? id,
    String title = '测试主题',
    String description = '测试描述',
    String status = 'pending',
  }) {
    final now = DateTime.now();
    return TodoTopicEntity(
      id: id ?? const Uuid().v4(),
      employeeId: employeeId,
      title: title,
      description: description,
      status: status,
      createTime: now,
      updateTime: now,
    );
  }

  /// 创建 todo task item
  TodoTaskItemEntity createTaskItem({
    String? id,
    required String topicId,
    String title = '测试子项',
    String content = '测试内容',
    String status = 'pending',
  }) {
    final now = DateTime.now();
    return TodoTaskItemEntity(
      id: id ?? const Uuid().v4(),
      employeeId: employeeId,
      topicId: topicId,
      title: title,
      content: content,
      status: status,
      createTime: now,
      updateTime: now,
    );
  }

  /// 模拟同步路径1：event（LAN 广播 + event）> update store
  ///
  /// Device A 产生 session summary 变更后广播到 Device B，
  /// Device B 通过 upsertFromRemote 更新本地 store。
  Future<void> syncViaEvent(String empId, {String? fromDeviceId}) async {
    final targetDeviceId = fromDeviceId ?? deviceA;
    final summary = await summaryStoreA.getSummary(empId, deviceId: targetDeviceId);
    if (summary != null) async {
      await sawait uawait mmaryStoreB.upsertFromRemote(summary);
    }
  }

  /// 模拟同步路径2：query > update store
  ///
  /// Device B 主动查询 Device A 的所有 session summaries，
  /// 然后通过 upsertFromRemote 写入本地 store。
  Future<void> syncViaQuery() async {
    final summaries = await summaryStoreA.getAllSummaries();
    for (final summary in summaries) async {
      await sawait uawait mmaryStoreB.upsertFromRemote(summary);
    }
  }

  /// 模拟 todo 同步：将 Device A 的 todo 数据同步到 Device B
  Future<void> syncTodoFromA() async {
    final topics = await todoStoreA.findAllTopics(employeeId);
    await todoStoreB.upsertAllTopicsFromRemote(topics);
    for (final topic in topics) async {
      final items = await todoStoreA.findTaskItemsByTopic(topic.id);
      await todoStoreB.upsertAllTaskItemsFromRemote(items);
    }
  }

  /// 模拟 Agent 执行 todo 子项：更新状态 → 产生 assistant 消息 → 更新 session summary
  Future<void> simulateAgentExecuteTask({
    required String topicId,
    required String taskId,
    required String taskTitle,
    String assistantReply = '任务已完成',
  }) async {
    // 1. 更新 task item 状态为 in_progress
    await todoStoreA.updateTaskItemStatus(taskId, 'in_progress');
    await todoStoreA.recalculateTopicStatus(topicId);

    // 2. 模拟 Agent 执行任务后产生 assistant 消息
    final msgId = 'msg-${const Uuid().v4().substring(0, 8)}';
    final now = DateTime.now().millisecondsSinceEpoch;
    await summaryStoreA.onMessageAdded(
      employeeId: employeeId,
      deviceId: deviceA,
      role: 'assistant',
      isRead: false,
      messageId: msgId,
      createTime: now,
      seq: now ~/ 1000,
      content: assistantReply,
    );

    // 3. 标记 task item 为 completed
    await todoStoreA.updateTaskItemStatus(taskId, 'completed');
    await todoStoreA.recalculateTopicStatus(topicId);
  }

  // ═══════════════════════════════════════════════════
  // 1. 基础流程：创建 todo → 执行 → session summary 更新
  // ═══════════════════════════════════════════════════

  group('基础流程：创建 todo → 执行 → session summary 更新', () {
    test('创建 todo topic 后，session summary 初始为空（无消息产生）', () async {
      // 创建 todo topic
      final topic = createTopic(title: '实现登录功能');
      await todoStoreA.saveTopic(topic);

      // 添加 task items
      await todoStoreA.saveTaskItem(
        createTaskItem(topicId: topic.id, title: '设计登录页面'),
      );
      await todoStoreA.saveTaskItem(
        createTaskItem(topicId: topic.id, title: '实现登录逻辑'),
      );
      await todoStoreA.recalculateTopicStatus(topic.id);

      // session summary 尚未创建（没有消息产生）
      expect(
        await summaryStoreA.getSummary(employeeId, deviceId: deviceA),
        isNull,
      );

      // todo 数据存在
      final topics = await todoStoreA.findAllTopics(employeeId);
      expect(topics.length, equals(1));
      expect(topics.first.title, equals('实现登录功能'));
      expect(topics.first.status, equals('pending'));

      final items = await todoStoreA.findTaskItemsByTopic(topic.id);
      expect(items.length, equals(2));
    });

    test('执行 todo 子项后产生 assistant 消息，session summary 正确更新', () async {
      // 1. 创建 todo
      final topic = createTopic(title: '实现登录功能');
      await todoStoreA.saveTopic(topic);
      final task1 = createTaskItem(
        topicId: topic.id,
        title: '设计登录页面',
      );
      final task2 = createTaskItem(
        topicId: topic.id,
        title: '实现登录逻辑',
      );
      await todoStoreA.saveTaskItem(task1);
      await todoStoreA.saveTaskItem(task2);
      await todoStoreA.recalculateTopicStatus(topic.id);

      // 2. 执行第一个子项（手动控制步骤，验证中间状态）
      await todoStoreA.updateTaskItemStatus(task1.id, 'in_progress');
      await todoStoreA.recalculateTopicStatus(topic.id);

      // 产生 assistant 消息
      await summaryStoreA.onMessageAdded(
        employeeId: employeeId,
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-${const Uuid().v4().substring(0, 8)}',
        createTime: DateTime.now().millisecondsSinceEpoch,
        seq: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        content: '登录页面设计完成，包含用户名和密码输入框',
      );

      // 3. 验证 session summary
      final summary = await summaryStoreA.getSummary(employeeId, deviceId: deviceA);
      expect(summary, isNotNull);
      expect(summary!.unreadCount, equals(1));
      expect(summary.lastMsgContent, contains('登录页面设计完成'));
      expect(summary.lastMsgRole, equals('assistant'));

      // 4. 验证 todo 状态（task1 还在 in_progress，topic 应为 in_progress）
      final updatedTopic = await todoStoreA.findTopicById(topic.id);
      expect(updatedTopic!.status, equals('in_progress'));

      final updatedTask1 = await todoStoreA.findTaskItemById(task1.id);
      expect(updatedTask1!.status, equals('in_progress'));

      final updatedTask2 = await todoStoreA.findTaskItemById(task2.id);
      expect(updatedTask2!.status, equals('pending'));

      // 5. 执行第二个子项
      simulateAgentExecuteTask(
        topicId: topic.id,
        taskId: task2.id,
        taskTitle: '实现登录逻辑',
        assistantReply: '登录逻辑实现完成，支持密码加密和JWT认证',
      );

      // 6. 验证 session summary 更新
      final summaryAfter = await summaryStoreA.getSummary(
        employeeId,
        deviceId: deviceA,
      );
      expect(summaryAfter, isNotNull);
      expect(summaryAfter!.unreadCount, equals(2));
      expect(summaryAfter.lastMsgContent, contains('登录逻辑实现完成'));

      // 7. 验证 todo 全部完成
      final finalTopic = await todoStoreA.findTopicById(topic.id);
      expect(finalTopic!.status, equals('completed'));
      expect(finalTopic.completedAt, isNotNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // 2. 同步路径1：event（LAN 广播 + event）> update store
  // ═══════════════════════════════════════════════════

  group('同步路径1：event（LAN 广播 + event）> update store', () {
    test(
      'Device A 创建 todo 并执行后，通过 event 广播 session summary 到 Device B',
      () async {
        // 1. Device A 创建 todo 并执行
        final topic = createTopic(title: '数据同步任务');
        await todoStoreA.saveTopic(topic);
        final task = createTaskItem(
          topicId: topic.id,
          title: '实现增量同步',
        );
        await todoStoreA.saveTaskItem(task);
        await todoStoreA.recalculateTopicStatus(topic.id);

        // 2. 执行任务，产生消息
        simulateAgentExecuteTask(
          topicId: topic.id,
          taskId: task.id,
          taskTitle: '实现增量同步',
          assistantReply: '增量同步已实现，基于 watermark 机制',
        );

        // 3. Device B 初始状态为空
        expect(await summaryStoreB.getAllSummaries(), isEmpty);

        // 4. 模拟 event 广播：Device A → Device B
        syncViaEvent(employeeId);

        // 5. 验证 Device B 收到 session summary
        final summaryB = await summaryStoreB.getSummary(
          employeeId,
          deviceId: deviceA,
        );
        expect(summaryB, isNotNull);
        expect(summaryB!.unreadCount, equals(1));
        expect(summaryB.lastMsgContent, contains('增量同步已实现'));
        expect(summaryB.lastMsgRole, equals('assistant'));
        expect(summaryB.employeeId, equals(employeeId));
        expect(summaryB.deviceId, equals(deviceA));
      },
    );

    test(
      'Device A 连续执行多个 todo 子项，每次执行后广播，Device B 逐步更新',
      () async {
        // 创建 todo with 3 个子项
        final topic = createTopic(title: '重构项目');
        await todoStoreA.saveTopic(topic);
        final tasks = <TodoTaskItemEntity>[];
        for (int i = 1; i <= 3; i++) {
          final task = createTaskItem(
            topicId: topic.id,
            title: '步骤$i',
          );
          await todoStoreA.saveTaskItem(task);
          tasks.add(task);
        }
        await todoStoreA.recalculateTopicStatus(topic.id);

        // 执行第 1 个子项并广播
        simulateAgentExecuteTask(
          topicId: topic.id,
          taskId: tasks[0].id,
          taskTitle: '步骤1',
          assistantReply: '步骤1完成',
        );
        syncViaEvent(employeeId);

        var summaryB = await summaryStoreB.getSummary(
          employeeId,
          deviceId: deviceA,
        );
        expect(summaryB!.unreadCount, equals(1));
        expect(summaryB.lastMsgContent, equals('步骤1完成'));

        // 执行第 2 个子项并广播
        simulateAgentExecuteTask(
          topicId: topic.id,
          taskId: tasks[1].id,
          taskTitle: '步骤2',
          assistantReply: '步骤2完成',
        );
        syncViaEvent(employeeId);

        summaryB = await summaryStoreB.getSummary(employeeId, deviceId: deviceA);
        expect(summaryB!.unreadCount, equals(2));
        expect(summaryB.lastMsgContent, equals('步骤2完成'));

        // 执行第 3 个子项并广播
        simulateAgentExecuteTask(
          topicId: topic.id,
          taskId: tasks[2].id,
          taskTitle: '步骤3',
          assistantReply: '步骤3完成，项目重构完毕',
        );
        syncViaEvent(employeeId);

        summaryB = await summaryStoreB.getSummary(employeeId, deviceId: deviceA);
        expect(summaryB!.unreadCount, equals(3));
        expect(summaryB.lastMsgContent, equals('步骤3完成，项目重构完毕'));

        // 验证 todo topic 状态为 completed
        final topicA = await todoStoreA.findTopicById(topic.id);
        expect(topicA!.status, equals('completed'));
      },
    );

    test(
      'Device B 标记已读后，event 广播不会覆盖已读状态（MAX 策略保护）',
      () async {
        // Device A 产生消息
        final topic = createTopic(title: '测试任务');
        await todoStoreA.saveTopic(topic);
        final task = createTaskItem(topicId: topic.id, title: '子任务');
        await todoStoreA.saveTaskItem(task);
        await todoStoreA.recalculateTopicStatus(topic.id);
        simulateAgentExecuteTask(
          topicId: topic.id,
          taskId: task.id,
          taskTitle: '子任务',
          assistantReply: '任务完成',
        );

        // 广播到 Device B
        syncViaEvent(employeeId);
        expect(
          await summaryStoreB.getUnreadCount(employeeId, deviceId: deviceA),
          equals(1),
        );

        // Device B 标记已读
        await summaryStoreB.markAsRead(employeeId, deviceId: deviceA);
        expect(
          await summaryStoreB.getUnreadCount(employeeId, deviceId: deviceA),
          equals(0),
        );

        // Device A 再次广播（可能因为其他事件触发）
        // 模拟 Device A 产生新消息
        final msgId = 'msg-${const Uuid().v4().substring(0, 8)}';
        final now = DateTime.now().millisecondsSinceEpoch;
        await summaryStoreA.onMessageAdded(
          employeeId: employeeId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: msgId,
          createTime: now,
          seq: now ~/ 1000,
          content: '新的回复',
        );
        syncViaEvent(employeeId);

        // Device B 的未读数取 MAX(local=0, remote=2) = 2
        // MAX 策略保护：Device B 的已读状态不会被覆盖为 0，
        // 但新消息会增加未读
        final unreadB =
            await summaryStoreB.getUnreadCount(employeeId, deviceId: deviceA);
        expect(unreadB, equals(2));
      },
    );

    test(
      '旧 event 到达（网络延迟）不覆盖 Device B 更新的本地数据',
      () async {
        // Device B 先收到较新的 session summary（通过其他路径）
        await summaryStoreB.onMessageAdded(
          employeeId: employeeId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-new',
          createTime: 3000,
          seq: 5,
          content: '最新回复',
        );

        // 模拟延迟到达的旧 event（Device A 的旧摘要）
        final oldRemote = SessionSummaryEntity(
          employeeId: employeeId,
          deviceId: deviceA,
          unreadCount: 1,
          lastMsgId: 'msg-old',
          lastMsgRole: 'assistant',
          lastMsgContent: '旧回复',
          lastMsgTime: 1000,
          lastMsgSeq: 1,
          updateTime: 1000,
        );
        await sawait uawait mmaryStoreB.upsertFromRemote(oldRemote);

        // Device B 的最新消息不被旧 event 覆盖
        final summaryB = await summaryStoreB.getSummary(
          employeeId,
          deviceId: deviceA,
        );
        expect(summaryB, isNotNull);
        expect(summaryB!.lastMsgId, equals('msg-new'));
        expect(summaryB.lastMsgContent, equals('最新回复'));
        expect(summaryB.lastMsgTime, equals(3000));
      },
    );

    test(
      'event 广播携带 pending 权限请求，Device B 正确接收',
      () async {
        // Device A 创建 todo 并执行
        final topic = createTopic(title: '文件操作任务');
        await todoStoreA.saveTopic(topic);
        final task = createTaskItem(topicId: topic.id, title: '读取配置文件');
        await todoStoreA.saveTaskItem(task);
        await todoStoreA.recalculateTopicStatus(topic.id);
        simulateAgentExecuteTask(
          topicId: topic.id,
          taskId: task.id,
          taskTitle: '读取配置文件',
          assistantReply: '需要权限读取配置文件',
        );

        // Device A 产生权限请求
        await summaryStoreA.setPendingPermission(
          employeeId,
          deviceA,
          '{"type":"permission","id":"req-1","tool":"file_read"}',
        );

        // 广播到 Device B
        syncViaEvent(employeeId);

        // Device B 验证
        final summaryB = await summaryStoreB.getSummary(
          employeeId,
          deviceId: deviceA,
        );
        expect(summaryB, isNotNull);
        expect(summaryB!.hasPendingPermission, isTrue);
        expect(summaryB.pendingPermission, contains('req-1'));
        expect(summaryB.unreadCount, equals(1));
        expect(summaryB.lastMsgContent, equals('需要权限读取配置文件'));
      },
    );
  });

  // ═══════════════════════════════════════════════════
  // 3. 同步路径2：query > update store
  // ═══════════════════════════════════════════════════

  group('同步路径2：query > update store', () {
    test(
      'Device B 上线后主动 query，拉取 Device A 的所有 session summaries',
      () async {
        // Device A 有多个员工的会话
        await summaryStoreA.onMessageAdded(
          employeeId: 'emp-1',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-1',
          createTime: 1000,
          seq: 1,
          content: '消息1',
        );
        await summaryStoreA.onMessageAdded(
          employeeId: 'emp-2',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-2',
          createTime: 2000,
          seq: 1,
          content: '消息2',
        );
        await summaryStoreA.onMessageAdded(
          employeeId: 'emp-3',
          deviceId: deviceA,
          role: 'assistant',
          isRead: true,
          messageId: 'msg-3',
          createTime: 3000,
          seq: 1,
          content: '消息3（已读）',
        );

        // Device B 初始为空
        expect(await summaryStoreB.getAllSummaries(), isEmpty);

        // Device B 主动 query
        syncViaQuery();

        // 验证 Device B 拉取到所有 summaries
        final summariesB = await summaryStoreB.getAllSummaries();
        expect(summariesB.length, equals(3));

        // 验证各摘要数据
        final s1 = await summaryStoreB.getSummary('emp-1', deviceId: deviceA);
        expect(s1!.unreadCount, equals(1));
        expect(s1.lastMsgContent, equals('消息1'));

        final s2 = await summaryStoreB.getSummary('emp-2', deviceId: deviceA);
        expect(s2!.unreadCount, equals(1));
        expect(s2.lastMsgContent, equals('消息2'));

        final s3 = await summaryStoreB.getSummary('emp-3', deviceId: deviceA);
        expect(s3!.unreadCount, equals(0));
        expect(s3.lastMsgContent, equals('消息3（已读）'));
      },
    );

    test(
      'Device B 多次 query 不产生数据漂移（幂等性）',
      () async {
        // Device A 创建 todo 并执行
        final topic = createTopic(title: '幂等测试');
        await todoStoreA.saveTopic(topic);
        final task = createTaskItem(topicId: topic.id, title: '子任务');
        await todoStoreA.saveTaskItem(task);
        await todoStoreA.recalculateTopicStatus(topic.id);
        simulateAgentExecuteTask(
          topicId: topic.id,
          taskId: task.id,
          taskTitle: '子任务',
          assistantReply: '执行完成',
        );

        // Device B 连续 query 10 次
        for (int i = 0; i < 10; i++) {
          syncViaQuery();
        }

        // 数据不变
        final summaryB = await summaryStoreB.getSummary(
          employeeId,
          deviceId: deviceA,
        );
        expect(summaryB, isNotNull);
        expect(summaryB!.unreadCount, equals(1));
        expect(summaryB.lastMsgContent, equals('执行完成'));
      },
    );

    test(
      'Device A 离线期间产生大量数据，上线后 query 全量同步恢复',
      () async {
        // Device A 离线期间：创建 todo + 执行 + 产生消息
        final topic = createTopic(title: '离线任务');
        await todoStoreA.saveTopic(topic);

        // 创建 5 个子项并全部执行
        final tasks = <TodoTaskItemEntity>[];
        for (int i = 1; i <= 5; i++) {
          final task = createTaskItem(
            topicId: topic.id,
            title: '离线子任务$i',
          );
          await todoStoreA.saveTaskItem(task);
          tasks.add(task);
        }
        await todoStoreA.recalculateTopicStatus(topic.id);

        for (int i = 0; i < tasks.length; i++) {
          simulateAgentExecuteTask(
            topicId: topic.id,
            taskId: tasks[i].id,
            taskTitle: '离线子任务${i + 1}',
            assistantReply: '离线子任务${i + 1}完成',
          );
        }

        // Device B 完全不知道
        expect(await summaryStoreB.getAllSummaries(), isEmpty);

        // 上线后全量 query
        syncViaQuery();

        // Device B 恢复所有数据
        final summaryB = await summaryStoreB.getSummary(
          employeeId,
          deviceId: deviceA,
        );
        expect(summaryB, isNotNull);
        expect(summaryB!.unreadCount, equals(5));
        expect(summaryB.lastMsgContent, equals('离线子任务5完成'));

        // 同步 todo 数据
        syncTodoFromA();
        final topicsB = await todoStoreB.findAllTopics(employeeId);
        expect(topicsB.length, equals(1));
        expect(topicsB.first.status, equals('completed'));

        final itemsB = await todoStoreB.findTaskItemsByTopic(topicsB.first.id);
        expect(itemsB.length, equals(5));
        expect(
          itemsB.every((item) => item.status == 'completed'),
          isTrue,
        );
      },
    );

    test(
      'query 同步时，MAX 策略保护 Device B 本地的未读数',
      () async {
        // Device B 本地已有较高的未读数（通过其他途径获得）
        await summaryStoreB.onMessageAdded(
          employeeId: employeeId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-b-local',
          createTime: 2500,
          seq: 3,
          content: 'B本地消息',
        );
        expect(
          await summaryStoreB.getUnreadCount(employeeId, deviceId: deviceA),
          equals(1),
        );

        // Device A 的未读数为 1（只有 1 条未读）
        await summaryStoreA.onMessageAdded(
          employeeId: employeeId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-a',
          createTime: 2000,
          seq: 2,
          content: 'A的消息',
        );

        // Device B query 同步
        syncViaQuery();

        // MAX 策略：max(local=1, remote=1) = 1
        expect(
          await summaryStoreB.getUnreadCount(employeeId, deviceId: deviceA),
          equals(1),
        );

        // 最新消息取时间更晚的
        final summaryB = await summaryStoreB.getSummary(
          employeeId,
          deviceId: deviceA,
        );
        expect(summaryB!.lastMsgTime, equals(2500));
      },
    );
  });

  // ═══════════════════════════════════════════════════
  // 4. 两条同步路径协作
  // ═══════════════════════════════════════════════════

  group('两条同步路径协作', () {
    test(
      'event 和 query 混合使用，最终数据一致',
      () async {
        // 1. Device A 创建 todo 并执行第一个子项
        final topic = createTopic(title: '混合同步测试');
        await todoStoreA.saveTopic(topic);
        final task1 = createTaskItem(
          topicId: topic.id,
          title: '子任务1',
        );
        final task2 = createTaskItem(
          topicId: topic.id,
          title: '子任务2',
        );
        await todoStoreA.saveTaskItem(task1);
        await todoStoreA.saveTaskItem(task2);
        await todoStoreA.recalculateTopicStatus(topic.id);

        simulateAgentExecuteTask(
          topicId: topic.id,
          taskId: task1.id,
          taskTitle: '子任务1',
          assistantReply: '子任务1完成',
        );

        // 2. 通过 event 同步到 Device B
        syncViaEvent(employeeId);
        var summaryB = await summaryStoreB.getSummary(
          employeeId,
          deviceId: deviceA,
        );
        expect(summaryB!.unreadCount, equals(1));
        expect(summaryB.lastMsgContent, equals('子任务1完成'));

        // 3. Device A 继续执行第二个子项
        simulateAgentExecuteTask(
          topicId: topic.id,
          taskId: task2.id,
          taskTitle: '子任务2',
          assistantReply: '子任务2完成',
        );

        // 4. Device B 通过 query 拉取最新数据
        syncViaQuery();
        summaryB = await summaryStoreB.getSummary(employeeId, deviceId: deviceA);
        expect(summaryB!.unreadCount, equals(2));
        expect(summaryB.lastMsgContent, equals('子任务2完成'));

        // 5. Device A 和 Device B 数据一致
        final summaryA = await summaryStoreA.getSummary(
          employeeId,
          deviceId: deviceA,
        );
        expect(summaryA!.lastMsgId, equals(summaryB.lastMsgId));
        expect(summaryA.lastMsgContent, equals(summaryB.lastMsgContent));
        expect(summaryA.lastMsgTime, equals(summaryB.lastMsgTime));
      },
    );

    test(
      'Device B 先通过 query 全量同步，后续通过 event 增量同步',
      () async {
        // Device A 已有 3 个会话摘要
        for (int i = 1; i <= 3; i++) {
          await summaryStoreA.onMessageAdded(
            employeeId: 'emp-$i',
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-$i',
            createTime: 1000 * i,
            seq: i,
            content: '消息$i',
          );
        }

        // 1. Device B 上线，全量 query
        syncViaQuery();
        expect(await summaryStoreB.getAllSummaries().length, equals(3));

        // 2. Device A 新增消息，通过 event 广播
        await summaryStoreA.onMessageAdded(
          employeeId: 'emp-1',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-1-new',
          createTime: 5000,
          seq: 4,
          content: 'emp-1新消息',
        );
        syncViaEvent('emp-1');

        // 3. 验证增量更新
        final summaryB =
            await summaryStoreB.getSummary('emp-1', deviceId: deviceA);
        expect(summaryB!.lastMsgId, equals('msg-1-new'));
        expect(summaryB.lastMsgContent, equals('emp-1新消息'));
        expect(summaryB.unreadCount, equals(2)); // 原有1条 + 新增1条

        // 4. 其他会话不受影响
        expect(
          await summaryStoreB.getSummary('emp-2', deviceId: deviceA)!.lastMsgId,
          equals('msg-2'),
        );
        expect(
          await summaryStoreB.getSummary('emp-3', deviceId: deviceA)!.lastMsgId,
          equals('msg-3'),
        );
      },
    );

    test(
      '多员工场景下，event 和 query 分别同步不同员工的数据',
      () async {
        // Device A 有 emp-1, emp-2, emp-3 三个员工的会话
        for (int i = 1; i <= 3; i++) {
          final topic = createTopic(
            title: '员工$i的任务',
          );
          // 每个 todo 绑定不同员工
          final empTopic = topic.copyWith(employeeId: 'emp-$i');
          await todoStoreA.saveTopic(empTopic);
          final task = createTaskItem(
            topicId: empTopic.id,
            title: '子任务',
          );
          final empTask = task.copyWith(employeeId: 'emp-$i');
          await todoStoreA.saveTaskItem(empTask);
          await todoStoreA.recalculateTopicStatus(empTopic.id);

          await summaryStoreA.onMessageAdded(
            employeeId: 'emp-$i',
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-$i',
            createTime: 1000 * i,
            seq: i,
            content: '员工$i的消息',
          );
        }

        // 1. event 同步 emp-1
        syncViaEvent('emp-1');
        expect(
          await summaryStoreB.getSummary('emp-1', deviceId: deviceA),
          isNotNull,
        );
        expect(
          await summaryStoreB.getSummary('emp-2', deviceId: deviceA),
          isNull,
        );
        expect(
          await summaryStoreB.getSummary('emp-3', deviceId: deviceA),
          isNull,
        );

        // 2. query 全量同步
        syncViaQuery();
        expect(
          await summaryStoreB.getSummary('emp-1', deviceId: deviceA),
          isNotNull,
        );
        expect(
          await summaryStoreB.getSummary('emp-2', deviceId: deviceA),
          isNotNull,
        );
        expect(
          await summaryStoreB.getSummary('emp-3', deviceId: deviceA),
          isNotNull,
        );
        expect(await summaryStoreB.getAllSummaries().length, equals(3));

        // 3. event 同步 emp-2 的新消息
        await summaryStoreA.onMessageAdded(
          employeeId: 'emp-2',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-2-new',
          createTime: 5000,
          seq: 2,
          content: '员工2的新消息',
        );
        syncViaEvent('emp-2');

        final summaryB2 =
            await summaryStoreB.getSummary('emp-2', deviceId: deviceA);
        expect(summaryB2!.lastMsgId, equals('msg-2-new'));
        expect(summaryB2.lastMsgContent, equals('员工2的新消息'));
      },
    );
  });

  // ═══════════════════════════════════════════════════
  // 5. 完整端到端场景
  // ═══════════════════════════════════════════════════

  group('完整端到端场景', () {
    test(
      '完整生命周期：创建 todo → 执行 → 权限请求 → 响应 → 完成 → 同步 → 已读 → 删除',
      () async {
        // ─── Phase 1: 创建 todo ───
        final topic = createTopic(
          title: '实现文件搜索功能',
          description: '需要搜索项目中的所有 Dart 文件',
        );
        await todoStoreA.saveTopic(topic);

        final task1 = createTaskItem(
          topicId: topic.id,
          title: '扫描项目目录',
          content: '遍历项目目录，收集所有 .dart 文件路径',
        );
        final task2 = createTaskItem(
          topicId: topic.id,
          title: '实现搜索逻辑',
          content: '在文件内容中搜索关键词并返回匹配结果',
        );
        final task3 = createTaskItem(
          topicId: topic.id,
          title: '测试验证',
          content: '编写测试用例验证搜索功能',
        );
        await todoStoreA.saveTaskItem(task1);
        await todoStoreA.saveTaskItem(task2);
        await todoStoreA.saveTaskItem(task3);
        await todoStoreA.recalculateTopicStatus(topic.id);

        // topic 状态为 pending
        expect(await todoStoreA.findTopicById(topic.id)!.status, equals('pending'));

        // ─── Phase 2: 执行 task1（无需权限）───
        simulateAgentExecuteTask(
          topicId: topic.id,
          taskId: task1.id,
          taskTitle: '扫描项目目录',
          assistantReply: '已扫描项目目录，发现 42 个 Dart 文件',
        );

        // topic 状态变为 in_progress
        expect(
          await todoStoreA.findTopicById(topic.id)!.status,
          equals('in_progress'),
        );

        // session summary 有 1 条未读
        expect(
          await summaryStoreA.getUnreadCount(employeeId, deviceId: deviceA),
          equals(1),
        );

        // event 广播到 Device B
        syncViaEvent(employeeId);
        expect(
          await summaryStoreB.getUnreadCount(employeeId, deviceId: deviceA),
          equals(1),
        );

        // ─── Phase 3: 执行 task2（需要权限）───
        // task1 已完成（simulateAgentExecuteTask 在 Phase 2 中已标记）
        // 手动控制 task2 的执行步骤
        await todoStoreA.updateTaskItemStatus(task2.id, 'in_progress');
        await todoStoreA.recalculateTopicStatus(topic.id);

        // 产生 assistant 消息（需要权限）
        await summaryStoreA.onMessageAdded(
          employeeId: employeeId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-permission-request',
          createTime: DateTime.now().millisecondsSinceEpoch,
          seq: 100,
          content: '需要读取文件权限才能搜索文件内容',
        );

        // 产生权限请求
        await summaryStoreA.setPendingPermission(
          employeeId,
          deviceA,
          '{"type":"permission","id":"req-file-read","tool":"file_read","path":"/project/src"}',
        );

        // event 广播（携带 pending）
        syncViaEvent(employeeId);

        // Device B 验证：有 pending 权限请求
        var summaryB = await summaryStoreB.getSummary(
          employeeId,
          deviceId: deviceA,
        );
        expect(summaryB!.hasPendingPermission, isTrue);
        expect(summaryB.pendingPermission, contains('req-file-read'));
        expect(summaryB.unreadCount, equals(2));

        // ─── Phase 4: Device B 响应权限请求 ───
        await summaryStoreA.clearPendingPermission(employeeId, deviceA);
        await summaryStoreB.clearPendingPermission(employeeId, deviceA);

        // event 广播（pending 已清除）
        syncViaEvent(employeeId);

        summaryB = await summaryStoreB.getSummary(employeeId, deviceId: deviceA);
        expect(summaryB!.hasPendingPermission, isFalse);

        // ─── Phase 5: 继续执行 task2（权限已获）───
        simulateAgentExecuteTask(
          topicId: topic.id,
          taskId: task2.id,
          taskTitle: '实现搜索逻辑',
          assistantReply: '搜索逻辑已实现，支持正则表达式匹配',
        );

        // ─── Phase 6: 执行 task3（完成）───
        simulateAgentExecuteTask(
          topicId: topic.id,
          taskId: task3.id,
          taskTitle: '测试验证',
          assistantReply: '测试通过，文件搜索功能已完成',
        );

        // topic 状态为 completed
        expect(
          await todoStoreA.findTopicById(topic.id)!.status,
          equals('completed'),
        );

        // session summary 有 5 条未读（1+1+1+1+1，每次执行产生一条）
        expect(
          await summaryStoreA.getUnreadCount(employeeId, deviceId: deviceA),
          equals(5),
        );

        // event 广播最终状态
        syncViaEvent(employeeId);

        // Device B 验证最终状态
        summaryB = await summaryStoreB.getSummary(employeeId, deviceId: deviceA);
        expect(summaryB!.unreadCount, equals(5));
        expect(summaryB.lastMsgContent, equals('测试通过，文件搜索功能已完成'));
        expect(summaryB.hasPendingPermission, isFalse);

        // ─── Phase 7: Device B query 全量同步确认 ───
        syncViaQuery();
        summaryB = await summaryStoreB.getSummary(employeeId, deviceId: deviceA);
        expect(summaryB!.lastMsgContent, equals('测试通过，文件搜索功能已完成'));

        // ─── Phase 8: Device B 标记已读 ───
        await summaryStoreB.markAsRead(employeeId, deviceId: deviceA);
        expect(
          await summaryStoreB.getUnreadCount(employeeId, deviceId: deviceA),
          equals(0),
        );

        // Device A 也标记已读
        await summaryStoreA.markAsRead(employeeId, deviceId: deviceA);
        expect(
          await summaryStoreA.getUnreadCount(employeeId, deviceId: deviceA),
          equals(0),
        );

        // ─── Phase 9: 删除会话 ───
        await summaryStoreA.deleteSummary(employeeId, deviceId: deviceA);
        await summaryStoreB.deleteSummary(employeeId, deviceId: deviceA);

        expect(
          await summaryStoreA.getSummary(employeeId, deviceId: deviceA),
          isNull,
        );
        expect(
          await summaryStoreB.getSummary(employeeId, deviceId: deviceA),
          isNull,
        );
        expect(await summaryStoreA.getTotalUnreadCount(), equals(0));
        expect(await summaryStoreB.getTotalUnreadCount(), equals(0));
      },
    );

    test(
      '多设备并发场景：Device A 执行 todo，Device B 同时 query，最终一致',
      () async {
        // Device A 创建 todo
        final topic = createTopic(title: '并发测试');
        await todoStoreA.saveTopic(topic);
        final task = createTaskItem(topicId: topic.id, title: '并发子任务');
        await todoStoreA.saveTaskItem(task);
        await todoStoreA.recalculateTopicStatus(topic.id);

        // Device A 执行 todo，产生消息
        simulateAgentExecuteTask(
          topicId: topic.id,
          taskId: task.id,
          taskTitle: '并发子任务',
          assistantReply: '并发执行完成',
        );

        // 模拟并发：同时 event 和 query
        syncViaEvent(employeeId);
        syncViaQuery();

        // 两端数据一致
        final summaryA = await summaryStoreA.getSummary(
          employeeId,
          deviceId: deviceA,
        );
        final summaryB = await summaryStoreB.getSummary(
          employeeId,
          deviceId: deviceA,
        );

        expect(summaryA, isNotNull);
        expect(summaryB, isNotNull);
        expect(summaryA!.lastMsgId, equals(summaryB!.lastMsgId));
        expect(summaryA.lastMsgContent, equals(summaryB.lastMsgContent));
        expect(summaryA.lastMsgTime, equals(summaryB.lastMsgTime));
        expect(summaryA.unreadCount, equals(summaryB.unreadCount));
      },
    );

    test(
      'Entity 序列化往返一致性（模拟 LAN 广播传输）',
      () async {
        // 创建完整的 session summary
        await summaryStoreA.onMessageAdded(
          employeeId: employeeId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-serialize-test',
          createTime: 12345,
          seq: 42,
          content: '序列化测试消息',
        );
        await summaryStoreA.setPendingPermission(
          employeeId,
          deviceA,
          '{"type":"permission","id":"req-serialize"}',
        );
        await summaryStoreA.setPendingConfirm(
          employeeId,
          deviceA,
          '{"type":"confirm","id":"conf-serialize"}',
        );

        // 读取 → toMap → fromMap（模拟序列化传输）
        final original = await summaryStoreA.getSummary(
          employeeId,
          deviceId: deviceA,
        )!;
        final map = original.toMap();
        final restored = SessionSummaryEntity.fromMap(map);

        // 写入 Device B
        await sawait uawait mmaryStoreB.upsertFromRemote(restored);

        // 验证往返一致性
        final summaryB = await summaryStoreB.getSummary(
          employeeId,
          deviceId: deviceA,
        );
        expect(summaryB, isNotNull);
        expect(summaryB!.employeeId, equals(original.employeeId));
        expect(summaryB.deviceId, equals(original.deviceId));
        expect(summaryB.unreadCount, equals(original.unreadCount));
        expect(summaryB.lastMsgId, equals(original.lastMsgId));
        expect(summaryB.lastMsgRole, equals(original.lastMsgRole));
        expect(summaryB.lastMsgContent, equals(original.lastMsgContent));
        expect(summaryB.lastMsgTime, equals(original.lastMsgTime));
        expect(summaryB.lastMsgSeq, equals(original.lastMsgSeq));
        expect(summaryB.hasPendingPermission, equals(original.hasPendingPermission));
        expect(summaryB.hasPendingConfirm, equals(original.hasPendingConfirm));
      },
    );
  });

  // ═══════════════════════════════════════════════════
  // 6. PK 隔离验证（employeeId + deviceId）
  // ═══════════════════════════════════════════════════

  group('PK 隔离验证（employeeId + deviceId）', () {
    test(
      '同一 employeeId 不同 deviceId 的摘要互不影响',
      () async {
        // Device A 的 session summary（deviceId = deviceA）
        await summaryStoreA.onMessageAdded(
          employeeId: employeeId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-on-a',
          createTime: 1000,
          seq: 1,
          content: 'Device A 上的消息',
        );

        // Device A 也存储来自 Device C 的 session summary（deviceId = deviceC）
        const deviceC = 'device-c-xxx';
        await summaryStoreA.onMessageAdded(
          employeeId: employeeId,
          deviceId: deviceC,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-on-c',
          createTime: 2000,
          seq: 1,
          content: 'Device C 上的消息',
        );

        // 两个摘要独立存在
        final summaryA =
            await summaryStoreA.getSummary(employeeId, deviceId: deviceA);
        final summaryC =
            await summaryStoreA.getSummary(employeeId, deviceId: deviceC);

        expect(summaryA, isNotNull);
        expect(summaryA!.lastMsgContent, equals('Device A 上的消息'));
        expect(summaryA.unreadCount, equals(1));

        expect(summaryC, isNotNull);
        expect(summaryC!.lastMsgContent, equals('Device C 上的消息'));
        expect(summaryC.unreadCount, equals(1));

        // 同步到 Device B 时，两个摘要分别存储
        syncViaEvent(employeeId); // 同步 deviceA 的摘要
        // 手动同步 deviceC 的摘要
        final summaryCForSync =
            await summaryStoreA.getSummary(employeeId, deviceId: deviceC);
        if (summaryCForSync != null) {
          await sawait uawait mmaryStoreB.upsertFromRemote(summaryCForSync);
        }

        // Device B 有两个独立的摘要
        final bSummaryA =
            await summaryStoreB.getSummary(employeeId, deviceId: deviceA);
        final bSummaryC =
            await summaryStoreB.getSummary(employeeId, deviceId: deviceC);

        expect(bSummaryA, isNotNull);
        expect(bSummaryA!.lastMsgContent, equals('Device A 上的消息'));
        expect(bSummaryC, isNotNull);
        expect(bSummaryC!.lastMsgContent, equals('Device C 上的消息'));

        // 标记 deviceA 的已读不影响 deviceC
        await summaryStoreB.markAsRead(employeeId, deviceId: deviceA);
        expect(
          await summaryStoreB.getUnreadCount(employeeId, deviceId: deviceA),
          equals(0),
        );
        expect(
          await summaryStoreB.getUnreadCount(employeeId, deviceId: deviceC),
          equals(1),
        );
      },
    );

    test(
      '不同 employeeId 的摘要完全隔离',
      () async {
        // Device A 有两个员工的会话
        await summaryStoreA.onMessageAdded(
          employeeId: 'emp-alpha',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-alpha',
          createTime: 1000,
          seq: 1,
          content: 'Alpha的消息',
        );
        await summaryStoreA.onMessageAdded(
          employeeId: 'emp-beta',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-beta',
          createTime: 2000,
          seq: 1,
          content: 'Beta的消息',
        );

        // 全量同步到 Device B
        syncViaQuery();

        // 标记 emp-alpha 已读不影响 emp-beta
        await summaryStoreB.markAsRead('emp-alpha', deviceId: deviceA);
        expect(
          await summaryStoreB.getUnreadCount('emp-alpha', deviceId: deviceA),
          equals(0),
        );
        expect(
          await summaryStoreB.getUnreadCount('emp-beta', deviceId: deviceA),
          equals(1),
        );

        // 删除 emp-alpha 不影响 emp-beta
        await summaryStoreB.deleteSummary('emp-alpha', deviceId: deviceA);
        expect(
          await summaryStoreB.getSummary('emp-alpha', deviceId: deviceA),
          isNull,
        );
        expect(
          await summaryStoreB.getSummary('emp-beta', deviceId: deviceA),
          isNotNull,
        );
      },
    );
  });
}
