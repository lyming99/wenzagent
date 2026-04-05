import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../agent/adapter/persistent_chat_adapter.dart';
import '../../agent/client/agent_proxy.dart';
import '../../agent/i_agent.dart';
import '../../agent/impl/agent_impl.dart';
import '../../agent/rpc/agent_rpc_config.dart';
import '../../entity/lan_device_info.dart';
import '../../entity/lan_message.dart';
import '../../host/host_rpc_methods.dart';
import '../../lan/impl/lan_client_service_impl.dart';
import '../../persistence/persistence.dart';
import '../../rpc/remote_call_manager.dart';
import '../../rpc/remote_call_server.dart';
import '../../rpc/rpc_config.dart';
import '../../service/service.dart';
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

  /// RPC 管理器（发起调用）
  RemoteCallManager? _rpcManager;

  /// RPC 服务器（处理调用）
  RemoteCallServer? _rpcServer;

  /// 本地 Agent 实例缓存
  final Map<String, IAgent> _localAgents = {};

  /// 本地 AgentProxy 缓存
  final Map<String, AgentProxy> _localProxies = {};

  /// 远程 AgentProxy 缓存
  final Map<String, AgentProxy> _remoteProxies = {};

  /// Agent 事件订阅
  final Map<String, StreamSubscription<Map<String, dynamic>>>
  _agentEventSubscriptions = {};

  /// 连接状态控制器
  final _stateController = StreamController<DeviceConnectionState>.broadcast();

  /// Agent 事件控制器
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();

  /// LAN 消息控制器
  final _lanMessageController = StreamController<LanMessage>.broadcast();

  /// 消息订阅
  StreamSubscription<LanMessage>? _messageSubscription;

  /// LAN 消息处理器
  LanMessageHandler? _lanMessageHandler;

  /// 当前连接状态
  DeviceConnectionState _connectionState = DeviceConnectionState.disconnected;

  /// 是否已释放
  bool _disposed = false;

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

  DeviceClientImpl({
    required this.deviceId,
    this.deviceName,
    required this.host,
    this.port = 9090,
    this.topic,
  }) {
    // 初始化服务层，使用 deviceId 作为 spaceId
    _employeeManager = EmployeeManagerImpl();
    _employeeManager.setSpace(deviceId);

    _sessionManager = SessionManagerImpl();
    _messageStoreService = MessageStoreServiceImpl(spaceId: deviceId);
    _skillManager = SkillManagerImpl(spaceId: deviceId);

    // 初始化员工配置服务
    _configService = EmployeeConfigServiceImpl(
      employeeManager: _employeeManager,
      skillManager: _skillManager,
    );
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
  Stream<LanMessage> get onLanMessage => _lanMessageController.stream;

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

      // 6. 发送设备注册信息
      _sendDeviceRegistration();

      _updateState(DeviceConnectionState.connected);
    } catch (e) {
      _updateState(DeviceConnectionState.disconnected);
      rethrow;
    }
  }

  /// 注册 RPC 方法处理器
  void _registerRpcMethods() {
    // Agent相关方法
    _rpcServer!.register(AgentRpcConfig.methodSendMessage, (params) async {
      final employeeUuid = params['employeeUuid'] as String;
      final messageData = params['messageData'] as Map<String, dynamic>;
      final agent = _localAgents[employeeUuid];
      if (agent == null) {
        throw Exception('Agent not found: $employeeUuid');
      }
      final messageId = await agent.sendMessage(messageData);
      return {'messageId': messageId};
    });

    _rpcServer!.register(AgentRpcConfig.methodInterrupt, (params) async {
      final employeeUuid = params['employeeUuid'] as String;
      final agent = _localAgents[employeeUuid];
      if (agent == null) {
        throw Exception('Agent not found: $employeeUuid');
      }
      await agent.interrupt();
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetSessionList, (params) async {
      final employeeUuid = params['employeeUuid'] as String;
      final agent = _localAgents[employeeUuid];
      if (agent == null) {
        throw Exception('Agent not found: $employeeUuid');
      }
      final sessions = await agent.getSessionList();
      return {'sessions': sessions};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetSessionMessages, (
      params,
    ) async {
      final employeeUuid = params['employeeUuid'] as String?;
      final employeeId = params['employeeId'] as String?;
      final agent = employeeUuid != null ? _localAgents[employeeUuid] : null;
      if (agent == null) {
        throw Exception('Agent not found: $employeeUuid');
      }
      final uuid = employeeId ?? agent.employeeUuid;
      final messages = await agent.getSessionMessages(uuid);
      return {'messages': messages};
    });

    _rpcServer!.register(AgentRpcConfig.methodCreateSession, (params) async {
      final employeeUuid = params['employeeUuid'] as String;
      final agent = _localAgents[employeeUuid];
      if (agent == null) {
        throw Exception('Agent not found: $employeeUuid');
      }
      final employeeId = await agent.createSession();
      return {'employeeId': employeeId};
    });

    _rpcServer!.register(AgentRpcConfig.methodSwitchSession, (params) async {
      final employeeUuid = params['employeeUuid'] as String;
      final employeeId = params['employeeId'] as String;
      final agent = _localAgents[employeeUuid];
      if (agent == null) {
        throw Exception('Agent not found: $employeeUuid');
      }
      await agent.switchSession(employeeId);
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetState, (params) async {
      final employeeUuid = params['employeeUuid'] as String;
      final agent = _localAgents[employeeUuid];
      if (agent == null) {
        throw Exception('Agent not found: $employeeUuid');
      }
      return agent.getStateSnapshot().toMap();
    });

    _rpcServer!.register(AgentRpcConfig.methodSetContext, (params) async {
      final employeeUuid = params['employeeUuid'] as String;
      final contextData = params['contextData'] as Map<String, dynamic>;
      final agent = _localAgents[employeeUuid];
      if (agent == null) {
        throw Exception('Agent not found: $employeeUuid');
      }
      await agent.setContext(contextData);
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetContext, (params) async {
      final employeeUuid = params['employeeUuid'] as String;
      final agent = _localAgents[employeeUuid];
      if (agent == null) {
        throw Exception('Agent not found: $employeeUuid');
      }
      return {'context': agent.getCurrentContext()};
    });

    _rpcServer!.register(AgentRpcConfig.methodSetProvider, (params) async {
      final employeeUuid = params['employeeUuid'] as String;
      final providerConfig = params['providerConfig'] as Map<String, dynamic>;
      final agent = _localAgents[employeeUuid];
      if (agent == null) {
        throw Exception('Agent not found: $employeeUuid');
      }
      await agent.setProvider(providerConfig);
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodClearSession, (params) async {
      final employeeUuid = params['employeeUuid'] as String;
      final agent = _localAgents[employeeUuid];
      if (agent == null) {
        throw Exception('Agent not found: $employeeUuid');
      }
      await agent.clearCurrentSession();
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodPing, (params) async {
      final employeeUuid = params['employeeUuid'] as String?;
      if (employeeUuid != null) {
        final agent = _localAgents[employeeUuid];
        return {
          'alive': agent != null && agent.isAlive,
          'employeeUuid': employeeUuid,
        };
      }
      return {
        'alive': true,
        'agentCount': _localAgents.length,
        'deviceId': deviceId,
      };
    });

    _rpcServer!.register(AgentRpcConfig.methodGetOrCreateAgent, (params) async {
      final employeeUuid = params['employeeUuid'] as String;
      var agent = _localAgents[employeeUuid];
      if (agent == null) {
        throw Exception(
          'Agent not found and auto-creation not supported: $employeeUuid',
        );
      }
      return {
        'employeeUuid': employeeUuid,
        'status': agent.status.name,
      };
    });

    // 员工管理方法
    _rpcServer!.register(HostRpcConfig.methodGetEmployees, (params) async {
      final employees = await _employeeManager.getEmployees(
        keyword: params['keyword'] as String?,
        status: params['status'] as String?,
      );
      return {'employees': employees.map((e) => e.toMap()).toList()};
    });

    _rpcServer!.register(HostRpcConfig.methodGetEmployee, (params) async {
      final uuid = params['uuid'] as String;
      final employee = await _employeeManager.getEmployee(uuid);
      if (employee == null) {
        throw Exception('Employee not found: $uuid');
      }
      return {'employee': employee.toMap()};
    });

    // 会话管理方法
    _rpcServer!.register(HostRpcConfig.methodGetSessions, (params) async {
      final sessions = await _sessionManager.getAllSessions(
        includeArchived: params['includeArchived'] as bool? ?? false,
      );
      return {'sessions': sessions.map((s) => s.toMap()).toList()};
    });

    // 技能管理方法
    _rpcServer!.register(HostRpcConfig.methodGetSkills, (params) async {
      final employeeUuid = params['employeeUuid'] as String;
      final skills = await _skillManager.getSkills(employeeUuid);
      return {'skills': skills.map((s) => s.toMap()).toList()};
    });

    // 数据同步方法
    _rpcServer!.register(HostRpcConfig.methodSyncEmployees, (params) async {
      final employeesData = params['employees'] as List;
      final employees = employeesData
          .map((e) => AiEmployeeEntity.fromMap(e as Map<String, dynamic>))
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
      final sessionsData = params['sessions'] as List;
      final sessions = sessionsData
          .map(
            (s) => AiEmployeeSessionEntity.fromMap(s as Map<String, dynamic>),
          )
          .toList();
      for (final session in sessions) {
        final existing = await _sessionManager.getSession(session.employeeUuid);
        if (existing == null ||
            session.updateTime.isAfter(existing.updateTime)) {
          await _sessionManager.save(session);
        }
      }
      return {'count': sessions.length};
    });

    _rpcServer!.register(HostRpcConfig.methodSyncMessages, (params) async {
      final messagesData = params['messages'] as List;
      final messages = messagesData
          .map(
            (m) => AiEmployeeMessageEntity.fromMap(m as Map<String, dynamic>),
          )
          .toList();
      await _messageStoreService.addMessages(messages);
      return {'count': messages.length};
    });

    // 设备管理方法
    _rpcServer!.register(HostRpcConfig.methodGetOnlineDevices, (params) async {
      // 通过 Host 获取设备列表
      return {'devices': []};
    });
  }

  @override
  Future<void> disconnect() async {
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

    for (final proxy in _remoteProxies.values) {
      await proxy.dispose();
    }
    _remoteProxies.clear();

    for (final agent in _localAgents.values) {
      await agent.dispose();
    }
    _localAgents.clear();

    await _stateController.close();
    await _eventController.close();
    await _lanMessageController.close();
  }

  // ===== AgentProxy 管理 =====

  @override
  Future<AgentProxy> getOrCreateAgentProxy({
    required String employeeUuid,
    String? deviceId,
  }) async {
    // 1. 确保Session存在（只需要employeeUuid）
    final session = await _sessionManager.getOrCreateSession(employeeUuid);

    // 2. 获取员工配置
    final employee = await _employeeManager.getEmployee(employeeUuid);
    if (employee == null) {
      throw StateError('Employee not found: $employeeUuid');
    }

    // 3. 确定目标设备ID（从Employee.currentDeviceId获取）
    // 如果currentDeviceId为空，设置为当前设备（首次打开）
    String targetDeviceId;
    if (employee.currentDeviceId == null || employee.currentDeviceId!.isEmpty) {
      targetDeviceId = this.deviceId;
      await _employeeManager.updateCurrentDeviceId(employeeUuid, this.deviceId);
    } else {
      targetDeviceId = employee.currentDeviceId!;
    }

    // 4. 判断本地还是远程
    if (targetDeviceId == this.deviceId) {
      // ===== 本地会话 =====
      var proxy = _localProxies[employeeUuid];
      if (proxy != null) return proxy;

      // 创建本地 Agent 和 Proxy
      final agent = await _getOrCreateLocalAgent(
        employeeUuid,
        employee,
        session,
      );
      proxy = AgentProxy.local(employeeUuid: employeeUuid, localAgent: agent);
      proxy.attach();
      _localProxies[employeeUuid] = proxy;

      // 订阅 Agent 事件
      _subscribeAgentEvents(employeeUuid, agent);

      return proxy;
    }

    // ===== 远程会话 =====
    final key = '$targetDeviceId:$employeeUuid';
    var proxy = _remoteProxies[key];
    if (proxy != null) return proxy;

    proxy = AgentProxy.remote(
      employeeUuid: employeeUuid,
      rpcCall: (method, params) =>
          _invokeRemote(targetDeviceId, method, params),
      remoteEventStream: _eventController.stream,
    );
    _remoteProxies[key] = proxy;
    return proxy;
  }

  /// 获取或创建本地 Agent
  Future<IAgent> _getOrCreateLocalAgent(
    String employeeUuid,
    AiEmployeeEntity employee,
    AiEmployeeSessionEntity session,
  ) async {
    var agent = _localAgents[employeeUuid];
    if (agent != null) return agent;

    // 创建 ChatAdapter
    final chatAdapter = PersistentChatAdapter();
    _setupPersistCallbacks(chatAdapter, employeeUuid);

    // 创建 Agent
    agent = AgentImpl(employeeUuid: employeeUuid, chatAdapter: chatAdapter);
    await agent.initialize();

    // 设置 Provider 配置（从当前设备配置获取）
    final deviceConfig = session.getConfig(deviceId);
    if (deviceConfig?.providerConfig != null) {
      try {
        final config =
            jsonDecode(deviceConfig!.providerConfig!) as Map<String, dynamic>;
        await agent.setProvider(config);
      } catch (_) {}
    } else if (employee.provider != null && employee.provider!.isNotEmpty) {
      // 向后兼容：使用Employee的配置
      final providerConfig = <String, dynamic>{'type': employee.provider};
      if (employee.model != null) {
        providerConfig['model'] = employee.model;
      }
      if (employee.apiKey != null) {
        providerConfig['apiKey'] = employee.apiKey;
      }
      if (employee.apiBaseUrl != null) {
        providerConfig['baseUrl'] = employee.apiBaseUrl;
      }
      if (employee.modelConfig != null) {
        try {
          providerConfig['modelConfig'] = jsonDecode(employee.modelConfig!);
        } catch (_) {}
      }
      await agent.setProvider(providerConfig);
    }

    // 设置 System Prompt（优先设备配置覆盖，其次Employee默认）
    final systemPrompt =
        deviceConfig?.systemPromptOverride ?? employee.systemPrompt;
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      await agent.setContext({'systemPrompt': systemPrompt});
    }

    _localAgents[employeeUuid] = agent;
    return agent;
  }

  /// 设置持久化回调
  void _setupPersistCallbacks(
    PersistentChatAdapter adapter,
    String employeeUuid,
  ) {
    adapter.persistSession = (session) async {
      var existingSession = await _sessionManager.getSession(employeeUuid);
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
          employeeUuid,
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
      final entity = _mapToMessageEntity(message);
      await _messageStoreService.addMessage(entity);
    };

    adapter.loadSession = (employeeId) async {
      // employeeId现在实际上是employeeUuid
      final session = await _sessionManager.getSession(employeeUuid);
      if (session == null) return null;

      final deviceConfig = session.getConfig(deviceId);
      return {
        'uuid': employeeUuid, // 兼容旧格式
        'employeeUuid': session.employeeUuid,
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
      final messages = await _messageStoreService.getMessages(employeeId);
      return messages.map((m) => m.toMap()).toList();
    };

    adapter.updateMessageStatusCallback = (messageId, status, {error}) async {
      await _messageStoreService.updateMessageStatus(
        messageId,
        status.name,
        error: error,
      );
    };
  }

  AiEmployeeMessageEntity _mapToMessageEntity(Map<String, dynamic> message) {
    return AiEmployeeMessageEntity(
      uuid: message['id'] ?? '',
      employeeId: message['employeeId'] ?? '',
      role: message['role'] ?? 'user',
      type: message['type'] ?? 'text',
      content: message['content'],
      toolCallId: message['toolCallId'],
      toolName: message['toolName'],
      toolArguments: message['toolArguments'],
      toolResult: message['toolResult'],
      toolCalls: message['toolCalls'] != null
          ? jsonEncode(message['toolCalls'])
          : null,
      processingStatus: message['processingStatus'] ?? 'none',
      processingError: message['processingError'],
      createTime: message['createTime'] is DateTime
          ? message['createTime']
          : DateTime.now(),
      updateTime: DateTime.now(),
    );
  }

  /// 订阅 Agent 事件
  void _subscribeAgentEvents(String employeeUuid, IAgent agent) {
    final subscription = agent.onEvent.listen((event) {
      _broadcastAgentEvent(employeeUuid, event);
    });
    _agentEventSubscriptions[employeeUuid] = subscription;
  }

  /// 广播 Agent 事件
  void _broadcastAgentEvent(String employeeUuid, Map<String, dynamic> event) {
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
      default:
        return;
    }

    final msg = LanMessage(
      type: msgType,
      fromId: deviceId,
      content: jsonEncode({
        'employeeUuid': employeeUuid,
        'type': type,
        'data': data,
      }),
      topic: topic,
    );

    lanClient.sendLanMessage(msg);
  }

  @override
  Future<void> destroyAgentProxy(String employeeUuid) async {
    // 销毁本地代理
    final proxy = _localProxies.remove(employeeUuid);
    if (proxy != null) {
      await proxy.dispose();
    }

    // 销毁 Agent
    final agent = _localAgents.remove(employeeUuid);
    if (agent != null) {
      await agent.dispose();
    }

    // 取消事件订阅
    _agentEventSubscriptions[employeeUuid]?.cancel();
    _agentEventSubscriptions.remove(employeeUuid);
  }

  @override
  AgentProxy? getAgentProxy(String employeeUuid) {
    return _localProxies[employeeUuid];
  }

  @override
  List<AgentProxy> getLocalAgentProxies() {
    return _localProxies.values.toList();
  }

  // ===== 设备管理 =====

  @override
  Future<List<LanDeviceInfo>> getOnlineDevices() async {
    if (!isConnected) {
      throw StateError('未连接到服务器');
    }

    try {
      // 构造查询参数，包含 topic 过滤
      final queryParameters = <String, String>{};
      if (topic != null && topic!.isNotEmpty) {
        queryParameters['topic'] = topic!;
      }

      final uri = Uri.http(
        '$host:$port',
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

      return devices
          .map((d) => LanDeviceInfo.fromMap(d as Map<String, dynamic>))
          .toList();
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
            await _employeeManager.createEmployee(employee);
          } else if (employee.updateTime.isAfter(existing.updateTime)) {
            await _employeeManager.updateEmployee(employee);
          }
        }
      } catch (e) {
        // 忽略单个设备的同步错误
      }
    }
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
            session.employeeUuid,
          );
          if (existing == null ||
              session.updateTime.isAfter(existing.updateTime)) {
            await _sessionManager.save(session);
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
  }

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
      fileName: deviceId,
      topic: topic ?? '',
    );

    _lanClient!.sendLanMessage(msg);
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
        _handleAgentEvent(msg);
      case LanMessageType.system:
        _handleSystemMessage(msg);
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
      final employeeUuid = content['employeeUuid'] as String?;

      _eventController.add({
        'type': type,
        'data': data,
        'employeeUuid': employeeUuid,
        'fromId': msg.fromId,
        'fromDeviceId': msg.fromId,
      });
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
    }
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
}
