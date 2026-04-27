import 'dart:async';

import '../agent/client/cached_agent_proxy.dart';
import '../agent/entity/entity.dart';
import '../agent/rpc/agent_rpc_config.dart';
import '../agent/notification/agent_notification_hub.dart';
import '../entity/lan_device_info.dart';
import '../entity/lan_message.dart';
import '../persistence/persistence.dart';
import '../service/service.dart';
import '../utils/logger.dart';
import 'app_context.dart';
import 'impl/async_lock.dart';
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

/// DeviceClient 初始化配置
///
/// 包含数据库路径和连接参数等初始化所需的信息。
/// host/port/topic 不传时，将从数据库配置表中自动读取。
class DeviceClientConfig {
  /// 数据库存储路径（必填）
  final String dbPath;

  /// 服务器地址（可选，不传则从数据库配置读取）
  final String? host;

  /// 服务器端口，默认 9090
  final int port;

  /// 分组主题（可选）
  final String? topic;

  /// 设备名称（可选）
  final String? deviceName;

  const DeviceClientConfig({
    required this.dbPath,
    this.host,
    this.port = 9090,
    this.topic,
    this.deviceName,
  });
}

/// 当前打开的会话状态
class OpenSessionState {
  final String employeeId;
  final String? fromDeviceId;

  const OpenSessionState({required this.employeeId, this.fromDeviceId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenSessionState &&
          employeeId == other.employeeId &&
          fromDeviceId == other.fromDeviceId;

  @override
  int get hashCode => Object.hash(employeeId, fromDeviceId);
}

/// 设备连接状态
enum DeviceConnectionState {
  /// 已断开
  disconnected,

  /// 连接中
  connecting,

  /// 已连接
  connected,

  /// 重连中
  reconnecting,
}

/// LAN消息处理器
typedef LanMessageHandler = void Function(LanMessage message);

/// DeviceClient - 设备级统一入口
///
/// 核心概念：
/// - deviceId 作为数据隔离标识
/// - 员工绑定设备 = 员工在该设备上线
/// - AgentProxy = 会话窗口代理，用于与员工对话
/// - 数据同步通过LAN RPC自动实现
///
/// 业务操作通过暴露的Service属性访问：
/// - employeeManager: 员工CRUD操作
/// - sessionManager: 会话管理
/// - skillManager: 技能管理
/// - messageStore: 消息存储
/// - configService: 员工配置管理（包含MCP配置）
///
/// 使用 [getInstance] 获取实例，用 [initialize] 初始化。
///
/// ```dart
/// final client = DeviceClient.getInstance(deviceId);
/// await client.initialize(DeviceClientConfig(
///   dbPath: '/path/to/data',
///   host: '192.168.1.100',
///   port: 9090,
/// ));
/// await client.connect();
/// ```
class DeviceClient {
  static final _log = Logger('DeviceClient');

  final String _deviceId;
  String? _deviceName;
  String _host = '';
  int _port = 9090;
  String? _topic;
  bool _initialized = false;

  // ===== AppContext 依赖注入 =====

  /// 获取关联的 AppContext（初始化后可用）
  AppContext? get _ctx => AppContext.get(_deviceId);

  // ===== 子模块懒加载引用（优先从 AppContext 获取） =====

  DeviceConnectionManager get _connectionManager =>
      _ctx?.connectionManager ?? DeviceConnectionManager.getInstance(_deviceId);

  DeviceRegistry get _deviceRegistry =>
      _ctx?.deviceRegistry ?? DeviceRegistry.getInstance(_deviceId);

  DeviceConfigManager get _configManager =>
      _ctx?.configManager ?? DeviceConfigManager.getInstance(_deviceId);

  DataSyncManager get _dataSyncManager =>
      _ctx?.dataSyncManager ?? DataSyncManager.getInstance(_deviceId);

  EmployeeOnlineTracker get _onlineTracker =>
      _ctx?.onlineTracker ?? EmployeeOnlineTracker.getInstance(_deviceId);

  DeviceAgentManager get _agentManager =>
      _ctx?.agentManager ?? DeviceAgentManager.getInstance(_deviceId);

  DeviceNotificationManager get _notificationManager =>
      _ctx?.notificationManager ??
      DeviceNotificationManager.getInstance(_deviceId);

  DeviceMessageHandler get _messageHandler =>
      _ctx?.messageHandler ?? DeviceMessageHandler.getInstance(_deviceId);

  DeviceStateHolder get _stateHolder =>
      _ctx?.stateHolder ?? DeviceStateHolder.getInstance(_deviceId);

  // ===== 基础服务 =====

  EmployeeManager get _employeeManager =>
      _ctx?.employeeManager ?? EmployeeManager.getInstance(_deviceId);

  SessionManager get _sessionManager =>
      _ctx?.sessionManager ?? SessionManager.getInstance(_deviceId);

  MessageStoreService get _messageStoreService =>
      _ctx?.messageStoreService ?? MessageStoreService.getInstance(_deviceId);

  SkillManager get _skillManager =>
      _ctx?.skillManager ?? SkillManager.getInstance(_deviceId);

  EmployeeConfigService get _configService =>
      _ctx?.employeeConfigService ??
      EmployeeConfigService.getInstance(_deviceId);

  DeviceClient._({required String deviceId}) : _deviceId = deviceId;

  // ===== 单例管理 =====

  static final Map<String, DeviceClient> _instances = {};
  static final Map<String, AsyncLock> _initLocks = {};

  /// 获取实例（不存在则自动创建）
  static DeviceClient getInstance(String deviceId) {
    return _instances.putIfAbsent(
      deviceId,
      () => DeviceClient._(deviceId: deviceId),
    );
  }

  /// 初始化配置（带锁，防止并发初始化）
  ///
  /// 统一初始化流程：
  /// 1. 初始化数据库 [DatabaseManager]
  /// 2. 创建 [AppContext] 依赖容器
  /// 3. 读取数据库配置表（合并缺失的连接参数）
  /// 4. 初始化所有关联子模块
  Future<void> initialize(DeviceClientConfig config) async {
    if (_initialized) return;
    final lock = _initLocks.putIfAbsent(_deviceId, () => AsyncLock());
    await lock.synchronized(() async {
      if (_initialized) return;

      // 1. 初始化数据库
      await DatabaseManager.getInstance(
        _deviceId,
      ).initialize(storagePath: config.dbPath);

      // 2. 创建 AppContext 依赖容器
      AppContext.create(deviceId: _deviceId, dbPath: config.dbPath);

      // 3. 设置配置（参数优先）
      _host = config.host ?? '';
      _port = config.port;
      _topic = config.topic;
      _deviceName = config.deviceName;

      // 如果 host 未传入，尝试从数据库配置读取
      if (_host.isEmpty) {
        try {
          final dbConfig = await _configManager.getDeviceConfig();
          _mergeDbConfig(dbConfig);
        } catch (e) {
          // DB 中无配置，忽略
          _log.debug('read config from DB failed: $e');
        }
      }

      // 4. 初始化子模块
      _connectionManager.initialize(host: _host, port: _port, topic: _topic);
      _deviceRegistry.initialize(
        deviceName: _deviceName,
        host: _host,
        port: _port,
        topic: _topic,
      );
      _notificationManager.initialize(topic: _topic);
      _agentManager.initialize(topic: _topic);
      _messageHandler.initialize(deviceName: _deviceName, topic: _topic);

      // 5. 初始化完成
      _initialized = true;
    });
  }

  /// 从数据库配置合并缺失的连接参数
  ///
  /// 优先级：参数传入 > 数据库 metadata > 环境变量
  void _mergeDbConfig(DeviceConfigEntity dbConfig) {
    final meta = dbConfig.deviceInfo.metadata;
    final env = dbConfig.environmentVariables;

    if (_host.isEmpty) {
      _host = meta['host'] as String? ?? env['LAN_HOST'] ?? '';
    }
    if (meta['port'] != null) {
      _port = int.tryParse(meta['port'].toString()) ?? _port;
    }
    _topic ??= meta['topic'] as String? ?? env['LAN_TOPIC'];
    _deviceName ??= dbConfig.deviceInfo.name;
  }

  /// 获取当前配置
  DeviceClientConfig getConfig() => DeviceClientConfig(
    dbPath: '',
    // dbPath 仅在 initialize 时设置，运行时不可变
    host: _host,
    port: _port,
    topic: _topic,
    deviceName: _deviceName,
  );

  /// 更新运行时配置
  ///
  /// 如果连接参数（host/port/topic）发生变化且当前已连接，将自动触发重连。
  /// 其他参数（deviceName）变更会同步到关联子模块。
  Future<void> updateConfig({
    String? host,
    int? port,
    String? topic,
    String? deviceName,
  }) async {
    final oldHost = _host;
    final oldPort = _port;
    final oldTopic = _topic;

    if (host != null) _host = host;
    if (port != null) _port = port;
    if (topic != null) _topic = topic;
    if (deviceName != null) _deviceName = deviceName;

    // 同步到所有子模块
    _connectionManager.updateConfig(host: _host, port: _port, topic: _topic);
    _deviceRegistry.updateConfig(
      deviceName: _deviceName,
      host: _host,
      port: _port,
      topic: _topic,
    );
    _notificationManager.updateConfig(topic: _topic);
    _agentManager.updateConfig(topic: _topic);
    _messageHandler.updateConfig(deviceName: _deviceName, topic: _topic);

    // 如果连接参数变化且当前已连接，自动重连
    final connectionChanged =
        _host != oldHost || _port != oldPort || _topic != oldTopic;
    if (connectionChanged && _connectionManager.isConnected) {
      await _connectionManager.reconnect();
    }
  }

  /// 销毁实例并释放所有资源
  static Future<void> removeInstance(String deviceId) async {
    _initLocks.remove(deviceId);
    final client = _instances.remove(deviceId);
    if (client != null) {
      client._initialized = false;
      await client.dispose();
    }
    // 释放 AppContext（统一管理所有子模块实例）
    await AppContext.dispose(deviceId);
    // 兼容清理：移除各模块独立 _instances 中的记录
    DeviceStateHolder.removeInstance(deviceId);
    DeviceConnectionManager.removeInstance(deviceId);
    DeviceRegistry.removeInstance(deviceId);
    DeviceConfigManager.removeInstance(deviceId);
    DataSyncManager.removeInstance(deviceId);
    EmployeeOnlineTracker.removeInstance(deviceId);
    DeviceRpcHandler.removeInstance(deviceId);
    DeviceAgentManager.removeInstance(deviceId);
    DeviceMessageHandler.removeInstance(deviceId);
    DeviceNotificationManager.removeInstance(deviceId);
  }

  // ===== 只读属性 =====

  String get deviceId => _deviceId;

  String? get deviceName => _deviceName;

  String get host => _host;

  int get port => _port;

  String? get topic => _topic;

  bool get isInitialized => _initialized;

  DeviceConnectionState get connectionState =>
      _connectionManager.connectionState;

  bool get isConnected => _connectionManager.isConnected;

  List<String> get localAgentProxyIds => _agentManager.localAgentProxyIds;

  List<String> get remoteAgentProxyIds => _agentManager.remoteAgentProxyIds;

  Stream<DeviceConnectionState> get onConnectionStateChanged =>
      _stateHolder.onConnectionStateChanged;

  Stream<EmployeeOnlineEvent> get onEmployeeOnlineEvent =>
      _stateHolder.onEmployeeOnlineEvent;

  Stream<AgentEvent> get onAgentEvent => _stateHolder.onAgentEvent;

  Stream<DeviceEvent> get onDeviceEvent => _stateHolder.onDeviceEvent;

  /// 员工数据变更通知（新增/更新/删除），由底层 EmployeeManager 触发
  Stream<EmployeeChangeEvent> get onEmployeeEvent =>
      _stateHolder.onEmployeeEvent;

  /// 会话数据变更通知（新增/更新/删除），由底层 SessionManager 触发
  Stream<SessionChangeEvent> get onSessionEvent => _stateHolder.onSessionEvent;

  /// 跨设备数据同步完成事件（同步后如有数据变更则发射）
  Stream<DataSyncEvent> get onSyncEvent => _stateHolder.onSyncEvent;

  List<LanDeviceInfo> get cachedDevices => _deviceRegistry.cachedDevices;

  Stream<LanMessage> get onLanMessage => _stateHolder.onLanMessage;

  // ===== Service 属性 =====

  EmployeeManager get employeeManager => _employeeManager;

  SessionManager get sessionManager => _sessionManager;

  SkillManager get skillManager => _skillManager;

  MessageStoreService get messageStore => _messageStoreService;

  EmployeeConfigService get configService => _configService;

  // ===== 连接管理 =====

  Future<bool> pingEmployee(
    String employeeId, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final localAgent = _agentManager.getLocalAgent(employeeId);
    if (localAgent != null) return localAgent.isAlive;
    final employee = await _employeeManager.getEmployee(employeeId);
    if (employee == null) return false;
    final targetDeviceId = employee.currentDeviceId;
    if (targetDeviceId == null || targetDeviceId.isEmpty) return false;
    if (targetDeviceId == deviceId) return false;
    if (!isConnected) return false;
    return _deviceRegistry.containsDevice(targetDeviceId);
  }

  bool? isEmployeeOnline(String employeeId) =>
      _onlineTracker.isEmployeeOnline(employeeId);

  /// 连接到服务器
  ///
  /// 必须先调用 [initialize] 完成初始化。
  Future<void> connect() async {
    if (!_initialized) {
      throw StateError('DeviceClient 未初始化，请先调用 initialize() 方法');
    }
    if (_host.isEmpty) {
      throw StateError('未配置服务器地址(host)，请先通过 initialize() 或 updateConfig() 配置');
    }
    await _connectionManager.connect();
  }

  Future<void> reconnect({String? newHost, int? newPort}) =>
      _connectionManager.reconnect(newHost: newHost, newPort: newPort);

  Future<void> disconnect() => _connectionManager.disconnect();

  Future<void> dispose() async {
    await _connectionManager.dispose();
    await _agentManager.dispose();
    await _stateHolder.close();
  }

  // ===== AgentProxy 管理（核心） =====

  Future<CachedAgentProxy> getOrCreateAgentProxy({
    required String employeeId,
    String? deviceId,
    AiEmployeeEntity? employee,
    bool autoCreateSession = true,
  }) => _agentManager.getOrCreateAgentProxy(
    employeeId: employeeId,
    deviceId: deviceId,
    employee: employee,
    autoCreateSession: autoCreateSession,
  );

  Future<void> destroyAgentProxy(
    String employeeId, {
    String? targetDeviceId,
    bool keepLocalAgent = false,
  }) => _agentManager.destroyAgentProxy(
    employeeId,
    targetDeviceId: targetDeviceId,
    keepLocalAgent: keepLocalAgent,
  );

  CachedAgentProxy? getAgentProxy(String employeeId) =>
      _agentManager.getAgentProxy(employeeId);

  List<CachedAgentProxy> getLocalAgentProxies() =>
      _agentManager.getLocalAgentProxies();

  List<CachedAgentProxy> getRemoteAgentProxies() =>
      _agentManager.getRemoteAgentProxies();

  List<CachedAgentProxy> getAllAgentProxies() =>
      _agentManager.getAllAgentProxies();

  // ===== 设备管理 =====

  Future<List<LanDeviceInfo>> getOnlineDevices() =>
      _deviceRegistry.getOnlineDevices();

  Future<List<DeviceWithEmployeesInfo>> getOnlineDevicesWithEmployees() =>
      _deviceRegistry.getOnlineDevicesWithEmployees();

  Future<void> refreshDeviceList() => _deviceRegistry.refreshDeviceList();

  Future<void> sendToDevice(String toDeviceId, LanMessage message) async {
    _deviceRegistry.sendToDevice(toDeviceId, message);
  }

  Future<void> requestDeviceInfoBroadcast() async {
    _deviceRegistry.requestDeviceInfoBroadcast();
  }

  // ===== 设备配置 =====

  Future<DeviceConfigEntity> getDeviceConfig() =>
      _configManager.getDeviceConfig();

  Future<void> updateDeviceInfo(DeviceInfoConfig deviceInfo) async {
    await _configManager.updateDeviceInfo(deviceInfo);
    if (deviceInfo.name != null) {
      _deviceName = deviceInfo.name;
      _deviceRegistry.updateConfig(deviceName: deviceInfo.name);
      await _deviceRegistry.sendDeviceRegistration();
    }
  }

  Future<void> updateRemoteDeviceInfo({
    required String targetDeviceId,
    required DeviceInfoConfig deviceInfo,
  }) async {
    if (!_connectionManager.isConnected) throw StateError('未连接到服务器');
    if (targetDeviceId == deviceId) {
      await updateDeviceInfo(deviceInfo);
      return;
    }
    await _connectionManager.remoteUpdateDeviceInfo(
      targetDeviceId: targetDeviceId,
      deviceInfoMap: deviceInfo.toMap(),
    );
  }

  Future<void> updateEnvironmentVariables(Map<String, String> vars) =>
      _configManager.updateEnvironmentVariables(vars);

  Future<void> setEnvironmentVariable(String key, String value) =>
      _configManager.setEnvironmentVariable(key, value);

  Future<void> deleteEnvironmentVariable(String key) =>
      _configManager.deleteEnvironmentVariable(key);

  // ===== 员工操作（含跨设备同步） =====

  /// 删除员工（软删除 + 广播同步到所有设备）
  Future<void> deleteEmployee(String employeeId) =>
      _dataSyncManager.deleteEmployeeWithSync(employeeId);

  // ===== 会话操作（含跨设备同步） =====

  Future<void> deleteSession(String employeeId) =>
      _dataSyncManager.deleteSessionWithSync(employeeId);

  // ===== 数据同步（内部LAN RPC实现） =====

  /// 同步员工数据（防抖）
  Future<void> syncEmployeesFromDevices() =>
      _dataSyncManager.syncEmployeesFromDevices();

  /// 同步会话数据（防抖）
  Future<void> syncSessionsFromDevices() =>
      _dataSyncManager.syncSessionsFromDevices();

  /// 同步全部数据：员工+会话（防抖）
  Future<void> syncAllFromDevices() => _dataSyncManager.syncAllFromDevices();

  /// 同步会话摘要数据（从远端拉取最新摘要到本地）
  Future<void> syncSessionSummariesFromDevices() =>
      _dataSyncManager.syncSessionSummariesFromDevices();

  /// 从其他设备同步单个员工数据
  Future<AiEmployeeEntity?> syncEmployeeFromDevice({
    required String employeeId,
    String? targetDeviceId,
  }) => _dataSyncManager.syncEmployeeFromDevice(
    employeeId: employeeId,
    targetDeviceId: targetDeviceId,
  );

  /// 广播员工到所有在线设备（创建/更新后调用）
  Future<void> broadcastEmployeeToAllDevices(String employeeId) =>
      _dataSyncManager.broadcastEmployeeToAllDevices(employeeId);

  /// 广播会话到所有在线设备（创建/更新后调用）
  Future<void> broadcastSessionToAllDevices(String employeeId) =>
      _dataSyncManager.broadcastSessionToAllDevices(employeeId);

  /// 同步员工到指定远程设备
  Future<bool> syncEmployeeToDevice({
    required String employeeId,
    required String targetDeviceId,
  }) => _dataSyncManager.syncEmployeeToDevice(
    employeeId: employeeId,
    targetDeviceId: targetDeviceId,
  );

  // ===== 远程设备文件操作 =====

  /// 调用远程设备的文件操作 RPC
  ///
  /// 通用方法，不依赖特定 employee，直接通过 RPC 通道调用远程设备。
  Future<Map<String, dynamic>> invokeFileRpc({
    required String toDeviceId,
    required String method,
    required Map<String, dynamic> params,
  }) {
    if (!_connectionManager.isConnected) {
      throw StateError('未连接到服务器');
    }
    return _connectionManager.invokeRemote(toDeviceId, method, params);
  }

  /// 列出远程设备目录内容
  Future<DirectoryListingResult> listRemoteDirectory({
    required String toDeviceId,
    required String path,
  }) async {
    final result = await invokeFileRpc(
      toDeviceId: toDeviceId,
      method: AgentRpcConfig.methodListDirectory,
      params: {'path': path},
    );
    return DirectoryListingResult.fromMap(result);
  }

  /// 获取远程设备文件/目录信息
  Future<FileInfoResult> getRemoteFileInfo({
    required String toDeviceId,
    required String path,
  }) async {
    final result = await invokeFileRpc(
      toDeviceId: toDeviceId,
      method: AgentRpcConfig.methodGetFileInfo,
      params: {'path': path},
    );
    return FileInfoResult.fromMap(result);
  }

  /// 读取远程设备文件内容（小文件，Base64 编码返回）
  Future<FileReadResult> readRemoteFile({
    required String toDeviceId,
    required String path,
    int? offset,
    int? limit,
    int? maxBytes,
  }) async {
    final params = <String, dynamic>{'path': path};
    if (offset != null) params['offset'] = offset;
    if (limit != null) params['limit'] = limit;
    if (maxBytes != null) params['maxBytes'] = maxBytes;

    final result = await invokeFileRpc(
      toDeviceId: toDeviceId,
      method: AgentRpcConfig.methodReadFile,
      params: params,
    );
    return FileReadResult.fromMap(result);
  }

  /// 写入远程设备文件
  Future<FileWriteResult> writeRemoteFile({
    required String toDeviceId,
    required String path,
    required String contentBase64,
    bool append = false,
  }) async {
    final result = await invokeFileRpc(
      toDeviceId: toDeviceId,
      method: AgentRpcConfig.methodWriteFile,
      params: {
        'path': path,
        'contentBase64': contentBase64,
        'append': append,
      },
    );
    return FileWriteResult.fromMap(result);
  }

  /// 请求远程设备文件下载 Token
  Future<FileDownloadUrlResult> requestRemoteDownloadToken({
    required String toDeviceId,
    required String path,
  }) async {
    final result = await invokeFileRpc(
      toDeviceId: toDeviceId,
      method: AgentRpcConfig.methodDownloadFile,
      params: {'path': path},
    );
    // 从 RPC 响应中提取远程设备的 HTTP 地址，拼接完整下载 URL
    final hostIp = result['hostIp'] as String? ?? '';
    final hostPort = result['hostPort'] as int? ?? 0;
    final token = result['token'] as String? ?? '';
    if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
      result['url'] = 'http://$hostIp:$hostPort/file-download?token=$token';
    }
    return FileDownloadUrlResult.fromMap(result);
  }

  /// 请求远程设备文件上传 Token
  Future<FileUploadUrlResult> requestRemoteUploadToken({
    required String toDeviceId,
    required String path,
    bool overwrite = true,
  }) async {
    final result = await invokeFileRpc(
      toDeviceId: toDeviceId,
      method: AgentRpcConfig.methodUploadFile,
      params: {
        'path': path,
        'overwrite': overwrite,
      },
    );
    // 从 RPC 响应中提取远程设备的 HTTP 地址，拼接完整上传 URL
    final hostIp = result['hostIp'] as String? ?? '';
    final hostPort = result['hostPort'] as int? ?? 0;
    final token = result['token'] as String? ?? '';
    if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
      result['url'] = 'http://$hostIp:$hostPort/file-upload?token=$token';
    }
    return FileUploadUrlResult.fromMap(result);
  }

  // ===== LAN消息扩展 =====

  void setLanMessageHandler(LanMessageHandler? handler) =>
      _stateHolder.lanMessageHandler = handler;

  Future<bool> sendLanMessage(LanMessage message) {
    return _connectionManager.sendLanMessage(message);
  }

  Future<void> sendLanMessageTo(String toDeviceId, LanMessage message) {
    final lc = _connectionManager.lanClient;
    if (lc == null || !lc.isConnected) throw StateError('未连接到服务器');
    lc.sendLanMessage(
      LanMessage(
        type: message.type,
        fromId: deviceId,
        toDeviceId: toDeviceId,
        content: message.content,
        fileName: message.fileName,
        fileSize: message.fileSize,
        topic: message.topic,
      ),
    );
    return Future.value();
  }

  // ===== 文件传输 =====

  Future<String> uploadFile(
    String filePath, {
    void Function(double)? onProgress,
  }) async {
    final fileId = await _connectionManager.uploadFile(filePath);
    return fileId;
  }

  Future<void> downloadFile(
    String fileId,
    String savePath, {
    void Function(double)? onProgress,
  }) async {
    await _connectionManager.downloadFile(fileId, savePath);
  }

  // ===== 当前打开的会话状态 =====

  OpenSessionState? get currentOpenSession =>
      _notificationManager.currentOpenSession;

  Future<void> setCurrentOpenSession({
    required String employeeId,
    String? fromDeviceId,
  }) => _notificationManager.setCurrentOpenSession(
    employeeId: employeeId,
    fromDeviceId: fromDeviceId,
  );

  void clearCurrentOpenSession() =>
      _notificationManager.clearCurrentOpenSession();

  bool isSessionOpen({required String employeeId, String? fromDeviceId}) =>
      _notificationManager.isSessionOpen(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
      );

  // ===== 会话摘要查询 =====

  /// 获取所有会话摘要列表（含最新消息 + 未读 + pending 状态）
  List<SessionSummaryEntity> getSessionSummaries({String? deviceId}) {
    final summaryStore = SessionSummaryStore(deviceId: _deviceId);
    return summaryStore.getAllSummaries(deviceId: deviceId ?? _deviceId);
  }

  /// 获取单个会话摘要
  SessionSummaryEntity? getSessionSummary({
    required String employeeId,
    String? deviceId,
  }) {
    final summaryStore = SessionSummaryStore(deviceId: _deviceId);
    return summaryStore.getSummary(employeeId, deviceId: deviceId ?? _deviceId);
  }

  /// 获取所有有 pending 请求的会话
  List<SessionSummaryEntity> getPendingSessions() {
    final summaryStore = SessionSummaryStore(deviceId: _deviceId);
    return summaryStore.getPendingSummaries();
  }

  /// 获取有未读消息的会话列表
  List<SessionSummaryEntity> getUnreadSessions({String? deviceId}) {
    final summaryStore = SessionSummaryStore(deviceId: _deviceId);
    final ids = summaryStore.getUnreadEmployeeIds(
      deviceId: deviceId ?? _deviceId,
    );
    if (ids.isEmpty) return [];
    final summaries = <SessionSummaryEntity>[];
    for (final id in ids) {
      final s = summaryStore.getSummary(id, deviceId: deviceId ?? _deviceId);
      if (s != null) summaries.add(s);
    }
    return summaries;
  }

  // ===== 消息通知中心 =====

  AgentNotificationHub get notificationHub =>
      _notificationManager.notificationHub;

  int getUnreadCount({required String employeeId, String? fromDeviceId}) =>
      _notificationManager.getUnreadCount(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
      );

  int getTotalUnreadCount() => _notificationManager.getTotalUnreadCount();

  Future<void> markAllMessagesAsRead({
    required String employeeId,
    String? targetDeviceId,
  }) async {
    final deviceId = targetDeviceId ?? _deviceId;
    if (deviceId == _deviceId) {
      // 本地设备：通过 notificationManager 统一处理 DB + memory + broadcast + agent
      _notificationManager.markAllMessagesAsRead(
        employeeId: employeeId,
        targetDeviceId: deviceId,
      );
    } else {
      // 远程设备：通过 RPC 调用远程 Agent 的 markAllMessagesAsRead
      final proxy = _agentManager.getAgentProxy(employeeId);
      if (proxy != null) {
        await proxy.proxy.markAllMessagesAsRead(deviceId);
      }
    }
  }

  void markAllMessagesAsReadGlobal() =>
      _notificationManager.markAllMessagesAsReadGlobal();

  Future<void> syncReadStatusFromAgent({required String employeeId}) =>
      _notificationManager.syncReadStatusFromAgent(employeeId: employeeId);

  Future<void> restoreUnreadStatus() =>
      _notificationManager.restoreUnreadStatus();

  /// 恢复 pending 请求（App 启动时调用）
  void restorePendingRequests() =>
      _notificationManager.restorePendingRequests();

  Future<List<ChatMessage>> getLatestMessages({
    required String employeeId,
    required String deviceId,
    int limit = 2,
  }) => _notificationManager.getLatestMessages(
    employeeId: employeeId,
    deviceId: deviceId,
    limit: limit,
  );

  AgentMessage? getCachedLatestMessage({
    required String employeeId,
    required String deviceId,
  }) => _notificationManager.getCachedLatestMessage(
    employeeId: employeeId,
    deviceId: deviceId,
  );
}

/// 员工在线状态变化事件
class EmployeeOnlineEvent {
  /// 员工ID
  final String employeeId;

  /// 是否在线
  final bool isOnline;

  /// 设备ID（员工所在的设备）
  final String? deviceId;

  EmployeeOnlineEvent({
    required this.employeeId,
    required this.isOnline,
    this.deviceId,
  });
}

/// 设备与员工信息
class DeviceWithEmployeesInfo {
  final String deviceId;
  final String? deviceName;
  final String? ip;
  final DateTime? connectedAt;
  final List<EmployeeBriefInfo> employees;

  DeviceWithEmployeesInfo({
    required this.deviceId,
    this.deviceName,
    this.ip,
    this.connectedAt,
    required this.employees,
  });

  Map<String, dynamic> toMap() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'ip': ip,
    'connectedAt': connectedAt?.millisecondsSinceEpoch,
    'employees': employees.map((e) => e.toMap()).toList(),
  };
}

/// 员工简要信息
class EmployeeBriefInfo {
  final String uuid;
  final String name;
  final String status;
  final String? deviceId;

  EmployeeBriefInfo({
    required this.uuid,
    required this.name,
    required this.status,
    this.deviceId,
  });

  Map<String, dynamic> toMap() => {
    'uuid': uuid,
    'name': name,
    'status': status,
    'deviceId': deviceId,
  };
}
