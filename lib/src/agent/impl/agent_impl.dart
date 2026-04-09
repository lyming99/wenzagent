import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../../wenzagent.dart';
import '../agent_state.dart';
import '../entity/entity.dart';
import '../i_agent.dart';
import '../processor/interrupt_judge.dart';
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
  final String employeeId;

  // ===== 内部组件 =====

  /// 对话适配器
  final IChatAdapter _chatAdapter;

  /// 消息处理调度器（延迟初始化）
  MessageProcessor? _processor;

  /// 工具注册器
  final ToolRegistry _toolRegistry = ToolRegistry();

  /// 获取工具注册器（供内部模块注入回调使用）
  ToolRegistry get toolRegistry => _toolRegistry;

  /// 权限管理器
  final ToolPermissionManager _permissionManager = ToolPermissionManager();

  /// 待处理的权限请求 Completer
  final Map<String, Completer<PermissionDecision>> _pendingPermissions = {};

  /// 待处理的权限请求信息
  final Map<String, AgentPermissionRequest> _pendingPermissionRequests = {};

  /// 消息接收状态跟踪
  /// Map<messageId, Map<receiverDeviceId, updateTime>>
  /// 当消息被设备接收后，记录接收时间和消息的更新时间
  /// 当消息状态更新时，清除接收状态，让设备可以重新接收
  final Map<String, Map<String, DateTime>> _messageReceiveStatus = {};

  /// 消息已读状态跟踪
  /// Map<messageId, Map<readerDeviceId, readTime>>
  /// 当某个设备上的用户查看了消息后，记录已读状态
  final Map<String, Map<String, DateTime>> _messageReadStatus = {};

  // ===== 内部状态 =====

  /// 当前 Agent 状态
  AgentStatus _status = AgentStatus.idle;

  /// 引用计数
  int _refCount = 0;

  /// 最后活跃时间
  DateTime _lastActiveTime = DateTime.now();

  /// 异步操作锁
  Completer<void>? _lockCompleter;

  AgentImpl({required this.employeeId, required IChatAdapter chatAdapter})
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

  @override
  Future<void> initialize({String? employeeId, bool enableBuiltinTools = true}) async {
    // 初始化适配器
    await _chatAdapter.initSession(
      employeeId: employeeId ?? this.employeeId,
    );

    // 注册内置工具（可选）
    if (enableBuiltinTools) {
      _toolRegistry.registerTools(BuiltinTools.all());
    }

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
        'employeeId': employeeId,
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
      _eventController.add({...event, 'employeeId': employeeId});
    });

    // 初始化消息处理调度器
    // 创建打断判断器
    final interruptJudge = InterruptJudge((prompt) async {
      return await _chatAdapter.invokeOnce(prompt);
    });

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
      interruptJudge: interruptJudge,
    );

    // 监听处理器状态变更
    _processor!.onStateChanged = (processorStatus) {
      _syncProcessorStatus(processorStatus);
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
  Future<String> sendMessage(MessageInput input) async {
    _touch();
    print('[AgentImpl] sendMessage: ${input.content.substring(0, input.content.length.clamp(0, 50))}');

    return await _withLock(() async {
      // 🔑 关键修复：优先使用 MessageInput.id，避免被 metadata.id 覆盖
      // 这是客户端提供的"真实"消息ID，必须在整个传输链中保持一致
      final clientProvidedId = input.id;
      
      // 转换为 Map 以便内部处理
      final messageData = input.toMap();
      
      // 🔑 关键：如果客户端提供了ID，强制使用它，覆盖metadata中的id
      if (clientProvidedId != null && clientProvidedId.isNotEmpty) {
        messageData['id'] = clientProvidedId;
        print('[AgentImpl] 使用客户端提供的消息ID: $clientProvidedId (强制覆盖metadata)');
      } else {
        // 客户端没有提供ID，检查messageData中是否有ID（可能来自metadata）
        final existingId = messageData['id'] as String?;
        if (existingId == null || existingId.isEmpty) {
          // 没有任何ID，生成一个新的
          final newMessageId = const Uuid().v4();
          messageData['id'] = newMessageId;
          print('[AgentImpl] 生成新消息ID: $newMessageId');
        } else {
          print('[AgentImpl] 使用metadata中的消息ID: $existingId');
        }
      }

      final finalMessageId = messageData['id'] as String;
      messageData['role'] = 'user';
      messageData['type'] = messageData['type'] as String? ?? 'text';
      messageData['createdAt'] = DateTime.now().toIso8601String();

      print('[AgentImpl] 提交消息到处理器，最终消息ID: $finalMessageId');
      // 提交到处理器
      await _processor?.submitMessage(finalMessageId, messageData);

      return finalMessageId;
    });
  }

  @override
  Future<String> sendMessageFromMap(Map<String, dynamic> messageData) {
    return sendMessage(MessageInput.fromMap(messageData));
  }

  @override
  Future<void> interrupt() async {
    _touch();
    await _processor?.interruptCurrentTask();
    _setStatus(AgentStatus.idle);
  }

  // ===== IAgent: 会话管理 =====

  @override
  Future<List<AgentMessage>> getSessionMessages() async {
    return _chatAdapter.getSessionMessages(employeeId);
  }

  @override
  Future<List<AgentMessage>> getSessionMessagesByUserCount({
    int userMessageLimit = 20,
  }) async {
    // 1. 获取所有消息
    final allMessages = await _chatAdapter.getSessionMessages(employeeId);

    if (allMessages.isEmpty) {
      return [];
    }

    // 2. 按时间倒序排列（最新的在前）
    allMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // 3. 统计用户消息，达到限制时停止
    int userMessageCount = 0;
    final selectedMessages = <AgentMessage>[];

    for (final message in allMessages) {
      selectedMessages.add(message);

      // 统计用户消息
      if (message.role == 'user') {
        userMessageCount++;

        // 达到限制时停止
        if (userMessageCount >= userMessageLimit) {
          break;
        }
      }
    }

    // 4. 按时间正序排列返回
    selectedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return selectedMessages;
  }

  @override
  Future<List<AgentMessage>> getSessionMessagesPaged({
    int pageSize = 20,
    int offset = 0,
  }) async {
    // 1. 获取所有消息
    final allMessages = await _chatAdapter.getSessionMessages(employeeId);

    if (allMessages.isEmpty) {
      return [];
    }

    // 2. 按时间倒序排列（最新的在前）
    allMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // 3. 分页获取
    final pagedMessages = allMessages.skip(offset).take(pageSize).toList();

    // 4. 按时间正序排列返回
    pagedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return pagedMessages;
  }

  @override
  Future<List<AgentMessage>> getUnreceivedMessages({
    required String receiverDeviceId,
  }) async {
    // 1. 获取所有消息
    final allMessages = await _chatAdapter.getSessionMessages(employeeId);

    if (allMessages.isEmpty) {
      return [];
    }

    // 2. 过滤出该设备未接收的消息
    final unreceivedMessages = <AgentMessage>[];

    for (final message in allMessages) {
      final messageUpdateTime = _getMessageUpdateTime(message);

      // 检查该设备是否已接收此消息
      final receiveStatus = _messageReceiveStatus[message.id];
      if (receiveStatus == null) {
        // 消息未被任何设备接收过，属于未接收消息
        unreceivedMessages.add(message);
        continue;
      }

      final deviceReceiveTime = receiveStatus[receiverDeviceId];
      if (deviceReceiveTime == null) {
        // 该设备未接收过此消息，属于未接收消息
        unreceivedMessages.add(message);
        continue;
      }

      // 检查消息是否已更新（updateTime比接收时间更新）
      if (messageUpdateTime.isAfter(deviceReceiveTime)) {
        // 消息已更新，需要重新接收
        unreceivedMessages.add(message);
      }
    }

    print('[AgentImpl] 查询设备 $receiverDeviceId 的未接收消息，共 ${unreceivedMessages.length} 条');
    return unreceivedMessages;
  }

  @override
  Future<void> markMessagesAsReceived({
    required String receiverDeviceId,
    required List<MessageReceiveInfo> messageReceiveList,
  }) async {
    // 记录消息接收状态
    for (final info in messageReceiveList) {
      // 获取或创建消息的接收状态Map
      _messageReceiveStatus[info.messageId] ??= {};

      // 记录该设备的接收时间
      _messageReceiveStatus[info.messageId]![receiverDeviceId] = info.updateTime;
    }

    print('[AgentImpl] 已标记设备 $receiverDeviceId 接收 ${messageReceiveList.length} 条消息');
  }

  @override
  Future<void> markMessagesAsRead({
    required String readerDeviceId,
    required String employeeId,
    List<String>? messageIds,
  }) async {
    _touch();

    // 如果未指定消息ID列表，则标记该员工的所有消息为已读
    final ids = messageIds;
    if (ids != null && ids.isNotEmpty) {
      for (final messageId in ids) {
        _messageReadStatus[messageId] ??= {};
        _messageReadStatus[messageId]![readerDeviceId] = DateTime.now();
      }
      print('[AgentImpl] 已标记设备 $readerDeviceId 对 ${ids.length} 条消息的已读状态');
    } else {
      // 获取所有消息并标记已读
      final allMessages = await _chatAdapter.getSessionMessages(employeeId);
      for (final message in allMessages) {
        _messageReadStatus[message.id] ??= {};
        _messageReadStatus[message.id]![readerDeviceId] = DateTime.now();
      }
      print('[AgentImpl] 已标记设备 $readerDeviceId 对员工 $employeeId 所有消息的已读状态');
    }

    // 广播已读状态变更事件
    _eventController.add({
      'type': 'messageReadStatusChanged',
      'data': {
        'employeeId': employeeId,
        'readerDeviceId': readerDeviceId,
        'messageIds': ids,
      },
      'employeeId': employeeId,
    });
  }

  @override
  Future<Map<String, dynamic>> getMessagesReadStatus({
    required String deviceId,
    required String employeeId,
  }) async {
    // 获取该员工的所有消息
    final allMessages = await _chatAdapter.getSessionMessages(employeeId);

    final readStatus = <String, dynamic>{};
    for (final message in allMessages) {
      final messageReadMap = _messageReadStatus[message.id];
      if (messageReadMap != null && messageReadMap.containsKey(deviceId)) {
        readStatus[message.id] = true;
      } else {
        readStatus[message.id] = false;
      }
    }

    return {
      'employeeId': employeeId,
      'deviceId': deviceId,
      'readStatus': readStatus,
    };
  }

  /// 获取消息的更新时间
  DateTime _getMessageUpdateTime(AgentMessage message) {
    // 优先使用metadata中的updateTime
    if (message.metadata?['updateTime'] != null) {
      final updateTime = message.metadata!['updateTime'];
      if (updateTime is String) {
        return DateTime.parse(updateTime);
      } else if (updateTime is DateTime) {
        return updateTime;
      }
    }

    // 其次使用createdAt
    return message.createdAt;
  }

  /// 清除消息的接收状态（当消息更新时调用）
  void _clearMessageReceiveStatus(String messageId) {
    _messageReceiveStatus.remove(messageId);
    print('[AgentImpl] 已清除消息 $messageId 的接收状态');
  }

  /// 清除消息的已读状态（当消息更新时调用）
  void _clearMessageReadStatus(String messageId) {
    _messageReadStatus.remove(messageId);
    print('[AgentImpl] 已清除消息 $messageId 的已读状态');
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessagesAsMap() async {
    final messages = await getSessionMessages();
    return messages.map((m) => m.toMap()).toList();
  }

  @override
  Future<void> revokeMessage(String messageId) async {
    _touch();
    
    // 如果正在处理的是要删除的消息，先打断
    if (_processor?.currentProcessingMessageId == messageId) {
      print('[AgentImpl] 正在处理的消息被删除，打断处理: $messageId');
      await _processor?.interruptCurrentTask();
    } else {
      // 否则只从队列中撤回
      await _processor?.revokeMessage(messageId);
    }
    
    // 从内存中删除消息
    _chatAdapter.removeMessageFromMemory(messageId);
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
      // 如果有正在处理的消息，先打断
      if (_processor?.currentProcessingMessageId != null) {
        print('[AgentImpl] 清空会话，打断正在处理的消息');
        await _processor?.interruptCurrentTask();
      }
      
      await _chatAdapter.clearCurrentSession();
    });
  }

  @override
  Future<void> removeMessageFromMemory(String messageId) async {
    _touch();
    await _withLock(() async {
      _chatAdapter.removeMessageFromMemory(messageId);
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
        'employeeId': employeeId,
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
      'employeeId': employeeId,
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

  /// 注入一条 assistant 消息（不触发 LLM）
  ///
  /// 用于定时任务等场景：sub-agent 生成内容后，直接注入到主 agent 会话中。
  /// 消息会被写入 adapter session（内存）和持久化存储（Hive），
  /// 并通过事件流广播 messageStatusChanged，让 UI 能正常收到。
  Future<void> injectAssistantMessage({
    required String messageId,
    required String content,
  }) async {
    if (_status == AgentStatus.disposed) return;

    // 1. 写入 adapter session + 持久化
    if (_chatAdapter is PersistentChatAdapter) {
      (_chatAdapter as PersistentChatAdapter)
          .injectAssistantMessage(messageId, content, 'default');
    }

    // 2. 广播 completed 事件（UI 监听此事件渲染消息）
    _broadcasterBroadcastMessageStatusChange(
      messageId: messageId,
      status: AgentMessageStatus.completed,
      extraData: {
        'role': 'assistant',
        'type': 'text',
        'content': content,
      },
    );

    _touch();
  }

  /// 触发定时任务（注入 system 消息 + 触发 LLM 处理）
  ///
  /// 1. 将任务内容以 system 消息注入到会话（role=system，持久化）
  /// 2. 发送一条 user 消息触发 LLM 处理（走完整的 streamMessage 流程）
  /// 3. 用户不会看到 system 消息和触发消息，只看到 LLM 的自然回复
  Future<String?> triggerSystemTask({
    required String taskContent,
    String? taskName,
  }) async {
    if (_status == AgentStatus.disposed) return null;
    _touch();

    // 1. 注入 system 消息（role=system，写入 session + 持久化）
    final systemMsgId = const Uuid().v4();
    final systemContent = taskName != null
        ? '【定时任务：$taskName】\n$taskContent'
        : '【定时任务触发】\n$taskContent';

    if (_chatAdapter is PersistentChatAdapter) {
      (_chatAdapter as PersistentChatAdapter)
          .injectSystemMessage(systemMsgId, systemContent, 'default');
    }

    // 2. 发送 user 消息触发 LLM 处理（metadata 标记 trigger=scheduled_task，
    //    queued 状态会被 device_client 过滤，用户不可见）
    final userMsgId = const Uuid().v4();

    return await _withLock(() async {
      final messageData = {
        'id': userMsgId,
        'role': 'system',
        'type': 'text',
        'content': taskContent,
        'createdAt': DateTime.now().toIso8601String(),
        'metadata': {
          'trigger': 'scheduled_task',
          'scheduledSystemMessageId': systemMsgId,
        },
      };
      await _processor?.submitMessage(userMsgId, messageData);
      return userMsgId;
    });
  }

  /// 注入一条提醒类助手消息（不调用 LLM API）
  ///
  /// 用于定时提醒场景：提醒内容在创建时已预渲染，
  /// 触发时直接写入会话并广播给设备，用户看到的是一条助手消息。
  Future<String?> injectReminderMessage({
    required String content,
    String? taskName,
    String? taskId,
  }) async {
    if (_status == AgentStatus.disposed) return null;
    _touch();

    final msgId = const Uuid().v4();
    final now = DateTime.now();

    if (_chatAdapter is PersistentChatAdapter) {
      (_chatAdapter as PersistentChatAdapter)
          .injectAssistantMessage(msgId, content, 'system');
    }

    // 广播消息状态变更（completed），与正常助手消息完成流程一致
    _broadcasterBroadcastMessageStatusChange(
      messageId: msgId,
      status: AgentMessageStatus.completed,
      extraData: {
        'role': 'assistant',
        'content': content,
        'createdAt': now.toIso8601String(),
        'metadata': {
          'trigger': 'scheduled_reminder',
          'taskName': taskName,
          'taskId': taskId,
        },
      },
    );

    // 强制广播 agentStatusChanged(idle)，触发前端刷新消息列表
    // 与正常助手消息完成后的状态变更流程一致
    // 注入消息时 Agent 本身就是 idle，_setStatus 的 guard 会阻止重复广播，
    // 所以直接通过 controller 推送，绕过 guard
    if (!_stateController.isClosed && !_eventController.isClosed) {
      final snapshot = getStateSnapshot();
      _stateController.add(snapshot);
      _eventController.add({
        'type': 'agentStatusChanged',
        'data': snapshot.toMap(),
        'employeeId': employeeId,
      });
    }

    return msgId;
  }

  /// 广播消息状态变更
  void _broadcasterBroadcastMessageStatusChange({
    required String messageId,
    required AgentMessageStatus status,
    String? error,
    Map<String, dynamic> extraData = const {},
  }) {
    if (_status == AgentStatus.disposed) return;
    _eventController.add({
      'type': 'messageStatusChanged',
      'data': {
        'messageId': messageId,
        'status': status.name,
        if (error != null) 'error': error,
        ...extraData,
      },
      'employeeId': employeeId,
    });
  }
}
