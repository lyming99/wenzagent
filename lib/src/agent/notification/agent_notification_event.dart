import '../entity/agent_message.dart';

/// 消息通知事件基类（sealed class 保证穷举匹配）
sealed class AgentNotificationEvent {
  AgentNotificationEvent();
}

/// 新消息到达（来自任何设备的 Agent 返回）
///
/// 当远程 Agent 生成 assistant 回复，或本地 Agent 完成处理时触发
/// 消息此时自动标记为未读
class AgentMessageArrivedEvent extends AgentNotificationEvent {
  /// 消息内容
  final AgentMessage message;

  /// 来源设备 ID
  final String fromDeviceId;

  /// 目标设备 ID（本机）
  final String toDeviceId;

  /// 员工 ID
  final String employeeId;

  /// 是否为远程消息（vs 本地 Agent 回复）
  final bool isRemote;

  /// 是否自动已读（当前会话窗口打开时的消息）
  final bool autoRead;

  AgentMessageArrivedEvent({
    required this.message,
    required this.fromDeviceId,
    required this.toDeviceId,
    required this.employeeId,
    required this.isRemote,
    this.autoRead = false,
  });
}

/// 消息已读状态变更
class AgentMessageReadStatusChangedEvent extends AgentNotificationEvent {
  final String messageId;
  final String employeeId;
  final bool isRead;
  final String? fromDeviceId;

  AgentMessageReadStatusChangedEvent({
    required this.messageId,
    required this.employeeId,
    required this.isRead,
    this.fromDeviceId,
  });
}

/// 未读计数变更（按员工维度）
class AgentUnreadCountChangedEvent extends AgentNotificationEvent {
  /// 员工 ID
  final String employeeId;

  /// 来源设备 ID（可空，表示跨设备合计）
  final String? fromDeviceId;

  /// 新的未读数量
  final int unreadCount;

  AgentUnreadCountChangedEvent({
    required this.employeeId,
    this.fromDeviceId,
    required this.unreadCount,
  });
}

/// 会话最新消息缓存更新（用于会话列表实时刷新）
///
/// 当 DeviceClient 检测到新消息并更新内存缓存后触发，
/// 携带该会话的最新消息和未读数量，UI 可直接用于刷新会话列表预览，
/// 无需额外调用 getLatestMessages() 查询数据库。
class AgentLatestMessageUpdatedEvent extends AgentNotificationEvent {
  /// 最新的消息
  final AgentMessage latestMessage;

  /// 员工 ID
  final String employeeId;

  /// 来源设备 ID
  final String fromDeviceId;

  /// 当前该会话的未读数量
  final int unreadCount;

  AgentLatestMessageUpdatedEvent({
    required this.latestMessage,
    required this.employeeId,
    required this.fromDeviceId,
    required this.unreadCount,
  });
}

/// 会话最新消息缓存清除（用于清空消息后通知 UI）
///
/// 当用户清空某个员工的所有消息时触发，
/// UI 应清除该会话的最新消息预览。
class AgentLatestMessageClearedEvent extends AgentNotificationEvent {
  /// 员工 ID
  final String employeeId;

  /// 来源设备 ID
  final String fromDeviceId;

  AgentLatestMessageClearedEvent({
    required this.employeeId,
    required this.fromDeviceId,
  });
}

/// Agent 状态变更通知（轻量版，用于 UI 提示）
class AgentStatusNotifyEvent extends AgentNotificationEvent {
  final String employeeId;
  final String fromDeviceId;
  final String status; // idle / processing / streaming / waitingPermission

  AgentStatusNotifyEvent({
    required this.employeeId,
    required this.fromDeviceId,
    required this.status,
  });
}
