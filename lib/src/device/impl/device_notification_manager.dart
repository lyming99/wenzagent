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
/// 负责未读消息计数、已读状态管理、最新消息缓存、pending 请求持久化等。
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
    markAllMessagesAsRead(employeeId: employeeId, targetDeviceId: fromDeviceId);
  }

  void clearCurrentOpenSession() {
    _currentOpenSession = null;
  }

  // ===== 已读管理 =====

  void markAllMessagesAsRead({required String employeeId, String? targetDeviceId}) {
    // 使用 targetDeviceId（消息所在设备）而非本机 _deviceId，确保远程会话也能正确更新 DB
    final deviceId = targetDeviceId ?? _deviceId;
    // 1. 先写 DB（messages + session_summary），确保广播时数据已是最新
    //    markAsReadInDb 内部已同步更新 session_summary.unread_count = 0
    _messageStoreService.markAsReadInDb(deviceId, employeeId);
    // 2. 更新内存层
    _stateHolder.notificationHub.markAllAsRead(employeeId: employeeId, fromDeviceId: targetDeviceId);
    // 3. 广播到远程设备（携带已读后的最新摘要）
    _broadcastReadStatus(employeeId: employeeId, targetDeviceId: targetDeviceId);
    // 4. 通知 agent 层
    _notifyAgentReadStatus(employeeId: employeeId, targetDeviceId: targetDeviceId);
  }

  void markAllMessagesAsReadGlobal() {
    final employeeIds = _stateHolder.notificationHub.unreadEmployeeIds;
    for (final employeeId in employeeIds) {
      markAllMessagesAsRead(employeeId: employeeId);
    }
  }

  Future<void> syncReadStatusFromAgent({required String employeeId}) async {
    final cachedProxy = _agentManager.getAgentProxy(employeeId);
    if (cachedProxy == null) return;

    try {
      final result = await cachedProxy.proxy.getMessagesReadStatus(deviceId: _deviceId);
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
      // 恢复 pending 请求
      restorePendingRequests();
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

  // ===== Pending 请求持久化 =====

  /// App 启动时从 session_summary 恢复 pending 请求
  ///
  /// 遍历所有有 pending 请求的摘要，触发 notificationHub 事件，
  /// 使 UI 能在重启后显示未处理的权限/确认请求。
  void restorePendingRequests() {
    try {
      final summaryStore = SessionSummaryStore(deviceId: _deviceId);
      final pendingSummaries = summaryStore.getPendingSummaries();

      for (final summary in pendingSummaries) {
        if (summary.hasPendingPermission) {
          notificationHub.onPermissionPending(
            employeeId: summary.employeeId,
            fromDeviceId: summary.deviceId,
            permissionJson: summary.pendingPermission!,
          );
          _log.debug('恢复权限请求: employeeId=${summary.employeeId}');
        }
        if (summary.hasPendingConfirm) {
          notificationHub.onConfirmPending(
            employeeId: summary.employeeId,
            fromDeviceId: summary.deviceId,
            confirmJson: summary.pendingConfirm!,
          );
          _log.debug('恢复确认请求: employeeId=${summary.employeeId}');
        }
      }
    } catch (e) {
      _log.debug('restorePendingRequests failed: $e');
    }
  }

  /// 权限请求产生时调用：写入 DB + 广播事件
  ///
  /// 由 DeviceAgentManager 在收到 toolPermissionRequest 事件后调用。
  void onPermissionRequested({
    required String employeeId,
    required String fromDeviceId,
    required String permissionJson,
  }) {
    try {
      final summaryStore = SessionSummaryStore(deviceId: _deviceId);
      summaryStore.setPendingPermission(employeeId, fromDeviceId, permissionJson);

      notificationHub.onPermissionPending(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        permissionJson: permissionJson,
      );

      // 广播摘要变更到远程设备（携带 pending 数据）
      _broadcastSessionSummaryWithPending(employeeId, fromDeviceId);

      _log.info('权限请求已持久化: employeeId=$employeeId, device=$fromDeviceId');
    } catch (e) {
      _log.error('onPermissionRequested failed', e);
    }
  }

  /// 权限请求响应后调用：清除 DB + 广播事件
  ///
  /// 由 DeviceAgentManager 在收到 toolPermissionResponse 事件后调用。
  void onPermissionResponded({
    required String employeeId,
    required String fromDeviceId,
    required String requestId,
  }) {
    try {
      final summaryStore = SessionSummaryStore(deviceId: _deviceId);
      summaryStore.clearPendingPermission(employeeId, fromDeviceId);

      notificationHub.onPermissionResolved(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        requestId: requestId,
      );

      // 广播摘要变更到远程设备（pending 已清除）
      _broadcastSessionSummaryWithPending(employeeId, fromDeviceId);

      _log.info('权限请求已清除: employeeId=$employeeId, requestId=$requestId');
    } catch (e) {
      _log.error('onPermissionResponded failed', e);
    }
  }

  /// 确认请求产生时调用：写入 DB + 广播事件
  ///
  /// 由 DeviceAgentManager 在收到 confirmRequest 事件后调用。
  void onConfirmRequested({
    required String employeeId,
    required String fromDeviceId,
    required String confirmJson,
  }) {
    try {
      final summaryStore = SessionSummaryStore(deviceId: _deviceId);
      summaryStore.setPendingConfirm(employeeId, fromDeviceId, confirmJson);

      notificationHub.onConfirmPending(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        confirmJson: confirmJson,
      );

      // 广播摘要变更到远程设备（携带 pending 数据）
      _broadcastSessionSummaryWithPending(employeeId, fromDeviceId);

      _log.info('确认请求已持久化: employeeId=$employeeId, device=$fromDeviceId');
    } catch (e) {
      _log.error('onConfirmRequested failed', e);
    }
  }

  /// 确认请求响应后调用：清除 DB + 广播事件
  ///
  /// 由 DeviceAgentManager 在收到 confirmResponse 事件后调用。
  void onConfirmResponded({
    required String employeeId,
    required String fromDeviceId,
    required String requestId,
  }) {
    try {
      final summaryStore = SessionSummaryStore(deviceId: _deviceId);
      summaryStore.clearPendingConfirm(employeeId, fromDeviceId);

      notificationHub.onConfirmResolved(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        requestId: requestId,
      );

      // 广播摘要变更到远程设备（pending 已清除）
      _broadcastSessionSummaryWithPending(employeeId, fromDeviceId);

      _log.info('确认请求已清除: employeeId=$employeeId, requestId=$requestId');
    } catch (e) {
      _log.error('onConfirmResponded failed', e);
    }
  }

  /// 广播带 pending 数据的会话摘要到远程设备
  void _broadcastSessionSummaryWithPending(String employeeId, String fromDeviceId) {
    final lanClient = _connectionManager.lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    final summaryStore = SessionSummaryStore(deviceId: _deviceId);
    final summary = summaryStore.getSummary(employeeId, deviceId: fromDeviceId);

    final msg = LanMessage(
      type: LanMessageType.agentSessionSummaryChanged,
      fromId: _deviceId,
      content: jsonEncode({
        'employeeId': employeeId,
        'fromDeviceId': fromDeviceId,
        'summary': summary?.toMap(),
      }),
      topic: _topic,
    );

    lanClient.sendLanMessage(msg);
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
      final targetDeviceId = fromDeviceId ?? _deviceId;
      _messageStoreService.markAsReadInDb(targetDeviceId, employeeId);
      // 从摘要表读取未读数量（O(1)）
      return _messageStoreService.getUnreadCount(targetDeviceId, employeeId);
    } catch (e) {
      _log.debug('markMessagesAsReadInDb failed: $e');
      return -1;
    }
  }

  // ===== 广播已读状态 =====

  void _broadcastReadStatus({
    required String employeeId,
    String? targetDeviceId,
  }) {
    final lanClient = _connectionManager.lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    // 使用 targetDeviceId（消息所在设备）查找摘要，确保远程会话也能获取正确的摘要
    final deviceId = targetDeviceId ?? _deviceId;
    // 发送完整摘要数据，使远程设备能正确更新 session summary
    final summary = _messageStoreService.getLatestMessageSummary(deviceId, employeeId);

    final msg = LanMessage(
      type: LanMessageType.agentSessionSummaryChanged,
      fromId: _deviceId,
      content: jsonEncode({
        'employeeId': employeeId,
        'fromDeviceId': targetDeviceId,
        'readerDeviceId': _deviceId,
        'summary': summary?.toMap(),
      }),
      topic: _topic,
    );

    lanClient.sendLanMessage(msg);
  }

  void _notifyAgentReadStatus({required String employeeId, String? targetDeviceId}) {
    final localAgent = _agentManager.getLocalAgent(employeeId);
    if (localAgent != null) {
      // 本地 Agent：直接调用
      localAgent.markMessagesAsRead(
        deviceId: _deviceId,
        employeeId: employeeId,
      ).catchError((e) {
        _log.debug('notifyAgentReadStatus failed: $e');
      });
    } else {
      // 远程 Agent：通过 RPC
      final proxy = _agentManager.getAgentProxy(employeeId);
      if (proxy != null) {
        final deviceId = targetDeviceId ?? _deviceId;
        proxy.proxy.markAllMessagesAsRead(deviceId)
            .catchError((e) { _log.debug('notifyRemoteAgentReadStatus failed: $e'); });
      }
    }
  }
}
