import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../agent/adapter/persistent_chat_adapter.dart';
import '../../agent/agent_state.dart';
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
  final String? deviceName;

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

  /// 连接操作锁，防止并发连接/断开/重连导致的问题
  final _connectionLock = _AsyncLock();

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

      // 6. 发送设备注册信息
      _sendDeviceRegistration();

      _updateState(DeviceConnectionState.connected);
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
      final employeeId = params['employeeId'] as String;
      final messageData = params['messageData'] as Map<String, dynamic>;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      final messageId = await agent.sendMessage(messageData);
      return {'messageId': messageId};
    });

    _rpcServer!.register(AgentRpcConfig.methodInterrupt, (params) async {
      final employeeId = params['employeeId'] as String;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      await agent.interrupt();
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetSessionMessages, (
      params,
    ) async {
      final employeeId = params['employeeId'] as String?;
      final agent = employeeId != null ? _localAgents[employeeId] : null;
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      final uuid = employeeId ?? agent.employeeId;
      final messages = await agent.getSessionMessages(uuid);
      return {'messages': messages};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetState, (params) async {
      final employeeId = params['employeeId'] as String;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      return agent.getStateSnapshot().toMap();
    });

    _rpcServer!.register(AgentRpcConfig.methodSetContext, (params) async {
      final employeeId = params['employeeId'] as String;
      final contextData = params['contextData'] as Map<String, dynamic>;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      await agent.setContext(contextData);
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetContext, (params) async {
      final employeeId = params['employeeId'] as String;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      return {'context': agent.getCurrentContext()};
    });

    _rpcServer!.register(AgentRpcConfig.methodSetProvider, (params) async {
      final employeeId = params['employeeId'] as String;
      final providerConfig = params['providerConfig'] as Map<String, dynamic>;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      await agent.setProvider(providerConfig);
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodClearSession, (params) async {
      final employeeId = params['employeeId'] as String;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      await agent.clearCurrentSession();
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodPing, (params) async {
      final employeeId = params['employeeId'] as String?;
      if (employeeId != null) {
        final agent = _localAgents[employeeId];
        return {
          'alive': agent != null && agent.isAlive,
          'employeeId': employeeId,
        };
      }
      return {
        'alive': true,
        'agentCount': _localAgents.length,
        'deviceId': deviceId,
      };
    });

    _rpcServer!.register(AgentRpcConfig.methodGetOrCreateAgent, (params) async {
      final employeeId = params['employeeId'] as String;
      var agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception(
          'Agent not found and auto-creation not supported: $employeeId',
        );
      }
      return {
        'employeeId': employeeId,
        'status': agent.status.name,
      };
    });

    // 消息撤回
    _rpcServer!.register(AgentRpcConfig.methodRevokeMessage, (params) async {
      final employeeId = params['employeeId'] as String;
      final messageId = params['messageId'] as String;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      await agent.revokeMessage(messageId);
      return {};
    });

    // 权限管理方法
    _rpcServer!.register(AgentRpcConfig.methodGetPendingPermission, (params) async {
      final employeeId = params['employeeId'] as String;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      final request = agent.getPendingPermissionRequest();
      return {'request': request?.toMap()};
    });

    _rpcServer!.register(AgentRpcConfig.methodRespondPermission, (params) async {
      final employeeId = params['employeeId'] as String;
      final requestId = params['requestId'] as String;
      final decisionStr = params['decision'] as String;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      
      final decision = PermissionDecision.values.firstWhere(
        (d) => d.name == decisionStr,
        orElse: () => PermissionDecision.deny,
      );
      
      await agent.respondToPermission(requestId, decision);
      return {};
    });

    // 上下文管理
    _rpcServer!.register(AgentRpcConfig.methodClearContext, (params) async {
      final employeeId = params['employeeId'] as String;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      await agent.clearContext();
      return {};
    });

    // 模型管理
    _rpcServer!.register(AgentRpcConfig.methodGetProvider, (params) async {
      final employeeId = params['employeeId'] as String;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      return {'providerConfig': agent.getProviderConfig()};
    });

    // 项目管理
    _rpcServer!.register(AgentRpcConfig.methodSetProject, (params) async {
      final employeeId = params['employeeId'] as String;
      final projectData = params['projectData'] as Map<String, dynamic>?;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      await agent.setProject(projectData);
      return {};
    });

    _rpcServer!.register(AgentRpcConfig.methodGetProjectUuid, (params) async {
      final employeeId = params['employeeId'] as String;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      return {'projectUuid': agent.getCurrentProjectUuid()};
    });

    // 工具管理
    _rpcServer!.register(AgentRpcConfig.methodGetRegisteredTools, (params) async {
      final employeeId = params['employeeId'] as String;
      final agent = _localAgents[employeeId];
      if (agent == null) {
        throw Exception('Agent not found: $employeeId');
      }
      return {'tools': agent.getRegisteredTools()};
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
      final employeeId = params['employeeId'] as String;
      final skills = await _skillManager.getSkills(employeeId);
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
        final existing = await _sessionManager.getSession(session.employeeId);
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
    await _connectionLock.synchronized(() => _disconnectInternal());
  }

  /// 内部断开连接方法（无锁，供reconnect调用）
  Future<void> _disconnectInternal() async {
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
      var proxy = _localProxies[employeeId];
      if (proxy != null) return proxy;

      // 创建本地 Agent 和 Proxy
      final agent = await _getOrCreateLocalAgent(
        employeeId,
        employee,
        session,
      );
      proxy = AgentProxy.local(
        employeeId: employeeId,
        deviceId: targetDeviceId,
        localAgent: agent,
      );
      proxy.attach();
      _localProxies[employeeId] = proxy;

      // 订阅 Agent 事件
      _subscribeAgentEvents(employeeId, agent);

      return proxy;
    }

    // ===== 远程会话 =====
    final key = '$targetDeviceId:$employeeId';
    var proxy = _remoteProxies[key];
    if (proxy != null) return proxy;

    proxy = AgentProxy.remote(
      employeeId: employeeId,
      deviceId: targetDeviceId,
      rpcCall: (method, params) =>
          _invokeRemote(targetDeviceId, method, params),
      remoteEventStream: _eventController.stream,
    );
    _remoteProxies[key] = proxy;
    return proxy;
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
      final entity = _mapToMessageEntity(message);
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
      return messages.map((m) => m.toMap()).toList();
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
  void _subscribeAgentEvents(String employeeId, IAgent agent) {
    final subscription = agent.onEvent.listen((event) {
      _broadcastAgentEvent(employeeId, event);
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
  AgentProxy? getAgentProxy(String employeeId) {
    return _localProxies[employeeId];
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
            // 本地不存在 → 创建（包括已删除的会话）
            await _sessionManager.save(session);
          } else {
            // 本地已存在 → 判断是否需要更新
            
            // 优先比较 deletedTime（如果任一会话被删除）
            // 注意：Session 实体目前没有 deletedTime 字段，使用 updateTime 代替
            if (session.deleted == 1 || existing.deleted == 1) {
              // 至少一方被删除，比较 updateTime（因为 deleted 时会更新 updateTime）
              if (session.updateTime.isAfter(existing.updateTime)) {
                // 远程删除更新 → 同步删除状态
                await _sessionManager.save(session);
              }
              // 否则保留本地的删除状态
            } else {
              // 都未删除，正常比较 updateTime
              if (session.updateTime.isAfter(existing.updateTime)) {
                // 远程更新 → 更新本地
                await _sessionManager.save(session);
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
      final employeeId = content['employeeId'] as String?;

      _eventController.add({
        'type': type,
        'data': data,
        'employeeId': employeeId,
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
