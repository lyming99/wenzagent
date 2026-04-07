import 'dart:async';

import 'package:uuid/uuid.dart';

import '../agent_state.dart';
import '../entity/entity.dart';
import '../i_agent.dart';
import '../rpc/agent_rpc_util.dart';
import '../tool/agent_tool.dart';

/// RPC 调用回调类型
typedef RpcCall =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

/// Agent Proxy（纯 Dart）
///
/// 统一本地和远程调用入口，对上层透明。
///
/// 两种工作模式：
/// - 本地模式：直接调用 [IAgent] 实例
/// - 远程模式：通过 RPC 回调调用远程 Agent
class AgentProxy {
  /// 员工UUID
  final String employeeId;

  /// 设备ID
  final String deviceId;

  /// 是否为本地模式
  final bool isLocalMode;

  /// 本地 Agent 实例（本地模式使用）
  final IAgent? _localAgent;

  /// RPC 工具类（远程模式使用）
  AgentRpcUtil? _rpcUtil;

  /// 远程状态缓存
  final _RemoteStateCache _remoteCache = _RemoteStateCache();

  /// 状态变更通知
  final StreamController<AgentStateSnapshot> _stateController =
      StreamController<AgentStateSnapshot>.broadcast();

  /// 事件通知（用于缓存层监听原始事件）
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// 远程事件流订阅取消器
  StreamSubscription<Map<String, dynamic>>? _remoteEventSubscription;

  /// 待确认消息队列（存储已发送但未被查询确认的完整消息内容）
  final List<PendingMessage> _pendingMessageQueue = [];

  /// 创建本地模式 Proxy
  AgentProxy.local({
    required this.employeeId,
    required this.deviceId,
    required IAgent localAgent,
  }) : isLocalMode = true,
       _localAgent = localAgent;

  /// 创建远程模式 Proxy
  AgentProxy.remote({
    required this.employeeId,
    required this.deviceId,
    required RpcCall rpcCall,
    Stream<Map<String, dynamic>>? remoteEventStream,
  }) : isLocalMode = false,
       _localAgent = null {
    _rpcUtil = AgentRpcUtil(rpcCall);
    if (remoteEventStream != null) {
      _subscribeRemoteEvents(remoteEventStream);
    }
  }

  /// 状态变更流
  Stream<AgentStateSnapshot> get onStateChanged {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.onStateChanged;
    }
    return _stateController.stream;
  }

  /// 事件流（暴露原始事件，供CachedAgentProxy监听）
  Stream<Map<String, dynamic>> get onEvent {
    if (isLocalMode && _localAgent != null) {
      // 本地模式：尝试从IAgent获取事件流
      // 如果IAgent没有onEvent，返回空流
      return _eventController.stream;
    }
    return _eventController.stream;
  }

  /// 当前状态
  AgentStatus get status {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.status;
    }
    return _remoteCache.status;
  }

  /// 是否存活
  bool get isAlive {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.isAlive;
    }
    return _remoteCache.status != AgentStatus.disposed;
  }

  // ===== 对话操作 =====

  /// 发送消息
  Future<String> sendMessage(MessageInput input) async {
    print('[AgentProxy] sendMessage isLocalMode: $isLocalMode');
    
    // 🔑 关键：在客户端生成UUID，确保远程和本地ID一致
    final messageId = input.id ?? const Uuid().v4();
    print('[AgentProxy] 消息ID: $messageId (${input.id != null ? "客户端提供" : "客户端生成"})');
    
    // 创建带有ID的input副本
    final inputWithId = input.id != null ? input : input.copyWith(id: messageId);
    print('[AgentProxy] inputWithId.id: ${inputWithId.id}');
    
    // 🔑 如果是客户端生成的ID，验证UUID格式
    // 如果是用户提供ID，不验证（允许自定义格式）
    if (input.id == null && !_isValidUUID(messageId)) {
      print('[AgentProxy] ⚠️ 警告: 生成的消息ID不是有效的UUID格式: $messageId');
      // 但不抛出异常，继续使用
    }
    
    if (isLocalMode && _localAgent != null) {
      print('[AgentProxy] 调用本地Agent sendMessage');
      final returnedId = await _localAgent.sendMessage(inputWithId);
      
      // 🔑 验证本地Agent没有修改ID
      if (returnedId != messageId) {
        print('[AgentProxy] ⚠️ 严重错误：本地Agent修改了消息ID！期望: $messageId, 实际: $returnedId');
        // 记录错误但继续使用客户端生成的ID
      }
      
      // 将完整消息数据添加到待确认队列（使用客户端生成的messageId）
      final pendingMessage = _createPendingMessage(inputWithId, messageId);
      _pendingMessageQueue.add(pendingMessage);
      
      // ✅ 返回客户端生成的messageId，而不是Agent返回的ID
      return messageId;
    }
    
    print('[AgentProxy] 调用RPC sendMessage');
    // 将 MessageInput 转换为 Map 以便 RPC 传输
    final messageData = inputWithId.toMap();
    print('[AgentProxy] 发送的消息数据: $messageData');
    print('[AgentProxy] 消息数据中的ID: ${messageData['id']}');
    
    final request = SendMessageRequest(
      employeeId: employeeId,
      messageData: messageData,
    );
    final result = await _rpcUtil!.sendMessage(request);
    
    // ✅ 使用客户端生成的ID，而不是远程返回的ID
    // 远程服务器应该使用客户端提供的ID
    final returnedId = result['messageId'] as String? ?? '';
    print('[AgentProxy] 远程返回的消息ID: $returnedId');
    
    if (returnedId.isNotEmpty && returnedId != messageId) {
      print('[AgentProxy] ⚠️ 严重错误：远程Agent修改了消息ID！期望: $messageId, 实际: $returnedId');
    }
    
    // 将完整消息数据添加到待确认队列
    final pendingMessage = _createPendingMessage(inputWithId, messageId);
    _pendingMessageQueue.add(pendingMessage);
    
    print('[AgentProxy] 返回消息ID: $messageId');
    return messageId;
  }
  
  /// 验证UUID格式
  bool _isValidUUID(String uuid) {
    final uuidRegExp = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    return uuidRegExp.hasMatch(uuid);
  }

  /// 中断当前处理
  Future<void> interrupt() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.interrupt();
    }
    final request = InterruptRequest(employeeId: employeeId);
    await _rpcUtil!.interrupt(request);
  }

  /// 撤回消息
  Future<void> revokeMessage(String messageId) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.revokeMessage(messageId);
    }
    final request = RevokeMessageRequest(
      employeeId: employeeId,
      messageId: messageId,
    );
    await _rpcUtil!.revokeMessage(request);
  }

  /// 获取当前权限请求（如果有，同步版本仅适用于本地模式）
  AgentPermissionRequest? getPendingPermissionRequest() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getPendingPermissionRequest();
    }
    return null;
  }

  /// 获取当前权限请求(异步版本,支持远程 RPC)
  Future<AgentPermissionRequest?> getPendingPermissionRequestAsync() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getPendingPermissionRequest();
    }
    final request = GetPendingPermissionRequest(employeeId: employeeId);
    final result = await _rpcUtil!.getPendingPermission(request);
    final requestData = result['request'] as Map<String, dynamic>?;
    if (requestData == null) return null;
    return AgentPermissionRequest.fromMap(requestData);
  }

  // ===== 会话消息 =====

  /// 获取会话消息
  ///
  /// 返回当前 Agent 的会话消息列表
  Future<List<AgentMessage>> getSessionMessages() async {
    if (isLocalMode && _localAgent != null) {
      final messages = await _localAgent.getSessionMessages();
      // 根据返回的消息ID，从消息队列中移除
      _removeConfirmedMessages(messages.map((m) => m.toMap()).toList());
      return messages;
    }
    final request = GetSessionMessagesRequest(employeeId: employeeId);
    final result = await _rpcUtil!.getSessionMessages(request);
    final messages =
        (result['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    // 根据返回的消息ID，从消息队列中移除
    _removeConfirmedMessages(messages);
    // 转换为 AgentMessage 列表
    return messages.map((m) => AgentMessage.fromMap(m)).toList();
  }

  /// 根据用户消息计数获取会话消息
  ///
  /// 统计用户发送的消息数（role='user'），达到 [userMessageLimit] 条时停止，
  /// 返回该时间段内的所有消息（包括user和assistant）
  Future<List<AgentMessage>> getSessionMessagesByUserCount({
    int userMessageLimit = 20,
  }) async {
    if (isLocalMode && _localAgent != null) {
      final messages = await _localAgent.getSessionMessagesByUserCount(
        userMessageLimit: userMessageLimit,
      );
      // 根据返回的消息ID，从消息队列中移除
      _removeConfirmedMessages(messages.map((m) => m.toMap()).toList());
      return messages;
    }
    final request = GetSessionMessagesByUserCountRequest(
      employeeId: employeeId,
      userMessageLimit: userMessageLimit,
    );
    final result = await _rpcUtil!.getSessionMessagesByUserCount(request);
    final messages =
        (result['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    // 根据返回的消息ID，从消息队列中移除
    _removeConfirmedMessages(messages);
    // 转换为 AgentMessage 列表
    return messages.map((m) => AgentMessage.fromMap(m)).toList();
  }

  /// 分页获取会话消息
  ///
  /// [pageSize] 每页数量，默认20条
  /// [offset] 偏移量，默认0
  Future<List<AgentMessage>> getSessionMessagesPaged({
    int pageSize = 20,
    int offset = 0,
  }) async {
    if (isLocalMode && _localAgent != null) {
      final messages = await _localAgent.getSessionMessagesPaged(
        pageSize: pageSize,
        offset: offset,
      );
      // 根据返回的消息ID，从消息队列中移除
      _removeConfirmedMessages(messages.map((m) => m.toMap()).toList());
      return messages;
    }
    final request = GetSessionMessagesPagedRequest(
      employeeId: employeeId,
      pageSize: pageSize,
      offset: offset,
    );
    final result = await _rpcUtil!.getSessionMessagesPaged(request);
    final messages =
        (result['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    // 根据返回的消息ID，从消息队列中移除
    _removeConfirmedMessages(messages);
    // 转换为 AgentMessage 列表
    return messages.map((m) => AgentMessage.fromMap(m)).toList();
  }

  /// 获取未接收消息
  ///
  /// 查询指定设备的未接收消息（本机deviceId，而非proxy的deviceId）
  ///
  /// [receiverDeviceId] 接收设备的ID（本机设备ID）
  Future<List<AgentMessage>> getUnreceivedMessages({
    required String receiverDeviceId,
  }) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getUnreceivedMessages(
        receiverDeviceId: receiverDeviceId,
      );
    }
    final request = GetUnreceivedMessagesRequest(
      employeeId: employeeId,
      receiverDeviceId: receiverDeviceId,
    );
    final result = await _rpcUtil!.getUnreceivedMessages(request);
    final messages =
        (result['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    // 转换为 AgentMessage 列表
    return messages.map((m) => AgentMessage.fromMap(m)).toList();
  }

  /// 标记消息为已接收
  ///
  /// 更新消息接收状态到服务端，后续查询不会返回已接收消息（除非状态更新）
  ///
  /// [receiverDeviceId] 接收设备的ID（本机设备ID）
  /// [messageReceiveList] 消息接收列表（包含消息ID和更新时间）
  Future<void> markMessagesAsReceived({
    required String receiverDeviceId,
    required List<MessageReceiveInfo> messageReceiveList,
  }) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.markMessagesAsReceived(
        receiverDeviceId: receiverDeviceId,
        messageReceiveList: messageReceiveList,
      );
    }
    final request = MarkMessagesAsReceivedRequest(
      employeeId: employeeId,
      receiverDeviceId: receiverDeviceId,
      messageReceiveList: messageReceiveList,
    );
    await _rpcUtil!.markMessagesAsReceived(request);
  }

  /// 清空当前会话
  Future<void> clearCurrentSession() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.clearCurrentSession();
    }
    final request = ClearSessionRequest(employeeId: employeeId);
    await _rpcUtil!.clearSession(request);
  }

  // ===== 上下文管理 =====

  Future<void> setContext(Map<String, dynamic> contextData) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.setContext(contextData);
    }
    final request = SetContextRequest(
      employeeId: employeeId,
      contextData: contextData,
    );
    await _rpcUtil!.setContext(request);
  }

  Map<String, dynamic>? getCurrentContext() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getCurrentContext();
    }
    return _remoteCache.contextData;
  }

  // ===== 模型管理 =====

  Future<void> setProvider(ProviderConfig providerConfig) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.setProvider(providerConfig);
    }
    final request = SetProviderRequest(
      employeeId: employeeId,
      providerConfig: providerConfig.toMap(),
    );
    await _rpcUtil!.setProvider(request);
  }

  ProviderConfig? getProviderConfig() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getProviderConfig();
    }
    final configMap = _remoteCache.providerConfig;
    return configMap != null ? ProviderConfig.fromMap(configMap) : null;
  }

  // ===== 项目管理 =====

  Future<void> setProject(ProjectData? projectData) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.setProject(projectData);
    }
    final request = SetProjectRequest(
      employeeId: employeeId,
      projectData: projectData?.toMap(),
    );
    await _rpcUtil!.setProject(request);
  }

  String? getCurrentProjectUuid() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getCurrentProjectUuid();
    }
    return _remoteCache.projectUuid;
  }

  // ===== 工具管理 =====

  void registerTool(AgentTool tool) {
    if (isLocalMode && _localAgent != null) {
      _localAgent.registerTool(tool);
    }
  }

  void registerTools(List<AgentTool> tools) {
    if (isLocalMode && _localAgent != null) {
      _localAgent.registerTools(tools);
    }
  }

  void unregisterTool(String name) {
    if (isLocalMode && _localAgent != null) {
      _localAgent.unregisterTool(name);
    }
  }

  List<Map<String, dynamic>> getRegisteredTools() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getRegisteredTools();
    }
    return [];
  }

  // ===== 权限管理 =====

  Future<void> respondToPermission(
    String requestId,
    PermissionDecision decision,
  ) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.respondToPermission(requestId, decision);
    }
    final request = RespondPermissionRequest(
      employeeId: employeeId,
      requestId: requestId,
      decision: decision.name,
    );
    await _rpcUtil!.respondPermission(request);
  }

  // ===== 状态查询 =====

  AgentStateSnapshot getStateSnapshot() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getStateSnapshot();
    }
    return _remoteCache.snapshot ?? AgentStateSnapshot.idle();
  }

  /// 获取当前状态快照（异步版本，支持远程 RPC）
  Future<AgentStateSnapshot> getStateSnapshotAsync() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getStateSnapshot();
    }
    final request = GetStateRequest(employeeId: employeeId);
    final result = await _rpcUtil!.getState(request);
    return AgentStateSnapshot.fromMap(result);
  }

  bool get isSending {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.isSending;
    }
    return _remoteCache.status == AgentStatus.processing ||
        _remoteCache.status == AgentStatus.streaming;
  }

  /// 待确认消息队列长度
  int get pendingMessageQueueLength => _pendingMessageQueue.length;

  /// 待确认消息列表（只读副本，包含完整消息内容）
  List<PendingMessage> get pendingMessages =>
      List.unmodifiable(_pendingMessageQueue);

  /// 待确认消息ID列表（只读副本）
  List<String> get pendingMessageIds =>
      _pendingMessageQueue.map((msg) => msg.id).toList();

  // ===== 引用计数 =====

  void attach() {
    if (isLocalMode && _localAgent != null) {
      _localAgent.attach();
    }
  }

  void detach() {
    if (isLocalMode && _localAgent != null) {
      _localAgent.detach();
    }
  }

  // ===== 内部方法 =====

  /// 订阅远程事件流
  void _subscribeRemoteEvents(Stream<Map<String, dynamic>> stream) {
    _remoteEventSubscription?.cancel();
    _remoteEventSubscription = stream.listen(
      _onRemoteEvent,
      onError: (error) {
        // 连接错误
      },
      onDone: () {
        // 连接关闭
      },
    );
  }

  /// 处理远程事件
  void _onRemoteEvent(Map<String, dynamic> eventData) {
    final type = eventData['type'] as String?;
    final data = eventData['data'] as Map<String, dynamic>? ?? {};
    final eventEmployeeUuid = eventData['employeeId'] as String?;

    // 只处理与当前 Agent 相关的事件
    if (eventEmployeeUuid != null && eventEmployeeUuid != employeeId) {
      return;
    }

    // 🔑 关键改进：广播原始事件，供CachedAgentProxy监听
    _eventController.add(eventData);

    switch (type) {
      case 'agentStatusChanged':
        final snapshot = AgentStateSnapshot.fromMap(data);
        // 只在状态真正改变时才更新和广播
        if (_remoteCache.status != snapshot.status) {
          _remoteCache.snapshot = snapshot;
          _remoteCache.status = snapshot.status;
          _stateController.add(snapshot);
        }
        break;

      case 'messageStatusChanged':
        // 消息状态变化事件，需要根据消息状态更新 Agent 状态
        final messageStatusStr = data['status'] as String?;
        if (messageStatusStr != null) {
          final messageStatus = AgentMessageStatus.fromString(messageStatusStr);

          // 只有在消息完成、失败、中断或撤回时才更新状态为 idle
          // 并且当前状态不是 idle 时才触发更新
          if ((messageStatus == AgentMessageStatus.completed ||
                  messageStatus == AgentMessageStatus.failed ||
                  messageStatus == AgentMessageStatus.interrupted ||
                  messageStatus == AgentMessageStatus.revoked) &&
              _remoteCache.status != AgentStatus.idle) {
            // 消息处理完成，状态应该变为 idle
            final idleSnapshot = AgentStateSnapshot(
              status: AgentStatus.idle,
              currentProcessingMessageId: null,
              queuedMessageIds: data['queuedMessageIds'] as List<String>? ?? [],
              isStreaming: false,
              queueLength: data['queueLength'] as int? ?? 0,
            );
            _remoteCache.snapshot = idleSnapshot;
            _remoteCache.status = AgentStatus.idle;
            _stateController.add(idleSnapshot);
          } else {
            // 消息正在排队或处理中，或者已经是 idle 状态
            // 保持当前状态，但可能需要更新其他信息
            if (_remoteCache.snapshot != null) {
              _stateController.add(_remoteCache.snapshot!);
            }
          }
        }
        break;

      default:
        break;
    }
  }

  /// 释放资源
  Future<void> dispose() async {
    await _remoteEventSubscription?.cancel();
    await _stateController.close();
    await _eventController.close();
  }

  // ===== 私有方法 =====

  /// 创建待确认消息
  PendingMessage _createPendingMessage(MessageInput input, String messageId) {
    return PendingMessage(
      id: messageId,
      role: input.role ?? 'user',
      type: input.type,
      content: input.content,
      createdAt: input.createdAt ?? DateTime.now(),
      toolCallId: input.toolCallId,
      toolName: input.toolName,
      toolArguments: input.toolArguments,
      toolResult: input.toolResult,
      metadata: input.metadata,
      sentAt: DateTime.now(),
      pendingStatus: PendingMessageStatus.pending,
      deviceId: deviceId,
      employeeId: employeeId,
    );
  }

  /// 从待确认队列中移除已确认的消息
  ///
  /// 当查询消息列表时，如果返回的消息在队列中，说明已被持久化，可以从队列中移除
  void _removeConfirmedMessages(List<Map<String, dynamic>> messages) {
    if (_pendingMessageQueue.isEmpty) return;

    // 提取返回消息中的所有ID
    final confirmedIds = <String>{};
    for (final message in messages) {
      final id = message['id'] as String?;
      if (id != null && id.isNotEmpty) {
        confirmedIds.add(id);
      }
    }

    // 从队列中移除已确认的消息（根据消息ID）
    _pendingMessageQueue.removeWhere((msg) => confirmedIds.contains(msg.id));
  }
}

/// 远程状态缓存
class _RemoteStateCache {
  AgentStatus status = AgentStatus.idle;
  AgentStateSnapshot? snapshot;
  Map<String, dynamic>? contextData;
  Map<String, dynamic>? providerConfig;
  String? projectUuid;

  void clear() {
    status = AgentStatus.idle;
    snapshot = null;
    contextData = null;
    providerConfig = null;
    projectUuid = null;
  }
}
