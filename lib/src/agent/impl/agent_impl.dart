import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:wenzagent/wenzagent.dart';

import '../../device/device_client.dart';
import '../../device/impl/data_sync_manager.dart';
import '../../utils/logger.dart';
import '../tool/builtin/bg_command_tool.dart';
import '../tool/builtin/command_session_pool.dart';
import '../tool/builtin/send_file_message_tool.dart';
import '../tool/builtin/spec_manage_tool.dart';
import '../tool/builtin_tool_provider.dart';

part 'agent_impl_messaging.dart';
part 'agent_impl_skill.dart';

/// 消息和技能功能的基类，声明 mixin 需要访问的内部成员
abstract class _AgentImplBase implements IAgent {
  String get employeeId;
  String get deviceId;
  // ignore: unused_element
  IChatAdapter get _chatAdapter;
  // ignore: unused_element
  MessageProcessor? get _processor;
  set _processor(MessageProcessor? value);
  ToolRegistry get _toolRegistry;
  ToolPermissionManager get _permissionManager;
  Map<String, Completer<PermissionDecision>> get _pendingPermissions;
  Map<String, AgentPermissionRequest> get _pendingPermissionRequests;
  Map<String, Completer<String>> get _pendingConfirms;
  Map<String, AgentConfirmRequest> get _pendingConfirmRequests;
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
  FileOperationTracker? get _fileOperationTracker;
  set _fileOperationTracker(FileOperationTracker? value);
  TokenUsageTracker? get _tokenUsageTracker;
  set _tokenUsageTracker(TokenUsageTracker? value);
  Map<String, Map<String, dynamic>> get _toolCallArguments;
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

  /// 后台命令会话池
  CommandSessionPool? _commandSessionPool;

  /// 待处理的权限请求 Completer
  @override
  final Map<String, Completer<PermissionDecision>> _pendingPermissions = {};

  /// 待处理的权限请求信息
  @override
  final Map<String, AgentPermissionRequest> _pendingPermissionRequests = {};

  /// 待处理的确认请求 Completer
  @override
  final Map<String, Completer<String>> _pendingConfirms = {};

  /// 待处理的确认请求信息
  @override
  final Map<String, AgentConfirmRequest> _pendingConfirmRequests = {};

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

  /// 文件操作追踪器
  @override
  FileOperationTracker? _fileOperationTracker;

  /// Token 用量统计器
  @override
  TokenUsageTracker? _tokenUsageTracker;

  /// 工具调用参数缓存（toolCallStart 时缓存，toolCallResult 时消费）
  @override
  final Map<String, Map<String, dynamic>> _toolCallArguments = {};

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

  /// 内置工具提供者（可选，为 null 时使用默认全部内置工具）
  final BuiltinToolProvider? _builtinToolProvider;

  AgentImpl({
    required this.employeeId,
    required this.deviceId,
    required IChatAdapter chatAdapter,
    BuiltinToolProvider? builtinToolProvider,
  })  : _chatAdapter = chatAdapter,
        _builtinToolProvider = builtinToolProvider;

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
      final provider = _builtinToolProvider ?? DefaultBuiltinToolProvider();
      _toolRegistry.registerTools(provider.provide());
    }

    // 注入 TodoManageTool 回调
    _injectTodoManageCallbacks();

    // 注入 SpecManageTool 回调
    _injectSpecManageCallbacks();

    // 注入 SpawnSubAgentTool 回调（工具注册器引用）
    _injectSpawnSubAgentCallbacks();

    // 创建文件操作追踪器
    _fileOperationTracker = FileOperationTracker(
      employeeId: this.employeeId,
      store: FileOperationStore(deviceId: deviceId),
    );

    // 创建 Token 用量统计器
    _tokenUsageTracker = TokenUsageTracker();

    // 创建后台命令会话池并注入到 BgCommandTool
    _commandSessionPool = CommandSessionPool();
    _injectBgCommandCallbacks();

    // 注入 ConfirmTool 回调
    _injectConfirmToolCallbacks();

    // 注入 SendFileMessageTool 回调
    _injectSendFileMessageCallbacks();

    // 技能系统由 warmup 后台加载，不在 initialize 中阻塞

    // 设置工具注册器和权限管理器到适配器
    _chatAdapter.setToolRegistry(_toolRegistry);
    _chatAdapter.setPermissionManager(_permissionManager);

    // 注入流式输出增量回调：发射 streamDelta AgentEvent
    _chatAdapter.onStreamDelta = (chunk) {
      if (_status == AgentStatus.disposed) return;
      _eventController.add(AgentEvent(
        type: AgentEventType.streamDelta,
        data: {'content': chunk},
        employeeId: employeeId,
      ));
    };

    // 注入思考内容增量回调：发射 thinkingDelta AgentEvent
    _chatAdapter.onThinkingDelta = (delta) {
      if (_status == AgentStatus.disposed) return;
      _eventController.add(AgentEvent(
        type: AgentEventType.thinkingDelta,
        data: {'content': delta},
        employeeId: employeeId,
      ));
    };

    // 注入 Token 用量回调：累加统计并广播 tokenUsageUpdated AgentEvent
    _chatAdapter.onTokenUsage = (usage) {
      if (_status == AgentStatus.disposed) return;
      final processor = _processor;
      if (processor == null) return;
      final currentMsgId = processor.currentMessageId;
      if (currentMsgId == null) return;
      final msgId = currentMsgId;
      final eid = this.employeeId;
      _tokenUsageTracker?.accumulate(eid, msgId, usage);
      _eventController.add(AgentEvent(
        type: AgentEventType.tokenUsageUpdated,
        data: {
          'sessionUsage': _tokenUsageTracker?.getSessionUsage(eid).toMap(),
          'messageUsage': _tokenUsageTracker?.getMessageUsage(msgId)?.toMap(),
          'messageId': msgId,
        },
        employeeId: eid,
      ));
    };

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

    // 设置工具事件回调：通过事件流广播 + 维护工具调用状态 + 文件操作追踪
    _chatAdapter.setToolEventCallback((toolEvent) {
      switch (toolEvent) {
        case ToolCallStartEvent():
          _callingToolIds.add(toolEvent.toolCallId);
          // 缓存工具调用参数，供 toolCallResult 时使用
          _toolCallArguments[toolEvent.toolCallId] = toolEvent.arguments;
        case ToolCallResultEvent():
          _callingToolIds.remove(toolEvent.toolCallId);
          // 消费缓存的参数，通知文件操作追踪器
          final args = _toolCallArguments.remove(toolEvent.toolCallId) ?? {};
          _fileOperationTracker?.onToolResult(
            toolCallId: toolEvent.toolCallId,
            toolName: toolEvent.toolName,
            arguments: args,
            result: toolEvent.result,
            isError: toolEvent.isError,
          );
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

    // 消息完成前回调：将 Token 用量持久化到 MessageStore
    _processor!.onBeforeMessageCompleted = () async {
      await _persistTokenUsageToStore();
    };

    // 消息开始处理回调：发射 messageStarted AgentEvent
    _processor!.onMessageStarted = (messageId, messageData) {
      _eventController.add(AgentEvent(
        type: AgentEventType.messageStarted,
        data: {
          'messageId': messageId,
          'role': messageData['role'],
          'type': messageData['type'],
          'content': messageData['content'],
        },
        employeeId: employeeId,
      ));
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

    // 取消所有待处理的确认请求
    for (final completer in _pendingConfirms.values) {
      if (!completer.isCompleted) {
        completer.completeError('Agent disposed');
      }
    }
    _pendingConfirms.clear();
    _pendingConfirmRequests.clear();

    _processor?.dispose();
    _processor = null;

    _commandSessionPool?.dispose();
    _commandSessionPool = null;

    await _skillManager?.dispose();
    _skillManager = null;

    await _chatAdapter.dispose();
    await _stateController.close();
    await _eventController.close();

    _callingToolIds.clear();
    _tokenUsageTracker?.dispose();
    _tokenUsageTracker = null;
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
    _eventController.add(AgentEvent(
      type: AgentEventType.configChanged,
      data: {'configType': 'context', 'action': 'updated', 'contextData': contextData},
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> clearContext() async {
    _touch();
    _chatAdapter.clearContext();
    _eventController.add(AgentEvent(
      type: AgentEventType.configChanged,
      data: {'configType': 'context', 'action': 'cleared'},
      employeeId: employeeId,
    ));
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
    _eventController.add(AgentEvent(
      type: AgentEventType.configChanged,
      data: {'configType': 'provider', 'action': 'updated', 'providerConfig': providerConfig.toMap()},
      employeeId: employeeId,
    ));
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
    _eventController.add(AgentEvent(
      type: AgentEventType.configChanged,
      data: {
        'configType': 'project',
        'action': projectData != null ? 'updated' : 'cleared',
        if (projectData != null) 'projectData': projectData.toMap(),
      },
      employeeId: employeeId,
    ));
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
    _eventController.add(AgentEvent(
      type: AgentEventType.configChanged,
      data: {'configType': 'tools', 'action': 'added', 'toolName': tool.name},
      employeeId: employeeId,
    ));
  }

  @override
  void registerTools(List<AgentTool> tools) {
    _toolRegistry.registerTools(tools);
    _eventController.add(AgentEvent(
      type: AgentEventType.configChanged,
      data: {'configType': 'tools', 'action': 'added', 'count': tools.length},
      employeeId: employeeId,
    ));
  }

  @override
  void unregisterTool(String name) {
    _toolRegistry.unregisterTool(name);
    _eventController.add(AgentEvent(
      type: AgentEventType.configChanged,
      data: {'configType': 'tools', 'action': 'removed', 'toolName': name},
      employeeId: employeeId,
    ));
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

    // 主题查询
    todoTool.getCurrentTopics = (eid) async {
      return todoStore.findCurrentTopics(eid);
    };

    todoTool.getPendingTopics = (eid) async {
      return todoStore.findPendingTopics(eid);
    };

    todoTool.getAllTopics = (eid) async {
      return todoStore.findAllTopics(eid);
    };

    todoTool.getCompletedTopics = (eid, {limit = 50}) async {
      return todoStore.findCompletedTopics(eid, limit: limit);
    };

    // 主题写入
    todoTool.saveTopic = (topic) async {
      todoStore.saveTopic(topic);
    };

    todoTool.updateTopicContent = (id, {title, description}) async {
      todoStore.updateTopicContent(id, title: title, description: description);
    };

    todoTool.removeTopic = (id) async {
      todoStore.softDeleteTopic(id);
    };

    todoTool.clearCompletedTopics = (eid) async {
      todoStore.deleteCompletedTopics(eid);
    };

    // 任务子项
    todoTool.getTaskItemsByTopic = (topicId) async {
      return todoStore.findTaskItemsByTopic(topicId);
    };

    todoTool.saveTaskItem = (item) async {
      todoStore.saveTaskItem(item);
    };

    todoTool.updateTaskItemContent = (id, {title, content}) async {
      todoStore.updateTaskItemContent(id, title: title, content: content);
    };

    todoTool.updateTaskItemStatus = (id, status) async {
      todoStore.updateTaskItemStatus(id, status);
      // 更新子项状态后，重新推导主题状态
      // 需要先找到子项的 topicId
      final taskItem = todoStore.findTaskItemById(id);
      if (taskItem != null) {
        todoStore.recalculateTopicStatus(taskItem.topicId);
      }
    };

    todoTool.removeTaskItem = (id) async {
      // 先找到子项的 topicId
      final taskItem = todoStore.findTaskItemById(id);
      todoStore.softDeleteTaskItem(id);
      if (taskItem != null) {
        todoStore.recalculateTopicStatus(taskItem.topicId);
      }
    };

    todoTool.recalculateTopicStatus = (topicId) async {
      todoStore.recalculateTopicStatus(topicId);
    };

    // 广播事件
    todoTool.broadcastEvent = (type, data) {
      final eventType = type == 'todoTopicChanged'
          ? AgentEventType.todoTopicChanged
          : type == 'todoTaskItemChanged'
              ? AgentEventType.todoTaskItemChanged
              : AgentEventType.todoTopicChanged;
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
  Future<List<Map<String, dynamic>>> getCurrentTopics() async {
    final store = TodoStore(deviceId: deviceId);
    final items = store.findCurrentTopics(employeeId);
    return items.map((e) => e.toMap()).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getPendingTopics() async {
    final store = TodoStore(deviceId: deviceId);
    final items = store.findPendingTopics(employeeId);
    return items.map((e) => e.toMap()).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getAllTopics() async {
    final store = TodoStore(deviceId: deviceId);
    final items = store.findAllTopics(employeeId);
    return items.map((e) => e.toMap()).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getCompletedTopics({int limit = 50}) async {
    final store = TodoStore(deviceId: deviceId);
    final items = store.findCompletedTopics(employeeId, limit: limit);
    return items.map((e) => e.toMap()).toList();
  }

  @override
  Future<Map<String, dynamic>> getTodoStats() async {
    final store = TodoStore(deviceId: deviceId);
    return store.countTopicsByStatus(employeeId);
  }

  @override
  Future<void> updateTopicContent(String topicId, {String? title, String? description}) async {
    final store = TodoStore(deviceId: deviceId);
    store.updateTopicContent(topicId, title: title, description: description);
    _eventController.add(AgentEvent(
      type: AgentEventType.todoTopicChanged,
      data: {'action': 'updated', 'topicId': topicId},
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> deleteTopic(String topicId) async {
    final store = TodoStore(deviceId: deviceId);
    store.softDeleteTopic(topicId);
    _eventController.add(AgentEvent(
      type: AgentEventType.todoTopicChanged,
      data: {'action': 'removed', 'topicId': topicId},
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> clearCompletedTopics() async {
    final store = TodoStore(deviceId: deviceId);
    store.deleteCompletedTopics(employeeId);
    _eventController.add(AgentEvent(
      type: AgentEventType.todoTopicChanged,
      data: {'action': 'cleared'},
      employeeId: employeeId,
    ));
  }

  @override
  Future<List<Map<String, dynamic>>> getTaskItemsByTopic(String topicId) async {
    final store = TodoStore(deviceId: deviceId);
    final items = store.findTaskItemsByTopic(topicId);
    return items.map((e) => e.toMap()).toList();
  }

  @override
  Future<void> updateTaskItemStatus(String taskId, String status) async {
    final store = TodoStore(deviceId: deviceId);
    store.updateTaskItemStatus(taskId, status);
    final taskItem = store.findTaskItemById(taskId);
    if (taskItem != null) {
      store.recalculateTopicStatus(taskItem.topicId);
    }
    _eventController.add(AgentEvent(
      type: AgentEventType.todoTaskItemChanged,
      data: {'action': 'updated', 'taskId': taskId, 'status': status},
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> updateTaskItemContent(String taskId, {String? title, String? content}) async {
    final store = TodoStore(deviceId: deviceId);
    store.updateTaskItemContent(taskId, title: title, content: content);
    _eventController.add(AgentEvent(
      type: AgentEventType.todoTaskItemChanged,
      data: {'action': 'updated', 'taskId': taskId},
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> deleteTaskItem(String taskId) async {
    final store = TodoStore(deviceId: deviceId);
    final taskItem = store.findTaskItemById(taskId);
    store.softDeleteTaskItem(taskId);
    if (taskItem != null) {
      store.recalculateTopicStatus(taskItem.topicId);
    }
    _eventController.add(AgentEvent(
      type: AgentEventType.todoTaskItemChanged,
      data: {'action': 'removed', 'taskId': taskId},
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> updateTopicStatus(String topicId, String status) async {
    final store = TodoStore(deviceId: deviceId);
    store.updateTopicStatus(topicId, status);
    _eventController.add(AgentEvent(
      type: AgentEventType.todoTopicChanged,
      data: {'action': 'updated', 'topicId': topicId, 'status': status},
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> reorderTopics(List<String> topicIds) async {
    final store = TodoStore(deviceId: deviceId);
    store.reorderTopics(topicIds);
    _eventController.add(AgentEvent(
      type: AgentEventType.todoTopicChanged,
      data: {'action': 'reordered', 'topicIds': topicIds},
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> reorderTaskItems(List<String> taskItemIds) async {
    final store = TodoStore(deviceId: deviceId);
    store.reorderTaskItems(taskItemIds);
    _eventController.add(AgentEvent(
      type: AgentEventType.todoTaskItemChanged,
      data: {'action': 'reordered', 'taskItemIds': taskItemIds},
      employeeId: employeeId,
    ));
  }

  /// 注入 SpecManageTool 回调
  void _injectSpecManageCallbacks() {
    final specTool = _toolRegistry.getTool('spec_manage');
    if (specTool is! SpecManageTool) return;

    final specStore = SpecStore(deviceId: deviceId);

    // 注入 employeeId
    specTool.employeeId = employeeId;

    // 活跃 spec 查询
    specTool.getActiveSpecs = (eid) async {
      return specStore.findActiveByEmployee(eid);
    };

    // 已完成 spec 查询
    specTool.getCompletedSpecs = (eid, {limit = 50}) async {
      return specStore.findCompletedByEmployee(eid, limit: limit);
    };

    // 保存 spec 项
    specTool.saveSpec = (item) async {
      specStore.save(item);
    };

    // 更新 spec 状态
    specTool.updateSpecStatus = (id, status) async {
      specStore.updateStatus(id, status);
    };

    // 更新 spec 内容
    specTool.updateSpecContent = (id, {title, content}) async {
      specStore.updateContent(id, title: title, content: content);
    };

    // 软删除 spec 项
    specTool.removeSpec = (id) async {
      specStore.softDelete(id);
    };

    // 批量删除已完成项
    specTool.clearCompletedSpecs = (eid) async {
      specStore.deleteCompletedByEmployee(eid);
    };

    // 广播事件
    specTool.broadcastEvent = (type, data) {
      final eventType = AgentEventType.specChanged;
      _eventController.add(
        AgentEvent(
          type: eventType,
          data: data,
          employeeId: employeeId,
        ),
      );
    };
  }

  // ===== IAgent: Spec 管理 =====

  @override
  Future<List<Map<String, dynamic>>> getActiveSpecs() async {
    final store = SpecStore(deviceId: deviceId);
    final items = store.findActiveByEmployee(employeeId);
    return items.map((e) => e.toMap()).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getCompletedSpecs({int limit = 50}) async {
    final store = SpecStore(deviceId: deviceId);
    final items = store.findCompletedByEmployee(employeeId, limit: limit);
    return items.map((e) => e.toMap()).toList();
  }

  @override
  Future<Map<String, dynamic>> getSpecStats() async {
    final store = SpecStore(deviceId: deviceId);
    return store.countByStatus(employeeId);
  }

  @override
  Future<void> updateSpecStatus(String specId, String status) async {
    final store = SpecStore(deviceId: deviceId);
    store.updateStatus(specId, status);
    final spec = store.findByIdIncludingDeleted(specId);
    _eventController.add(AgentEvent(
      type: AgentEventType.specChanged,
      data: {
        'action': 'updated',
        'specId': specId,
        'status': status,
        if (spec != null) 'spec': spec.toMap(),
      },
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> updateSpecContent(String specId, String content) async {
    final store = SpecStore(deviceId: deviceId);
    store.updateContent(specId, content: content);
    final spec = store.findByIdIncludingDeleted(specId);
    _eventController.add(AgentEvent(
      type: AgentEventType.specChanged,
      data: {
        'action': 'updated',
        'specId': specId,
        if (spec != null) 'spec': spec.toMap(),
      },
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> deleteSpec(String specId) async {
    final store = SpecStore(deviceId: deviceId);
    store.softDelete(specId);
    final spec = store.findByIdIncludingDeleted(specId);
    _eventController.add(AgentEvent(
      type: AgentEventType.specChanged,
      data: {
        'action': 'deleted',
        'specId': specId,
        if (spec != null) 'spec': spec.toMap(),
      },
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> clearCompletedSpecs() async {
    final store = SpecStore(deviceId: deviceId);
    store.deleteCompletedByEmployee(employeeId);
    _eventController.add(AgentEvent(
      type: AgentEventType.specChanged,
      data: {'action': 'cleared', 'employeeId': employeeId},
      employeeId: employeeId,
    ));
  }

  @override
  Future<void> reorderSpecs(List<String> specIds) async {
    final store = SpecStore(deviceId: deviceId);
    store.reorderSpecs(specIds);
    _eventController.add(AgentEvent(
      type: AgentEventType.specChanged,
      data: {'action': 'reordered', 'specIds': specIds, 'employeeId': employeeId},
      employeeId: employeeId,
    ));
  }

  // ===== IAgent: 文件操作追踪 =====

  @override
  Future<List<Map<String, dynamic>>> getFileOperations({
    int limit = 100,
    int offset = 0,
  }) async {
    final ops = _fileOperationTracker?.getOperations(limit: limit, offset: offset) ?? [];
    return ops.map((e) => e.toMap()).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getFileOperationsByMessage(
      String messageId) async {
    final ops = _fileOperationTracker?.getOperationsByMessage(messageId) ?? [];
    return ops.map((e) => e.toMap()).toList();
  }

  @override
  Future<void> clearFileOperations() async {
    _fileOperationTracker?.clear();
  }

  /// 将当前消息的 Token 用量持久化到 MessageStore
  ///
  /// 在消息处理完成时调用（onBeforeMessageCompleted），一次性写入，
  /// 避免高频 DB 写入。
  Future<void> _persistTokenUsageToStore() async {
    final processor = _processor;
    if (processor == null) return;
    final currentMsgId = processor.currentMessageId;
    if (currentMsgId == null) return;

    final messageUsage = _tokenUsageTracker?.getMessageUsage(currentMsgId);
    if (messageUsage == null || messageUsage.isEmpty) return;

    // 更新 MessageStore 中对应消息的 input_tokens / output_tokens
    final store = MessageStore(deviceId: deviceId);
    final existing = await store.find(deviceId, currentMsgId);
    if (existing != null) {
      final updated = existing.copyWith(
        inputTokens: messageUsage.promptTokens,
        outputTokens: messageUsage.completionTokens,
        updatedAt: DateTime.now(),
      );
      await store.updateWithDeviceId(deviceId, updated);
    }
  }

  // ===== IAgent: Token 用量统计 =====

  @override
  TokenUsageRecord getSessionTokenUsage() {
    return _tokenUsageTracker?.getSessionUsage(employeeId) ?? const TokenUsageRecord();
  }

  @override
  TokenUsageRecord? getMessageTokenUsage(String messageId) {
    return _tokenUsageTracker?.getMessageUsage(messageId);
  }

  @override
  Future<TokenUsageRecord> getSessionTokenUsageAsync() async {
    // 优先读内存
    final memoryUsage = getSessionTokenUsage();
    if (memoryUsage.isNotEmpty) return memoryUsage;
    // 降级读 Store
    return getTokenUsageFromStore(employeeId);
  }

  @override
  Future<TokenUsageRecord?> getMessageTokenUsageAsync(String messageId) async {
    // 优先读内存
    final memoryUsage = getMessageTokenUsage(messageId);
    if (memoryUsage != null && memoryUsage.isNotEmpty) return memoryUsage;
    // 降级读 Store
    return getMessageTokenUsageFromStore(employeeId, messageId);
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
      return _buildAgentRuntimeConfig();
    };

    // 权限请求转发：通过 _permissionManager 转发
    executor.requestPermission = (request) async {
      if (_permissionManager.onPermissionRequest == null) {
        return PermissionDecision.deny;
      }
      return _permissionManager.onPermissionRequest!(request);
    };

    // 继承主 Agent 的权限配置
    executor.getParentPermissionConfig = () => _permissionManager.config;

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

  /// 注入 SendFileMessageTool 回调：将本地文件以助手文件消息形式发送给用户
  ///
  /// 回调内部完成：校验文件 → 计算 SHA256 → 创建 ChatMessage.file(role:assistant)
  /// → 持久化到 DB → 广播 messageStatusChanged(completed) 事件
  void _injectSendFileMessageCallbacks() {
    final tool = _toolRegistry.getTool('send_file_message');
    if (tool is! SendFileMessageTool) {
      _AgentImplBase._log.warn(
        'SendFileMessageTool not found in registry for injection. '
        'Available tools: ${_toolRegistry.toolNames}',
      );
      return;
    }

    final agentEmployeeId = employeeId;
    final agentDeviceId = deviceId;

    tool.sendFileMessage = ({
      required String filePath,
      String? mimeType,
    }) async {
      // 1. 校验文件
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('文件不存在: $filePath');
      }

      final fileName = p.basename(filePath);
      final fileSize = await file.length();
      final hash = crypto.sha256.convert(await file.readAsBytes()).toString();
      final fileId = const Uuid().v4();
      final messageId = const Uuid().v4();
      final actualMimeType = mimeType ?? _inferMimeType(filePath);

      // 2. 创建助手文件消息（与 AI 循环中 ChatMessage.assistant 模式一致）
      final fileMessage = ChatMessage.file(
        id: messageId,
        employeeId: agentEmployeeId,
        role: MessageRole.assistant,
        fileName: fileName,
        fileSize: fileSize,
        fileId: fileId,
        fileHash: hash,
        filePath: filePath,
        fromDeviceId: agentDeviceId,
        mimeType: actualMimeType,
        deviceId: agentDeviceId,
      );

      // 3. 持久化到 DB（与 injectAssistantMessage 模式一致）
      if (_chatAdapter case final LlmChatAdapter adapter) {
        adapter.memoryManager.addMessage(
          agentEmployeeId,
          agentDeviceId,
          fileMessage,
        );
      }

      // 4. 广播 completed 事件（与 AI 循环 onMessageStatusChanged 模式一致）
      _broadcasterBroadcastMessageStatusChange(
        messageId: messageId,
        status: AgentMessageStatus.completed,
        extraData: {
          'role': 'assistant',
          'type': 'file',
          'content': fileMessage.content,
          'metadata': fileMessage.metadata,
        },
      );

      return messageId;
    };

    _AgentImplBase._log.info(
      'SendFileMessageTool injected for $agentEmployeeId',
    );
  }

  /// 根据文件扩展名推断 MIME 类型
  String? _inferMimeType(String path) {
    final ext = p.extension(path).toLowerCase();
    const mimeMap = {
      '.pdf': 'application/pdf',
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.gif': 'image/gif',
      '.csv': 'text/csv',
      '.xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      '.json': 'application/json',
      '.txt': 'text/plain',
      '.md': 'text/markdown',
      '.html': 'text/html',
      '.zip': 'application/zip',
    };
    return mimeMap[ext];
  }

  /// 注入 BgCommandTool 的 CommandSessionPool 引用和监控 LLM 回调
  void _injectBgCommandCallbacks() {
    final bgTool = _toolRegistry.getTool('bg_command');
    if (bgTool is! BgCommandTool) {
      _AgentImplBase._log.warn(
        'BgCommandTool not found in registry for injection. '
        'Available tools: ${_toolRegistry.toolNames}',
      );
      return;
    }

    bgTool.pool = _commandSessionPool;

    // 注入监控 LLM 回调：使用 invokeOnce 做单次轻量 LLM 调用
    bgTool.invokeMonitorLlm = (prompt) async {
      try {
        return await _chatAdapter.invokeOnce(prompt);
      } catch (e) {
        _AgentImplBase._log.warn('BgCommand monitor LLM call failed: $e');
        return null;
      }
    };

    // 将 pool 引用也注入到 SubAgentExecutor，使子 Agent 可查询主 Agent 的后台会话
    final spawnTool = _toolRegistry.getTool('spawn_sub_agent');
    if (spawnTool is SpawnSubAgentTool && spawnTool.executor != null) {
      spawnTool.executor!.commandSessionPool = _commandSessionPool;
    }

    _AgentImplBase._log.info(
      'BgCommandTool injected (pool + monitor LLM) for $employeeId',
    );
  }

  /// 注入 ConfirmTool 回调  ///  /// 设置 onConfirmRequest 回调：创建 Completer、广播事件、  /// 等待用户选择后返回结果。  void _injectConfirmToolCallbacks() {
    final confirmTool = _toolRegistry.getTool('confirm');
    if (confirmTool is! ConfirmTool) {
      _AgentImplBase._log.warn(
        'ConfirmTool not found in registry for injection. '
        'Available tools: ${_toolRegistry.toolNames}',
      );
      return;
    }

    confirmTool.onConfirmRequest = (request) async {
      final completer = Completer<String>();
      _pendingConfirms[request.requestId] = completer;
      _pendingConfirmRequests[request.requestId] = request;

      // 设置处理器状态为等待权限（复用现有状态管理）
      _processor?.setPermissionBlocked(request.requestId);

      // 广播确认请求事件
      _eventController.add(
        AgentEvent(
          type: AgentEventType.confirmRequest,
          data: request.toMap(),
          employeeId: employeeId,
        ),
      );

      try {
        return await completer.future;
      } finally {
        _pendingConfirms.remove(request.requestId);
        _pendingConfirmRequests.remove(request.requestId);
        // 恢复处理状态
        _processor?.setPermissionBlocked(null);
      }
    };

    _AgentImplBase._log.info(
      'ConfirmTool injected (onConfirmRequest callback) for $employeeId',
    );
  }

  /// 从 _chatAdapter 构建 AgentRuntimeConfig，包含 provider、systemPrompt 和项目上下文
  AgentRuntimeConfig _buildAgentRuntimeConfig() {
    final providerConfig = _chatAdapter.getProviderConfig();
    final context = _chatAdapter.currentContext;
    final systemPrompt = context?['systemPrompt'] as String?;

    // 提取项目相关字段，传递给子 Agent 以便注入项目信息到 system prompt
    const projectKeys = [
      'projectUuid', 'projectName', 'projectContext',
      'workPath', 'additionalInfo', 'metadata',
    ];
    final projectContext = <String, dynamic>{};
    if (context != null) {
      for (final key in projectKeys) {
        final value = context[key];
        if (value != null) {
          projectContext[key] = value;
        }
      }
    }

    return AgentRuntimeConfig(
      providerConfig: providerConfig,
      systemPrompt: systemPrompt,
      projectContext: projectContext.isEmpty ? null : projectContext,
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
