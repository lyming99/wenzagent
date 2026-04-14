import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

int _testCounter = 0;

/// 会话管理功能测试
///
/// 测试会话 CRUD、未读计数追踪、最新消息追踪、
/// 消息已读恢复等关键验证项。
void main() {
  late String testDbPath;
  late MessageStoreService messageStore;
  late MessageStore rawStore;
  late String employeeId;
  late String deviceId;

  setUp(() async {
    _testCounter++;
    testDbPath = '${Directory.systemTemp.path}/wenzagent_conv_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    employeeId = 'emp-${const Uuid().v4()}';
    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    messageStore = MessageStoreServiceImpl(deviceId: deviceId);
    rawStore = MessageStore(deviceId: deviceId);
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    MessageStoreService.removeInstance(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  group('delete conversation', () {
    test('deleteMessages removes all messages for an employee', () async {
      // 插入消息
      for (int i = 1; i <= 5; i++) {
        final msg = ChatMessage(
          id: 'msg-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Message $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceId,
        );
        await messageStore.addMessage(deviceId, msg);
      }

      // 验证消息存在
      var messages = await messageStore.getMessages(deviceId, employeeId);
      expect(messages.length, equals(5));

      // 删除会话
      await messageStore.deleteMessages(deviceId, employeeId);

      // 验证消息已清空
      messages = await messageStore.getMessages(deviceId, employeeId);
      expect(messages, isEmpty);
    });

    test('deleteMessages is scoped to deviceId', () async {
      // 插入消息到 deviceId
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'msg-scoped-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Scoped message $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceId,
        );
        await messageStore.addMessage(deviceId, msg);
      }

      // 使用不同的 deviceId 删除（不应影响原 deviceId 的消息）
      await messageStore.deleteMessages('other-device', employeeId);

      // 验证原 deviceId 的消息仍然存在
      final messages = await messageStore.getMessagesWithDeviceId(
        deviceId, employeeId,
      );
      expect(messages.length, equals(3));
    });
  });

  group('unread count tracking', () {
    test('assistant messages increase unread count', () async {
      // 初始未读为 0
      expect(messageStore.getUnreadCount(deviceId, employeeId), equals(0));

      // 添加未读 assistant 消息
      for (int i = 1; i <= 5; i++) {
        final msg = ChatMessage(
          id: 'unread-$i',
          employeeId: employeeId,
          role: MessageRole.assistant,
          type: 'text',
          content: 'Unread $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceId,
          isRead: false,
        );
        await messageStore.addMessage(deviceId, msg, updateWatermark: false);
      }

      // 验证未读数
      expect(messageStore.getUnreadCount(deviceId, employeeId), equals(5));
    });

    test('user messages do not increase unread count', () async {
      // 添加 user 消息
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'user-msg-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'User msg $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceId,
          isRead: false,
        );
        await messageStore.addMessage(deviceId, msg, updateWatermark: false);
      }

      // 未读数应为 0（只统计 assistant 消息）
      expect(messageStore.getUnreadCount(deviceId, employeeId), equals(0));
    });

    test('markAsReadInDb clears unread count', () async {
      // 添加未读消息
      for (int i = 1; i <= 4; i++) {
        final msg = ChatMessage(
          id: 'to-read-$i',
          employeeId: employeeId,
          role: MessageRole.assistant,
          type: 'text',
          content: 'To read $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceId,
          isRead: false,
        );
        await messageStore.addMessage(deviceId, msg, updateWatermark: false);
      }

      expect(messageStore.getUnreadCount(deviceId, employeeId), equals(4));

      // 标记已读（通过 rawStore 直接调用，指定 deviceId）
      rawStore.markAsReadByEmployee(employeeId, deviceId: deviceId);

      // 验证未读数为 0
      expect(messageStore.getUnreadCount(deviceId, employeeId), equals(0));
    });

    test('mixed read/unread messages tracked correctly', () async {
      // 添加 2 条已读 + 3 条未读 assistant 消息
      for (int i = 1; i <= 2; i++) {
        final msg = ChatMessage(
          id: 'read-msg-$i',
          employeeId: employeeId,
          role: MessageRole.assistant,
          type: 'text',
          content: 'Read $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceId,
          isRead: true,
        );
        await messageStore.addMessage(deviceId, msg, updateWatermark: false);
      }

      for (int i = 3; i <= 5; i++) {
        final msg = ChatMessage(
          id: 'unread-msg-$i',
          employeeId: employeeId,
          role: MessageRole.assistant,
          type: 'text',
          content: 'Unread $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceId,
          isRead: false,
        );
        await messageStore.addMessage(deviceId, msg, updateWatermark: false);
      }

      // 未读数应为 3
      expect(messageStore.getUnreadCount(deviceId, employeeId), equals(3));
    });
  });

  group('latest message tracking', () {
    test('getLastMessage returns the most recent message', () async {
      // 按时间顺序插入
      for (int i = 1; i <= 3; i++) {
        final msg = ChatMessage(
          id: 'latest-test-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Message $i',
          createdAt: DateTime(2024, 1, 1, 12, 0, i),
          deviceId: deviceId,
        );
        await messageStore.addMessage(deviceId, msg);
      }

      final latest = await messageStore.getLastMessage(deviceId, employeeId);
      expect(latest, isNotNull);
      expect(latest!.content, equals('Message 3'));
      expect(latest.id, equals('latest-test-3'));
    });

    test('getLastMessage returns null when no messages exist', () async {
      final latest = await messageStore.getLastMessage(deviceId, 'non-existent-employee');
      expect(latest, isNull);
    });

    test('latest message updates after new message', () async {
      // 插入初始消息
      final msg1 = ChatMessage(
        id: 'initial-latest',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'Initial',
        createdAt: DateTime(2024, 1, 1, 12, 0, 0),
        deviceId: deviceId,
      );
      await messageStore.addMessage(deviceId, msg1);

      var latest = await messageStore.getLastMessage(deviceId, employeeId);
      expect(latest!.content, equals('Initial'));

      // 插入更新消息
      final msg2 = ChatMessage(
        id: 'newer-latest',
        employeeId: employeeId,
        role: MessageRole.assistant,
        type: 'text',
        content: 'Newer',
        createdAt: DateTime(2024, 1, 1, 12, 0, 10),
        deviceId: deviceId,
      );
      await messageStore.addMessage(deviceId, msg2);

      latest = await messageStore.getLastMessage(deviceId, employeeId);
      expect(latest!.content, equals('Newer'));
    });
  });

  group('hard delete message', () {
    test('hardDeleteMessage removes message from database', () async {
      final msg = ChatMessage(
        id: 'to-hard-delete',
        employeeId: employeeId,
        role: MessageRole.user,
        type: 'text',
        content: 'Delete me',
        createdAt: DateTime.now(),
        deviceId: deviceId,
      );
      await messageStore.addMessage(deviceId, msg);

      // 验证消息存在
      var found = await messageStore.getMessage(deviceId, 'to-hard-delete');
      expect(found, isNotNull);

      // 硬删除
      await messageStore.hardDeleteMessage(deviceId, 'to-hard-delete');

      // 验证消息已删除
      found = await messageStore.getMessage(deviceId, 'to-hard-delete');
      expect(found, isNull);
    });
  });

  group('message count', () {
    test('count returns correct number of non-deleted messages', () async {
      for (int i = 1; i <= 5; i++) {
        final msg = ChatMessage(
          id: 'count-test-$i',
          employeeId: employeeId,
          role: MessageRole.user,
          type: 'text',
          content: 'Count $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceId,
        );
        await messageStore.addMessage(deviceId, msg);
      }

      expect(messageStore.getUnreadCount(deviceId, employeeId), equals(0));

      final count = await rawStore.count(deviceId, employeeId);
      expect(count, equals(5));
    });
  });

  group('unread message IDs', () {
    test('getUnreadMessageIds returns correct IDs in order', () async {
      final ids = <String>[];
      for (int i = 1; i <= 3; i++) {
        final id = 'unread-id-$i';
        ids.add(id);
        final msg = ChatMessage(
          id: id,
          employeeId: employeeId,
          role: MessageRole.assistant,
          type: 'text',
          content: 'Unread $i',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          deviceId: deviceId,
          isRead: false,
        );
        await messageStore.addMessage(deviceId, msg, updateWatermark: false);
      }

      final unreadIds = messageStore.getUnreadMessageIds(deviceId, employeeId);
      expect(unreadIds.length, equals(3));

      // 验证按时间升序排列
      for (int i = 0; i < ids.length; i++) {
        expect(unreadIds[i], equals(ids[i]));
      }
    });
  });
}
