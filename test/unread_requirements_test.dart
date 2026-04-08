import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:wenzagent/src/agent/entity/agent_message.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_event.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_hub.dart';
import 'package:wenzagent/src/persistence/entities/message_entity.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

/// 未读消息需求测试
///
/// 需求：
/// 1. 重启app后，数量正确
/// 2. 会话中，数量要清除，标记为已读
/// 3. 打开会话，数量要清除，标记为已读
/// 4. 清空消息，要清空未读状态
void main() {
  // ====== Group 1: AgentNotificationHub 单元测试 ======
  group('需求2&3: 会话中/打开会话时自动已读', () {
    late AgentNotificationHub hub;
    const employeeId = 'emp-001';
    const fromDeviceId = 'device-remote-001';
    const toDeviceId = 'device-local-001';

    setUp(() {
      hub = AgentNotificationHub();
    });

    tearDown(() {
      hub.dispose();
    });

    AgentMessage _makeMessage(String id, String content) {
      return AgentMessage(
        id: id,
        role: 'assistant',
        type: 'text',
        content: content,
        createdAt: DateTime.now(),
        status: 'completed',
      );
    }

    test('需求2: shouldAutoMarkAsRead=true 时消息自动已读，不增加未读计数', () {
      // 模拟会话已打开
      hub.shouldAutoMarkAsReadCallback = ({
        required String employeeId,
        String? fromDeviceId,
      }) =>
          true;

      hub.onRemoteMessage(
        message: _makeMessage('msg-1', '你好'),
        fromDeviceId: fromDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );

      expect(hub.getUnreadCount(employeeId: employeeId), equals(0));
    });

    test('需求2: shouldAutoMarkAsRead=true 时 AgentMessageArrivedEvent.autoRead=true',
        () async {
      hub.shouldAutoMarkAsReadCallback = ({
        required String employeeId,
        String? fromDeviceId,
      }) =>
          true;

      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: employeeId).listen(events.add);

      hub.onRemoteMessage(
        message: _makeMessage('msg-1', '你好'),
        fromDeviceId: fromDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );

      await Future.delayed(Duration.zero);

      final arrivedEvents =
          events.whereType<AgentMessageArrivedEvent>().toList();
      expect(arrivedEvents, hasLength(1));
      expect(arrivedEvents.first.autoRead, isTrue);
    });

    test('需求3: markAllAsRead 后未读计数归零', () {
      // 先收到3条未读消息
      for (int i = 0; i < 3; i++) {
        hub.onRemoteMessage(
          message: _makeMessage('msg-$i', '消息$i'),
          fromDeviceId: fromDeviceId,
          toDeviceId: toDeviceId,
          employeeId: employeeId,
        );
      }
      expect(hub.getUnreadCount(employeeId: employeeId), equals(3));

      // 打开会话，标记全部已读
      hub.markAllAsRead(employeeId: employeeId);
      expect(hub.getUnreadCount(employeeId: employeeId), equals(0));
    });

    test('需求3: markAllAsRead 后广播 ReadStatusChanged 事件', () async {
      hub.onRemoteMessage(
        message: _makeMessage('msg-a', 'A'),
        fromDeviceId: fromDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );

      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: employeeId).listen(events.add);
      events.clear();

      hub.markAllAsRead(employeeId: employeeId);
      await Future.delayed(Duration.zero);

      final readEvents =
          events.whereType<AgentMessageReadStatusChangedEvent>().toList();
      expect(readEvents, hasLength(1));
      expect(readEvents.first.messageId, equals('msg-a'));
      expect(readEvents.first.isRead, isTrue);
    });

    test('需求3: markAllAsRead 后广播 UnreadCountChanged(count=0)', () async {
      hub.onRemoteMessage(
        message: _makeMessage('msg-1', 'M'),
        fromDeviceId: fromDeviceId,
        toDeviceId: toDeviceId,
        employeeId: employeeId,
      );

      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: employeeId).listen(events.add);
      events.clear();

      hub.markAllAsRead(employeeId: employeeId);
      await Future.delayed(Duration.zero);

      final countEvents =
          events.whereType<AgentUnreadCountChangedEvent>().toList();
      expect(countEvents.any((e) => e.unreadCount == 0), isTrue);
    });
  });

  // ====== Group 2: restoreUnreadCount + markAllAsRead 联动测试 ======
  group('需求1: 重启后从DB恢复未读计数', () {
    late AgentNotificationHub hub;

    setUp(() {
      hub = AgentNotificationHub();
    });

    tearDown(() {
      hub.dispose();
    });

    test('restoreUnreadCount 设置未读计数', () async {
      const employeeId = 'emp-001';

      hub.restoreUnreadCount(employeeId: employeeId, count: 5);

      expect(hub.getUnreadCount(employeeId: employeeId), equals(5));
    });

    test('restoreUnreadCount 广播 UnreadCountChanged 事件', () async {
      const employeeId = 'emp-001';
      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: employeeId).listen(events.add);

      hub.restoreUnreadCount(employeeId: employeeId, count: 3);
      await Future.delayed(Duration.zero);

      final countEvents =
          events.whereType<AgentUnreadCountChangedEvent>().toList();
      expect(countEvents, hasLength(1));
      expect(countEvents.first.unreadCount, equals(3));
      expect(countEvents.first.employeeId, equals(employeeId));
    });

    test('restoreUnreadCount 按 fromDeviceId 恢复', () async {
      const employeeId = 'emp-001';
      const fromDeviceId = 'device-A';

      hub.restoreUnreadCount(
        employeeId: employeeId,
        count: 3,
        fromDeviceId: fromDeviceId,
      );

      expect(hub.getUnreadCount(employeeId: employeeId), equals(3));
      expect(
        hub.getUnreadCount(employeeId: employeeId, fromDeviceId: fromDeviceId),
        equals(3),
      );
    });

    test('restoreUnreadCount 后 markAllAsRead 能正确清零', () async {
      const employeeId = 'emp-001';

      // 模拟从DB恢复：只设置了计数，没有跟踪具体消息
      hub.restoreUnreadCount(employeeId: employeeId, count: 5);
      expect(hub.getUnreadCount(employeeId: employeeId), equals(5));

      // 打开会话后标记已读
      hub.markAllAsRead(employeeId: employeeId);
      expect(hub.getUnreadCount(employeeId: employeeId), equals(0));
    });

    test('restoreUnreadCount 后 markAllAsRead 广播 count=0 事件', () async {
      const employeeId = 'emp-001';

      hub.restoreUnreadCount(employeeId: employeeId, count: 3);

      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: employeeId).listen(events.add);

      hub.markAllAsRead(employeeId: employeeId);
      await Future.delayed(Duration.zero);

      final countEvents =
          events.whereType<AgentUnreadCountChangedEvent>().toList();
      expect(countEvents.any((e) => e.unreadCount == 0), isTrue);
    });

    test('restoreUnreadCount 后 getTotalUnreadCount 正确', () {
      hub.restoreUnreadCount(employeeId: 'emp-001', count: 3);
      hub.restoreUnreadCount(employeeId: 'emp-002', count: 7);

      expect(hub.getTotalUnreadCount(), equals(10));
    });
  });

  // ====== Group 3: 带 Hive 的集成测试 ======
  group('需求1&4: 带持久化的集成测试', () {
    const testPath = 'D:\\project\\GitHub\\wenzagent\\test_hive_unread';
    late MessageStoreServiceImpl messageStore;
    const deviceId = 'device-local-001';
    const employeeId = 'emp-001';
    const remoteDeviceId = 'device-remote-001';

    setUpAll(() async {
      await HiveManager.instance.initialize(storagePath: testPath);
    });

    tearDownAll(() async {
      await HiveManager.instance.close();
    });

    setUp(() async {
      messageStore = MessageStoreServiceImpl(deviceId: deviceId);
      // 清理之前的测试数据
      try {
        await messageStore.deleteMessages(employeeId);
      } catch (_) {}
    });

    // ---- 需求1: 重启后恢复未读 ----
    test('需求1: 写入未读消息到DB后，统计未读数量正确', () async {
      // 模拟：写入3条助手消息（isRead=0）+ 2条用户消息
      for (int i = 0; i < 3; i++) {
        final entity = AiEmployeeMessageEntity(
          uuid: 'msg-assistant-$i',
          employeeId: employeeId,
          role: 'assistant',
          type: 'text',
          content: '助手回复$i',
          isRead: 0,
          createTime: DateTime.now().subtract(Duration(minutes: 5 - i)),
          updateTime: DateTime.now(),
        );
        await messageStore.addMessage(entity);
      }
      for (int i = 0; i < 2; i++) {
        final entity = AiEmployeeMessageEntity(
          uuid: 'msg-user-$i',
          employeeId: employeeId,
          role: 'user',
          type: 'text',
          content: '用户消息$i',
          isRead: 0,
          createTime: DateTime.now().subtract(Duration(minutes: 3 - i)),
          updateTime: DateTime.now(),
        );
        await messageStore.addMessage(entity);
      }

      // 查询所有消息，统计未读的助手消息
      final messages = await messageStore.getMessages(employeeId);
      final unreadCount =
          messages.where((m) => m.role == 'assistant' && m.isRead == 0).length;

      expect(unreadCount, equals(3));
    });

    test('需求1: 部分消息已读后，统计未读数量正确', () async {
      // 写入3条助手消息，其中2条未读
      for (int i = 0; i < 3; i++) {
        final entity = AiEmployeeMessageEntity(
          uuid: 'msg-read-test-$i',
          employeeId: employeeId,
          role: 'assistant',
          type: 'text',
          content: '消息$i',
          isRead: i == 0 ? 1 : 0, // 第1条已读，后2条未读
          createTime: DateTime.now().subtract(Duration(minutes: 3 - i)),
          updateTime: DateTime.now(),
        );
        await messageStore.addMessage(entity);
      }

      final messages = await messageStore.getMessages(employeeId);
      final unreadCount =
          messages.where((m) => m.role == 'assistant' && m.isRead == 0).length;

      expect(unreadCount, equals(2));
    });

    test('需求1: 模拟完整重启流程 - 写入消息 -> 销毁Hub -> 恢复 -> 计数正确',
        () async {
      // 阶段1: 正常运行时，写入未读消息
      final now = DateTime.now();
      for (int i = 0; i < 4; i++) {
        final entity = AiEmployeeMessageEntity(
          uuid: 'msg-restart-$i',
          employeeId: employeeId,
          role: 'assistant',
          type: 'text',
          content: '未读消息$i',
          isRead: 0,
          createTime: now.subtract(Duration(minutes: 4 - i)),
          updateTime: now,
        );
        await messageStore.addMessage(entity);
      }

      // 阶段2: 模拟App关闭 - dispose hub
      final hub1 = AgentNotificationHub();
      hub1.onRemoteMessage(
        message: AgentMessage(
          id: 'msg-restart-extra',
          role: 'assistant',
          type: 'text',
          content: '内存中但未持久化的消息',
          createdAt: now,
          status: 'completed',
        ),
        fromDeviceId: remoteDeviceId,
        toDeviceId: deviceId,
        employeeId: employeeId,
      );
      expect(hub1.getUnreadCount(employeeId: employeeId), equals(1));
      hub1.dispose();

      // 阶段3: 模拟App重启 - 新建 hub
      final hub2 = AgentNotificationHub();
      expect(hub2.getUnreadCount(employeeId: employeeId), equals(0));

      // 阶段4: 模拟 restoreUnreadStatus - 从DB查询未读并恢复
      final messages = await messageStore.getMessages(employeeId);
      final unreadCount = messages
          .where((m) => m.role == 'assistant' && m.isRead == 0)
          .length;

      hub2.restoreUnreadCount(employeeId: employeeId, count: unreadCount);

      // 验证：DB中有4条未读助手消息，恢复后hub计数应为4
      expect(hub2.getUnreadCount(employeeId: employeeId), equals(4));

      hub2.dispose();
    });

    test('需求1: 重启恢复后打开会话 -> 标记已读 -> DB也更新', () async {
      // 写入未读消息
      for (int i = 0; i < 3; i++) {
        final entity = AiEmployeeMessageEntity(
          uuid: 'msg-reopen-$i',
          employeeId: employeeId,
          role: 'assistant',
          type: 'text',
          content: '消息$i',
          isRead: 0,
          createTime: DateTime.now().subtract(Duration(minutes: 3 - i)),
          updateTime: DateTime.now(),
        );
        await messageStore.addMessage(entity);
      }

      // 模拟重启后恢复
      final hub = AgentNotificationHub();
      final messages = await messageStore.getMessages(employeeId);
      final unreadCount = messages
          .where((m) => m.role == 'assistant' && m.isRead == 0)
          .length;
      hub.restoreUnreadCount(employeeId: employeeId, count: unreadCount);
      expect(hub.getUnreadCount(employeeId: employeeId), equals(3));

      // 打开会话 -> 标记已读
      hub.markAllAsRead(employeeId: employeeId);
      expect(hub.getUnreadCount(employeeId: employeeId), equals(0));

      // 更新DB中的isRead
      final dbMessages = await messageStore.getMessages(employeeId);
      for (final m in dbMessages) {
        if (m.role == 'assistant' && m.isRead == 0) {
          await messageStore.updateMessage(m.copyWith(isRead: 1, jsonData: null));
        }
      }

      // 验证DB中所有助手消息已读
      final updatedMessages = await messageStore.getMessages(employeeId);
      final dbUnreadCount = updatedMessages
          .where((m) => m.role == 'assistant' && m.isRead == 0)
          .length;
      expect(dbUnreadCount, equals(0));

      // 再次模拟重启 -> 恢复后计数应为0
      hub.dispose();
      final hub2 = AgentNotificationHub();
      final messagesAfterRead = await messageStore.getMessages(employeeId);
      final unreadAfterRead = messagesAfterRead
          .where((m) => m.role == 'assistant' && m.isRead == 0)
          .length;
      hub2.restoreUnreadCount(
          employeeId: employeeId, count: unreadAfterRead);
      expect(hub2.getUnreadCount(employeeId: employeeId), equals(0));

      hub2.dispose();
    });

    // ---- 需求4: 清空消息后清除未读状态 ----
    test('需求4: 清空消息后Hub未读计数归零', () async {
      final hub = AgentNotificationHub();

      // 写入未读消息
      for (int i = 0; i < 3; i++) {
        final entity = AiEmployeeMessageEntity(
          uuid: 'msg-clear-$i',
          employeeId: employeeId,
          role: 'assistant',
          type: 'text',
          content: '消息$i',
          isRead: 0,
          createTime: DateTime.now(),
          updateTime: DateTime.now(),
        );
        await messageStore.addMessage(entity);
      }

      // 恢复未读计数
      final messages = await messageStore.getMessages(employeeId);
      final unreadCount = messages
          .where((m) => m.role == 'assistant' && m.isRead == 0)
          .length;
      hub.restoreUnreadCount(employeeId: employeeId, count: unreadCount);
      expect(hub.getUnreadCount(employeeId: employeeId), equals(3));

      // 清空消息
      await messageStore.deleteMessages(employeeId);

      // 清空后同步清除hub未读
      hub.markAllAsRead(employeeId: employeeId);
      expect(hub.getUnreadCount(employeeId: employeeId), equals(0));

      // 验证DB中消息已清空
      final remaining = await messageStore.getMessages(employeeId);
      expect(remaining, isEmpty);

      hub.dispose();
    });

    test('需求4: 清空消息后重新恢复计数为0', () async {
      final hub = AgentNotificationHub();

      // 写入未读消息
      for (int i = 0; i < 2; i++) {
        final entity = AiEmployeeMessageEntity(
          uuid: 'msg-clear2-$i',
          employeeId: employeeId,
          role: 'assistant',
          type: 'text',
          content: '消息$i',
          isRead: 0,
          createTime: DateTime.now(),
          updateTime: DateTime.now(),
        );
        await messageStore.addMessage(entity);
      }

      // 恢复 -> 清空 -> hub清零
      var messages = await messageStore.getMessages(employeeId);
      var unreadCount =
          messages.where((m) => m.role == 'assistant' && m.isRead == 0).length;
      hub.restoreUnreadCount(employeeId: employeeId, count: unreadCount);
      expect(hub.getUnreadCount(employeeId: employeeId), equals(2));

      await messageStore.deleteMessages(employeeId);
      hub.markAllAsRead(employeeId: employeeId);
      expect(hub.getUnreadCount(employeeId: employeeId), equals(0));

      // 模拟重启
      hub.dispose();
      final hub2 = AgentNotificationHub();
      messages = await messageStore.getMessages(employeeId);
      unreadCount =
          messages.where((m) => m.role == 'assistant' && m.isRead == 0).length;
      hub2.restoreUnreadCount(employeeId: employeeId, count: unreadCount);
      expect(hub2.getUnreadCount(employeeId: employeeId), equals(0));

      hub2.dispose();
    });

    // ---- 回归测试: 打开会话自动已读后 DB 必须同步更新 ----
    test('回归: markAllAsRead 后必须更新DB，否则重启后未读会被错误恢复',
        () async {
      // 阶段1: 写入3条未读助手消息
      for (int i = 0; i < 3; i++) {
        final entity = AiEmployeeMessageEntity(
          uuid: 'msg-regression-$i',
          employeeId: employeeId,
          role: 'assistant',
          type: 'text',
          content: '未读消息$i',
          isRead: 0,
          createTime: DateTime.now().subtract(Duration(minutes: 3 - i)),
          updateTime: DateTime.now(),
        );
        await messageStore.addMessage(entity);
      }

      // 阶段2: 模拟运行时，从DB恢复未读计数
      final hub1 = AgentNotificationHub();
      var messages = await messageStore.getMessages(employeeId);
      var unreadCount =
          messages.where((m) => m.role == 'assistant' && m.isRead == 0).length;
      hub1.restoreUnreadCount(employeeId: employeeId, count: unreadCount);
      expect(hub1.getUnreadCount(employeeId: employeeId), equals(3));

      // 阶段3: 打开会话 -> hub.markAllAsRead() 清除内存未读
      // （此时应该同时更新 DB，否则重启后未读会被错误恢复）
      hub1.markAllAsRead(employeeId: employeeId);
      expect(hub1.getUnreadCount(employeeId: employeeId), equals(0));

      // 阶段4: 模拟 _markMessagesAsReadInDb（修复后的 onMarkAsRead 回调会做这件事）
      messages = await messageStore.getMessages(employeeId);
      for (final m in messages) {
        if (m.role == 'assistant' && m.isRead == 0) {
          await messageStore.updateMessage(m.copyWith(isRead: 1, jsonData: null));
        }
      }

      // 阶段5: 模拟重启 -> 新建 hub -> 从 DB 恢复
      hub1.dispose();
      final hub2 = AgentNotificationHub();
      messages = await messageStore.getMessages(employeeId);
      unreadCount =
          messages.where((m) => m.role == 'assistant' && m.isRead == 0).length;
      hub2.restoreUnreadCount(employeeId: employeeId, count: unreadCount);

      // 验证：DB 中所有助手消息已读，重启后未读计数应为 0
      expect(unreadCount, equals(0),
          reason: 'DB 中应无未读消息（markAllAsRead 后必须同步更新 DB）');
      expect(hub2.getUnreadCount(employeeId: employeeId), equals(0));

      hub2.dispose();
    });

    test('回归: markAllAsRead 后不更新DB时重启会错误恢复未读（验证 bug 存在）',
        () async {
      // 写入2条未读助手消息
      for (int i = 0; i < 2; i++) {
        final entity = AiEmployeeMessageEntity(
          uuid: 'msg-bug-$i',
          employeeId: employeeId,
          role: 'assistant',
          type: 'text',
          content: '未读$i',
          isRead: 0,
          createTime: DateTime.now().subtract(Duration(minutes: 2 - i)),
          updateTime: DateTime.now(),
        );
        await messageStore.addMessage(entity);
      }

      // 运行时恢复
      final hub1 = AgentNotificationHub();
      var messages = await messageStore.getMessages(employeeId);
      var unreadCount =
          messages.where((m) => m.role == 'assistant' && m.isRead == 0).length;
      hub1.restoreUnreadCount(employeeId: employeeId, count: unreadCount);
      expect(hub1.getUnreadCount(employeeId: employeeId), equals(2));

      // 打开会话 -> hub.markAllAsRead() 但故意不更新 DB
      hub1.markAllAsRead(employeeId: employeeId);
      expect(hub1.getUnreadCount(employeeId: employeeId), equals(0));

      // 模拟重启 -> 从 DB 恢复（此时 DB 中 isRead 仍为 0）
      hub1.dispose();
      final hub2 = AgentNotificationHub();
      messages = await messageStore.getMessages(employeeId);
      unreadCount =
          messages.where((m) => m.role == 'assistant' && m.isRead == 0).length;
      hub2.restoreUnreadCount(employeeId: employeeId, count: unreadCount);

      // 验证：如果不更新 DB，重启后未读计数会被错误恢复
      expect(unreadCount, equals(2),
          reason: '未更新 DB 时，重启后 DB 中仍为未读');
      expect(hub2.getUnreadCount(employeeId: employeeId), equals(2),
          reason: 'bug 复现：打开会话后内存清零但 DB 未更新，重启后未读被错误恢复');

      hub2.dispose();

      // 清理：修复 DB 状态
      messages = await messageStore.getMessages(employeeId);
      for (final m in messages) {
        if (m.role == 'assistant' && m.isRead == 0) {
          await messageStore.updateMessage(m.copyWith(isRead: 1, jsonData: null));
        }
      }
    });
  });
}
