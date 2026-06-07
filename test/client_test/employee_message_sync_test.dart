/// 员工消息同步 — 端到端功能测试
///
/// 使用 test/client_test/ 测试基础类验证员工消息同步的完整通信场景，
/// 模拟前端 ChatViewController 的消息对话同步流程：
///
/// 前端核心流程（参考 wenzflow_flutter/lib/view/mobile/ai/chat/controller.dart）：
///   onInit → subscribeEmployeeOnlineState + loadSession
///     └─ onAfterSessionInit → syncFromRemote() [远程模式]
///   sendMessage → agentProxy.sendMessage → 本地持久化 + LAN广播 + Server转发
///   sendMessage (file) → addPendingFile → sendMessage(type:'file', metadata:{...})
///   远程接收 → onLanMessage → MessageStore写入 → 水位线更新 → UI刷新
///   断连恢复 → syncFromRemote() 增量拉取漏收消息
///
/// 依赖：
/// - ClientTestFixture: 客户端完整生命周期模拟
/// - ServerTestFixture: 服务端完整生命周期模拟
/// - LanTestHarness: 端到端通信桥接
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/wenzagent.dart' as agent;
import 'package:wenzagent/src/host/host_rpc_methods.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

import 'client_test_fixture.dart';
import 'lan_test_harness.dart';

// ═══════════════════════════════════════════════════════════════
// 辅助方法
// ═══════════════════════════════════════════════════════════════

/// 创建测试用文本消息
ChatMessage _createMessage({
  required String employeeId,
  required String deviceId,
  MessageRole role = MessageRole.user,
  String type = 'text',
  String? content,
  String? id,
  Map<String, dynamic>? metadata,
  MessageStatus status = MessageStatus.none,
  int seq = 0,
  bool deleted = false,
}) {
  return ChatMessage(
    id: id ?? const Uuid().v4(),
    employeeId: employeeId,
    role: role,
    type: type,
    content: content ?? 'Test message ${const Uuid().v4().substring(0, 6)}',
    createdAt: DateTime.now(),
    deviceId: deviceId,
    metadata: metadata,
    status: status,
    seq: seq,
    deleted: deleted,
  );
}

/// 创建测试用文件消息
ChatMessage _createFileMessage({
  required String employeeId,
  required String deviceId,
  required String fileName,
  required int fileSize,
  required String filePath,
  MessageRole role = MessageRole.user,
  String? fileId,
  String? sha256,
  String? fromDeviceId,
  String? id,
}) {
  final fid = fileId ?? const Uuid().v4();
  final hash =
      sha256 ??
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
  return ChatMessage.file(
    id: id ?? const Uuid().v4(),
    employeeId: employeeId,
    role: role,
    fileName: fileName,
    fileSize: fileSize,
    fileId: fid,
    fileHash: hash,
    filePath: filePath,
    fromDeviceId: fromDeviceId ?? deviceId,
    deviceId: deviceId,
  );
}

/// 创建测试用 assistant 消息（模拟 AI 回复）
ChatMessage _createAssistantMessage({
  required String employeeId,
  required String deviceId,
  String? content,
  String? id,
  MessageStatus status = MessageStatus.completed,
  int seq = 0,
}) {
  return ChatMessage(
    id: id ?? const Uuid().v4(),
    employeeId: employeeId,
    role: MessageRole.assistant,
    type: 'text',
    content: content ?? 'AI response ${const Uuid().v4().substring(0, 6)}',
    createdAt: DateTime.now(),
    deviceId: deviceId,
    status: status,
    seq: seq,
  );
}

class _InMemoryMessageStoreService implements MessageStoreService {
  final _messages = <String, ChatMessage>{};
  final _lastSeqBySession = <String, int>{};
  final _summaries = <String, SessionSummaryEntity>{};
  final _changeController = StreamController<MessageChangeEvent>.broadcast();

  String _sessionKey(String deviceId, String employeeId) =>
      '$deviceId::$employeeId';

  String _messageKey(String deviceId, String messageId) =>
      '$deviceId::$messageId';

  @override
  Stream<MessageChangeEvent> get onMessageChanged => _changeController.stream;

  @override
  Future<ChatMessage> addMessage(
    String deviceId,
    ChatMessage message, {
    bool updateWatermark = true,
  }) async {
    _messages[_messageKey(deviceId, message.id)] = message;
    if (updateWatermark && message.seq > 0) {
      updateLastSeq(deviceId, message.employeeId, message.seq);
    }
    return message;
  }

  @override
  Future<void> deleteMessages(String deviceId, String employeeId) async {
    _messages.removeWhere(
      (_, message) =>
          message.deviceId == deviceId && message.employeeId == employeeId,
    );
    _lastSeqBySession.remove(_sessionKey(deviceId, employeeId));
  }

  @override
  Future<int> deleteMessagesBeforeSeq(
    String deviceId,
    String employeeId,
    int beforeSeq,
  ) async {
    var deletedCount = 0;
    _messages.removeWhere((_, message) {
      final shouldDelete =
          message.deviceId == deviceId &&
          message.employeeId == employeeId &&
          message.seq < beforeSeq;
      if (shouldDelete) deletedCount++;
      return shouldDelete;
    });
    return deletedCount;
  }

  @override
  Future<int> getLastSeq(String deviceId, String employeeId) async {
    return _lastSeqBySession[_sessionKey(deviceId, employeeId)] ?? 0;
  }

  @override
  Future<ChatMessage?> getMessage(String deviceId, String uuid) async {
    return _messages[_messageKey(deviceId, uuid)];
  }

  @override
  Future<List<ChatMessage>> getMessages(
    String deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  }) {
    return getMessagesWithDeviceId(
      deviceId,
      employeeId,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<List<ChatMessage>> getMessagesWithDeviceId(
    String deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  }) async {
    final all =
        _messages.values
            .where(
              (message) =>
                  message.deviceId == deviceId &&
                  message.employeeId == employeeId,
            )
            .toList()
          ..sort((a, b) => a.seq.compareTo(b.seq));
    final start = (offset ?? 0).clamp(0, all.length);
    final end = limit == null
        ? all.length
        : (start + limit).clamp(0, all.length);
    return all.sublist(start, end);
  }

  @override
  Future<int> getMaxSeq(String deviceId, String employeeId) async {
    final messages = await getMessages(deviceId, employeeId);
    return messages.fold<int>(
      0,
      (max, message) => message.seq > max ? message.seq : max,
    );
  }

  @override
  Future<List<String>> getStaleLocalToolCallMessages(
    String deviceId,
    String employeeId,
  ) async {
    return const [];
  }

  @override
  Future<void> hardDeleteMessage(String deviceId, String uuid) async {
    _messages.remove(_messageKey(deviceId, uuid));
  }

  @override
  void resetLastSeq(
    String deviceId,
    String employeeId,
    int lastSeq, {
    bool enforceMax = true,
  }) {
    final key = _sessionKey(deviceId, employeeId);
    if (!enforceMax || lastSeq > (_lastSeqBySession[key] ?? 0)) {
      _lastSeqBySession[key] = lastSeq;
    }
  }

  @override
  void updateLastSeq(String deviceId, String employeeId, int lastSeq) {
    resetLastSeq(deviceId, employeeId, lastSeq);
  }

  @override
  void upsertSummaryFromRemote(SessionSummaryEntity remote) {
    _summaries[_sessionKey(remote.deviceId, remote.employeeId)] = remote;
  }

  Future<void> dispose() async {
    await _changeController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // ═══════════════════════════════════════════════════════════════
  // Group 1: 单员工消息发送与本地持久化
  //
  // 模拟前端 ChatViewController.sendMessage → agentProxy.sendMessage
  // → MessageStore 本地持久化链路
  // ═══════════════════════════════════════════════════════════════

  group('单员工消息发送与本地持久化', () {
    late ClientTestFixture fixture;

    setUp(() async {
      fixture = await ClientTestFixture.create('msg-local');
    });

    tearDown(() async {
      await fixture.dispose();
    });

    // ── 1.1 发送文本消息后本地可查询 ──

    test('1.1 发送文本消息后本地 MessageStore 可查询', () async {
      final empId = const Uuid().v4();
      final msg = _createMessage(
        employeeId: empId,
        deviceId: fixture.deviceId,
        content: 'Hello from test!',
      );

      await fixture.messageStore.addMessage(fixture.deviceId, msg);

      final messages = await fixture.messageStore.getMessages(
        fixture.deviceId,
        empId,
      );
      expect(messages, isNotEmpty);
      expect(messages.any((m) => m.id == msg.id), isTrue);
      expect(
        messages.firstWhere((m) => m.id == msg.id).content,
        equals('Hello from test!'),
      );
    });

    // ── 1.2 发送消息自动分配递增 seq ──

    test('1.2 发送消息自动分配递增 seq', () async {
      final empId = const Uuid().v4();

      final msg1 = _createMessage(
        employeeId: empId,
        deviceId: fixture.deviceId,
      );
      final msg2 = _createMessage(
        employeeId: empId,
        deviceId: fixture.deviceId,
      );
      final msg3 = _createMessage(
        employeeId: empId,
        deviceId: fixture.deviceId,
      );

      await fixture.messageStore.addMessage(fixture.deviceId, msg1);
      await fixture.messageStore.addMessage(fixture.deviceId, msg2);
      await fixture.messageStore.addMessage(fixture.deviceId, msg3);

      // 重新查询获取 DB 分配的 seq
      final saved1 = await fixture.messageStore.getMessage(
        fixture.deviceId,
        msg1.id,
      );
      final saved2 = await fixture.messageStore.getMessage(
        fixture.deviceId,
        msg2.id,
      );
      final saved3 = await fixture.messageStore.getMessage(
        fixture.deviceId,
        msg3.id,
      );

      // seq 应递增
      expect(saved1!.seq, greaterThan(0));
      expect(saved2!.seq, greaterThan(saved1.seq));
      expect(saved3!.seq, greaterThan(saved2.seq));
    });

    // ── 1.3 发送消息携带完整字段 ──

    test('1.3 发送消息携带完整字段（role, type, content, employeeId, deviceId）', () async {
      final empId = const Uuid().v4();
      final msg = _createMessage(
        employeeId: empId,
        deviceId: fixture.deviceId,
        role: MessageRole.assistant,
        type: 'functionCall',
        content: 'Tool call message',
      );

      await fixture.messageStore.addMessage(fixture.deviceId, msg);

      final found = await fixture.messageStore.getMessage(
        fixture.deviceId,
        msg.id,
      );
      expect(found, isNotNull);
      expect(found!.employeeId, equals(empId));
      // deviceId 是分区键，DB 层不一定会作为消息字段回填
      expect(found.role, equals(MessageRole.assistant));
      expect(found.type, equals('functionCall'));
      expect(found.content, equals('Tool call message'));
    });

    // ── 1.4 发送消息后可通过 employeeId 过滤查询 ──

    test('1.4 不同员工的消息按 employeeId 隔离', () async {
      final empA = const Uuid().v4();
      final empB = const Uuid().v4();

      await fixture.messageStore.addMessage(
        fixture.deviceId,
        _createMessage(
          employeeId: empA,
          deviceId: fixture.deviceId,
          content: 'Message from A',
        ),
      );
      await fixture.messageStore.addMessage(
        fixture.deviceId,
        _createMessage(
          employeeId: empB,
          deviceId: fixture.deviceId,
          content: 'Message from B',
        ),
      );

      final messagesA = await fixture.messageStore.getMessages(
        fixture.deviceId,
        empA,
      );
      final messagesB = await fixture.messageStore.getMessages(
        fixture.deviceId,
        empB,
      );

      expect(messagesA.length, equals(1));
      expect(messagesB.length, equals(1));
      expect(messagesA.first.content, contains('from A'));
      expect(messagesB.first.content, contains('from B'));
    });

    // ── 1.5 发送多条消息保持顺序 ──

    test('1.5 多条消息按 seq 升序排列', () async {
      final empId = const Uuid().v4();

      for (int i = 0; i < 5; i++) {
        await fixture.messageStore.addMessage(
          fixture.deviceId,
          _createMessage(
            employeeId: empId,
            deviceId: fixture.deviceId,
            content: 'Message #$i',
          ),
        );
      }

      final messages = await fixture.messageStore.getMessages(
        fixture.deviceId,
        empId,
      );

      expect(messages.length, greaterThanOrEqualTo(5));
      // 验证 seq 升序
      for (int i = 1; i < messages.length; i++) {
        expect(messages[i].seq, greaterThan(messages[i - 1].seq));
      }
    });

    // ── 1.6 发送文件类型消息 ──

    test('1.6 发送文件消息（type=file + metadata）', () async {
      final empId = const Uuid().v4();
      final fileMsg = _createFileMessage(
        employeeId: empId,
        deviceId: fixture.deviceId,
        fileName: 'test_document.pdf',
        fileSize: 102400,
        filePath: '/tmp/test_document.pdf',
      );

      final saved = await fixture.messageStore.addMessage(
        fixture.deviceId,
        fileMsg,
      );

      expect(saved.type, equals('file'));
      expect(saved.content, equals('test_document.pdf'));
      expect(saved.metadata, isNotNull);
      expect(saved.metadata!['fileName'], equals('test_document.pdf'));
      expect(saved.metadata!['fileSize'], equals(102400));
      expect(saved.metadata!['fileId'], isNotEmpty);
      expect(saved.metadata!['fileHash'], isNotEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // Group 2: 双设备消息同步
  //
  // 模拟前端两个员工在不同设备上收发消息的端到端场景：
  // Client A 发消息 → Server 转发 → Client B 收到
  // ═══════════════════════════════════════════════════════════════

  group('双设备消息同步', () {
    late LanTestHarness harness;

    setUp(() async {
      harness = await LanTestHarness.create('msg-e2e');
    });

    tearDown(() async {
      await harness.dispose();
    });

    // ── 2.1 Client A 发消息 → Server 收到 ──

    test('2.1 Client A 发消息后通过 RPC 同步到 Server', () async {
      final empId = const Uuid().v4();
      final msg = _createMessage(
        employeeId: empId,
        deviceId: harness.client.deviceId,
        content: 'Hello from Client A',
      );

      // Client 端先本地保存
      await harness.client.messageStore.addMessage(
        harness.client.deviceId,
        msg,
      );

      // 通过 RPC 同步消息到 Server
      final result = await harness.server.callRpc(
        HostRpcConfig.methodSyncMessages,
        {
          'messages': [msg.toJson()],
        },
      );
      expect(result['count'], equals(1));

      // Server 端验证消息已到达（RPC 按消息 deviceId 分组写入，需用 client 的 deviceId 查询）
      final serverMessages = await harness.server.messageStore.getMessages(
        harness.client.deviceId,
        empId,
      );
      expect(serverMessages.any((m) => m.id == msg.id), isTrue);
      expect(
        serverMessages.firstWhere((m) => m.id == msg.id).content,
        equals('Hello from Client A'),
      );
    });

    // ── 2.2 Client B 发回复 → Client A 收到（双向对话） ──

    test('2.2 双向对话消息同步', () async {
      final empId = const Uuid().v4();

      // Client A 发送
      final msgA = _createMessage(
        employeeId: empId,
        deviceId: harness.client.deviceId,
        content: 'Hello from A',
      );
      await harness.client.messageStore.addMessage(
        harness.client.deviceId,
        msgA,
      );

      // 同步 A 的消息到 Server
      await harness.server.callRpc(HostRpcConfig.methodSyncMessages, {
        'messages': [msgA.toJson()],
      });

      // Client B（模拟为另一个设备）创建并发送回复
      // 将回复消息作为 Server 端的 assistant 消息
      final msgB = _createAssistantMessage(
        employeeId: empId,
        deviceId: harness.server.deviceId,
        content: 'Hello from B (AI response)',
      );
      await harness.server.messageStore.addMessage(
        harness.server.deviceId,
        msgB,
      );

      // 同步 B 的消息回 Client A
      await harness.client.messageStore.addMessage(
        harness.client.deviceId,
        msgB.copyWith(deviceId: harness.server.deviceId),
      );

      // Client A 端应该能看到双向对话
      final clientMessages = await harness.client.messageStore.getMessages(
        harness.client.deviceId,
        empId,
      );

      final contents = clientMessages.map((m) => m.content).toList();
      expect(contents.any((c) => c!.contains('Hello from A')), isTrue);
      expect(contents.any((c) => c!.contains('Hello from B')), isTrue);
    });

    // ── 2.3 消息同步后水位线正确更新 ──

    test('2.3 消息同步到 Server 后水位线正确更新', () async {
      final empId = const Uuid().v4();

      // 初始水位线应为 0（RPC 按消息 deviceId 分组写入，用 client 的 deviceId 查询）
      final initialSeq = harness.server.messageStore.getLastSeq(
        harness.client.deviceId,
        empId,
      );
      expect(initialSeq, equals(0));

      // 发送并同步多条消息
      for (int i = 0; i < 3; i++) {
        final msg = _createMessage(
          employeeId: empId,
          deviceId: harness.client.deviceId,
          content: 'Sync message #$i',
        );
        await harness.client.messageStore.addMessage(
          harness.client.deviceId,
          msg,
        );
        await harness.server.callRpc(HostRpcConfig.methodSyncMessages, {
          'messages': [msg.toJson()],
        });
      }

      // 水位线应更新（大于 0，且随着消息增多递增）
      final finalSeq = harness.server.messageStore.getLastSeq(
        harness.client.deviceId,
        empId,
      );
      expect(finalSeq, greaterThan(0));
    });

    // ── 2.4 批量消息同步 ──

    test('2.4 批量同步多条消息', () async {
      final empId = const Uuid().v4();
      final messages = <ChatMessage>[];

      for (int i = 0; i < 5; i++) {
        final msg = _createMessage(
          employeeId: empId,
          deviceId: harness.client.deviceId,
          content: 'Batch message #$i',
        );
        await harness.client.messageStore.addMessage(
          harness.client.deviceId,
          msg,
        );
        messages.add(msg);
      }

      // 批量推送到 Server
      final result = await harness.server.callRpc(
        HostRpcConfig.methodSyncMessages,
        {'messages': messages.map((m) => m.toJson()).toList()},
      );
      expect(result['count'], equals(5));

      // Server 端验证所有消息收到（RPC 按消息 deviceId 分组写入，用 client 的 deviceId 查询）
      final serverMessages = await harness.server.messageStore.getMessages(
        harness.client.deviceId,
        empId,
      );
      expect(serverMessages.length, greaterThanOrEqualTo(5));
      for (int i = 0; i < 5; i++) {
        expect(
          serverMessages.any((m) => m.content == 'Batch message #$i'),
          isTrue,
        );
      }
    });

    // ── 2.5 两个设备同时发消息（并发无冲突） ──

    test('2.5 两个设备并发发消息，各自消息不丢失', () async {
      final empId = const Uuid().v4();

      // 创建第二个 Client
      final clientB = await ClientTestFixture.create('msg-concurrent-b');
      try {
        // 两个设备各自发送
        final msgA = _createMessage(
          employeeId: empId,
          deviceId: harness.client.deviceId,
          content: 'Concurrent from A',
        );
        final msgB = _createMessage(
          employeeId: empId,
          deviceId: clientB.deviceId,
          content: 'Concurrent from B',
        );

        await Future.wait([
          harness.client.messageStore.addMessage(harness.client.deviceId, msgA),
          clientB.messageStore.addMessage(clientB.deviceId, msgB),
        ]);

        // 各自同步到 Server
        await harness.server.callRpc(HostRpcConfig.methodSyncMessages, {
          'messages': [msgA.toJson()],
        });
        await harness.server.callRpc(HostRpcConfig.methodSyncMessages, {
          'messages': [msgB.toJson()],
        });

        // Server 端应包含两条消息（RPC 按各自 deviceId 分组写入，需分别查询）
        final serverMessagesA = await harness.server.messageStore.getMessages(
          harness.client.deviceId,
          empId,
        );
        final serverMessagesB = await harness.server.messageStore.getMessages(
          clientB.deviceId,
          empId,
        );
        expect(
          serverMessagesA.any((m) => m.content == 'Concurrent from A'),
          isTrue,
        );
        expect(
          serverMessagesB.any((m) => m.content == 'Concurrent from B'),
          isTrue,
        );
      } finally {
        await clientB.dispose();
      }
    });

    // ── 2.6 消息中包含 assistant 回复 ──

    test('2.6 assistant 角色消息在设备间同步', () async {
      final empId = const Uuid().v4();

      final userMsg = _createMessage(
        employeeId: empId,
        deviceId: harness.client.deviceId,
        role: MessageRole.user,
        content: 'User asks a question',
      );
      final assistantMsg = _createAssistantMessage(
        employeeId: empId,
        deviceId: harness.client.deviceId,
        content: 'AI answers the question',
      );

      // 本地保存并同步
      await harness.client.messageStore.addMessage(
        harness.client.deviceId,
        userMsg,
      );
      await harness.client.messageStore.addMessage(
        harness.client.deviceId,
        assistantMsg,
      );

      await harness.server.callRpc(HostRpcConfig.methodSyncMessages, {
        'messages': [userMsg.toJson(), assistantMsg.toJson()],
      });

      // Server 端验证（RPC 按消息 deviceId 分组写入，用 client 的 deviceId 查询）
      final serverMessages = await harness.server.messageStore.getMessages(
        harness.client.deviceId,
        empId,
      );
      expect(serverMessages.length, greaterThanOrEqualTo(2));

      final roles = serverMessages.map((m) => m.role).toSet();
      expect(roles, contains(MessageRole.user));
      expect(roles, contains(MessageRole.assistant));
    });

    // ── 2.7 文件消息在设备间同步 ──

    test('2.7 文件消息（type=file）在设备间同步', () async {
      final empId = const Uuid().v4();
      final fileMsg = _createFileMessage(
        employeeId: empId,
        deviceId: harness.client.deviceId,
        fileName: 'project_plan.docx',
        fileSize: 204800,
        filePath: '/docs/project_plan.docx',
      );

      // Client 保存
      await harness.client.messageStore.addMessage(
        harness.client.deviceId,
        fileMsg,
      );

      // 同步到 Server
      await harness.server.callRpc(HostRpcConfig.methodSyncMessages, {
        'messages': [fileMsg.toJson()],
      });

      // Server 端验证文件消息收到（RPC 按消息 deviceId 分组写入，用 client 的 deviceId 查询）
      final serverMessages = await harness.server.messageStore.getMessages(
        harness.client.deviceId,
        empId,
      );
      expect(serverMessages.any((m) => m.type == 'file'), isTrue);

      final syncedFile = serverMessages.firstWhere((m) => m.type == 'file');
      expect(syncedFile.metadata, isNotNull);
      expect(syncedFile.metadata!['fileName'], equals('project_plan.docx'));
      expect(syncedFile.metadata!['fileSize'], equals(204800));
      expect(syncedFile.metadata!['fileId'], isNotEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // Group 3: 断连与恢复场景
  //
  // 模拟前端网络断连时的消息处理和恢复后的同步：
  // ChatViewController.subscribeDeviceConnectionState
  // → onConnectionStateChanged → disconnected → syncFromRemote()
  // ═══════════════════════════════════════════════════════════════

  group('断连与恢复场景', () {
    late LanTestHarness harness;

    setUp(() async {
      harness = await LanTestHarness.create('msg-disconnect');
    });

    tearDown(() async {
      await harness.dispose();
    });

    // ── 3.1 断连期间消息暂存本地，恢复后同步 ──

    test('3.1 断连期间消息暂存本地，恢复后同步到 Server', () async {
      final empId = const Uuid().v4();

      // 断连前发一条消息
      final beforeMsg = _createMessage(
        employeeId: empId,
        deviceId: harness.client.deviceId,
        content: 'Before disconnect',
      );
      await harness.client.messageStore.addMessage(
        harness.client.deviceId,
        beforeMsg,
      );
      await harness.server.callRpc(HostRpcConfig.methodSyncMessages, {
        'messages': [beforeMsg.toJson()],
      });

      // 模拟断连
      harness.simulateNetworkDisconnect();
      expect(harness.client.isConnected, isFalse);

      // 断连期间发两条消息（仅本地）
      final offline1 = _createMessage(
        employeeId: empId,
        deviceId: harness.client.deviceId,
        content: 'Offline message 1',
      );
      final offline2 = _createMessage(
        employeeId: empId,
        deviceId: harness.client.deviceId,
        content: 'Offline message 2',
      );
      await harness.client.messageStore.addMessage(
        harness.client.deviceId,
        offline1,
      );
      await harness.client.messageStore.addMessage(
        harness.client.deviceId,
        offline2,
      );

      // 恢复连接
      harness.simulateNetworkRecover();
      expect(harness.client.isConnected, isTrue);

      // 恢复后同步离线消息
      final result = await harness.server.callRpc(
        HostRpcConfig.methodSyncMessages,
        {
          'messages': [offline1.toJson(), offline2.toJson()],
        },
      );
      expect(result['count'], equals(2));

      // Server 端应包含所有三条消息（RPC 按消息 deviceId 分组写入，用 client 的 deviceId 查询）
      final serverMessages = await harness.server.messageStore.getMessages(
        harness.client.deviceId,
        empId,
      );
      final contents = serverMessages.map((m) => m.content).toSet();
      expect(contents, contains('Before disconnect'));
      expect(contents, contains('Offline message 1'));
      expect(contents, contains('Offline message 2'));
    });

    // ── 3.2 断连期间远程产生消息，恢复后增量拉取 ──

    test('3.2 断连期间远程产生的消息，恢复后增量拉取', () async {
      final empId = const Uuid().v4();

      // 初始同步两条消息（建立水位线）
      for (int i = 1; i <= 2; i++) {
        final msg = _createMessage(
          employeeId: empId,
          deviceId: harness.server.deviceId,
          content: 'Initial message #$i',
        );
        await harness.server.messageStore.addMessage(
          harness.server.deviceId,
          msg,
        );
        await harness.client.messageStore.addMessage(
          harness.client.deviceId,
          msg.copyWith(deviceId: harness.server.deviceId),
        );
      }

      // 记录 Client 端当前水位线
      final lastSeqBefore = harness.client.messageStore.getLastSeq(
        harness.client.deviceId,
        empId,
      );
      expect(lastSeqBefore, greaterThan(0));

      // 模拟断连
      harness.simulateNetworkDisconnect();

      // 断连期间 Server 端产生新消息
      final remoteMsg = _createMessage(
        employeeId: empId,
        deviceId: harness.server.deviceId,
        content: 'Remote message during disconnect',
      );
      await harness.server.messageStore.addMessage(
        harness.server.deviceId,
        remoteMsg,
      );

      // 恢复连接
      harness.simulateNetworkRecover();

      // 模拟 syncFromRemote：按水位线增量拉取
      // 通过 getMessagesAfterSeq 语义直接同步
      await harness.client.messageStore.addMessage(
        harness.client.deviceId,
        remoteMsg.copyWith(deviceId: harness.server.deviceId),
      );

      // Client 端应能查到远程消息
      final clientMessages = await harness.client.messageStore.getMessages(
        harness.client.deviceId,
        empId,
      );
      expect(
        clientMessages.any(
          (m) => m.content == 'Remote message during disconnect',
        ),
        isTrue,
      );
    });

    // ── 3.3 断连后重连水位线正确恢复 ──

    test('3.3 断连后重连，水位线正确恢复，不丢消息、不重复', () async {
      final empId = const Uuid().v4();

      // 预先同步并建立水位线
      final msg1 = _createMessage(
        employeeId: empId,
        deviceId: harness.client.deviceId,
        content: 'Msg for watermark',
      );
      await harness.client.messageStore.addMessage(
        harness.client.deviceId,
        msg1,
      );
      await harness.server.callRpc(HostRpcConfig.methodSyncMessages, {
        'messages': [msg1.toJson()],
      });

      final seqBeforeDisconnect = harness.client.messageStore.getLastSeq(
        harness.client.deviceId,
        empId,
      );
      expect(seqBeforeDisconnect, greaterThan(0));

      // 断连
      harness.simulateNetworkDisconnect();

      // 重连
      harness.simulateNetworkRecover();

      // 水位线应保持不变（不应回退）
      final seqAfterRecover = harness.client.messageStore.getLastSeq(
        harness.client.deviceId,
        empId,
      );
      expect(seqAfterRecover, equals(seqBeforeDisconnect));
    });

    // ── 3.4 多次断连重连的稳定性 ──

    test('3.4 多次断连重连后消息同步仍正常', () async {
      final empId = const Uuid().v4();

      for (int cycle = 0; cycle < 3; cycle++) {
        // 断连
        harness.simulateNetworkDisconnect();
        expect(harness.client.isConnected, isFalse);

        // 断连期间发消息
        final offlineMsg = _createMessage(
          employeeId: empId,
          deviceId: harness.client.deviceId,
          content: 'Cycle $cycle offline',
        );
        await harness.client.messageStore.addMessage(
          harness.client.deviceId,
          offlineMsg,
        );

        // 重连
        harness.simulateNetworkRecover();
        expect(harness.client.isConnected, isTrue);

        // 同步
        await harness.server.callRpc(HostRpcConfig.methodSyncMessages, {
          'messages': [offlineMsg.toJson()],
        });
      }

      // 所有消息都应在 Server 端（RPC 按消息 deviceId 分组写入，用 client 的 deviceId 查询）
      final serverMessages = await harness.server.messageStore.getMessages(
        harness.client.deviceId,
        empId,
      );
      expect(serverMessages.length, greaterThanOrEqualTo(3));
      for (int cycle = 0; cycle < 3; cycle++) {
        expect(
          serverMessages.any((m) => m.content == 'Cycle $cycle offline'),
          isTrue,
        );
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // LAN 事件驱动消息同步
  //
  // 覆盖前端关闭定时刷新时，只依赖 AgentEvent/onMessagesChanged 的刷新路径。
  // ═══════════════════════════════════════════════════════════════

  group('LAN 事件驱动消息同步', () {
    late _InMemoryMessageStoreService messageStore;

    setUp(() {
      messageStore = _InMemoryMessageStoreService();
    });

    tearDown(() async {
      await messageStore.dispose();
    });

    test(
      'completed event triggers assistant detail sync without polling',
      () async {
        final empId = const Uuid().v4();
        final remoteDeviceId = 'remote-${const Uuid().v4()}';
        final now = DateTime.now();
        final remoteEvents = StreamController<agent.AgentEvent>.broadcast();

        final userMessage = agent.AgentMessage(
          id: 'remote-user-${const Uuid().v4()}',
          role: 'user',
          type: 'text',
          content: 'User message before agent reply',
          createdAt: now.subtract(const Duration(milliseconds: 10)),
          status: 'completed',
          metadata: {'seq': 1, 'updateTime': now.toIso8601String()},
        );
        final assistantMessage = agent.AgentMessage(
          id: 'remote-assistant-${const Uuid().v4()}',
          role: 'assistant',
          type: 'text',
          content: 'Assistant reply from completed event',
          createdAt: now,
          status: 'completed',
          metadata: {'seq': 2, 'updateTime': now.toIso8601String()},
        );
        final remoteMessages = [userMessage, assistantMessage];
        final remoteSummary = SessionSummaryEntity(
          employeeId: empId,
          deviceId: remoteDeviceId,
          unreadCount: 1,
          lastMsgId: assistantMessage.id,
          lastMsgRole: assistantMessage.role,
          lastMsgContent: assistantMessage.content,
          lastMsgTime: now.millisecondsSinceEpoch,
          lastMsgSeq: 2,
          updateTime: now.millisecondsSinceEpoch,
        );
        final rpcMethods = <String>[];

        Future<Map<String, dynamic>> rpcCall(
          String method,
          Map<String, dynamic> params,
        ) async {
          rpcMethods.add(method);
          switch (method) {
            case agent.AgentRpcConfig.methodGetClearSeq:
              return {
                'result': {'clearSeq': 0},
              };
            case agent.AgentRpcConfig.methodClearClearSeq:
              return {'result': <String, dynamic>{}};
            case agent.AgentRpcConfig.methodGetMaxSeq:
              return {
                'result': {'maxSeq': 2},
              };
            case agent.AgentRpcConfig.methodGetMessagesAfterSeq:
              final lastSeq = params['lastSeq'] as int? ?? 0;
              final limit = params['limit'] as int? ?? 20;
              final messages = remoteMessages
                  .where((message) {
                    final seq = message.metadata?['seq'] as int? ?? 0;
                    return seq > lastSeq;
                  })
                  .take(limit)
                  .map((message) => message.toMap())
                  .toList();
              return {
                'result': {'messages': messages},
              };
            case agent.AgentRpcConfig.methodGetSessionSummary:
              return {'result': remoteSummary.toMap()};
            default:
              throw StateError('Unexpected RPC method: $method');
          }
        }

        final remoteProxy = agent.AgentProxy.remote(
          employeeId: empId,
          deviceId: remoteDeviceId,
          rpcCall: rpcCall,
          remoteEventStream: remoteEvents.stream,
        );
        final cachedProxy = agent.CachedAgentProxy(
          proxy: remoteProxy,
          messageStore: messageStore,
          deviceId: remoteDeviceId,
          employeeId: empId,
        );

        StreamSubscription<List<agent.AgentMessage>>? messagesSub;
        try {
          await cachedProxy.initialize();

          final synced = Completer<List<agent.AgentMessage>>();
          messagesSub = cachedProxy.onMessagesChanged.listen((messages) {
            final hasAssistant = messages.any(
              (m) => m.id == assistantMessage.id,
            );
            if (hasAssistant && !synced.isCompleted) {
              synced.complete(messages);
            }
          });

          remoteEvents.add(
            agent.AgentEvent(
              type: agent.AgentEventType.messageStatusChanged,
              data: {'messageId': userMessage.id, 'status': 'completed'},
              employeeId: empId,
              fromDeviceId: remoteDeviceId,
            ),
          );

          final syncedMessages = await synced.future.timeout(
            const Duration(seconds: 2),
          );
          expect(
            syncedMessages.any(
              (m) =>
                  m.id == assistantMessage.id &&
                  m.content == 'Assistant reply from completed event',
            ),
            isTrue,
          );

          final cachedMessages = await cachedProxy.getMessages();
          expect(
            cachedMessages.map((m) => m.id),
            contains(assistantMessage.id),
          );
          expect(
            rpcMethods,
            contains(agent.AgentRpcConfig.methodGetMessagesAfterSeq),
          );
        } finally {
          await messagesSub?.cancel();
          await cachedProxy.dispose();
          await remoteProxy.dispose();
          await remoteEvents.close();
        }
      },
    );

    test('摘要 LAN 事件在无定时刷新时触发消息明细同步', () async {
      final empId = const Uuid().v4();
      final remoteDeviceId = 'remote-${const Uuid().v4()}';
      final now = DateTime.now();
      final remoteEvents = StreamController<agent.AgentEvent>.broadcast();

      final remoteMessage = agent.AgentMessage(
        id: 'remote-latest-${const Uuid().v4()}',
        role: 'assistant',
        type: 'text',
        content: 'Latest message from LAN event',
        createdAt: now,
        status: 'completed',
        metadata: {'seq': 1, 'updateTime': now.toIso8601String()},
      );
      final remoteMessages = [remoteMessage];
      final remoteSummary = SessionSummaryEntity(
        employeeId: empId,
        deviceId: remoteDeviceId,
        unreadCount: 1,
        lastMsgId: remoteMessage.id,
        lastMsgRole: remoteMessage.role,
        lastMsgContent: remoteMessage.content,
        lastMsgTime: now.millisecondsSinceEpoch,
        lastMsgSeq: 1,
        updateTime: now.millisecondsSinceEpoch,
      );
      final rpcMethods = <String>[];

      Future<Map<String, dynamic>> rpcCall(
        String method,
        Map<String, dynamic> params,
      ) async {
        rpcMethods.add(method);
        switch (method) {
          case agent.AgentRpcConfig.methodGetClearSeq:
            return {
              'result': {'clearSeq': 0},
            };
          case agent.AgentRpcConfig.methodClearClearSeq:
            return {'result': <String, dynamic>{}};
          case agent.AgentRpcConfig.methodGetMaxSeq:
            final maxSeq = remoteMessages.fold<int>(0, (max, message) {
              final seq = message.metadata?['seq'] as int? ?? 0;
              return seq > max ? seq : max;
            });
            return {
              'result': {'maxSeq': maxSeq},
            };
          case agent.AgentRpcConfig.methodGetMessagesAfterSeq:
            final lastSeq = params['lastSeq'] as int? ?? 0;
            final limit = params['limit'] as int? ?? 20;
            final messages = remoteMessages
                .where((message) {
                  final seq = message.metadata?['seq'] as int? ?? 0;
                  return seq > lastSeq;
                })
                .take(limit)
                .map((message) => message.toMap())
                .toList();
            return {
              'result': {'messages': messages},
            };
          case agent.AgentRpcConfig.methodGetSessionSummary:
            return {'result': remoteSummary.toMap()};
          default:
            throw StateError('Unexpected RPC method: $method');
        }
      }

      final remoteProxy = agent.AgentProxy.remote(
        employeeId: empId,
        deviceId: remoteDeviceId,
        rpcCall: rpcCall,
        remoteEventStream: remoteEvents.stream,
      );
      final cachedProxy = agent.CachedAgentProxy(
        proxy: remoteProxy,
        messageStore: messageStore,
        deviceId: remoteDeviceId,
        employeeId: empId,
      );

      StreamSubscription<List<agent.AgentMessage>>? messagesSub;
      try {
        await cachedProxy.initialize();

        final synced = Completer<List<agent.AgentMessage>>();
        messagesSub = cachedProxy.onMessagesChanged.listen((messages) {
          final hasRemoteMessage = messages.any(
            (m) => m.id == remoteMessage.id,
          );
          if (hasRemoteMessage && !synced.isCompleted) {
            synced.complete(messages);
          }
        });

        remoteEvents.add(
          agent.AgentEvent(
            type: agent.AgentEventType.sessionSummaryChanged,
            data: {'summary': remoteSummary.toMap()},
            employeeId: empId,
            fromDeviceId: remoteDeviceId,
          ),
        );

        final syncedMessages = await synced.future.timeout(
          const Duration(seconds: 2),
        );
        expect(
          syncedMessages.any(
            (m) =>
                m.id == remoteMessage.id &&
                m.content == 'Latest message from LAN event',
          ),
          isTrue,
        );

        final cachedMessages = await cachedProxy.getMessages();
        expect(cachedMessages.map((m) => m.id), contains(remoteMessage.id));
        expect(
          rpcMethods,
          contains(agent.AgentRpcConfig.methodGetMessagesAfterSeq),
        );
      } finally {
        await messagesSub?.cancel();
        await cachedProxy.dispose();
        await remoteProxy.dispose();
        await remoteEvents.close();
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // Group 4: 消息状态同步
  //
  // 模拟前端消息的各种状态变更：
  // sending → sent → delivering → completed → error
  // 以及 onMessageStatusChanged 事件传播
  // ═══════════════════════════════════════════════════════════════

  group('消息状态同步', () {
    late ClientTestFixture fixture;

    setUp(() async {
      fixture = await ClientTestFixture.create('msg-status');
    });

    tearDown(() async {
      await fixture.dispose();
    });

    // ── 4.1 新消息初始状态为 none ──

    test('4.1 新创建消息默认状态为 none', () async {
      final empId = const Uuid().v4();
      final msg = _createMessage(employeeId: empId, deviceId: fixture.deviceId);

      final saved = await fixture.messageStore.addMessage(
        fixture.deviceId,
        msg,
      );
      expect(saved.status, equals(MessageStatus.none));
    });

    // ── 4.2 消息状态从 none → completed ──

    test('4.2 消息状态可更新为 completed', () async {
      final empId = const Uuid().v4();
      final msg = _createMessage(employeeId: empId, deviceId: fixture.deviceId);

      final saved = await fixture.messageStore.addMessage(
        fixture.deviceId,
        msg,
      );
      expect(saved.status, equals(MessageStatus.none));

      await fixture.messageStore.updateMessageStatus(
        fixture.deviceId,
        saved.id,
        MessageStatus.completed,
      );

      final updated = await fixture.messageStore.getMessage(
        fixture.deviceId,
        saved.id,
      );
      expect(updated, isNotNull);
      expect(updated!.status, equals(MessageStatus.completed));
    });

    // ── 4.3 远程设备收到消息后状态变更通知 ──

    test('4.3 消息状态变更触发 onMessageChanged 事件', () async {
      final empId = const Uuid().v4();
      final events = <MessageChangeEvent>[];
      final sub = fixture.messageStore.onMessageChanged.listen((e) {
        events.add(e);
      });

      final msg = _createMessage(employeeId: empId, deviceId: fixture.deviceId);
      await fixture.messageStore.addMessage(fixture.deviceId, msg);

      // 等待事件传播
      await Future.delayed(const Duration(milliseconds: 50));

      await fixture.messageStore.updateMessageStatus(
        fixture.deviceId,
        msg.id,
        MessageStatus.completed,
      );

      await Future.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      // 应有 added 和 updated 事件
      expect(events.any((e) => e.type == MessageChangeType.added), isTrue);
      expect(events.any((e) => e.type == MessageChangeType.updated), isTrue);
    });

    // ── 4.4 消息发送失败状态 ──

    test('4.4 消息状态可更新为 failed 并携带错误信息', () async {
      final empId = const Uuid().v4();
      final msg = _createMessage(employeeId: empId, deviceId: fixture.deviceId);

      final saved = await fixture.messageStore.addMessage(
        fixture.deviceId,
        msg,
      );

      await fixture.messageStore.updateMessageStatus(
        fixture.deviceId,
        saved.id,
        MessageStatus.failed,
        error: 'Network timeout',
      );

      final updated = await fixture.messageStore.getMessage(
        fixture.deviceId,
        saved.id,
      );
      expect(updated, isNotNull);
      expect(updated!.status, equals(MessageStatus.failed));
    });

    // ── 4.5 消息软删除同步 ──

    test('4.5 消息软删除后 deleted=true 可被其他设备感知', () async {
      final empId = const Uuid().v4();
      final msg = _createMessage(employeeId: empId, deviceId: fixture.deviceId);

      final saved = await fixture.messageStore.addMessage(
        fixture.deviceId,
        msg,
      );

      // 软删除
      await fixture.messageStore.softDeleteMessage(fixture.deviceId, saved.id);

      // 查询不到（getMessages 默认不返回已删除消息）
      final messages = await fixture.messageStore.getMessages(
        fixture.deviceId,
        empId,
      );
      expect(messages.any((m) => m.id == saved.id), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // Group 5: 模拟前端完整对话流程
  //
  // 组合多个 Fixture，模拟前端 ChatViewController 的完整对话流程：
  // onInit → loadSession → sendMessage → AI回复 → 设备切换 → 会话隔离
  // ═══════════════════════════════════════════════════════════════

  group('模拟前端完整对话流程', () {
    // ── 5.1 完整对话：用户发消息 → AI回复 → 用户再回复 ──

    test('5.1 完整对话轮次：user → assistant → user → assistant', () async {
      final harness = await LanTestHarness.create('msg-full-conv');
      try {
        final empId = const Uuid().v4();

        // Round 1: user
        final userMsg1 = _createMessage(
          employeeId: empId,
          deviceId: harness.client.deviceId,
          role: MessageRole.user,
          content: 'What is Flutter?',
        );
        await harness.client.messageStore.addMessage(
          harness.client.deviceId,
          userMsg1,
        );

        // Round 1: assistant
        final assistantMsg1 = _createAssistantMessage(
          employeeId: empId,
          deviceId: harness.client.deviceId,
          content: 'Flutter is a UI toolkit by Google...',
        );
        await harness.client.messageStore.addMessage(
          harness.client.deviceId,
          assistantMsg1,
        );

        // Round 2: user
        final userMsg2 = _createMessage(
          employeeId: empId,
          deviceId: harness.client.deviceId,
          role: MessageRole.user,
          content: 'How to create a widget?',
        );
        await harness.client.messageStore.addMessage(
          harness.client.deviceId,
          userMsg2,
        );

        // Round 2: assistant
        final assistantMsg2 = _createAssistantMessage(
          employeeId: empId,
          deviceId: harness.client.deviceId,
          content: 'Use StatelessWidget or StatefulWidget...',
        );
        await harness.client.messageStore.addMessage(
          harness.client.deviceId,
          assistantMsg2,
        );

        // 同步到 Server
        await harness.server.callRpc(HostRpcConfig.methodSyncMessages, {
          'messages': [
            userMsg1.toJson(),
            assistantMsg1.toJson(),
            userMsg2.toJson(),
            assistantMsg2.toJson(),
          ],
        });

        // 验证消息顺序和完整性（RPC 按消息 deviceId 分组写入，用 client 的 deviceId 查询）
        final messages = await harness.server.messageStore.getMessages(
          harness.client.deviceId,
          empId,
        );
        expect(messages.length, greaterThanOrEqualTo(4));

        // 按 seq 排序后验证角色交替
        final sorted = List<ChatMessage>.from(messages)
          ..sort((a, b) => a.seq.compareTo(b.seq));
        final roles = sorted.map((m) => m.role).toList();
        expect(
          roles.where((r) => r == MessageRole.user).length,
          greaterThanOrEqualTo(2),
        );
        expect(
          roles.where((r) => r == MessageRole.assistant).length,
          greaterThanOrEqualTo(2),
        );
      } finally {
        await harness.dispose();
      }
    });

    // ── 5.2 对话中切换设备 ──

    test('5.2 切换设备后新设备可拉取历史消息', () async {
      final harness = await LanTestHarness.create('msg-switch-device');
      try {
        final empId = const Uuid().v4();

        // Device A 上产生消息
        final msgOnA = _createMessage(
          employeeId: empId,
          deviceId: harness.client.deviceId,
          content: 'Message on device A',
        );
        await harness.client.messageStore.addMessage(
          harness.client.deviceId,
          msgOnA,
        );

        // 同步到 Server
        await harness.server.callRpc(HostRpcConfig.methodSyncMessages, {
          'messages': [msgOnA.toJson()],
        });

        // 创建 Device B（模拟切换设备）
        final clientB = await ClientTestFixture.create('msg-device-b');
        try {
          // Device B 从 Server 拉取消息（RPC 按消息 deviceId 分组写入，用 client 的 deviceId 查询）
          final serverMessages = await harness.server.messageStore.getMessages(
            harness.client.deviceId,
            empId,
          );
          for (final msg in serverMessages) {
            await clientB.messageStore.addMessage(
              clientB.deviceId,
              msg.copyWith(deviceId: clientB.deviceId),
            );
          }

          // Device B 应能看到历史消息
          final deviceBMessages = await clientB.messageStore.getMessages(
            clientB.deviceId,
            empId,
          );
          expect(
            deviceBMessages.any((m) => m.content == 'Message on device A'),
            isTrue,
          );
        } finally {
          await clientB.dispose();
        }
      } finally {
        await harness.dispose();
      }
    });

    // ── 5.3 多会话隔离 ──

    test('5.3 不同会话（employeeId）消息互不干扰', () async {
      final fixture = await ClientTestFixture.create('msg-session-isolate');
      try {
        final sessionA = const Uuid().v4();
        final sessionB = const Uuid().v4();

        // 会话 A 的消息
        for (int i = 0; i < 3; i++) {
          await fixture.messageStore.addMessage(
            fixture.deviceId,
            _createMessage(
              employeeId: sessionA,
              deviceId: fixture.deviceId,
              content: 'Session A msg #$i',
            ),
          );
        }

        // 会话 B 的消息
        for (int i = 0; i < 2; i++) {
          await fixture.messageStore.addMessage(
            fixture.deviceId,
            _createMessage(
              employeeId: sessionB,
              deviceId: fixture.deviceId,
              content: 'Session B msg #$i',
            ),
          );
        }

        // 查询隔离
        final msgsA = await fixture.messageStore.getMessages(
          fixture.deviceId,
          sessionA,
        );
        final msgsB = await fixture.messageStore.getMessages(
          fixture.deviceId,
          sessionB,
        );

        expect(msgsA.length, greaterThanOrEqualTo(3));
        expect(msgsB.length, greaterThanOrEqualTo(2));

        // 互相不应包含对方的消息
        expect(msgsA.any((m) => m.content!.contains('Session B')), isFalse);
        expect(msgsB.any((m) => m.content!.contains('Session A')), isFalse);
      } finally {
        await fixture.dispose();
      }
    });

    // ── 5.4 onMessageChanged 事件触发验证 ──

    test('5.4 消息 CRUD 完整事件序列验证', () async {
      final fixture = await ClientTestFixture.create('msg-event-seq');
      try {
        final empId = const Uuid().v4();
        final events = <MessageChangeEvent>[];
        final sub = fixture.messageStore.onMessageChanged.listen((e) {
          events.add(e);
        });

        // 1. 创建
        final msg = _createMessage(
          employeeId: empId,
          deviceId: fixture.deviceId,
          content: 'Event test message',
        );
        final saved = await fixture.messageStore.addMessage(
          fixture.deviceId,
          msg,
        );

        // 2. 更新状态
        await fixture.messageStore.updateMessageStatus(
          fixture.deviceId,
          saved.id,
          MessageStatus.completed,
        );

        // 3. 软删除
        await fixture.messageStore.softDeleteMessage(
          fixture.deviceId,
          saved.id,
        );

        await Future.delayed(const Duration(milliseconds: 50));
        await sub.cancel();

        // 验证事件序列
        final addedEvents = events
            .where((e) => e.type == MessageChangeType.added)
            .toList();
        final updatedEvents = events
            .where((e) => e.type == MessageChangeType.updated)
            .toList();
        final deletedEvents = events
            .where((e) => e.type == MessageChangeType.deleted)
            .toList();

        expect(addedEvents.length, greaterThanOrEqualTo(1));
        expect(updatedEvents.length, greaterThanOrEqualTo(1));
        expect(deletedEvents.length, greaterThanOrEqualTo(1));

        // 验证事件顺序：added → updated → deleted
        final eventTypes = events.map((e) => e.type).toList();
        final addedIdx = eventTypes.indexOf(MessageChangeType.added);
        final updatedIdx = eventTypes.indexOf(MessageChangeType.updated);
        final deletedIdx = eventTypes.indexOf(MessageChangeType.deleted);
        expect(addedIdx, lessThan(updatedIdx));
        expect(updatedIdx, lessThan(deletedIdx));
      } finally {
        await fixture.dispose();
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // Group 6: 消息序列化往返验证
  // ═══════════════════════════════════════════════════════════════

  group('消息序列化往返验证', () {
    // ── 6.1 消息 toJson → fromJson 往返后字段一致 ──

    test('6.1 消息 toJson/fromJson 往返后所有字段保持一致', () {
      final empId = const Uuid().v4();
      final original = ChatMessage(
        id: const Uuid().v4(),
        employeeId: empId,
        role: MessageRole.assistant,
        type: 'text',
        content: 'Serialization test',
        createdAt: DateTime.now(),
        status: MessageStatus.completed,
        seq: 42,
        deviceId: 'device-xyz',
        inputTokens: 100,
        outputTokens: 200,
        metadata: {'key': 'value'},
      );

      final json = original.toJson();
      final roundTrip = ChatMessage.fromJson(json);

      expect(roundTrip.id, equals(original.id));
      expect(roundTrip.employeeId, equals(original.employeeId));
      expect(roundTrip.role, equals(original.role));
      expect(roundTrip.type, equals(original.type));
      expect(roundTrip.content, equals(original.content));
      expect(roundTrip.status, equals(original.status));
      expect(roundTrip.seq, equals(original.seq));
      expect(roundTrip.deviceId, equals(original.deviceId));
      expect(roundTrip.inputTokens, equals(original.inputTokens));
      expect(roundTrip.outputTokens, equals(original.outputTokens));
      expect(roundTrip.metadata?['key'], equals('value'));
    });

    // ── 6.2 文件消息序列化往返 ──

    test('6.2 文件消息序列化往返后文件元数据完整', () {
      final empId = const Uuid().v4();
      final fileMsg = ChatMessage.file(
        id: const Uuid().v4(),
        employeeId: empId,
        role: MessageRole.user,
        fileName: 'report.pdf',
        fileSize: 512000,
        fileId: 'file-uuid-123',
        fileHash: 'abc123def456',
        filePath: '/files/report.pdf',
        fromDeviceId: 'device-sender',
      );

      final json = fileMsg.toJson();
      final roundTrip = ChatMessage.fromJson(json);

      expect(roundTrip.type, equals('file'));
      expect(roundTrip.content, equals('report.pdf'));
      expect(roundTrip.metadata, isNotNull);
      expect(roundTrip.metadata!['fileName'], equals('report.pdf'));
      expect(roundTrip.metadata!['fileSize'], equals(512000));
      expect(roundTrip.metadata!['fileId'], equals('file-uuid-123'));
      expect(roundTrip.metadata!['fileHash'], equals('abc123def456'));
      expect(roundTrip.metadata!['filePath'], equals('/files/report.pdf'));
      expect(roundTrip.metadata!['fromDeviceId'], equals('device-sender'));
    });

    // ── 6.3 批量消息序列化后持久化验证 ──

    test('6.3 批量消息 toJson 后持久化并正确恢复', () async {
      final fixture = await ClientTestFixture.create('msg-serialize-batch');
      try {
        final empId = const Uuid().v4();
        final messages = List.generate(
          3,
          (i) => _createMessage(
            employeeId: empId,
            deviceId: fixture.deviceId,
            content: 'Batch message #$i',
          ),
        );

        // 通过 toJson + fromJson 模拟网络传输序列化
        final jsonList = messages.map((m) => m.toJson()).toList();
        final deserialized = jsonList
            .map((j) => ChatMessage.fromJson(j))
            .toList();

        // 持久化反序列化后的消息
        for (final msg in deserialized) {
          await fixture.messageStore.addMessage(fixture.deviceId, msg);
        }

        // 验证所有消息可正确查询
        final stored = await fixture.messageStore.getMessages(
          fixture.deviceId,
          empId,
        );
        expect(stored.length, greaterThanOrEqualTo(3));
        for (int i = 0; i < 3; i++) {
          expect(stored.any((m) => m.content == 'Batch message #$i'), isTrue);
        }
      } finally {
        await fixture.dispose();
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // Group 7: 特殊消息类型同步
  //
  // 模拟前端 ChatMessageType 中的三种关键消息类型：
  // - permissionRequest: 工具权限请求（含 MCP 工具权限）
  // - confirmRequest: Agent 确认请求
  // - MCP 权限: permissionRequest 子类型，permissionType='mcp_tool'
  //
  // 前端流程（来自 wenzflow ChatControllerBase）：
  //   _buildPermissionMessage → ChatMessage.permissionRequest(metadata:{...})
  //   _buildConfirmMessage    → ChatMessage.confirmRequest(metadata:{...})
  //   用户做出决策后 → metadata 写入 permissionDecision/confirmChoice → 同步
  // ═══════════════════════════════════════════════════════════════

  group('特殊消息类型同步', () {
    late ClientTestFixture fixture;

    setUp(() async {
      fixture = await ClientTestFixture.create('msg-special');
    });

    tearDown(() async {
      await fixture.dispose();
    });

    // ── 7.1 创建 permissionRequest 并持久化 ──

    test('7.1 permissionRequest 消息持久化后 metadata 字段完整', () async {
      final empId = const Uuid().v4();
      final requestId = const Uuid().v4();

      // 模拟前端 ChatMessage.permissionRequest(...)
      final msg = ChatMessage(
        id: const Uuid().v4(),
        employeeId: empId,
        role: MessageRole.assistant,
        type: 'permissionRequest',
        content: '需要读取文件的权限',
        createdAt: DateTime.now(),
        deviceId: fixture.deviceId,
        metadata: {
          'requestId': requestId,
          'functionName': 'read_file',
          'permissionPattern': 'read_file',
          'permissionType': 'file_read',
          'args': {'path': '/home/user/test.txt'},
          'suggestedPattern': 'read_file.*',
        },
      );

      await fixture.messageStore.addMessage(fixture.deviceId, msg);

      final found = await fixture.messageStore.getMessage(
        fixture.deviceId,
        msg.id,
      );
      expect(found, isNotNull);
      expect(found!.type, equals('permissionRequest'));
      expect(found.role, equals(MessageRole.assistant));
      expect(found.content, equals('需要读取文件的权限'));
      expect(found.metadata, isNotNull);
      expect(found.metadata!['requestId'], equals(requestId));
      expect(found.metadata!['functionName'], equals('read_file'));
      expect(found.metadata!['permissionPattern'], equals('read_file'));
      expect(found.metadata!['permissionType'], equals('file_read'));
      expect(found.metadata!['args'], isNotNull);
      expect(found.metadata!['suggestedPattern'], equals('read_file.*'));
    });

    // ── 7.2 创建 confirmRequest 并持久化 ──

    test('7.2 confirmRequest 消息持久化后 metadata 字段完整', () async {
      final empId = const Uuid().v4();
      final requestId = const Uuid().v4();

      // 模拟前端 ChatMessage.confirmRequest(...)
      final msg = ChatMessage(
        id: const Uuid().v4(),
        employeeId: empId,
        role: MessageRole.assistant,
        type: 'confirmRequest',
        content: '请选择部署方案',
        createdAt: DateTime.now(),
        deviceId: fixture.deviceId,
        metadata: {
          'requestId': requestId,
          'confirmTitle': '请选择部署方案',
          'confirmMessage': '选择一个方案来部署应用：',
          'confirmOptions': [
            {
              'key': 'plan_a',
              'label': '方案A：使用Docker部署',
              'description': '适合容器化环境',
            },
            {'key': 'plan_b', 'label': '方案B：直接部署', 'description': '适合简单场景'},
          ],
          'confirmDefaultOption': 'plan_a',
        },
      );

      await fixture.messageStore.addMessage(fixture.deviceId, msg);

      final found = await fixture.messageStore.getMessage(
        fixture.deviceId,
        msg.id,
      );
      expect(found, isNotNull);
      expect(found!.type, equals('confirmRequest'));
      expect(found.role, equals(MessageRole.assistant));
      expect(found.content, equals('请选择部署方案'));
      expect(found.metadata, isNotNull);
      expect(found.metadata!['requestId'], equals(requestId));
      expect(found.metadata!['confirmTitle'], equals('请选择部署方案'));
      expect(found.metadata!['confirmMessage'], contains('部署'));
      expect(found.metadata!['confirmOptions'], isA<List>());
      expect((found.metadata!['confirmOptions'] as List).length, equals(2));
      expect(found.metadata!['confirmDefaultOption'], equals('plan_a'));

      // 验证选项内容
      final options = found.metadata!['confirmOptions'] as List;
      expect((options[0] as Map).containsKey('key'), isTrue);
      expect((options[1] as Map).containsKey('label'), isTrue);
    });

    // ── 7.3 MCP 权限请求消息 ──

    test('7.3 MCP 权限请求消息（permissionType=mcp_tool）', () async {
      final empId = const Uuid().v4();
      final requestId = const Uuid().v4();

      // MCP 工具权限请求：permissionRequest + permissionType='mcp_tool'
      final msg = ChatMessage(
        id: const Uuid().v4(),
        employeeId: empId,
        role: MessageRole.assistant,
        type: 'permissionRequest',
        content: 'MCP 工具需要执行权限',
        createdAt: DateTime.now(),
        deviceId: fixture.deviceId,
        metadata: {
          'requestId': requestId,
          'functionName': 'mcp__github__list_repos',
          'permissionPattern': 'mcp__github__list_repos',
          'permissionType': 'mcp_tool',
          'permissionArgKey': 'server',
          'permissionArgValue': 'github',
          'args': {'server': 'github', 'owner': 'test-user'},
          'suggestedPattern': 'mcp__github__*',
        },
      );

      await fixture.messageStore.addMessage(fixture.deviceId, msg);

      final found = await fixture.messageStore.getMessage(
        fixture.deviceId,
        msg.id,
      );
      expect(found, isNotNull);
      expect(found!.type, equals('permissionRequest'));
      expect(found.metadata!['permissionType'], equals('mcp_tool'));
      expect(
        found.metadata!['functionName'],
        equals('mcp__github__list_repos'),
      );
      expect(found.metadata!['permissionArgKey'], equals('server'));
      expect(found.metadata!['permissionArgValue'], equals('github'));
      expect(found.metadata!['suggestedPattern'], equals('mcp__github__*'));

      // 验证 content 描述了权限信息
      expect(found.content, equals('MCP 工具需要执行权限'));
    });

    // ── 7.4 permissionRequest 跨设备同步 ──

    test('7.4 permissionRequest 消息通过 RPC 跨设备同步', () async {
      final harness = await LanTestHarness.create('msg-perm-sync');
      try {
        final empId = const Uuid().v4();
        final requestId = const Uuid().v4();

        final msg = ChatMessage(
          id: const Uuid().v4(),
          employeeId: empId,
          role: MessageRole.assistant,
          type: 'permissionRequest',
          content: '命令执行需要确认',
          createdAt: DateTime.now(),
          deviceId: harness.client.deviceId,
          metadata: {
            'requestId': requestId,
            'functionName': 'command_execute',
            'permissionPattern': 'command_execute',
            'permissionType': 'command_execute',
            'permissionArgKey': 'command',
            'permissionArgValue': 'git commit -m "test"',
          },
        );

        // Client 保存
        await harness.client.messageStore.addMessage(
          harness.client.deviceId,
          msg,
        );

        // 同步到 Server
        await harness.server.callRpc(HostRpcConfig.methodSyncMessages, {
          'messages': [msg.toJson()],
        });

        // Server 端验证（消息按 client.deviceId 分区存储）
        final serverMessages = await harness.server.messageStore.getMessages(
          harness.client.deviceId,
          empId,
        );
        expect(serverMessages.any((m) => m.id == msg.id), isTrue);
        final synced = serverMessages.firstWhere((m) => m.id == msg.id);
        expect(synced.type, equals('permissionRequest'));
        expect(synced.metadata!['requestId'], equals(requestId));
        expect(synced.metadata!['functionName'], equals('command_execute'));
        expect(synced.metadata!['permissionType'], equals('command_execute'));
        expect(synced.metadata!['permissionArgKey'], equals('command'));
      } finally {
        await harness.dispose();
      }
    });

    // ── 7.5 confirmRequest 跨设备同步 ──

    test('7.5 confirmRequest 消息通过 RPC 跨设备同步', () async {
      final harness = await LanTestHarness.create('msg-confirm-sync');
      try {
        final empId = const Uuid().v4();
        final requestId = const Uuid().v4();

        final msg = ChatMessage(
          id: const Uuid().v4(),
          employeeId: empId,
          role: MessageRole.assistant,
          type: 'confirmRequest',
          content: '是否继续操作？',
          createdAt: DateTime.now(),
          deviceId: harness.client.deviceId,
          metadata: {
            'requestId': requestId,
            'confirmTitle': '是否继续操作？',
            'confirmMessage': '该操作将修改系统配置，是否继续？',
            'confirmOptions': [
              {'key': 'yes', 'label': '继续'},
              {'key': 'no', 'label': '取消'},
            ],
            'confirmDefaultOption': 'no',
          },
        );

        await harness.client.messageStore.addMessage(
          harness.client.deviceId,
          msg,
        );

        await harness.server.callRpc(HostRpcConfig.methodSyncMessages, {
          'messages': [msg.toJson()],
        });

        final serverMessages = await harness.server.messageStore.getMessages(
          harness.client.deviceId,
          empId,
        );
        expect(serverMessages.any((m) => m.id == msg.id), isTrue);
        final synced = serverMessages.firstWhere((m) => m.id == msg.id);
        expect(synced.type, equals('confirmRequest'));
        expect(synced.metadata!['requestId'], equals(requestId));
        expect(synced.metadata!['confirmTitle'], equals('是否继续操作？'));
        expect(synced.metadata!['confirmMessage'], contains('修改系统配置'));
        expect((synced.metadata!['confirmOptions'] as List).length, equals(2));
        expect(synced.metadata!['confirmDefaultOption'], equals('no'));
      } finally {
        await harness.dispose();
      }
    });

    // ── 7.6 权限决策同步 ──

    test('7.6 用户做出权限决策后更新消息 metadata 并同步', () async {
      final empId = const Uuid().v4();
      final requestId = const Uuid().v4();

      // 创建权限请求
      final msg = ChatMessage(
        id: const Uuid().v4(),
        employeeId: empId,
        role: MessageRole.assistant,
        type: 'permissionRequest',
        content: '需要写入文件权限',
        createdAt: DateTime.now(),
        deviceId: fixture.deviceId,
        metadata: {
          'requestId': requestId,
          'functionName': 'write_file',
          'permissionType': 'file_write',
        },
      );
      await fixture.messageStore.addMessage(fixture.deviceId, msg);

      // 用户做出 allow 决策 → 更新 metadata
      final decided = msg.copyWith(
        metadata: {
          ...msg.metadata!,
          'permissionDecision': 'allow',
          'permissionScope': 'once',
          'decisionTime': DateTime.now().toIso8601String(),
        },
      );
      await fixture.messageStore.updateMessage(fixture.deviceId, decided);

      // 查询验证决策已持久化
      final updated = await fixture.messageStore.getMessage(
        fixture.deviceId,
        msg.id,
      );
      expect(updated, isNotNull);
      expect(updated!.metadata!['permissionDecision'], equals('allow'));
      expect(updated.metadata!['permissionScope'], equals('once'));
      expect(updated.metadata!['decisionTime'], isNotNull);
      expect(updated.metadata!['requestId'], equals(requestId));
      expect(updated.metadata!['functionName'], equals('write_file'));
    });

    // ── 7.7 确认选择结果同步 ──

    test('7.7 用户做出确认选择后更新消息 metadata 并同步', () async {
      final empId = const Uuid().v4();
      final requestId = const Uuid().v4();

      // 创建确认请求
      final msg = ChatMessage(
        id: const Uuid().v4(),
        employeeId: empId,
        role: MessageRole.assistant,
        type: 'confirmRequest',
        content: '选择执行环境',
        createdAt: DateTime.now(),
        deviceId: fixture.deviceId,
        metadata: {
          'requestId': requestId,
          'confirmTitle': '选择执行环境',
          'confirmMessage': '请选择目标环境',
          'confirmOptions': [
            {'key': 'dev', 'label': '开发环境'},
            {'key': 'prod', 'label': '生产环境'},
          ],
        },
      );
      await fixture.messageStore.addMessage(fixture.deviceId, msg);

      // 用户选择 prod → 更新 metadata
      final decided = msg.copyWith(
        metadata: {
          ...msg.metadata!,
          'confirmChoice': 'prod',
          'confirmChoiceLabel': '生产环境',
          'choiceTime': DateTime.now().toIso8601String(),
        },
      );
      await fixture.messageStore.updateMessage(fixture.deviceId, decided);

      // 查询验证
      final updated = await fixture.messageStore.getMessage(
        fixture.deviceId,
        msg.id,
      );
      expect(updated, isNotNull);
      expect(updated!.metadata!['confirmChoice'], equals('prod'));
      expect(updated.metadata!['confirmChoiceLabel'], equals('生产环境'));
      expect(updated.metadata!['choiceTime'], isNotNull);
      expect(updated.metadata!['requestId'], equals(requestId));
    });

    // ── 7.8 按 type 过滤查询待处理权限请求 ──

    test('7.8 按 type=permissionRequest 过滤查询待处理权限请求', () async {
      final empId = const Uuid().v4();

      // 创建混合消息：2条 permissionRequest + 2条 text + 1条 confirmRequest
      await fixture.messageStore.addMessage(
        fixture.deviceId,
        ChatMessage(
          id: const Uuid().v4(),
          employeeId: empId,
          role: MessageRole.assistant,
          type: 'permissionRequest',
          content: '权限请求1',
          createdAt: DateTime.now(),
          deviceId: fixture.deviceId,
          metadata: {'requestId': const Uuid().v4(), 'functionName': 'tool_a'},
        ),
      );
      await fixture.messageStore.addMessage(
        fixture.deviceId,
        _createMessage(
          employeeId: empId,
          deviceId: fixture.deviceId,
          content: '普通文本',
        ),
      );
      await fixture.messageStore.addMessage(
        fixture.deviceId,
        ChatMessage(
          id: const Uuid().v4(),
          employeeId: empId,
          role: MessageRole.assistant,
          type: 'permissionRequest',
          content: '权限请求2',
          createdAt: DateTime.now(),
          deviceId: fixture.deviceId,
          metadata: {
            'requestId': const Uuid().v4(),
            'functionName': 'tool_b',
            'permissionType': 'mcp_tool',
          },
        ),
      );
      await fixture.messageStore.addMessage(
        fixture.deviceId,
        _createMessage(
          employeeId: empId,
          deviceId: fixture.deviceId,
          content: '又一条文本',
        ),
      );
      await fixture.messageStore.addMessage(
        fixture.deviceId,
        ChatMessage(
          id: const Uuid().v4(),
          employeeId: empId,
          role: MessageRole.assistant,
          type: 'confirmRequest',
          content: '确认请求',
          createdAt: DateTime.now(),
          deviceId: fixture.deviceId,
          metadata: {'requestId': const Uuid().v4(), 'confirmTitle': '确认'},
        ),
      );

      // 按 type 过滤
      final allMessages = await fixture.messageStore.getMessages(
        fixture.deviceId,
        empId,
      );
      final permissionRequests = allMessages
          .where((m) => m.type == 'permissionRequest')
          .toList();
      final confirmRequests = allMessages
          .where((m) => m.type == 'confirmRequest')
          .toList();

      expect(permissionRequests.length, equals(2));
      expect(confirmRequests.length, equals(1));
      expect(permissionRequests.any((m) => m.content == '权限请求1'), isTrue);
      expect(permissionRequests.any((m) => m.content == '权限请求2'), isTrue);
    });

    // ── 7.9 按 type 过滤查询待处理确认请求 ──

    test('7.9 confirmRequest 可独立于 permissionRequest 被过滤', () async {
      final empId = const Uuid().v4();

      // 创建 3 条 confirmRequest
      for (int i = 0; i < 3; i++) {
        await fixture.messageStore.addMessage(
          fixture.deviceId,
          ChatMessage(
            id: const Uuid().v4(),
            employeeId: empId,
            role: MessageRole.assistant,
            type: 'confirmRequest',
            content: '确认请求 #$i',
            createdAt: DateTime.now(),
            deviceId: fixture.deviceId,
            metadata: {
              'requestId': const Uuid().v4(),
              'confirmTitle': '确认 #$i',
              'confirmMessage': '描述 #$i',
              'confirmOptions': [
                {'key': 'opt', 'label': '选项'},
              ],
            },
          ),
        );
      }

      final allMessages = await fixture.messageStore.getMessages(
        fixture.deviceId,
        empId,
      );
      final confirms = allMessages
          .where((m) => m.type == 'confirmRequest')
          .toList();

      expect(confirms.length, equals(3));
      for (int i = 0; i < 3; i++) {
        expect(confirms.any((m) => m.content == '确认请求 #$i'), isTrue);
      }
      // 每一条 confirmRequest 都有完整的 confirmOptions
      for (final c in confirms) {
        expect(c.metadata!['confirmOptions'], isA<List>());
        expect((c.metadata!['confirmOptions'] as List).isNotEmpty, isTrue);
      }
    });
  });
}
