import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

int _testCounter = 0;

/// 关键验收测试
///
/// 覆盖规格说明中的关键验收项：
/// - 清空消息后新发送消息正常
/// - 重启app后状态正常（模拟）
/// - 会话删除同步
/// - 未读消息数量正确
/// - 最新消息正常
/// - 消息根据employeeId和deviceId隔离
/// - 消息状态更新同步（seq更新）
/// - 工具消息状态同步
/// - 已读状态同步
void main() {
  late String testDbPath;
  late MessageStoreService messageStore;
  late MessageStore rawStore;
  late SyncWatermarkStore watermarkStore;
  late String employeeId;
  late String deviceIdA;
  late String deviceIdB;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_key_acceptance_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    employeeId = 'emp-${const Uuid().v4()}';
    deviceIdA = 'devA-${const Uuid().v4().substring(0, 8)}';
    deviceIdB = 'devB-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceIdA).initialize(
      storagePath: testDbPath,
    );
    await DatabaseManager.getInstance(deviceIdB).initialize(
      storagePath: testDbPath,
    );

    messageStore = MessageStoreServiceImpl(deviceId: deviceIdA);
    rawStore = MessageStore(deviceId: deviceIdA);
    watermarkStore = SyncWatermarkStore(deviceId: deviceIdA);
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

  group('清空消息后新发送消息正常', () {
    test('clear session then send: new message visible, seq correct', () async {
      // 1. 插入5条消息
      for (int i = 1; i <= 5; i++) {
        final msg = ChatMessage(
          id: 'old-msg-$i',
          employeeId: employeeId,
          role: i.isOdd ? MessageRole.user : MessageRole.assistant,
          type: 'text',
          content: 'Old message $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await messageStore.addMessage(deviceIdA, msg);
      }

      final maxSeqBefore = rawStore.getMaxSeqForEmployeeAll(employeeId);
      expect(maxSeqBefore, greaterThan(0));

      // 2. 清空会话
      final clearSeqValue = maxSeqBefore + 1;
      watermarkStore.setClearSeq(employeeId, clearSeqValue, deviceId: deviceIdA);
      await messageStore.deleteMessages(deviceIdA, employeeId);
      messageStore.resetLastSeq(deviceIdA, employeeId, 0);

      // 3. 验证清空后消息为空
      var messages = await messageStore.getMessagesWithDeviceId(
          deviceIdA, employeeId);
      expect(messages, isEmpty);

      // 4. 发送新消息
      final newMsg = ChatMessage(
        id: 'new-msg-after-clear',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'Hello after clear',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await messageStore.addMessage(deviceIdA, newMsg);

      // 5. 验证新消息可见
      messages = await messageStore.getMessagesWithDeviceId(
          deviceIdA, employeeId);
      expect(messages.length, equals(1));
      expect(messages.first.id, equals('new-msg-after-clear'));
      expect(messages.first.content, equals('Hello after clear'));

      // 6. 验证新消息的 seq > clearSeq（清空后seq从clearSeq值继续递增）
      expect(messages.first.seq, greaterThan(clearSeqValue));

      // 7. 再发一条，验证seq继续递增
      final secondMsg = ChatMessage(
        id: 'second-msg-after-clear',
        employeeId: employeeId,
        role: MessageRole.assistant,
        type: 'text',
        content: 'Reply after clear',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await messageStore.addMessage(secondMsg, deviceId: deviceIdA);

      messages = await messageStore.getMessagesWithDeviceId(
          deviceIdA, employeeId);
      expect(messages.length, equals(2));
      expect(messages.last.seq, greaterThan(messages.first.seq));
    });

    test('clear session: other device sync via clearSeq', () async {
      // 模拟服务端插入消息
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'sync-msg-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Sync msg $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await messageStore.addMessage(msg, deviceId: deviceIdA);
      }

      final maxSeq = rawStore.getMaxSeqForEmployeeAll(employeeId);
      final clearSeqValue = maxSeq + 1;

      // 服务端设置 clearSeq
      watermarkStore.setClearSeq(employeeId, clearSeqValue, deviceId: deviceIdA);
      // 服务端硬删除消息
      await messageStore.deleteMessages(employeeId, deviceId: deviceIdA);

      // 模拟客户端B：有之前同步的本地消息
      final clientStoreB = MessageStoreServiceImpl(deviceId: deviceIdB);
      final clientRawStoreB = MessageStore(deviceId: deviceIdB);
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'sync-msg-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Sync msg $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdB,
          seq: i,
        );
        await clientStoreB.addMessage(msg,
            deviceId: deviceIdB, updateWatermark: false);
      }

      // 客户端B同步：读取clearSeq，删除本地消息
      final clearSeq = watermarkStore.getClearSeq(employeeId, deviceId: deviceIdA);
      expect(clearSeq, isNotNull);
      expect(clearSeq!, greaterThan(0));

      final deletedCount =
          clientRawStoreB.deleteBeforeSeq(employeeId, clearSeqValue);
      expect(deletedCount, equals(3));

      // 验证客户端B消息已清空
      final clientMessages = await clientStoreB.getMessagesWithDeviceId(
          deviceIdB, employeeId);
      expect(clientMessages, isEmpty);

      MessageStoreService.removeInstance(deviceIdB);
    });
  });

  group('重启app后打开聊天窗口状态正常', () {
    test('messages persist across instance recreation', () async {
      // 插入消息
      for (int i = 1; i <= 5; i++) {
        final msg = ChatMessage(
          id: 'persist-msg-$i',
          employeeId: employeeId,
          role: i.isOdd ? MessageRole.user : MessageRole.assistant,
          type: 'text',
          content: 'Persistent $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
          isRead: i <= 2, // 前2条已读
        );
        await messageStore.addMessage(msg,
            deviceId: deviceIdA, updateWatermark: false);
      }

      // 模拟重启：创建新实例
      final restarted = MessageStoreServiceImpl(deviceId: deviceIdA);

      // 验证消息数量
      final messages =
          await restarted.getMessagesWithDeviceId(deviceIdA, employeeId);
      expect(messages.length, equals(5));

      // 验证顺序
      expect(messages.first.id, equals('persist-msg-1'));
      expect(messages.last.id, equals('persist-msg-5'));

      MessageStoreService.removeInstance(deviceIdA);
    });

    test('unread count persists across restart', () async {
      // 插入3条未读assistant消息
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'restart-unread-$i',
          employeeId: employeeId,
          role: MessageRole.assistant,
          type: 'text',
          content: 'Unread $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
          isRead: false,
        );
        await messageStore.addMessage(msg,
            deviceId: deviceIdA, updateWatermark: false);
      }

      // 模拟重启
      final restarted = MessageStoreServiceImpl(deviceId: deviceIdA);
      expect(restarted.getUnreadCount(employeeId), equals(3));

      MessageStoreService.removeInstance(deviceIdA);
    });

    test('latest message persists across restart', () async {
      final msg = ChatMessage(
        id: 'latest-restart',
        employeeId: employeeId,
        role: MessageRole.assistant,
        type: 'text',
        content: 'Latest before restart',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await messageStore.addMessage(msg, deviceId: deviceIdA);

      // 模拟重启
      final restarted = MessageStoreServiceImpl(deviceId: deviceIdA);
      final latest = await restarted.getLastMessage(employeeId);
      expect(latest, isNotNull);
      expect(latest!.content, equals('Latest before restart'));

      MessageStoreService.removeInstance(deviceIdA);
    });

    test('watermark persists across restart', () async {
      watermarkStore.updateLastSeq(employeeId, 42, deviceId: deviceIdA);

      // 模拟重启
      final restartedWatermark = SyncWatermarkStore(deviceId: deviceIdA);
      expect(
          restartedWatermark.getLastSeq(employeeId, deviceId: deviceIdA),
          equals(42));
    });
  });

  group('消息根据employeeId和deviceId隔离', () {
    test('different devices see different messages for same employee', () async {
      final storeA = MessageStoreServiceImpl(deviceId: deviceIdA);
      final storeB = MessageStoreServiceImpl(deviceId: deviceIdB);

      // Device A 插入3条
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'devA-msg-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Device A msg $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await storeA.addMessage(msg, deviceId: deviceIdA);
      }

      // Device B 插入2条
      for (int i = 1; i <= 2; i++) {
        final msg = ChatMessage(
          id: 'devB-msg-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Device B msg $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdB,
        );
        await storeB.addMessage(msg, deviceId: deviceIdB);
      }

      // Device A 只看到自己的消息
      final messagesA =
          await storeA.getMessagesWithDeviceId(deviceIdA, employeeId);
      expect(messagesA.length, equals(3));
      for (final msg in messagesA) {
        expect(msg.id, startsWith('devA-'));
      }

      // Device B 只看到自己的消息
      final messagesB =
          await storeB.getMessagesWithDeviceId(deviceIdB, employeeId);
      expect(messagesB.length, equals(2));
      for (final msg in messagesB) {
        expect(msg.id, startsWith('devB-'));
      }

      // 删除Device A的消息不影响Device B
      await storeA.deleteMessages(employeeId, deviceId: deviceIdA);

      final messagesBAfterDelete =
          await storeB.getMessagesWithDeviceId(deviceIdB, employeeId);
      expect(messagesBAfterDelete.length, equals(2));

      MessageStoreService.removeInstance(deviceIdA);
      MessageStoreService.removeInstance(deviceIdB);
    });

    test('unread count respects deviceId isolation', () async {
      final storeA = MessageStoreServiceImpl(deviceId: deviceIdA);
      final storeARaw = MessageStore(deviceId: deviceIdA);

      // Device A: 3条未读assistant消息
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'devA-unread-$i',
          employeeId: employeeId,
          role: MessageRole.assistant,
          type: 'text',
          content: 'Device A unread $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
          isRead: false,
        );
        await storeA.addMessage(msg,
            deviceId: deviceIdA, updateWatermark: false);
      }

      // 未读数 = 3 (只统计deviceIdA下的assistant消息)
      expect(storeA.getUnreadCount(employeeId), equals(3));

      // 标记已读（指定deviceId）
      storeARaw.markAsReadByEmployee(employeeId, deviceId: deviceIdA);

      expect(storeA.getUnreadCount(employeeId), equals(0));

      MessageStoreService.removeInstance(deviceIdA);
    });
  });

  group('消息状态更新同步 (seq更新)', () {
    test('updateStatus assigns new seq for sync propagation', () async {
      final msg = ChatMessage(
        id: 'status-sync-msg',
        employeeId: employeeId,
        role: MessageRole.assistant,
        type: 'text',
        content: 'Status test',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await messageStore.addMessage(msg, deviceId: deviceIdA);

      final seqBeforeStatusUpdate =
          rawStore.getMaxSeqForEmployeeAll(employeeId);

      // 更新状态
      await rawStore.updateStatus(deviceIdA, 'status-sync-msg',
          MessageStatus.processing);

      // 验证seq已更新
      final updatedMsg = await messageStore.getMessage('status-sync-msg',
          deviceId: deviceIdA);
      expect(updatedMsg, isNotNull);
      expect(updatedMsg!.seq, greaterThan(seqBeforeStatusUpdate));
      expect(updatedMsg.status, equals(MessageStatus.processing));

      // 再次更新为completed
      final seqBeforeComplete =
          rawStore.getMaxSeqForEmployeeAll(employeeId);
      await rawStore.updateStatus(
          deviceIdA, 'status-sync-msg', MessageStatus.completed);

      final completedMsg = await messageStore.getMessage('status-sync-msg',
          deviceId: deviceIdA);
      expect(completedMsg!.seq, greaterThan(seqBeforeComplete));
      expect(completedMsg.status, equals(MessageStatus.completed));
    });

    test('tool message status update increments seq', () async {
      // 模拟工具调用消息
      final toolMsg = ChatMessage(
        id: 'local_toolcall_test-call-123',
        employeeId: employeeId,
        role: MessageRole.assistant,
        type: 'functionCall',
        content: null,
        toolCallId: 'test-call-123',
        toolName: 'execute_command',
        toolArguments: {'command': 'ls -la'},
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
        status: MessageStatus.processing,
      );
      await messageStore.addMessage(toolMsg,
          deviceId: deviceIdA, updateWatermark: false);

      final seqBefore = rawStore.getMaxSeqForEmployeeAll(employeeId);

      // 更新工具消息状态
      await rawStore.updateStatus(deviceIdA, 'local_toolcall_test-call-123',
          MessageStatus.completed,
          error: null);

      // 验证seq已更新
      final updatedToolMsg = await messageStore.getMessage(
          'local_toolcall_test-call-123',
          deviceId: deviceIdA);
      expect(updatedToolMsg!.seq, greaterThan(seqBefore));
      expect(updatedToolMsg.status, equals(MessageStatus.completed));
    });
  });

  group('已读状态同步', () {
    test('markAsRead updates seq for sync', () async {
      // 插入3条未读assistant消息
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'read-sync-$i',
          employeeId: employeeId,
          role: MessageRole.assistant,
          type: 'text',
          content: 'Read sync $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
          isRead: false,
        );
        await messageStore.addMessage(msg,
            deviceId: deviceIdA, updateWatermark: false);
      }

      final seqBeforeMarkRead =
          rawStore.getMaxSeqForEmployeeAll(employeeId);

      // 标记已读
      rawStore.markAsReadByEmployee(employeeId, deviceId: deviceIdA);

      // 验证seq已更新（已读状态变更需要同步到其他设备）
      final seqAfterMarkRead =
          rawStore.getMaxSeqForEmployeeAll(employeeId);
      expect(seqAfterMarkRead, greaterThan(seqBeforeMarkRead));

      // 验证所有消息已读
      expect(messageStore.getUnreadCount(employeeId), equals(0));

      // 验证消息可通过增量同步拉取（seq > seqBeforeMarkRead）
      final syncMessages =
          await rawStore.getMessagesAfterSeq(employeeId, seqBeforeMarkRead);
      expect(syncMessages.length, greaterThan(0));
      for (final msg in syncMessages) {
        expect(msg.isRead, isTrue);
      }
    });
  });

  group('最新消息和未读数量', () {
    test('latest message updates correctly after new message', () async {
      // 插入消息
      final msg1 = ChatMessage(
        id: 'latest-1',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'First message',
        createdAt: DateTime(2024, 1, 1, 12, 0, 0),
        deviceId: deviceIdA,
      );
      await messageStore.addMessage(msg1, deviceId: deviceIdA);

      var latest = await messageStore.getLastMessage(employeeId);
      expect(latest!.content, equals('First message'));

      // 插入新消息
      final msg2 = ChatMessage(
        id: 'latest-2',
        employeeId: employeeId,
        role: MessageRole.assistant,
        type: 'text',
        content: 'Second message',
        createdAt: DateTime(2024, 1, 1, 12, 0, 10),
        deviceId: deviceIdA,
      );
      await messageStore.addMessage(msg2, deviceId: deviceIdA);

      latest = await messageStore.getLastMessage(employeeId);
      expect(latest!.content, equals('Second message'));
    });

    test('unread count only counts assistant messages', () async {
      // 插入 user 消息
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'user-only-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'User $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
          isRead: false,
        );
        await messageStore.addMessage(msg,
            deviceId: deviceIdA, updateWatermark: false);
      }

      expect(messageStore.getUnreadCount(employeeId), equals(0));

      // 插入 assistant 消息
      for (int i = 1; i <= 2; i++) {
        final msg = ChatMessage(
          id: 'assistant-only-$i',
          employeeId: employeeId,
          role: MessageRole.assistant,
          type: 'text',
          content: 'Assistant $i',
          createdAt: DateTime.now().add(Duration(seconds: i + 10)),
          deviceId: deviceIdA,
          isRead: false,
        );
        await messageStore.addMessage(msg,
            deviceId: deviceIdA, updateWatermark: false);
      }

      expect(messageStore.getUnreadCount(employeeId), equals(2));

      // 已读的 assistant 不计入
      final readMsg = ChatMessage(
        id: 'assistant-read',
        employeeId: employeeId,
        role: MessageRole.assistant,
        type: 'text',
        content: 'Read assistant',
        createdAt: DateTime.now().add(Duration(seconds: 30)),
        deviceId: deviceIdA,
        isRead: true,
      );
      await messageStore.addMessage(readMsg,
          deviceId: deviceIdA, updateWatermark: false);

      expect(messageStore.getUnreadCount(employeeId), equals(2));
    });

    test('deleted messages excluded from unread count', () async {
      final msg = ChatMessage(
        id: 'deleted-unread',
        employeeId: employeeId,
        role: MessageRole.assistant,
        type: 'text',
        content: 'Deleted unread',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
        isRead: false,
      );
      await messageStore.addMessage(msg,
          deviceId: deviceIdA, updateWatermark: false);

      expect(messageStore.getUnreadCount(employeeId), equals(1));

      // 软删除
      await messageStore.softDeleteMessage('deleted-unread');

      expect(messageStore.getUnreadCount(employeeId), equals(0));
    });
  });

  group('会话删除同步', () {
    test('delete conversation and verify messages cleared', () async {
      for (int i = 1; i <= 5; i++) {
        final msg = ChatMessage(
          id: 'delete-conv-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Conv $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await messageStore.addMessage(msg, deviceId: deviceIdA);
      }

      // 验证消息存在
      var messages = await messageStore.getMessagesWithDeviceId(
          deviceIdA, employeeId);
      expect(messages.length, equals(5));

      // 删除会话
      await messageStore.deleteMessages(employeeId, deviceId: deviceIdA);

      // 验证消息已清空
      messages = await messageStore.getMessagesWithDeviceId(
          deviceIdA, employeeId);
      expect(messages, isEmpty);

      // 验证最新消息为null
      final latest = await messageStore.getLastMessage(employeeId);
      expect(latest, isNull);

      // 验证未读数归零
      expect(messageStore.getUnreadCount(employeeId), equals(0));
    });
  });

  group('soft delete sync across devices', () {
    test('softDeleteMessage makes message invisible but preserves for sync',
        () async {
      final msg = ChatMessage(
        id: 'soft-delete-sync',
        employeeId: employeeId,
        role: MessageRole.assistant,
        type: 'text',
        content: 'Soft delete sync test',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
        isRead: false,
      );
      await messageStore.addMessage(msg, deviceId: deviceIdA);

      final seqBefore = rawStore.getMaxSeqForEmployeeAll(employeeId);

      // 软删除
      await messageStore.softDeleteMessage('soft-delete-sync');

      // 验证消息在常规查询中不可见
      final visibleMessages = await messageStore.getMessagesWithDeviceId(
          deviceIdA, employeeId);
      expect(visibleMessages, isEmpty);

      // 验证消息可通过增量同步拉取（含deleted标记）
      final syncMessages =
          await rawStore.getMessagesAfterSeq(employeeId, seqBefore);
      expect(syncMessages.length, greaterThan(0));
      expect(syncMessages.first.deleted, isTrue);
    });
  });

  group('水位线机制', () {
    test('watermark correctly tracks incremental sync progress', () async {
      // 插入10条消息
      for (int i = 1; i <= 10; i++) {
        final msg = ChatMessage(
          id: 'watermark-msg-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Watermark $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await messageStore.addMessage(msg, deviceId: deviceIdA);
      }

      final lastSeq = watermarkStore.getLastSeq(employeeId, deviceId: deviceIdA);
      expect(lastSeq, greaterThan(0));

      // 客户端A同步到lastSeq
      final clientRawStore = MessageStore(deviceId: deviceIdA);
      final messages = await clientRawStore.getMessagesAfterSeq(
          employeeId, lastSeq);
      expect(messages, isEmpty); // 已经是最新

      // 服务端新增消息
      final newMsg = ChatMessage(
        id: 'watermark-new',
        employeeId: employeeId,
        role: MessageRole.assistant,
        type: 'text',
        content: 'New after watermark',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await messageStore.addMessage(newMsg, deviceId: deviceIdA);

      // 客户端增量拉取
      final newMessages = await clientRawStore.getMessagesAfterSeq(
          employeeId, lastSeq);
      expect(newMessages.length, equals(1));
      expect(newMessages.first.id, equals('watermark-new'));
    });

    test('updateLastSeq uses MAX semantics', () {
      watermarkStore.updateLastSeq(employeeId, 100, deviceId: deviceIdA);
      watermarkStore.updateLastSeq(employeeId, 50, deviceId: deviceIdA);
      expect(
          watermarkStore.getLastSeq(employeeId, deviceId: deviceIdA),
          equals(100));
    });

    test('resetLastSeq can lower the watermark', () {
      watermarkStore.updateLastSeq(employeeId, 100, deviceId: deviceIdA);
      watermarkStore.resetLastSeq(employeeId, 0, deviceId: deviceIdA);
      expect(
          watermarkStore.getLastSeq(employeeId, deviceId: deviceIdA),
          equals(0));
    });
  });
}
