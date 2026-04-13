import 'dart:async';

import 'package:test/test.dart';
import 'package:wenzagent/src/agent/entity/agent_message.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_event.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_hub.dart';

/// AgentNotificationHub 测试
///
/// 验证：
/// - 本地/远程未读计数追踪
/// - 最新消息缓存更新
/// - restoreUnreadStatus 恢复流程
/// - 标记已读传播
void main() {
  late AgentNotificationHub hub;

  setUp(() {
    hub = AgentNotificationHub();
  });

  tearDown(() {
    hub.dispose();
  });

  AgentMessage _createMessage({
    required String id,
    String content = 'test',
    String role = 'assistant',
    DateTime? createdAt,
  }) {
    return AgentMessage(
      id: id,
      role: role,
      type: 'text',
      content: content,
      createdAt: createdAt ?? DateTime.now(),
    );
  }

  group('本地/远程未读计数追踪', () {
    test('remote message increments unread count', () async {
      final arrivedEvents = <AgentMessageArrivedEvent>[];
      final sub = hub.stream().where((e) => e is AgentMessageArrivedEvent).cast<AgentMessageArrivedEvent>().listen(arrivedEvents.add);

      hub.onRemoteMessage(
        message: _createMessage(id: 'msg-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      // 等待事件传播
      await Future.delayed(const Duration(milliseconds: 50));

      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(1));
      expect(arrivedEvents, hasLength(1));

      sub.cancel();
    });

    test('local message does not increment unread by default', () async {
      hub.onLocalMessage(
        message: _createMessage(id: 'msg-2'),
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(0));
    });

    test('local message with markUnread=true increments count', () async {
      hub.onLocalMessage(
        message: _createMessage(id: 'msg-3'),
        employeeId: 'emp-1',
        markUnread: true,
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(1));
    });

    test('autoRead prevents unread count', () async {
      hub.shouldAutoMarkAsReadCallback = ({
        required String employeeId,
        String? fromDeviceId,
      }) {
        return true; // 当前会话打开，自动已读
      };

      hub.onRemoteMessage(
        message: _createMessage(id: 'msg-4'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(0));
    });

    test('unread count tracks by device', () async {
      hub.onRemoteMessage(
        message: _createMessage(id: 'msg-a1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: _createMessage(id: 'msg-a2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: _createMessage(id: 'msg-c1'),
        fromDeviceId: 'device-C',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(3));
      expect(
        hub.getUnreadCount(employeeId: 'emp-1', fromDeviceId: 'device-A'),
        equals(2),
      );
      expect(
        hub.getUnreadCount(employeeId: 'emp-1', fromDeviceId: 'device-C'),
        equals(1),
      );
    });

    test('duplicate message ignored', () {
      hub.onRemoteMessage(
        message: _createMessage(id: 'msg-dup'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: _createMessage(id: 'msg-dup'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(1));
    });

    test('total unread across employees', () {
      hub.onRemoteMessage(
        message: _createMessage(id: 'msg-e1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: _createMessage(id: 'msg-e2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-2',
      );

      expect(hub.getTotalUnreadCount(), equals(2));
    });
  });

  group('最新消息缓存更新', () {
    test('onLatestMessageUpdated emits event', () async {
      final events = <AgentNotificationEvent>[];
      final sub = hub.stream().listen(events.add);

      hub.onLatestMessageUpdated(
        message: _createMessage(id: 'latest-1', content: 'Latest msg'),
        employeeId: 'emp-1',
        fromDeviceId: 'device-A',
        unreadCount: 5,
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(events, hasLength(1));
      final event = events.first as AgentLatestMessageUpdatedEvent;
      expect(event.latestMessage.content, equals('Latest msg'));
      expect(event.unreadCount, equals(5));
      expect(event.employeeId, equals('emp-1'));

      sub.cancel();
    });

    test('onLatestMessageCleared emits event', () async {
      final events = <AgentNotificationEvent>[];
      final sub = hub.stream().listen(events.add);

      hub.onLatestMessageCleared(
        employeeId: 'emp-1',
        fromDeviceId: 'device-A',
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(events, hasLength(1));
      expect(events.first, isA<AgentLatestMessageClearedEvent>());

      sub.cancel();
    });
  });

  group('restoreUnreadStatus 恢复流程', () {
    test('restoreUnreadCount sets count without messages', () async {
      final events = <AgentUnreadCountChangedEvent>[];
      final sub = hub.subscribeUnreadCount(events.add, employeeId: 'emp-1');

      hub.restoreUnreadCount(employeeId: 'emp-1', count: 3);

      await Future.delayed(const Duration(milliseconds: 50));

      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(3));
      expect(events, hasLength(1));
      expect(events.first.unreadCount, equals(3));

      sub.cancel();
    });

    test('restoreUnreadMessages rebuilds message tracking', () async {
      final messages = [
        (
          messageId: 'restore-1',
          fromDeviceId: 'device-A',
          message: _createMessage(id: 'restore-1'),
        ),
        (
          messageId: 'restore-2',
          fromDeviceId: 'device-A',
          message: _createMessage(id: 'restore-2'),
        ),
      ];

      hub.restoreUnreadMessages(
        employeeId: 'emp-1',
        unreadMessages: messages,
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(2));

      // 消息应该被标记为已处理，不会再次触发通知
      hub.onRemoteMessage(
        message: _createMessage(id: 'restore-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      // 仍然是2，因为 restore-1 已处理
      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(2));
    });

    test('restore with device tracking', () async {
      hub.restoreUnreadCount(
        employeeId: 'emp-1',
        count: 5,
        fromDeviceId: 'device-A',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(5));
      expect(
        hub.getUnreadCount(employeeId: 'emp-1', fromDeviceId: 'device-A'),
        equals(5),
      );
    });
  });

  group('标记已读传播', () {
    test('markAsRead removes single message', () async {
      hub.onRemoteMessage(
        message: _createMessage(id: 'read-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: _createMessage(id: 'read-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(2));

      final changed = hub.markAsRead(messageId: 'read-1', employeeId: 'emp-1');
      expect(changed, isTrue);
      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(1));

      // 标记已读的消息返回 false
      final changedAgain =
          hub.markAsRead(messageId: 'read-1', employeeId: 'emp-1');
      expect(changedAgain, isFalse);
    });

    test('markAllAsRead clears all for employee', () async {
      hub.onRemoteMessage(
        message: _createMessage(id: 'all-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: _createMessage(id: 'all-2'),
        fromDeviceId: 'device-C',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(2));

      hub.markAllAsRead(employeeId: 'emp-1');

      expect(hub.getUnreadCount(employeeId: 'emp-1'), equals(0));
    });

    test('markAllAsRead with fromDeviceId filters correctly', () async {
      hub.onRemoteMessage(
        message: _createMessage(id: 'dev-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: _createMessage(id: 'dev-2'),
        fromDeviceId: 'device-C',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      hub.markAllAsRead(employeeId: 'emp-1', fromDeviceId: 'device-A');

      // device-A 的已清除，device-C 的仍在
      expect(
        hub.getUnreadCount(employeeId: 'emp-1', fromDeviceId: 'device-A'),
        equals(0),
      );
      expect(
        hub.getUnreadCount(employeeId: 'emp-1', fromDeviceId: 'device-C'),
        equals(1),
      );
    });

    test('markAllAsReadGlobal clears all employees', () async {
      hub.onRemoteMessage(
        message: _createMessage(id: 'global-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: _createMessage(id: 'global-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-2',
      );

      hub.markAllAsReadGlobal();

      expect(hub.getTotalUnreadCount(), equals(0));
    });

    test('markAsRead broadcasts event', () async {
      final events = <AgentNotificationEvent>[];
      final sub = hub.stream(employeeId: 'emp-1').listen(events.add);

      hub.onRemoteMessage(
        message: _createMessage(id: 'broadcast-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      await Future.delayed(const Duration(milliseconds: 50));
      events.clear();

      hub.markAsRead(messageId: 'broadcast-1', employeeId: 'emp-1');

      await Future.delayed(const Duration(milliseconds: 50));

      final readEvent = events.whereType<AgentMessageReadStatusChangedEvent>().firstOrNull;
      expect(readEvent, isNotNull);
      expect(readEvent!.messageId, equals('broadcast-1'));
      expect(readEvent.isRead, isTrue);

      sub.cancel();
    });
  });

  group('isMessageRead 查询', () {
    test('returns false for unread messages', () {
      hub.onRemoteMessage(
        message: _createMessage(id: 'check-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      expect(
        hub.isMessageRead(messageId: 'check-1', employeeId: 'emp-1'),
        isFalse,
      );
    });

    test('returns true after markAsRead', () {
      hub.onRemoteMessage(
        message: _createMessage(id: 'check-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      hub.markAsRead(messageId: 'check-2', employeeId: 'emp-1');

      expect(
        hub.isMessageRead(messageId: 'check-2', employeeId: 'emp-1'),
        isTrue,
      );
    });

    test('returns true for unknown messages', () {
      expect(
        hub.isMessageRead(messageId: 'unknown', employeeId: 'emp-1'),
        isTrue,
      );
    });
  });

  group('订阅过滤', () {
    test('subscribe with employeeId filter', () async {
      final arrivedEvents = <AgentMessageArrivedEvent>[];
      final sub = hub.stream(employeeId: 'emp-1').where((e) => e is AgentMessageArrivedEvent).cast<AgentMessageArrivedEvent>().listen(arrivedEvents.add);

      hub.onRemoteMessage(
        message: _createMessage(id: 'filter-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: _createMessage(id: 'filter-2'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-2',
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(arrivedEvents, hasLength(1));
      expect(arrivedEvents.first.employeeId, equals('emp-1'));

      sub.cancel();
    });

    test('subscribe with fromDeviceId filter', () async {
      final arrivedEvents = <AgentMessageArrivedEvent>[];
      final sub = hub.stream(fromDeviceId: 'device-A').where((e) => e is AgentMessageArrivedEvent).cast<AgentMessageArrivedEvent>().listen(arrivedEvents.add);

      hub.onRemoteMessage(
        message: _createMessage(id: 'dev-filter-1'),
        fromDeviceId: 'device-A',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );
      hub.onRemoteMessage(
        message: _createMessage(id: 'dev-filter-2'),
        fromDeviceId: 'device-C',
        toDeviceId: 'device-B',
        employeeId: 'emp-1',
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(arrivedEvents, hasLength(1));
      expect(arrivedEvents.first.fromDeviceId, equals('device-A'));

      sub.cancel();
    });
  });
}
