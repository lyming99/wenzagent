/// Spec 和 Todo 同步测试 & 数量查询测试
///
/// 参考前端 wenzflow_flutter 中的 spec/todo 管理逻辑：
/// - chat_controller_base.dart: spec_manage / todo_manage tool call 检测与摘要卡片
/// - data_sync_manager.dart: spec/todo 跨设备同步（broadcast + pull）
/// - host_rpc_methods.dart: RPC 方法注册（methodGetSpecs/SyncSpecs, methodGetTodos/SyncTodos）
///
/// 测试覆盖：
/// 1. Spec 同步（通过 ServerTestFixture RPC）
/// 2. Todo 同步（通过 ServerTestFixture RPC）
/// 3. Spec 数量查询（SpecStore.countByStatus）
/// 4. Todo 数量查询（TodoStore.countTopicsByStatus）
/// 5. 端到端同步（通过 LanTestHarness）
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/host/host_rpc_methods.dart';
import 'package:wenzagent/src/persistence/entities/spec_item_entity.dart';
import 'package:wenzagent/src/persistence/entities/todo_task_item_entity.dart';
import 'package:wenzagent/src/persistence/entities/todo_topic_entity.dart';
import 'package:wenzagent/src/persistence/stores/spec_store.dart';
import 'package:wenzagent/src/persistence/stores/todo_store.dart';

import 'client_test_fixture.dart';
import 'lan_test_harness.dart';
import 'server_test_fixture.dart';

// =============================================================================
// 辅助方法
// =============================================================================

const _employeeId = 'emp-spec-todo-test-001';

/// 创建一个 [SpecItemEntity] 测试实例
SpecItemEntity _createSpec({
  String? id,
  String title = '测试Spec',
  String content = '测试内容',
  String status = 'pending',
  String priority = 'medium',
  String tags = '',
}) {
  final now = DateTime.now();
  return SpecItemEntity(
    id: id ?? 'spec_${now.millisecondsSinceEpoch}_${const Uuid().v4().substring(0, 4)}',
    employeeId: _employeeId,
    title: title,
    content: content,
    status: status,
    priority: priority,
    tags: tags,
    createTime: now,
    updateTime: now,
  );
}

/// 创建一个 [TodoTopicEntity] 测试实例
TodoTopicEntity _createTopic({
  String? id,
  String title = '测试主题',
  String description = '测试描述',
  String status = 'pending',
}) {
  final now = DateTime.now();
  return TodoTopicEntity(
    id: id ?? 'topic_${const Uuid().v4()}',
    employeeId: _employeeId,
    title: title,
    description: description,
    status: status,
    createTime: now,
    updateTime: now,
  );
}

/// 创建一个 [TodoTaskItemEntity] 测试实例
TodoTaskItemEntity _createTaskItem({
  String? id,
  required String topicId,
  String title = '测试子项',
  String content = '测试内容',
  String status = 'pending',
}) {
  final now = DateTime.now();
  return TodoTaskItemEntity(
    id: id ?? 'task_${const Uuid().v4()}',
    employeeId: _employeeId,
    topicId: topicId,
    title: title,
    content: content,
    status: status,
    createTime: now,
    updateTime: now,
  );
}

// =============================================================================
// Tests
// =============================================================================

void main() {
  // ═══════════════════════════════════════════════════════════════
  // Group 1: Spec 同步测试（通过 ServerTestFixture RPC）
  // ═══════════════════════════════════════════════════════════════

  group('Spec 同步测试（ServerTestFixture RPC）', () {
    late ServerTestFixture fixture;

    setUp(() async {
      fixture = await ServerTestFixture.create('spec-sync');
    });

    tearDown(() async {
      await fixture.dispose();
    });

    test('methodSyncSpecs RPC 已注册', () {
      expect(fixture.hasRpcMethod(HostRpcConfig.methodSyncSpecs), isTrue);
      expect(fixture.hasRpcMethod(HostRpcConfig.methodGetSpecs), isTrue);
    });

    test('同步单个 spec → 通过 getSpecs 查询到', () async {
      final spec = _createSpec(title: '需求规格说明书');
      final specMap = spec.toMap();

      // 调用 RPC 同步 spec
      final syncResult = await fixture.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {'specs': [specMap]},
      );
      expect(syncResult['count'], equals(1));

      // 通过 RPC 查询 spec 列表
      final getResult = await fixture.callRpc(
        HostRpcConfig.methodGetSpecs,
        {'employeeId': _employeeId},
      );
      final specs = getResult['specs'] as List;
      expect(specs.length, equals(1));
      expect(specs.first['title'], equals('需求规格说明书'));
      expect(specs.first['status'], equals('pending'));
      expect(specs.first['priority'], equals('medium'));
    });

    test('同步多个 spec → 仅变更项计入 count', () async {
      final spec1 = _createSpec(title: 'Spec A');
      final spec2 = _createSpec(title: 'Spec B');
      final spec3 = _createSpec(title: 'Spec C', priority: 'high');

      // 第一次同步
      final result1 = await fixture.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {'specs': [spec1.toMap(), spec2.toMap(), spec3.toMap()]},
      );
      expect(result1['count'], equals(3));

      // 第二次同步同样的数据（无变更）
      final result2 = await fixture.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {'specs': [spec1.toMap(), spec2.toMap(), spec3.toMap()]},
      );
      expect(result2['count'], equals(0));

      // 验证总数不变
      final getResult = await fixture.callRpc(
        HostRpcConfig.methodGetSpecs,
        {'employeeId': _employeeId},
      );
      expect((getResult['specs'] as List).length, equals(3));
    });

    test('syncSpecs merge - 远程更新已有 spec', () async {
      // 先创建 spec
      final spec = _createSpec(title: '原始标题', content: '原始内容');
      await fixture.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {'specs': [spec.toMap()]},
      );

      // 远程更新（模拟另一设备修改后同步回来）
      final updated = spec.copyWith(
        title: '更新后标题',
        content: '更新后内容',
        status: 'in_progress',
        updateTime: DateTime.now().add(const Duration(minutes: 5)),
      );
      final updateResult = await fixture.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {'specs': [updated.toMap()]},
      );
      expect(updateResult['count'], equals(1));

      // 验证更新
      final getResult = await fixture.callRpc(
        HostRpcConfig.methodGetSpecs,
        {'employeeId': _employeeId},
      );
      final specs = getResult['specs'] as List;
      expect(specs.length, equals(1));
      expect(specs.first['title'], equals('更新后标题'));
      expect(specs.first['content'], equals('更新后内容'));
      expect(specs.first['status'], equals('in_progress'));
    });

    test('syncSpecs merge - updateTime 旧的不覆盖新的', () async {
      final now = DateTime.now();
      final specNew = _createSpec(title: '新版本').copyWith(
        updateTime: now.add(const Duration(minutes: 10)),
      );
      final specOld = _createSpec(title: '旧版本', id: specNew.id).copyWith(
        updateTime: now.subtract(const Duration(minutes: 10)),
      );

      // 先写入新版本
      await fixture.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {'specs': [specNew.toMap()]},
      );

      // 尝试用旧版本覆盖（应被拒绝）
      final result = await fixture.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {'specs': [specOld.toMap()]},
      );
      expect(result['count'], equals(0));

      // 验证仍是新版本
      final getResult = await fixture.callRpc(
        HostRpcConfig.methodGetSpecs,
        {'employeeId': _employeeId},
      );
      final specs = getResult['specs'] as List;
      expect(specs.first['title'], equals('新版本'));
    });

    test('getSpecs 查询不存在的员工返回空列表', () async {
      final result = await fixture.callRpc(
        HostRpcConfig.methodGetSpecs,
        {'employeeId': 'non-existent-employee'},
      );
      final specs = result['specs'] as List;
      expect(specs, isEmpty);
    });

    test('syncSpecs 空列表不报错', () async {
      final result = await fixture.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {'specs': []},
      );
      expect(result['count'], equals(0));
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // Group 2: Todo 同步测试（通过 ServerTestFixture RPC）
  // ═══════════════════════════════════════════════════════════════

  group('Todo 同步测试（ServerTestFixture RPC）', () {
    late ServerTestFixture fixture;

    setUp(() async {
      fixture = await ServerTestFixture.create('todo-sync');
    });

    tearDown(() async {
      await fixture.dispose();
    });

    test('methodSyncTodos RPC 已注册', () {
      expect(fixture.hasRpcMethod(HostRpcConfig.methodSyncTodos), isTrue);
      expect(fixture.hasRpcMethod(HostRpcConfig.methodGetTodos), isTrue);
    });

    test('同步单个 todo topic → 通过 getTodos 查询到', () async {
      final topic = _createTopic(title: '实现用户登录');

      // 调用 RPC 同步 todo
      final syncResult = await fixture.callRpc(
        HostRpcConfig.methodSyncTodos,
        {
          'topics': [topic.toMap()],
          'taskItems': <Map<String, dynamic>>[],
        },
      );
      expect(syncResult['count'], equals(1));

      // 通过 RPC 查询 todo 列表
      final getResult = await fixture.callRpc(
        HostRpcConfig.methodGetTodos,
        {'employeeId': _employeeId},
      );
      final topics = getResult['topics'] as List;
      expect(topics.length, equals(1));
      expect(topics.first['title'], equals('实现用户登录'));
      expect(topics.first['status'], equals('pending'));
    });

    test('同步 topic + taskItems → 查询到完整数据', () async {
      final topic = _createTopic(title: '重构数据层');
      final task1 = _createTaskItem(
        topicId: topic.id,
        title: '设计接口',
        content: '定义所有 DAO 接口',
      );
      final task2 = _createTaskItem(
        topicId: topic.id,
        title: '实现 DAO',
        content: '使用 SQLite 实现',
      );
      final task3 = _createTaskItem(
        topicId: topic.id,
        title: '编写测试',
        status: 'completed',
      );

      // 同步
      final syncResult = await fixture.callRpc(
        HostRpcConfig.methodSyncTodos,
        {
          'topics': [topic.toMap()],
          'taskItems': [task1.toMap(), task2.toMap(), task3.toMap()],
        },
      );
      // topic(1) + taskItems(3) = 4
      expect(syncResult['count'], equals(4));

      // 查询验证
      final getResult = await fixture.callRpc(
        HostRpcConfig.methodGetTodos,
        {'employeeId': _employeeId},
      );
      final topics = getResult['topics'] as List;
      final taskItems = getResult['taskItems'] as List;

      expect(topics.length, equals(1));
      expect(taskItems.length, equals(3));
      expect(
        taskItems.where((t) => t['status'] == 'completed').length,
        equals(1),
      );
      expect(
        taskItems.where((t) => t['status'] == 'pending').length,
        equals(2),
      );
    });

    test('多次同步相同数据不重复计数', () async {
      final topic = _createTopic(title: '持久主题');
      final task = _createTaskItem(topicId: topic.id, title: '持久子项');

      // 第一次
      final r1 = await fixture.callRpc(
        HostRpcConfig.methodSyncTodos,
        {
          'topics': [topic.toMap()],
          'taskItems': [task.toMap()],
        },
      );
      expect(r1['count'], equals(2));

      // 第二次
      final r2 = await fixture.callRpc(
        HostRpcConfig.methodSyncTodos,
        {
          'topics': [topic.toMap()],
          'taskItems': [task.toMap()],
        },
      );
      expect(r2['count'], equals(0));
    });

    test('syncTodos merge - 远程更新 taskItem 状态', () async {
      final topic = _createTopic(title: '状态更新测试');
      final task = _createTaskItem(topicId: topic.id, title: '待执行', status: 'pending');

      // 初始同步
      await fixture.callRpc(
        HostRpcConfig.methodSyncTodos,
        {
          'topics': [topic.toMap()],
          'taskItems': [task.toMap()],
        },
      );

      // 远程更新状态为 completed
      final updatedTask = task.copyWith(
        status: 'completed',
        updateTime: DateTime.now().add(const Duration(minutes: 5)),
      );
      final updateResult = await fixture.callRpc(
        HostRpcConfig.methodSyncTodos,
        {
          'topics': [topic.toMap()],
          'taskItems': [updatedTask.toMap()],
        },
      );
      expect(updateResult['count'], equals(1));

      // 验证
      final getResult = await fixture.callRpc(
        HostRpcConfig.methodGetTodos,
        {'employeeId': _employeeId},
      );
      final taskItems = getResult['taskItems'] as List;
      expect(taskItems.first['status'], equals('completed'));
    });

    test('syncTodos merge - updateTime 旧的 taskItem 不覆盖新的', () async {
      final topic = _createTopic(title: '时间戳保护');
      final now = DateTime.now();
      final taskNew = _createTaskItem(
        topicId: topic.id,
        title: '新状态',
        status: 'completed',
      ).copyWith(updateTime: now.add(const Duration(minutes: 10)));
      final taskOld = _createTaskItem(
        id: taskNew.id,
        topicId: topic.id,
        title: '旧状态',
        status: 'pending',
      ).copyWith(updateTime: now.subtract(const Duration(minutes: 10)));

      // 先写入新版本
      await fixture.callRpc(
        HostRpcConfig.methodSyncTodos,
        {
          'topics': [topic.toMap()],
          'taskItems': [taskNew.toMap()],
        },
      );

      // 尝试用旧版本覆盖
      final result = await fixture.callRpc(
        HostRpcConfig.methodSyncTodos,
        {
          'topics': [topic.toMap()],
          'taskItems': [taskOld.toMap()],
        },
      );
      expect(result['count'], equals(0));

      // 验证仍是新版本
      final getResult = await fixture.callRpc(
        HostRpcConfig.methodGetTodos,
        {'employeeId': _employeeId},
      );
      final taskItems = getResult['taskItems'] as List;
      expect(taskItems.first['status'], equals('completed'));
    });

    test('getTodos 查询不存在的员工返回空列表', () async {
      final result = await fixture.callRpc(
        HostRpcConfig.methodGetTodos,
        {'employeeId': 'ghost-employee'},
      );
      expect(result['topics'] as List, isEmpty);
      expect(result['taskItems'] as List, isEmpty);
    });

    test('syncTodos 空列表不报错', () async {
      final result = await fixture.callRpc(
        HostRpcConfig.methodSyncTodos,
        {'topics': [], 'taskItems': []},
      );
      expect(result['count'], equals(0));
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // Group 3: Spec 数量查询测试（SpecStore.countByStatus）
  // ═══════════════════════════════════════════════════════════════

  group('Spec 数量查询测试（SpecStore.countByStatus）', () {
    late ServerTestFixture fixture;
    late SpecStore specStore;

    setUp(() async {
      fixture = await ServerTestFixture.create('spec-count');
      specStore = SpecStore(deviceId: fixture.deviceId);
    });

    tearDown(() async {
      await fixture.dispose();
    });

    test('空数据 → 所有状态计数为 0', () async {
      final counts = await specStore.countByStatus(_employeeId);
      expect(counts['draft'], equals(0));
      expect(counts['pending'], equals(0));
      expect(counts['in_progress'], equals(0));
      expect(counts['completed'], equals(0));
    });

    test('只有 pending 状态 → 计数正确', () async {
      specStore.save(_createSpec(title: 'Spec P1', status: 'pending'));
      specStore.save(_createSpec(title: 'Spec P2', status: 'pending'));

      final counts = await specStore.countByStatus(_employeeId);
      expect(counts['pending'], equals(2));
      expect(counts['in_progress'], equals(0));
      expect(counts['completed'], equals(0));
      expect(counts['draft'], equals(0));
    });

    test('混合状态 → 各状态计数正确', () async {
      specStore.save(_createSpec(title: 'Draft A', status: 'draft'));
      specStore.save(_createSpec(title: 'Pending A', status: 'pending'));
      specStore.save(_createSpec(title: 'Pending B', status: 'pending'));
      specStore.save(_createSpec(title: 'InProgress A', status: 'in_progress'));
      specStore.save(_createSpec(title: 'Completed A', status: 'completed'));
      specStore.save(_createSpec(title: 'Completed B', status: 'completed'));
      specStore.save(_createSpec(title: 'Completed C', status: 'completed'));

      final counts = await specStore.countByStatus(_employeeId);
      expect(counts['draft'], equals(1));
      expect(counts['pending'], equals(2));
      expect(counts['in_progress'], equals(1));
      expect(counts['completed'], equals(3));
    });

    test('状态变更后计数更新', () async {
      final spec = _createSpec(title: '可变状态', status: 'pending');
      specStore.save(spec);

      // 初始：pending=1
      expect((await specStore.countByStatus(_employeeId))['pending'], equals(1));

      // 通过 RPC 更新状态为 in_progress
      await fixture.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {
          'specs': [
            spec.copyWith(
              status: 'in_progress',
              updateTime: DateTime.now().add(const Duration(seconds: 1)),
            ).toMap(),
          ],
        },
      );

      final newCounts = await specStore.countByStatus(_employeeId);
      expect(newCounts['pending'], equals(0));
      expect(newCounts['in_progress'], equals(1));
    });

    test('已删除的 spec 不计入 countByStatus', () async {
      // 通过 RPC 同步一个 spec
      final spec = _createSpec(title: '将被删除', status: 'pending');
      await fixture.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {'specs': [spec.toMap()]},
      );
      expect((await specStore.countByStatus(_employeeId))['pending'], equals(1));

      // 标记删除（deleted=1）
      await fixture.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {
          'specs': [
            spec.copyWith(
              deleted: 1,
              updateTime: DateTime.now().add(const Duration(seconds: 2)),
            ).toMap(),
          ],
        },
      );

      final counts = await specStore.countByStatus(_employeeId);
      expect(counts['pending'], equals(0));
    });

    test('不同员工的 spec 互不影响', () async {
      specStore.save(_createSpec(title: 'Emp1 Spec'));
      specStore.save(_createSpec(title: 'Emp1 Spec 2'));

      final countsEmp1 = await specStore.countByStatus(_employeeId);
      expect(countsEmp1['pending'], equals(2));

      final countsOther = await specStore.countByStatus('other-employee');
      expect(countsOther['pending'], equals(0));
    });

    test('upsertAllFromRemote 后 countByStatus 正确', () async {
      final specs = [
        _createSpec(title: 'A', status: 'draft'),
        _createSpec(title: 'B', status: 'draft'),
        _createSpec(title: 'C', status: 'pending'),
        _createSpec(title: 'D', status: 'in_progress'),
        _createSpec(title: 'E', status: 'completed'),
      ];

      final changed = specStore.upsertAllFromRemote(specs);
      expect(changed, equals(5));

      final counts = await specStore.countByStatus(_employeeId);
      expect(counts['draft'], equals(2));
      expect(counts['pending'], equals(1));
      expect(counts['in_progress'], equals(1));
      expect(counts['completed'], equals(1));
    });

    test('countAll 返回所有非删除 spec 的总数量（含已完成）', () async {
      expect(await specStore.countAll(_employeeId), equals(0));

      specStore.save(_createSpec(title: 'A', status: 'draft'));
      specStore.save(_createSpec(title: 'B', status: 'pending'));
      specStore.save(_createSpec(title: 'C', status: 'in_progress'));
      specStore.save(_createSpec(title: 'D', status: 'completed'));
      specStore.save(_createSpec(title: 'E', status: 'completed'));

      expect(await specStore.countAll(_employeeId), equals(5));
    });

    test('countAll 等于 countByStatus 各状态之和', () async {
      specStore.save(_createSpec(title: 'X1', status: 'draft'));
      specStore.save(_createSpec(title: 'X2', status: 'pending'));
      specStore.save(_createSpec(title: 'X3', status: 'pending'));
      specStore.save(_createSpec(title: 'X4', status: 'in_progress'));
      specStore.save(_createSpec(title: 'X5', status: 'completed'));
      specStore.save(_createSpec(title: 'X6', status: 'completed'));
      specStore.save(_createSpec(title: 'X7', status: 'completed'));

      final counts = await specStore.countByStatus(_employeeId);
      final sum = counts['draft']! + counts['pending']! +
          counts['in_progress']! + counts['completed']!;
      final total = await specStore.countAll(_employeeId);

      expect(total, equals(sum));
      expect(total, equals(7));
    });

    test('countAll 不计入已删除的 spec', () async {
      final spec = _createSpec(title: '将被删除');
      specStore.save(spec);
      expect(await specStore.countAll(_employeeId), equals(1));

      await fixture.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {
          'specs': [
            spec.copyWith(
              deleted: 1,
              updateTime: DateTime.now().add(const Duration(seconds: 1)),
            ).toMap(),
          ],
        },
      );

      expect(await specStore.countAll(_employeeId), equals(0));
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // Group 4: Todo 数量查询测试（TodoStore.countTopicsByStatus）
  // ═══════════════════════════════════════════════════════════════

  group('Todo 数量查询测试（TodoStore.countTopicsByStatus）', () {
    late ServerTestFixture fixture;
    late TodoStore todoStore;

    setUp(() async {
      fixture = await ServerTestFixture.create('todo-count');
      todoStore = TodoStore(deviceId: fixture.deviceId);
    });

    tearDown(() async {
      await fixture.dispose();
    });

    test('空数据 → 所有状态计数为 0', () async {
      final counts = await todoStore.countTopicsByStatus(_employeeId);
      expect(counts['pending'], equals(0));
      expect(counts['in_progress'], equals(0));
      expect(counts['completed'], equals(0));
    });

    test('只有 pending topic → 计数正确', () async {
      todoStore.saveTopic(_createTopic(title: 'Topic 1', status: 'pending'));
      todoStore.saveTopic(_createTopic(title: 'Topic 2', status: 'pending'));

      final counts = await todoStore.countTopicsByStatus(_employeeId);
      expect(counts['pending'], equals(2));
      expect(counts['in_progress'], equals(0));
      expect(counts['completed'], equals(0));
    });

    test('混合状态 topic → 各状态计数正确', () async {
      todoStore.saveTopic(_createTopic(title: 'P1', status: 'pending'));
      todoStore.saveTopic(_createTopic(title: 'P2', status: 'pending'));
      todoStore.saveTopic(_createTopic(title: 'P3', status: 'pending'));
      todoStore.saveTopic(_createTopic(title: 'IP1', status: 'in_progress'));
      todoStore.saveTopic(_createTopic(title: 'IP2', status: 'in_progress'));
      todoStore.saveTopic(_createTopic(title: 'C1', status: 'completed'));

      final counts = await todoStore.countTopicsByStatus(_employeeId);
      expect(counts['pending'], equals(3));
      expect(counts['in_progress'], equals(2));
      expect(counts['completed'], equals(1));
    });

    test('添加 taskItem 后 topic 状态自动重新计算', () async {
      final topic = _createTopic(title: '自动计算状态');
      todoStore.saveTopic(topic);

      // 添加 pending 任务 → topic 仍是 pending
      final task1 = _createTaskItem(topicId: topic.id, title: 'Task 1', status: 'pending');
      todoStore.saveTaskItem(task1);
      todoStore.recalculateTopicStatus(topic.id);

      expect((await todoStore.countTopicsByStatus(_employeeId))['pending'], equals(1));
      expect((await todoStore.countTopicsByStatus(_employeeId))['in_progress'], equals(0));

      // 添加 in_progress 任务 → topic 变为 in_progress
      final task2 = _createTaskItem(topicId: topic.id, title: 'Task 2', status: 'in_progress');
      todoStore.saveTaskItem(task2);
      todoStore.recalculateTopicStatus(topic.id);

      final countsAfterIP = await todoStore.countTopicsByStatus(_employeeId);
      expect(countsAfterIP['pending'], equals(0));
      expect(countsAfterIP['in_progress'], equals(1));

      // 将所有任务标记为 completed → topic 变为 completed
      todoStore.updateTaskItemStatus(task1.id, 'completed');
      todoStore.updateTaskItemStatus(task2.id, 'completed');
      todoStore.recalculateTopicStatus(topic.id);

      final countsAfterComplete = await todoStore.countTopicsByStatus(_employeeId);
      expect(countsAfterComplete['in_progress'], equals(0));
      expect(countsAfterComplete['completed'], equals(1));
    });

    test('已删除的 topic 不计入 countTopicsByStatus', () async {
      final topic = _createTopic(title: '将被删除');
      todoStore.saveTopic(topic);
      expect((await todoStore.countTopicsByStatus(_employeeId))['pending'], equals(1));

      // 通过 RPC 标记删除
      await fixture.callRpc(
        HostRpcConfig.methodSyncTodos,
        {
          'topics': [
            topic.copyWith(
              deleted: 1,
              updateTime: DateTime.now().add(const Duration(seconds: 2)),
            ).toMap(),
          ],
          'taskItems': <Map<String, dynamic>>[],
        },
      );

      expect((await todoStore.countTopicsByStatus(_employeeId))['pending'], equals(0));
    });

    test('不同员工的 todo topic 互不影响', () async {
      todoStore.saveTopic(_createTopic(title: 'Emp1 Topic'));
      todoStore.saveTopic(_createTopic(title: 'Emp1 Topic 2'));

      expect((await todoStore.countTopicsByStatus(_employeeId))['pending'], equals(2));
      expect((await todoStore.countTopicsByStatus('other-employee'))['pending'], equals(0));
    });

    test('upsertAllTopicsFromRemote 后 countTopicsByStatus 正确', () async {
      final topics = [
        _createTopic(title: 'A', status: 'pending'),
        _createTopic(title: 'B', status: 'pending'),
        _createTopic(title: 'C', status: 'in_progress'),
        _createTopic(title: 'D', status: 'in_progress'),
        _createTopic(title: 'E', status: 'in_progress'),
        _createTopic(title: 'F', status: 'completed'),
      ];

      final changed = todoStore.upsertAllTopicsFromRemote(topics);
      expect(changed, equals(6));

      final counts = await todoStore.countTopicsByStatus(_employeeId);
      expect(counts['pending'], equals(2));
      expect(counts['in_progress'], equals(3));
      expect(counts['completed'], equals(1));
    });

    test('countAllTopics 返回所有非删除 topic 的总数量（含已完成）', () async {
      expect(await todoStore.countAllTopics(_employeeId), equals(0));

      todoStore.saveTopic(_createTopic(title: 'A', status: 'pending'));
      todoStore.saveTopic(_createTopic(title: 'B', status: 'in_progress'));
      todoStore.saveTopic(_createTopic(title: 'C', status: 'completed'));
      todoStore.saveTopic(_createTopic(title: 'D', status: 'completed'));

      expect(await todoStore.countAllTopics(_employeeId), equals(4));
    });

    test('countAllTopics 等于 countTopicsByStatus 各状态之和', () async {
      todoStore.saveTopic(_createTopic(title: 'Y1', status: 'pending'));
      todoStore.saveTopic(_createTopic(title: 'Y2', status: 'pending'));
      todoStore.saveTopic(_createTopic(title: 'Y3', status: 'in_progress'));
      todoStore.saveTopic(_createTopic(title: 'Y4', status: 'completed'));
      todoStore.saveTopic(_createTopic(title: 'Y5', status: 'completed'));

      final counts = await todoStore.countTopicsByStatus(_employeeId);
      final sum = counts['pending']! + counts['in_progress']! + counts['completed']!;
      final total = await todoStore.countAllTopics(_employeeId);

      expect(total, equals(sum));
      expect(total, equals(5));
    });

    test('countAllTopics 不计入已删除的 topic', () async {
      final topic = _createTopic(title: '将被删除');
      todoStore.saveTopic(topic);
      expect(await todoStore.countAllTopics(_employeeId), equals(1));

      await fixture.callRpc(
        HostRpcConfig.methodSyncTodos,
        {
          'topics': [
            topic.copyWith(
              deleted: 1,
              updateTime: DateTime.now().add(const Duration(seconds: 1)),
            ).toMap(),
          ],
          'taskItems': <Map<String, dynamic>>[],
        },
      );

      expect(await todoStore.countAllTopics(_employeeId), equals(0));
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // Group 5: 端到端 Spec/Todo 同步（LanTestHarness）
  // ═══════════════════════════════════════════════════════════════

  group('端到端 Spec/Todo 同步（LanTestHarness）', () {
    late LanTestHarness harness;
    late SpecStore clientSpecStore;
    late SpecStore serverSpecStore;
    late TodoStore clientTodoStore;
    late TodoStore serverTodoStore;

    setUp(() async {
      harness = await LanTestHarness.create('e2e-spec-todo');

      // 注册客户端到 Host
      harness.server.simulateClientConnect(
        clientId: 'client-1',
        clientDeviceId: harness.client.deviceId,
        deviceName: 'E2E Test Client',
      );

      clientSpecStore = SpecStore(deviceId: harness.client.deviceId);
      serverSpecStore = SpecStore(deviceId: harness.server.deviceId);
      clientTodoStore = TodoStore(deviceId: harness.client.deviceId);
      serverTodoStore = TodoStore(deviceId: harness.server.deviceId);
    });

    tearDown(() async {
      await harness.dispose();
    });

    // --- Spec E2E ---

    test('Client 创建 spec → 通过 RPC 同步到 Server', () async {
      // Client 端创建 spec
      final spec = _createSpec(title: 'E2E Spec 测试', status: 'pending');
      clientSpecStore.save(spec);

      // Client 通过 RPC 同步到 Server
      // 模拟 broadcastSpecToAllDevices 的流程
      final syncResult = await harness.server.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {'specs': [spec.toMap()]},
      );
      expect(syncResult['count'], equals(1));

      // Server 端通过 RPC 查询验证
      final getResult = await harness.server.callRpc(
        HostRpcConfig.methodGetSpecs,
        {'employeeId': _employeeId},
      );
      final specsOnServer = getResult['specs'] as List;
      expect(specsOnServer.length, equals(1));
      expect(specsOnServer.first['title'], equals('E2E Spec 测试'));

      // Server 端直接查询 store 验证
      expect((await serverSpecStore.countByStatus(_employeeId))['pending'], equals(1));
    });

    test('Client 创建 spec → Server 查询后 countByStatus 正确', () async {
      // Client 端创建多个不同状态的 spec
      final specs = [
        _createSpec(title: 'E2E Draft', status: 'draft'),
        _createSpec(title: 'E2E Pending 1', status: 'pending'),
        _createSpec(title: 'E2E Pending 2', status: 'pending'),
        _createSpec(title: 'E2E InProgress', status: 'in_progress'),
        _createSpec(title: 'E2E Completed 1', status: 'completed'),
        _createSpec(title: 'E2E Completed 2', status: 'completed'),
      ];
      for (final s in specs) {
        clientSpecStore.save(s);
      }

      // 同步到 Server
      await harness.server.callRpc(
        HostRpcConfig.methodSyncSpecs,
        {'specs': specs.map((s) => s.toMap()).toList()},
      );

      // Server 端 countByStatus
      final counts = await serverSpecStore.countByStatus(_employeeId);
      expect(counts['draft'], equals(1));
      expect(counts['pending'], equals(2));
      expect(counts['in_progress'], equals(1));
      expect(counts['completed'], equals(2));
    });

    // --- Todo E2E ---

    test('Client 创建 todo → 通过 RPC 同步到 Server', () async {
      // Client 端创建 topic + tasks
      final topic = _createTopic(title: 'E2E Todo 测试');
      clientTodoStore.saveTopic(topic);

      final task1 = _createTaskItem(topicId: topic.id, title: 'E2E Task 1');
      final task2 = _createTaskItem(topicId: topic.id, title: 'E2E Task 2', status: 'in_progress');
      final task3 = _createTaskItem(topicId: topic.id, title: 'E2E Task 3', status: 'completed');
      clientTodoStore.saveTaskItem(task1);
      clientTodoStore.saveTaskItem(task2);
      clientTodoStore.saveTaskItem(task3);

      // 同步到 Server
      final syncResult = await harness.server.callRpc(
        HostRpcConfig.methodSyncTodos,
        {
          'topics': [topic.toMap()],
          'taskItems': [task1.toMap(), task2.toMap(), task3.toMap()],
        },
      );
      expect(syncResult['count'], equals(4));

      // Server 端通过 RPC 查询验证
      final getResult = await harness.server.callRpc(
        HostRpcConfig.methodGetTodos,
        {'employeeId': _employeeId},
      );
      final topicsOnServer = getResult['topics'] as List;
      final taskItemsOnServer = getResult['taskItems'] as List;

      expect(topicsOnServer.length, equals(1));
      expect(topicsOnServer.first['title'], equals('E2E Todo 测试'));
      expect(taskItemsOnServer.length, equals(3));
    });

    test('Client 创建 todo → Server 查询后 countTopicsByStatus 正确', () async {
      // Client 端创建多个 topic（不同状态）
      final topic1 = _createTopic(title: 'E2E Pending Topic', status: 'pending');
      final topic2 = _createTopic(title: 'E2E InProgress Topic', status: 'in_progress');
      final topic3 = _createTopic(title: 'E2E Completed Topic', status: 'completed');
      clientTodoStore.saveTopic(topic1);
      clientTodoStore.saveTopic(topic2);
      clientTodoStore.saveTopic(topic3);

      // 同步到 Server
      await harness.server.callRpc(
        HostRpcConfig.methodSyncTodos,
        {
          'topics': [topic1.toMap(), topic2.toMap(), topic3.toMap()],
          'taskItems': <Map<String, dynamic>>[],
        },
      );

      // Server 端 countTopicsByStatus
      final counts = await serverTodoStore.countTopicsByStatus(_employeeId);
      expect(counts['pending'], equals(1));
      expect(counts['in_progress'], equals(1));
      expect(counts['completed'], equals(1));
    });

    test('双向同步：Server 更新 → Client 查询到更新', () async {
      // 先在 Server 端创建 spec
      final spec = _createSpec(title: 'Server Spec');
      serverSpecStore.save(spec);

      // Client 通过 getSpecs 查询到数据（模拟 _doSyncSpecsFromDevices）
      // 这里直接使用 RPC 获取 Server 端的数据
      final getResult = await harness.server.callRpc(
        HostRpcConfig.methodGetSpecs,
        {'employeeId': _employeeId},
      );
      final specsFromServer = (getResult['specs'] as List)
          .map((s) => SpecItemEntity.fromMap(s as Map<String, dynamic>))
          .toList();

      // Client 写入本地
      clientSpecStore.upsertAllFromRemote(specsFromServer);

      // Client 端验证
      expect((await clientSpecStore.countByStatus(_employeeId))['pending'], equals(1));
    });
  });
}
