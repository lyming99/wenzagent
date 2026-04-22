import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/client/cached_agent_proxy.dart';
import 'package:wenzagent/src/agent/entity/agent_event.dart';
import 'package:wenzagent/src/agent/entity/agent_message.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/spec_item_entity.dart';
import 'package:wenzagent/src/persistence/entities/todo_task_item_entity.dart';
import 'package:wenzagent/src/persistence/entities/todo_topic_entity.dart';
import 'package:wenzagent/src/persistence/entities/session_summary_entity.dart';
import 'package:wenzagent/src/persistence/stores/spec_store.dart';
import 'package:wenzagent/src/persistence/stores/todo_store.dart';
import 'package:wenzagent/src/persistence/stores/mark_read_queue_store.dart';
import 'package:wenzagent/src/service/message_store_service.dart';
import 'package:wenzagent/src/shared/chat_message.dart';

// ===== Mock 层 =====

/// 内存模拟 MessageStoreService（复用自 session_window_state_sync_test.dart）
class MockMessageStoreService implements MessageStoreService {
  final Map<String, ChatMessage> _messages = {};
  int _lastSeq = 0;
  int _maxSeq = 0;

  @override
  Future<List<ChatMessage>> getMessages(String deviceId, String employeeId,
          {int? limit, int? offset}) =>
      _getAll();

  @override
  Future<List<ChatMessage>> getMessagesWithDeviceId(
          String deviceId, String employeeId,
          {int? limit, int? offset}) =>
      _getAll();

  Future<List<ChatMessage>> _getAll() async =>
      _messages.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));

  @override
  Future<ChatMessage?> getMessage(String deviceId, String uuid) async =>
      _messages[uuid];

  @override
  Future<ChatMessage> addMessage(String deviceId, ChatMessage message,
      {bool updateWatermark = true}) async {
    _messages[message.id] = message;
    if (updateWatermark) {
      final seq = message.seq > 0 ? message.seq : ++_maxSeq;
      if (seq > _lastSeq) _lastSeq = seq;
      if (seq > _maxSeq) _maxSeq = seq;
    }
    return message;
  }

  @override
  Future<void> addMessages(
          String deviceId, List<ChatMessage> messages) async {
    for (final m in messages) {
      _messages[m.id] = m;
    }
  }

  @override
  Future<void> updateMessage(String deviceId, ChatMessage message,
      {bool updateWatermark = true}) async {
    _messages[message.id] = message;
  }

  @override
  Future<void> updateMessageStatus(
    String deviceId,
    String uuid,
    MessageStatus status, {
    String? error,
  }) async {
    final existing = _messages[uuid];
    if (existing != null) {
      _messages[uuid] = existing.copyWith(status: status);
    }
  }

  @override
  Future<void> batchUpdateMessages(
      String deviceId, List<ChatMessage> messages) async {
    for (final m in messages) {
      _messages[m.id] = m;
    }
  }

  @override
  Future<void> deleteMessages(String deviceId, String employeeId) async {
    _messages.clear();
    _lastSeq = 0;
  }

  @override
  Future<void> softDeleteMessage(String deviceId, String uuid) async {
    final existing = _messages[uuid];
    if (existing != null) {
      _messages[uuid] = existing.copyWith(deleted: true);
    }
  }

  @override
  Future<void> softDeleteBySession(String deviceId, String employeeId) async {
    for (final id in _messages.keys.toList()) {
      _messages[id] = _messages[id]!.copyWith(deleted: true);
    }
  }

  @override
  int deleteMessagesBeforeSeq(
      String deviceId, String employeeId, int beforeSeq) {
    final toDelete = _messages.entries
        .where((e) => e.value.seq > 0 && e.value.seq < beforeSeq)
        .map((e) => e.key)
        .toList();
    for (final id in toDelete) {
      _messages.remove(id);
    }
    return toDelete.length;
  }

  @override
  int getMaxSeq(String deviceId, String employeeId) => _maxSeq;

  @override
  Future<void> hardDeleteMessage(String deviceId, String uuid) async {
    _messages.remove(uuid);
  }

  @override
  Future<ChatMessage?> getLastMessage(String deviceId, String employeeId) =>
      _getAll().then((list) => list.isEmpty ? null : list.last);

  @override
  int getUnreadCount(String deviceId, String employeeId) => _messages.values
      .where((m) => !m.isRead && m.role.name == 'assistant')
      .length;

  @override
  int getTotalUnreadCount({String deviceId = ''}) => 0;

  @override
  SessionSummaryEntity? getLatestMessageSummary(
          String deviceId, String employeeId) =>
      null;

  @override
  List<SessionSummaryEntity> getAllSummaries({String deviceId = ''}) => [];

  @override
  int markAsReadInDb(String deviceId, String employeeId) {
    int count = 0;
    for (final id in _messages.keys.toList()) {
      final m = _messages[id]!;
      if (!m.isRead) {
        _messages[id] = m.copyWith(isRead: true);
        count++;
      }
    }
    return count;
  }

  @override
  int markAsReadBySeqInDb(String deviceId, String employeeId, int readSeq) {
    int count = 0;
    for (final id in _messages.keys.toList()) {
      final m = _messages[id]!;
      if (!m.isRead && m.seq > 0 && m.seq <= readSeq) {
        _messages[id] = m.copyWith(isRead: true);
        count++;
      }
    }
    return count;
  }

  @override
  List<String> getUnreadMessageIds(String deviceId, String employeeId) =>
      _messages.entries
          .where((e) => !e.value.isRead && e.value.role.name == 'assistant')
          .map((e) => e.key)
          .toList();

  @override
  List<String> getStaleLocalToolCallMessages(
          String deviceId, String employeeId) =>
      [];

  @override
  Stream<MessageChangeEvent> get onMessageChanged => Stream.empty();

  @override
  int getLastSeq(String deviceId, String employeeId) => _lastSeq;

  @override
  void updateLastSeq(String deviceId, String employeeId, int lastSeq) {
    if (lastSeq > _lastSeq) _lastSeq = lastSeq;
  }

  @override
  void resetLastSeq(String deviceId, String employeeId, int lastSeq) {
    _lastSeq = lastSeq;
  }

  @override
  void upsertSummaryFromRemote(SessionSummaryEntity remote) {}
}

/// Mock RPC 调用函数
typedef MockRpcHandler = Future<Map<String, dynamic>> Function(
    String method, Map<String, dynamic> params);

int _globalTestCounter = 0;

// ===== 测试 Fixture =====

class SpecTodoTestFixture {
  // === CachedAgentProxy 层 ===
  late final StreamController<AgentEvent> remoteEventController;
  late final MockMessageStoreService messageStore;
  late MockRpcHandler rpcHandler;
  late AgentProxy proxy;
  late CachedAgentProxy cachedProxy;

  // === Store 层（真实 SQLite） ===
  late String testDbPath;
  late String deviceId;
  late SpecStore specStore;
  late TodoStore todoStore;

  // === 测试数据 ===
  final String employeeId;

  // === RPC Mock 数据（可动态设置） ===
  List<Map<String, dynamic>> mockActiveSpecs = [];
  List<Map<String, dynamic>> mockCompletedSpecs = [];
  List<Map<String, dynamic>> mockCurrentTopics = [];
  List<Map<String, dynamic>> mockPendingTopics = [];
  List<Map<String, dynamic>> mockCompletedTopics = [];
  Map<String, List<Map<String, dynamic>>> mockTaskItemsByTopic = {};

  SpecTodoTestFixture({String? employeeId})
      : employeeId = employeeId ?? 'emp-spec-todo-test';

  /// 创建并初始化测试环境
  Future<void> setUp() async {
    _globalTestCounter++;
    remoteEventController = StreamController<AgentEvent>.broadcast();
    messageStore = MockMessageStoreService();

    // 使用唯一 deviceId 创建临时 SQLite 数据库
    deviceId = 'device-test-${const Uuid().v4().substring(0, 8)}';
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_spec_todo_test_$_globalTestCounter';
    await Directory(testDbPath).create(recursive: true);

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    specStore = SpecStore(deviceId: deviceId);
    todoStore = TodoStore(deviceId: deviceId);

    // 设置默认 RPC handler
    rpcHandler = _createDefaultRpcHandler();

    proxy = AgentProxy.remote(
      employeeId: employeeId,
      deviceId: 'device-server-001',
      rpcCall: (method, params) => rpcHandler(method, params),
      remoteEventStream: remoteEventController.stream,
    );

    cachedProxy = CachedAgentProxy(
      proxy: proxy,
      messageStore: messageStore,
      deviceId: deviceId,
      employeeId: employeeId,
      markReadQueueStore: _NoopMarkReadQueueStore(),
    );

    await cachedProxy.initialize();
  }

  /// 创建默认 RPC handler，支持 Spec/Todo RPC 方法
  MockRpcHandler _createDefaultRpcHandler() {
    return (String method, Map<String, dynamic> params) async {
      switch (method) {
        case 'agentGetState':
          return AgentStateSnapshot.idle().toMap();
        case 'agentGetPendingPermission':
          return {};
        case 'agentGetPendingConfirm':
          return {};
        case 'agentGetProvider':
          return {};
        case 'agentGetProjectUuid':
          return {'projectUuid': null};
        case 'agentGetSkills':
          return {'skills': []};
        case 'agentGetMcpConfigs':
          return {'mcpConfigs': []};
        case 'agentGetMaxSeq':
          return {'maxSeq': 0};
        case 'agentGetClearSeq':
          return {'clearSeq': 0};
        case 'agentGetMessagesAfterSeq':
          return {'messages': []};
        case 'agentGetSessionSummary':
          return {};
        // ===== Spec RPC =====
        case 'agentGetActiveSpecs':
          return {'specs': mockActiveSpecs};
        case 'agentGetCompletedSpecs':
          return {'specs': mockCompletedSpecs};
        // ===== Todo RPC =====
        case 'agentGetCurrentTopics':
          return {'topics': mockCurrentTopics};
        case 'agentGetPendingTopics':
          return {'topics': mockPendingTopics};
        case 'agentGetCompletedTopics':
          return {'topics': mockCompletedTopics};
        case 'agentGetTaskItemsByTopic':
          final topicId = params['topicId'] as String?;
          // 注意：RPC 实际返回的 key 是 'tasks'，不是 'taskItems'
          return {'tasks': mockTaskItemsByTopic[topicId] ?? []};
        default:
          return {};
      }
    };
  }

  /// 清理测试环境
  Future<void> tearDown() async {
    await cachedProxy.dispose();
    await proxy.dispose();
    await remoteEventController.close();

    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  }

  /// 发送远程事件（模拟 LAN 广播）
  void sendRemoteEvent(AgentEvent event) {
    remoteEventController.add(event);
  }

  /// 等待事件处理完成（让 microtask 和 Timer 执行）
  Future<void> flush() async {
    await Future.delayed(const Duration(milliseconds: 50));
  }

  /// 等待去抖定时器触发
  Future<void> flushDebounce() async {
    await Future.delayed(const Duration(milliseconds: 600));
  }

  // ===== 辅助方法：创建测试数据 =====

  /// 创建 Spec Map（模拟 RPC 返回数据）
  Map<String, dynamic> createSpecMap({
    String? id,
    String? title,
    String? content,
    String? status,
    String? priority,
    int? deleted,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return {
      'id': id ?? const Uuid().v4(),
      'employeeId': employeeId,
      'title': title ?? '测试Spec',
      'content': content ?? 'Spec内容描述',
      'status': status ?? 'pending',
      'priority': priority ?? 'medium',
      'tags': '',
      'sortOrder': 0,
      'deleted': deleted ?? 0,
      'createTime':
          (createTime ?? now).millisecondsSinceEpoch,
      'updateTime':
          (updateTime ?? now).millisecondsSinceEpoch,
    };
  }

  /// 创建 TodoTopic Map（模拟 RPC 返回数据）
  Map<String, dynamic> createTopicMap({
    String? id,
    String? title,
    String? description,
    String? status,
    int? deleted,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return {
      'id': id ?? const Uuid().v4(),
      'employeeId': employeeId,
      'title': title ?? '测试主题',
      'description': description ?? '主题描述',
      'status': status ?? 'pending',
      'sortOrder': 0,
      'deleted': deleted ?? 0,
      'createTime':
          (createTime ?? now).millisecondsSinceEpoch,
      'updateTime':
          (updateTime ?? now).millisecondsSinceEpoch,
    };
  }

  /// 创建 TodoTaskItem Map（模拟 RPC 返回数据）
  Map<String, dynamic> createTaskItemMap({
    String? id,
    required String topicId,
    String? title,
    String? content,
    String? status,
    int? deleted,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return {
      'id': id ?? const Uuid().v4(),
      'employeeId': employeeId,
      'topicId': topicId,
      'title': title ?? '测试子项',
      'content': content ?? '子项内容',
      'status': status ?? 'pending',
      'sortOrder': 0,
      'deleted': deleted ?? 0,
      'createTime':
          (createTime ?? now).millisecondsSinceEpoch,
      'updateTime':
          (updateTime ?? now).millisecondsSinceEpoch,
    };
  }
}

/// 空操作 MarkReadQueueStore
class _NoopMarkReadQueueStore extends MarkReadQueueStore {
  _NoopMarkReadQueueStore() : super(deviceId: '');

  @override
  void enqueue({
    required String employeeId,
    required String readerDeviceId,
    List<String>? messageIds,
  }) {}

  @override
  List<MarkReadQueueEntry> getPending({String? employeeId}) => [];

  @override
  void removeAll(List<int> ids) {}

  @override
  void clear({String? employeeId}) {}
}

// ===== 测试主体 =====

void main() {
  group('会话窗口 Spec/Todo 数据同步测试', () {
    late SpecTodoTestFixture fixture;

    setUp(() async {
      fixture = SpecTodoTestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    // ============================================================
    // 1. Spec 数据同步 - 同步路径1：event(lan广播+event)>update store
    // ============================================================

    group('Spec数据同步 - 同步路径1：event(lan广播+event)>update store', () {
      test('specChanged 事件触发 onMessagesChanged 通知', () async {
        // 监听 onMessagesChanged 流
        final notifications = <List<AgentMessage>>[];
        final sub = fixture.cachedProxy.onMessagesChanged.listen(notifications.add);

        // 发送 specChanged 事件（模拟 LAN 广播）
        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.specChanged,
          data: {},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        // 验证：onMessagesChanged 被触发（事件路径仅通知 UI 刷新）
        expect(notifications, isNotEmpty,
            reason: 'specChanged 事件应触发 onMessagesChanged 通知');

        await sub.cancel();
      });

      test('specChanged 事件不修改 currentProcessingMessageId 等状态', () async {
        // 确保 initial state 为空
        expect(fixture.cachedProxy.currentProcessingMessageId, isNull);
        expect(fixture.cachedProxy.queuedMessageIds, isEmpty);
        expect(fixture.cachedProxy.callingToolIds, isEmpty);

        // 发送 specChanged 事件
        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.specChanged,
          data: {},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        // 验证：聊天状态缓存不受影响
        expect(fixture.cachedProxy.currentProcessingMessageId, isNull);
        expect(fixture.cachedProxy.queuedMessageIds, isEmpty);
        expect(fixture.cachedProxy.callingToolIds, isEmpty);
      });

      test('不同 employeeId 的 specChanged 事件被过滤', () async {
        final notifications = <List<AgentMessage>>[];
        final sub = fixture.cachedProxy.onMessagesChanged.listen(notifications.add);

        // 先清空初始化时产生的通知
        await fixture.flush();
        notifications.clear();

        // 发送其他 employeeId 的 specChanged 事件
        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.specChanged,
          data: {},
          employeeId: 'other-employee-999',
        ));
        await fixture.flush();

        // 验证：不应触发通知（employeeId 不匹配）
        expect(notifications, isEmpty,
            reason: '不同 employeeId 的 specChanged 事件应被过滤');

        await sub.cancel();
      });

      test('连续多个 specChanged 事件均触发通知', () async {
        final notifications = <List<AgentMessage>>[];
        final sub = fixture.cachedProxy.onMessagesChanged.listen(notifications.add);

        // 连续发送 3 次 specChanged 事件
        for (int i = 0; i < 3; i++) {
          fixture.sendRemoteEvent(AgentEvent(
            type: AgentEventType.specChanged,
            data: {'index': i},
            employeeId: fixture.employeeId,
          ));
          await fixture.flush();
        }

        // 验证：每次事件都应触发通知
        expect(notifications.length, greaterThanOrEqualTo(3),
            reason: '连续多个 specChanged 事件应均触发通知');

        await sub.cancel();
      });
    });

    // ============================================================
    // 2. Spec 数据同步 - 同步路径2：query>update store
    // ============================================================

    group('Spec数据同步 - 同步路径2：query>update store', () {
      test('syncFromRemote 后本地 SpecStore 包含远端所有活跃 Spec', () async {
        // 设置 Mock RPC 返回 3 个 active spec
        fixture.mockActiveSpecs = [
          fixture.createSpecMap(id: 'spec-1', title: 'Spec 1', status: 'pending'),
          fixture.createSpecMap(id: 'spec-2', title: 'Spec 2', status: 'in_progress'),
          fixture.createSpecMap(id: 'spec-3', title: 'Spec 3', status: 'draft'),
        ];
        fixture.mockCompletedSpecs = [];

        // 调用 syncFromRemote
        await fixture.cachedProxy.syncFromRemote();

        // 验证：本地 SpecStore 包含 3 条活跃 Spec
        final activeSpecs = fixture.specStore.findActiveByEmployee(fixture.employeeId);
        expect(activeSpecs.length, equals(3));
        expect(activeSpecs.map((s) => s.id).toSet(),
            equals({'spec-1', 'spec-2', 'spec-3'}));
      });

      test('syncFromRemote 后本地 SpecStore 包含远端已完成 Spec', () async {
        // 设置 Mock RPC 返回 2 个 completed spec
        fixture.mockActiveSpecs = [];
        fixture.mockCompletedSpecs = [
          fixture.createSpecMap(id: 'spec-c1', title: 'Completed 1', status: 'completed'),
          fixture.createSpecMap(id: 'spec-c2', title: 'Completed 2', status: 'completed'),
        ];

        await fixture.cachedProxy.syncFromRemote();

        // 验证
        final completedSpecs =
            fixture.specStore.findCompletedByEmployee(fixture.employeeId);
        expect(completedSpecs.length, equals(2));
        expect(completedSpecs.map((s) => s.id).toSet(),
            equals({'spec-c1', 'spec-c2'}));
      });

      test('syncFromRemote 合并活跃和已完成 Spec', () async {
        fixture.mockActiveSpecs = [
          fixture.createSpecMap(id: 'spec-a1', title: 'Active 1', status: 'pending'),
          fixture.createSpecMap(id: 'spec-a2', title: 'Active 2', status: 'in_progress'),
        ];
        fixture.mockCompletedSpecs = [
          fixture.createSpecMap(id: 'spec-c1', title: 'Completed 1', status: 'completed'),
        ];

        await fixture.cachedProxy.syncFromRemote();

        // 验证：findAllByEmployee 返回所有 spec
        final allSpecs = fixture.specStore.findAllByEmployee(fixture.employeeId);
        expect(allSpecs.length, equals(3));
      });

      test('syncFromRemote 空 RPC 返回不修改本地 Store', () async {
        // 先写入一些本地数据
        final now = DateTime.now();
        fixture.specStore.save(SpecItemEntity(
          id: 'local-spec-1',
          employeeId: fixture.employeeId,
          title: '本地Spec',
          status: 'pending',
          createTime: now,
          updateTime: now,
        ));

        // 设置 Mock RPC 返回空列表
        fixture.mockActiveSpecs = [];
        fixture.mockCompletedSpecs = [];

        await fixture.cachedProxy.syncFromRemote();

        // 验证：本地数据不变（空 RPC 不清除已有数据）
        final allSpecs = fixture.specStore.findAllByEmployee(fixture.employeeId);
        expect(allSpecs.length, equals(1));
        expect(allSpecs.first.id, equals('local-spec-1'));
      });

      test('多次 syncFromRemote 幂等（不产生数据漂移）', () async {
        fixture.mockActiveSpecs = [
          fixture.createSpecMap(id: 'spec-1', title: 'Spec 1'),
          fixture.createSpecMap(id: 'spec-2', title: 'Spec 2'),
        ];
        fixture.mockCompletedSpecs = [];

        // 连续调用 3 次 syncFromRemote
        for (int i = 0; i < 3; i++) {
          await fixture.cachedProxy.syncFromRemote();
        }

        // 验证：数据条数和内容不变
        final allSpecs = fixture.specStore.findAllByEmployee(fixture.employeeId);
        expect(allSpecs.length, equals(2));
      });

      test('SpecItemEntity.fromMap 序列化往返一致', () async {
        final now = DateTime.now();
        final original = SpecItemEntity(
          id: 'spec-roundtrip',
          employeeId: fixture.employeeId,
          title: '往返测试',
          content: '详细内容',
          status: 'in_progress',
          priority: 'high',
          tags: 'tag1,tag2',
          sortOrder: 5,
          deleted: 0,
          createTime: now,
          updateTime: now,
        );

        // toMap → fromMap 往返
        final map = original.toMap();
        final restored = SpecItemEntity.fromMap(map);

        expect(restored.id, equals(original.id));
        expect(restored.employeeId, equals(original.employeeId));
        expect(restored.title, equals(original.title));
        expect(restored.content, equals(original.content));
        expect(restored.status, equals(original.status));
        expect(restored.priority, equals(original.priority));
        expect(restored.tags, equals(original.tags));
        expect(restored.sortOrder, equals(original.sortOrder));
        expect(restored.deleted, equals(original.deleted));
      });
    });

    // ============================================================
    // 3. Todo 数据同步 - 同步路径1：event(lan广播+event)>update store
    // ============================================================

    group('Todo数据同步 - 同步路径1：event(lan广播+event)>update store', () {
      test('todoTopicChanged 事件触发 onMessagesChanged 通知', () async {
        final notifications = <List<AgentMessage>>[];
        final sub = fixture.cachedProxy.onMessagesChanged.listen(notifications.add);

        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.todoTopicChanged,
          data: {},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        expect(notifications, isNotEmpty,
            reason: 'todoTopicChanged 事件应触发 onMessagesChanged 通知');

        await sub.cancel();
      });

      test('todoTaskItemChanged 事件触发 onMessagesChanged 通知', () async {
        final notifications = <List<AgentMessage>>[];
        final sub = fixture.cachedProxy.onMessagesChanged.listen(notifications.add);

        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.todoTaskItemChanged,
          data: {},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        expect(notifications, isNotEmpty,
            reason: 'todoTaskItemChanged 事件应触发 onMessagesChanged 通知');

        await sub.cancel();
      });

      test('todoTopicChanged 和 todoTaskItemChanged 事件互不干扰', () async {
        final notifications = <List<AgentMessage>>[];
        final sub = fixture.cachedProxy.onMessagesChanged.listen(notifications.add);

        // 交替发送两种事件
        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.todoTopicChanged,
          data: {'index': 0},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.todoTaskItemChanged,
          data: {'index': 1},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.todoTopicChanged,
          data: {'index': 2},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        // 验证：每次事件都触发通知
        expect(notifications.length, greaterThanOrEqualTo(3),
            reason: '交替发送的 todo 事件应均触发通知');

        await sub.cancel();
      });

      test('不同 employeeId 的 todo 事件被过滤', () async {
        final notifications = <List<AgentMessage>>[];
        final sub = fixture.cachedProxy.onMessagesChanged.listen(notifications.add);

        // 先清空初始化时产生的通知
        await fixture.flush();
        notifications.clear();

        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.todoTopicChanged,
          data: {},
          employeeId: 'other-employee-888',
        ));
        await fixture.flush();

        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.todoTaskItemChanged,
          data: {},
          employeeId: 'other-employee-888',
        ));
        await fixture.flush();

        expect(notifications, isEmpty,
            reason: '不同 employeeId 的 todo 事件应被过滤');

        await sub.cancel();
      });
    });

    // ============================================================
    // 4. Todo 数据同步 - 同步路径2：query>update store
    // ============================================================

    group('Todo数据同步 - 同步路径2：query>update store', () {
      test('syncFromRemote 后本地 TodoStore 包含远端所有 Topic', () async {
        // 设置 Mock RPC 返回 pending + completed topics
        final topicId1 = 'topic-1';
        final topicId2 = 'topic-2';
        final topicId3 = 'topic-3';

        fixture.mockPendingTopics = [
          fixture.createTopicMap(id: topicId2, title: '待处理主题', status: 'pending'),
          fixture.createTopicMap(id: topicId1, title: '当前主题', status: 'in_progress'),
        ];
        fixture.mockCurrentTopics = [];
        fixture.mockCompletedTopics = [
          fixture.createTopicMap(id: topicId3, title: '已完成主题', status: 'completed'),
        ];

        await fixture.cachedProxy.syncFromRemote();

        // 验证：各状态查询（pending 仅含 pending，不含 in_progress）
        final currentTopics =
            fixture.todoStore.findCurrentTopics(fixture.employeeId);
        expect(currentTopics.length, equals(1));
        expect(currentTopics.first.id, equals(topicId1));

        final pendingTopics =
            fixture.todoStore.findPendingTopics(fixture.employeeId);
        // pending 查询仅返回 pending 状态的 topics（不含 in_progress）
        expect(pendingTopics.length, equals(1));
        expect(pendingTopics.first.id, equals(topicId2));

        final completedTopics =
            fixture.todoStore.findCompletedTopics(fixture.employeeId);
        expect(completedTopics.length, equals(1));
        expect(completedTopics.first.id, equals(topicId3));
      });

      test('syncFromRemote 后 Topic 去重正确', () async {
        // pending 和 completed 结果集天然无交集（status 不同），无需去重
        final topicId1 = 'topic-dup-1';
        final topicId2 = 'topic-dup-2';

        fixture.mockPendingTopics = [
          fixture.createTopicMap(id: topicId1, title: '待处理主题', status: 'pending'),
          fixture.createTopicMap(id: topicId2, title: '进行中主题', status: 'in_progress'),
        ];
        fixture.mockCurrentTopics = [];
        fixture.mockCompletedTopics = [
          fixture.createTopicMap(id: 'topic-done', title: '已完成主题', status: 'completed'),
        ];

        await fixture.cachedProxy.syncFromRemote();

        // 验证：3 个 topic 全部同步到本地
        final allTopics =
            fixture.todoStore.findAllTopics(fixture.employeeId);
        expect(allTopics.length, equals(3));
      });

      test('syncFromRemote 后每个 Topic 的 TaskItems 正确同步', () async {
        final topicId1 = 'topic-task-1';
        final topicId2 = 'topic-task-2';

        fixture.mockPendingTopics = [
          fixture.createTopicMap(id: topicId1, title: '主题1', status: 'pending'),
          fixture.createTopicMap(id: topicId2, title: '主题2', status: 'pending'),
        ];
        fixture.mockCurrentTopics = [];
        fixture.mockCompletedTopics = [];

        // 每个 topic 各 3 个 taskItem
        fixture.mockTaskItemsByTopic = {
          topicId1: [
            fixture.createTaskItemMap(id: 'task-1-1', topicId: topicId1, title: '任务1-1'),
            fixture.createTaskItemMap(id: 'task-1-2', topicId: topicId1, title: '任务1-2'),
            fixture.createTaskItemMap(id: 'task-1-3', topicId: topicId1, title: '任务1-3'),
          ],
          topicId2: [
            fixture.createTaskItemMap(id: 'task-2-1', topicId: topicId2, title: '任务2-1'),
            fixture.createTaskItemMap(id: 'task-2-2', topicId: topicId2, title: '任务2-2'),
            fixture.createTaskItemMap(id: 'task-2-3', topicId: topicId2, title: '任务2-3'),
          ],
        };

        await fixture.cachedProxy.syncFromRemote();

        // 验证：每个 topic 的 taskItems
        final items1 = fixture.todoStore.findTaskItemsByTopic(topicId1);
        expect(items1.length, equals(3));
        expect(items1.map((i) => i.id).toSet(),
            equals({'task-1-1', 'task-1-2', 'task-1-3'}));

        final items2 = fixture.todoStore.findTaskItemsByTopic(topicId2);
        expect(items2.length, equals(3));
        expect(items2.map((i) => i.id).toSet(),
            equals({'task-2-1', 'task-2-2', 'task-2-3'}));
      });

      test('syncFromRemote 空 RPC 返回不修改本地 Store', () async {
        // 先写入一些本地数据
        final now = DateTime.now();
        fixture.todoStore.saveTopic(TodoTopicEntity(
          id: 'local-topic-1',
          employeeId: fixture.employeeId,
          title: '本地主题',
          createTime: now,
          updateTime: now,
        ));

        // 设置 Mock RPC 返回空列表
        fixture.mockCurrentTopics = [];
        fixture.mockPendingTopics = [];
        fixture.mockCompletedTopics = [];

        await fixture.cachedProxy.syncFromRemote();

        // 验证：本地数据不变
        final allTopics =
            fixture.todoStore.findAllTopics(fixture.employeeId);
        expect(allTopics.length, equals(1));
        expect(allTopics.first.id, equals('local-topic-1'));
      });

      test('多次 syncFromRemote 幂等', () async {
        fixture.mockPendingTopics = [
          fixture.createTopicMap(id: 'topic-1', title: '主题1'),
          fixture.createTopicMap(id: 'topic-2', title: '主题2'),
        ];
        fixture.mockCurrentTopics = [];
        fixture.mockCompletedTopics = [];
        fixture.mockTaskItemsByTopic = {};

        // 连续调用 3 次
        for (int i = 0; i < 3; i++) {
          await fixture.cachedProxy.syncFromRemote();
        }

        // 验证：数据不变
        final allTopics =
            fixture.todoStore.findAllTopics(fixture.employeeId);
        expect(allTopics.length, equals(2));
      });

      test('TodoTopicEntity 序列化往返一致', () {
        final now = DateTime.now();
        final original = TodoTopicEntity(
          id: 'topic-roundtrip',
          employeeId: fixture.employeeId,
          title: '往返测试主题',
          description: '描述内容',
          status: 'in_progress',
          sortOrder: 3,
          deleted: 0,
          createTime: now,
          updateTime: now,
          completedAt: null,
        );

        final map = original.toMap();
        final restored = TodoTopicEntity.fromMap(map);

        expect(restored.id, equals(original.id));
        expect(restored.employeeId, equals(original.employeeId));
        expect(restored.title, equals(original.title));
        expect(restored.description, equals(original.description));
        expect(restored.status, equals(original.status));
        expect(restored.sortOrder, equals(original.sortOrder));
        expect(restored.deleted, equals(original.deleted));
      });

      test('TodoTaskItemEntity 序列化往返一致', () {
        final now = DateTime.now();
        final original = TodoTaskItemEntity(
          id: 'task-roundtrip',
          employeeId: fixture.employeeId,
          topicId: 'topic-1',
          title: '往返测试任务',
          content: '任务内容',
          status: 'completed',
          sortOrder: 2,
          deleted: 0,
          createTime: now,
          updateTime: now,
          completedAt: now,
        );

        final map = original.toMap();
        final restored = TodoTaskItemEntity.fromMap(map);

        expect(restored.id, equals(original.id));
        expect(restored.employeeId, equals(original.employeeId));
        expect(restored.topicId, equals(original.topicId));
        expect(restored.title, equals(original.title));
        expect(restored.content, equals(original.content));
        expect(restored.status, equals(original.status));
        expect(restored.deleted, equals(original.deleted));
      });
    });

    // ============================================================
    // 5. 双路径协作 - Spec/Todo 同步
    // ============================================================

    group('双路径协作 - Spec/Todo 同步', () {
      test('先 Event 通知后 Query 全量同步，Spec 数据完整', () async {
        final notifications = <List<AgentMessage>>[];
        final sub = fixture.cachedProxy.onMessagesChanged.listen(notifications.add);

        // 步骤1：发送 specChanged 事件（触发 UI 刷新通知）
        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.specChanged,
          data: {},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        // 验证：Event 路径已触发通知
        expect(notifications, isNotEmpty);

        // 步骤2：syncFromRemote 拉取全量 Spec 数据
        fixture.mockActiveSpecs = [
          fixture.createSpecMap(id: 'spec-1', title: 'Spec 1'),
          fixture.createSpecMap(id: 'spec-2', title: 'Spec 2'),
        ];
        fixture.mockCompletedSpecs = [];

        await fixture.cachedProxy.syncFromRemote();

        // 验证：SpecStore 数据完整
        final specs =
            fixture.specStore.findActiveByEmployee(fixture.employeeId);
        expect(specs.length, equals(2));

        await sub.cancel();
      });

      test('先 Event 通知后 Query 全量同步，Todo 数据完整', () async {
        final notifications = <List<AgentMessage>>[];
        final sub = fixture.cachedProxy.onMessagesChanged.listen(notifications.add);

        // 步骤1：发送 todoTopicChanged 事件
        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.todoTopicChanged,
          data: {},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        expect(notifications, isNotEmpty);

        // 步骤2：syncFromRemote 拉取全量 Todo 数据
        final topicId = 'topic-coop-1';
        fixture.mockPendingTopics = [
          fixture.createTopicMap(id: topicId, title: '协作主题', status: 'in_progress'),
        ];
        fixture.mockCurrentTopics = [];
        fixture.mockCompletedTopics = [];
        fixture.mockTaskItemsByTopic = {
          topicId: [
            fixture.createTaskItemMap(
                id: 'task-coop-1', topicId: topicId, title: '协作任务'),
          ],
        };

        await fixture.cachedProxy.syncFromRemote();

        // 验证：TodoStore 数据完整
        final topics =
            fixture.todoStore.findCurrentTopics(fixture.employeeId);
        expect(topics.length, equals(1));
        expect(topics.first.id, equals(topicId));

        final items = fixture.todoStore.findTaskItemsByTopic(topicId);
        expect(items.length, equals(1));
        expect(items.first.id, equals('task-coop-1'));

        await sub.cancel();
      });

      test('Query 同步后 Event 增量通知，UI 正确刷新', () async {
        // 步骤1：先全量同步
        fixture.mockActiveSpecs = [
          fixture.createSpecMap(id: 'spec-1', title: 'Spec 1'),
        ];
        fixture.mockPendingTopics = [
          fixture.createTopicMap(id: 'topic-1', title: 'Topic 1', status: 'pending'),
        ];
        fixture.mockCurrentTopics = [];
        fixture.mockCompletedTopics = [];
        fixture.mockCompletedSpecs = [];
        fixture.mockTaskItemsByTopic = {};

        await fixture.cachedProxy.syncFromRemote();

        // 步骤2：后续变更通过 Event 通知
        final notifications = <List<AgentMessage>>[];
        final sub = fixture.cachedProxy.onMessagesChanged.listen(notifications.add);

        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.specChanged,
          data: {},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.todoTopicChanged,
          data: {},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        // 验证：两次 Event 通知都触发
        expect(notifications.length, greaterThanOrEqualTo(2));

        await sub.cancel();
      });

      test('Spec 和 Todo 混合变更场景', () async {
        final notifications = <List<AgentMessage>>[];
        final sub = fixture.cachedProxy.onMessagesChanged.listen(notifications.add);

        // 先清空初始化时产生的通知
        await fixture.flush();
        notifications.clear();

        // 同时发送 Spec 和 Todo 变更事件
        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.specChanged,
          data: {},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();
        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.todoTopicChanged,
          data: {},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();
        fixture.sendRemoteEvent(AgentEvent(
          type: AgentEventType.todoTaskItemChanged,
          data: {},
          employeeId: fixture.employeeId,
        ));
        await fixture.flush();

        // 验证：所有事件都触发通知
        expect(notifications.length, greaterThanOrEqualTo(3),
            reason: 'Spec 和 Todo 混合变更事件应均触发通知');

        // 然后全量同步
        fixture.mockActiveSpecs = [
          fixture.createSpecMap(id: 'spec-mix-1', title: '混合Spec'),
        ];
        fixture.mockCompletedSpecs = [];
        fixture.mockPendingTopics = [
          fixture.createTopicMap(id: 'topic-mix-1', title: '混合Topic', status: 'pending'),
        ];
        fixture.mockCurrentTopics = [];
        fixture.mockCompletedTopics = [];
        fixture.mockTaskItemsByTopic = {};

        await fixture.cachedProxy.syncFromRemote();

        // 验证：Store 数据正确
        expect(
            fixture.specStore.findActiveByEmployee(fixture.employeeId).length,
            equals(1));
        // 使用 findAllTopics 因为 topic-mix-1 状态是 pending，不在 findCurrentTopics 结果中
        expect(
            fixture.todoStore.findAllTopics(fixture.employeeId).length,
            equals(1));

        await sub.cancel();
      });
    });

    // ============================================================
    // 6. 数据合并策略 - upsertFromRemote
    // ============================================================

    group('数据合并策略 - upsertFromRemote', () {
      test('远端较新的 Spec 覆盖本地旧数据', () async {
        final now = DateTime.now();
        final oldTime = now.subtract(const Duration(hours: 1));
        final newTime = now.add(const Duration(hours: 1));

        // 本地写入旧数据
        fixture.specStore.save(SpecItemEntity(
          id: 'spec-merge-1',
          employeeId: fixture.employeeId,
          title: '旧标题',
          status: 'pending',
          createTime: now,
          updateTime: oldTime,
        ));

        // Mock RPC 返回较新的数据
        fixture.mockActiveSpecs = [
          fixture.createSpecMap(
            id: 'spec-merge-1',
            title: '新标题',
            status: 'in_progress',
            updateTime: newTime,
          ),
        ];
        fixture.mockCompletedSpecs = [];

        await fixture.cachedProxy.syncFromRemote();

        // 验证：本地数据被远端覆盖
        final spec = fixture.specStore.findById('spec-merge-1');
        expect(spec, isNotNull);
        expect(spec!.title, equals('新标题'));
        expect(spec.status, equals('in_progress'));
      });

      test('远端较旧的 Spec 不覆盖本地新数据', () async {
        final now = DateTime.now();
        final oldTime = now.subtract(const Duration(hours: 1));
        final newTime = now.add(const Duration(hours: 1));

        // 本地写入新数据
        fixture.specStore.save(SpecItemEntity(
          id: 'spec-merge-2',
          employeeId: fixture.employeeId,
          title: '本地新标题',
          status: 'in_progress',
          createTime: now,
          updateTime: newTime,
        ));

        // Mock RPC 返回较旧的数据
        fixture.mockActiveSpecs = [
          fixture.createSpecMap(
            id: 'spec-merge-2',
            title: '远端旧标题',
            status: 'pending',
            updateTime: oldTime,
          ),
        ];
        fixture.mockCompletedSpecs = [];

        await fixture.cachedProxy.syncFromRemote();

        // 验证：本地数据未被覆盖
        final spec = fixture.specStore.findById('spec-merge-2');
        expect(spec, isNotNull);
        expect(spec!.title, equals('本地新标题'));
        expect(spec.status, equals('in_progress'));
      });

      test('远端软删除的 Spec 正确同步到本地', () async {
        // 先在本地创建一个 spec
        fixture.specStore.save(SpecItemEntity(
          id: 'spec-del-1',
          employeeId: fixture.employeeId,
          title: '待删除Spec',
          status: 'pending',
          createTime: DateTime.now(),
          updateTime: DateTime.now().subtract(const Duration(hours: 1)),
        ));

        // Mock RPC 返回已软删除的 spec
        fixture.mockActiveSpecs = [
          fixture.createSpecMap(
            id: 'spec-del-1',
            title: '待删除Spec',
            deleted: 1,
            updateTime: DateTime.now(),
          ),
        ];
        fixture.mockCompletedSpecs = [];

        await fixture.cachedProxy.syncFromRemote();

        // 验证：活跃 spec 中不包含已删除的
        final activeSpecs =
            fixture.specStore.findActiveByEmployee(fixture.employeeId);
        expect(activeSpecs.where((s) => s.id == 'spec-del-1'), isEmpty);
      });

      test('远端较新的 TodoTopic 覆盖本地旧数据', () async {
        final now = DateTime.now();
        final oldTime = now.subtract(const Duration(hours: 1));
        final newTime = now.add(const Duration(hours: 1));

        // 本地写入旧数据
        fixture.todoStore.saveTopic(TodoTopicEntity(
          id: 'topic-merge-1',
          employeeId: fixture.employeeId,
          title: '旧主题',
          status: 'pending',
          createTime: now,
          updateTime: oldTime,
        ));

        // Mock RPC 返回较新的数据
        fixture.mockPendingTopics = [
          fixture.createTopicMap(
            id: 'topic-merge-1',
            title: '新主题',
            status: 'in_progress',
            updateTime: newTime,
          ),
        ];
        fixture.mockCurrentTopics = [];
        fixture.mockCompletedTopics = [];

        await fixture.cachedProxy.syncFromRemote();

        // 验证
        final topic = fixture.todoStore.findTopicById('topic-merge-1');
        expect(topic, isNotNull);
        expect(topic!.title, equals('新主题'));
        expect(topic.status, equals('in_progress'));
      });

      test('远端较新的 TaskItem 覆盖本地旧数据', () async {
        final now = DateTime.now();
        final oldTime = now.subtract(const Duration(hours: 1));
        final newTime = now.add(const Duration(hours: 1));
        final topicId = 'topic-task-merge';

        // 先创建 topic
        fixture.todoStore.saveTopic(TodoTopicEntity(
          id: topicId,
          employeeId: fixture.employeeId,
          title: '任务合并测试',
          createTime: now,
          updateTime: now,
        ));

        // 本地写入旧 task item
        fixture.todoStore.saveTaskItem(TodoTaskItemEntity(
          id: 'task-merge-1',
          employeeId: fixture.employeeId,
          topicId: topicId,
          title: '旧任务',
          status: 'pending',
          createTime: now,
          updateTime: oldTime,
        ));

        // Mock RPC 返回较新的 task item
        fixture.mockPendingTopics = [
          fixture.createTopicMap(id: topicId, title: '任务合并测试'),
        ];
        fixture.mockCurrentTopics = [];
        fixture.mockCompletedTopics = [];
        fixture.mockTaskItemsByTopic = {
          topicId: [
            fixture.createTaskItemMap(
              id: 'task-merge-1',
              topicId: topicId,
              title: '新任务',
              status: 'completed',
              updateTime: newTime,
            ),
          ],
        };

        await fixture.cachedProxy.syncFromRemote();

        // 验证：使用 findByIdIncludingDeleted 因为 upsertFromRemote 可能更新 deleted 字段
        final task = fixture.todoStore.findTaskItemByIdIncludingDeleted('task-merge-1');
        expect(task, isNotNull);
        expect(task!.title, equals('新任务'));
        expect(task.status, equals('completed'));
      });

      test('远端软删除的 TodoTopic 和 TaskItem 正确同步', () async {
        final now = DateTime.now();
        final topicId = 'topic-del-test';
        final taskId = 'task-del-test';

        // 先在本地创建 topic 和 task
        fixture.todoStore.saveTopic(TodoTopicEntity(
          id: topicId,
          employeeId: fixture.employeeId,
          title: '待删除主题',
          createTime: now,
          updateTime: now.subtract(const Duration(hours: 1)),
        ));
        fixture.todoStore.saveTaskItem(TodoTaskItemEntity(
          id: taskId,
          employeeId: fixture.employeeId,
          topicId: topicId,
          title: '待删除任务',
          createTime: now,
          updateTime: now.subtract(const Duration(hours: 1)),
        ));

        // Mock RPC 返回软删除的数据
        fixture.mockPendingTopics = [
          fixture.createTopicMap(
            id: topicId,
            title: '待删除主题',
            deleted: 1,
            updateTime: now,
          ),
        ];
        fixture.mockCurrentTopics = [];
        fixture.mockCompletedTopics = [];
        fixture.mockTaskItemsByTopic = {
          topicId: [
            fixture.createTaskItemMap(
              id: taskId,
              topicId: topicId,
              title: '待删除任务',
              deleted: 1,
              updateTime: now,
            ),
          ],
        };

        await fixture.cachedProxy.syncFromRemote();

        // 验证：活跃 topic 中不包含已删除的
        final activeTopics =
            fixture.todoStore.findCurrentTopics(fixture.employeeId);
        expect(activeTopics.where((t) => t.id == topicId), isEmpty);

        // 验证：活跃 task 中不包含已删除的（findTaskItemsByTopic 过滤 deleted=1）
        final activeItems = fixture.todoStore.findTaskItemsByTopic(topicId);
        expect(activeItems.where((i) => i.id == taskId), isEmpty);

        // 验证：包括已删除的查询中可以找到
        final topicIncDel = fixture.todoStore.findTopicByIdIncludingDeleted(topicId);
        expect(topicIncDel, isNotNull);
        expect(topicIncDel!.deleted, equals(1));

        final taskIncDel = fixture.todoStore.findTaskItemByIdIncludingDeleted(taskId);
        expect(taskIncDel, isNotNull);
        expect(taskIncDel!.deleted, equals(1));
      });
    });
  });
}
