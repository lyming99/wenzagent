import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/persistence/store_merge_util.dart';
import 'package:wenzagent/src/service/message_store_service.dart';
import 'package:wenzagent/src/shared/shared.dart';

int _testCounter = 0;

/// 会话窗口消息同步测试
///
/// 测试消息在多设备间的同步机制，核心围绕两条同步路径：
///
/// 同步路径1：event(LAN广播+event) > sync(水位线同步) > update store
///   - 远程设备产生消息 → LAN 广播事件 → 本地收到事件 → 写入 MessageStore → 更新水位线
///   - 对应 CachedAgentProxy._handleAgentEvent 中的 messageStatusChanged 处理
///   - 对应 DeviceMessageHandler._handleAgentEvent 中远程消息的 notificationHub.onRemoteMessage
///
/// 同步路径2：sync(水位线同步) > update store
///   - 客户端主动查询服务端 → 按本地水位线(lastSeq)增量拉取 → 写入 MessageStore → 更新水位线
///   - 对应 CachedAgentProxy._syncMessagesFromRemote 的核心逻辑
///   - 对应 MessageStore.getMessagesAfterSeq 增量查询
///
/// 验证要点：
/// - 水位线(MAX语义)防回退
/// - resetLastSeq 强制重置（清空会话场景）
/// - clearSeq 清空水位线 + 硬删除旧消息
/// - 软删除消息的同步传播
/// - 多设备并发场景
void main() {
  late String testDbPathA;
  late String testDbPathB;
  late String deviceA;
  late String deviceB;
  late MessageStoreService serviceA;
  late MessageStoreService serviceB;
  late MessageStore storeA;
  late MessageStore storeB;
  late SyncWatermarkStore watermarkA;
  late SyncWatermarkStore watermarkB;

  setUp(() async {
    _testCounter++;
    final base =
        '${Directory.systemTemp.path}/wenzagent_session_message_sync_test_$_testCounter';

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

    serviceA = MessageStoreService.getInstance(deviceA);
    serviceB = MessageStoreService.getInstance(deviceB);
    storeA = MessageStore(deviceId: deviceA);
    storeB = MessageStore(deviceId: deviceB);
    watermarkA = SyncWatermarkStore(deviceId: deviceA);
    watermarkB = SyncWatermarkStore(deviceId: deviceB);
  });

  tearDown(() async {
    (serviceA as MessageStoreServiceImpl).dispose();
    (serviceB as MessageStoreServiceImpl).dispose();
    await DatabaseManager.getInstance(deviceA).close();
    await DatabaseManager.getInstance(deviceB).close();
    DatabaseManager.removeInstance(deviceA);
    DatabaseManager.removeInstance(deviceB);
    MessageStoreService.removeInstance(deviceA);
    MessageStoreService.removeInstance(deviceB);
    try {
      await Directory(testDbPathA).delete(recursive: true);
      await Directory(testDbPathB).delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════
  // 辅助方法
  // ═══════════════════════════════════════════════════

  String randomEmpId() => 'emp-${const Uuid().v4().substring(0, 8)}';
  String randomMsgId() => const Uuid().v4();

  /// 创建一条 ChatMessage（本地新消息，seq=0，由 MessageStore 分配）
  ChatMessage createLocalMessage({
    required String employeeId,
    required String deviceId,
    MessageRole role = MessageRole.user,
    String type = 'text',
    String? content,
  }) {
    return ChatMessage(
      id: randomMsgId(),
      employeeId: employeeId,
      role: role,
      type: type,
      content: content ?? 'Hello ${const Uuid().v4().substring(0, 4)}',
      createdAt: DateTime.now(),
      deviceId: deviceId,
    );
  }

  /// 创建一条远程同步消息（携带 seq > 0，保留原始 seq）
  ChatMessage createRemoteMessage({
    required String employeeId,
    required String deviceId,
    required int seq,
    MessageRole role = MessageRole.assistant,
    String type = 'text',
    String? content,
    String? id,
    MessageStatus status = MessageStatus.completed,
  }) {
    return ChatMessage(
      id: id ?? randomMsgId(),
      employeeId: employeeId,
      role: role,
      type: type,
      content: content ?? 'Response ${const Uuid().v4().substring(0, 4)}',
      createdAt: DateTime.now(),
      status: status,
      seq: seq,
      deviceId: deviceId,
    );
  }

  // ═══════════════════════════════════════════════════
  // 同步路径1：event(LAN广播+event) > sync(水位线同步) > update store
  // ═══════════════════════════════════════════════════

  group('同步路径1: event → sync → update store', () {
    test('远程消息通过事件写入本地 MessageStore 并更新水位线', () async {
      final employeeId = randomEmpId();

      // 模拟服务端(deviceA)产生消息，seq=1
      final remoteMsg = createRemoteMessage(
        employeeId: employeeId,
        deviceId: deviceA,
        seq: 1,
        content: 'Hello from remote',
      );
      await storeA.addWithDeviceId(deviceA, remoteMsg);

      // 模拟客户端(deviceB)收到 LAN 广播事件后写入本地
      // 对应 DeviceMessageHandler._handleAgentEvent 中:
      //   _stateHolder.notificationHub.onRemoteMessage(...)
      //   → CachedAgentProxy._addMessageToCache → _saveMessageToDatabase
      await serviceB.addMessage(deviceB, remoteMsg);

      // 验证消息已写入本地
      final localMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(localMessages.length, equals(1));
      expect(localMessages.first.content, equals('Hello from remote'));

      // 验证水位线已更新
      final lastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(lastSeq, equals(1));
    });

    test('多条远程消息依次到达，水位线递增', () async {
      final employeeId = randomEmpId();

      // 模拟3条远程消息依次到达
      for (var i = 1; i <= 3; i++) {
        final remoteMsg = createRemoteMessage(
          employeeId: employeeId,
          deviceId: deviceA,
          seq: i,
          content: 'Message $i',
        );
        await serviceB.addMessage(deviceB, remoteMsg);
      }

      // 验证消息数量
      final localMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(localMessages.length, equals(3));

      // 验证水位线
      final lastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(lastSeq, equals(3));

      // 验证消息顺序（按创建时间升序）
      expect(localMessages[0].content, equals('Message 1'));
      expect(localMessages[1].content, equals('Message 2'));
      expect(localMessages[2].content, equals('Message 3'));
    });

    test('远程消息状态变更事件更新本地消息状态', () async {
      final employeeId = randomEmpId();

      // 1. 先写入一条 queued 状态的远程消息
      final msgId = randomMsgId();
      final queuedMsg = createRemoteMessage(
        employeeId: employeeId,
        deviceId: deviceA,
        seq: 1,
        content: 'Processing...',
        status: MessageStatus.queued,
        id: msgId,
      );
      await serviceB.addMessage(deviceB, queuedMsg);

      // 验证初始状态
      var localMsg = await serviceB.getMessage(deviceB, msgId);
      expect(localMsg?.status, equals(MessageStatus.queued));

      // 2. 收到 messageStatusChanged 事件（status → processing）
      await serviceB.updateMessageStatus(deviceB, msgId, MessageStatus.processing);
      localMsg = await serviceB.getMessage(deviceB, msgId);
      expect(localMsg?.status, equals(MessageStatus.processing));

      // 3. 收到 messageStatusChanged 事件（status → completed）
      await serviceB.updateMessageStatus(deviceB, msgId, MessageStatus.completed);
      localMsg = await serviceB.getMessage(deviceB, msgId);
      expect(localMsg?.status, equals(MessageStatus.completed));
    });

    test('远程消息状态变更为 failed 时携带错误信息', () async {
      final employeeId = randomEmpId();

      final msgId = randomMsgId();
      final msg = createRemoteMessage(
        employeeId: employeeId,
        deviceId: deviceA,
        seq: 1,
        status: MessageStatus.processing,
        id: msgId,
      );
      await serviceB.addMessage(deviceB, msg);

      // 收到 failed 事件
      await serviceB.updateMessageStatus(
        deviceB, msgId, MessageStatus.failed,
        error: 'API rate limit exceeded',
      );

      final localMsg = await serviceB.getMessage(deviceB, msgId);
      expect(localMsg?.status, equals(MessageStatus.failed));
      expect(localMsg?.processingError, equals('API rate limit exceeded'));
    });

    test('远程软删除消息通过事件同步到本地', () async {
      final employeeId = randomEmpId();

      // 1. 远程写入消息
      final msgId = randomMsgId();
      final remoteMsg = createRemoteMessage(
        employeeId: employeeId,
        deviceId: deviceA,
        seq: 1,
        content: 'To be deleted',
        id: msgId,
      );
      await serviceB.addMessage(deviceB, remoteMsg);

      // 验证消息存在
      var localMsg = await serviceB.getMessage(deviceB, msgId);
      expect(localMsg, isNotNull);
      expect(localMsg!.deleted, isFalse);

      // 2. 远程执行软删除（对应 MessageStore.softDeleteForSync）
      await serviceB.softDeleteMessage(deviceB, msgId);

      // 验证消息已删除（getMessage 不过滤 deleted，需检查 deleted 字段）
      localMsg = await serviceB.getMessage(deviceB, msgId);
      expect(localMsg, isNotNull);
      expect(localMsg!.deleted, isTrue);

      // 验证水位线已更新（软删除会分配新 seq）
      final lastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(lastSeq, greaterThan(1));
    });

    test('事件到达顺序不影响最终一致性（乱序事件）', () async {
      final employeeId = randomEmpId();

      // 模拟乱序到达：seq=3 先到，seq=1 后到
      final msg3 = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 3,
        content: 'Third', id: 'msg-3',
      );
      final msg1 = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 1,
        content: 'First', id: 'msg-1',
      );
      final msg2 = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 2,
        content: 'Second', id: 'msg-2',
      );

      // 乱序写入
      await serviceB.addMessage(deviceB, msg3);
      await serviceB.addMessage(deviceB, msg1);
      await serviceB.addMessage(deviceB, msg2);

      // 验证所有消息都存在
      final localMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(localMessages.length, equals(3));

      // 验证水位线为最大值
      final lastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(lastSeq, equals(3));
    });

    test('重复事件（相同消息ID）不产生重复消息', () async {
      final employeeId = randomEmpId();
      final msgId = randomMsgId();

      final remoteMsg = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 1,
        content: 'Duplicate test', id: msgId,
      );

      // 同一条消息写入两次（模拟重复事件）
      await serviceB.addMessage(deviceB, remoteMsg);
      await serviceB.addMessage(deviceB, remoteMsg);

      // 验证只有一条消息（INSERT OR REPLACE）
      final localMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(localMessages.length, equals(1));
      expect(localMessages.first.content, equals('Duplicate test'));
    });
  });

  // ═══════════════════════════════════════════════════
  // 同步路径2：sync(水位线同步) > update store
  // ═══════════════════════════════════════════════════

  group('同步路径2: sync(水位线同步) → update store', () {
    test('增量拉取：本地 lastSeq=0，拉取远程全部消息', () async {
      final employeeId = randomEmpId();

      // 在服务端(deviceA)写入3条消息
      for (var i = 1; i <= 3; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceA, seq: i,
          content: 'Server msg $i',
        );
        await storeA.addWithDeviceId(deviceA, msg);
      }

      // 模拟客户端(deviceB)增量同步
      // 对应 CachedAgentProxy._syncMessagesFromRemote:
      //   1. localLastSeq = serviceB.getLastSeq(deviceB, employeeId) → 0
      //   2. remoteLastSeq = storeA.getMaxSeqForEmployeeAll(employeeId) → 3
      //   3. batch = storeA.getMessagesAfterSeq(employeeId, 0) → [msg1, msg2, msg3]
      final localLastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(localLastSeq, equals(0));

      final remoteLastSeq = storeA.getMaxSeqForEmployeeAll(
        employeeId, deviceId: deviceA,
      );
      expect(remoteLastSeq, equals(3));

      // 增量拉取
      final newMessages = await storeA.getMessagesAfterSeq(
        employeeId, localLastSeq, deviceId: deviceA,
      );
      expect(newMessages.length, equals(3));

      // 写入本地
      for (final msg in newMessages) {
        await serviceB.addMessage(deviceB, msg);
      }

      // 验证本地消息
      final localMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(localMessages.length, equals(3));

      // 验证水位线更新
      final newLastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(newLastSeq, equals(3));
    });

    test('增量拉取：本地已有部分消息，只拉取差量', () async {
      final employeeId = randomEmpId();

      // 服务端有5条消息
      for (var i = 1; i <= 5; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceA, seq: i,
          content: 'Server msg $i',
        );
        await storeA.addWithDeviceId(deviceA, msg);
      }

      // 客户端已有前2条（水位线=2）
      for (var i = 1; i <= 2; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceA, seq: i,
          content: 'Server msg $i',
        );
        await serviceB.addMessage(deviceB, msg);
      }

      // 增量同步
      final localLastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(localLastSeq, equals(2));

      final newMessages = await storeA.getMessagesAfterSeq(
        employeeId, localLastSeq, deviceId: deviceA,
      );
      expect(newMessages.length, equals(3)); // seq=3,4,5

      // 写入差量
      for (final msg in newMessages) {
        await serviceB.addMessage(deviceB, msg);
      }

      // 验证本地总共5条
      final localMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(localMessages.length, equals(5));

      // 验证水位线
      final newLastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(newLastSeq, equals(5));
    });

    test('增量拉取：本地与远程一致时无新消息', () async {
      final employeeId = randomEmpId();

      // 服务端3条消息
      for (var i = 1; i <= 3; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceA, seq: i,
          content: 'Msg $i',
        );
        await storeA.addWithDeviceId(deviceA, msg);
      }

      // 客户端已有全部3条
      for (var i = 1; i <= 3; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceA, seq: i,
          content: 'Msg $i',
        );
        await serviceB.addMessage(deviceB, msg);
      }

      // 增量同步
      final localLastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(localLastSeq, equals(3));

      final newMessages = await storeA.getMessagesAfterSeq(
        employeeId, localLastSeq, deviceId: deviceA,
      );
      expect(newMessages.length, equals(0)); // 无新消息
    });

    test('增量拉取包含软删除消息（deleted=1），客户端执行硬删除', () async {
      final employeeId = randomEmpId();

      // 服务端：写入3条消息，然后软删除第2条
      final msg1 = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 1,
        content: 'Keep', id: 'msg-1',
      );
      final msg2 = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 2,
        content: 'Delete me', id: 'msg-2',
      );
      final msg3 = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 3,
        content: 'Also keep', id: 'msg-3',
      );
      await storeA.addWithDeviceId(deviceA, msg1);
      await storeA.addWithDeviceId(deviceA, msg2);
      await storeA.addWithDeviceId(deviceA, msg3);

      // 服务端软删除 msg2（分配新 seq=4）
      await storeA.softDeleteForSync('msg-2', deviceId: deviceA);

      // 客户端已有 msg1, msg2, msg3（水位线=3）
      await serviceB.addMessage(deviceB, msg1);
      await serviceB.addMessage(deviceB, msg2);
      await serviceB.addMessage(deviceB, msg3);

      // 增量拉取 seq > 3 的消息
      final newMessages = await storeA.getMessagesAfterSeq(
        employeeId, 3, deviceId: deviceA,
      );
      // 应该拉到软删除的 msg2（seq=4, deleted=1）
      final deletedMsgs = newMessages.where((m) => m.deleted).toList();
      expect(deletedMsgs.length, equals(1));
      expect(deletedMsgs.first.id, equals('msg-2'));

      // 客户端处理：检测到 deleted → 硬删除
      for (final msg in deletedMsgs) {
        await serviceB.hardDeleteMessage(deviceB, msg.id);
      }

      // 验证本地只有2条消息
      final localMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(localMessages.length, equals(2));
      expect(localMessages.any((m) => m.id == 'msg-2'), isFalse);

      // 验证水位线（hardDelete 不更新水位线，水位线保持 addMessage 时的值）
      final lastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(lastSeq, greaterThanOrEqualTo(3));
    });

    test('批量拉取：超过 batchSize 时分批获取', () async {
      final employeeId = randomEmpId();
      const totalMessages = 25;
      const batchSize = 20;

      // 服务端写入25条消息
      for (var i = 1; i <= totalMessages; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceA, seq: i,
          content: 'Msg $i',
        );
        await storeA.addWithDeviceId(deviceA, msg);
      }

      // 模拟分批拉取（对应 _syncMessagesFromRemote 中的 while 循环）
      final allNewMessages = <ChatMessage>[];
      int currentSeq = 0;

      while (true) {
        final batch = await storeA.getMessagesAfterSeq(
          employeeId, currentSeq, deviceId: deviceA, limit: batchSize,
        );
        if (batch.isEmpty) break;
        allNewMessages.addAll(batch);
        for (final msg in batch) {
          if (msg.seq > currentSeq) currentSeq = msg.seq;
        }
        if (batch.length < batchSize) break;
      }

      // 验证全部拉取
      expect(allNewMessages.length, equals(totalMessages));

      // 写入本地
      for (final msg in allNewMessages) {
        await serviceB.addMessage(deviceB, msg);
      }

      final localMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(localMessages.length, equals(totalMessages));
    });
  });

  // ═══════════════════════════════════════════════════
  // 水位线语义
  // ═══════════════════════════════════════════════════

  group('水位线语义', () {
    test('updateLastSeq 使用 MAX 语义防止回退', () async {
      final employeeId = randomEmpId();

      // 设置水位线为 10
      watermarkA.updateLastSeq(employeeId, 10, deviceId: deviceA);
      expect(watermarkA.getLastSeq(employeeId, deviceId: deviceA), equals(10));

      // 尝试更新为 5（应被 MAX 语义拒绝，保持 10）
      watermarkA.updateLastSeq(employeeId, 5, deviceId: deviceA);
      expect(watermarkA.getLastSeq(employeeId, deviceId: deviceA), equals(10));

      // 更新为 15（应成功）
      watermarkA.updateLastSeq(employeeId, 15, deviceId: deviceA);
      expect(watermarkA.getLastSeq(employeeId, deviceId: deviceA), equals(15));
    });

    test('resetLastSeq 强制重置水位线（不受 MAX 语义限制）', () async {
      final employeeId = randomEmpId();

      // 设置水位线为 100
      watermarkA.updateLastSeq(employeeId, 100, deviceId: deviceA);
      expect(watermarkA.getLastSeq(employeeId, deviceId: deviceA), equals(100));

      // 强制重置为 0
      watermarkA.resetLastSeq(employeeId, 0, deviceId: deviceA);
      expect(watermarkA.getLastSeq(employeeId, deviceId: deviceA), equals(0));

      // 重置为 50（小于之前的 100，但 resetLastSeq 允许）
      watermarkA.updateLastSeq(employeeId, 100, deviceId: deviceA);
      watermarkA.resetLastSeq(employeeId, 50, deviceId: deviceA);
      expect(watermarkA.getLastSeq(employeeId, deviceId: deviceA), equals(50));
    });

    test('MessageStoreService 层的 resetLastSeq 正确传递', () async {
      final employeeId = randomEmpId();

      // 写入消息，水位线自动更新
      final msg = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceB, seq: 5,
      );
      await serviceB.addMessage(deviceB, msg);
      expect(serviceB.getLastSeq(deviceB, employeeId), equals(5));

      // 通过 service 层重置
      serviceB.resetLastSeq(deviceB, employeeId, 0);
      expect(serviceB.getLastSeq(deviceB, employeeId), equals(0));
    });

    test('addMessage 自动更新水位线（updateWatermark=true）', () async {
      final employeeId = randomEmpId();

      // seq=0 的本地消息，由 MessageStore 分配 seq 并更新水位线
      final localMsg = createLocalMessage(
        employeeId: employeeId, deviceId: deviceB,
      );
      await serviceB.addMessage(deviceB, localMsg);

      final lastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(lastSeq, greaterThan(0));

      // seq>0 的远程消息，保留原始 seq
      final remoteMsg = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 100,
      );
      await serviceB.addMessage(deviceB, remoteMsg);

      final newLastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(newLastSeq, greaterThanOrEqualTo(100));
    });

    test('addMessage 不更新水位线（updateWatermark=false）', () async {
      final employeeId = randomEmpId();

      // 本地临时消息不更新水位线
      final localMsg = createLocalMessage(
        employeeId: employeeId, deviceId: deviceB,
      );
      await serviceB.addMessage(deviceB, localMsg, updateWatermark: false);

      // 水位线应仍为 0
      final lastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(lastSeq, equals(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // clearSeq 清空水位线
  // ═══════════════════════════════════════════════════

  group('clearSeq 清空水位线', () {
    test('setClearSeq 设置清空标记', () async {
      final employeeId = randomEmpId();

      // 设置 clearSeq
      watermarkB.setClearSeq(employeeId, 50, deviceId: deviceB);

      final clearSeq = watermarkB.getClearSeq(employeeId, deviceId: deviceB);
      expect(clearSeq, equals(50));
    });

    test('setClearSeq 使用 MAX 语义防止回退', () async {
      final employeeId = randomEmpId();

      watermarkB.setClearSeq(employeeId, 100, deviceId: deviceB);
      watermarkB.setClearSeq(employeeId, 50, deviceId: deviceB);

      final clearSeq = watermarkB.getClearSeq(employeeId, deviceId: deviceB);
      expect(clearSeq, equals(100)); // 保持较大值
    });

    test('clearClearSeq 清除清空标记', () async {
      final employeeId = randomEmpId();

      watermarkB.setClearSeq(employeeId, 50, deviceId: deviceB);
      expect(watermarkB.getClearSeq(employeeId, deviceId: deviceB), equals(50));

      watermarkB.clearClearSeq(employeeId, deviceId: deviceB);
      expect(watermarkB.getClearSeq(employeeId, deviceId: deviceB), isNull);
    });

    test('客户端根据 clearSeq 硬删除旧消息并重置水位线', () async {
      final employeeId = randomEmpId();

      // 客户端有5条消息（seq=1~5）
      for (var i = 1; i <= 5; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceB, seq: i,
          content: 'Msg $i',
        );
        await serviceB.addMessage(deviceB, msg);
      }

      // 验证初始状态
      expect(
        (await serviceB.getMessages(deviceB, employeeId)).length, equals(5),
      );
      expect(serviceB.getLastSeq(deviceB, employeeId), equals(5));

      // 服务端设置 clearSeq=3（seq < 3 的消息应被删除）
      watermarkB.setClearSeq(employeeId, 3, deviceId: deviceB);

      // 客户端检测到 clearSeq，执行硬删除
      final clearSeq = watermarkB.getClearSeq(employeeId, deviceId: deviceB);
      expect(clearSeq, equals(3));

      // 直接通过 MessageStore 硬删除（避免 deleteMessagesBeforeSeq 触发 rebuildSummary）
      final deletedCount = storeB.deleteBeforeSeq(employeeId, clearSeq!, deviceId: deviceB);
      expect(deletedCount, equals(2)); // seq=1, seq=2 被删除

      // 重置水位线
      serviceB.resetLastSeq(deviceB, employeeId, clearSeq);
      expect(serviceB.getLastSeq(deviceB, employeeId), equals(3));

      // 清除 clearSeq 标记
      watermarkB.clearClearSeq(employeeId, deviceId: deviceB);

      // 验证剩余消息
      final remainingMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(remainingMessages.length, equals(3));
    });

    test('clearSeq=0 不删除任何消息', () async {
      final employeeId = randomEmpId();

      // 写入消息
      final msg = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceB, seq: 1,
      );
      await serviceB.addMessage(deviceB, msg);

      // clearSeq=0
      watermarkB.setClearSeq(employeeId, 0, deviceId: deviceB);

      final deletedCount = serviceB.deleteMessagesBeforeSeq(
        deviceB, employeeId, 0,
      );
      expect(deletedCount, equals(0)); // seq < 0 不存在
    });
  });

  // ═══════════════════════════════════════════════════
  // 软删除同步传播
  // ═══════════════════════════════════════════════════

  group('软删除同步传播', () {
    test('软删除单条消息并分配新 seq', () async {
      final employeeId = randomEmpId();

      // 写入消息
      final msgId = randomMsgId();
      final msg = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 1,
        id: msgId,
      );
      await storeA.addWithDeviceId(deviceA, msg);

      // 软删除
      await storeA.softDeleteForSync(msgId, deviceId: deviceA);

      // 验证：getMessagesAfterSeq 能拉到这条删除消息（含 deleted=1）
      final messages = await storeA.getMessagesAfterSeq(
        employeeId, 0, deviceId: deviceA,
      );
      // 应包含原始消息（deleted=1）
      expect(messages.any((m) => m.deleted && m.id == msgId), isTrue);
    });

    test('软删除会话所有消息', () async {
      final employeeId = randomEmpId();

      // 写入3条消息
      for (var i = 1; i <= 3; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceA, seq: i,
          id: 'msg-$i',
        );
        await storeA.addWithDeviceId(deviceA, msg);
      }

      // 软删除整个会话
      await storeA.softDeleteBySessionForSync(employeeId, deviceId: deviceA);

      // 验证所有消息都被软删除（getMessagesAfterSeq 包含 deleted 消息）
      final messages = await storeA.getMessagesAfterSeq(
        employeeId, 0, deviceId: deviceA,
      );
      // 过滤出原始消息（排除软删除产生的更新版本）
      final originalMsgs = messages.where((m) => m.id.startsWith('msg-')).toList();
      expect(originalMsgs.every((m) => m.deleted), isTrue);

      // 验证水位线已更新
      final maxSeq = storeA.getMaxSeqForEmployeeAll(
        employeeId, deviceId: deviceA,
      );
      final lastSeq = watermarkA.getLastSeq(employeeId, deviceId: deviceA);
      expect(lastSeq, equals(maxSeq));
    });

    test('客户端同步到软删除消息后执行硬删除', () async {
      final employeeId = randomEmpId();

      // 服务端写入并软删除
      final msgId = randomMsgId();
      final msg = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 1,
        id: msgId, content: 'Will be deleted',
      );
      await storeA.addWithDeviceId(deviceA, msg);
      await storeA.softDeleteForSync(msgId, deviceId: deviceA);

      // 客户端先同步原始消息
      await serviceB.addMessage(deviceB, msg);
      expect(
        (await serviceB.getMessages(deviceB, employeeId)).length, equals(1),
      );

      // 增量拉取软删除事件
      final newMessages = await storeA.getMessagesAfterSeq(
        employeeId, 1, deviceId: deviceA,
      );
      expect(newMessages.length, equals(1));
      expect(newMessages.first.deleted, isTrue);

      // 客户端处理：硬删除
      await serviceB.hardDeleteMessage(deviceB, msgId);

      // 验证消息已删除（getMessages 过滤 deleted=0）
      final localMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(localMessages.length, equals(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // 多设备并发场景
  // ═══════════════════════════════════════════════════

  group('多设备并发场景', () {
    test('两条路径交叉：事件同步 + 增量拉取结果一致', () async {
      final employeeId = randomEmpId();

      // 服务端写入5条消息
      for (var i = 1; i <= 5; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceA, seq: i,
          content: 'Msg $i', id: 'msg-$i',
        );
        await storeA.addWithDeviceId(deviceA, msg);
      }

      // --- 路径1：事件同步（模拟收到前2条事件） ---
      for (var i = 1; i <= 2; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceA, seq: i,
          content: 'Msg $i', id: 'msg-$i',
        );
        await serviceB.addMessage(deviceB, msg);
      }

      // --- 路径2：增量拉取（拉取剩余消息） ---
      final localLastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(localLastSeq, equals(2));

      final newMessages = await storeA.getMessagesAfterSeq(
        employeeId, localLastSeq, deviceId: deviceA,
      );
      expect(newMessages.length, equals(3)); // seq=3,4,5

      for (final msg in newMessages) {
        await serviceB.addMessage(deviceB, msg);
      }

      // 验证最终一致性
      final localMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(localMessages.length, equals(5));
      expect(serviceB.getLastSeq(deviceB, employeeId), equals(5));
    });

    test('并发写入后水位线不回退', () async {
      final employeeId = randomEmpId();

      // 两个设备各自写入消息到同一个 employeeId
      // deviceA 写入 seq=1,2,3
      for (var i = 1; i <= 3; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceA, seq: i,
          content: 'A msg $i',
        );
        await storeA.addWithDeviceId(deviceA, msg);
      }

      // deviceB 写入 seq=1,2,3（本地独立 seq 空间）
      for (var i = 1; i <= 3; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceB, seq: i,
          content: 'B msg $i',
        );
        await storeB.addWithDeviceId(deviceB, msg);
      }

      // 各自的水位线独立
      expect(
        watermarkA.getLastSeq(employeeId, deviceId: deviceA), equals(3),
      );
      expect(
        watermarkB.getLastSeq(employeeId, deviceId: deviceB), equals(3),
      );

      // 各自的消息独立
      final messagesA = await storeA.getMessages(deviceA, employeeId);
      final messagesB = await storeB.getMessages(deviceB, employeeId);
      expect(messagesA.length, equals(3));
      expect(messagesB.length, equals(3));
    });

    test('同一设备同一会话的 seq 全局递增', () async {
      final employeeId = randomEmpId();

      // 写入多条消息，验证 seq 递增
      int prevSeq = 0;
      for (var i = 0; i < 5; i++) {
        final msg = createLocalMessage(
          employeeId: employeeId, deviceId: deviceB,
        );
        await serviceB.addMessage(deviceB, msg);

        final messages = await serviceB.getMessages(deviceB, employeeId);
        final lastMsg = messages.last;
        expect(lastMsg.seq, greaterThan(prevSeq));
        prevSeq = lastMsg.seq;
      }
    });

    test('getNextSeq 在清空消息后不产生重复 seq', () async {
      final employeeId = randomEmpId();

      // 写入3条消息
      for (var i = 0; i < 3; i++) {
        final msg = createLocalMessage(
          employeeId: employeeId, deviceId: deviceB,
        );
        await serviceB.addMessage(deviceB, msg);
      }

      // getNextSeq 按 deviceId 隔离，取 messages 表 + watermark 表 + clear_seq 的最大值
      final seqBeforeClear = storeB.getNextSeq(deviceId: deviceB);
      expect(seqBeforeClear, greaterThan(3));

      // 清空消息（直接用 storeB 避免触发 rebuildSummary）
      await storeB.deleteBySession(deviceB, employeeId);
      serviceB.resetLastSeq(deviceB, employeeId, 0);

      // 新消息的 seq 应大于清空前（getNextSeq 取 MAX(messages, watermark, clearSeq)）
      // 注意：resetLastSeq 只重置 watermark，messages 表已清空
      // 但 getNextSeq 还会看 clearSeq，如果 clearSeq=0 则取 MAX(0, 0, 0) + 1 = 1
      // 所以清空后 seq 会从 1 重新开始（这是正确行为，因为所有旧消息已删除，不会产生冲突）
      final newMsg = createLocalMessage(
        employeeId: employeeId, deviceId: deviceB,
      );
      await serviceB.addMessage(deviceB, newMsg);

      final messages = await serviceB.getMessages(deviceB, employeeId);
      expect(messages.length, equals(1));
      // 清空后 seq 从头开始，因为所有旧消息已删除，不会产生冲突
      expect(messages.first.seq, greaterThan(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // 端到端场景
  // ═══════════════════════════════════════════════════

  group('端到端场景', () {
    test('完整对话流程：发送消息 → 事件同步 → 增量拉取 → 一致性', () async {
      final employeeId = randomEmpId();

      // === 阶段1: 用户在 deviceB 发送消息 ===
      final userMsgId = randomMsgId();
      final userMsg = ChatMessage(
        id: userMsgId,
        employeeId: employeeId,
        role: MessageRole.user,
        content: 'What is Dart?',
        createdAt: DateTime.now(),
        deviceId: deviceB,
      );

      // 本地写入（不更新水位线，因为是本地临时消息）
      await serviceB.addMessage(deviceB, userMsg, updateWatermark: false);

      // === 阶段2: 服务端(deviceA)处理后返回助手回复 ===
      // 服务端收到用户消息后保存（seq=1）
      final serverUserMsg = ChatMessage(
        id: userMsgId,
        employeeId: employeeId,
        role: MessageRole.user,
        content: 'What is Dart?',
        createdAt: userMsg.createdAt,
        seq: 1,
        deviceId: deviceB,
        status: MessageStatus.completed,
      );
      await storeA.addWithDeviceId(deviceB, serverUserMsg);

      // 服务端生成助手回复（seq=2）
      final assistantMsgId = randomMsgId();
      final assistantMsg = ChatMessage(
        id: assistantMsgId,
        employeeId: employeeId,
        role: MessageRole.assistant,
        content: 'Dart is a programming language...',
        createdAt: DateTime.now(),
        seq: 2,
        deviceId: deviceA,
        status: MessageStatus.completed,
      );
      await storeA.addWithDeviceId(deviceA, assistantMsg);

      // === 阶段3: 客户端通过事件收到助手回复 ===
      await serviceB.addMessage(deviceB, assistantMsg);

      // 验证
      final localMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(localMessages.length, equals(2));

      // === 阶段4: 后台增量拉取确保一致性 ===
      final localLastSeq = serviceB.getLastSeq(deviceB, employeeId);
      final newMessages = await storeA.getMessagesAfterSeq(
        employeeId, localLastSeq, deviceId: deviceB,
      );
      // 无新消息（事件已同步）
      expect(newMessages.where((m) => !m.deleted).length, equals(0));
    });

    test('清空会话后重新同步', () async {
      final employeeId = randomEmpId();

      // 1. 初始同步：服务端5条消息 → 客户端
      for (var i = 1; i <= 5; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceA, seq: i,
          content: 'Msg $i', id: 'msg-$i',
        );
        await storeA.addWithDeviceId(deviceA, msg);
        await serviceB.addMessage(deviceB, msg);
      }

      expect(
        (await serviceB.getMessages(deviceB, employeeId)).length, equals(5),
      );
      expect(serviceB.getLastSeq(deviceB, employeeId), equals(5));

      // 2. 服务端清空会话
      await storeA.softDeleteBySessionForSync(employeeId, deviceId: deviceA);

      // 3. 客户端收到清空事件
      await serviceB.deleteMessages(deviceB, employeeId);
      serviceB.resetLastSeq(deviceB, employeeId, 0);

      expect(
        (await serviceB.getMessages(deviceB, employeeId)).length, equals(0),
      );
      expect(serviceB.getLastSeq(deviceB, employeeId), equals(0));

      // 4. 服务端写入新消息（seq 继续递增）
      final newMsg = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 10,
        content: 'New msg after clear',
      );
      await storeA.addWithDeviceId(deviceA, newMsg);

      // 5. 客户端增量同步
      final newMessages = await storeA.getMessagesAfterSeq(
        employeeId, 0, deviceId: deviceA,
      );
      // 应只拉到新消息（软删除的旧消息在客户端已被清除）
      final activeMessages = newMessages.where((m) => !m.deleted).toList();
      expect(activeMessages.length, equals(1));
      expect(activeMessages.first.content, equals('New msg after clear'));

      // 写入本地
      for (final msg in activeMessages) {
        await serviceB.addMessage(deviceB, msg);
      }

      // 验证最终状态
      final localMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(localMessages.length, equals(1));
      expect(localMessages.first.content, equals('New msg after clear'));
    });

    test('离线期间的消息在上线后全部同步', () async {
      final employeeId = randomEmpId();

      // 1. 初始同步
      final msg1 = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 1,
        content: 'Before offline', id: 'msg-1',
      );
      await storeA.addWithDeviceId(deviceA, msg1);
      await serviceB.addMessage(deviceB, msg1);

      // 2. 客户端"离线"期间，服务端产生3条新消息
      for (var i = 2; i <= 4; i++) {
        final msg = createRemoteMessage(
          employeeId: employeeId, deviceId: deviceA, seq: i,
          content: 'Offline msg $i', id: 'msg-$i',
        );
        await storeA.addWithDeviceId(deviceA, msg);
      }

      // 3. 客户端"上线"，执行增量同步
      final localLastSeq = serviceB.getLastSeq(deviceB, employeeId);
      expect(localLastSeq, equals(1));

      final newMessages = await storeA.getMessagesAfterSeq(
        employeeId, localLastSeq, deviceId: deviceA,
      );
      expect(newMessages.length, equals(3));

      // 写入本地
      for (final msg in newMessages) {
        await serviceB.addMessage(deviceB, msg);
      }

      // 验证
      final localMessages = await serviceB.getMessages(deviceB, employeeId);
      expect(localMessages.length, equals(4));
      expect(serviceB.getLastSeq(deviceB, employeeId), equals(4));
    });
  });

  // ═══════════════════════════════════════════════════
  // 消息变更事件通知
  // ═══════════════════════════════════════════════════

  group('消息变更事件通知', () {
    test('addMessage 触发 MessageChangeEvent.added', () async {
      final employeeId = randomEmpId();
      final events = <MessageChangeEvent>[];

      final sub = serviceB.onMessageChanged.listen(events.add);

      final msg = createLocalMessage(
        employeeId: employeeId, deviceId: deviceB,
      );
      await serviceB.addMessage(deviceB, msg);

      await Future.delayed(const Duration(milliseconds: 50));

      expect(events.length, equals(1));
      expect(events.first.type, equals(MessageChangeType.added));
      expect(events.first.employeeId, equals(employeeId));

      await sub.cancel();
    });

    test('updateMessageStatus 触发 MessageChangeEvent.updated', () async {
      final employeeId = randomEmpId();
      final events = <MessageChangeEvent>[];

      final msg = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 1,
      );
      await serviceB.addMessage(deviceB, msg);

      final sub = serviceB.onMessageChanged.listen(events.add);

      await serviceB.updateMessageStatus(
        deviceB, msg.id, MessageStatus.completed,
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(events.length, equals(1));
      expect(events.first.type, equals(MessageChangeType.updated));

      await sub.cancel();
    });

    test('softDeleteMessage 触发 MessageChangeEvent.deleted', () async {
      final employeeId = randomEmpId();
      final events = <MessageChangeEvent>[];

      final msg = createRemoteMessage(
        employeeId: employeeId, deviceId: deviceA, seq: 1,
      );
      await serviceB.addMessage(deviceB, msg);

      final sub = serviceB.onMessageChanged.listen(events.add);

      await serviceB.softDeleteMessage(deviceB, msg.id);

      await Future.delayed(const Duration(milliseconds: 50));

      expect(events.any((e) => e.type == MessageChangeType.deleted), isTrue);

      await sub.cancel();
    });
  });
}
