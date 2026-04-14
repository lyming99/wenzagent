import '../../agent/entity/agent_message.dart';
import '../../agent/notification/agent_notification_hub.dart';
import '../../entity/lan_message.dart';
import '../../shared/shared.dart';
import '../../service/service.dart';
import '../device_client.dart';
import 'device_connection_manager.dart';
import 'device_agent_manager.dart';
import 'device_state_holder.dart';

/// 通知与已读管理器
///
/// 负责未读消息计数、已读状态管理、最新消息缓存等。
class DeviceNotificationManager {
  final String _deviceId;
  String? _topic;
  late final EmployeeManager _employeeManager = EmployeeManager.getInstance(_deviceId);
  late final SessionManager _sessionManager = SessionManager.getInstance(_deviceId);
  late final MessageStoreService _messageStoreService = MessageStoreService.getInstance(_deviceId);
  late final DeviceConnectionManager _connectionManager = DeviceConnectionManager.getInstance(_deviceId);
  late final DeviceStateHolder _stateHolder = DeviceStateHolder.getInstance(_deviceId);
  late final DeviceAgentManager _agentManager = DeviceAgentManager.getInstance(_deviceId);

  /// 当前打开的会话状态
  OpenSessionState? _currentOpenSession;

  /// 最新消息内存缓存（key = '$employeeId:$deviceId'）
  final Map<String, AgentMessage> _latestMessageCache = {};

  DeviceNotificationManager._({required String deviceId, String? topic})
      : _deviceId = deviceId,
        _topic = topic;

  // ===== 单例管理 =====

  static final Map<String, DeviceNotificationManager> _instances = {};

  static DeviceNotificationManager getInstance(String deviceId) {
    return _instances.putIfAbsent(
      deviceId,
      () => DeviceNotificationManager._(deviceId: deviceId),
    );
  }

  /// 初始化配置
  void initialize({String? topic}) {
    updateConfig(topic: topic);
  }

  static void removeInstance(String deviceId) {
    _instances.remove(deviceId);
  }

  // ===== 配置 =====

  void updateConfig({String? topic}) {
    if (topic != null) _topic = topic;
  }

  /// 设置 AgentNotificationHub 的 shouldAutoMarkAsRead 回调
  /// 必须在 getInstance 后调用一次
  void initNotificationHubCallback() {
    _stateHolder.notificationHub.shouldAutoMarkAsReadCallback =
        ({required String employeeId, String? fromDeviceId}) =>
            shouldAutoMarkAsRead(
              employeeId: employeeId,
              fromDeviceId: fromDeviceId,
            );
  }

  // ===== 公开访问 =====

  OpenSessionState? get currentOpenSession => _currentOpenSession;

  AgentNotificationHub get notificationHub => _stateHolder.notificationHub;

  int getUnreadCount({required String employeeId, String? fromDeviceId}) {
    return _stateHolder.notificationHub.getUnreadCount(
      employeeId: employeeId,
      fromDeviceId: fromDeviceId,
    );
  }

  int getTotalUnreadCount() => _stateHolder.notificationHub.getTotalUnreadCount();

  bool isSessionOpen({required String employeeId, String? fromDeviceId}) {
    final session = _currentOpenSession;
    if (session == null) return false;
    if (session.employeeId != employeeId) return false;
    if (fromDeviceId != null && session.fromDeviceId != fromDeviceId) return false;
    return true;
  }

  bool shouldAutoMarkAsRead({required String employeeId, String? fromDeviceId}) {
    return isSessionOpen(employeeId: employeeId, fromDeviceId: fromDeviceId);
  }

  AgentMessage? getCachedLatestMessage({
    required String employeeId,
    required String deviceId,
  }) {
    return _latestMessageCache['$employeeId:$deviceId'];
  }

  // ===== 会话打开状态 =====

  Future<void> setCurrentOpenSession({required String employeeId, String? fromDeviceId}) async {
    _currentOpenSession = OpenSessionState(employeeId: employeeId, fromDeviceId: fromDeviceId);
    markAllMessagesAsRead(employeeId: employeeId, fromDeviceId: fromDeviceId);
  }

  void clearCurrentOpenSession() {
    _currentOpenSession = null;
  }

  // ===== 已读管理 =====

  void markAllMessagesAsRead({required String employeeId, String? fromDeviceId}) {
    _stateHolder.notificationHub.markAllAsRead(employeeId: employeeId, fromDeviceId: fromDeviceId);
    _broadcastReadStatus(employeeId: employeeId, fromDeviceId: fromDeviceId);
    // DB 更新后用 SQL 统计修正内存缓存
    markMessagesAsReadInDb(employeeId, fromDeviceId).then((dbUnreadCount) {
      if (dbUnreadCount >= 0) {
        _stateHolder.notificationHub.restoreUnreadCount(
          employeeId: employeeId,
          count: dbUnreadCount,
        );
      }
    });
    _notifyAgentReadStatus(employeeId: employeeId, fromDeviceId: fromDeviceId);
  }

  void markAllMessagesAsReadGlobal() {
    _stateHolder.notificationHub.markAllAsReadGlobal();
    _broadcastReadStatusGlobal();
    _markAllMessagesAsReadInDbGlobal();
  }

  Future<void> syncReadStatusFromAgent({required String employeeId}) async {
    final proxy = _agentManager.getAgentProxy(employeeId);
    if (proxy == null) return;

    try {
      final result = await proxy.getMessagesReadStatus(deviceId: _deviceId);
      final readStatus = result.readStatus;

      for (final entry in readStatus.entries) {
        final messageId = entry.key;
        final isRead = entry.value;
        if (isRead) {
          _messageStoreService.getMessage(_deviceId, messageId).then((message) {
            if (message != null && !message.isRead) {
              _messageStoreService.updateMessage(
                _deviceId, message.copyWith(isRead: true),
              );
            }
          }).catchError((_) {});
        }
      }

      final hasRead = readStatus.values.any((v) => v == true);
      if (hasRead) {
        _stateHolder.notificationHub.markAllAsRead(employeeId: employeeId);
      }
    } catch (_) {}
  }

  Future<void> restoreUnreadStatus() async {
    try {
      final sessions = await _sessionManager.getAllSessions();
      final allEmployees = await _employeeManager.getEmployees();

      final employeeMap = <String, dynamic>{};
      for (final emp in allEmployees) {
        employeeMap[emp.uuid] = emp;
      }

      for (final session in sessions) {
        final employeeId = session.employeeId;
        final messages = await _messageStoreService.getMessages(_deviceId, employeeId);
        final unreadMessages = messages
            .where((m) => m.role == MessageRole.assistant && !m.isRead)
            .toList();
        final unreadCount = unreadMessages.length;

        if (unreadCount > 0) {
          // 恢复未读计数（兼容旧逻辑）
          _stateHolder.notificationHub.restoreUnreadCount(
            employeeId: employeeId,
            count: unreadCount,
          );

          // 建立 messageId → isRead 内存映射
          final employee = employeeMap[employeeId];
          final String messageDeviceId = (employee?.currentDeviceId != null &&
                  employee!.currentDeviceId!.isNotEmpty)
              ? employee.currentDeviceId! as String
              : _deviceId;

          final unreadItems = unreadMessages.map((entity) {
            final msgMap = entity.toJson();
            final msg = AgentMessage.fromMap(msgMap);
            return (
              messageId: entity.id,
              fromDeviceId: messageDeviceId,
              message: msg,
            );
          }).toList();

          _stateHolder.notificationHub.restoreUnreadMessages(
            employeeId: employeeId,
            unreadMessages: unreadItems,
          );
        }

        if (messages.isNotEmpty) {
          final employee = employeeMap[employeeId];
          final rawDeviceId = (employee?.currentDeviceId != null &&
                  employee!.currentDeviceId!.isNotEmpty)
              ? employee.currentDeviceId!
              : _deviceId;
          final messageDeviceId = rawDeviceId;

          final latestEntity = messages.last;
          final latestMap = latestEntity.toJson();
          final latestMsg = AgentMessage.fromMap(latestMap);

          final key = '$employeeId:$messageDeviceId';
          _latestMessageCache[key] = latestMsg;

          _stateHolder.notificationHub.onLatestMessageUpdated(
            message: latestMsg,
            employeeId: employeeId,
            fromDeviceId: messageDeviceId,
            unreadCount: _stateHolder.notificationHub.getUnreadCount(employeeId: employeeId),
          );
        }
      }
    } catch (_) {}
  }

  Future<List<ChatMessage>> getLatestMessages({
    required String employeeId,
    required String deviceId,
    int limit = 2,
  }) {
    return _messageStoreService.getMessagesWithDeviceId(
      deviceId,
      employeeId,
      limit: limit,
    );
  }

  // ===== 消息缓存 =====

  void updateLatestMessageCache(
    String employeeId,
    String fromDeviceId,
    AgentMessage message,
  ) {
    final key = '$employeeId:$fromDeviceId';
    final cached = _latestMessageCache[key];

    final shouldUpdate = cached == null ||
        message.type == 'permission' ||
        message.createdAt.isAfter(cached.createdAt);

    if (shouldUpdate) {
      _latestMessageCache[key] = message;

      final unreadCount = _stateHolder.notificationHub.getUnreadCount(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId.isNotEmpty ? fromDeviceId : null,
      );
      _stateHolder.notificationHub.onLatestMessageUpdated(
        message: message,
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        unreadCount: unreadCount,
      );
    }
  }

  void clearLatestMessageCache(String employeeId) {
    final keysToRemove = _latestMessageCache.keys
        .where((key) => key.startsWith('$employeeId:'))
        .toList();

    for (final key in keysToRemove) {
      _latestMessageCache.remove(key);
      final fromDeviceId = key.substring('$employeeId:'.length);
      _stateHolder.notificationHub.onLatestMessageCleared(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
      );
    }
  }

  // ===== 已读状态数据库操作 =====

  /// 在数据库中标记已读，并返回 DB SQL 统计的未读数量
  ///
  /// 返回值为 DB 中该员工剩余的未读消息数量，调用方可用其修正内存缓存。
  Future<int> markMessagesAsReadInDb(String employeeId, String? fromDeviceId) async {
    try {
      _messageStoreService.markAsReadInDb(_deviceId, employeeId);
      // 从 DB SQL 统计未读数量
      return _messageStoreService.getUnreadCount(_deviceId, employeeId);
    } catch (_) {
      return -1;
    }
  }

  void _markAllMessagesAsReadInDbGlobal() {
    final employeeIds = _stateHolder.notificationHub.unreadEmployeeIds;
    for (final employeeId in employeeIds) {
      markMessagesAsReadInDb(employeeId, null).then((dbUnreadCount) {
        if (dbUnreadCount >= 0) {
          _stateHolder.notificationHub.restoreUnreadCount(
            employeeId: employeeId,
            count: dbUnreadCount,
          );
        }
      });
    }
  }

  // ===== 广播已读状态 =====

  void _broadcastReadStatus({
    required String employeeId,
    String? fromDeviceId,
  }) {
    final lanClient = _connectionManager.lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    final msg = LanMessage(
      type: LanMessageType.agentMessageReadStatus,
      fromId: _deviceId,
      content: '{"employeeId":"$employeeId","fromDeviceId":"$fromDeviceId","readerDeviceId":"$_deviceId"}',
      topic: _topic,
    );

    lanClient.sendLanMessage(msg);
  }

  void _broadcastReadStatusGlobal() {
    final lanClient = _connectionManager.lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    final msg = LanMessage(
      type: LanMessageType.agentMessageReadStatus,
      fromId: _deviceId,
      content: '{"global":true,"readerDeviceId":"$_deviceId"}',
      topic: _topic,
    );

    lanClient.sendLanMessage(msg);
  }

  void _notifyAgentReadStatus({required String employeeId, String? fromDeviceId}) {
    final agent = _agentManager.getLocalAgent(employeeId);
    if (agent == null) return;
    agent.markMessagesAsRead(
      readerDeviceId: _deviceId,
      employeeId: employeeId,
    ).catchError((_) {});
  }
}
