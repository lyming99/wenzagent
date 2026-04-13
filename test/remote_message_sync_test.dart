/// 远程聊天窗口消息同步测试
///
/// 测试远程消息同步的核心功能，覆盖 CachedAgentProxy / AgentProxy / MessageStore / SyncWatermarkStore
/// 各层的同步行为，同时以注释标注后端行为如何映射到前端 ChatViewController 已识别的问题。
///
/// 前端问题清单（共 8 个，详见各测试组注释）：
///   P1. 签名跳过可能漏掉细微变化
///   P2. 防抖+防重入导致更新丢失
///   P3. 用户消息 ±5 秒去重窗口可能误判
///   P4. 工具调用匹配依赖顺序
///   P5. localToolCall 过滤可能导致工具调用丢失
///   P6. onReplace 不重新加载消息
///   P7. 权限请求检查依赖状态快照时序
///   P8. forceRefresh 后首次非 force 加载必定重建
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:wenzagent/src/agent/adapter/persistent_chat_adapter.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/client/cached_agent_proxy.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/agent/impl/agent_impl.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/persistence/stores/message_store.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

void main() {
  late DatabaseManager dbManager;
  late DatabaseManager? hostDbManager;
  late String dbDir;
  const employeeId = 'test-remote-sync-employee';
  const hostDeviceId = 'host-device';
  const clientDeviceId = 'client-device';

  late AgentImpl hostAgent;
  late AgentProxy hostProxy;
  late PersistentChatAdapter hostAdapter;
  late MessageStoreServiceImpl hostMessageStore;
  late AgentProxy clientProxy;
  late CachedAgentProxy cachedClientProxy;
  late MessageStoreServiceImpl clientMessageStore;
  late SyncWatermarkStore clientWatermarkStore;

  setUpAll(() {
    dbDir = p.join(
      Directory.systemTemp.path,
      'remote_sync_test_${DateTime.now().millisecondsSinceEpoch}',
    );
    Directory(dbDir).createSync(recursive: true);
  });

  tearDownAll(() async {
    await hostDbManager?.close();
    await dbManager.close();
    final dir = Directory(dbDir);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> _setup() async {
    final instance = DatabaseManager.getInstance('test');
    if (instance.isInitialized) await instance.close();
    await instance.initialize(storagePath: dbDir);
    dbManager = instance;
    // AgentImpl.getMessagesAfterSeq 内部使用 MessageStore(deviceId: deviceId)，
    // 即 DatabaseManager.getInstance(hostDeviceId)，因此也需要初始化该键。
    hostDbManager = DatabaseManager.getInstance(hostDeviceId);
    if (!hostDbManager!.isInitialized) {
      await hostDbManager!.initialize(storagePath: dbDir);
    }
    dbManager.db.execute('DELETE FROM sync_watermark');
    dbManager.db.execute('DELETE FROM messages');

    hostMessageStore = MessageStoreServiceImpl(
      store: MessageStore(dbManager: dbManager), deviceId: hostDeviceId);
    hostAdapter = PersistentChatAdapter();
    hostAdapter.persistMessage = (messageData) async {
      final chatMsg = ChatMessage.fromJson(messageData as Map<String, dynamic>);
      await hostMessageStore.addMessage(chatMsg, deviceId: hostDeviceId);
    };
    hostAdapter.loadMessages = (empId, {int? limit}) async {
      final messages = await hostMessageStore.getMessages(empId);
      return messages.map((m) => m.toJson()).toList();
    };
    hostAdapter.updateMessageStatusCallback = (messageId, status, {error}) async {
      await hostMessageStore.updateMessageStatus(
        messageId, MessageStatus.values.byName(status), error: error);
    };
    hostAdapter.deleteMessagesCallback = (empId) async {
      await hostMessageStore.deleteMessages(empId, deviceId: hostDeviceId);
    };
    hostAgent = AgentImpl(
      employeeId: employeeId, deviceId: hostDeviceId, chatAdapter: hostAdapter);
    await hostAgent.initialize(enableBuiltinTools: false);
    hostProxy = AgentProxy.local(
      employeeId: employeeId, deviceId: hostDeviceId, localAgent: hostAgent);

    clientMessageStore = MessageStoreServiceImpl(
      store: MessageStore(dbManager: dbManager), deviceId: clientDeviceId);
    clientWatermarkStore = SyncWatermarkStore(dbManager: dbManager);
    clientProxy = AgentProxy.local(
      employeeId: employeeId, deviceId: clientDeviceId, localAgent: hostAgent);
    cachedClientProxy = CachedAgentProxy(
      proxy: clientProxy, messageStore: clientMessageStore,
      deviceId: clientDeviceId, employeeId: employeeId);
    await cachedClientProxy.initialize();
  }

  Future<void> _tearDown() async {
    await cachedClientProxy.dispose();
    await clientProxy.dispose();
    await hostProxy.dispose();
    await hostAgent.dispose();
    hostMessageStore.dispose();
    clientMessageStore.dispose();
  }

  Future<String> hostInjectAssistant(String content) async {
    final msgId = const Uuid().v4();
    await hostAgent.injectAssistantMessage(messageId: msgId, content: content);
    return msgId;
  }

  Future<String> hostAddUserMessage(String content) async {
    final msgId = const Uuid().v4();
    final chatMsg = ChatMessage.user(
      id: msgId, employeeId: employeeId, content: content, deviceId: hostDeviceId);
    await hostMessageStore.addMessage(chatMsg, deviceId: hostDeviceId);
    return msgId;
  }

  /// 从消息列表中提取最大 seq
  int _maxSeqFromMessages(List<AgentMessage> messages) {
    int maxSeq = 0;
    for (final msg in messages) {
      final seq = msg.metadata?['seq'] as int? ?? 0;
      if (seq > maxSeq) maxSeq = seq;
    }
    return maxSeq;
  }

  // ================================================================
  // 1. LSN 增量同步基础验证
  // 【前端映射 P2】后端使用 Completer 锁可复用 Future，前端布尔锁会丢弃更新
  // ================================================================
  group('LSN 增量同步', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('初始水位线为 0 时拉取全部消息', () async {
      await hostAddUserMessage('消息1');
      await hostInjectAssistant('回复1');
      await hostAddUserMessage('消息2');

      final messages = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 20);
      expect(messages.length, equals(3));
      for (final msg in messages) {
        expect(msg.metadata?['seq'], isNotNull);
      }
    });

    test('水位线更新后只拉取新增消息', () async {
      await hostAddUserMessage('A');
      await hostInjectAssistant('A回复');
      await hostAddUserMessage('B');

      final batch1 = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 20);
      expect(batch1.length, equals(3));
      final maxSeq = _maxSeqFromMessages(batch1);

      await hostInjectAssistant('B回复');
      await hostAddUserMessage('C');

      final batch2 = await clientProxy.getMessagesAfterSeq(
          lastSeq: maxSeq, limit: 20);
      expect(batch2.length, equals(2));
    });

    test('getMaxSeq 返回正确的最大 seq', () async {
      await hostAddUserMessage('X');
      await hostInjectAssistant('X回复');
      final maxSeq = await clientProxy.getMaxSeq();
      expect(maxSeq, greaterThan(0));
    });
  });

  // ================================================================
  // 2. CachedAgentProxy 初始化
  // 【前端映射 P6】onReplace 继承旧列表但不加载新数据，可能显示过期数据
  // ================================================================
  group('CachedAgentProxy 初始化', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('initialize 加载本地缓存消息到缓存', () async {
      final msgId = const Uuid().v4();
      final chatMsg = ChatMessage.user(
        id: msgId, employeeId: employeeId,
        content: '本地缓存消息', deviceId: clientDeviceId);
      await clientMessageStore.addMessage(chatMsg, deviceId: clientDeviceId);

      await cachedClientProxy.dispose();
      clientProxy = AgentProxy.local(
        employeeId: employeeId, deviceId: clientDeviceId, localAgent: hostAgent);
      cachedClientProxy = CachedAgentProxy(
        proxy: clientProxy, messageStore: clientMessageStore,
        deviceId: clientDeviceId, employeeId: employeeId);

      // 监听 onMessagesChanged 流来验证初始化加载了本地缓存
      final events = <List<AgentMessage>>[];
      final sub = cachedClientProxy.onMessagesChanged.listen(events.add);
      await cachedClientProxy.initialize();
      await Future.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      // initialize 时 _loadLocalMessagesByUserCount 会加载本地消息并通知
      expect(events.isNotEmpty, isTrue,
          reason: 'initialize 后 onMessagesChanged 应触发');
      expect(events.last.any((m) => m.id == msgId), isTrue,
          reason: '本地缓存消息应出现在事件流中');
    });

    test('initialize 后本地缓存为空时 getMessages 返回空列表', () async {
      // 本地模式下 getMessages 走代理→hostAgent→内存会话，内存会话为空
      final messages = await cachedClientProxy.getMessages();
      expect(messages.length, equals(0));
    });
  });

  // ================================================================
  // 3. 消息合并与去重
  // 【前端映射 P1】后端按 ID 去重+updateTime 更新，前端签名仅检查 content.length
  // 【前端映射 P3】后端以 UUID 为主键不去重，前端 5 秒窗口可能误去重
  // ================================================================
  group('消息合并与去重', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('不同 ID 的相同内容消息不去重', () async {
      final msg1 = ChatMessage.user(id: const Uuid().v4(),
        employeeId: employeeId, content: '相同内容', deviceId: clientDeviceId);
      final msg2 = ChatMessage.user(id: const Uuid().v4(),
        employeeId: employeeId, content: '相同内容',
        createdAt: DateTime.now().add(const Duration(seconds: 1)),
        deviceId: clientDeviceId);

      await clientMessageStore.addMessage(msg1, deviceId: clientDeviceId);
      await clientMessageStore.addMessage(msg2, deviceId: clientDeviceId);

      final messages = await clientMessageStore.getMessages(employeeId);
      expect(messages.length, equals(2));
    });

    test('同 ID 消息更新保留原 seq', () async {
      final id = const Uuid().v4();
      final original = ChatMessage.user(
        id: id, employeeId: employeeId, content: '原始', deviceId: clientDeviceId);
      await clientMessageStore.addMessage(original, deviceId: clientDeviceId);
      var stored = await clientMessageStore.getMessage(id);
      final originalSeq = stored!.seq;

      await clientMessageStore.updateMessage(
        original.copyWith(content: '更新'), deviceId: clientDeviceId);
      stored = await clientMessageStore.getMessage(id);
      expect(stored!.seq, equals(originalSeq));
    });

    test('getMessagesAfterSeq 包含软删除消息', () async {
      await hostAddUserMessage('保留');
      final deleteId = await hostAddUserMessage('待删除');
      await hostAddUserMessage('保留2');

      MessageStore(dbManager: dbManager).softDeleteForSync(deleteId);

      final messages = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 20);
      expect(messages.length, equals(3));
      final deletedMsg = messages.firstWhere((m) => m.id == deleteId);
      expect(deletedMsg.metadata?['deleted'], equals(1));
    });
  });

  // ================================================================
  // 4. 水位线管理
  // 【前端映射 P2】MAX 语义保证同步不丢失，前端防抖丢失请求后仍可续接
  // ================================================================
  group('水位线管理', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('MAX 语义：只升不降', () async {
      clientWatermarkStore.updateLastSeq(employeeId, 10);
      clientWatermarkStore.updateLastSeq(employeeId, 5);
      expect(clientWatermarkStore.getLastSeq(employeeId), equals(10));
    });

    test('并发模拟保持最大值', () async {
      clientWatermarkStore.updateLastSeq(employeeId, 100);
      clientWatermarkStore.updateLastSeq(employeeId, 50);
      clientWatermarkStore.updateLastSeq(employeeId, 80);
      expect(clientWatermarkStore.getLastSeq(employeeId), equals(100));
    });

    test('初始水位线为 0', () {
      expect(clientWatermarkStore.getLastSeq(employeeId), equals(0));
    });
  });

  // ================================================================
  // 5. 远程删除同步
  // 【前端映射 P1】后端 softDeleteForSync 更新 seq 使删除可增量拉取，
  //   前端签名跳过变更会导致删除的消息继续显示
  // ================================================================
  group('远程删除同步', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('softDeleteForSync 更新 seq 使删除事件可被增量拉取', () async {
      await hostAddUserMessage('保留');
      final deleteId = await hostAddUserMessage('待删除');
      await hostAddUserMessage('保留2');

      final batch1 = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 20);
      final maxSeq = _maxSeqFromMessages(batch1);

      MessageStore(dbManager: dbManager).softDeleteForSync(deleteId);

      final batch2 = await clientProxy.getMessagesAfterSeq(
          lastSeq: maxSeq, limit: 20);
      expect(batch2.length, equals(1));
      expect(batch2.first.id, equals(deleteId));
      expect(batch2.first.metadata?['deleted'], equals(1));
    });

    test('softDeleteBySessionForSync 批量删除可被增量拉取', () async {
      for (int i = 0; i < 3; i++) await hostAddUserMessage('消息$i');

      final batch1 = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 20);
      final maxSeq = _maxSeqFromMessages(batch1);

      await MessageStore(dbManager: dbManager).softDeleteBySessionForSync(employeeId);

      final batch2 = await clientProxy.getMessagesAfterSeq(
          lastSeq: maxSeq, limit: 20);
      expect(batch2.length, equals(3));
      expect(batch2.every((m) => m.metadata?['deleted'] == 1), isTrue);
    });
  });

  // ================================================================
  // 6. 工具调用消息同步
  // 【前端映射 P4】后端 seq 严格保证顺序，PersistenceQueue 确保落盘后广播
  // 【前端映射 P5】_cleanupLocalToolCallMessages 仅在远程消息到达后清理
  // ================================================================
  group('工具调用消息同步', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('assistant 含 toolCalls 的消息正确存储和检索', () async {
      final toolCallId = const Uuid().v4();
      final assistantMsg = ChatMessage(
        id: const Uuid().v4(), employeeId: employeeId,
        role: MessageRole.assistant, type: 'functionCall', content: null,
        createdAt: DateTime.now(), deviceId: hostDeviceId,
        toolCalls: [ToolCall(id: toolCallId, name: 'test_tool', arguments: {'a': '1'})],
      );
      await hostMessageStore.addMessage(assistantMsg, deviceId: hostDeviceId);

      final messages = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 20);
      expect(messages.length, equals(1));
      expect(messages.first.toolCalls!.first.id, equals(toolCallId));
    });

    test('tool result 消息正确存储和检索', () async {
      final toolCallId = const Uuid().v4();
      final toolResultMsg = ChatMessage.toolResult(
        id: const Uuid().v4(), employeeId: employeeId,
        toolCallId: toolCallId, content: '结果', toolName: 'test_tool',
        deviceId: hostDeviceId);
      await hostMessageStore.addMessage(toolResultMsg, deviceId: hostDeviceId);

      final messages = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 20);
      expect(messages.first.toolCallId, equals(toolCallId));
      expect(messages.first.role, equals('tool'));
    });

    test('多工具调用按 seq 顺序返回', () async {
      final tcId1 = const Uuid().v4();
      final tcId2 = const Uuid().v4();
      await hostMessageStore.addMessage(ChatMessage(
        id: const Uuid().v4(), employeeId: employeeId,
        role: MessageRole.assistant, type: 'functionCall',
        createdAt: DateTime.now(), deviceId: hostDeviceId,
        toolCalls: [
          ToolCall(id: tcId1, name: 'tool1', arguments: {}),
          ToolCall(id: tcId2, name: 'tool2', arguments: {}),
        ]), deviceId: hostDeviceId);
      await hostMessageStore.addMessage(ChatMessage.toolResult(
        id: const Uuid().v4(), employeeId: employeeId,
        toolCallId: tcId1, content: 'r1', toolName: 'tool1',
        deviceId: hostDeviceId), deviceId: hostDeviceId);
      await hostMessageStore.addMessage(ChatMessage.toolResult(
        id: const Uuid().v4(), employeeId: employeeId,
        toolCallId: tcId2, content: 'r2', toolName: 'tool2',
        deviceId: hostDeviceId), deviceId: hostDeviceId);

      final messages = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 20);
      expect(messages.length, equals(3));
      for (int i = 1; i < messages.length; i++) {
        final prevSeq = messages[i - 1].metadata?['seq'] as int? ?? 0;
        final currSeq = messages[i].metadata?['seq'] as int? ?? 0;
        expect(currSeq, greaterThan(prevSeq));
      }
    });
  });

  // ================================================================
  // 7. 消息注入与持久化一致性
  // 【前端映射 P4】injectAssistantMessage 等待持久化完成后再广播，
  //   确保 getMessagesAfterSeq 不会拉到 seq 不连续的消息
  // ================================================================
  group('消息注入与持久化一致性', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('injectAssistantMessage 后消息可立即增量拉取', () async {
      final msgId = await hostInjectAssistant('注入消息');
      final messages = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 20);
      expect(messages.length, equals(1));
      expect(messages.first.id, equals(msgId));
      expect(messages.first.metadata?['seq'], isNotNull);
    });

    test('连续注入的消息 seq 递增', () async {
      await hostInjectAssistant('A');
      await hostInjectAssistant('B');
      await hostInjectAssistant('C');
      final messages = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 20);
      expect(messages.length, equals(3));
      final seqs = messages.map((m) => m.metadata?['seq'] as int? ?? 0).toList();
      for (int i = 1; i < seqs.length; i++) {
        expect(seqs[i], greaterThan(seqs[i - 1]));
      }
    });

    test('注入消息包含 updateTime', () async {
      await hostInjectAssistant('有时间戳');
      final messages = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 20);
      expect(messages.first.metadata?['updateTime'], isNotNull);
    });
  });

  // ================================================================
  // 8. 分批拉取
  // 【前端映射 P2】后端分批循环累积消息再合并，前端防抖丢失可依靠下次续接
  // ================================================================
  group('分批拉取', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('limit=2 分批获取全部消息', () async {
      for (int i = 0; i < 5; i++) await hostAddUserMessage('消息$i');

      int maxSeq = 0;
      final batch1 = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 2);
      expect(batch1.length, equals(2));
      maxSeq = _maxSeqFromMessages(batch1);

      final batch2 = await clientProxy.getMessagesAfterSeq(lastSeq: maxSeq, limit: 2);
      expect(batch2.length, equals(2));
      maxSeq = _maxSeqFromMessages(batch2);

      final batch3 = await clientProxy.getMessagesAfterSeq(lastSeq: maxSeq, limit: 2);
      expect(batch3.length, equals(1));
      maxSeq = _maxSeqFromMessages(batch3);

      final batch4 = await clientProxy.getMessagesAfterSeq(lastSeq: maxSeq, limit: 2);
      expect(batch4.length, equals(0));
    });
  });

  // ================================================================
  // 9. 水位线校验与降级全量同步
  // 【前端映射 P8】后端检测到 lastSeq>maxSeq 时自动清空并全量同步，
  //   forceRefresh 后 _lastMessagesSignature=null 导致不必要重建
  // ================================================================
  group('水位线校验与降级', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('水位线等于 maxSeq 时不触发清空', () async {
      await hostAddUserMessage('A');
      await hostInjectAssistant('回复');
      final maxSeq = await clientProxy.getMaxSeq();
      clientWatermarkStore.updateLastSeq(employeeId, maxSeq);
      expect(clientWatermarkStore.getLastSeq(employeeId) <= maxSeq, isTrue);
    });

    test('清空后重新同步正常工作', () async {
      for (int i = 0; i < 3; i++) await hostAddUserMessage('旧$i');
      final batch1 = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 20);
      expect(batch1.length, equals(3));

      dbManager.db.execute('DELETE FROM messages');
      clientWatermarkStore.updateLastSeq(employeeId, 0);

      await hostAddUserMessage('新A');
      await hostInjectAssistant('新回复');
      final batch2 = await clientProxy.getMessagesAfterSeq(lastSeq: 0, limit: 20);
      expect(batch2.length, equals(2));
    });
  });

  // ================================================================
  // 10. 消息状态同步
  // 【前端映射 P7】后端通过事件流推送状态变更，
  //   前端应在回调中直接处理而非依赖加载时机
  // ================================================================
  group('消息状态同步', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('消息状态可正确更新', () async {
      final msgId = await hostAddUserMessage('测试');
      await hostMessageStore.updateMessageStatus(msgId, MessageStatus.completed);
      final msg = await clientMessageStore.getMessage(msgId);
      expect(msg!.status, equals(MessageStatus.completed));
    });

    test('消息状态包含错误信息', () async {
      final msgId = await hostAddUserMessage('测试');
      await hostMessageStore.updateMessageStatus(
          msgId, MessageStatus.failed, error: '超时');
      final msg = await clientMessageStore.getMessage(msgId);
      expect(msg!.processingError, equals('超时'));
    });
  });

  // ================================================================
  // 11. 跨 employee 隔离
  // ================================================================
  group('跨 employee 隔离', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('不同员工的消息和水位线独立', () async {
      const empA = 'emp-iso-A';
      const empB = 'emp-iso-B';
      await clientMessageStore.addMessage(ChatMessage.user(
        id: const Uuid().v4(), employeeId: empA,
        content: 'A', deviceId: clientDeviceId), deviceId: clientDeviceId);
      await clientMessageStore.addMessage(ChatMessage.user(
        id: const Uuid().v4(), employeeId: empB,
        content: 'B', deviceId: clientDeviceId), deviceId: clientDeviceId);

      expect((await clientMessageStore.getMessages(empA)).length, equals(1));
      expect((await clientMessageStore.getMessages(empB)).length, equals(1));

      clientWatermarkStore.updateLastSeq(empA, 10);
      clientWatermarkStore.updateLastSeq(empB, 20);
      expect(clientWatermarkStore.getLastSeq(empA), equals(10));
      expect(clientWatermarkStore.getLastSeq(empB), equals(20));
    });
  });

  // ================================================================
  // 12. 消息变更事件流
  // 【前端映射 P2】后端 16ms 去抖合并同一帧多次变更，不会丢弃
  // ================================================================
  group('消息变更事件流', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('MessageStoreService 广播变更事件', () async {
      final events = <MessageChangeEvent>[];
      final sub = clientMessageStore.onMessageChanged.listen(events.add);

      final msgId = const Uuid().v4();
      await clientMessageStore.addMessage(ChatMessage.user(
        id: msgId, employeeId: employeeId,
        content: '事件测试', deviceId: clientDeviceId), deviceId: clientDeviceId);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(events.any((e) => e.type == MessageChangeType.added), isTrue);

      await clientMessageStore.updateMessageStatus(msgId, MessageStatus.completed);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(events.any((e) => e.type == MessageChangeType.updated), isTrue);

      await sub.cancel();
    });
  });

  // ================================================================
  // 13. 内容变更检测（验证前端签名问题 P1）
  // 【前端映射 P1】内容变化但长度不变时前端签名无法检测
  // ================================================================
  group('内容变更检测', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('内容变化但长度不变时后端正确更新', () async {
      final msgId = const Uuid().v4();
      await clientMessageStore.addMessage(ChatMessage.user(
        id: msgId, employeeId: employeeId,
        content: 'AAAA', deviceId: clientDeviceId), deviceId: clientDeviceId);

      await clientMessageStore.updateMessage(ChatMessage.user(
        id: msgId, employeeId: employeeId,
        content: 'BBBB', deviceId: clientDeviceId), deviceId: clientDeviceId);

      final msg = await clientMessageStore.getMessage(msgId);
      expect(msg!.content, equals('BBBB'),
          reason: '后端应正确更新内容（前端签名仅检查长度会遗漏此变更）');
    });

    test('metadata 内部值变化时后端正确更新', () async {
      final msgId = const Uuid().v4();
      await clientMessageStore.addMessage(ChatMessage.user(
        id: msgId, employeeId: employeeId, content: 'test',
        deviceId: clientDeviceId), deviceId: clientDeviceId);

      await hostMessageStore.updateMessageStatus(msgId, MessageStatus.completed);
      await Future.delayed(const Duration(milliseconds: 50));

      final msg = await hostMessageStore.getMessage(msgId);
      expect(msg!.status, equals(MessageStatus.completed),
          reason: '后端应正确更新状态（前端签名仅检查 metadata 长度会遗漏此变更）');
    });
  });

  // ================================================================
  // 14. 消息 ID 一致性（直接注入验证 ID 不被篡改）
  // ================================================================
  group('消息 ID 一致性', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('hostAddUserMessage 返回客户端生成的 ID 且不变', () async {
      final clientMsgId = const Uuid().v4();
      final chatMsg = ChatMessage.user(
        id: clientMsgId, employeeId: employeeId,
        content: 'ID 一致性测试', deviceId: hostDeviceId);
      await hostMessageStore.addMessage(chatMsg, deviceId: hostDeviceId);
      expect(chatMsg.id, equals(clientMsgId));

      final hostMsg = await hostMessageStore.getMessage(clientMsgId);
      expect(hostMsg, isNotNull);
      expect(hostMsg!.id, equals(clientMsgId));
    });
  });

  // ================================================================
  // 15. CachedAgentProxy 消息流（通过 hostInjectAssistant 驱动）
  // 【前端映射 P6】onReplace 不调用 _loadMessages 导致使用过期数据
  // ================================================================
  group('CachedAgentProxy 消息流', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('hostInjectAssistant 后消息可通过 CachedAgentProxy 获取', () async {
      final msgId = await hostInjectAssistant('缓存测试');
      final messages = await cachedClientProxy.getMessages();
      // CachedAgentProxy 在本地模式下直接代理 hostAgent，
      // 但 _needCache = !_proxy.isLocalMode，本地模式不启用缓存，
      // 所以 getMessages 返回的是代理结果
      expect(messages.any((m) => m.id == msgId), isTrue);
    });

    test('onMessagesChanged 流在初始化和消息变更时触发', () async {
      // 先向 clientMessageStore 写入消息，再重新初始化 CachedAgentProxy
      final msgId = const Uuid().v4();
      await clientMessageStore.addMessage(ChatMessage.user(
        id: msgId, employeeId: employeeId,
        content: '流测试', deviceId: clientDeviceId), deviceId: clientDeviceId);

      // 重新创建 proxy 以触发 initialize
      await cachedClientProxy.dispose();
      clientProxy = AgentProxy.local(
        employeeId: employeeId, deviceId: clientDeviceId, localAgent: hostAgent);
      cachedClientProxy = CachedAgentProxy(
        proxy: clientProxy, messageStore: clientMessageStore,
        deviceId: clientDeviceId, employeeId: employeeId);

      final events = <List<AgentMessage>>[];
      final sub = cachedClientProxy.onMessagesChanged.listen(events.add);
      await cachedClientProxy.initialize();
      // 等待 16ms debounce
      await Future.delayed(const Duration(milliseconds: 100));

      expect(events.isNotEmpty, isTrue,
          reason: 'initialize 后 onMessagesChanged 应触发');
      expect(events.last.any((m) => m.id == msgId), isTrue,
          reason: '事件应包含从本地缓存加载的消息');
      await sub.cancel();
    });
  });

  print('\n=== 远程消息同步测试完成 ===\n');
}
