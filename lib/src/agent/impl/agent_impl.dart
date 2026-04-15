import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';
import 'package:wenzagent/wenzagent.dart';

import '../../utils/logger.dart';

part 'agent_impl_messaging.dart';
part 'agent_impl_skill.dart';

/// 消息和技能功能的基类，声明 mixin 需要访问的内部成员
abstract class _AgentImplBase implements IAgent {
  String get employeeId;
  String get deviceId;
  IChatAdapter get _chatAdapter;
  MessageProcessor? get _processor;
  set _processor(MessageProcessor? value);
  ToolRegistry get _toolRegistry;
  ToolPermissionManager get _permissionManager;
  Map<String, Completer<PermissionDecision>> get _pendingPermissions;
  Map<String, AgentPermissionRequest> get _pendingPermissionRequests;
  SkillLifecycleManager? get _skillManager;
  set _skillManager(SkillLifecycleManager? value);
  bool get _enableSkills;
  set _enableSkills(bool value);
  Map<String, Map<String, DateTime>> get _messageReceiveStatus;
  Map<String, Map<String, DateTime>> get _messageReadStatus;
  Set<String> get _callingToolIds;
  AgentStatus get _status;
  set _status(AgentStatus value);
  int get _refCount;
  set _refCount(int value);
  DateTime get _lastActiveTime;
  set _lastActiveTime(DateTime value);
  Completer<void>? get _lockCompleter;
  set _lockCompleter(Completer<void>? value);
  Completer<void>? get _warmupCompleter;
  set _warmupCompleter(Completer<void>? value);
  StreamController<AgentStateSnapshot> get _stateController;
  StreamController<AgentEvent> get _eventController;
  static Logger get _log => Logger('AgentImpl');

  void _touch();
  void _setStatus(AgentStatus newStatus);
  Future<T> _withLock<T>(Future<T> Function() operation);
  void _broadcasterBroadcastMessageStatusChange({
    required String messageId,
    required AgentMessageStatus status,
    String? error,
    required Map<String, dynamic> extraData,
  });
}

/// Agent 主体实现类（纯 Dart）
///
/// 实现 [IAgent] 接口，组装所有内部组件：
/// - [IChatAdapter]: 对话适配器（流式消息、持久化）
/// - [MessageProcessor]: 消息处理调度器
/// - [ToolRegistry]: 工具注册器
/// - [ToolPermissionManager]: 权限管理器
///
/// 设计原则：
/// - 纯 Dart，不依赖 Flutter
/// - Completer-based 加锁保证多客户端一致性
/// - 引用计数管理生命周期
class AgentImpl extends _AgentImplBase
    with _AgentImplMessaging, _AgentImplSkill
    implements IAgent {
  @override
  final String employeeId;

  /// 所属设备ID（用于数据库隔离）
  @override
  final String deviceId;

  // ===== 内部组件 =====

  /// 对话适配器
  @override
  final IChatAdapter _chatAdapter;

  /// 消息处理调度器（延迟初始化）
  @override
  MessageProcessor? _processor;

  /// 工具注册器
  @override
  final ToolRegistry _toolRegistry = ToolRegistry();

  /// 获取工具注册器（供内部模块注入回调使用）
  ToolRegistry get toolRegistry => _toolRegistry;

  /// 权限管理器
  @override
  final ToolPermissionManager _permissionManager = ToolPermissionManager();

  /// 获取权限管理器（供 AgentFactory 注入配置使用）
  ToolPermissionManager get permissionManager => _permissionManager;

  /// 待处理的权限请求 Completer
  @override
  final Map<String, Completer<PermissionDecision>> _pendingPermissions = {};

  /// 待处理的权限请求信息
  @override
  final Map<String, AgentPermissionRequest> _pendingPermissionRequests = {};

  /// 技能管理器
  @override
  SkillLifecycleManager? _skillManager;

  /// 是否已启用技能系统
  @override
  bool _enableSkills = false;

  /// 消息接收状态跟踪
  /// 当消息被设备接收后，记录接收时间和消息的更新时间
  /// 当消息状态更新时，清除接收状态，让设备可以重新接收
  @override
  final Map<String, Map<String, DateTime>> _messageReceiveStatus = {};

  /// 消息已读状态跟踪
  /// 当某个设备上的用户查看了消息后，记录已读状态
  @override
  final Map<String, Map<String, DateTime>> _messageReadStatus = {};

  /// 正在调用中的工具 callId 集合
  /// toolCallStart 时加入，toolCallResult 时移除
  @override
  final Set<String> _callingToolIds = {};

  // ===== 内部状态 =====

  /// 当前 Agent 状态
  @override
  AgentStatus _status = AgentStatus.idle;

  /// 引用计数
  @override
  int _refCount = 0;

  /// 最后活跃时间
  @override
  DateTime _lastActiveTime = DateTime.now();

  /// 异步操作锁
  @override
  Completer<void>? _lockCompleter;

  AgentImpl({required this.employeeId, required this.deviceId, required IChatAdapter chatAdapter})
    : _chatAdapter = chatAdapter;

  // ===== IAgent: 基础信息 =====

  @override
  AgentStatus get status => _status;

  @override
  bool get isAlive => _status != AgentStatus.disposed;

  @override
  int get refCount => _refCount;

  @override
  DateTime get lastActiveTime => _lastActiveTime;

  @override
  bool get isSending =>
      _status == AgentStatus.processing || _status == AgentStatus.streaming;

  @override
  bool get isStreaming => _chatAdapter.isStreaming;

  @override
  String? get currentProcessingMessageId =>
      _processor?.currentProcessingMessageId;

  @override
  List<String> get queuedMessageIds => _processor?.queuedMessageIds ?? [];

  @override
  int get queueLength => _processor?.queueLength ?? 0;

  // ===== IAgent: 生命周期 =====

  /// 延迟加载锁（防止重复 warmup）
  ///
  /// warmup 期间 sendMessage 通过此 Completer 排队等待。
  @override
  Completer<void>? _warmupCompleter;

  @override
  Future<void> initialize({
    String? employeeId,
    bool enableBuiltinTools = true,
    bool enableSkills = true,
  }) async {
    final eid = employeeId ?? this.employeeId;

    // 初始化适配器：恢复 session 配置 + 分页加载全部消息
    await _chatAdapter.initSession(employeeId: eid);

    // 注册内置工具（可选）
    if (enableBuiltinTools) {
      _toolRegistry.registerTools(BuiltinTools.all());
    }

    // 注入 TodoManageTool 回调
    _injectTodoManageCallbacks();

    // 注入 SpawnSubAgentTool 回调（工具注册器引用）
    _injectSpawnSubAgentCallbacks();

    // 技能系统由 warmup 后台加载，不在 initialize 中阻塞

    // 设置工具注册器和权限管理器到适配器
    _chatAdapter.setToolRegistry(_toolRegistry);
    _chatAdapter.setPermissionManager(_permissionManager);

    // 设置权限回调：通过事件流广播权限请求
    _permissionManager.onPermissionRequest = (request) async {
      final completer = Completer<PermissionDecision>();
      _pendingPermissions[request.requestId] = completer;
      _pendingPermissionRequests[request.requestId] = request;

      // 设置处理器状态为等待权限
      _processor?.setPermissionBlocked(request.requestId);

      // 广播权限请求事件
      _eventController.add(
        AgentEvent(
          type: AgentEventType.toolPermissionRequest,
          data: request.toMap(),
          employeeId: employeeId,
        ),
      );

      try {
        return await completer.future;
      } finally {
        _pendingPermissions.remove(request.requestId);
        _pendingPermissionRequests.remove(request.requestId);
        // 恢复处理状态
        _processor?.setPermissionBlocked(null);
      }
    };

    // 设置工具事件回调：通过事件流广播 + 维护工具调用状态
    _chatAdapter.setToolEventCallback((toolEvent) {
      switch (toolEvent) {
        case ToolCallStartEvent():
          _callingToolIds.add(toolEvent.toolCallId);
        case ToolCallResultEvent():
          _callingToolIds.remove(toolEvent.toolCallId);
      }
      final map = ToolEventMapper.toMap(toolEvent);
      _eventController.add(
        AgentEvent.fromMap({...map, 'employeeId': employeeId}),
      );
    });

    // 初始化消息处理调度器
    // 创建打断判断器
    final interruptJudge = InterruptJudge((prompt) async {
      return await _chatAdapter.invokeOnce(prompt);
    });

    _processor = MessageProcessor(
      streamMessage: (messageId, message, {cancellationToken}) {
        return _chatAdapter
            .streamMessage(message, cancellationToken: cancellationToken)
            .map(
              (r) => StreamResponse(
                content: r.content,
                error: r.error,
                isDone: r.isDone,
                type: r.type,
                data: r.data,
              ),
            );
      },
      stopStreaming: () => _chatAdapter.stopStreaming(),
      interruptJudge: interruptJudge,
    );

    // 监听处理器状态变更
    _processor!.onStateChanged = (processorStatus) {
      _syncProcessorStatus(processorStatus);
    };

    // 消息完成前回调：消息已通过 memoryManager.addMessage 同步持久化，无需等待
    _processor!.onBeforeMessageCompleted = () async {
      // no-op: addMessage 已同步写 DB
    };

    // 监听消息处理状态变更
    _processor!.onMessageStatusChanged = (messageId, msgStatus, {error}) async {
      // 附带消息完整数据，供通知中心构建预览卡片
      Map<String, dynamic> extraData = {};
      final tracked = _processor!.allTrackedMessages
          .where((m) => m.messageId == messageId)
          .firstOrNull;
      if (tracked != null) {
        final msgMap = tracked.messageData;
        extraData['role'] = msgMap['role'] ?? 'user';
        extraData['type'] = msgMap['type'] ?? 'text';
        extraData['content'] = msgMap['content'];
        if (msgMap['metadata'] != null) {
          extraData['metadata'] = msgMap['metadata'];
        }
      }
      _broadcasterBroadcastMessageStatusChange(
        messageId: messageId,
        status: msgStatus,
        error: error,
        extraData: extraData,
      );
    };

    _touch();
    _setStatus(AgentStatus.idle);
  }

  @override
  Future<void> warmup() async {
    // 双重锁：防止并发重复加载
    if (_warmupCompleter != null) return _warmupCompleter!.future;

    _warmupCompleter = Completer<void>();
    try {
      // 1. 加载全部历史消息（替换 initialize 中的最近 10 条）
      await _chatAdapter.loadRemainingMessages();

      // 2. 初始化技能系统（MCP / 持久化技能 / 文件夹技能）
      await _initSkillSystem(employeeId);
    } catch (e) {
      _AgentImplBase._log.error('warmup 失败', e);
    } finally {
      _warmupCompleter!.complete();
      _warmupCompleter = null;
    }
  }

  @override
  Future<void> dispose() async {
    if (_status == AgentStatus.disposed) return;

    _setStatus(AgentStatus.disposed);

    // 取消所有待处理的权限请求
    for (final completer in _pendingPermissions.values) {
      if (!completer.isCompleted) {
        completer.complete(PermissionDecision.deny);
      }
    }
    _pendingPermissions.clear();
    _pendingPermissionRequests.clear();

    _processor?.dispose();
    _processor = null;

    await _skillManager?.dispose();
    _skillManager = null;

    await _chatAdapter.dispose();
    await _stateController.close();
    await _eventController.close();

    _callingToolIds.clear();
  }

  // ===== IAgent: 引用计数 =====

  @override
  void attach() {
    _refCount++;
    _touch();
  }

  @override
  void detach() {
    if (_refCount > 0) _refCount--;
    _touch();
  }

  // ===== IAgent: 上下文管理 =====

  @override
  Future<void> setContext(Map<String, dynamic> contextData) async {
    _touch();
    _chatAdapter.setContext(contextData);
  }

  @override
  Future<void> clearContext() async {
    _touch();
    _chatAdapter.clearContext();
  }

  @override
  Map<String, dynamic>? getCurrentContext() {
    return _chatAdapter.currentContext;
  }

  // ===== IAgent: 模型管理 =====

  @override
  Future<void> setProvider(ProviderConfig providerConfig) async {
    _touch();
    await _withLock(() async {
      await _chatAdapter.updateProvider(providerConfig.toMap());
    });
  }

  @override
  ProviderConfig? getProviderConfig() {
    final configMap = _chatAdapter.getProviderConfig();
    return configMap != null ? ProviderConfig.fromMap(configMap) : null;
  }

  // ===== IAgent: 项目管理 =====

  @override
  Future<void> setProject(ProjectData? projectData) async {
    _touch();
    await _chatAdapter.updateProjectContext(projectData?.toMap());
  }

  @override
  String? getCurrentProjectUuid() {
    final context = _chatAdapter.currentContext;
    return context?['projectUuid'] as String?;
  }

  // ===== IAgent: 工具管理 =====

  @override
  void registerTool(AgentTool tool) {
    _toolRegistry.registerTool(tool);
  }

  @override
  void registerTools(List<AgentTool> tools) {
    _toolRegistry.registerTools(tools);
  }

  @override
  void unregisterTool(String name) {
    _toolRegistry.unregisterTool(name);
  }

  @override
  List<Map<String, dynamic>> getRegisteredTools() {
    return _toolRegistry.toMapList();
  }

  // ===== IAgent: 状态查询 =====

  @override
  List<String> getCallingToolIds() {
    return List.unmodifiable(_callingToolIds);
  }

  @override
  AgentStateSnapshot getStateSnapshot() {
    return AgentStateSnapshot(
      status: _status,
      currentProcessingMessageId: _processor?.currentProcessingMessageId,
      queuedMessageIds: _processor?.queuedMessageIds ?? [],
      isStreaming: _chatAdapter.isStreaming,
      queueLength: _processor?.queueLength ?? 0,
    );
  }

  @override
  final _stateController = StreamController<AgentStateSnapshot>.broadcast();
  @override
  final _eventController = StreamController<AgentEvent>.broadcast();

  @override
  Stream<AgentStateSnapshot> get onStateChanged => _stateController.stream;

  @override
  Stream<AgentEvent> get onEvent => _eventController.stream;

  // ===== 内部方法 =====

  /// 注入 TodoManageTool 回调
  ///
  /// 基于 TodoStore 注入所有异步回调，所有 todo 操作直接读写 SQLite。
  void _injectTodoManageCallbacks() {
    final todoTool = _toolRegistry.getTool('todo_manage');
    if (todoTool is! TodoManageTool) return;

    final todoStore = TodoStore(deviceId: deviceId);

    // 注入 employeeId
    todoTool.employeeId = employeeId;

    // 活跃 todo 查询
    todoTool.getActiveTodos = (eid) async {
      return todoStore.findActiveByEmployee(eid);
    };

    // 已完成 todo 查询
    todoTool.getCompletedTodos = (eid, {limit = 50}) async {
      return todoStore.findCompletedByEmployee(eid, limit: limit);
    };

    // 保存 todo 项
    todoTool.saveTodo = (item) async {
      todoStore.save(item);
    };

    // 更新 todo 状态
    todoTool.updateTodoStatus = (id, status) async {
      todoStore.updateStatus(id, status);
    };

    // 更新 todo 内容
    todoTool.updateTodoContent = (id, content) async {
      if (content != null) {
        todoStore.updateContent(id, content);
      }
    };

    // 软删除 todo 项
    todoTool.removeTodo = (id) async {
      todoStore.softDelete(id);
    };

    // 批量删除已完成项
    todoTool.clearCompletedTodos = (eid) async {
      todoStore.deleteCompletedByEmployee(eid);
    };

    // 移动到分组
    todoTool.moveTodoToGroup = (id, groupId) async {
      todoStore.moveToGroup(id, groupId);
    };

    // 获取所有分组
    todoTool.getGroups = (eid) async {
      return todoStore.findGroupsByEmployee(eid);
    };

    // 按名称查找分组
    todoTool.findGroupByName = (eid, name) async {
      return todoStore.findGroupByName(eid, name);
    };

    // 保存分组
    todoTool.saveGroup = (group) async {
      todoStore.saveGroup(group);
    };

    // 软删除分组
    todoTool.removeGroup = (id) async {
      todoStore.softDeleteGroup(id);
    };

    // 重命名分组
    todoTool.renameGroupFn = (id, newName) async {
      todoStore.renameGroup(id, newName);
    };

    // 广播事件
    todoTool.broadcastEvent = (type, data) {
      final eventType = type == 'todoChanged'
          ? AgentEventType.todoChanged
          : AgentEventType.todoGroupChanged;
      _eventController.add(
        AgentEvent(
          type: eventType,
          data: data,
          employeeId: employeeId,
        ),
      );
    };
  }

  // ===== IAgent: Todo 管理 =====

  @override
  Future<List<Map<String, dynamic>>> getActiveTodos() async {
    final store = TodoStore(deviceId: deviceId);
    final items = store.findActiveByEmployee(employeeId);
    return items.map((e) => e.toMap()).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getCompletedTodos({int limit = 50}) async {
    final store = TodoStore(deviceId: deviceId);
    final items = store.findCompletedByEmployee(employeeId, limit: limit);
    return items.map((e) => e.toMap()).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getTodoGroups() async {
    final store = TodoStore(deviceId: deviceId);
    final groups = store.findGroupsByEmployee(employeeId);
    return groups.map((e) => e.toMap()).toList();
  }

  @override
  Future<Map<String, dynamic>> getTodoStats() async {
    final store = TodoStore(deviceId: deviceId);
    return store.countByStatus(employeeId);
  }

  @override
  Future<void> updateTodoStatus(String todoId, String status) async {
    final store = TodoStore(deviceId: deviceId);
    store.updateStatus(todoId, status);
    _eventController.add(AgentEvent(
      type: AgentEventType.todoChanged,
      data: {'action': 'updated', 'todoId': todoId, 'status': status},
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> updateTodoContent(String todoId, String content) async {
    final store = TodoStore(deviceId: deviceId);
    store.updateContent(todoId, content);
    _eventController.add(AgentEvent(
      type: AgentEventType.todoChanged,
      data: {'action': 'updated', 'todoId': todoId},
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> deleteTodo(String todoId) async {
    final store = TodoStore(deviceId: deviceId);
    store.softDelete(todoId);
    _eventController.add(AgentEvent(
      type: AgentEventType.todoChanged,
      data: {'action': 'removed', 'todoId': todoId},
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> clearCompletedTodos() async {
    final store = TodoStore(deviceId: deviceId);
    store.deleteCompletedByEmployee(employeeId);
    _eventController.add(AgentEvent(
      type: AgentEventType.todoChanged,
      data: {'action': 'cleared'},
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> moveTodoToGroup(String todoId, String? groupId) async {
    final store = TodoStore(deviceId: deviceId);
    store.moveToGroup(todoId, groupId);
    _eventController.add(AgentEvent(
      type: AgentEventType.todoChanged,
      data: {'action': 'moved', 'todoId': todoId, 'groupId': groupId},
      employeeId: employeeId,
    ));
  }

  /// 注入 SpawnSubAgentTool 回调
  ///
  /// 所有依赖（provider 配置、权限转发、文件读取）均从 _chatAdapter /
  /// _permissionManager 直接获取，不依赖 AgentFactoryImpl。
  void _injectSpawnSubAgentCallbacks() {
    final spawnTool = _toolRegistry.getTool('spawn_sub_agent');
    if (spawnTool is! SpawnSubAgentTool) {
      _AgentImplBase._log.warn(
        'SpawnSubAgentTool not found in registry for injection. '
        'Available tools: ${_toolRegistry.toolNames}',
      );
      return;
    }

    final agentEmployeeId = employeeId;

    // 工具注册器引用
    spawnTool.getAvailableTools = () => _toolRegistry.tools;

    // 创建 SubAgentExecutor 并注入所有回调
    final executor = SubAgentExecutor();

    // Provider 配置：直接从 _chatAdapter 获取
    executor.getAgentConfig = (eid) async {
      final providerConfig = _chatAdapter.getProviderConfig();
      final context = _chatAdapter.currentContext;
      return AgentRuntimeConfig(
        providerConfig: providerConfig,
        systemPrompt: context?['systemPrompt'] as String?,
        projectContext: null,
      );
    };

    // 权限请求转发：通过 _permissionManager 转发
    executor.requestPermission = (request) async {
      if (_permissionManager.onPermissionRequest == null) {
        return PermissionDecision.deny;
      }
      return _permissionManager.onPermissionRequest!(request);
    };

    // 文件读取
    executor.readFileContent = (filePath) async {
      try {
        return await File(filePath).readAsString();
      } catch (e) {
        return null;
      }
    };

    spawnTool.executor = executor;
    spawnTool.employeeId = agentEmployeeId;
    spawnTool.readFileContent = executor.readFileContent;

    _AgentImplBase._log.info(
      'SpawnSubAgentTool fully injected (executor + registry) for $agentEmployeeId',
    );
  }

  /// 同步处理器状态到 Agent 状态
  void _syncProcessorStatus(AgentStatus processorStatus) {
    switch (processorStatus) {
      case AgentStatus.idle:
        _setStatus(AgentStatus.idle);
        break;
      case AgentStatus.processing:
      case AgentStatus.streaming:
        _setStatus(processorStatus);
        break;
      case AgentStatus.waitingPermission:
        _setStatus(AgentStatus.waitingPermission);
        break;
      case AgentStatus.disposed:
        break;
    }
  }

  /// 设置状态并广播
  @override
  void _setStatus(AgentStatus newStatus) {
    if (_status == newStatus) return;
    _status = newStatus;

    final snapshot = getStateSnapshot();
    _stateController.add(snapshot);
    _eventController.add(
      AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: snapshot.toMap(),
        employeeId: employeeId,
      ),
    );
  }

  /// 更新最后活跃时间
  @override
  void _touch() {
    _lastActiveTime = DateTime.now();
  }

  /// 异步操作加锁
  @override
  Future<T> _withLock<T>(Future<T> Function() operation) async {
    while (_lockCompleter != null) {
      await _lockCompleter!.future;
    }

    _lockCompleter = Completer<void>();
    try {
      return await operation();
    } finally {
      final completer = _lockCompleter;
      _lockCompleter = null;
      completer?.complete();
    }
  }

  /// 广播消息状态变更
  @override
  void _broadcasterBroadcastMessageStatusChange({
    required String messageId,
    required AgentMessageStatus status,
    String? error,
    Map<String, dynamic> extraData = const {},
  }) {
    if (_status == AgentStatus.disposed) return;
    _eventController.add(
      AgentEvent(
        type: AgentEventType.messageStatusChanged,
        data: {
          'messageId': messageId,
          'status': status.name,
          'error': ?error,
          ...extraData,
        },
        employeeId: employeeId,
      ),
    );
  }
}
