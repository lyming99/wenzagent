import 'dart:async';

import '../agent_state.dart';
import '../i_agent.dart';
import '../processor/message_processor.dart';
import '../tool/agent_tool.dart';
import '../tool/builtin/builtin_tools.dart';
import '../tool/permission_manager.dart';
import '../tool/tool_registry.dart';

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
class AgentImpl implements IAgent {
  @override
  final String employeeUuid;

  // ===== 内部组件 =====

  /// 对话适配器
  final IChatAdapter _chatAdapter;

  /// 消息处理调度器（延迟初始化）
  MessageProcessor? _processor;

  /// 工具注册器
  final ToolRegistry _toolRegistry = ToolRegistry();

  /// 权限管理器
  final ToolPermissionManager _permissionManager = ToolPermissionManager();

  /// 待处理的权限请求 Completer
  final Map<String, Completer<PermissionDecision>> _pendingPermissions = {};

  /// 待处理的权限请求信息
  final Map<String, AgentPermissionRequest> _pendingPermissionRequests = {};

  // ===== 内部状态 =====

  /// 当前 Agent 状态
  AgentStatus _status = AgentStatus.idle;

  /// 引用计数
  int _refCount = 0;

  /// 最后活跃时间
  DateTime _lastActiveTime = DateTime.now();

  /// 异步操作锁
  Completer<void>? _lockCompleter;

  AgentImpl({required this.employeeUuid, required IChatAdapter chatAdapter})
    : _chatAdapter = chatAdapter;

  // ===== IAgent: 基础信息 =====

  @override
  String? get currentSessionUuid => _chatAdapter.currentSessionUuid;

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

  @override
  Future<void> initialize({String? sessionUuid}) async {
    // 初始化适配器
    await _chatAdapter.initSession(
      employeeUuid: employeeUuid,
      sessionUuid: sessionUuid,
    );

    // 注册内置工具
    _toolRegistry.registerTools(BuiltinTools.all());

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
      _eventController.add({
        'type': 'toolPermissionRequest',
        'data': request.toMap(),
        'employeeUuid': employeeUuid,
      });

      try {
        return await completer.future;
      } finally {
        _pendingPermissions.remove(request.requestId);
        _pendingPermissionRequests.remove(request.requestId);
        // 恢复处理状态
        _processor?.setPermissionBlocked(null);
      }
    };

    // 设置工具事件回调：通过事件流广播
    _chatAdapter.setToolEventCallback((event) {
      _eventController.add({...event, 'employeeUuid': employeeUuid});
    });

    // 初始化消息处理调度器
    _processor = MessageProcessor(
      streamMessage: (messageId, messageData, {cancellationToken}) {
        return _chatAdapter
            .streamMessage(messageData, cancellationToken: cancellationToken)
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
    );

    // 监听处理器状态变更
    _processor!.onStateChanged = (processorStatus) {
      _syncProcessorStatus(processorStatus);
    };

    // 监听消息处理状态变更
    _processor!.onMessageStatusChanged = (messageId, msgStatus, {error}) async {
      _broadcasterBroadcastMessageStatusChange(
        messageId: messageId,
        status: msgStatus,
        error: error,
      );
    };

    _touch();
    _setStatus(AgentStatus.idle);
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

    await _chatAdapter.dispose();
    await _stateController.close();
    await _eventController.close();
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

  // ===== IAgent: 对话操作 =====

  @override
  Future<String> sendMessage(Map<String, dynamic> messageData) async {
    _touch();
    print('[AgentImpl] sendMessage: ${messageData['content']?.toString().substring(0, (messageData['content']?.toString().length ?? 0).clamp(0, 50))}');
    print('[AgentImpl] currentSessionUuid: $currentSessionUuid');

    return await _withLock(() async {
      // 生成消息ID
      final messageId =
          messageData['id'] as String? ??
          'msg_${DateTime.now().millisecondsSinceEpoch}_${Object().hashCode}';
      messageData['id'] = messageId;
      messageData['role'] = 'user';
      messageData['type'] = messageData['type'] as String? ?? 'text';
      messageData['createdAt'] = DateTime.now().toIso8601String();

      print('[AgentImpl] submitting message to processor, messageId: $messageId');
      // 提交到处理器
      await _processor?.submitMessage(messageId, messageData);

      return messageId;
    });
  }

  @override
  Future<void> interrupt() async {
    _touch();
    await _processor?.interruptCurrentTask();
    _setStatus(AgentStatus.idle);
  }

  // ===== IAgent: 会话管理 =====

  @override
  Future<List<Map<String, dynamic>>> getSessionList() async {
    return _chatAdapter.getSessionsByEmployee(employeeUuid);
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String sessionUuid,
  ) async {
    return _chatAdapter.getSessionMessages(sessionUuid);
  }

  @override
  Future<String> createSession() async {
    _touch();
    final uuid = await _chatAdapter.createNewSession(
      employeeUuid: employeeUuid,
    );
    return uuid;
  }

  @override
  Future<void> switchSession(String sessionUuid) async {
    _touch();
    await _withLock(() async {
      if (_chatAdapter.isStreaming) {
        await _chatAdapter.stopStreaming();
      }

      await _chatAdapter.switchSession(sessionUuid);
    });
  }

  @override
  Future<void> revokeMessage(String messageId) async {
    _touch();
    await _processor?.revokeMessage(messageId);
  }

  @override
  AgentPermissionRequest? getPendingPermissionRequest() {
    // 返回第一个待处理的权限请求
    if (_pendingPermissionRequests.isEmpty) return null;
    return _pendingPermissionRequests.values.first;
  }

  @override
  Future<void> clearCurrentSession() async {
    _touch();
    await _withLock(() async {
      await _chatAdapter.clearCurrentSession();
    });
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
  Future<void> setProvider(Map<String, dynamic> providerConfig) async {
    _touch();
    await _withLock(() async {
      await _chatAdapter.updateProvider(providerConfig);
    });
  }

  @override
  Map<String, dynamic>? getProviderConfig() {
    return _chatAdapter.getProviderConfig();
  }

  // ===== IAgent: 项目管理 =====

  @override
  Future<void> setProject(Map<String, dynamic>? projectData) async {
    _touch();
    await _chatAdapter.updateProjectContext(projectData);
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

  // ===== IAgent: 权限管理 =====

  @override
  Future<void> respondToPermission(
    String requestId,
    PermissionDecision decision,
  ) async {
    final completer = _pendingPermissions[requestId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(decision);

      // 广播权限响应事件
      _eventController.add({
        'type': 'toolPermissionResponse',
        'data': {'requestId': requestId, 'decision': decision.name},
        'employeeUuid': employeeUuid,
      });
    }
  }

  // ===== IAgent: 状态查询 =====

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

  final _stateController = StreamController<AgentStateSnapshot>.broadcast();
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<AgentStateSnapshot> get onStateChanged => _stateController.stream;

  @override
  Stream<Map<String, dynamic>> get onEvent => _eventController.stream;

  // ===== 内部方法 =====

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
  void _setStatus(AgentStatus newStatus) {
    if (_status == newStatus) return;
    _status = newStatus;

    final snapshot = getStateSnapshot();
    _stateController.add(snapshot);
    _eventController.add({
      'type': 'agentStatusChanged',
      'data': snapshot.toMap(),
      'employeeUuid': employeeUuid,
    });
  }

  /// 更新最后活跃时间
  void _touch() {
    _lastActiveTime = DateTime.now();
  }

  /// 异步操作加锁
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
  void _broadcasterBroadcastMessageStatusChange({
    required String messageId,
    required AgentMessageStatus status,
    String? error,
  }) {
    _eventController.add({
      'type': 'messageStatusChanged',
      'data': {
        'messageId': messageId,
        'status': status.name,
        if (error != null) 'error': error,
      },
      'employeeUuid': employeeUuid,
    });
  }
}
