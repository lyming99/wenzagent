import 'dart:async';

import '../../agent/entity/agent_event.dart';
import '../../agent/notification/agent_notification_hub.dart';
import '../../entity/lan_message.dart';
import '../../service/service.dart';
import '../app_context.dart';
import '../device_client.dart';

/// 数据同步完成事件
class DataSyncEvent {
  /// 变更的员工ID集合
  final Set<String> changedEmployeeIds;

  /// 变更的会话ID集合（employeeId）
  final Set<String> changedSessionIds;

  DataSyncEvent({
    this.changedEmployeeIds = const {},
    this.changedSessionIds = const {},
  });

  bool get hasChanges => changedEmployeeIds.isNotEmpty || changedSessionIds.isNotEmpty;
}

/// 设备共享状态持有者
///
/// 持有跨模块共享的 StreamControllers 和 AgentNotificationHub。
/// 每个 deviceId 对应一个实例。
class DeviceStateHolder {
  final String deviceId;

  final _stateController = StreamController<DeviceConnectionState>.broadcast();
  final _eventController = StreamController<AgentEvent>.broadcast();
  final _lanMessageController = StreamController<LanMessage>.broadcast();
  final _deviceEventController = StreamController<DeviceEvent>.broadcast();
  final _employeeOnlineController =
      StreamController<EmployeeOnlineEvent>.broadcast();
  final _employeeChangeController =
      StreamController<EmployeeChangeEvent>.broadcast();
  final _sessionChangeController =
      StreamController<SessionChangeEvent>.broadcast();
  final _syncEventController =
      StreamController<DataSyncEvent>.broadcast();

  final AgentNotificationHub notificationHub = AgentNotificationHub();

  /// 外部 LAN 消息处理器
  LanMessageHandler? lanMessageHandler;

  StreamSubscription? _employeeChangeSub;
  StreamSubscription? _sessionChangeSub;

  DeviceStateHolder._({required this.deviceId}) {
    _initSubscriptions();
  }

  /// 订阅底层 manager 的变更流，转发到 DeviceClient 级别的 stream
  void _initSubscriptions() {
    final employeeManager = EmployeeManager.getInstance(deviceId);
    _employeeChangeSub = employeeManager.onEmployeeEvent.listen((event) {
      _employeeChangeController.add(event);
    });

    final sessionManager = SessionManager.getInstance(deviceId);
    _sessionChangeSub = sessionManager.onSessionEvent.listen((event) {
      _sessionChangeController.add(event);
    });
  }

  // ===== 流访问 =====

  Stream<DeviceConnectionState> get onConnectionStateChanged => _stateController.stream;
  Stream<AgentEvent> get onAgentEvent => _eventController.stream;
  Stream<LanMessage> get onLanMessage => _lanMessageController.stream;
  Stream<DeviceEvent> get onDeviceEvent => _deviceEventController.stream;
  Stream<EmployeeOnlineEvent> get onEmployeeOnlineEvent =>
      _employeeOnlineController.stream;
  Stream<EmployeeChangeEvent> get onEmployeeEvent =>
      _employeeChangeController.stream;
  Stream<SessionChangeEvent> get onSessionEvent =>
      _sessionChangeController.stream;
  Stream<DataSyncEvent> get onSyncEvent => _syncEventController.stream;

  // ===== 流控制 =====

  StreamController<DeviceConnectionState> get stateController => _stateController;
  StreamController<AgentEvent> get eventController => _eventController;
  StreamController<LanMessage> get lanMessageController =>
      _lanMessageController;
  StreamController<DeviceEvent> get deviceEventController =>
      _deviceEventController;
  StreamController<EmployeeOnlineEvent> get employeeOnlineController =>
      _employeeOnlineController;

  /// 发射数据同步完成事件（同步后如有数据变更，UI 可据此刷新列表）
  void notifyDataSynced(DataSyncEvent event) {
    if (event.hasChanges) {
      _syncEventController.add(event);
    }
  }

  // ===== 单例管理 =====

  static final Map<String, DeviceStateHolder> _instances = {};

  /// 从 [AppContext] 获取实例，不存在则回退到独立创建
  static DeviceStateHolder getInstance(String deviceId) {
    final ctx = AppContext.get(deviceId);
    if (ctx != null) return ctx.stateHolder;
    return _instances.putIfAbsent(
      deviceId,
      () => DeviceStateHolder._(deviceId: deviceId),
    );
  }

  static void removeInstance(String deviceId) {
    final instance = _instances.remove(deviceId);
    instance?.close();
  }

  Future<void> close() async {
    await _employeeChangeSub?.cancel();
    await _sessionChangeSub?.cancel();
    await _stateController.close();
    await _eventController.close();
    await _lanMessageController.close();
    await _deviceEventController.close();
    await _employeeOnlineController.close();
    await _employeeChangeController.close();
    await _sessionChangeController.close();
    await _syncEventController.close();
  }
}
