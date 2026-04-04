import 'dart:async';
import 'dart:convert';

import '../../agent/client/agent_proxy.dart';
import '../../agent/i_agent.dart';
import '../../entity/lan_device_info.dart';
import '../../entity/lan_message.dart';
import '../../lan/impl/lan_client_service_impl.dart';
import '../../rpc/remote_call_manager.dart';
import '../../rpc/rpc_config.dart';
import '../device_client.dart';

/// DeviceClient 实现类
class DeviceClientImpl implements DeviceClient {
  @override
  final String deviceId;

  @override
  final String? deviceName;

  @override
  final String host;

  @override
  final int port;

  @override
  final String? topic;

  /// LAN 客户端
  LanClientServiceImpl? _lanClient;

  /// RPC 管理器
  RemoteCallManager? _rpcManager;

  /// 本地 Agent 注册表
  final Map<String, IAgent> _localAgents = {};

  /// 本地代理缓存
  final Map<String, AgentProxy> _localProxies = {};

  /// 远程代理缓存（断线时保留）
  final Map<String, AgentProxy> _remoteProxies = {};

  /// 连接状态控制器
  final _stateController = StreamController<DeviceConnectionState>.broadcast();

  /// Agent 事件控制器
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();

  /// 消息订阅
  StreamSubscription<LanMessage>? _messageSubscription;

  /// 当前连接状态
  DeviceConnectionState _connectionState = DeviceConnectionState.disconnected;

  /// 是否已释放
  bool _disposed = false;

  DeviceClientImpl({
    required this.deviceId,
    this.deviceName,
    required this.host,
    this.port = 9090,
    this.topic,
  });

  // ===== 只读属性 =====

  @override
  DeviceConnectionState get connectionState => _connectionState;

  @override
  bool get isConnected => _connectionState == DeviceConnectionState.connected;

  @override
  List<String> get localAgentIds => _localAgents.keys.toList();

  @override
  List<String> get remoteAgentIds => _remoteProxies.keys.toList();

  @override
  Stream<DeviceConnectionState> get onStateChanged => _stateController.stream;

  @override
  Stream<Map<String, dynamic>> get onAgentEvent => _eventController.stream;

  // ===== 连接管理 =====

  @override
  Future<void> connect() async {
    if (_disposed) {
      throw StateError('DeviceClient 已释放');
    }

    if (_connectionState == DeviceConnectionState.connected ||
        _connectionState == DeviceConnectionState.connecting) {
      return;
    }

    _updateState(DeviceConnectionState.connecting);

    try {
      // 1. 创建 LAN 客户端
      _lanClient = LanClientServiceImpl(
        deviceId: deviceId,
        topic: topic,
      );

      // 2. 连接服务器
      await _lanClient!.connect(host, port: port);

      // 3. 创建 RPC 管理器
      _rpcManager = RemoteCallManager(
        clientService: _lanClient!,
        localDeviceId: deviceId,
      );

      // 4. 订阅消息流
      _messageSubscription = _lanClient!.messageStream.listen(_handleMessage);

      // 5. 发送设备注册信息
      _sendDeviceRegistration();

      _updateState(DeviceConnectionState.connected);
    } catch (e) {
      _updateState(DeviceConnectionState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    if (_lanClient == null) return;

    await _messageSubscription?.cancel();
    _messageSubscription = null;

    await _lanClient!.disconnect();

    _rpcManager?.dispose();
    _rpcManager = null;

    // 注意：断线时保留 remoteProxies，重连后可继续使用
    _updateState(DeviceConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await disconnect();

    // 清理本地代理
    for (final proxy in _localProxies.values) {
      await proxy.dispose();
    }
    _localProxies.clear();

    // 清理远程代理
    for (final proxy in _remoteProxies.values) {
      await proxy.dispose();
    }
    _remoteProxies.clear();

    _localAgents.clear();

    await _stateController.close();
    await _eventController.close();
  }

  // ===== Agent 管理 =====

  @override
  void registerLocalAgent(String employeeId, IAgent agent) {
    if (_localAgents.containsKey(employeeId)) {
      throw StateError('Agent $employeeId 已注册');
    }

    _localAgents[employeeId] = agent;

    // 创建本地代理
    final proxy = AgentProxy.local(
      employeeUuid: employeeId,
      localAgent: agent,
    );
    proxy.attach(); // 增加引用计数
    _localProxies[employeeId] = proxy;
  }

  @override
  void unregisterLocalAgent(String employeeId) {
    final agent = _localAgents.remove(employeeId);
    if (agent == null) return;

    // 减少引用计数
    final proxy = _localProxies.remove(employeeId);
    proxy?.detach();
  }

  @override
  AgentProxy getAgent({
    required String deviceId,
    required String employeeId,
  }) {
    // 如果是本地设备，从 localProxies 获取
    if (deviceId == this.deviceId) {
      final proxy = _localProxies[employeeId];
      if (proxy == null) {
        throw StateError('本地 Agent $employeeId 未注册');
      }
      return proxy;
    }

    // 否则从 remoteProxies 创建或获取
    return _getOrCreateRemoteProxy(deviceId, employeeId);
  }

  /// 获取或创建远程代理
  AgentProxy _getOrCreateRemoteProxy(String deviceId, String employeeId) {
    final key = '$deviceId:$employeeId';

    var proxy = _remoteProxies[key];
    if (proxy != null) return proxy;

    // 创建远程代理
    proxy = AgentProxy.remote(
      employeeUuid: employeeId,
      rpcCall: (method, params) => _invokeRemote(deviceId, method, params),
      remoteEventStream: _eventController.stream,
    );

    _remoteProxies[key] = proxy;
    return proxy;
  }

  /// 发起远程 RPC 调用
  Future<Map<String, dynamic>> _invokeRemote(
    String toDeviceId,
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_rpcManager == null || !isConnected) {
      throw StateError('未连接到服务器');
    }

    return _rpcManager!.invoke(
      method,
      params,
      toDeviceId: toDeviceId,
    );
  }

  // ===== 设备管理 =====

  @override
  Future<List<LanDeviceInfo>> getOnlineDevices() async {
    if (_rpcManager == null || !isConnected) {
      throw StateError('未连接到服务器');
    }

    // 通过 RPC 调用获取设备列表
    try {
      final result = await _rpcManager!.invoke(
        RpcConfig.methodGetOnlineDevices,
        {},
        toDeviceId: 'host', // 发送给主机
      );

      final devices = result['devices'] as List?;
      if (devices == null) return [];

      return devices
          .map((d) => LanDeviceInfo.fromMap(d as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // 如果 RPC 方法不存在，返回空列表
      return [];
    }
  }

  // ===== 文件传输 =====

  @override
  Future<String> uploadFile(
    String filePath, {
    void Function(double)? onProgress,
  }) async {
    if (_lanClient == null || !isConnected) {
      throw StateError('未连接到服务器');
    }

    final fileId = await _lanClient!.uploadFile(filePath);

    // 监听上传进度
    if (onProgress != null) {
      _monitorProgress(_lanClient!.uploadProgress, onProgress);
    }

    return fileId;
  }

  @override
  Future<void> downloadFile(
    String fileId,
    String savePath, {
    void Function(double)? onProgress,
  }) async {
    if (_lanClient == null || !isConnected) {
      throw StateError('未连接到服务器');
    }

    await _lanClient!.downloadFile(fileId, savePath);

    // 监听下载进度
    if (onProgress != null) {
      _monitorProgress(_lanClient!.downloadProgress, onProgress);
    }
  }

  /// 监控进度（简化实现）
  void _monitorProgress(double progress, void Function(double) onProgress) {
    Timer.periodic(const Duration(milliseconds: 100), (timer) {
      onProgress(progress);
      if (progress >= 1.0) {
        timer.cancel();
      }
    });
  }

  // ===== 内部方法 =====

  /// 更新连接状态
  void _updateState(DeviceConnectionState state) {
    _connectionState = state;
    _stateController.add(state);
  }

  /// 发送设备注册信息
  void _sendDeviceRegistration() {
    if (_lanClient == null || !_lanClient!.isConnected) return;

    final msg = LanMessage(
      type: LanMessageType.clientInfo,
      fromId: deviceId,
      fromName: deviceName,
      content: jsonEncode({
        'deviceId': deviceId,
        'deviceName': deviceName,
        'topic': topic,
      }),
      fileName: deviceId, // 使用 fileName 字段传递 deviceId
      topic: topic ?? '',
    );

    _lanClient!.sendLanMessage(msg);
  }

  /// 处理收到的消息
  void _handleMessage(LanMessage msg) {
    switch (msg.type) {
      case LanMessageType.rpcResponse:
        _handleRpcResponse(msg);

      case LanMessageType.rpcError:
        _handleRpcError(msg);

      case LanMessageType.rpcStreamChunk:
        _handleStreamChunk(msg);

      case LanMessageType.rpcStreamEnd:
        _handleStreamEnd(msg);

      case LanMessageType.agentStatusChanged:
        _handleAgentStatusChanged(msg);

      case LanMessageType.system:
        _handleSystemMessage(msg);

      default:
        break;
    }
  }

  /// 处理 RPC 响应
  void _handleRpcResponse(LanMessage msg) {
    if (_rpcManager == null) return;

    try {
      final payload = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      _rpcManager!.handleResponse(payload);
    } catch (_) {}
  }

  /// 处理 RPC 错误
  void _handleRpcError(LanMessage msg) {
    if (_rpcManager == null) return;

    try {
      final payload = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      _rpcManager!.handleError(payload);
    } catch (_) {}
  }

  /// 处理流式 chunk
  void _handleStreamChunk(LanMessage msg) {
    if (_rpcManager == null) return;

    try {
      final payload = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      _rpcManager!.handleStreamChunk(payload);
    } catch (_) {}
  }

  /// 处理流式结束
  void _handleStreamEnd(LanMessage msg) {
    if (_rpcManager == null) return;

    try {
      final payload = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      _rpcManager!.handleStreamEnd(payload);
    } catch (_) {}
  }

  /// 处理 Agent 状态变更
  void _handleAgentStatusChanged(LanMessage msg) {
    try {
      final data = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      _eventController.add({
        'type': 'agentStatusChanged',
        'data': data,
        'fromId': msg.fromId,
        'fromDeviceId': msg.fromId, // fromId 即发送方的 deviceId
      });
    } catch (_) {}
  }

  /// 处理系统消息
  void _handleSystemMessage(LanMessage msg) {
    // 检测重连成功
    final content = msg.content ?? '';
    if (content.contains('重连成功')) {
      _updateState(DeviceConnectionState.connected);
      _sendDeviceRegistration();
    }
  }
}
