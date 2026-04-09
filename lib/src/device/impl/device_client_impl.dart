import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../agent/adapter/persistent_chat_adapter.dart';
import '../../agent/agent_state.dart';
import '../../agent/client/agent_proxy.dart';
import '../../agent/client/cached_agent_proxy.dart';
import '../../agent/entity/agent_message.dart';
import '../../agent/entity/entity.dart';
import '../../agent/i_agent.dart';
import '../../agent/impl/agent_impl.dart';
import '../../agent/notification/agent_notification_hub.dart';
import '../../agent/rpc/agent_rpc_config.dart';
import '../../entity/host_rpc_request.dart';
import '../../entity/lan_device_info.dart';
import '../../entity/lan_message.dart';
import '../../host/host_rpc_methods.dart';
import '../../lan/impl/lan_client_service_impl.dart';
import '../../persistence/persistence.dart';
import '../../rpc/remote_call_manager.dart';
import '../../rpc/remote_call_server.dart';
import '../../service/service.dart';
import '../device_client.dart';

/// 简单的异步锁实现
class _AsyncLock {
  bool _locked = false;
  final _completerQueue = <Completer<void>>[];

  Future<T> synchronized<T>(Future<T> Function() fn) async {
    if (_locked) {
      final completer = Completer<void>();
      _completerQueue.add(completer);
      await completer.future;
    }

    _locked = true;
    try {
      return await fn();
    } finally {
      if (_completerQueue.isNotEmpty) {
        final next = _completerQueue.removeAt(0);
        _locked = false;
        next.complete();
      } else {
        _locked = false;
      }
    }
  }
}

/// DeviceClient 实现类
class DeviceClientImpl implements DeviceClient {
  @override
  final String deviceId;

  @override
  String? deviceName;

  @override
  String host;

  @override
  int port;

  @override
  final String? topic;

  /// LAN 客户端
  LanClientServiceImpl? _lanClient;

  /// RPC 管理器（发起调用）
  RemoteCallManager? _rpcManager;

  /// RPC 服务器（处理调用）
  RemoteCallServer? _rpcServer;

  /// 本地 Agent 实例缓存
  final Map<String, IAgent> _localAgents = {};

  /// 本地 AgentProxy 缓存（已包装为 CachedAgentProxy）
  final Map<String, CachedAgentProxy> _localProxies = {};

  /// 远程 AgentProxy 缓存（已包装为 CachedAgentProxy）
  final Map<String, CachedAgentProxy> _remoteProxies = {};

  /// Agent 事件订阅
  final Map<String, StreamSubscription<Map<String, dynamic>>>
  _agentEventSubscriptions = {};

  /// 连接状态控制器
  final _stateController = StreamController<DeviceConnectionState>.broadcast();

  /// Agent 事件控制器
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();

  /// LAN 消息控制器
  final _lanMessageController = StreamController<LanMessage>.broadcast();

  /// 设备事件控制器
  final _deviceEventController = StreamController<DeviceEvent>.broadcast();

  /// 员工在线状态变化控制器
  final _employeeOnlineController = StreamController<EmployeeOnlineEvent>.broadcast();

  /// 员工在线状态缓存 (employeeId -> online)
  final Map<String, bool> _employeeOnlineState = {};

  /// 员工在线状态 Ping 定时器（检测本地/远程 Agent 存活）
  Timer? _employeePingTimer;

  /// 员工到设备的映射缓存 (employeeId -> deviceId)
  /// 在 _doPingAllEmployees 中填充，供设备下线时同步查找使用
  final Map<String, String> _employeeDeviceMap = {};

  /// 设备缓存 (deviceId -> LanDeviceInfo)
  final Map<String, LanDeviceInfo> _deviceCache = {};

  /// 本机局域网 IP（连接后初始化）
  String? _localIp;

  /// 消息订阅
  StreamSubscription<LanMessage>? _messageSubscription;

  /// 连接状态监控定时器（检测 LAN 客户端断开/重连）
  Timer? _connectionMonitorTimer;

  /// LAN 消息处理器
  LanMessageHandler? _lanMessageHandler;

  /// 当前连接状态
  DeviceConnectionState _connectionState = DeviceConnectionState.disconnected;

  /// 是否已释放
  bool _disposed = false;

  /// 连接操作锁，防止并发连接/断开/重连导致的问题
  final _connectionLock = _AsyncLock();

  /// Agent 消息通知中心
  late final AgentNotificationHub _notificationHub;

  /// 当前打开的会话状态
  OpenSessionState? _currentOpenSession;

  /// 最新消息内存缓存（key = '$employeeId:$deviceId'）
  ///
  /// 用于会话列表实时刷新，避免每次都查询数据库。
  /// 当监听到新消息时，与缓存中的最新消息比较，取较新的更新。
  final Map<String, AgentMessage> _latestMessageCache = {};

  // ===== 服务层成员 =====

  /// 员工管理器
  late final EmployeeManagerImpl _employeeManager;

  /// 会话管理器
  late final SessionManagerImpl _sessionManager;

  /// 消息存储服务
  late final MessageStoreServiceImpl _messageStoreService;

  /// 技能管理器
  late final SkillManagerImpl _skillManager;

  /// 员工配置服务
  late final EmployeeConfigServiceImpl _configService;

  /// 设备配置存储
  late final DeviceConfigStore _deviceConfigStore;

  DeviceClientImpl({
    required this.deviceId,
    this.deviceName,
    required this.host,
    this.port = 9090,
    this.topic,
  }) {
    // 初始化服务层，使用 deviceId
    _employeeManager = EmployeeManagerImpl(deviceId: deviceId);

    _sessionManager = SessionManagerImpl();
    _messageStoreService = MessageStoreServiceImpl(deviceId: deviceId);
    _skillManager = SkillManagerImpl(deviceId: deviceId);

    // 初始化员工配置服务
    _configService = EmployeeConfigServiceImpl(
      employeeManager: _employeeManager,
      skillManager: _skillManager,
    );

    // 初始化设备配置存储
    _deviceConfigStore = DeviceConfigStore();

    // 初始化通知中心
    _notificationHub = AgentNotificationHub();
    _notificationHub.shouldAutoMarkAsReadCallback = shouldAutoMarkAsRead;

    // 从 DB 恢复未读计数（fire-and-forget，不阻塞构造函数）
    restoreUnreadStatus();
  }

  // ===== 只读属性 =====

  @override
  DeviceConnectionState get connectionState => _connectionState;

  @override
  bool get isConnected => _connectionState == DeviceConnectionState.connected;

  @override
  List<String> get localAgentProxyIds => _localProxies.keys.toList();

  @override
  List<String> get remoteAgentProxyIds => _remoteProxies.keys.toList();

  @override
  Stream<DeviceConnectionState> get onStateChanged => _stateController.stream;

  @override
  Stream<Map<String, dynamic>> get onAgentEvent => _eventController.stream;

  @override
  Stream<DeviceEvent> get onDeviceEvent => _deviceEventController.stream;

  @override
  Stream<EmployeeOnlineEvent> get onEmployeeOnlineChanged => _employeeOnlineController.stream;

  @override
  List<LanDeviceInfo> get cachedDevices => _deviceCache.values.toList();

  @override
  Stream<LanMessage> get onLanMessage => _lanMessageController.stream;

  // ===== 连接管理 =====

  @override
  @override
  Future<bool> pingEmployee(String employeeId, {Duration timeout = const Duration(seconds: 2)}) async {
    // 本地员工：直接检查 isAlive
    final localAgent = _localAgents[employeeId];
    if (localAgent != null) {
      return localAgent.isAlive;
    }

    // 远程员工：通过 RPC ping
    final employee = await _employeeManager.getEmployee(employeeId);
    if (employee == null) return false;

    final targetDeviceId = employee.currentDeviceId;
    if (targetDeviceId == null || targetDeviceId.isEmpty) return false;
    if (targetDeviceId == deviceId) return false; // 本设备但 _localAgents 中不存在

    if (_rpcManager == null || !isConnected) return false;

    try {
      final result = await _rpcManager!.invoke(
        AgentRpcConfig.methodPing,
        PingRequest(employeeId: employeeId).toMap(),
        toDeviceId: targetDeviceId,
        timeout: timeout.inMilliseconds,
      );
      return result['alive'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  bool? isEmployeeOnline(String employeeId) {
    return _employeeOnlineState[employeeId];
  }

  Future<void> connect() async {
    await _connectionLock.synchronized(() => _connectInternal());
  }

  /// 内部连接方法（无锁，供reconnect调用）
  Future<void> _connectInternal() async {
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
      _lanClient = LanClientServiceImpl(deviceId: deviceId, topic: topic);

      // 2. 连接服务器
      await _lanClient!.connect(host, port: port);

      // 3. 创建 RPC 管理器
      _rpcManager = RemoteCallManager(
        clientService: _lanClient!,
        localDeviceId: deviceId,
      );

      // 4. 创建 RPC 服务器
      _rpcServer = RemoteCallServer(
        clientService: _lanClient!,
        localDeviceId: deviceId,
      );
      _registerRpcMethods();

      // 5. 订阅消息流
      _messageSubscription = _lanClient!.messageStream.listen(_handleMessage);

      // 6. 获取本机 IP 并发送设备注册信息
      _localIp = await _getLocalIp();
      await _sendDeviceRegistration();

      _updateState(DeviceConnectionState.connected);

      // 7. 启动连接状态监控（检测 LAN 客户端断开/重连）
      _startConnectionMonitor();

      // 8. 刷新设备缓存
      _refreshDeviceList();
    } catch (e) {
      _updateState(DeviceConnectionState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> reconnect({String? newHost, int? newPort}) async {
    await _connectionLock.synchronized(() async {
      // 更新连接参数（如果提供了新的值）
      if (newHost != null) {
        host = newHost;
      }
      if (newPort != null) {
        port = newPort;
      }

      // 如果当前已连接，先断开
      if (isConnected || _connectionState == DeviceConnectionState.connecting) {
        await _disconnectInternal();
      }

      // 重新连接
      await _connectInternal();
    });
  }

  /// 注册 RPC 方法处理器
  void _registerRpcMethods() {
    // Agent相关方法
    _rpcServer!.register(AgentRpcConfig.methodSendMessage, (params) async {
      final request = SendMessageRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);

      // 🔑 日志：记录接收到的消息数据中的ID
      print('[DeviceClientImpl] RPC sendMessage 接收到消息数据: ${request.messageData}');
      print('[DeviceClientImpl] 消息ID: ${request.messageData['id']}');

      final input = MessageInput.fromMap(request.messageData);
      print('[DeviceClientImpl] MessageInput.id: ${input.id}');

      final messageId = await agent.sendMessage(input);
      print('[DeviceClientImpl] Agent返回的消息ID: $messageId');

      return {'messageId': messageId};
    });

    _rpcServer!.register(AgentRpcConfig.methodInterrupt, (params) async {
      final request = InterruptRequest.fromMap(params);
      final agent = _localAgents[request.employeeId];
      if (agent == null) return {};
      await agent.interrupt();
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetSessionMessages, (
      params,
    ) async {
      final request = GetSessionMessagesRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      final messages = await agent.getSessionMessages();
      return {'messages': messages.map((m) => m.toMap()).toList()};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetSessionMessagesByUserCount, (
      params,
    ) async {
      final request = GetSessionMessagesByUserCountRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      final messages = await agent.getSessionMessagesByUserCount(
        userMessageLimit: request.userMessageLimit,
      );
      return {'messages': messages.map((m) => m.toMap()).toList()};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetSessionMessagesPaged, (
      params,
    ) async {
      final request = GetSessionMessagesPagedRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      final messages = await agent.getSessionMessagesPaged(
        pageSize: request.pageSize,
        offset: request.offset,
      );
      return {'messages': messages.map((m) => m.toMap()).toList()};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetUnreceivedMessages, (
      params,
    ) async {
      final request = GetUnreceivedMessagesRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      final messages = await agent.getUnreceivedMessages(
        receiverDeviceId: request.receiverDeviceId,
      );
      return {'messages': messages.map((m) => m.toMap()).toList()};
    });

    _rpcServer!.register(AgentRpcConfig.methodMarkMessagesAsReceived, (
      params,
    ) async {
      final request = MarkMessagesAsReceivedRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      await agent.markMessagesAsReceived(
        receiverDeviceId: request.receiverDeviceId,
        messageReceiveList: request.messageReceiveList,
      );
      return {'success': true};
    });

    // 标记消息为已读
    _rpcServer!.register(AgentRpcConfig.methodMarkMessagesAsRead, (
      params,
    ) async {
      final request = MarkMessagesAsReadRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      await agent.markMessagesAsRead(
        readerDeviceId: request.readerDeviceId,
        employeeId: request.employeeId,
        messageIds: request.messageIds,
      );
      return {'success': true};
    });

    // 查询消息已读状态
    _rpcServer!.register(AgentRpcConfig.methodGetMessagesReadStatus, (
      params,
    ) async {
      final request = GetMessagesReadStatusRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      return agent.getMessagesReadStatus(
        deviceId: request.deviceId,
        employeeId: request.employeeId,
      );
    });

    _rpcServer!.register(AgentRpcConfig.methodGetState, (params) async {
      final request = GetStateRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      return agent.getStateSnapshot().toMap();
    });

    _rpcServer!.register(AgentRpcConfig.methodSetContext, (params) async {
      final request = SetContextRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      await agent.setContext(request.contextData);
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetContext, (params) async {
      final request = GetContextRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      return {'context': agent.getCurrentContext()};
    });

    _rpcServer!.register(AgentRpcConfig.methodSetProvider, (params) async {
      final request = SetProviderRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      final providerConfig = ProviderConfig.fromMap(request.providerConfig);
      await agent.setProvider(providerConfig);
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodClearSession, (params) async {
      final request = ClearSessionRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      await agent.clearCurrentSession();
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodPing, (params) async {
      final request = PingRequest.fromMap(params);
      if (request.employeeId != null) {
        final agent = _localAgents[request.employeeId];
        return {
          'alive': agent != null && agent.isAlive,
          'employeeId': request.employeeId,
        };
      }
      return {
        'alive': true,
        'agentCount': _localAgents.length,
        'deviceId': deviceId,
      };
    });

    _rpcServer!.register(AgentRpcConfig.methodGetOrCreateAgent, (params) async {
      final request = GetOrCreateAgentRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      return {
        'employeeId': request.employeeId,
        'status': agent.status.name,
      };
    });

    // 消息撤回
    _rpcServer!.register(AgentRpcConfig.methodRevokeMessage, (params) async {
      final request = RevokeMessageRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      await agent.revokeMessage(request.messageId);
      return {};
    });

    // 权限管理方法
    _rpcServer!.register(AgentRpcConfig.methodGetPendingPermission, (params) async {
      final request = GetPendingPermissionRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      final permissionRequest = agent.getPendingPermissionRequest();
      return {'request': permissionRequest?.toMap()};
    });

    _rpcServer!.register(AgentRpcConfig.methodRespondPermission, (params) async {
      final request = RespondPermissionRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      
      final decision = PermissionDecision.values.firstWhere(
        (d) => d.name == request.decision,
        orElse: () => PermissionDecision.deny,
      );
      
      await agent.respondToPermission(request.requestId, decision);
      return {};
    });

    // 上下文管理
    _rpcServer!.register(AgentRpcConfig.methodClearContext, (params) async {
      final request = ClearContextRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      await agent.clearContext();
      return {};
    });

    // 模型管理
    _rpcServer!.register(AgentRpcConfig.methodGetProvider, (params) async {
      final request = GetProviderRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      return {'providerConfig': agent.getProviderConfig()?.toMap()};
    });

    // 项目管理
    _rpcServer!.register(AgentRpcConfig.methodSetProject, (params) async {
      final request = SetProjectRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      final projectData = request.projectData != null 
          ? ProjectData.fromMap(request.projectData!) 
          : null;
      await agent.setProject(projectData);
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetProjectUuid, (params) async {
      final request = GetProjectUuidRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      return {'projectUuid': agent.getCurrentProjectUuid()};
    });

    // 工具管理
    _rpcServer!.register(AgentRpcConfig.methodGetRegisteredTools, (params) async {
      final request = GetRegisteredToolsRequest.fromMap(params);
      final agent = await _ensureLocalAgentForRpc(request.employeeId);
      return {'tools': agent.getRegisteredTools()};
    });

    // 员工管理方法
    _rpcServer!.register(HostRpcConfig.methodGetEmployees, (params) async {
      final request = GetEmployeesRequest.fromMap(params);
      final employees = await _employeeManager.getEmployees(
        keyword: request.keyword,
        status: request.status,
      );
      return {'employees': employees.map((e) => e.toMap()).toList()};
    });

    _rpcServer!.register(HostRpcConfig.methodGetEmployee, (params) async {
      final request = GetEmployeeRequest.fromMap(params);
      final employee = await _employeeManager.getEmployee(request.uuid);
      if (employee == null) {
        throw Exception('Employee not found: ${request.uuid}');
      }
      return {'employee': employee.toMap()};
    });

    // 会话管理方法
    _rpcServer!.register(HostRpcConfig.methodGetSessions, (params) async {
      final request = GetSessionsRequest.fromMap(params);
      final sessions = await _sessionManager.getAllSessions(
        includeArchived: request.includeArchived,
      );
      return {'sessions': sessions.map((s) => s.toMap()).toList()};
    });

    // 技能管理方法
    _rpcServer!.register(HostRpcConfig.methodGetSkills, (params) async {
      final request = GetSkillsRequest.fromMap(params);
      final skills = await _skillManager.getSkills(request.employeeId);
      return {'skills': skills.map((s) => s.toMap()).toList()};
    });

    // 数据同步方法
    _rpcServer!.register(HostRpcConfig.methodSyncEmployees, (params) async {
      final request = SyncEmployeesRequest.fromMap(params);
      final employees = request.employees
          .map((e) => AiEmployeeEntity.fromMap(e))
          .toList();
      for (final employee in employees) {
        final existing = await _employeeManager.getEmployee(employee.uuid);
        if (existing == null) {
          await _employeeManager.createEmployee(employee);
        } else {
          await _employeeManager.updateEmployee(employee);
        }
      }
      return {'count': employees.length};
    });

    _rpcServer!.register(HostRpcConfig.methodSyncSessions, (params) async {
      final request = SyncSessionsRequest.fromMap(params);
      final sessions = request.sessions
          .map((s) => AiEmployeeSessionEntity.fromMap(s))
          .toList();
      for (final session in sessions) {
        final existing = await _sessionManager.getSession(session.employeeId);
        if (existing == null ||
            session.updateTime.isAfter(existing.updateTime)) {
          await _sessionManager.save(session);
        }
      }
      return {'count': sessions.length};
    });

    _rpcServer!.register(HostRpcConfig.methodSyncMessages, (params) async {
      final request = SyncMessagesRequest.fromMap(params);
      final messages = request.messages
          .map((m) => AiEmployeeMessageEntity.fromMap(m))
          .toList();
      await _messageStoreService.addMessages(messages);
      return {'count': messages.length};
    });

    // 设备管理方法
    _rpcServer!.register(HostRpcConfig.methodGetOnlineDevices, (params) async {
      // 通过 Host 获取设备列表
      return {'devices': []};
    });

    // 远程更新设备信息（如名称）
    _rpcServer!.register(HostRpcConfig.methodUpdateDeviceInfo, (params) async {
      final deviceInfoMap = params['deviceInfo'] as Map<String, dynamic>?;
      if (deviceInfoMap == null) {
        throw Exception('deviceInfo is required');
      }
      final deviceInfo = DeviceInfoConfig.fromMap(deviceInfoMap);
      await updateDeviceInfo(deviceInfo);
      return {'success': true};
    });
  }

  @override
  Future<void> disconnect() async {
    await _connectionLock.synchronized(() => _disconnectInternal());
  }

  /// 内部断开连接方法（无锁，供reconnect调用）
  Future<void> _disconnectInternal() async {
    _stopConnectionMonitor();
    _stopEmployeeOnlineMonitor();
    await _messageSubscription?.cancel();
    _messageSubscription = null;

    await _lanClient?.disconnect();

    _rpcManager?.dispose();
    _rpcManager = null;

    _rpcServer?.dispose();
    _rpcServer = null;

    _updateState(DeviceConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await disconnect();

    for (final subscription in _agentEventSubscriptions.values) {
      await subscription.cancel();
    }
    _agentEventSubscriptions.clear();

    for (final proxy in _localProxies.values) {
      await proxy.dispose();
    }
    _localProxies.clear();

    for (final cachedProxy in _remoteProxies.values) {
      await cachedProxy.dispose();
    }
    _remoteProxies.clear();

    for (final agent in _localAgents.values) {
      await agent.dispose();
    }
    _localAgents.clear();

    // 释放通知中心
    _notificationHub.dispose();

    await _stateController.close();
    await _eventController.close();
    await _lanMessageController.close();
    await _deviceEventController.close();
    await _employeeOnlineController.close();
    _deviceCache.clear();
  }

  // ===== AgentProxy 管理 =====

  @override
  Future<CachedAgentProxy> getOrCreateAgentProxy({
    required String employeeId,
    String? deviceId,
  }) async {
    // 1. 确保Session存在（只需要employeeId）
    final session = await _sessionManager.getOrCreateSession(employeeId);

    // 2. 获取员工配置
    final employee = await _employeeManager.getEmployee(employeeId);
    if (employee == null) {
      throw StateError('Employee not found: $employeeId');
    }

    // 3. 确定目标设备ID（优先从Employee.currentDeviceId获取，否则使用传入的deviceId，最后使用当前设备ID）
    String targetDeviceId;
    if (employee.currentDeviceId != null && employee.currentDeviceId!.isNotEmpty) {
      targetDeviceId = employee.currentDeviceId!;
    } else if (deviceId != null && deviceId.isNotEmpty) {
      targetDeviceId = deviceId;
    } else {
      targetDeviceId = this.deviceId;
      // 如果currentDeviceId为空，设置为当前设备（首次打开）
      if (employee.currentDeviceId == null || employee.currentDeviceId!.isEmpty) {
        await _employeeManager.updateCurrentDeviceId(employeeId, this.deviceId);
      }
    }

    // 4. 判断本地还是远程
    if (targetDeviceId == this.deviceId) {
      // ===== 本地会话 =====
      var cachedProxy = _localProxies[employeeId];
      if (cachedProxy != null) return cachedProxy;

      // 创建本地 Agent 和 Proxy
      final agent = await _getOrCreateLocalAgent(
        employeeId,
        employee,
        session,
      );
      final proxy = AgentProxy.local(
        employeeId: employeeId,
        deviceId: targetDeviceId,
        localAgent: agent,
      );
      
      // 包装为 CachedAgentProxy（本地模式不启用缓存）
      cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: _messageStoreService,
        deviceId: targetDeviceId,
        employeeId: employeeId,
        onMarkAsRead: (empId, fromDevId) {
          _notificationHub.markAllAsRead(employeeId: empId, fromDeviceId: fromDevId);
          _broadcastReadStatus(employeeId: empId, fromDeviceId: fromDevId);
          _markMessagesAsReadInDb(empId, fromDevId);
        },
        shouldSaveAsReadCallback: () => isSessionOpen(employeeId: employeeId),
      );

      await cachedProxy.initialize();
      proxy.attach();
      _localProxies[employeeId] = cachedProxy;

      // 订阅 Agent 事件
      _subscribeAgentEvents(employeeId, agent);

      return cachedProxy;
    }

    // ===== 远程会话 =====
    final key = '$targetDeviceId:$employeeId';
    var cachedProxy = _remoteProxies[key];
    if (cachedProxy != null) return cachedProxy;

    // 将员工信息同步到目标设备（确保目标设备的 RPC 处理器能找到员工）
    await syncEmployeeToDevice(employeeId: employeeId, targetDeviceId: targetDeviceId);

    final proxy = AgentProxy.remote(
      employeeId: employeeId,
      deviceId: targetDeviceId,
      rpcCall: (method, params) =>
          _invokeRemote(targetDeviceId, method, params),
      remoteEventStream: _eventController.stream,
    );
    
    // 包装为 CachedAgentProxy（远程模式启用缓存）
    cachedProxy = CachedAgentProxy(
      proxy: proxy,
      messageStore: _messageStoreService,
      deviceId: targetDeviceId,
      employeeId: employeeId,
      onMarkAsRead: (empId, fromDevId) {
          _notificationHub.markAllAsRead(employeeId: empId, fromDeviceId: fromDevId);
          _broadcastReadStatus(employeeId: empId, fromDeviceId: fromDevId);
          _markMessagesAsReadInDb(empId, fromDevId);
        },
      shouldSaveAsReadCallback: () => isSessionOpen(employeeId: employeeId),
      );
    
      await cachedProxy.initialize();
      _remoteProxies[key] = cachedProxy;
    return cachedProxy;
  }

  /// 确保 RPC 调用所需的本地 Agent 存在（懒加载）
  ///
  /// 当远程设备调用 RPC 方法时，对应的本地 Agent 可能尚未被创建。
  /// 此方法在需要时自动创建 Agent（含持久化回调和事件订阅），
  /// 但不创建 CachedAgentProxy（由 getOrCreateAgentProxy 负责）。
  ///
  /// 当员工记录不存在时（例如从其他设备创建后尚未同步），自动创建
  /// 最小化的员工记录，确保 RPC 调用不会因 "Employee not found" 失败。
  Future<IAgent> _ensureLocalAgentForRpc(String employeeId) async {
    var agent = _localAgents[employeeId];
    if (agent != null) return agent;

    var employee = await _employeeManager.getEmployee(employeeId);
    if (employee == null) {
      // 员工不存在（可能从其他设备创建但尚未同步），创建最小记录
      final now = DateTime.now();
      employee = await _employeeManager.createEmployee(
        AiEmployeeEntity(
          uuid: employeeId,
          name: 'AI Assistant',
          role: 'assistant',
          status: 'active',
          deviceId: deviceId,
          createTime: now,
          updateTime: now,
        ),
      );
    }

    final session = await _sessionManager.getOrCreateSession(employeeId);
    agent = await _getOrCreateLocalAgent(employeeId, employee, session);

    // 订阅 Agent 事件（确保 RPC 路径也能广播事件和更新缓存）
    if (!_agentEventSubscriptions.containsKey(employeeId)) {
      _subscribeAgentEvents(employeeId, agent);
    }

    return agent;
  }

  /// 获取或创建本地 Agent
  Future<IAgent> _getOrCreateLocalAgent(
    String employeeId,
    AiEmployeeEntity employee,
    AiEmployeeSessionEntity session,
  ) async {
    var agent = _localAgents[employeeId];
    if (agent != null) return agent;

    // 创建 ChatAdapter
    final chatAdapter = PersistentChatAdapter();
    _setupPersistCallbacks(chatAdapter, employeeId);

    // 创建 Agent
    agent = AgentImpl(employeeId: employeeId, chatAdapter: chatAdapter);
    await agent.initialize(employeeId: employeeId); // 传递 employeeId 以加载历史消息

    // 设置 Provider 配置（从当前设备配置获取）
    final deviceConfig = session.getConfig(deviceId);
    if (deviceConfig?.providerConfig != null) {
      try {
        final configMap =
            jsonDecode(deviceConfig!.providerConfig!) as Map<String, dynamic>;
        final config = ProviderConfig.fromMap(configMap);
        await agent.setProvider(config);
      } catch (_) {}
    } else if (employee.provider != null && employee.provider!.isNotEmpty) {
      // 向后兼容：使用Employee的配置
      final providerConfigMap = <String, dynamic>{
        'provider': employee.provider,
      };
      if (employee.model != null) {
        providerConfigMap['model'] = employee.model;
      }
      if (employee.apiKey != null) {
        providerConfigMap['apiKey'] = employee.apiKey;
      }
      if (employee.apiBaseUrl != null) {
        providerConfigMap['baseUrl'] = employee.apiBaseUrl;
      }
      if (employee.modelConfig != null) {
        try {
          providerConfigMap['modelConfig'] = jsonDecode(employee.modelConfig!);
        } catch (_) {}
      }
      final providerConfig = ProviderConfig.fromMap(providerConfigMap);
      await agent.setProvider(providerConfig);
    }

    // 设置 System Prompt（优先设备配置覆盖，其次Employee默认）
    final systemPrompt =
        deviceConfig?.systemPromptOverride ?? employee.systemPrompt;
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      await agent.setContext({'systemPrompt': systemPrompt});
    }

    _localAgents[employeeId] = agent;
    return agent;
  }

  /// 设置持久化回调
  void _setupPersistCallbacks(
    PersistentChatAdapter adapter,
    String employeeId,
  ) {
    adapter.persistSession = (session) async {
      var existingSession = await _sessionManager.getSession(employeeId);
      if (existingSession == null) {
        // Session应该已由getOrCreateSession创建
        return;
      }

      // 更新Session标题
      final title = session['title'] as String?;
      if (title != null && title != existingSession.title) {
        existingSession = existingSession.copyWith(
          title: title,
          updateTime: DateTime.now(),
        );
        await _sessionManager.save(existingSession);
      }

      // 更新设备配置
      final providerConfig = session['providerConfig'];
      final projectUuid = session['projectUuid'] as String?;
      final contextData = session['contextData'];

      if (providerConfig != null ||
          projectUuid != null ||
          contextData != null) {
        await _sessionManager.updateDeviceConfig(
          employeeId,
          deviceId,
          providerConfig: providerConfig != null
              ? jsonEncode(providerConfig)
              : null,
          projectUuid: projectUuid,
          systemPromptOverride: null, // 不在这里更新
        );
      }
    };

    adapter.persistMessage = (message) async {
      // 使用 fromMessageMap 将整个 Map 序列化为 JSON 字符串存入 Hive
      var entity = AiEmployeeMessageEntity.fromMessageMap(message);
      // 如果当前正在查看该会话，直接写入已读状态（避免重启后因 DB 未更新而误显示未读）
      if (entity.role == 'assistant' && _currentOpenSession?.employeeId == employeeId) {
        entity = entity.copyWith(isRead: 1);
      }
      await _messageStoreService.addMessage(entity);
    };

    adapter.loadSession = (employeeId) async {
      final session = await _sessionManager.getSession(employeeId);
      if (session == null) return null;

      final deviceConfig = session.getConfig(deviceId);
      return {
        'uuid': employeeId, // 兼容旧格式
        'employeeId': session.employeeId,
        'title': session.title,
        'providerConfig': deviceConfig?.providerConfig != null
            ? jsonDecode(deviceConfig!.providerConfig!)
            : null,
        'projectUuid': deviceConfig?.projectUuid,
        'contextData': deviceConfig?.contextData != null
            ? jsonDecode(deviceConfig!.contextData!)
            : null,
      };
    };

    adapter.loadMessages = (employeeId) async {
      // 优先从 employee.currentDeviceId 获取消息，如果没有则使用当前设备
      final employee = await _employeeManager.getEmployee(employeeId);
      final messageDeviceId = (employee?.currentDeviceId != null && employee!.currentDeviceId!.isNotEmpty)
          ? employee.currentDeviceId
          : deviceId;
      
      final messages = await _messageStoreService.getMessagesWithDeviceId(
        messageDeviceId,
        employeeId,
      );
      // 优先从 jsonData 无损还原完整消息数据
      return messages.map((m) => m.toMessageMap()).toList();
    };

    adapter.updateMessageStatusCallback = (messageId, status, {error}) async {
      await _messageStoreService.updateMessageStatus(
        messageId,
        status.name,
        error: error,
      );
    };

    adapter.deleteMessagesCallback = (employeeId) async {
      await _messageStoreService.deleteMessages(employeeId);
      // 清空消息时同步清除该会话的未读状态
      _notificationHub.markAllAsRead(employeeId: employeeId);
      // 清除该员工相关的最新消息缓存并通知 UI
      _clearLatestMessageCache(employeeId);
    };
  }


  /// 更新最新消息缓存并通知 UI
  ///
  /// 比较 [message] 与当前缓存中该会话（[employeeId]+[fromDeviceId]）的最新消息，
  /// 如果 [message] 更新则更新缓存，并通过 notificationHub 发出
  /// [AgentLatestMessageUpdatedEvent] 通知 UI 刷新最新消息和未读数量。
  void _updateLatestMessageCache(
    String employeeId,
    String fromDeviceId,
    AgentMessage message,
  ) {
    final key = '$employeeId:$fromDeviceId';
    final cached = _latestMessageCache[key];

    // 权限请求消息始终优先缓存（直到权限被授权后由 completed 消息覆盖）
    final shouldUpdate = cached == null ||
        message.type == 'permission' ||
        message.createdAt.isAfter(cached.createdAt);

    if (shouldUpdate) {
      _latestMessageCache[key] = message;

      final unreadCount = _notificationHub.getUnreadCount(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId.isNotEmpty ? fromDeviceId : null,
      );
      _notificationHub.onLatestMessageUpdated(
        message: message,
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
        unreadCount: unreadCount,
      );
    }
  }

  /// 清除指定员工相关的最新消息缓存并通知 UI
  ///
  /// 遍历 [_latestMessageCache]，移除所有以 [employeeId] 为前缀的缓存条目，
  /// 并通过 notificationHub 发出 [AgentLatestMessageClearedEvent] 通知 UI 清除预览。
  void _clearLatestMessageCache(String employeeId) {
    final keysToRemove = _latestMessageCache.keys
        .where((key) => key.startsWith('$employeeId:'))
        .toList();

    for (final key in keysToRemove) {
      _latestMessageCache.remove(key);
      final fromDeviceId = key.substring('$employeeId:'.length);
      _notificationHub.onLatestMessageCleared(
        employeeId: employeeId,
        fromDeviceId: fromDeviceId,
      );
    }
  }

  /// 订阅 Agent 事件
  void _subscribeAgentEvents(String employeeId, IAgent agent) {
    final subscription = agent.onEvent.listen((event) {
      _broadcastAgentEvent(employeeId, event);

      final type = event['type'] as String?;
      final data = event['data'] as Map<String, dynamic>? ?? {};

      // LAN 未连接时，直接将 agent 事件推送到 onAgentEvent 流
      // LAN 已连接时，事件会通过 LAN 回环路径到达 _handleAgentEvent 推送
      final lanClient = _lanClient;
      if (lanClient == null || !lanClient.isConnected) {
        _eventController.add({
          'type': type,
          'data': data,
          'employeeId': employeeId,
          'fromId': deviceId,
          'fromDeviceId': deviceId,
        });
      }

      if (type != 'messageStatusChanged') return;
      final status = data['status'] as String?;
      final messageId = data['messageId'] as String?;

      // queued：立即推送用户消息到会话列表（同步，无延迟，解决空白期问题）
      if (status == 'queued' && messageId != null) {
        final content = data['content'] as String?;
        if (content != null && content.isNotEmpty) {
          final msg = AgentMessage(
            id: messageId,
            role: data['role'] as String? ?? 'user',
            type: data['type'] as String? ?? 'text',
            content: content,
            createdAt: DateTime.now(),
            status: status,
            metadata: Map<String, dynamic>.from(data)..['deviceId'] = deviceId,
          );
          _notificationHub.onLocalMessage(
            message: msg,
            employeeId: employeeId,
          );
          _updateLatestMessageCache(employeeId, deviceId, msg);
        }
      }

      // completed：异步获取最新 AI 回复并推送
      if (status == 'completed') {
        agent.getSessionMessages().then((messages) {
          if (messages.isEmpty) return;
          final lastAssistant = messages.lastWhere(
            (m) => m.role == 'assistant',
            orElse: () => messages.last,
          );
          final msg = AgentMessage(
            id: lastAssistant.id,
            role: lastAssistant.role,
            type: lastAssistant.type ?? 'text',
            content: lastAssistant.content,
            createdAt: lastAssistant.createdAt,
            status: status,
            metadata: Map<String, dynamic>.from(data)..['deviceId'] = deviceId,
          );
          // 本地消息也检查会话是否打开，未打开时标记未读（与远程模式一致）
          final autoRead = _notificationHub.shouldAutoMarkAsReadCallback?.call(
                employeeId: employeeId,
                fromDeviceId: deviceId,
              ) ?? false;
          _notificationHub.onLocalMessage(
            message: msg,
            employeeId: employeeId,
            markUnread: !autoRead,
            autoRead: autoRead,
          );
          _updateLatestMessageCache(employeeId, deviceId, msg);
        }).catchError((_) {});
      }
    });
    _agentEventSubscriptions[employeeId] = subscription;
  }

  /// 广播 Agent 事件
  void _broadcastAgentEvent(String employeeId, Map<String, dynamic> event) {
    final lanClient = _lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    final type = event['type'] as String?;
    final data = event['data'] as Map<String, dynamic>? ?? {};

    LanMessageType msgType;
    switch (type) {
      case 'agentStatusChanged':
        msgType = LanMessageType.agentStatusChanged;
      case 'messageStatusChanged':
        msgType = LanMessageType.agentMessageStatusChanged;
      case 'messageReadStatusChanged':
        msgType = LanMessageType.agentMessageReadStatusChanged;
      case 'toolCallStart':
        msgType = LanMessageType.toolCallStart;
      case 'toolCallResult':
        msgType = LanMessageType.toolCallResult;
      default:
        return;
    }

    final msg = LanMessage(
      type: msgType,
      fromId: deviceId,
      content: jsonEncode({
        'employeeId': employeeId,
        'type': type,
        'data': data,
      }),
      topic: topic,
    );

    lanClient.sendLanMessage(msg);
  }

  @override
  Future<void> destroyAgentProxy(String employeeId) async {
    // 销毁本地代理
    final proxy = _localProxies.remove(employeeId);
    if (proxy != null) {
      await proxy.dispose();
    }

    // 销毁 Agent
    final agent = _localAgents.remove(employeeId);
    if (agent != null) {
      await agent.dispose();
    }

    // 取消事件订阅
    _agentEventSubscriptions[employeeId]?.cancel();
    _agentEventSubscriptions.remove(employeeId);
  }

  @override
  CachedAgentProxy? getAgentProxy(String employeeId) {
    // 先从本地代理查找
    final localProxy = _localProxies[employeeId];
    if (localProxy != null) {
      return localProxy;
    }
    
    // 如果本地没有，从远程代理查找
    for (final entry in _remoteProxies.entries) {
      if (entry.key.endsWith(':$employeeId')) {
        return entry.value;
      }
    }
    
    return null;
  }

  @override
  List<CachedAgentProxy> getLocalAgentProxies() {
    return _localProxies.values.toList();
  }
  
  @override
  List<CachedAgentProxy> getRemoteAgentProxies() {
    return _remoteProxies.values.toList();
  }
  
  @override
  List<CachedAgentProxy> getAllAgentProxies() {
    return [..._localProxies.values, ..._remoteProxies.values];
  }

  // ===== 设备管理 =====

  @override
  Future<List<LanDeviceInfo>> getOnlineDevices() async {
    if (!isConnected) {
      throw StateError('未连接到服务器');
    }

    try {
      // 使用 LanClient 的 hostIp 和 hostPort（HTTP API 地址）
      // 而不是 DeviceClient 的 host/port（RPC 连接地址）
      final apiHost = _lanClient?.hostIp ?? host;
      final apiPort = _lanClient?.hostPort ?? port;

      // 构造查询参数，包含 topic 过滤
      final queryParameters = <String, String>{};
      if (topic != null && topic!.isNotEmpty) {
        queryParameters['topic'] = topic!;
      }

      final uri = Uri.http(
        '$apiHost:$apiPort',
        'api/devices/online',
        queryParameters.isEmpty ? null : queryParameters,
      );
      final client = HttpClient();

      final request = await client.getUrl(uri);
      final response = await request.close().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('获取在线设备列表超时');
        },
      );

      if (response.statusCode != 200) {
        return [];
      }

      final responseBody = await response.transform(utf8.decoder).join();
      final data = jsonDecode(responseBody) as Map<String, dynamic>;
      final devices = data['devices'] as List?;

      if (devices == null) return [];

      final httpDevices = devices
          .map((d) => LanDeviceInfo.fromMap(d as Map<String, dynamic>))
          .toList();

      // 合并缓存中的设备广播数据，丰富设备信息
      // HTTP API 只返回基础连接字段，缓存中可能有广播响应带来的详细信息（type/os/platform 等）
      // 但 HTTP API 的 name 来自 Host 的 _clients[idx].name，是最新值（通过 clientInfo 消息更新）
      // 因此 name 优先用 HTTP API 的值，其他详细字段从缓存补充
      return httpDevices.map((device) {
        final cached = _deviceCache[device.id];
        if (cached != null) {
          return cached.copyWith(
            name: device.name ?? cached.name,
            ip: device.ip,
            connectedAt: device.connectedAt,
            isHost: device.isHost,
            status: device.status ?? 'online',
          );
        }
        // 本机设备没有缓存时，用本地已知信息丰富
        // （本机收不到自己发出的 deviceInfoRequest 广播，所以缓存中不会有本机信息）
        if (device.id == deviceId) {
          return _buildLocalDeviceInfo(device);
        }
        return device;
      }).toList();
    } catch (e) {
      print('获取在线设备列表失败: $e');
      return [];
    }
  }

  @override
  Future<List<DeviceWithEmployeesInfo>> getOnlineDevicesWithEmployees() async {
    final devices = await getOnlineDevices();
    final result = <DeviceWithEmployeesInfo>[];

    for (final device in devices) {
      // 使用employeeManager获取员工，然后按设备过滤
      final allEmployees = await _employeeManager.getEmployees();
      final employees = allEmployees
          .where((e) => e.deviceId == device.id)
          .toList();
      result.add(
        DeviceWithEmployeesInfo(
          deviceId: device.id,
          deviceName: device.name,
          ip: device.ip,
          connectedAt: device.connectedAt,
          employees: employees
              .map(
                (e) => EmployeeBriefInfo(
                  uuid: e.uuid,
                  name: e.name,
                  status: e.status,
                  deviceId: e.deviceId,
                ),
              )
              .toList(),
        ),
      );
    }

    return result;
  }

  // ===== 设备配置 =====

  @override
  Future<DeviceConfigEntity> getDeviceConfig() async {
    return await _deviceConfigStore.getOrCreate(deviceId);
  }

  @override
  Future<void> updateDeviceInfo(DeviceInfoConfig deviceInfo) async {
    // 先读取现有配置，做 merge 更新而非全量替换
    // 避免前端只传 name 时把 description、type 等已有字段清空
    try {
      final existing = await _deviceConfigStore.find(deviceId);
      if (existing != null) {
        final mergedInfo = existing.deviceInfo.copyWith(
          name: deviceInfo.name,
          type: deviceInfo.type,
          description: deviceInfo.description,
          icon: deviceInfo.icon,
          os: deviceInfo.os,
          osVersion: deviceInfo.osVersion,
          appVersion: deviceInfo.appVersion,
          model: deviceInfo.model,
          manufacturer: deviceInfo.manufacturer,
          tags: deviceInfo.tags.isNotEmpty ? deviceInfo.tags : null,
          metadata: deviceInfo.metadata.isNotEmpty ? deviceInfo.metadata : null,
        );
        await _deviceConfigStore.updateDeviceInfo(deviceId, mergedInfo);
      } else {
        await _deviceConfigStore.updateDeviceInfo(deviceId, deviceInfo);
      }
    } catch (_) {
      // 查询失败时回退到直接替换
      await _deviceConfigStore.updateDeviceInfo(deviceId, deviceInfo);
    }
    // 更新内存中的 deviceName 并重新发送注册信息
    if (deviceInfo.name != null) {
      deviceName = deviceInfo.name;
      await _sendDeviceRegistration();
    }
  }

  @override
  Future<void> updateRemoteDeviceInfo({
    required String targetDeviceId,
    required DeviceInfoConfig deviceInfo,
  }) async {
    if (_rpcManager == null || !isConnected) {
      throw StateError('未连接到服务器');
    }
    print('[DeviceClientImpl] updateRemoteDeviceInfo: targetDeviceId=$targetDeviceId, localDeviceId=$deviceId, match=${targetDeviceId == deviceId}');
    if (targetDeviceId == deviceId) {
      // 目标设备是本机，直接调用本地方法
      print('[DeviceClientImpl] 本机更新设备信息: name=${deviceInfo.name}');
      await updateDeviceInfo(deviceInfo);
      return;
    }
    print('[DeviceClientImpl] 远程更新设备信息: targetDeviceId=$targetDeviceId');
    await _rpcManager!.invoke(
      HostRpcConfig.methodUpdateDeviceInfo,
      {'deviceInfo': deviceInfo.toMap()},
      toDeviceId: targetDeviceId,
    );
  }

  @override
  Future<void> updateEnvironmentVariables(
    Map<String, String> environmentVariables,
  ) async {
    await _deviceConfigStore.updateEnvironmentVariables(
      deviceId,
      environmentVariables,
    );
  }

  @override
  Future<void> setEnvironmentVariable(String key, String value) async {
    await _deviceConfigStore.setEnvironmentVariable(deviceId, key, value);
  }

  @override
  Future<void> deleteEnvironmentVariable(String key) async {
    await _deviceConfigStore.deleteEnvironmentVariable(deviceId, key);
  }

  // ===== Service 属性 =====

  @override
  EmployeeManager get employeeManager => _employeeManager;

  @override
  SessionManager get sessionManager => _sessionManager;

  @override
  SkillManager get skillManager => _skillManager;

  @override
  MessageStoreService get messageStore => _messageStoreService;

  @override
  EmployeeConfigService get configService => _configService;

  // ===== 消息通知中心 =====

  @override
  AgentNotificationHub get notificationHub => _notificationHub;

  @override
  int getUnreadCount({required String employeeId, String? fromDeviceId}) {
    return _notificationHub.getUnreadCount(
      employeeId: employeeId,
      fromDeviceId: fromDeviceId,
    );
  }

  @override
  int getTotalUnreadCount() => _notificationHub.getTotalUnreadCount();

  @override
  OpenSessionState? get currentOpenSession => _currentOpenSession;

  @override
  Future<void> setCurrentOpenSession({required String employeeId, String? fromDeviceId}) async {
    _currentOpenSession = OpenSessionState(employeeId: employeeId, fromDeviceId: fromDeviceId);
    // 设置打开会话时，同时将该会话的所有未读消息标记为已读
    markAllMessagesAsRead(employeeId: employeeId, fromDeviceId: fromDeviceId);
    // 等待 DB 更新完成，确保切回列表时不会读到旧的未读数
    await _markMessagesAsReadInDb(employeeId, fromDeviceId);
  }

  @override
  void clearCurrentOpenSession() {
    _currentOpenSession = null;
  }

  @override
  bool isSessionOpen({required String employeeId, String? fromDeviceId}) {
    final session = _currentOpenSession;
    if (session == null) return false;
    if (session.employeeId != employeeId) return false;
    if (fromDeviceId != null && session.fromDeviceId != fromDeviceId) return false;
    return true;
  }

  @override
  bool shouldAutoMarkAsRead({required String employeeId, String? fromDeviceId}) {
    return isSessionOpen(employeeId: employeeId, fromDeviceId: fromDeviceId);
  }

  @override
  void markAllMessagesAsRead({required String employeeId, String? fromDeviceId}) {
    _notificationHub.markAllAsRead(employeeId: employeeId, fromDeviceId: fromDeviceId);
    _broadcastReadStatus(employeeId: employeeId, fromDeviceId: fromDeviceId);
    // 异步更新数据库中的已读标记（fire-and-forget，不阻塞调用方）
    _markMessagesAsReadInDb(employeeId, fromDeviceId);
    // 通知本地 Agent 记录已读状态（Agent 会广播给所有设备）
    _notifyAgentReadStatus(employeeId: employeeId, fromDeviceId: fromDeviceId);
  }

  /// 通知本地 Agent 消息已读（fire-and-forget）
  void _notifyAgentReadStatus({required String employeeId, String? fromDeviceId}) {
    final agent = _localAgents[employeeId];
    if (agent == null) return;
    agent.markMessagesAsRead(
      readerDeviceId: deviceId,
      employeeId: employeeId,
    ).catchError((_) {});
  }

  /// 异步更新数据库消息为已读
  ///
  /// 使用 [fromDeviceId] 查询和更新，确保读写使用同一个 Hive key。
  /// 当 [fromDeviceId] 为空时回退到本机 deviceId（与消息存储逻辑一致）。
  Future<void> _markMessagesAsReadInDb(String employeeId, String? fromDeviceId) async {
    final effectiveDeviceId = (fromDeviceId != null && fromDeviceId.isNotEmpty)
        ? fromDeviceId
        : deviceId;
    try {
      final messages = await _messageStoreService.getMessagesWithDeviceId(effectiveDeviceId, employeeId);
      for (final m in messages) {
        if (m.role == 'assistant' && m.isRead == 0) {
          await _messageStoreService.updateMessage(
            m.copyWith(isRead: 1, jsonData: null),
            deviceId: effectiveDeviceId,
          );
        }
      }
    } catch (_) {}
  }

  /// 异步更新数据库中所有有未读消息的员工的消息为已读（fire-and-forget）
  void _markAllMessagesAsReadInDbGlobal() {
    final employeeIds = _notificationHub.unreadEmployeeIds;
    for (final employeeId in employeeIds) {
      _markMessagesAsReadInDb(employeeId, null);
    }
  }

  @override
  void markAllMessagesAsReadGlobal() {
    _notificationHub.markAllAsReadGlobal();
    _broadcastReadStatusGlobal();
    // 异步更新数据库中所有消息为已读
    _markAllMessagesAsReadInDbGlobal();
  }

  @override
  Future<void> syncReadStatusFromAgent({required String employeeId}) async {
    // 1. 查找该员工的 AgentProxy（本地或远程）
    final proxy = getAgentProxy(employeeId);
    if (proxy == null) return;

    try {
      // 2. 通过 proxy 向 Agent 查询已读状态
      final result = await proxy.getMessagesReadStatus(deviceId: deviceId);
      final readStatus = result['readStatus'] as Map<String, dynamic>? ?? {};

      // 3. 遍历已读状态，更新本地数据库中对应消息的 isRead 字段
      for (final entry in readStatus.entries) {
        final messageId = entry.key;
        final isRead = entry.value as bool? ?? false;
        if (isRead) {
          // 通过 uuid 获取消息，更新 isRead 标记
          _messageStoreService.getMessage(messageId).then((message) {
            if (message != null && message.isRead == 0) {
              _messageStoreService.updateMessage(
                message.copyWith(isRead: 1, jsonData: null),
              );
            }
          }).catchError((_) {});
        }
      }

      // 4. 如果有已读消息，清除 notificationHub 中的未读计数
      final hasRead = readStatus.values.any((v) => v == true);
      if (hasRead) {
        _notificationHub.markAllAsRead(employeeId: employeeId);
      }
    } catch (_) {
      // 查询失败静默处理，不影响主流程
    }
  }

  @override
  Future<void> restoreUnreadStatus() async {
    try {
      // 获取所有会话
      final sessions = await _sessionManager.getAllSessions();
      for (final session in sessions) {
        final employeeId = session.employeeId;
        // 查询该会话的所有消息，统计未读的助手消息数量
        final messages = await _messageStoreService.getMessages(employeeId);
        final unreadCount = messages
            .where((m) => m.role == 'assistant' && m.isRead == 0)
            .length;

        if (unreadCount > 0) {
          _notificationHub.restoreUnreadCount(
            employeeId: employeeId,
            count: unreadCount,
          );
        }

        // 恢复最新消息缓存（从 DB 加载最新消息到内存缓存，并通知 UI）
        if (messages.isNotEmpty) {
          // 获取员工实体以确定消息所属设备
          final employee = await _employeeManager.getEmployee(employeeId);
          final rawDeviceId = (employee?.currentDeviceId != null &&
                  employee!.currentDeviceId!.isNotEmpty)
              ? employee.currentDeviceId!
              : deviceId;
          final messageDeviceId = rawDeviceId;

          // 取最新的消息（列表按旧→新排列）
          final latestEntity = messages.last;
          final latestMap = latestEntity.toMessageMap();
          final latestMsg = AgentMessage.fromMap(latestMap);

          final key = '$employeeId:$messageDeviceId';
          _latestMessageCache[key] = latestMsg;

          _notificationHub.onLatestMessageUpdated(
            message: latestMsg,
            employeeId: employeeId,
            fromDeviceId: messageDeviceId,
            unreadCount: _notificationHub.getUnreadCount(employeeId: employeeId),
          );
        }
      }
    } catch (_) {
      // 恢复失败静默处理，不影响主流程
    }
  }

  @override
  Future<List<AiEmployeeMessageEntity>> getLatestMessages({
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

  @override
  AgentMessage? getCachedLatestMessage({
    required String employeeId,
    required String deviceId,
  }) {
    return _latestMessageCache['$employeeId:$deviceId'];
  }

  // ===== 数据同步 =====

  @override
  Future<void> syncEmployeesFromDevices() async {
    if (_rpcManager == null || !isConnected) {
      throw StateError('未连接到服务器');
    }

    final devices = await getOnlineDevices();
    for (final device in devices) {
      if (device.id == deviceId) continue;

      try {
        final result = await _rpcManager!.invoke(
          HostRpcConfig.methodGetEmployees,
          {},
          toDeviceId: device.id,
        );
        final employeesData = result['employees'] as List? ?? [];
        for (final data in employeesData) {
          final employee = AiEmployeeEntity.fromMap(
            data as Map<String, dynamic>,
          );
          final existing = await _employeeManager.getEmployee(employee.uuid);
          
          if (existing == null) {
            // 本地不存在 → 创建（包括已删除的员工）
            await _employeeManager.createEmployee(employee);
          } else {
            // 本地已存在 → 判断是否需要更新
            
            // 优先比较 deletedTime（如果任一员工被删除）
            if (employee.deleted == 1 || existing.deleted == 1) {
              // 至少一方被删除，比较 deletedTime
              final remoteDeletedTime = employee.deletedTime;
              final localDeletedTime = existing.deletedTime;
              
              if (remoteDeletedTime != null && localDeletedTime != null) {
                // 双方都有 deletedTime，比较哪个更新
                if (remoteDeletedTime.isAfter(localDeletedTime)) {
                  // 远程删除更新 → 同步删除状态
                  await _employeeManager.updateEmployee(
                    employee.copyWith(updateTime: DateTime.now()),
                  );
                }
                // 否则保留本地的删除状态
              } else if (remoteDeletedTime != null) {
                // 远程已删除，本地未删除 → 标记删除
                await _employeeManager.updateEmployee(
                  employee.copyWith(updateTime: DateTime.now()),
                );
              }
              // 如果只有本地删除了，保留本地状态
            } else {
              // 都未删除，正常比较 updateTime
              if (employee.updateTime.isAfter(existing.updateTime)) {
                // 远程更新 → 更新本地
                await _employeeManager.updateEmployee(employee);
              }
              // 否则：本地更新或相同 → 保留本地
            }
          }
        }
      } catch (e) {
        // 忽略单个设备的同步错误
      }
    }
  }

  @override
  Future<bool> syncEmployeeToDevice({
    required String employeeId,
    required String targetDeviceId,
  }) async {
    if (_rpcManager == null || !isConnected) return false;
    if (targetDeviceId == deviceId) return false;

    try {
      final employee = await _employeeManager.getEmployee(employeeId);
      if (employee == null) return false;

      final result = await _rpcManager!.invoke(
        HostRpcConfig.methodSyncEmployees,
        {'employees': [employee.toMap()]},
        toDeviceId: targetDeviceId,
      );
      return (result['count'] as int? ?? 0) > 0;
    } catch (e) {
      print('[DeviceClientImpl] 同步员工到设备 $targetDeviceId 失败: $e');
      return false;
    }
  }

  @override
  Future<void> deleteSession(String employeeId) async {
    // 1. 本地软删除（保留记录以便同步时识别已删除状态）
    await _sessionManager.deleteSession(employeeId);

    // 2. 后台异步通知其他在线设备，不阻塞 UI
    _syncDeleteToDevices(employeeId);
  }

  /// 后台异步传播删除到其他设备
  void _syncDeleteToDevices(String employeeId) {
    Future(() async {
      if (_rpcManager == null || !isConnected) return;
      try {
        final devices = await getOnlineDevices();
        for (final device in devices) {
          if (device.id == deviceId) continue;
          try {
            await _rpcManager!.invoke(
              HostRpcConfig.methodDeleteSession,
              {'employeeId': employeeId},
              toDeviceId: device.id,
            );
          } catch (_) {}
        }
      } catch (_) {}
    });
  }

  @override
  Future<void> syncSessionsFromDevices() async {
    if (_rpcManager == null || !isConnected) {
      throw StateError('未连接到服务器');
    }

    final devices = await getOnlineDevices();
    for (final device in devices) {
      if (device.id == deviceId) continue;

      try {
        final result = await _rpcManager!.invoke(
          HostRpcConfig.methodGetSessions,
          {},
          toDeviceId: device.id,
        );
        final sessionsData = result['sessions'] as List? ?? [];
        for (final data in sessionsData) {
          final session = AiEmployeeSessionEntity.fromMap(
            data as Map<String, dynamic>,
          );
          final existing = await _sessionManager.getSession(
            session.employeeId,
          );

          if (existing == null) {
            // 本地不存在 → 远程未删除的直接创建；远程已删除且未被复活的也同步（保留删除状态）
            if (session.deleted != 1 ||
                (session.deleteTime != null && session.updateTime.isAfter(session.deleteTime!))) {
              // 远程未删除，或已复活 → 创建
              await _sessionManager.save(session);
            }
            // 远程已删除且未复活 → 不同步（避免拉回垃圾数据）
          } else {
            // 本地已存在 → 合并逻辑
            if (existing.deleted == 1 && session.deleted == 1) {
              // 双方都已删除 → 保留 deleteTime 更大（更晚删除）的一方
              final eTime = existing.deleteTime ?? existing.updateTime;
              final sTime = session.deleteTime ?? session.updateTime;
              if (sTime.isAfter(eTime)) {
                await _sessionManager.save(session);
              }
            } else if (existing.deleted == 1) {
              // 仅本地已删除 → 检查是否已被远程复活（远程 updateTime > 本地 deleteTime）
              final localDeleteTime = existing.deleteTime ?? existing.updateTime;
              if (session.updateTime.isAfter(localDeleteTime)) {
                // 远程有更新活动（新消息等）→ 远程复活，同步过来
                await _sessionManager.save(session.copyWith(
                  deleted: 0,
                  deleteTime: null,
                ));
              }
              // 否则保留本地的删除状态
            } else if (session.deleted == 1) {
              // 仅远程已删除 → 检查本地是否有更新活动
              final remoteDeleteTime = session.deleteTime ?? session.updateTime;
              if (existing.updateTime.isAfter(remoteDeleteTime)) {
                // 本地有更新活动 → 忽略远程删除（本地已复活）
              } else {
                // 本地无更新活动 → 同步远程删除
                await _sessionManager.save(session);
              }
            } else {
              // 双方都未删除 → 正常比较 updateTime
              if (session.updateTime.isAfter(existing.updateTime)) {
                await _sessionManager.save(session);
              }
            }
          }
        }
      } catch (e) {
        // 忽略单个设备的同步错误
      }
    }
  }

  // ===== LAN消息扩展 =====

  @override
  void setLanMessageHandler(LanMessageHandler? handler) {
    _lanMessageHandler = handler;
  }

  @override
  Future<void> sendLanMessage(LanMessage message) async {
    if (_lanClient == null || !_lanClient!.isConnected) {
      throw StateError('未连接到服务器');
    }
    _lanClient!.sendLanMessage(message);
  }

  @override
  Future<void> sendLanMessageTo(String toDeviceId, LanMessage message) async {
    if (_lanClient == null || !_lanClient!.isConnected) {
      throw StateError('未连接到服务器');
    }
    // 设置目标设备ID
    final msg = LanMessage(
      type: message.type,
      fromId: deviceId,
      toDeviceId: toDeviceId,
      content: message.content,
      fileName: message.fileName,
      fileSize: message.fileSize,
      topic: message.topic,
    );
    _lanClient!.sendLanMessage(msg);
  }

  // ===== 文件传输 =====

  @override
  Future<String> uploadFile(
    String filePath, {
    void Function(double)? onProgress,
  }) async {
    if (_lanClient == null || !_lanClient!.isConnected) {
      throw StateError('未连接到服务器');
    }

    final fileId = await _lanClient!.uploadFile(filePath);

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
    if (_lanClient == null || !_lanClient!.isConnected) {
      throw StateError('未连接到服务器');
    }

    await _lanClient!.downloadFile(fileId, savePath);

    if (onProgress != null) {
      _monitorProgress(_lanClient!.downloadProgress, onProgress);
    }
  }

  /// 构建本机设备的完整信息
  ///
  /// HTTP API 只返回基础字段（id、name、ip），不包含 type、os、platform 等。
  /// 本机无法收到自己发出的 deviceInfoRequest 广播，所以 _deviceCache 中没有本机详细信息。
  /// 此方法用本地已知的平台信息和 DB 中的设备名称来丰富基础数据。
  LanDeviceInfo _buildLocalDeviceInfo(LanDeviceInfo base) {
    String? os, platform;
    if (Platform.isAndroid) {
      os = 'android';
      platform = 'mobile';
    } else if (Platform.isIOS) {
      os = 'ios';
      platform = 'mobile';
    } else if (Platform.isWindows) {
      os = 'windows';
      platform = 'desktop';
    } else if (Platform.isMacOS) {
      os = 'macos';
      platform = 'desktop';
    } else if (Platform.isLinux) {
      os = 'linux';
      platform = 'desktop';
    }

    return base.copyWith(
      name: base.name ?? deviceName,
      type: base.type ?? platform,
      os: base.os ?? os,
      platform: base.platform ?? platform,
      status: base.status ?? 'online',
    );
  }

  void _monitorProgress(double progress, void Function(double) onProgress) {
    Timer.periodic(const Duration(milliseconds: 100), (timer) {
      onProgress(progress);
      if (progress >= 1.0) {
        timer.cancel();
      }
    });
  }

  // ===== 内部方法 =====
  void _updateState(DeviceConnectionState state) {
    _connectionState = state;
    _stateController.add(state);

    if (state == DeviceConnectionState.connected) {
      // LAN 连接成功，启动员工在线监控
      _startEmployeeOnlineMonitor();
    } else if (state == DeviceConnectionState.disconnected) {
      // LAN 断开，停止监控并标记所有员工离线
      _stopEmployeeOnlineMonitor();
      _markAllRemoteEmployeesOffline();
    }
  }

  /// 启动连接状态监控定时器
  ///
  /// 定期检查底层 LAN 客户端的连接状态，当检测到
  /// LAN 客户端断开（如服务器关闭）或重连成功时同步更新 DeviceClient 的状态。
  void _startConnectionMonitor() {
    _stopConnectionMonitor();
    _connectionMonitorTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_disposed) {
        _stopConnectionMonitor();
        return;
      }

      final lanClient = _lanClient;
      if (lanClient == null) return;

      final lanConnected = lanClient.isConnected;
      final lanConnecting = lanClient.isConnecting;

      if (lanConnecting && _connectionState != DeviceConnectionState.connecting && _connectionState != DeviceConnectionState.connected) {
        // LAN 客户端正在重连
        _updateState(DeviceConnectionState.connecting);
      } else if (lanConnected && _connectionState != DeviceConnectionState.connected) {
        // LAN 客户端重连成功
        _updateState(DeviceConnectionState.connected);
        _sendDeviceRegistration();
        _refreshDeviceList();
      } else if (!lanConnected && !lanConnecting && _connectionState == DeviceConnectionState.connected) {
        // LAN 客户端已断开（服务器关闭等）
        _updateState(DeviceConnectionState.disconnected);
      }
    });
  }

  /// 停止连接状态监控定时器
  void _stopConnectionMonitor() {
    _connectionMonitorTimer?.cancel();
    _connectionMonitorTimer = null;
  }

  // ===== 员工在线状态监控 =====

  /// 启动员工在线状态监控
  ///
  /// 定期 ping 所有已知员工，检测其在线状态，通过 Stream 发布状态变化。
  void _startEmployeeOnlineMonitor() {
    _stopEmployeeOnlineMonitor();
    _doPingAllEmployees(); // 立即 ping 一次
    _employeePingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_disposed) {
        _stopEmployeeOnlineMonitor();
        return;
      }
      _doPingAllEmployees();
    });
  }

  /// 停止员工在线状态监控
  void _stopEmployeeOnlineMonitor() {
    _employeePingTimer?.cancel();
    _employeePingTimer = null;
  }

  /// Ping 所有已知员工并更新在线状态
  Future<void> _doPingAllEmployees() async {
    try {
      final employees = await _employeeManager.getEmployees();
      for (final employee in employees) {
        final empId = employee.uuid;
        final devId = employee.currentDeviceId;

        // 更新员工-设备映射缓存
        if (devId != null && devId.isNotEmpty) {
          _employeeDeviceMap[empId] = devId;
        }

        bool online = false;

        if (devId != null && devId.isNotEmpty) {
          if (devId == deviceId) {
            // 本设备员工：检查本地 Agent
            online = _localAgents[empId]?.isAlive ?? false;
          } else {
            // 远程员工：先检查设备是否在缓存中
            if (!_deviceCache.containsKey(devId) || _rpcManager == null || !isConnected) {
              online = false;
            } else {
              // 设备在线，进一步 RPC ping
              try {
                final result = await _rpcManager!.invoke(
                  AgentRpcConfig.methodPing,
                  PingRequest(employeeId: empId).toMap(),
                  toDeviceId: devId,
                  timeout: 2000,
                );
                online = result['alive'] == true;
              } catch (_) {
                online = false;
              }
            }
          }
        }

        _updateEmployeeOnlineState(empId, online, devId);
      }
    } catch (_) {}
  }

  /// 更新员工在线状态并发布事件
  void _updateEmployeeOnlineState(String employeeId, bool isOnline, String? deviceId) {
    final wasOnline = _employeeOnlineState[employeeId];
    if (wasOnline != isOnline) {
      _employeeOnlineState[employeeId] = isOnline;
      if (!_disposed) {
        _employeeOnlineController.add(EmployeeOnlineEvent(
          employeeId: employeeId,
          isOnline: isOnline,
          deviceId: deviceId,
        ));
      }
    }
  }

  /// 局域网断开时，标记所有远程员工离线
  void _markAllRemoteEmployeesOffline() {
    for (final entry in Map<String, bool>.from(_employeeOnlineState).entries) {
      if (entry.value) {
        _employeeOnlineState[entry.key] = false;
        if (!_disposed) {
          _employeeOnlineController.add(EmployeeOnlineEvent(
            employeeId: entry.key,
            isOnline: false,
          ));
        }
      }
    }
  }

  /// 指定设备下线时，标记该设备上所有员工离线
  void _markDeviceEmployeesOffline(String offlineDeviceId) {
    if (offlineDeviceId == deviceId) return;
    for (final entry in Map<String, bool>.from(_employeeOnlineState).entries) {
      if (!entry.value) continue;
      if (_employeeDeviceMap[entry.key] == offlineDeviceId) {
        _employeeOnlineState[entry.key] = false;
        if (!_disposed) {
          _employeeOnlineController.add(EmployeeOnlineEvent(
            employeeId: entry.key,
            isOnline: false,
            deviceId: offlineDeviceId,
          ));
        }
      }
    }
  }

  Future<void> _sendDeviceRegistration() async {
    if (_lanClient == null || !_lanClient!.isConnected) return;

    // 从 DB 读取设备配置中的名称
    String? effectiveName = deviceName;
    try {
      final config = await _deviceConfigStore.find(deviceId);
      if (config?.deviceInfo.name != null) {
        effectiveName = config!.deviceInfo.name;
      }
    } catch (_) {}

    // 收集平台信息
    String? os, osVersion, platform;
    if (Platform.isAndroid) {
      os = 'android';
      platform = 'mobile';
    } else if (Platform.isIOS) {
      os = 'ios';
      platform = 'mobile';
    } else if (Platform.isWindows) {
      os = 'windows';
      platform = 'desktop';
    } else if (Platform.isMacOS) {
      os = 'macos';
      platform = 'desktop';
    } else if (Platform.isLinux) {
      os = 'linux';
      platform = 'desktop';
    }

    final msg = LanMessage(
      type: LanMessageType.clientInfo,
      fromId: deviceId,
      fromName: effectiveName,
      content: jsonEncode({
        'deviceId': deviceId,
        'deviceName': effectiveName,
        'topic': topic,
        'os': os,
        'platform': platform,
        'ip': _localIp,
      }),
      fileName: deviceId,
      topic: topic ?? '',
    );

    _lanClient!.sendLanMessage(msg);
  }

  Future<String?> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  void _handleMessage(LanMessage msg) {
    // 广播到LAN消息流
    _lanMessageController.add(msg);

    // 调用外部处理器
    _lanMessageHandler?.call(msg);

    // 处理内部消息
    switch (msg.type) {
      case LanMessageType.rpcRequest:
        _handleRpcRequest(msg);
      case LanMessageType.rpcResponse:
        _handleRpcResponse(msg);
      case LanMessageType.rpcError:
        _handleRpcError(msg);
      case LanMessageType.rpcStreamChunk:
        _handleStreamChunk(msg);
      case LanMessageType.rpcStreamEnd:
        _handleStreamEnd(msg);
      case LanMessageType.agentStatusChanged:
      case LanMessageType.agentMessageStatusChanged:
      case LanMessageType.agentMessageReadStatusChanged:
      case LanMessageType.toolCallStart:
      case LanMessageType.toolCallResult:
        _handleAgentEvent(msg);
      case LanMessageType.agentMessageReadStatus:
        _handleRemoteReadStatus(msg);
      case LanMessageType.system:
        _handleSystemMessage(msg);
      case LanMessageType.deviceOnline:
      case LanMessageType.deviceOffline:
      case LanMessageType.deviceInfoChanged:
      case LanMessageType.deviceInfoResponse:
        _handleDeviceEventMessage(msg);
      case LanMessageType.deviceMessage:
        break;
      case LanMessageType.deviceInfoRequest:
        _handleDeviceInfoRequest(msg);
        break;
      default:
        break;
    }
  }

  void _handleRpcRequest(LanMessage msg) {
    if (_rpcServer == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? {};
      _rpcServer!.handleRequest(payload);
    } catch (_) {}
  }

  void _handleRpcResponse(LanMessage msg) {
    if (_rpcManager == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      _rpcManager!.handleResponse(payload);
    } catch (_) {}
  }

  void _handleRpcError(LanMessage msg) {
    if (_rpcManager == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      _rpcManager!.handleError(payload);
    } catch (_) {}
  }

  void _handleStreamChunk(LanMessage msg) {
    if (_rpcManager == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      _rpcManager!.handleStreamChunk(payload);
    } catch (_) {}
  }

  void _handleStreamEnd(LanMessage msg) {
    if (_rpcManager == null) return;
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final payload = content['payload'] as Map<String, dynamic>? ?? content;
      _rpcManager!.handleStreamEnd(payload);
    } catch (_) {}
  }

  void _handleAgentEvent(LanMessage msg) {
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final type = content['type'] as String?;
      final data = content['data'] as Map<String, dynamic>? ?? {};
      final employeeId = content['employeeId'] as String?;
      final fromDeviceId = msg.fromId;

      _eventController.add({
        'type': type,
        'data': data,
        'employeeId': employeeId,
        'fromId': msg.fromId,
        'fromDeviceId': msg.fromId,
      });

      // 接入通知中心
      if (employeeId != null && fromDeviceId != null) {
        if (type == 'messageStatusChanged') {
          final status = data['status'] as String?;
          final messageId = data['messageId'] as String?;

          if (status == 'completed' && messageId != null) {
            final isLocal = fromDeviceId == deviceId;
            if (!isLocal) {
              // 远程 Agent 消息：通过 onRemoteMessage 通知（自动标记未读）
              // completed 状态代表 AI 回复完成，role 固定为 assistant
              // （data['role'] 是原始追踪的用户消息 role，不能使用）
              final remoteMsg = AgentMessage(
                id: messageId,
                role: 'assistant',
                type: data['type'] as String? ?? 'text',
                content: data['content'] as String?,
                createdAt: DateTime.now(),
                status: status,
                metadata: Map<String, dynamic>.from(data),
              );
              _notificationHub.onRemoteMessage(
                message: remoteMsg,
                fromDeviceId: fromDeviceId,
                toDeviceId: deviceId,
                employeeId: employeeId,
              );
              _updateLatestMessageCache(employeeId, fromDeviceId, remoteMsg);
            }
            // 本地 Agent completed 事件由 _subscribeAgentEvents 的直接路径处理，
            // 从 agent.getSessionMessages() 获取完整 AI 回复内容后通知 notificationHub
          }
        }

        if (type == 'agentStatusChanged') {
          final status = data['status'] as String?;
          if (status != null) {
            _notificationHub.onAgentStatusChanged(
              employeeId: employeeId,
              fromDeviceId: fromDeviceId,
              status: status,
            );

            // 权限请求消息也统计未读数量
            if (status == 'waitingPermission') {
              final requestId = data['requestId'] as String?;
              final permMessageId = requestId != null
                  ? 'perm_$requestId'
                  : 'perm_${DateTime.now().millisecondsSinceEpoch}';
              final permMsg = AgentMessage(
                id: permMessageId,
                role: 'assistant',
                type: 'permission',
                content: data['description'] as String? ?? '等待权限确认',
                createdAt: DateTime.now(),
                metadata: {
                  'isPermissionRequest': true,
                  'permissionRequest': data,
                },
              );
              _notificationHub.onRemoteMessage(
                message: permMsg,
                fromDeviceId: fromDeviceId,
                toDeviceId: deviceId,
                employeeId: employeeId,
              );
              _updateLatestMessageCache(employeeId, fromDeviceId, permMsg);
            }
          }
        }

        // 处理从 Agent 广播来的已读状态变更
        if (type == 'messageReadStatusChanged') {
          final readerDeviceId = data['readerDeviceId'] as String?;
          if (readerDeviceId != null && readerDeviceId != deviceId) {
            // 其他设备的用户标记了已读，更新本设备的 notificationHub 和 DB
            _notificationHub.markAllAsRead(
              employeeId: employeeId,
              fromDeviceId: fromDeviceId,
            );
            _markMessagesAsReadInDb(employeeId, fromDeviceId);
          }
        }
      }
    } catch (_) {}
  }

  void _handleSystemMessage(LanMessage msg) {
    final content = msg.content ?? '';

    if (content == 'kicked:duplicate_login') {
      _updateState(DeviceConnectionState.disconnected);
      return;
    }

    if (content.contains('重连成功')) {
      _updateState(DeviceConnectionState.connected);
      _sendDeviceRegistration();
      _refreshDeviceList();
    }
  }

  /// 处理设备事件消息
  void _handleDeviceEventMessage(LanMessage msg) {
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final device = LanDeviceInfo.fromMap(content);

      DeviceEventType eventType;
      switch (msg.type) {
        case LanMessageType.deviceOnline:
          eventType = DeviceEventType.online;
          _deviceCache[device.id] = device.copyWith(status: 'online');
          break;
        case LanMessageType.deviceOffline:
          eventType = DeviceEventType.offline;
          _deviceCache.remove(device.id);
          // 设备下线，标记该设备上的所有员工离线
          _markDeviceEmployeesOffline(device.id);
          break;
        case LanMessageType.deviceInfoChanged:
        case LanMessageType.deviceInfoResponse:
          eventType = msg.type == LanMessageType.deviceInfoChanged
              ? DeviceEventType.infoChanged
              : DeviceEventType.infoChanged;
          // 更新缓存中的设备信息
          final existing = _deviceCache[device.id];
          _deviceCache[device.id] = device.copyWith(
            status: existing?.status ?? 'online',
          );
          break;
        default:
          return;
      }

      _deviceEventController.add(DeviceEvent(
        type: eventType,
        device: device.copyWith(
          status: eventType == DeviceEventType.offline
              ? 'offline'
              : (device.status ?? 'online'),
        ),
        timestamp: msg.timestamp,
      ));
    } catch (_) {}
  }

  /// 处理设备信息请求，回复本设备的详细信息
  void _handleDeviceInfoRequest(LanMessage msg) {
    if (_lanClient == null || !_lanClient!.isConnected) return;

    // 从 Platform 获取设备类型和操作系统
    String? os, deviceType;
    if (Platform.isAndroid) {
      os = 'android';
      deviceType = 'mobile';
    } else if (Platform.isIOS) {
      os = 'ios';
      deviceType = 'mobile';
    } else if (Platform.isWindows) {
      os = 'windows';
      deviceType = 'desktop';
    } else if (Platform.isMacOS) {
      os = 'macos';
      deviceType = 'desktop';
    } else if (Platform.isLinux) {
      os = 'linux';
      deviceType = 'desktop';
    }

    final responseInfo = LanDeviceInfo(
      id: deviceId,
      name: deviceName,
      type: deviceType,
      os: os,
      platform: deviceType,
      status: 'online',
    );

    final response = LanMessage(
      type: LanMessageType.deviceInfoResponse,
      fromId: deviceId,
      fromName: deviceName,
      toDeviceId: msg.fromId,
      content: jsonEncode(responseInfo.toMap()),
      topic: topic,
    );

    _lanClient!.sendLanMessage(response);
  }

  /// 刷新设备缓存列表
  Future<void> _refreshDeviceList() async {
    try {
      final devices = await getOnlineDevices();
      _deviceCache.clear();
      for (final device in devices) {
        // getOnlineDevices 已做了合并（HTTP name + 缓存详情 + 本机本地信息）
        // 直接存入缓存即可
        _deviceCache[device.id] = device.copyWith(status: 'online');
      }
    } catch (e) {
      // 静默处理
    }
  }

  @override
  Future<void> refreshDeviceList() async {
    await _refreshDeviceList();
  }

  @override
  Future<void> sendToDevice(String toDeviceId, LanMessage message) async {
    if (_lanClient == null || !_lanClient!.isConnected) {
      throw StateError('未连接到服务器');
    }
    final msg = LanMessage(
      type: LanMessageType.deviceMessage,
      fromId: deviceId,
      fromName: deviceName,
      toDeviceId: toDeviceId,
      content: message.content,
      fileName: message.fileName,
      topic: message.topic ?? topic,
    );
    _lanClient!.sendLanMessage(msg);
  }

  @override
  Future<void> requestDeviceInfoBroadcast() async {
    if (_lanClient == null || !_lanClient!.isConnected) {
      throw StateError('未连接到服务器');
    }
    final msg = LanMessage(
      type: LanMessageType.deviceInfoRequest,
      fromId: deviceId,
      fromName: deviceName,
      content: jsonEncode({
        'deviceId': deviceId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
      topic: topic,
    );
    _lanClient!.sendLanMessage(msg);
  }

  Future<Map<String, dynamic>> _invokeRemote(
    String toDeviceId,
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_rpcManager == null || !isConnected) {
      throw StateError('未连接到服务器');
    }

    return _rpcManager!.invoke(method, params, toDeviceId: toDeviceId);
  }

  /// 广播已读状态到其他设备
  ///
  /// 当本设备用户查看了某个员工的会话消息后，
  /// 通过 LAN 广播通知其他设备清除对应消息的未读计数。
  void _broadcastReadStatus({
    required String employeeId,
    String? fromDeviceId,
  }) {
    final lanClient = _lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    final msg = LanMessage(
      type: LanMessageType.agentMessageReadStatus,
      fromId: deviceId,
      content: jsonEncode({
        'employeeId': employeeId,
        'fromDeviceId': fromDeviceId,
        'readerDeviceId': deviceId,
      }),
      topic: topic,
    );

    lanClient.sendLanMessage(msg);
  }

  /// 处理远程设备的已读状态通知
  ///
  /// 当其他设备的用户查看了某个员工的会话消息后，
  /// 本设备收到通知后清除对应消息的未读计数。
  void _handleRemoteReadStatus(LanMessage msg) {
    try {
      final content = jsonDecode(msg.content ?? '{}') as Map<String, dynamic>;
      final employeeId = content['employeeId'] as String?;
      final fromDeviceId = content['fromDeviceId'] as String?;
      final readerDeviceId = content['readerDeviceId'] as String?;
      final global = content['global'] as bool? ?? false;

      // 只处理来自其他设备的已读通知
      if (readerDeviceId == deviceId) return;

      if (global) {
        // 全局已读：清除所有未读
        _notificationHub.markAllAsReadGlobal();
        // 同步更新本地数据库
        _markAllMessagesAsReadInDbGlobal();
      } else {
        if (employeeId == null) return;
        // 清除本设备上对应员工（和来源设备）的未读计数
        _notificationHub.markAllAsRead(
          employeeId: employeeId,
          fromDeviceId: fromDeviceId,
        );
        // 同步更新本地数据库
        _markMessagesAsReadInDb(employeeId, fromDeviceId);
      }
    } catch (_) {}
  }

  /// 广播全局已读状态到其他设备
  void _broadcastReadStatusGlobal() {
    final lanClient = _lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    final msg = LanMessage(
      type: LanMessageType.agentMessageReadStatus,
      fromId: deviceId,
      content: jsonEncode({
        'global': true,
        'readerDeviceId': deviceId,
      }),
      topic: topic,
    );

    lanClient.sendLanMessage(msg);
  }
}
