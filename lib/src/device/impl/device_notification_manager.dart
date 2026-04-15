import 'dart:convert';

import '../../agent/entity/agent_message.dart';
import '../../agent/notification/agent_notification_hub.dart';
import '../../entity/lan_message.dart';
import '../../persistence/persistence.dart';
import '../../service/service.dart';
import '../../utils/logger.dart';
import '../app_context.dart';
import '../device_client.dart';
import 'device_connection_manager.dart';
import 'device_agent_manager.dart';
import 'device_state_holder.dart';

/// 通知与已读管理器
///
/// 负责未读消息计数、已读状态管理、最新消息缓存等。
class DeviceNotificationManager {
  static final _log = Logger('DeviceNotificationManager');

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

  /// 从 [AppContext] 获取实例，不存在则回退到独立创建
  static DeviceNotificationManager getInstance(String deviceId) {
    final ctx = AppContext.get(deviceId);
    if (ctx != null) return ctx.notificationManager;
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
    // 1. 先写 DB（messages + summary），确保广播时数据已是最新
    _messageStoreService.markAsReadInDb(_deviceId, employeeId);
    // 2. 更新内存层
    _stateHolder.notificationHub.markAllAsRead(employeeId: employeeId, fromDeviceId: fromDeviceId);
    // 3. 广播到远程设备（携带已读后的最新摘要）
    _broadcastReadStatus(employeeId: employeeId, fromDeviceId: fromDeviceId);
    // 4. 通知 agent 层
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
          }).catchError((e) {
            _log.debug('getMessage/updateMessage failed: $e');
          });
        }
      }

      final hasRead = readStatus.values.any((v) => v == true);
      if (hasRead) {
        _stateHolder.notificationHub.markAllAsRead(employeeId: employeeId);
      }
    } catch (e) {
      _log.debug('syncReadStatusFromAgent failed: $e');
    }
  }

  Future<void> restoreUnreadStatus() async {
    try {
      final summaryStore = SessionSummaryStore(deviceId: _deviceId);
      // 一次查询获取所有摘要（O(S)，S = 会话数）
      final summaries = summaryStore.getAllSummaries(deviceId: _deviceId);

      for (final summary in summaries) {
        // 恢复未读计数（O(1) per session，直接从摘要表读取）
        if (summary.unreadCount > 0) {
          _stateHolder.notificationHub.restoreUnreadCount(
            employeeId: summary.employeeId,
            count: summary.unreadCount,
            fromDeviceId: summary.deviceId.isNotEmpty ? summary.deviceId : null,
          );
        }

        // 恢复最新消息预览（O(1)，无需查 messages 表）
        if (summary.hasLatestMessage) {
          final agentMsg = summaryToAgentMessage(summary);
          final key = '${summary.employeeId}:${summary.deviceId}';
          _latestMessageCache[key] = agentMsg;

          _stateHolder.notificationHub.onLatestMessageUpdated(
            message: agentMsg,
            employeeId: summary.employeeId,
            fromDeviceId: summary.deviceId,
            unreadCount: summary.unreadCount,
          );
        }
      }
    } catch (e) {
      _log.debug('restoreUnreadStatus failed: $e');
    }
  }

  /// 将 SessionSummaryEntity 转换为 AgentMessage（用于最新消息预览）
  AgentMessage summaryToAgentMessage(SessionSummaryEntity summary) {
    return AgentMessage(
      id: summary.lastMsgId ?? '',
      role: summary.lastMsgRole ?? 'assistant',
      content: summary.lastMsgContent,
      createdAt: summary.lastMsgTime != null
          ? DateTime.fromMillisecondsSinceEpoch(summary.lastMsgTime!)
          : DateTime.now(),
      metadata: {
        'seq': summary.lastMsgSeq ?? 0,
        'deviceId': summary.deviceId,
      },
    );
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

  /// 在数据库中标记已读，并返回摘要表中剩余的未读数量
  ///
  /// 返回值为摘要表中该员工剩余的未读消息数量，调用方可用其修正内存缓存。
  Future<int> markMessagesAsReadInDb(String employeeId, String? fromDeviceId) async {
    try {
      _messageStoreService.markAsReadInDb(_deviceId, employeeId);
      // 从摘要表读取未读数量（O(1)）
      return _messageStoreService.getUnreadCount(_deviceId, employeeId);
    } catch (e) {
      _log.debug('markMessagesAsReadInDb failed: $e');
      return -1;
    }
  }

  void _markAllMessagesAsReadInDbGlobal() {
    final employeeIds = _stateHolder.notificationHub.unreadEmployeeIds;
    for (final employeeId in employeeIds) {
      _messageStoreService.markAsReadInDb(_deviceId, employeeId);
    }
  }

  // ===== 广播已读状态 =====

  void _broadcastReadStatus({
    required String employeeId,
    String? fromDeviceId,
  }) {
    final lanClient = _connectionManager.lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    // 发送完整摘要数据，使远程设备能正确更新 session summary
    final summary = _messageStoreService.getLatestMessageSummary(_deviceId, employeeId);

    final msg = LanMessage(
      type: LanMessageType.agentSessionSummaryChanged,
      fromId: _deviceId,
      content: jsonEncode({
        'employeeId': employeeId,
        'fromDeviceId': fromDeviceId,
        'readerDeviceId': _deviceId,
        'summary': summary?.toMap(),
      }),
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
    ).catchError((e) {
      _log.debug('notifyAgentReadStatus failed: $e');
    });
  }
}
