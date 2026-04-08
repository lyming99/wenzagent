import 'dart:async';

import 'package:test/test.dart';

import 'package:wenzagent/src/agent/entity/agent_message.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_event.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_hub.dart';

/// 最新消息缓存需求测试
///
/// 需求覆盖：
/// 1. 收到消息时通知会话列表更新（onLatestMessageUpdated 事件）
/// 2. 清空消息时清除最新消息缓存（onLatestMessageCleared 事件）
/// 3. 权限请求消息优先显示，直到被更新的消息覆盖
/// 4. 打开 app 时从 DB 恢复最新消息缓存（通过 hub 事件通知 UI）
void main() {
  // ====== Group 1: onLatestMessageUpdated 事件测试 ======
  group('需求1: 收到消息时通知会话列表更新', () {
    late AgentNotificationHub hub;

    setUp(() {
      hub = AgentNotificationHub();
    });

    tearDown(() {
      hub.dispose();
    });

    AgentMessage _makeMessage(String id, String content, {DateTime? createdAt}) {
      return AgentMessage(
        id: id,
        role: 'assistant',
        type: 'text',
        content: content,
        createdAt: createdAt ?? DateTime.now(),
        status: 'completed',
      );
    }

    test('onLatestMessageUpdated 广播 AgentLatestMessageUpdatedEvent', () async {
      const employeeId = 'emp-001';
      const fromDeviceId = 'device-001';
      final msg = _makeMessage('msg-1', '你好世界');

      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: employeeId).listen(events.add);

      hub.onLatestMessageUpdated(
        message: msg,
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        unreadCount: 2,
      );

      await Future.delayed(Duration.zero);

      final latestEvents =
          events.whereType<AgentLatestMessageUpdatedEvent>().toList();
      expect(latestEvents, hasLength(1));
      expect(latestEvents.first.latestMessage.id, equals('msg-1'));
      expect(latestEvents.first.employeeId, equals(employeeId));
      expect(latestEvents.first.fromDeviceId, equals(fromDeviceId));
      expect(latestEvents.first.unreadCount, equals(2));
    });

    test('onLatestMessageUpdated 事件可按 employeeId 过滤', () async {
      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: 'emp-001').listen(events.add);

      hub.onLatestMessageUpdated(
        message: _makeMessage('msg-1', 'A'),
        employeeId: 'emp-001',
        fromDeviceId: 'device-001',
        unreadCount: 1,
      );
      hub.onLatestMessageUpdated(
        message: _makeMessage('msg-2', 'B'),
        employeeId: 'emp-002',
        fromDeviceId: 'device-002',
        unreadCount: 3,
      );

      await Future.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(
        (events.first as AgentLatestMessageUpdatedEvent)
            .latestMessage
            .id,
        equals('msg-1'),
      );
    });

    test('onLatestMessageUpdated 事件可按 fromDeviceId 过滤', () async {
      final events = <AgentNotificationEvent>[];
      hub.stream(fromDeviceId: 'device-A').listen(events.add);

      hub.onLatestMessageUpdated(
        message: _makeMessage('msg-1', 'A'),
        employeeId: 'emp-001',
        fromDeviceId: 'device-A',
        unreadCount: 1,
      );
      hub.onLatestMessageUpdated(
        message: _makeMessage('msg-2', 'B'),
        employeeId: 'emp-001',
        fromDeviceId: 'device-B',
        unreadCount: 2,
      );

      await Future.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(
        (events.first as AgentLatestMessageUpdatedEvent).fromDeviceId,
        equals('device-A'),
      );
    });
  });

  // ====== Group 2: onLatestMessageCleared 事件测试 ======
  group('需求5: 清空消息时清除最新消息缓存', () {
    late AgentNotificationHub hub;

    setUp(() {
      hub = AgentNotificationHub();
    });

    tearDown(() {
      hub.dispose();
    });

    test('onLatestMessageCleared 广播 AgentLatestMessageClearedEvent', () async {
      const employeeId = 'emp-001';
      const fromDeviceId = 'device-001';

      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: employeeId).listen(events.add);

      hub.onLatestMessageCleared(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
      );

      await Future.delayed(Duration.zero);

      final clearedEvents =
          events.whereType<AgentLatestMessageClearedEvent>().toList();
      expect(clearedEvents, hasLength(1));
      expect(clearedEvents.first.employeeId, equals(employeeId));
      expect(clearedEvents.first.fromDeviceId, equals(fromDeviceId));
    });

    test('onLatestMessageCleared 事件可按 employeeId 过滤', () async {
      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: 'emp-001').listen(events.add);

      hub.onLatestMessageCleared(
        employeeId: 'emp-001',
        fromDeviceId: 'device-001',
      );
      hub.onLatestMessageCleared(
        employeeId: 'emp-002',
        fromDeviceId: 'device-001',
      );

      await Future.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(
        (events.first as AgentLatestMessageClearedEvent).employeeId,
        equals('emp-001'),
      );
    });

    test('onLatestMessageCleared 事件可按 fromDeviceId 过滤', () async {
      final events = <AgentNotificationEvent>[];
      hub.stream(fromDeviceId: 'device-A').listen(events.add);

      hub.onLatestMessageCleared(
        employeeId: 'emp-001',
        fromDeviceId: 'device-A',
      );
      hub.onLatestMessageCleared(
        employeeId: 'emp-001',
        fromDeviceId: 'device-B',
      );

      await Future.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(
        (events.first as AgentLatestMessageClearedEvent).fromDeviceId,
        equals('device-A'),
      );
    });

    test('清空消息流程：先更新再清除，事件序列正确', () async {
      const employeeId = 'emp-001';
      const fromDeviceId = 'device-001';

      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: employeeId).listen(events.add);

      // 模拟收到消息 → 更新最新消息
      hub.onLatestMessageUpdated(
        message: AgentMessage(
          id: 'msg-1',
          role: 'assistant',
          type: 'text',
          content: '你好',
          createdAt: DateTime.now(),
          status: 'completed',
        ),
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        unreadCount: 1,
      );

      // 模拟清空消息 → 清除最新消息
      hub.onLatestMessageCleared(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
      );

      await Future.delayed(Duration.zero);

      expect(events, hasLength(2));
      expect(events[0], isA<AgentLatestMessageUpdatedEvent>());
      expect(events[1], isA<AgentLatestMessageClearedEvent>());
    });
  });

  // ====== Group 3: 权限请求消息优先显示测试 ======
  group('需求3: 权限请求消息优先显示', () {
    /// 模拟 _updateLatestMessageCache 的优先级逻辑
    ///
    /// 由于 _updateLatestMessageCache 是 DeviceClientImpl 的私有方法，
    /// 这里提取其核心优先级判断逻辑进行测试。
    bool shouldUpdateCache(AgentMessage? cached, AgentMessage incoming) {
      if (cached == null) return true;
      // 权限请求消息始终优先缓存
      if (incoming.type == 'permission') return true;
      // 其他消息按时间比较
      return incoming.createdAt.isAfter(cached.createdAt);
    }

    AgentMessage _makeMessage(String id, String content, String type,
        {DateTime? createdAt}) {
      return AgentMessage(
        id: id,
        role: 'assistant',
        type: type,
        content: content,
        createdAt: createdAt ?? DateTime.now(),
        status: 'completed',
      );
    }

    test('无缓存时，任何消息都应缓存', () {
      final incoming = _makeMessage('msg-1', '你好', 'text');
      expect(shouldUpdateCache(null, incoming), isTrue);
    });

    test('权限请求消息始终覆盖普通消息（即使时间更早）', () {
      final cached = _makeMessage(
        'msg-normal',
        '普通消息',
        'text',
        createdAt: DateTime.now().add(Duration(minutes: 1)),
      );
      final permissionMsg = _makeMessage(
        'msg-perm',
        '等待权限确认',
        'permission',
        createdAt: DateTime.now().subtract(Duration(minutes: 1)),
      );

      expect(shouldUpdateCache(cached, permissionMsg), isTrue);
    });

    test('权限请求消息覆盖已有权限请求（权限更新）', () {
      final cached = _makeMessage(
        'perm-old',
        '旧权限请求',
        'permission',
        createdAt: DateTime.now().subtract(Duration(minutes: 1)),
      );
      final newPerm = _makeMessage(
        'perm-new',
        '新权限请求',
        'permission',
        createdAt: DateTime.now(),
      );

      expect(shouldUpdateCache(cached, newPerm), isTrue);
    });

    test('普通消息不能覆盖权限请求（时间更早时）', () {
      final cached = _makeMessage(
        'msg-perm',
        '权限请求中',
        'permission',
        createdAt: DateTime.now(),
      );
      final normalMsg = _makeMessage(
        'msg-normal',
        '普通消息',
        'text',
        createdAt: DateTime.now().subtract(Duration(minutes: 1)),
      );

      expect(shouldUpdateCache(cached, normalMsg), isFalse);
    });

    test('普通消息可以覆盖权限请求（时间更新时，代表权限已处理）', () {
      final cached = _makeMessage(
        'msg-perm',
        '权限请求中',
        'permission',
        createdAt: DateTime.now().subtract(Duration(minutes: 1)),
      );
      final normalMsg = _makeMessage(
        'msg-normal',
        '权限已处理后的回复',
        'text',
        createdAt: DateTime.now().add(Duration(seconds: 30)),
      );

      expect(shouldUpdateCache(cached, normalMsg), isTrue);
    });

    test('正常消息按时间比较更新', () {
      final cached = _makeMessage(
        'msg-old',
        '旧消息',
        'text',
        createdAt: DateTime.now().subtract(Duration(minutes: 1)),
      );
      final newerMsg = _makeMessage(
        'msg-new',
        '新消息',
        'text',
        createdAt: DateTime.now().add(Duration(minutes: 1)),
      );
      final olderMsg = _makeMessage(
        'msg-older',
        '更旧消息',
        'text',
        createdAt: DateTime.now().subtract(Duration(minutes: 5)),
      );

      expect(shouldUpdateCache(cached, newerMsg), isTrue);
      expect(shouldUpdateCache(cached, olderMsg), isFalse);
    });
  });

  // ====== Group 4: 恢复最新消息缓存测试（模拟 restoreUnreadStatus 行为） ======
  group('需求2&5: 恢复/清除最新消息缓存的 Hub 事件集成', () {
    late AgentNotificationHub hub;

    setUp(() {
      hub = AgentNotificationHub();
    });

    tearDown(() {
      hub.dispose();
    });

    test('恢复最新消息缓存时广播正确的未读计数', () async {
      const employeeId = 'emp-001';
      const fromDeviceId = 'device-001';

      final events = <AgentNotificationEvent>[];

      // 先恢复未读计数
      hub.restoreUnreadCount(employeeId: employeeId, count: 5);

      // 再恢复最新消息缓存
      hub.stream(employeeId: employeeId).listen(events.add);
      hub.onLatestMessageUpdated(
        message: AgentMessage(
          id: 'msg-1',
          role: 'assistant',
          type: 'text',
          content: '恢复的最新消息',
          createdAt: DateTime.now(),
          status: 'completed',
        ),
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        unreadCount: hub.getUnreadCount(employeeId: employeeId),
      );

      await Future.delayed(Duration.zero);

      final latestEvents =
          events.whereType<AgentLatestMessageUpdatedEvent>().toList();
      expect(latestEvents, hasLength(1));
      expect(latestEvents.first.unreadCount, equals(5));
    });

    test('清除缓存后 UI 收到 ClearedEvent，后续更新可正常收到 UpdatedEvent',
        () async {
      const employeeId = 'emp-001';
      const fromDeviceId = 'device-001';

      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: employeeId).listen(events.add);

      // 1. 先有最新消息
      hub.onLatestMessageUpdated(
        message: AgentMessage(
          id: 'msg-1',
          role: 'assistant',
          type: 'text',
          content: '消息A',
          createdAt: DateTime.now(),
          status: 'completed',
        ),
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        unreadCount: 1,
      );

      // 2. 清空消息
      hub.onLatestMessageCleared(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
      );

      // 3. 收到新消息
      hub.onLatestMessageUpdated(
        message: AgentMessage(
          id: 'msg-2',
          role: 'assistant',
          type: 'text',
          content: '消息B',
          createdAt: DateTime.now().add(Duration(seconds: 1)),
          status: 'completed',
        ),
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        unreadCount: 1,
      );

      await Future.delayed(Duration.zero);

      // 预期：Updated → Cleared → Updated
      expect(events, hasLength(3));
      expect(events[0], isA<AgentLatestMessageUpdatedEvent>());
      expect(events[1], isA<AgentLatestMessageClearedEvent>());
      expect(events[2], isA<AgentLatestMessageUpdatedEvent>());

      final lastUpdated = events[2] as AgentLatestMessageUpdatedEvent;
      expect(lastUpdated.latestMessage.id, equals('msg-2'));
    });

    test('多个设备清空时各自发送 ClearedEvent', () async {
      const employeeId = 'emp-001';

      final events = <AgentNotificationEvent>[];
      hub.stream(employeeId: employeeId).listen(events.add);

      // 模拟有两个设备的缓存条目被清除
      hub.onLatestMessageCleared(
        employeeId: employeeId,
        fromDeviceId: 'device-A',
      );
      hub.onLatestMessageCleared(
        employeeId: employeeId,
        fromDeviceId: 'device-B',
      );

      await Future.delayed(Duration.zero);

      final clearedEvents =
          events.whereType<AgentLatestMessageClearedEvent>().toList();
      expect(clearedEvents, hasLength(2));
      final deviceIds =
          clearedEvents.map((e) => e.fromDeviceId).toSet();
      expect(deviceIds, containsAll(['device-A', 'device-B']));
    });
  });
}
