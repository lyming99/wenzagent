import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/agent/adapter/session_memory_manager.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

int _testCounter = 0;

/// 清空会话后发送消息的集成测试
///
/// 覆盖以下场景：
/// 1. 清空后发送消息，消息应正确持久化并分配 seq
/// 2. 清空后发送消息，同步时应只拉到新消息，不拉到旧消息
/// 3. Agent 侧 addUserMessage 移除+重建消息后，DB 中只有一条记录且 seq 正确
/// 4. clearSeq = lastSeq = maxSeq 后，新消息的 seq 应大于 clearSeq
void main() {
  late String testDbPath;
  late MessageStoreService serverStore; // 模拟 agent 端（deviceIdA）
  late MessageStoreService clientStore; // 模拟客户端（deviceIdB）
  late MessageStore serverRawStore;
  late MessageStore clientRawStore;
  late SyncWatermarkStore serverWatermark;
  late SyncWatermarkStore clientWatermark;
  late String employeeId;
  late String deviceIdA; // agent 设备
  late String deviceIdB; // client 设备

  setUp(() async {
    _testCounter++;
    testDbPath = '${Directory.systemTemp.path}/wenzagent_clear_send_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    employeeId = 'emp-${const Uuid().v4()}';
    deviceIdA = 'agent-${const Uuid().v4().substring(0, 8)}';
    deviceIdB = 'client-${const Uuid().v4().substring(0, 8)}';

    // agent 和 client 使用同一个 DB 文件（模拟同一台设备上的数据库）
    // 在实际部署中 agent 和 client 可能在不同设备上
    await DatabaseManager.getInstance(deviceIdA).initialize(
      storagePath: testDbPath,
    );
    await DatabaseManager.getInstance(deviceIdB).initialize(
      storagePath: testDbPath,
    );

    serverStore = MessageStoreServiceImpl(deviceId: deviceIdA);
    clientStore = MessageStoreServiceImpl(deviceId: deviceIdB);
    serverRawStore = MessageStore(deviceId: deviceIdA);
    clientRawStore = MessageStore(deviceId: deviceIdB);
    serverWatermark = SyncWatermarkStore(deviceId: deviceIdA);
    clientWatermark = SyncWatermarkStore(deviceId: deviceIdB);
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceIdA).close();
    DatabaseManager.removeInstance(deviceIdA);
    await DatabaseManager.getInstance(deviceIdB).close();
    DatabaseManager.removeInstance(deviceIdB);
    MessageStoreService.removeInstance(deviceIdA);
    MessageStoreService.removeInstance(deviceIdB);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  /// 辅助：插入消息并返回 seq 列表
  Future<List<int>> _insertMessages(
    MessageStoreService store,
    String deviceId,
    int count, {
    String idPrefix = 'msg',
  }) async {
    final seqs = <int>[];
    for (int i = 1; i <= count; i++) {
      final msg = ChatMessage(
        id: '$idPrefix-$i',
        employeeId: employeeId,
        role: i.isOdd ? MessageRole.user : MessageRole.assistant,
        type: 'text',
        content: 'Message $i',
        createdAt: DateTime.now().add(Duration(seconds: i)),
        deviceId: deviceId,
      );
      await store.addMessage(deviceId, msg);
      // 读取实际分配的 seq
      final saved = await store.getMessage(deviceId, '$idPrefix-$i');
      if (saved != null) seqs.add(saved.seq);
    }
    return seqs;
  }

  /// 辅助：模拟清空会话（服务端）
  Future<int> _serverClearSession() async {
    final maxSeq = serverStore.getMaxSeq(deviceIdA, employeeId);
    // 1. 设置 clearSeq = lastSeq = maxSeq
    if (maxSeq > 0) {
      serverWatermark.setClearSeq(employeeId, maxSeq, deviceId: deviceIdA);
      serverWatermark.resetLastSeq(employeeId, maxSeq, deviceId: deviceIdA);
    }
    // 2. 硬删除消息
    await serverStore.deleteMessages(deviceIdA, employeeId);
    return maxSeq;
  }

  /// 辅助：模拟客户端收到清空事件
  Future<void> _clientHandleClear() async {
    final maxSeq = clientStore.getMaxSeq(deviceIdB, employeeId);
    await clientStore.deleteMessages(deviceIdB, employeeId);
    if (maxSeq > 0) {
      clientWatermark.resetLastSeq(employeeId, maxSeq, deviceId: deviceIdB);
    }
  }

  /// 辅助：模拟客户端增量同步
  Future<List<ChatMessage>> _clientSync() async {
    final lastSeq = clientWatermark.getLastSeq(employeeId, deviceId: deviceIdB) ?? 0;
    final remoteMaxSeq = serverRawStore.getMaxSeqForEmployeeAll(employeeId);

    if (remoteMaxSeq <= lastSeq) return [];

    final newMessages = <ChatMessage>[];
    int currentSeq = lastSeq;
    while (true) {
      final batch = await serverRawStore.getMessagesAfterSeq(
        employeeId, currentSeq, limit: 20,
      );
      if (batch.isEmpty) break;
      newMessages.addAll(batch);
      for (final msg in batch) {
        if (msg.seq > currentSeq) currentSeq = msg.seq;
      }
      if (batch.length < 20) break;
    }

    // 写入客户端 DB
    for (final msg in newMessages) {
      await clientStore.addMessage(msg, deviceId: deviceIdB);
    }
    // 更新客户端水位线
    clientWatermark.resetLastSeq(employeeId, currentSeq, deviceId: deviceIdB);

    return newMessages;
  }

  // ===== 测试组 =====

  group('清空后发送消息 - seq 正确性', () {
    test('清空后新消息的 seq 应大于 clearSeq', () async {
      // 1. 插入旧消息
      await _insertMessages(serverStore, deviceIdA, 5);
      final maxSeqBeforeClear = serverRawStore.getMaxSeqForEmployeeAll(employeeId);

      // 2. 清空会话
      final clearSeq = await _serverClearSession();

      expect(clearSeq, equals(maxSeqBeforeClear));
      // 验证 DB 已清空
      final remaining = await serverStore.getMessagesWithDeviceId(deviceIdA, employeeId);
      expect(remaining, isEmpty);

      // 3. 发送新消息
      final newMsg = ChatMessage(
        id: 'msg-new-1',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'New message after clear',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await serverStore.addMessage(newMsg, deviceId: deviceIdA);

      // 4. 验证新消息 seq > clearSeq
      final saved = await serverStore.getMessage('msg-new-1', deviceId: deviceIdA);
      expect(saved, isNotNull);
      expect(saved!.seq, greaterThan(clearSeq));

      // 5. 验证只有 1 条消息
      final all = await serverStore.getMessagesWithDeviceId(deviceIdA, employeeId);
      expect(all.length, equals(1));
    });

    test('清空后连续发送多条消息，seq 单调递增', () async {
      await _insertMessages(serverStore, deviceIdA, 3);
      await _serverClearSession();

      // 连续发送 3 条新消息
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'msg-new-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'New message $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await serverStore.addMessage(msg, deviceId: deviceIdA);
      }

      final all = await serverStore.getMessagesWithDeviceId(deviceIdA, employeeId);
      expect(all.length, equals(3));

      // 验证 seq 单调递增
      for (int i = 1; i < all.length; i++) {
        expect(all[i].seq, greaterThan(all[i - 1].seq));
      }
    });
  });

  group('清空后同步 - 不应拉到旧消息', () {
    test('清空+发送后客户端同步，只拉到新消息', () async {
      // 1. 服务端插入 5 条旧消息
      await _insertMessages(serverStore, deviceIdA, 5);

      // 2. 客户端同步旧消息
      final syncedOld = await _clientSync();
      expect(syncedOld.length, equals(5));

      // 3. 服务端清空
      final clearSeq = await _serverClearSession();

      // 4. 客户端收到清空事件
      await _clientHandleClear();

      // 5. 验证客户端已清空
      final clientMsgs = await clientStore.getMessagesWithDeviceId(deviceIdB, employeeId);
      expect(clientMsgs, isEmpty);

      // 6. 服务端发送新消息
      final newMsg = ChatMessage(
        id: 'msg-new-after-clear',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'New message after clear',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await serverStore.addMessage(newMsg, deviceId: deviceIdA);

      // 7. 客户端同步
      final syncedNew = await _clientSync();

      // 8. 验证只拉到 1 条新消息
      expect(syncedNew.length, equals(1));
      expect(syncedNew.first.id, equals('msg-new-after-clear'));
      expect(syncedNew.first.seq, greaterThan(clearSeq));

      // 9. 验证客户端总共只有 1 条消息
      final allClient = await clientStore.getMessagesWithDeviceId(deviceIdB, employeeId);
      expect(allClient.length, equals(1));
    });

    test('清空后发送多条消息+AI回复，客户端同步完整', () async {
      // 1. 插入旧消息
      await _insertMessages(serverStore, deviceIdA, 4);

      // 2. 客户端同步
      await _clientSync();

      // 3. 清空
      final clearSeq = await _serverClearSession();
      await _clientHandleClear();

      // 4. 服务端：用户消息 + AI 回复 + 用户消息 + AI 回复
      final messages = [
        ('msg-u1', MessageRole.user, 'Hello'),
        ('msg-a1', MessageRole.assistant, 'Hi there!'),
        ('msg-u2', MessageRole.user, 'How are you?'),
        ('msg-a2', MessageRole.assistant, 'I am fine!'),
      ];
      for (int i = 0; i < messages.length; i++) {
        final (id, role, content) = messages[i];
        final msg = ChatMessage(
          id: id,
          employeeId: employeeId,
          role: role,
          type: 'text',
          content: content,
          createdAt: DateTime.now().add(Duration(seconds: i + 1)),
          deviceId: deviceIdA,
        );
        await serverStore.addMessage(msg, deviceId: deviceIdA);
      }

      // 5. 客户端同步
      final synced = await _clientSync();

      // 6. 验证拉到 4 条新消息，且没有旧消息
      expect(synced.length, equals(4));
      for (final msg in synced) {
        expect(msg.seq, greaterThan(clearSeq));
      }

      // 7. 验证客户端总共只有 4 条消息
      final allClient = await clientStore.getMessagesWithDeviceId(deviceIdB, employeeId);
      expect(allClient.length, equals(4));
    });
  });

  group('addUserMessage 移除+重建消息', () {
    test('预持久化后 addUserMessage 移除重建，DB 只有一条记录且 seq 更新', () async {
      final memMgr = SessionMemoryManager();
      memMgr.configurePersistence(
        messageStore: serverStore,
        deviceId: deviceIdA,
      );
      memMgr.getOrCreateSession(employeeId);

      // 1. 模拟 AgentImpl.sendMessage 预持久化
      final prePersistedMsg = ChatMessage.user(
        id: 'msg-test-1',
        employeeId: employeeId,
        content: 'Pre-persisted message',
        createdAt: DateTime.now().subtract(const Duration(seconds: 10)),
      );
      memMgr.addMessage(employeeId, deviceIdA, prePersistedMsg);

      // 验证预持久化成功
      var dbMsg = await serverStore.getMessage('msg-test-1', deviceId: deviceIdA);
      expect(dbMsg, isNotNull);
      final preSeq = dbMsg!.seq;
      expect(preSeq, greaterThan(0));

      // 验证内存中也有
      var session = memMgr.getSession(employeeId);
      expect(session, isNotNull);
      expect(session!.allMessages.any((m) => m.id == 'msg-test-1'), isTrue);

      // 2. 模拟 addUserMessage 移除+重建
      session.removeMessage('msg-test-1');
      final rebuiltMsg = ChatMessage.user(
        id: 'msg-test-1',
        employeeId: employeeId,
        content: 'Pre-persisted message',
        createdAt: DateTime.now(),
      );
      memMgr.addMessage(employeeId, deviceIdA, rebuiltMsg);

      // 3. 验证 DB 中只有一条记录
      dbMsg = await serverStore.getMessage('msg-test-1', deviceId: deviceIdA);
      expect(dbMsg, isNotNull);
      final newSeq = dbMsg!.seq;
      expect(newSeq, greaterThan(preSeq), reason: '重建后 seq 应大于预持久化的 seq');

      // 4. 验证内存中也只有一条
      session = memMgr.getSession(employeeId);
      final count = session!.allMessages.where((m) => m.id == 'msg-test-1').length;
      expect(count, equals(1));

      memMgr.dispose();
    });

    test('预持久化消息的 createdAt 被更新为实际发送时间', () async {
      final memMgr = SessionMemoryManager();
      memMgr.configurePersistence(
        messageStore: serverStore,
        deviceId: deviceIdA,
      );
      memMgr.getOrCreateSession(employeeId);

      final oldTime = DateTime.now().subtract(const Duration(minutes: 5));

      // 预持久化
      memMgr.addMessage(employeeId, deviceIdA, ChatMessage.user(
        id: 'msg-time-test',
        employeeId: employeeId,
        content: 'Test',
        createdAt: oldTime,
      ));

      // 重建
      final session = memMgr.getSession(employeeId)!;
      session.removeMessage('msg-time-test');
      final newTime = DateTime.now();
      memMgr.addMessage(employeeId, deviceIdA, ChatMessage.user(
        id: 'msg-time-test',
        employeeId: employeeId,
        content: 'Test',
        createdAt: newTime,
      ));

      // 验证 DB 中的 createdAt 已更新
      final dbMsg = await serverStore.getMessage('msg-time-test', deviceId: deviceIdA);
      expect(dbMsg, isNotNull);
      // DB 中的时间应接近 newTime（允许 1 秒误差）
      expect(
        dbMsg!.createdAt.difference(newTime).inSeconds.abs(),
        lessThanOrEqualTo(1),
        reason: 'createdAt 应更新为实际发送时间',
      );

      memMgr.dispose();
    });
  });

  group('清空水位线一致性', () {
    test('清空后 clearSeq == lastSeq == maxSeq', () async {
      await _insertMessages(serverStore, deviceIdA, 5);
      final maxSeq = serverRawStore.getMaxSeqForEmployeeAll(employeeId);

      await _serverClearSession();

      final clearSeq = serverWatermark.getClearSeq(employeeId, deviceId: deviceIdA);
      final lastSeq = serverWatermark.getLastSeq(employeeId, deviceId: deviceIdA);

      expect(clearSeq, equals(maxSeq));
      expect(lastSeq, equals(maxSeq));
      expect(clearSeq, equals(lastSeq));
    });

    test('客户端清空后 lastSeq 应等于清空前的 maxSeq', () async {
      await _insertMessages(serverStore, deviceIdA, 3);

      // 客户端同步旧消息
      await _clientSync();

      // 客户端本地 maxSeq
      final clientMaxSeq = clientRawStore.getMaxSeqForEmployeeAll(employeeId);
      expect(clientMaxSeq, greaterThan(0));

      // 客户端处理清空
      await _clientHandleClear();

      // 验证客户端 lastSeq == 清空前 maxSeq
      final clientLastSeq = clientWatermark.getLastSeq(employeeId, deviceId: deviceIdB);
      expect(clientLastSeq, equals(clientMaxSeq));
    });

    test('清空后 getMessagesAfterSeq 不返回旧消息', () async {
      await _insertMessages(serverStore, deviceIdA, 5);
      final clearSeq = await _serverClearSession();

      // 用 clearSeq 作为 lastSeq 查询
      final messages = await serverRawStore.getMessagesAfterSeq(employeeId, clearSeq);
      expect(messages, isEmpty);

      // 用 clearSeq - 1 查询（也不应返回，因为消息已被硬删除）
      final messages2 = await serverRawStore.getMessagesAfterSeq(
        employeeId, clearSeq - 1,
      );
      expect(messages2, isEmpty);
    });
  });

  group('客户端本地缓存消息在同步时被正确替换', () {
    test('本地 localOnly 消息在同步后被远程消息替换', () async {
      // 1. 客户端创建本地缓存消息（seq=0, updateWatermark=false）
      final localMsg = ChatMessage(
        id: 'msg-local-cached',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'Local cached message',
        createdAt: DateTime.now(),
        deviceId: deviceIdB,
        seq: 0, // 本地缓存没有 seq
      );
      await clientStore.addMessage(localMsg, deviceId: deviceIdB, updateWatermark: false);

      // 2. 服务端处理消息并持久化（有 seq）
      final serverMsg = ChatMessage(
        id: 'msg-local-cached',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'Local cached message',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await serverStore.addMessage(serverMsg, deviceId: deviceIdA);

      final serverSaved = await serverStore.getMessage('msg-local-cached', deviceId: deviceIdA);
      expect(serverSaved, isNotNull);
      expect(serverSaved!.seq, greaterThan(0));

      // 3. 客户端同步
      await _clientSync();

      // 4. 验证本地消息被替换（有正确的 seq）
      final clientSaved = await clientStore.getMessage('msg-local-cached', deviceId: deviceIdB);
      expect(clientSaved, isNotNull);
      expect(clientSaved!.seq, equals(serverSaved.seq));
      expect(clientSaved.seq, greaterThan(0));
    });
  });

  group('端到端场景：清空 → 发送 → 同步', () {
    test('完整流程：有历史 → 清空 → 发送 → AI回复 → 客户端同步', () async {
      // === 阶段1：正常对话 ===
      await _insertMessages(serverStore, deviceIdA, 6);
      await _clientSync();

      // 客户端应有 6 条消息
      var clientMsgs = await clientStore.getMessagesWithDeviceId(deviceIdB, employeeId);
      expect(clientMsgs.length, equals(6));

      // === 阶段2：清空会话 ===
      final clearSeq = await _serverClearSession();
      await _clientHandleClear();

      clientMsgs = await clientStore.getMessagesWithDeviceId(deviceIdB, employeeId);
      expect(clientMsgs.length, equals(0));

      // === 阶段3：发送新消息 ===
      final userMsg = ChatMessage(
        id: 'msg-new-user',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'New question',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await serverStore.addMessage(userMsg, deviceId: deviceIdA);

      // === 阶段4：AI 回复 ===
      final aiMsg = ChatMessage(
        id: 'msg-new-ai',
        employeeId: employeeId,
        role: MessageRole.assistant,
        type: 'text',
        content: 'New answer',
        createdAt: DateTime.now().add(const Duration(seconds: 1)),
        deviceId: deviceIdA,
      );
      await serverStore.addMessage(aiMsg, deviceId: deviceIdA);

      // === 阶段5：客户端同步 ===
      final synced = await _clientSync();

      // 验证只拉到 2 条新消息
      expect(synced.length, equals(2));

      // 验证所有新消息 seq > clearSeq
      for (final msg in synced) {
        expect(msg.seq, greaterThan(clearSeq));
      }

      // 验证客户端总共只有 2 条消息（没有旧消息混入）
      clientMsgs = await clientStore.getMessagesWithDeviceId(deviceIdB, employeeId);
      expect(clientMsgs.length, equals(2));

      final ids = clientMsgs.map((m) => m.id).toSet();
      expect(ids, contains('msg-new-user'));
      expect(ids, contains('msg-new-ai'));
    });
  });
}
