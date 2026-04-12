import 'dart:async';
import 'dart:io';

import '../../entity/lan_message.dart';
import '../../host/host_rpc_methods.dart';
import '../../lan/impl/lan_client_service_impl.dart';
import '../../rpc/remote_call_manager.dart';
import '../../rpc/remote_call_server.dart';
import '../device_client.dart';
import 'async_lock.dart';
import 'data_sync_manager.dart';
import 'device_message_handler.dart';
import 'device_registry.dart';
import 'device_rpc_handler.dart';
import 'device_state_holder.dart';
import 'employee_online_tracker.dart';

/// 连接管理器
///
/// 负责 LAN 连接的生命周期管理、状态监控。
class DeviceConnectionManager {
  final String _deviceId;
  String _host;
  int _port;
  String? _topic;

  LanClientServiceImpl? _lanClient;
  RemoteCallManager? _rpcManager;
  RemoteCallServer? _rpcServer;
  StreamSubscription<LanMessage>? _messageSubscription;

  DeviceConnectionState _connectionState = DeviceConnectionState.disconnected;
  final _connectionLock = AsyncLock();
  Timer? _connectionMonitorTimer;
  String? _localIp;
  bool _disposed = false;

  late final DeviceStateHolder _stateHolder = DeviceStateHolder.getInstance(_deviceId);
  late final DeviceMessageHandler _messageHandler = DeviceMessageHandler.getInstance(_deviceId);
  late final DeviceRpcHandler _rpcHandler = DeviceRpcHandler.getInstance(_deviceId);
  late final DeviceRegistry _deviceRegistry = DeviceRegistry.getInstance(_deviceId);
  late final EmployeeOnlineTracker _onlineTracker = EmployeeOnlineTracker.getInstance(_deviceId);

  DeviceConnectionManager._({
    required String deviceId,
    required String host,
    required int port,
    String? topic,
  })  : _deviceId = deviceId,
        _host = host,
        _port = port,
        _topic = topic;

  // ===== 单例管理 =====

  static final Map<String, DeviceConnectionManager> _instances = {};

  static DeviceConnectionManager getInstance(String deviceId) {
    return _instances.putIfAbsent(
      deviceId,
      () => DeviceConnectionManager._(
        deviceId: deviceId,
        host: '',
        port: 9090,
      ),
    );
  }

  /// 初始化配置
  void initialize({String? host, int? port, String? topic}) {
    updateConfig(host: host, port: port, topic: topic);
  }

  static void removeInstance(String deviceId) {
    _instances.remove(deviceId);
  }

  // ===== 配置更新 =====

  void updateConfig({String? host, int? port, String? topic}) {
    if (host != null) _host = host;
    if (port != null) _port = port;
    if (topic != null) _topic = topic;
  }

  // ===== 公开访问 =====

  DeviceConnectionState get connectionState => _connectionState;
  bool get isConnected => _connectionState == DeviceConnectionState.connected;
  LanClientServiceImpl? get lanClient => _lanClient;
  RemoteCallManager? get rpcManager => _rpcManager;
  RemoteCallServer? get rpcServer => _rpcServer;
  String? get localIp => _localIp;

  String get host => _host;
  int get port => _port;

  void _requireConnected() {
    if (_lanClient == null || !_lanClient!.isConnected) {
      throw StateError('未连接到服务器');
    }
  }

  void _requireRpcConnected() {
    if (_rpcManager == null || !isConnected) {
      throw StateError('未连接到服务器');
    }
  }

  /// 连接到服务器
  Future<void> connect() async =>
      _connectionLock.synchronized(() => _connectInternal());

  Future<void> _connectInternal() async {
    if (_disposed) throw StateError('DeviceClient 已释放');
    if (_connectionState == DeviceConnectionState.connected ||
        _connectionState == DeviceConnectionState.connecting) {
      return;
    }

    _updateState(DeviceConnectionState.connecting);
    try {
      _lanClient = LanClientServiceImpl(
        deviceId: _deviceId,
        topic: _topic,
      );
      await _lanClient!.connect(_host, port: _port);
      _rpcManager = RemoteCallManager(
        clientService: _lanClient!,
        localDeviceId: _deviceId,
      );
      _rpcServer = RemoteCallServer(
        clientService: _lanClient!,
        localDeviceId: _deviceId,
      );

      _rpcHandler.registerAll(_rpcServer!);

      _messageSubscription = _lanClient!.messageStream.listen((message) {
        _messageHandler.handleMessage(message);
      });
      _localIp = await _getLocalIp();

      _updateState(DeviceConnectionState.connected);
      _startConnectionMonitor();
    } catch (e) {
      _updateState(DeviceConnectionState.disconnected);
      rethrow;
    }
  }

  /// 重新连接到服务器
  Future<void> reconnect({String? newHost, int? newPort}) async {
    await _connectionLock.synchronized(() async {
      if (newHost != null) _host = newHost;
      if (newPort != null) _port = newPort;
      if (isConnected ||
          _connectionState == DeviceConnectionState.connecting) {
        await _disconnectInternal();
      }
      await _connectInternal();
    });
  }

  /// 断开连接
  Future<void> disconnect() async =>
      _connectionLock.synchronized(() => _disconnectInternal());

  Future<void> _disconnectInternal() async {
    _stopConnectionMonitor();
    await _messageSubscription?.cancel();
    _messageSubscription = null;
    await _lanClient?.disconnect();
    _rpcManager?.dispose();
    _rpcManager = null;
    _rpcServer?.dispose();
    _rpcServer = null;
    _updateState(DeviceConnectionState.disconnected);
  }

  /// 释放资源
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
  }

  /// 发送 LAN 消息
  void sendLanMessage(LanMessage message) {
    _requireConnected();
    _lanClient!.sendLanMessage(message);
  }

  /// 上传文件
  Future<String> uploadFile(String filePath) async {
    _requireConnected();
    return _lanClient!.uploadFile(filePath);
  }

  /// 下载文件
  Future<void> downloadFile(String fileId, String savePath) async {
    _requireConnected();
    await _lanClient!.downloadFile(fileId, savePath);
  }

  /// 调用远程 RPC
  Future<Map<String, dynamic>> invokeRemote(
    String toDeviceId,
    String method,
    Map<String, dynamic> params,
  ) {
    _requireRpcConnected();
    return _rpcManager!.invoke(method, params, toDeviceId: toDeviceId);
  }

  /// 调用远程更新设备信息
  Future<void> remoteUpdateDeviceInfo({
    required String targetDeviceId,
    required Map<String, dynamic> deviceInfoMap,
  }) async {
    if (_rpcManager == null || !isConnected) throw StateError('未连接到服务器');
    await _rpcManager!.invoke(
      HostRpcConfig.methodUpdateDeviceInfo,
      {'deviceInfo': deviceInfoMap},
      toDeviceId: targetDeviceId,
    );
  }

  // ===== 内部方法 =====

  void _updateState(DeviceConnectionState state) {
    _connectionState = state;
    _stateHolder.stateController.add(state);
    if (state == DeviceConnectionState.connected) {
      _deviceRegistry.sendDeviceRegistration();
      _refreshOnlineStateAfterDeviceList();
      // 连接/重连后自动同步全部数据（防抖已在 syncAllFromDevices 内部处理）
      DataSyncManager.getInstance(_deviceId).syncAllFromDevices();
    } else if (state == DeviceConnectionState.disconnected) {
      _onlineTracker.markAllRemoteEmployeesOffline();
    }
  }

  /// 先刷新设备列表到缓存，再基于缓存判断员工在线状态
  void _refreshOnlineStateAfterDeviceList() {
    () async {
      try {
        await _deviceRegistry.refreshDeviceList();
        _onlineTracker.refreshEmployeeOnlineStates();
      } catch (_) {
        // 即使刷新设备列表失败，也尝试刷新在线状态
        _onlineTracker.refreshEmployeeOnlineStates();
      }
    }();
  }

  void _startConnectionMonitor() {
    _stopConnectionMonitor();
    _connectionMonitorTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_disposed) {
        _stopConnectionMonitor();
        return;
      }
      final lc = _lanClient;
      if (lc == null) return;
      if (lc.isConnecting &&
          _connectionState != DeviceConnectionState.connecting &&
          _connectionState != DeviceConnectionState.connected) {
        _updateState(DeviceConnectionState.connecting);
      } else if (lc.isConnected &&
          _connectionState != DeviceConnectionState.connected) {
        _updateState(DeviceConnectionState.connected);
        _deviceRegistry.sendDeviceRegistration();
        _refreshOnlineStateAfterDeviceList();
      } else if (!lc.isConnected &&
          !lc.isConnecting &&
          _connectionState == DeviceConnectionState.connected) {
        _updateState(DeviceConnectionState.disconnected);
      }
    });
  }

  void _stopConnectionMonitor() {
    _connectionMonitorTimer?.cancel();
    _connectionMonitorTimer = null;
  }

  Future<String?> _getLocalIp() async {
    try {
      for (final iface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return null;
  }
}
