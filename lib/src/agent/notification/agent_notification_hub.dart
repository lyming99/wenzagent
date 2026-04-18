import 'dart:async';

import '../entity/agent_message.dart';
import 'agent_notification_event.dart';

/// 订阅令牌（管理生命周期）
class AgentNotificationSubscription {
  final StreamSubscription<AgentNotificationEvent> _sub;

  AgentNotificationSubscription(this._sub);

  void pause() => _sub.pause();
  void resume() => _sub.resume();
  void cancel() => _sub.cancel();
}

/// Agent 消息通知中心（观察者模式核心）
///
/// 职责：
/// 1. 接收来自设备通信层的 Agent 返回消息
/// 2. 第一时间标记为未读
/// 3. 广播给所有订阅者（Stream）
/// 4. 提供标记已读的能力
class AgentNotificationHub {
  /// 事件广播流控制器
  final StreamController<AgentNotificationEvent> _controller =
      StreamController<AgentNotificationEvent>.broadcast();

  /// 未读消息索引：employeeId -> { messageId -> event }
  final Map<String, Map<String, AgentMessageArrivedEvent>> _unreadMessages = {};

  /// 未读计数：employeeId -> count
  final Map<String, int> _unreadCount = {};

  /// 按来源设备的未读计数：employeeId:fromDeviceId -> count
  final Map<String, int> _unreadCountByDevice = {};

  /// 已处理的消息 ID 集合（避免重复通知，使用 Queue 实现 LRU 驱逐）
  final Set<String> _processedMessageIds = {};

  /// 已处理消息的插入顺序（用于 LRU 驱逐）
  final List<String> _processedIdOrder = [];

  /// 最大缓存已处理消息 ID 数量（防止内存泄漏）
  static const int _maxProcessedIds = 10000;

  bool _isDisposed = false;

  // ============================================================
  // 对外暴露的订阅流
  // ============================================================

  /// 获取通知事件流
  ///
  /// [employeeId] 可选，只接收特定员工的通知
  /// [fromDeviceId] 可选，只接收来自特定设备的通知
  Stream<AgentNotificationEvent> stream({
    String? employeeId,
    String? fromDeviceId,
  }) {
    return _controller.stream.where((event) {
      if (employeeId != null) {
        switch (event) {
          case AgentMessageArrivedEvent e:
            if (e.employeeId != employeeId) return false;
          case AgentMessageReadStatusChangedEvent e:
            if (e.employeeId != employeeId) return false;
          case AgentUnreadCountChangedEvent e:
            if (e.employeeId != employeeId) return false;
          case AgentLatestMessageUpdatedEvent e:
            if (e.employeeId != employeeId) return false;
          case AgentLatestMessageClearedEvent e:
            if (e.employeeId != employeeId) return false;
          case AgentStatusNotifyEvent e:
            if (e.employeeId != employeeId) return false;
        }
      }

      if (fromDeviceId != null) {
        switch (event) {
          case AgentMessageArrivedEvent e:
            if (e.fromDeviceId != fromDeviceId) return false;
          case AgentUnreadCountChangedEvent e:
            if (e.fromDeviceId != fromDeviceId) return false;
          case AgentLatestMessageUpdatedEvent e:
            if (e.fromDeviceId != fromDeviceId) return false;
          case AgentLatestMessageClearedEvent e:
            if (e.fromDeviceId != fromDeviceId) return false;
          case AgentStatusNotifyEvent e:
            if (e.fromDeviceId != fromDeviceId) return false;
          default:
            break;
        }
      }

      return true;
    });
  }

  /// 便捷方法：订阅所有通知
  AgentNotificationSubscription subscribe(
    void Function(AgentNotificationEvent) onEvent, {
    String? employeeId,
    String? fromDeviceId,
  }) {
    final sub = stream(
      employeeId: employeeId,
      fromDeviceId: fromDeviceId,
    ).listen(onEvent);
    return AgentNotificationSubscription(sub);
  }

  /// 便捷方法：只订阅消息到达事件
  AgentNotificationSubscription subscribeMessages(
    void Function(AgentMessageArrivedEvent) onMessage, {
    String? employeeId,
    String? fromDeviceId,
  }) {
    final sub = stream(
      employeeId: employeeId,
      fromDeviceId: fromDeviceId,
    ).where((e) => e is AgentMessageArrivedEvent).cast<AgentMessageArrivedEvent>().listen(onMessage);
    return AgentNotificationSubscription(sub);
  }

  /// 便捷方法：只订阅未读计数变更
  AgentNotificationSubscription subscribeUnreadCount(
    void Function(AgentUnreadCountChangedEvent) onCount, {
    String? employeeId,
  }) {
    final sub = stream(employeeId: employeeId)
        .where((e) => e is AgentUnreadCountChangedEvent).cast<AgentUnreadCountChangedEvent>()
        .listen(onCount);
    return AgentNotificationSubscription(sub);
  }

  // ============================================================
  // 消息入站（被 DeviceClientImpl 调用）
  // ============================================================

  /// 接收远程 Agent 返回消息
  ///
  /// 始终标记为未读，由 ChatControllerBase 监听消息到达后对当前打开的会话标记已读。
  ///
  /// 由 DeviceClientImpl 在以下时机调用：
  /// 1. 收到 LAN 广播的 agentMessageStatusChanged（status=completed）
  /// 2. CachedAgentProxy 同步到新的未接收消息时
  void onRemoteMessage({
    required AgentMessage message,
    required String fromDeviceId,
    required String toDeviceId,
    required String employeeId,
  }) {
    if (_isDisposed) return;

    // 去重
    if (_processedMessageIds.contains(message.id)) return;
    _addProcessedId(message.id);

    // 始终标记为未读
    _markUnread(employeeId, message.id, fromDeviceId, message);

    // 广播消息到达事件
    _controller.add(AgentMessageArrivedEvent(
      message: message,
      fromDeviceId: fromDeviceId,
      toDeviceId: toDeviceId,
      employeeId: employeeId,
      isRemote: true,
    ));
  }

  /// 接收本地 Agent 返回消息
  ///
  /// [markUnread] 是否标记未读，默认 false（本地消息默认不增加未读计数）
  void onLocalMessage({
    required AgentMessage message,
    required String employeeId,
    String? fromDeviceId,
    bool markUnread = false,
  }) {
    if (_isDisposed) return;

    if (_processedMessageIds.contains(message.id)) return;
    _addProcessedId(message.id);

    if (markUnread) {
      _markUnread(employeeId, message.id, fromDeviceId, message);
    }

    _controller.add(AgentMessageArrivedEvent(
      message: message,
      fromDeviceId: message.metadata?['deviceId'] ?? '',
      toDeviceId: message.metadata?['deviceId'] ?? '',
      employeeId: employeeId,
      isRemote: false,
    ));
  }

  /// 通知最新消息缓存更新
  ///
  /// 由 DeviceClientImpl 在更新内存最新消息缓存后调用，
  /// 携带最新消息和未读数量，UI 可直接用于刷新会话列表。
  void onLatestMessageUpdated({
    required AgentMessage message,
    required String employeeId,
    required String fromDeviceId,
    required int unreadCount,
  }) {
    if (_isDisposed) return;

    _controller.add(AgentLatestMessageUpdatedEvent(
      latestMessage: message,
      employeeId: employeeId,
      fromDeviceId: fromDeviceId,
      unreadCount: unreadCount,
    ));
  }

  /// 通知最新消息缓存已清除
  ///
  /// 由 DeviceClientImpl 在清空消息后调用，
  /// UI 应清除该会话的最新消息预览。
  void onLatestMessageCleared({
    required String employeeId,
    required String fromDeviceId,
  }) {
    if (_isDisposed) return;

    _controller.add(AgentLatestMessageClearedEvent(
      employeeId: employeeId,
      fromDeviceId: fromDeviceId,
    ));
  }

  /// 通知 Agent 状态变更（轻量级，不包含完整消息）
  void onAgentStatusChanged({
    required String employeeId,
    required String fromDeviceId,
    required String status,
    Map<String, dynamic>? extra,
  }) {
    if (_isDisposed) return;

    _controller.add(AgentStatusNotifyEvent(
      employeeId: employeeId,
      fromDeviceId: fromDeviceId,
      status: status,
      extra: extra,
    ));
  }

  // ============================================================
  // 标记已读（核心能力）
  // ============================================================

  /// 标记单条消息为已读
  ///
  /// 返回 true 表示状态实际发生了变更
  bool markAsRead({
    required String messageId,
    required String employeeId,
  }) {
    final unreadMap = _unreadMessages[employeeId];
    if (unreadMap == null || !unreadMap.containsKey(messageId)) return false;

    final event = unreadMap.remove(messageId)!;
    _decrementUnreadCount(employeeId, event.fromDeviceId);

    // 广播状态变更
    _controller.add(AgentMessageReadStatusChangedEvent(
      messageId: messageId,
      employeeId: employeeId,
      isRead: true,
      fromDeviceId: event.fromDeviceId,
    ));

    return true;
  }

  /// 标记来自指定设备的所有消息为已读
  ///
  /// [fromDeviceId] 来源设备 ID，为 null 则标记该员工所有设备的未读消息
  /// 改为发送一次聚合事件，而非逐条发送 AgentMessageReadStatusChangedEvent
  void markAllAsRead({
    required String employeeId,
    String? fromDeviceId,
  }) {
    final unreadMap = _unreadMessages[employeeId];

    if (unreadMap != null && unreadMap.isNotEmpty) {
      final idsToRemove = <String>[];
      for (final entry in unreadMap.entries) {
        if (fromDeviceId == null || entry.value.fromDeviceId == fromDeviceId) {
          idsToRemove.add(entry.key);
        }
      }

      for (final id in idsToRemove) {
        unreadMap.remove(id);
      }
    }

    // 始终重新计算未读计数（覆盖从 DB 恢复但未跟踪消息的场景）
    _recalculateUnreadCount(employeeId);
    if (fromDeviceId != null) {
      _recalculateUnreadCountByDevice(employeeId, fromDeviceId);
    }
  }

  /// 从数据库恢复未读计数（用于 App 重启后恢复状态）
  ///
  /// 当 App 重启时，内存中的 [_unreadMessages] 为空，
  /// 但数据库中记录了哪些消息尚未已读。
  /// 通过此方法直接设置未读计数，无需重建完整的消息事件。
  void restoreUnreadCount({
    required String employeeId,
    required int count,
    String? fromDeviceId,
  }) {
    _unreadCount[employeeId] = count;
    _controller.add(AgentUnreadCountChangedEvent(
      employeeId: employeeId,
      unreadCount: count,
    ));

    if (fromDeviceId != null && fromDeviceId.isNotEmpty) {
      final key = '$employeeId:$fromDeviceId';
      _unreadCountByDevice[key] = count;
      _controller.add(AgentUnreadCountChangedEvent(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        unreadCount: count,
      ));
    }
  }

  /// 从数据库恢复未读消息映射（用于 App 重启后建立 messageId → isRead 内存表）
  ///
  /// 此方法将未读的 assistant 消息逐一加入 [_unreadMessages]，
  /// 使得 [isMessageRead] 在重启后仍能正确判断单条消息的已读状态。
  ///
  /// [employeeId] 员工ID
  /// [unreadMessages] 未读消息列表，每项包含 messageId、fromDeviceId 和 message
  void restoreUnreadMessages({
    required String employeeId,
    required List<({String messageId, String fromDeviceId, AgentMessage message})> unreadMessages,
  }) {
    _unreadMessages.putIfAbsent(employeeId, () => {});

    for (final item in unreadMessages) {
      final event = AgentMessageArrivedEvent(
        message: item.message,
        fromDeviceId: item.fromDeviceId,
        toDeviceId: '',
        employeeId: employeeId,
        isRemote: true,
      );
      _unreadMessages[employeeId]![item.messageId] = event;

      // 标记为已处理，避免后续重复通知
      _addProcessedId(item.messageId);
    }

    // 重新计算未读计数（确保与 _unreadMessages 一致）
    _recalculateUnreadCount(employeeId);
  }

  /// 标记所有员工的所有消息为已读
  void markAllAsReadGlobal() {
    for (final employeeId in _unreadMessages.keys.toList()) {
      markAllAsRead(employeeId: employeeId);
    }
  }

  /// 用 DB 统计值修正内存未读计数
  ///
  /// 与 [restoreUnreadCount] 不同，此方法仅在内存中没有精确追踪时才覆盖。
  /// 如果内存中已有精确的未读消息映射（_unreadMessages 非空），
  /// 说明内存追踪更精确，跳过覆盖以避免远程旧值覆盖本地精确值。
  ///
  /// 适用场景：
  /// - 已读标记后用 DB 统计修正内存缓存
  /// - 远程摘要同步后修正本地计数
  void adjustUnreadCountFromDb({
    required String employeeId,
    required int count,
  }) {
    // 如果内存中有精确追踪的未读消息，以内存为准
    final trackedCount = _unreadMessages[employeeId]?.length ?? 0;
    if (trackedCount > 0) {
      return;
    }
    // 内存无追踪数据时，使用 DB 值恢复
    restoreUnreadCount(employeeId: employeeId, count: count);
  }

  // ============================================================
  // 查询方法
  // ============================================================

  /// 获取指定员工的未读消息列表
  List<AgentMessageArrivedEvent> getUnreadMessages({
    required String employeeId,
    String? fromDeviceId,
  }) {
    final unreadMap = _unreadMessages[employeeId];
    if (unreadMap == null) return [];

    var events = unreadMap.values.toList();
    if (fromDeviceId != null) {
      events = events.where((e) => e.fromDeviceId == fromDeviceId).toList();
    }
    return events;
  }

  /// 获取指定员工的未读数量
  int getUnreadCount({required String employeeId, String? fromDeviceId}) {
    if (fromDeviceId != null) {
      return _unreadCountByDevice['$employeeId:$fromDeviceId'] ?? 0;
    }
    return _unreadCount[employeeId] ?? 0;
  }

  /// 获取所有员工的未读总数
  int getTotalUnreadCount() {
    return _unreadCount.values.fold(0, (sum, count) => sum + count);
  }

  /// 获取有未读消息的员工ID列表
  Set<String> get unreadEmployeeIds =>
      _unreadMessages.keys.where((id) => _unreadMessages[id]!.isNotEmpty).toSet();

  /// 检查指定消息是否已读
  bool isMessageRead({
    required String messageId,
    required String employeeId,
  }) {
    return !(_unreadMessages[employeeId]?.containsKey(messageId) ?? false);
  }

  // ============================================================
  // 内部方法
  // ============================================================

  void _markUnread(
    String employeeId,
    String messageId,
    String? fromDeviceId,
    AgentMessage message,
  ) {
    _unreadMessages.putIfAbsent(employeeId, () => {});

    final event = AgentMessageArrivedEvent(
      message: message,
      fromDeviceId: fromDeviceId ?? '',
      toDeviceId: '',
      employeeId: employeeId,
      isRemote: true,
    );
    _unreadMessages[employeeId]![messageId] = event;

    _incrementUnreadCount(employeeId, fromDeviceId);
  }

  void _incrementUnreadCount(String employeeId, String? fromDeviceId) {
    // 总计数
    _unreadCount[employeeId] = (_unreadCount[employeeId] ?? 0) + 1;
    _controller.add(AgentUnreadCountChangedEvent(
      employeeId: employeeId,
      unreadCount: _unreadCount[employeeId]!,
    ));

    // 按设备计数
    if (fromDeviceId != null && fromDeviceId.isNotEmpty) {
      final key = '$employeeId:$fromDeviceId';
      _unreadCountByDevice[key] = (_unreadCountByDevice[key] ?? 0) + 1;
      _controller.add(AgentUnreadCountChangedEvent(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        unreadCount: _unreadCountByDevice[key]!,
      ));
    }
  }

  void _decrementUnreadCount(String employeeId, String? fromDeviceId) {
    _unreadCount[employeeId] = (_unreadCount[employeeId] ?? 1) - 1;
    if (_unreadCount[employeeId]! < 0) _unreadCount[employeeId] = 0;
    _controller.add(AgentUnreadCountChangedEvent(
      employeeId: employeeId,
      unreadCount: _unreadCount[employeeId]!,
    ));

    if (fromDeviceId != null && fromDeviceId.isNotEmpty) {
      final key = '$employeeId:$fromDeviceId';
      _unreadCountByDevice[key] = (_unreadCountByDevice[key] ?? 1) - 1;
      if (_unreadCountByDevice[key]! < 0) _unreadCountByDevice[key] = 0;
      _controller.add(AgentUnreadCountChangedEvent(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        unreadCount: _unreadCountByDevice[key]!,
      ));
    }
  }

  void _recalculateUnreadCount(String employeeId) {
    final count = _unreadMessages[employeeId]?.length ?? 0;
    _unreadCount[employeeId] = count;
    _controller.add(AgentUnreadCountChangedEvent(
      employeeId: employeeId,
      unreadCount: count,
    ));
  }

  void _recalculateUnreadCountByDevice(String employeeId, String fromDeviceId) {
    final key = '$employeeId:$fromDeviceId';
    final count = _unreadMessages[employeeId]
            ?.values
            .where((e) => e.fromDeviceId == fromDeviceId)
            .length ??
        0;
    _unreadCountByDevice[key] = count;
    _controller.add(AgentUnreadCountChangedEvent(
      employeeId: employeeId,
      fromDeviceId: fromDeviceId,
      unreadCount: count,
    ));
  }

  void _addProcessedId(String messageId) {
    if (_processedMessageIds.contains(messageId)) return;
    _processedMessageIds.add(messageId);
    _processedIdOrder.add(messageId);
    // LRU 驱逐：超过上限时移除最早的一半，而非全部清空
    if (_processedMessageIds.length > _maxProcessedIds) {
      final removeCount = _maxProcessedIds ~/ 2;
      for (int i = 0; i < removeCount; i++) {
        _processedMessageIds.remove(_processedIdOrder[i]);
      }
      _processedIdOrder.removeRange(0, removeCount);
    }
  }

  // ============================================================
  // 生命周期
  // ============================================================

  /// 释放资源
  void dispose() {
    _isDisposed = true;
    _controller.close();
    _unreadMessages.clear();
    _unreadCount.clear();
    _unreadCountByDevice.clear();
    _processedMessageIds.clear();
    _processedIdOrder.clear();
  }
}
