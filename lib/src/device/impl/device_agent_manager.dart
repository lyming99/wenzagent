import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../agent/adapter/llm_chat_adapter.dart';
import '../../agent/client/agent_proxy.dart';
import '../../agent/client/cached_agent_proxy.dart';
import '../../agent/entity/entity.dart';
import '../../agent/i_agent.dart';
import '../../agent/impl/agent_impl.dart';
import '../../agent/tool/builtin/schedule_task_tool.dart';
import '../../agent/tool/permission_rule.dart';
import '../../entity/lan_message.dart';
import '../../host/host_rpc_methods.dart';
import '../../persistence/persistence.dart';
import '../../service/service.dart';
import 'data_sync_manager.dart';
import 'device_connection_manager.dart';
import 'device_notification_manager.dart';
import 'device_registry.dart';
import 'device_state_holder.dart';

/// Agent 管理器
///
/// 负责本地/远程 Agent 的创建、缓存、事件订阅、持久化回调等。
class DeviceAgentManager {
  final String _deviceId;
  String? _topic;
  late final EmployeeManager _employeeManager = EmployeeManager.getInstance(_deviceId);
  late final SessionManager _sessionManager = SessionManager.getInstance(_deviceId);
  late final MessageStoreService _messageStoreService = MessageStoreService.getInstance(_deviceId);
  late final DeviceConnectionManager _connectionManager = DeviceConnectionManager.getInstance(_deviceId);
  late final DeviceStateHolder _stateHolder = DeviceStateHolder.getInstance(_deviceId);
  late final DeviceNotificationManager _notificationManager = DeviceNotificationManager.getInstance(_deviceId);
  late final DataSyncManager _dataSyncManager = DataSyncManager.getInstance(_deviceId);

  /// 本地 Agent 实例缓存
  final Map<String, IAgent> _localAgents = {};

  /// 本地 AgentProxy 缓存
  final Map<String, CachedAgentProxy> _localProxies = {};

  /// 远程 AgentProxy 缓存
  final Map<String, CachedAgentProxy> _remoteProxies = {};

  /// 正在后台同步的远程代理 key 集合
  final Set<String> _syncingRemoteKeys = {};

  /// Agent 事件订阅
  final Map<String, StreamSubscription<AgentEvent>> _agentEventSubscriptions = {};

  /// 定时任务管理器
  late final ScheduledTaskManagerImpl _scheduledTaskManager =
      ScheduledTaskManagerImpl(deviceId: _deviceId);

  DeviceAgentManager._({required String deviceId, String? topic})
      : _deviceId = deviceId,
        _topic = topic {
    _scheduledTaskManager.getAgent = (employeeId) async {
      return _localAgents[employeeId];
    };
  }

  // ===== 单例管理 =====

  static final Map<String, DeviceAgentManager> _instances = {};

  static DeviceAgentManager getInstance(String deviceId) {
    return _instances.putIfAbsent(
      deviceId,
      () => DeviceAgentManager._(deviceId: deviceId),
    );
  }

  /// 初始化配置
  void initialize({String? topic}) {
    updateConfig(topic: topic);
    _scheduledTaskManager.start();
  }

  static void removeInstance(String deviceId) {
    _instances.remove(deviceId);
  }

  // ===== 配置 =====

  void updateConfig({String? topic}) {
    if (topic != null) _topic = topic;
  }

  // ===== 公开访问 =====

  Map<String, IAgent> get localAgents => _localAgents;
  int get localAgentCount => _localAgents.length;
  Map<String, CachedAgentProxy> get localProxies => _localProxies;
  Map<String, CachedAgentProxy> get remoteProxies => _remoteProxies;

  List<String> get localAgentProxyIds => _localProxies.keys.toList();
  List<String> get remoteAgentProxyIds => _remoteProxies.keys.toList();

  ScheduledTaskManagerImpl get scheduledTaskManager => _scheduledTaskManager;

  /// 获取已创建的本地 Agent（可能为 null）
  IAgent? getLocalAgent(String employeeId) => _localAgents[employeeId];

  /// 获取或创建 AgentProxy
  Future<CachedAgentProxy> getOrCreateAgentProxy({
    required String employeeId,
    String? deviceId,
    AiEmployeeEntity? employee,
    bool autoCreateSession = true,
  }) async {
    final sw = Stopwatch()..start();
    // 先检查会话是否已被有效删除，避免 getOrCreateSession 自动恢复已删除的会话
    AiEmployeeSessionEntity? existingSession = await _sessionManager.getSession(employeeId);
    final bool isSessionEffectivelyDeleted = existingSession != null &&
        existingSession.deleted == 1 &&
        existingSession.isEffectivelyDeleted();

    final results = await Future.wait<dynamic>([
      (autoCreateSession && !isSessionEffectivelyDeleted)
          ? _sessionManager.getOrCreateSession(employeeId)
          : _sessionManager.getSession(employeeId),
      employee != null
          ? Future.value(employee)
          : _employeeManager.getEmployee(employeeId),
    ]);
    print('[DeviceAgentManager] Future.wait (session+employee): ${sw.elapsedMilliseconds}ms');
    var session = results[0] as AiEmployeeSessionEntity?;
    employee = results[1] as AiEmployeeEntity?;
    if (employee == null) {
      throw StateError('Employee not found: $employeeId');
    }

    session ??= AiEmployeeSessionEntity(
      employeeId: employeeId,
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );

    // 确定目标设备ID
    String targetDeviceId;
    if (employee.currentDeviceId != null && employee.currentDeviceId!.isNotEmpty) {
      targetDeviceId = employee.currentDeviceId!;
    } else if (deviceId != null && deviceId.isNotEmpty) {
      targetDeviceId = deviceId;
    } else {
      targetDeviceId = _deviceId;
      if (employee.currentDeviceId == null || employee.currentDeviceId!.isEmpty) {
        await _employeeManager.updateCurrentDeviceId(employeeId, _deviceId);
      }
    }

    if (targetDeviceId == _deviceId) {
      // ===== 本地会话 =====
      var cachedProxy = _localProxies[employeeId];
      if (cachedProxy != null) return cachedProxy;

      sw.reset();
      final agent = await _getOrCreateLocalAgent(employeeId, employee, session);
      print('[DeviceAgentManager] _getOrCreateLocalAgent: ${sw.elapsedMilliseconds}ms');
      final proxy = AgentProxy.local(
        employeeId: employeeId,
        deviceId: targetDeviceId,
        localAgent: agent,
      );

      cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: _messageStoreService,
        deviceId: targetDeviceId,
        employeeId: employeeId,
        onMarkAsRead: (empId, fromDevId) {
          _stateHolder.notificationHub.markAllAsRead(employeeId: empId, fromDeviceId: fromDevId);
          _broadcastReadStatus(employeeId: empId, fromDeviceId: fromDevId);
          // DB 更新后用 SQL 统计修正内存缓存
          _notificationManager.markMessagesAsReadInDb(empId, fromDevId).then((dbUnreadCount) {
            if (dbUnreadCount >= 0) {
              _stateHolder.notificationHub.restoreUnreadCount(
                employeeId: empId,
                count: dbUnreadCount,
              );
            }
          });
        },
        shouldSaveAsReadCallback: () => _notificationManager.isSessionOpen(employeeId: employeeId),
      );

      _localProxies[employeeId] = cachedProxy;
      proxy.attach();

      _subscribeAgentEvents(employeeId, agent);

      cachedProxy.initialize();
      agent.warmup();

      return cachedProxy;
    }

    // ===== 远程会话 =====
    final key = '$targetDeviceId:$employeeId';
    var cachedProxy = _remoteProxies[key];
    if (cachedProxy != null) {
      print('[DeviceAgentManager] remote proxy cache HIT');
      return cachedProxy;
    }

    print('[DeviceAgentManager] remote proxy cache MISS, creating...');
    sw.reset();
    final proxy = AgentProxy.remote(
      employeeId: employeeId,
      deviceId: targetDeviceId,
      rpcCall: (method, params) =>
          _connectionManager.invokeRemote(targetDeviceId, method, params),
      remoteEventStream: _stateHolder.onAgentEvent,
    );
    print('[DeviceAgentManager] AgentProxy.remote created: ${sw.elapsedMilliseconds}ms');

    cachedProxy = CachedAgentProxy(
      proxy: proxy,
      messageStore: _messageStoreService,
      deviceId: targetDeviceId,
      employeeId: employeeId,
      onMarkAsRead: (empId, fromDevId) {
        _stateHolder.notificationHub.markAllAsRead(employeeId: empId, fromDeviceId: fromDevId);
        _broadcastReadStatus(employeeId: empId, fromDeviceId: fromDevId);
        // DB 更新后用 SQL 统计修正内存缓存
        _notificationManager.markMessagesAsReadInDb(empId, fromDevId).then((dbUnreadCount) {
          if (dbUnreadCount >= 0) {
            _stateHolder.notificationHub.restoreUnreadCount(
              employeeId: empId,
              count: dbUnreadCount,
            );
          }
        });
      },
      shouldSaveAsReadCallback: () => _notificationManager.isSessionOpen(employeeId: employeeId),
    );

    _remoteProxies[key] = cachedProxy;

    final remoteProxy = cachedProxy;
    cachedProxy.initialize().then((_) {
      _backgroundSyncRemoteProxy(key, employeeId, targetDeviceId, remoteProxy);
    });

    return cachedProxy;
  }

  /// 销毁 AgentProxy（同时清理本地和远程代理缓存）
  ///
  /// [targetDeviceId] 可选参数，如果指定，则只销毁指向该设备的远程代理。
  /// 不指定时，销毁所有代理（向后兼容）。
  ///
  /// [keepLocalAgent] 如果为 true，保留本地 Agent 实例和事件订阅不销毁。
  /// 用于设备切换场景：切换设备时只需要清理远程代理缓存，不中断本地运行的 Agent。
  Future<void> destroyAgentProxy(String employeeId, {
    String? targetDeviceId,
    bool keepLocalAgent = false,
  }) async {
    // 清理本地代理
    if (!keepLocalAgent) {
      final localProxy = _localProxies.remove(employeeId);
      if (localProxy != null) {
        await localProxy.dispose();
      }

      // 清理本地 Agent 实例
      final agent = _localAgents.remove(employeeId);
      if (agent != null) {
        await agent.dispose();
      }

      _agentEventSubscriptions[employeeId]?.cancel();
      _agentEventSubscriptions.remove(employeeId);
    } else {
      // keepLocalAgent=true：只清理本地代理缓存（UI层），保留 Agent 实例和事件订阅
      _localProxies.remove(employeeId);
    }

    // 清理远程代理
    if (targetDeviceId != null) {
      // 只销毁指向指定设备的远程代理
      final key = '$targetDeviceId:$employeeId';
      final remoteProxy = _remoteProxies.remove(key);
      if (remoteProxy != null) {
        await remoteProxy.dispose();
      }
    } else {
      // 清理所有远程代理（不同 targetDeviceId 下可能有多个缓存）
      final remoteKeysToRemove = _remoteProxies.keys
          .where((key) => key.endsWith(':$employeeId'))
          .toList();
      for (final key in remoteKeysToRemove) {
        final remoteProxy = _remoteProxies.remove(key);
        if (remoteProxy != null) {
          await remoteProxy.dispose();
        }
      }
    }
  }

  /// 获取已创建的 AgentProxy
  CachedAgentProxy? getAgentProxy(String employeeId) {
    final localProxy = _localProxies[employeeId];
    if (localProxy != null) return localProxy;

    for (final entry in _remoteProxies.entries) {
      if (entry.key.endsWith(':$employeeId')) {
        return entry.value;
      }
    }
    return null;
  }

  List<CachedAgentProxy> getLocalAgentProxies() => _localProxies.values.toList();
  List<CachedAgentProxy> getRemoteAgentProxies() => _remoteProxies.values.toList();
  List<CachedAgentProxy> getAllAgentProxies() =>
      [..._localProxies.values, ..._remoteProxies.values];

  /// 确保 RPC 调用所需的本地 Agent 存在（懒加载）
  Future<IAgent> ensureLocalAgentForRpc(String employeeId) async {
    var agent = _localAgents[employeeId];
    if (agent != null) return agent;

    var employee = await _employeeManager.getEmployee(employeeId);
    if (employee == null) {
      // 同步优先：尝试从在线设备拉取员工数据
      employee = await _fetchEmployeeFromRemote(employeeId);
      if (employee == null) {
        // 所有在线设备都没有该员工，才创建默认占位
        final now = DateTime.now();
        employee = await _employeeManager.createEmployee(
          AiEmployeeEntity(
            uuid: employeeId,
            name: 'AI Assistant',
            role: 'assistant',
            status: 'active',
            deviceId: _deviceId,
            createTime: now,
            updateTime: now,
          ),
        );
      }
    }

    final session = await _sessionManager.getSession(employeeId) ??
        AiEmployeeSessionEntity(
          employeeId: employeeId,
          createTime: DateTime.now(),
          updateTime: DateTime.now(),
        );
    agent = await _getOrCreateLocalAgent(employeeId, employee, session);

    agent.warmup();

    if (!_agentEventSubscriptions.containsKey(employeeId)) {
      _subscribeAgentEvents(employeeId, agent);
    }

    return agent;
  }

  /// 从在线远程设备拉取指定员工数据
  ///
  /// 遍历在线设备，逐个尝试 RPC 调用获取员工信息。
  /// 找到后保存到本地并返回，找不到返回 null。
  Future<AiEmployeeEntity?> _fetchEmployeeFromRemote(String employeeId) async {
    final deviceRegistry = DeviceRegistry.getInstance(_deviceId);
    final devices = await deviceRegistry.getOnlineDevices();
    for (final device in devices) {
      if (device.id == _deviceId) continue;
      try {
        final result = await _connectionManager.invokeRemote(
          device.id,
          HostRpcConfig.methodGetEmployee,
          {'uuid': employeeId},
        );
        final data = result['employee'] as Map<String, dynamic>?;
        if (data != null) {
          final employee = AiEmployeeEntity.fromMap(data);
          // 保存到本地（保留原始 deviceId）
          await _employeeManager.saveEmployee(employee);
          return employee;
        }
      } catch (_) {
        // 该设备没有此员工，尝试下一个
      }
    }
    return null;
  }

  /// 热更新已运行 Agent 的权限配置
  void reloadPermissionConfig(String employeeId, AiEmployeeEntity employee) {
    final agent = _localAgents[employeeId];
    if (agent == null) return;

    final impl = agent as AgentImpl;
    final manager = impl.permissionManager;

    if (employee.permissionConfig != null &&
        employee.permissionConfig!.isNotEmpty) {
      final config =
          PermissionConfig.fromJsonString(employee.permissionConfig!);
      manager.configure(config);
      print('[DeviceAgentManager] Permission config reloaded for $employeeId'
          ' (${config.whitelist.length} whitelist, ${config.blacklist.length} blacklist rules)');
    }
  }

  /// 广播 Agent 事件到 LAN
  void broadcastAgentEvent(String employeeId, AgentEvent event) {
    final lanClient = _connectionManager.lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    final type = event.type;
    final data = event.data;

    LanMessageType msgType;
    switch (type) {
      case AgentEventType.agentStatusChanged:
        msgType = LanMessageType.agentStatusChanged;
      case AgentEventType.messageStatusChanged:
        msgType = LanMessageType.agentMessageStatusChanged;
      case AgentEventType.messageReadStatusChanged:
        msgType = LanMessageType.agentMessageReadStatusChanged;
      case AgentEventType.toolCallStart:
        msgType = LanMessageType.toolCallStart;
      case AgentEventType.toolCallResult:
        msgType = LanMessageType.toolCallResult;
      case AgentEventType.sessionCleared:
        msgType = LanMessageType.agentSessionCleared;
      default:
        return;
    }

    final msg = LanMessage(
      type: msgType,
      fromId: _deviceId,
      content: jsonEncode({
        'employeeId': employeeId,
        'type': type.value,
        'data': data,
      }),
      topic: _topic,
    );

    lanClient.sendLanMessage(msg);
  }

  /// 广播已读状态到 LAN
  void _broadcastReadStatus({
    required String employeeId,
    String? fromDeviceId,
  }) {
    final lanClient = _connectionManager.lanClient;
    if (lanClient == null || !lanClient.isConnected) return;

    final msg = LanMessage(
      type: LanMessageType.agentMessageReadStatus,
      fromId: _deviceId,
      content: jsonEncode({
        'employeeId': employeeId,
        'fromDeviceId': fromDeviceId,
        'readerDeviceId': _deviceId,
      }),
      topic: _topic,
    );

    lanClient.sendLanMessage(msg);
  }



  /// 处理收到的广播消息（客户端侧）
  ///
  /// 收到广播消息后：
  /// 1. 更新通知状态（未读计数 + UI 事件）
  /// 2. 触发基于水位线的 LSN 增量拉取
  /// 3. 由增量拉取统一处理消息存储和水位线更新
  Future<void> onUnreceivedMessagesBatch({
    required String employeeId,
    required String fromDeviceId,
    required List<Map<String, dynamic>> messageMaps,
  }) async {
    if (messageMaps.isEmpty) return;

    print('[DeviceAgentManager] 收到来自设备 $fromDeviceId 的广播消息通知'
        '（员工: $employeeId, ${messageMaps.length} 条）');

    final messages = messageMaps.map((m) => AgentMessage.fromMap(m)).toList();

    // 1. 更新通知状态（未读追踪 + UI 事件）
    for (final message in messages) {
      if (message.role == 'assistant') {
        _stateHolder.notificationHub.onRemoteMessage(
          message: message,
          fromDeviceId: fromDeviceId,
          toDeviceId: _deviceId,
          employeeId: employeeId,
        );
      }
    }

    // 2. 更新最新消息缓存
    if (messages.isNotEmpty) {
      final latestMsg = messages.reduce(
        (a, b) => a.createdAt.isAfter(b.createdAt) ? a : b,
      );
      _notificationManager.updateLatestMessageCache(
        employeeId, fromDeviceId, latestMsg,
      );
    }

    // 3. 触发基于水位线的增量拉取，统一处理消息存储和水位线更新
    final proxy = getAgentProxy(employeeId);
    if (proxy != null) {
      try {
        await proxy.syncWithRemote();
        print('[DeviceAgentManager] 增量同步完成: employeeId=$employeeId');
      } catch (e) {
        print('[DeviceAgentManager] 增量同步失败: employeeId=$employeeId, $e');
      }
    } else {
      print('[DeviceAgentManager] 未找到代理，跳过增量同步: employeeId=$employeeId');
    }
  }

  /// 释放所有资源
  Future<void> dispose() async {
    _scheduledTaskManager.dispose();

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
  }

  // ===== 内部方法 =====

  Future<void> _backgroundSyncRemoteProxy(
    String cacheKey,
    String employeeId,
    String targetDeviceId,
    CachedAgentProxy cachedProxy,
  ) async {
    if (_syncingRemoteKeys.contains(cacheKey)) return;
    _syncingRemoteKeys.add(cacheKey);

    try {
      await _dataSyncManager.syncEmployeeToDevice(employeeId: employeeId, targetDeviceId: targetDeviceId);
      await cachedProxy.syncFromRemote();
    } catch (e) {
      print('[DeviceAgentManager] 后台同步远程代理失败: $e');
    } finally {
      _syncingRemoteKeys.remove(cacheKey);
    }
  }

  Future<IAgent> _getOrCreateLocalAgent(
    String employeeId,
    AiEmployeeEntity employee,
    AiEmployeeSessionEntity session,
  ) async {
    var agent = _localAgents[employeeId];
    if (agent != null) return agent;

    final chatAdapter = LlmChatAdapter();
    _setupAdapter(chatAdapter, employeeId);

    final deviceId = employee.currentDeviceId;
    if (deviceId == null || deviceId.isEmpty) {
      throw StateError('员工 $employeeId 的 currentDeviceId 为空，无法创建 Agent');
    }

    agent = AgentImpl(employeeId: employeeId, deviceId: deviceId, chatAdapter: chatAdapter);
    await agent.initialize(employeeId: employeeId);

    _injectScheduleTaskCallbacks(agent, employeeId);

    // 设置 Provider 配置
    final deviceConfig = session.getConfig(_deviceId);
    if (deviceConfig?.providerConfig != null) {
      try {
        final configMap =
            jsonDecode(deviceConfig!.providerConfig!) as Map<String, dynamic>;
        final config = ProviderConfig.fromMap(configMap);
        await agent.setProvider(config);
      } catch (_) {}
    } else if (employee.provider != null && employee.provider!.isNotEmpty) {
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

    // 设置 System Prompt
    final systemPrompt =
        deviceConfig?.systemPromptOverride ?? employee.systemPrompt;
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      await agent.setContext({'systemPrompt': systemPrompt});
    }

    // 设置项目
    if (employee.projectUuid != null && employee.projectUuid!.isNotEmpty) {
      await agent.setProject(ProjectData(
        projectUuid: employee.projectUuid,
        projectName: employee.projectName,
        projectContext: employee.projectContext,
        workPath: employee.workPath,
      ));
    }

    // 注入权限配置
    _injectPermissionConfig(agent, employee);

    _localAgents[employeeId] = agent;
    return agent;
  }

  void _injectPermissionConfig(IAgent agent, AiEmployeeEntity employee) {
    final impl = agent as AgentImpl;
    final manager = impl.permissionManager;

    if (employee.permissionConfig != null &&
        employee.permissionConfig!.isNotEmpty) {
      final config =
          PermissionConfig.fromJsonString(employee.permissionConfig!);
      manager.configure(config);
      print('[DeviceAgentManager] Permission config injected for ${employee.uuid}'
          ' (${config.whitelist.length} whitelist, ${config.blacklist.length} blacklist rules)');
    }

    manager.onConfigChanged = (newConfig) async {
      try {
        final updatedEmployee = await _employeeManager.getEmployee(employee.uuid);
        if (updatedEmployee != null) {
          final saved = updatedEmployee.copyWith(
            permissionConfig: newConfig.toJsonString(),
            updateTime: DateTime.now(),
          );
          await _employeeManager.updateEmployee(saved);
          print('[DeviceAgentManager] Permission config saved for ${employee.uuid}');
        }
      } catch (e) {
        print('[DeviceAgentManager] Failed to save permission config: $e');
      }
    };
  }

  void _injectScheduleTaskCallbacks(IAgent agent, String agentEmployeeId) {
    final impl = agent as AgentImpl;
    final scheduleTool = impl.toolRegistry.getTool('schedule_task');
    if (scheduleTool is! ScheduleTaskTool) return;

    final now = DateTime.now();

    scheduleTool.onCreateTask = (data) async {
      final taskType = data['taskType'] as String? ?? 'reminder';
      final repeatType = data['repeatType'] as String? ?? 'recurring';
      final scheduleExpr = data['schedule'] as String;
      final scheduleType = _parseScheduleType(scheduleExpr);

      final entity = AiScheduledTaskEntity(
        uuid: const Uuid().v4(),
        employeeId: agentEmployeeId,
        name: data['name'] as String? ?? 'Scheduled task',
        scheduleType: scheduleType,
        scheduleExpression: scheduleExpr,
        repeatType: repeatType,
        taskType: taskType,
        taskConfig: jsonEncode({
          'action': 'sendMessage',
          'message': data['message'],
        }),
        createTime: now,
        updateTime: now,
      );
      final created = await _scheduledTaskManager.createTask(entity);
      return {
        'taskId': created.uuid,
        'name': created.name,
        'taskType': created.taskType,
        'schedule': created.scheduleExpression,
        'nextExecutionAt': created.nextExecutionAt?.toIso8601String(),
      };
    };

    scheduleTool.onListTasks = ({String? employeeId}) async {
      final tasks = await _scheduledTaskManager
          .getTasks(employeeId: employeeId ?? agentEmployeeId);
      return tasks.map((t) => <String, dynamic>{
        'taskId': t.uuid,
        'name': t.name,
        'schedule': t.scheduleExpression,
        'nextExecutionAt': t.nextExecutionAt?.toIso8601String(),
        'enabled': t.isEnabled,
      }).toList();
    };

    scheduleTool.onCancelTask = (taskId) async {
      try {
        await _scheduledTaskManager.deleteTask(taskId);
        return true;
      } catch (_) {
        return false;
      }
    };

    print('[DeviceAgentManager] ScheduleTaskTool callbacks injected for $agentEmployeeId');
  }

  static String _parseScheduleType(String expression) {
    if (expression.contains(' ') || expression.contains('*')) {
      return 'cron';
    }
    return 'interval';
  }

  void _setupAdapter(
    LlmChatAdapter adapter,
    String employeeId,
  ) {
    adapter.configurePersistence(
      messageStore: _messageStoreService,
      deviceId: _deviceId,
    );
    adapter.deviceId = _deviceId;

    adapter.shouldMarkAsRead = (empId) =>
      _notificationManager.currentOpenSession?.employeeId == empId;

    // 会话清空回调：设置 clearSeq = lastSeq + 清理通知
    adapter.onSessionCleared = (empId, maxSeq) async {
      if (maxSeq > 0) {
        final watermarkStore = SyncWatermarkStore(deviceId: _deviceId);
        watermarkStore.setClearSeq(empId, maxSeq, deviceId: _deviceId);
        watermarkStore.resetLastSeq(empId, maxSeq, deviceId: _deviceId);
      }
      _stateHolder.notificationHub.markAllAsRead(employeeId: empId);
      _notificationManager.clearLatestMessageCache(empId);
    };

    // Provider 配置变更回调
    adapter.onProviderConfigChanged = (providerConfig) async {
      await _sessionManager.updateDeviceConfig(
        employeeId, _deviceId,
        providerConfig: jsonEncode(providerConfig),
      );
    };
  }

  void _subscribeAgentEvents(String employeeId, IAgent agent) {
    final subscription = agent.onEvent.listen((event) {
      // 始终广播到 LAN
      broadcastAgentEvent(employeeId, event);

      // 始终添加到本地 eventController，确保本地 UI 能接收到所有事件
      _stateHolder.eventController.add(AgentEvent(
        type: event.type,
        data: event.data,
        employeeId: employeeId,
        fromDeviceId: _deviceId,
      ));

      final type = event.type;
      final data = event.data;

      if (type != AgentEventType.messageStatusChanged) return;
      final status = data['status'] as String?;
      final messageId = data['messageId'] as String?;

      if (status == 'queued' && messageId != null) {
        final metadata = data['metadata'] as Map<String, dynamic>?;
        final isScheduledTrigger = metadata?['trigger'] == 'scheduled_task';
        if (!isScheduledTrigger) {
          final content = data['content'] as String?;
          if (content != null && content.isNotEmpty) {
            final msg = AgentMessage(
              id: messageId,
              role: data['role'] as String? ?? 'user',
              type: data['type'] as String? ?? 'text',
              content: content,
              createdAt: DateTime.now(),
              status: status,
              metadata: Map<String, dynamic>.from(data)..['deviceId'] = _deviceId,
            );
            _stateHolder.notificationHub.onLocalMessage(
              message: msg,
              employeeId: employeeId,
            );
            _notificationManager.updateLatestMessageCache(employeeId, _deviceId, msg);
          }
        }
      }

      if (status == 'completed') {
        agent.getSessionMessagesByUserCount(userMessageLimit: 1).then((messages) {
          if (messages.isEmpty) return;
          final lastAssistant = messages.lastWhere(
            (m) => m.role == 'assistant',
            orElse: () => messages.last,
          );
          final msg = AgentMessage(
            id: lastAssistant.id,
            role: lastAssistant.role,
            type: lastAssistant.type,
            content: lastAssistant.content,
            createdAt: lastAssistant.createdAt,
            status: status,
            metadata: Map<String, dynamic>.from(data)..['deviceId'] = _deviceId,
          );
          final autoRead = _stateHolder.notificationHub.shouldAutoMarkAsReadCallback?.call(
                employeeId: employeeId,
                fromDeviceId: _deviceId,
              ) ?? false;
          _stateHolder.notificationHub.onLocalMessage(
            message: msg,
            employeeId: employeeId,
            markUnread: !autoRead,
            autoRead: autoRead,
          );
          _notificationManager.updateLatestMessageCache(employeeId, _deviceId, msg);
        }).catchError((_) {});
      }
    });
    _agentEventSubscriptions[employeeId] = subscription;
  }
}
