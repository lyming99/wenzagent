import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

int _testCounter = 0;

/// 消息同步功能测试
///
/// 测试 LSN 水位线同步、清空会话同步、软删除同步、
/// 已读状态同步、设备隔离、seq 单调性等关键验证项。
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
    testDbPath = '${Directory.systemTemp.path}/wenzagent_msg_sync_test_$_testCounter';
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

  group('LSN waterline sync', () {
    test('getMessagesAfterSeq returns correct incremental messages', () async {
      // 插入 10 条消息
      for (int i = 1; i <= 10; i++) {
        final msg = ChatMessage(
          id: 'msg-$i',
          employeeId: employeeId,
          role: i.isOdd ? MessageRole.user : MessageRole.assistant,
          type: 'text',
          content: 'Message $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await messageStore.addMessage(deviceIdA, msg);
      }

      // 客户端水位线在 seq 5，拉取 seq > 5 的消息
      final messages = await rawStore.getMessagesAfterSeq(employeeId, 5);

      // 应返回 seq 6-10 的消息
      expect(messages.length, equals(5));
      for (final msg in messages) {
        expect(msg.seq, greaterThan(5));
      }

      // 验证 seq 递增
      for (int i = 1; i < messages.length; i++) {
        expect(messages[i].seq, greaterThan(messages[i - 1].seq));
      }
    });

    test('getMessagesAfterSeq returns empty when no newer messages', () async {
      // 插入 3 条消息
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'msg-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Message $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await messageStore.addMessage(deviceIdA, msg);
      }

      // 获取最大 seq
      final maxSeq = rawStore.getMaxSeqForEmployeeAll(employeeId);
      expect(maxSeq, greaterThan(0));

      // 拉取 seq > maxSeq 的消息，应返回空
      final messages = await rawStore.getMessagesAfterSeq(
        employeeId, maxSeq,
      );
      expect(messages, isEmpty);
    });
  });

  group('clearSeq mechanism', () {
    test('setClearSeq and getClearSeq round-trip', () {
      // 初始 clearSeq 应为 null
      expect(watermarkStore.getClearSeq(employeeId, deviceId: deviceIdA), isNull);

      // 设置 clearSeq
      watermarkStore.setClearSeq(employeeId, 100, deviceId: deviceIdA);

      // 读取 clearSeq
      expect(watermarkStore.getClearSeq(employeeId, deviceId: deviceIdA), equals(100));
    });

    test('clearSeq uses MAX semantic to prevent regression', () {
      watermarkStore.setClearSeq(employeeId, 100, deviceId: deviceIdA);
      watermarkStore.setClearSeq(employeeId, 50, deviceId: deviceIdA);

      // 应保持较大的值
      expect(watermarkStore.getClearSeq(employeeId, deviceId: deviceIdA), equals(100));
    });

    test('clearClearSeq resets the marker', () {
      watermarkStore.setClearSeq(employeeId, 100, deviceId: deviceIdA);
      watermarkStore.clearClearSeq(employeeId, deviceId: deviceIdA);

      expect(watermarkStore.getClearSeq(employeeId, deviceId: deviceIdA), isNull);
    });

    test('deleteBeforeSeq deletes messages with seq < beforeSeq', () async {
      // 插入消息
      for (int i = 1; i <= 10; i++) {
        final msg = ChatMessage(
          id: 'msg-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Message $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await messageStore.addMessage(deviceIdA, msg);
      }

      final maxSeq = rawStore.getMaxSeqForEmployeeAll(employeeId);

      // 设置 clearSeq（比 maxSeq 大 1，确保所有消息被删除）
      final clearSeqValue = maxSeq + 1;
      watermarkStore.setClearSeq(employeeId, clearSeqValue, deviceId: deviceIdA);

      // 删除 seq < clearSeq 的消息
      final deletedCount = rawStore.deleteBeforeSeq(employeeId, clearSeqValue);
      expect(deletedCount, equals(10));

      // 验证消息已清空
      final remaining = await messageStore.getMessages(deviceIdA, employeeId);
      expect(remaining, isEmpty);
    });

    test('clear session sync flow: set clearSeq, client deletes local messages', () async {
      // 模拟服务端：插入消息并设置 clearSeq
      for (int i = 1; i <= 5; i++) {
        final msg = ChatMessage(
          id: 'msg-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Message $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await messageStore.addMessage(deviceIdA, msg);
      }

      final maxSeq = rawStore.getMaxSeqForEmployeeAll(employeeId);

      // 模拟清空会话：设置 clearSeq 并硬删除
      final clearSeqValue = maxSeq + 1;
      watermarkStore.setClearSeq(employeeId, clearSeqValue, deviceId: deviceIdA);
      await messageStore.deleteMessages(deviceIdA, employeeId);

      // 验证服务端消息已清空
      final serverMessages = await messageStore.getMessagesWithDeviceId(
        deviceIdA, employeeId,
      );
      expect(serverMessages, isEmpty);

      // 模拟客户端 B：插入相同的消息（模拟之前同步的本地缓存）
      final clientStoreB = MessageStoreServiceImpl(deviceId: deviceIdB);
      for (int i = 1; i <= 5; i++) {
        final msg = ChatMessage(
          id: 'msg-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Message $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdB,
          seq: i, // 模拟同步时分配的 seq
        );
        await clientStoreB.addMessage(deviceIdB, msg, updateWatermark: false);
      }

      // 客户端 B 同步：检查 clearSeq 并删除本地消息
      final clientRawStore = MessageStore(deviceId: deviceIdB);
      final clearSeq = watermarkStore.getClearSeq(employeeId, deviceId: deviceIdA);
      expect(clearSeq, isNotNull);
      expect(clearSeq!, greaterThan(0));

      final deletedCount = clientRawStore.deleteBeforeSeq(employeeId, clearSeqValue);
      expect(deletedCount, equals(5));

      // 验证客户端 B 消息已清空
      final clientMessages = await clientStoreB.getMessagesWithDeviceId(
        deviceIdB, employeeId,
      );
      expect(clientMessages, isEmpty);
    });
  });

  group('clear then send', () {
    test('new message gets proper seq after clear', () async {
      // 插入 5 条消息
      for (int i = 1; i <= 5; i++) {
        final msg = ChatMessage(
          id: 'msg-old-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Old message $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await messageStore.addMessage(deviceIdA, msg);
      }

      final seqBeforeClear = rawStore.getMaxSeqForEmployeeAll(employeeId);

      // 清空会话（先设 clearSeq，再硬删除）
      final clearSeqValue = seqBeforeClear + 1;
      watermarkStore.setClearSeq(employeeId, clearSeqValue, deviceId: deviceIdA);
      await messageStore.deleteMessages(deviceIdA, employeeId);
      messageStore.resetLastSeq(deviceIdA, employeeId, 0);

      // 发送新消息
      final newMsg = ChatMessage(
        id: 'msg-new',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'New message after clear',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await messageStore.addMessage(deviceIdA, newMsg);

      // 验证只有 1 条消息且是新消息
      final messages = await messageStore.getMessagesWithDeviceId(
        deviceIdA, employeeId,
      );
      expect(messages.length, equals(1));
      expect(messages.first.id, equals('msg-new'));
    });
  });

  group('soft delete sync', () {
    test('softDeleteForSync updates deleted flag and seq', () async {
      // 插入消息
      final msg = ChatMessage(
        id: 'msg-to-delete',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'To be deleted',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await messageStore.addMessage(deviceIdA, msg);

      // 获取原始 seq
      final originalSeq = rawStore.getMaxSeqForEmployeeAll(employeeId);

      // 软删除
      await messageStore.softDeleteMessage(deviceIdA, 'msg-to-delete');

      // 验证 seq 已更新（应大于原始 seq）
      // getMessagesAfterSeq 包含已删除的消息
      final newMessages = await rawStore.getMessagesAfterSeq(employeeId, originalSeq);
      expect(newMessages.length, greaterThan(0));

      // 验证已删除消息在 getMessages (deleted=0 过滤) 中不可见
      final visibleMessages = await messageStore.getMessages(deviceIdA, employeeId);
      expect(visibleMessages.where((m) => m.id == 'msg-to-delete'), isEmpty);
    });
  });

  group('mark as read sync', () {
    test('markAsReadByEmployee updates is_read and seq', () async {
      // 插入未读的 assistant 消息
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'msg-unread-$i',
          employeeId: employeeId,
          role: MessageRole.assistant,
          type: 'text',
          content: 'Unread message $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
          isRead: false,
        );
        await messageStore.addMessage(deviceIdA, msg, updateWatermark: false);
      }

      // 验证未读数
      expect(messageStore.getUnreadCount(deviceIdA, employeeId), equals(3));

      // 标记已读（通过 rawStore 直接调用）
      rawStore.markAsReadByEmployee(employeeId, deviceId: deviceIdA);

      // 验证未读数为 0
      expect(messageStore.getUnreadCount(deviceIdA, employeeId), equals(0));
    });
  });

  group('unread count after restart', () {
    test('unread count persists across restart simulation', () async {
      // 插入 5 条未读的 assistant 消息
      for (int i = 1; i <= 5; i++) {
        final msg = ChatMessage(
          id: 'msg-persist-$i',
          employeeId: employeeId,
          role: MessageRole.assistant,
          type: 'text',
          content: 'Persistent message $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
          isRead: false,
        );
        await messageStore.addMessage(deviceIdA, msg, updateWatermark: false);
      }

      // 标记 2 条为已读
      rawStore.markAsReadByEmployee(employeeId, deviceId: deviceIdA);
      final remaining = messageStore.getUnreadCount(deviceIdA, employeeId);

      // 模拟重启：重新创建 MessageStoreService 实例
      final restartedStore = MessageStoreServiceImpl(deviceId: deviceIdA);
      final unreadAfterRestart = restartedStore.getUnreadCount(deviceIdA, employeeId);

      // 未读数应为 0（之前已全部标记已读）
      expect(unreadAfterRestart, equals(remaining));

      MessageStoreService.removeInstance(deviceIdA);
    });
  });

  group('latest message after restart', () {
    test('latest message persists across restart', () async {
      // 插入消息
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'msg-latest-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Latest message $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await messageStore.addMessage(deviceIdA, msg);
      }

      // 获取最新消息
      final latestBefore = await messageStore.getLastMessage(deviceIdA, employeeId);
      expect(latestBefore, isNotNull);
      expect(latestBefore!.content, equals('Latest message 3'));

      // 模拟重启
      final restartedStore = MessageStoreServiceImpl(deviceId: deviceIdA);
      final latestAfter = await restartedStore.getLastMessage(deviceIdA, employeeId);

      expect(latestAfter, isNotNull);
      expect(latestAfter!.content, equals('Latest message 3'));
      expect(latestAfter.id, equals(latestBefore.id));

      MessageStoreService.removeInstance(deviceIdA);
    });
  });

  group('device isolation', () {
    test('messages are isolated by deviceId', () async {
      // Device A 插入消息
      final msgA = ChatMessage(
        id: 'msg-deviceA',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'Message from device A',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await messageStore.addMessage(deviceIdA, msgA);

      // Device B 插入消息
      final storeB = MessageStoreServiceImpl(deviceId: deviceIdB);
      final msgB = ChatMessage(
        id: 'msg-deviceB',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'Message from device B',
        createdAt: DateTime.now(),
        deviceId: deviceIdB,
      );
      await storeB.addMessage(deviceIdB, msgB);

      // Device A 只能看到自己的消息
      final messagesA = await messageStore.getMessagesWithDeviceId(
        deviceIdA, employeeId,
      );
      expect(messagesA.length, equals(1));
      expect(messagesA.first.id, equals('msg-deviceA'));

      // Device B 只能看到自己的消息
      final messagesB = await storeB.getMessagesWithDeviceId(
        deviceIdB, employeeId,
      );
      expect(messagesB.length, equals(1));
      expect(messagesB.first.id, equals('msg-deviceB'));

      MessageStoreService.removeInstance(deviceIdB);
    });
  });

  group('seq monotonicity', () {
    test('getNextSeq always returns increasing values after inserts', () async {
      final store = MessageStore(deviceId: deviceIdA);

      final seq1 = store.getNextSeq(deviceId: deviceIdA);

      // Insert a message to advance the counter
      final msg = ChatMessage(
        id: 'seq-test-1',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'Seq test 1',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await store.addWithDeviceId(deviceIdA, msg);

      final seq2 = store.getNextSeq(deviceId: deviceIdA);

      expect(seq2, greaterThan(seq1));

      // Insert another message
      final msg2 = ChatMessage(
        id: 'seq-test-2',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'Seq test 2',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await store.addWithDeviceId(deviceIdA, msg2);

      final seq3 = store.getNextSeq(deviceId: deviceIdA);
      expect(seq3, greaterThan(seq2));
    });

    test('seq continues to increase after delete', () async {
      final store = MessageStore(deviceId: deviceIdA);

      // 插入消息
      for (int i = 1; i <= 5; i++) {
        final msg = ChatMessage(
          id: 'seq-test-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Seq test $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await store.addWithDeviceId(deviceIdA, msg);
      }

      final seqBeforeDelete = store.getMaxSeqForEmployeeAll(employeeId);

      // 删除所有消息
      await store.deleteBySession(deviceIdA, employeeId);

      // 新消息的 seq 应大于删除前的 seq
      final newMsg = ChatMessage(
        id: 'seq-after-delete',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'After delete',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await store.addWithDeviceId(deviceIdA, newMsg);

      final seqAfterDelete = store.getMaxSeqForEmployeeAll(employeeId);
      expect(seqAfterDelete, greaterThan(seqBeforeDelete));
    });

    test('seq continues to increase after clear session', () async {
      final store = MessageStore(deviceId: deviceIdA);

      // 插入消息
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'clear-seq-test-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Clear seq test $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceIdA,
        );
        await store.addWithDeviceId(deviceIdA, msg);
      }

      final seqBeforeClear = store.getMaxSeqForEmployeeAll(employeeId);

      // 清空会话
      await store.deleteBySession(deviceIdA, employeeId);
      watermarkStore.setClearSeq(employeeId, seqBeforeClear + 1, deviceId: deviceIdA);

      // 新消息的 seq 应大于 clearSeq
      final newMsg = ChatMessage(
        id: 'clear-seq-after',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'After clear',
        createdAt: DateTime.now(),
        deviceId: deviceIdA,
      );
      await store.addWithDeviceId(deviceIdA, newMsg);

      final seqAfterClear = store.getMaxSeqForEmployeeAll(employeeId);
      expect(seqAfterClear, greaterThan(seqBeforeClear));
    });
  });

  group('waterline management', () {
    test('updateLastSeq uses MAX semantic', () {
      watermarkStore.updateLastSeq(employeeId, 10, deviceId: deviceIdA);
      watermarkStore.updateLastSeq(employeeId, 5, deviceId: deviceIdA);

      expect(watermarkStore.getLastSeq(employeeId, deviceId: deviceIdA), equals(10));
    });

    test('resetLastSeq bypasses MAX semantic', () {
      watermarkStore.updateLastSeq(employeeId, 10, deviceId: deviceIdA);
      watermarkStore.resetLastSeq(employeeId, 0, deviceId: deviceIdA);

      expect(watermarkStore.getLastSeq(employeeId, deviceId: deviceIdA), equals(0));
    });

    test('getLastSeq returns 0 when no watermark exists', () {
      expect(
        watermarkStore.getLastSeq('non-existent-employee', deviceId: deviceIdA),
        equals(0),
      );
    });
  });
}
