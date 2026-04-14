import '../service/service.dart';
import 'impl/data_sync_manager.dart';
import 'impl/device_agent_manager.dart';
import 'impl/device_config_manager.dart';
import 'impl/device_connection_manager.dart';
import 'impl/device_message_handler.dart';
import 'impl/device_notification_manager.dart';
import 'impl/device_registry.dart';
import 'impl/device_rpc_handler.dart';
import 'impl/device_state_holder.dart';
import 'impl/employee_online_tracker.dart';

/// 依赖注入容器
///
/// 每个 deviceId 对应一个 [AppContext]，在 [DeviceClient.initialize] 时创建。
/// 持有所有服务和管理器的引用，通过两阶段构造解决循环依赖。
///
/// 使用方式：
/// - 生产环境：通过 [AppContext.create] 创建
/// - 测试环境：通过 [AppContext.test] 创建，可注入 mock
class AppContext {
  final String deviceId;

  // ===== 服务层 =====
  final EmployeeManager employeeManager;
  final SessionManager sessionManager;
  final MessageStoreService messageStoreService;
  final SkillManager skillManager;
  final EmployeeConfigService employeeConfigService;

  // ===== 设备实现层 =====
  final DeviceStateHolder stateHolder;
  final DeviceConnectionManager connectionManager;
  final DeviceRegistry deviceRegistry;
  final DeviceConfigManager configManager;
  final DataSyncManager dataSyncManager;
  final EmployeeOnlineTracker onlineTracker;
  final DeviceAgentManager agentManager;
  final DeviceNotificationManager notificationManager;
  final DeviceMessageHandler messageHandler;
  final DeviceRpcHandler rpcHandler;

  AppContext._({
    required this.deviceId,
    required this.employeeManager,
    required this.sessionManager,
    required this.messageStoreService,
    required this.skillManager,
    required this.employeeConfigService,
    required this.stateHolder,
    required this.connectionManager,
    required this.deviceRegistry,
    required this.configManager,
    required this.dataSyncManager,
    required this.onlineTracker,
    required this.agentManager,
    required this.notificationManager,
    required this.messageHandler,
    required this.rpcHandler,
  });

  // ===== 实例注册表（替代各类的 _instances Map） =====

  static final Map<String, AppContext> _registry = {};

  /// 获取指定 deviceId 的 AppContext
  static AppContext? get(String deviceId) => _registry[deviceId];

  /// 生产环境工厂
  ///
  /// 内部调用现有 getInstance() 工厂创建各组件，
  /// 然后通过两阶段构造解决循环依赖。
  static AppContext create({required String deviceId, required String dbPath}) {
    // 第一阶段：创建所有对象
    final employeeManager = EmployeeManager.getInstance(deviceId);
    final sessionManager = SessionManager.getInstance(deviceId);
    final messageStoreService = MessageStoreService.getInstance(deviceId);
    final skillManager = SkillManager.getInstance(deviceId);
    final employeeConfigService = EmployeeConfigService.getInstance(deviceId);
    final stateHolder = DeviceStateHolder.getInstance(deviceId);
    final connectionManager = DeviceConnectionManager.getInstance(deviceId);
    final deviceRegistry = DeviceRegistry.getInstance(deviceId);
    final configManager = DeviceConfigManager.getInstance(deviceId);
    final dataSyncManager = DataSyncManager.getInstance(deviceId);
    final onlineTracker = EmployeeOnlineTracker.getInstance(deviceId);
    final agentManager = DeviceAgentManager.getInstance(deviceId);
    final notificationManager = DeviceNotificationManager.getInstance(deviceId);
    final messageHandler = DeviceMessageHandler.getInstance(deviceId);
    final rpcHandler = DeviceRpcHandler.getInstance(deviceId);

    final ctx = AppContext._(
      deviceId: deviceId,
      employeeManager: employeeManager,
      sessionManager: sessionManager,
      messageStoreService: messageStoreService,
      skillManager: skillManager,
      employeeConfigService: employeeConfigService,
      stateHolder: stateHolder,
      connectionManager: connectionManager,
      deviceRegistry: deviceRegistry,
      configManager: configManager,
      dataSyncManager: dataSyncManager,
      onlineTracker: onlineTracker,
      agentManager: agentManager,
      notificationManager: notificationManager,
      messageHandler: messageHandler,
      rpcHandler: rpcHandler,
    );

    _registry[deviceId] = ctx;
    return ctx;
  }

  /// 测试环境工厂
  ///
  /// 可注入任意服务的 mock 实现，未注入的服务使用真实实现。
  /// 不注册到 _registry，避免污染生产环境。
  static AppContext test({
    required String deviceId,
    EmployeeManager? employeeManager,
    SessionManager? sessionManager,
    MessageStoreService? messageStoreService,
    SkillManager? skillManager,
    EmployeeConfigService? employeeConfigService,
    DeviceStateHolder? stateHolder,
    DeviceConnectionManager? connectionManager,
    DeviceRegistry? deviceRegistry,
    DeviceConfigManager? configManager,
    DataSyncManager? dataSyncManager,
    EmployeeOnlineTracker? onlineTracker,
    DeviceAgentManager? agentManager,
    DeviceNotificationManager? notificationManager,
    DeviceMessageHandler? messageHandler,
    DeviceRpcHandler? rpcHandler,
  }) {
    return AppContext._(
      deviceId: deviceId,
      employeeManager: employeeManager ?? EmployeeManager.getInstance(deviceId),
      sessionManager: sessionManager ?? SessionManager.getInstance(deviceId),
      messageStoreService: messageStoreService ?? MessageStoreService.getInstance(deviceId),
      skillManager: skillManager ?? SkillManager.getInstance(deviceId),
      employeeConfigService: employeeConfigService ?? EmployeeConfigService.getInstance(deviceId),
      stateHolder: stateHolder ?? DeviceStateHolder.getInstance(deviceId),
      connectionManager: connectionManager ?? DeviceConnectionManager.getInstance(deviceId),
      deviceRegistry: deviceRegistry ?? DeviceRegistry.getInstance(deviceId),
      configManager: configManager ?? DeviceConfigManager.getInstance(deviceId),
      dataSyncManager: dataSyncManager ?? DataSyncManager.getInstance(deviceId),
      onlineTracker: onlineTracker ?? EmployeeOnlineTracker.getInstance(deviceId),
      agentManager: agentManager ?? DeviceAgentManager.getInstance(deviceId),
      notificationManager: notificationManager ?? DeviceNotificationManager.getInstance(deviceId),
      messageHandler: messageHandler ?? DeviceMessageHandler.getInstance(deviceId),
      rpcHandler: rpcHandler ?? DeviceRpcHandler.getInstance(deviceId),
    );
  }

  /// 释放指定 deviceId 的 AppContext 及其所有资源
  static Future<void> dispose(String deviceId) async {
    _registry.remove(deviceId);
  }

  /// 释放所有 AppContext
  static Future<void> disposeAll() async {
    _registry.clear();
  }
}
