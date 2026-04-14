import 'dart:async';

import 'package:uuid/uuid.dart';

import 'agent_proxy.dart';
import '../entity/entity.dart';
import '../agent_state.dart';
import '../tool/agent_tool.dart';
import '../../shared/chat_message.dart' show ToolCall;
import '../../shared/shared.dart' as shared;
import '../../service/message_store_service.dart';
import '../../persistence/stores/mark_read_queue_store.dart';

/// 缓存状态
enum CacheState {
  /// 空闲
  idle,

  /// 加载中
  loading,

  /// 同步中
  syncing,

  /// 错误
  error,
}

/// 带缓存的AgentProxy包装器
///
/// **核心设计**：
/// - 本地模式（isLocalMode=true）：直接透传调用，不缓存（本地Agent已有持久化）
/// - 远程模式（isLocalMode=false）：启用缓存机制，支持离线查看
///
/// **远程模式缓存策略**：
/// 1. 立即显示本地缓存消息（快速响应，支持离线查看）
/// 2. 后台异步加载远程最新消息（实时同步）
/// 3. 智能合并本地和远程消息（避免重复）
/// 4. 更新本地缓存（保持最新状态）
class CachedAgentProxy {
  final AgentProxy _proxy;
  final MessageStoreService _messageStore;
  final String _deviceId;
  final String _employeeId;
  final MarkReadQueueStore _markReadQueueStore;

  /// 底层 AgentProxy 实例（供需要直接访问RPC的调用方使用）
  AgentProxy get proxy => _proxy;

  /// 标记已读回调（由 DeviceClient 注入）
  ///
  /// 当用户通过 CachedAgentProxy.markMessagesAsRead() 标记已读时，
  /// 回调通知 DeviceClient 执行本地标记 + 跨设备广播
  final void Function(String employeeId, String? fromDeviceId)? onMarkAsRead;

  /// 判断消息是否应直接保存为已读（由 DeviceClient 注入）
  ///
  /// 当当前会话窗口打开时，新消息应直接保存为 isRead=1，
  /// 避免重启 app 后从 DB 恢复未读数量。
  final bool Function()? shouldSaveAsReadCallback;

  /// 缓存状态（仅远程模式使用）
  CacheState _cacheState = CacheState.idle;
  final StreamController<CacheState> _cacheStateController =
  StreamController<CacheState>.broadcast();

  /// 消息变更通知流（仅远程模式使用）
  final StreamController<List<AgentMessage>> _messagesController =
  StreamController<List<AgentMessage>>.broadcast();

  DateTime? _lastSyncTime;

  /// 同步锁
  Completer<void>? _syncCompleter;

  /// 初始化锁（防止重复初始化）
  Completer<void>? _initCompleter;

  /// 同步去抖定时器（避免短时间内重复触发远程消息同步）
  Timer? _syncDebounceTimer;

  /// 消息变更通知去抖定时器（避免高频事件下短时间内多次通知 UI）
  Timer? _notifyDebounceTimer;

  /// 权限请求缓存（远程模式使用）
  final Map<String, AgentPermissionRequest> _pendingPermissionRequests = {};

  /// 内存中的工具调用消息（本地模式使用，DB不保存临时消息）
  final Map<String, AgentMessage> _inMemoryToolCallMessages = {};

  /// 事件订阅
  StreamSubscription<AgentEvent>? _eventSubscription;
  StreamSubscription<AgentStateSnapshot>? _stateSubscription;

  /// 是否已释放
  bool _isDisposed = false;

  /// 会话清空标志：sessionCleared 事件处理中设为 true，
  /// 防止 _debouncedSyncMessages 在清空后立即重新同步消息
  bool _sessionClearPending = false;

  /// 会话清空保护定时器：清空后短时间内跳过消息同步
  Timer? _sessionClearGuardTimer;

  /// 是否已释放
  bool get isDisposed => _isDisposed;

  CachedAgentProxy({
    required AgentProxy proxy,
    required MessageStoreService messageStore,
    required String deviceId,
    required String employeeId,
    required MarkReadQueueStore markReadQueueStore,
    this.onMarkAsRead,
    this.shouldSaveAsReadCallback,
  })
      : _proxy = proxy,
        _messageStore = messageStore,
        _deviceId = deviceId,
        _employeeId = employeeId,
        _markReadQueueStore = markReadQueueStore {
    // 关键：只在远程模式下启用缓存
  }

  // ===== 核心方法 =====

  /// 初始化
  ///
  /// 仅加载本地缓存，完成后通过 [_notifyMessagesChanged] 通知 UI 刷新。
  /// 需要调用方在合适时机触发 [syncFromRemote] 来同步远程数据。
  /// 双重锁：防止并发重复初始化，重复调用直接复用首次的 Future。
  Future<void> initialize() async {
    if (_isDisposed) return;

    // 双重锁：快速判断 + Completer 复用
    if (_initCompleter != null) return _initCompleter!.future;

    _initCompleter = Completer<void>();
    try {
      // 初始化事件监听（本地和远程模式都需要）
      _initializeEventListeners();

      // 本地模式：直接通知
      if (_proxy.isLocalMode) {
        _notifyMessagesChanged();
        return;
      }

      // 远程模式：直接通知
      _updateCacheState(CacheState.loading);
      _updateCacheState(CacheState.idle);
      _notifyMessagesChanged();
    } finally {
      _initCompleter!.complete();
      _initCompleter = null;
    }
  }

  /// 从远程同步消息和状态（后台调用）
  ///
  /// 在 [initialize] 之后调用，同步远程未接收消息、远程会话状态和权限请求。
  /// 同步完成后自动通过 [_notifyMessagesChanged] 通知 UI 刷新。
  /// 双重锁：防止并发同步，重复调用直接复用首次的 Future。
  Future<void> syncFromRemote() async {
    if (_isDisposed || _proxy.isLocalMode) return;

    // 双重锁：快速判断 + Completer 复用
    if (_syncCompleter != null) return _syncCompleter!.future;

    _syncCompleter = Completer<void>();

    try {
      try {
        // 同步远程消息
        await _syncMessagesFromRemote();
      } catch (e, st) {
        print('[CachedAgentProxy] 同步远程消息失败: $e\n$st');
      }

      // 同步远程状态和权限请求
      try {
        await _syncRemoteStateAndPermission();
        print('[CachedAgentProxy] 同步远程状态成功');
      } catch (e) {
        print('[CachedAgentProxy] 同步远程状态失败: $e');
      }

      // 同步完成后，重发待处理的标记已读队列
      await _flushMarkAsReadQueue();
      _syncCompleter!.complete();
      _syncCompleter = null;
    } catch (e, st) {
      print(e);
      _syncCompleter!.completeError(e, st);
      _syncCompleter = null;
    }
  }


  /// 初始化事件监听
  void _initializeEventListeners() {
    print('[CachedAgentProxy] 初始化事件监听...');

    // 监听Agent事件（本地和远程模式都需要）
    _eventSubscription = _proxy.onEvent.listen((event) {
      _handleAgentEvent(event);
    });

    // 监听状态变更
    _stateSubscription = _proxy.onStateChanged.listen((state) {
      _handleStateChange(state);
    });
  }

  /// 处理Agent事件
  void _handleAgentEvent(AgentEvent event) {
    final type = event.type;
    final data = event.data;
    final employeeId = event.employeeId;

    // 只处理当前员工的事件
    if (employeeId != null && employeeId != _employeeId) {
      return;
    }

    print('[CachedAgentProxy] 收到事件: $type');

    switch (type) {
      case AgentEventType.messageStatusChanged:
        _handleMessageStatusChanged(data);
        break;
      case AgentEventType.agentStatusChanged:
        _handleAgentStatusChanged(data);
        break;
      case AgentEventType.toolCallStart:
      case AgentEventType.toolCallResult:
        _handleToolEvent(type.value, data);
        break;
      case AgentEventType.toolPermissionRequest:
        _handlePermissionRequest(data);
        break;
      case AgentEventType.messageReplied:
        _handleMessageReplied(data);
        break;
      case AgentEventType.messageQueued:
        _handleMessageQueued(data);
        break;
      case AgentEventType.messageProcessing:
        _handleMessageProcessing(data);
        break;
      case AgentEventType.sessionCleared:
        _handleSessionCleared(data);
        break;
      case AgentEventType.toolPermissionResponse:
        _handlePermissionResponse(data);
        break;
      case AgentEventType.unknown:
      case AgentEventType.messageReadStatusChanged:
        break;
    }
  }

  /// 处理消息状态变更事件
  void _handleMessageStatusChanged(Map<String, dynamic> data) {
    final messageId = data['messageId'] as String?;
    final status = data['status'] as String?;
    final error = data['error'] as String?;

    if (messageId == null || status == null) return;

    print('[CachedAgentProxy] 消息状态变更: $messageId -> $status${error != null
        ? ", error: $error"
        : ""}');

    // 更新本地缓存中的消息状态（包含错误信息）
    _updateMessageStatus(messageId, status, error: error);

    // 如果是失败状态且有错误信息，创建一条错误消息返回给客户端
    if (status == 'failed' && error != null) {
      _createErrorMessage(messageId, error);
    }

    // 如果是完成或失败状态，立即同步远程消息（避免 500ms 去抖延迟）
    if (status == 'completed' || status == 'failed' ||
        status == 'interrupted') {
      // 本地模式：从内存缓存移除已完成的工具调用消息
      _inMemoryToolCallMessages.removeWhere((key, _) {
        // 移除所有以该 messageId 相关的工具调用（按 toolCallId 关联）
        return key == messageId ||
            key == messageId.replaceFirst('local_toolcall_', '');
      });
      _syncMessagesFromRemote();
    }
  }

  /// 创建错误消息（当消息处理失败时，生成一条 assistant 类型的错误消息给客户端可见）
  Future<void> _createErrorMessage(String originalMessageId,
      String errorContent) async {
    // 截断过长的错误信息，避免存储和显示问题
    final displayError = errorContent.length > 500
        ? '${errorContent.substring(0, 500)}...'
        : errorContent;

    final errorMessage = AgentMessage(
      id: 'error_$originalMessageId',
      role: 'assistant',
      type: 'error',
      content: '处理失败: $displayError',
      createdAt: DateTime.now(),
      status: 'failed',
      metadata: {
        'error': true,
        'originalMessageId': originalMessageId,
        'updateTime': DateTime.now().toIso8601String(),
      },
    );

    // 添加到缓存
    await _addMessageToCache(errorMessage);

    print('[CachedAgentProxy] 已创建错误消息: ${errorMessage.id}');
  }

  /// 处理Agent状态变更事件
  void _handleAgentStatusChanged(Map<String, dynamic> data) {
    final status = data['status'] as String?;
    print('[CachedAgentProxy] Agent状态变更: $status');

    // 如果是空闲状态，可能意味着消息处理完成
    if (status == 'idle') {
      // 使用 debounce 避免与 completed/failed 状态的同步重复
      _debouncedSyncMessages();
    }
  }

  /// 处理工具事件
  void _handleToolEvent(String eventType, Map<String, dynamic> data) {
    print('[CachedAgentProxy] 工具事件: $eventType');

    if (eventType == 'toolCallStart') {
      // 工具调用开始：创建工具调用消息
      _createToolCallMessage(data);
    } else if (eventType == 'toolCallResult') {
      // 工具调用完成：更新工具消息
      _updateToolCallMessage(data);

      // 使用 debounce 同步消息，避免与 completed/idle 重复
      _debouncedSyncMessages();
    }
  }

  /// 创建工具调用消息（本地临时消息，用于实时显示工具调用状态）
  Future<void> _createToolCallMessage(Map<String, dynamic> data) async {
    final toolCallId = data['toolCallId'] as String?;
    final toolName = data['toolName'] as String?;
    final arguments = data['arguments'] as Map<String, dynamic>?;

    if (toolCallId == null || toolName == null) return;

    // 去重检查：避免重复创建相同 toolCallId 的临时消息
    final localId = 'local_toolcall_$toolCallId';
    final exists = await _messageStore.getMessage(localId, deviceId: _deviceId);
    if (exists != null) {
      print(
          '[CachedAgentProxy] 工具调用临时消息已存在，跳过: $toolName ($toolCallId)');
      return;
    }

    print('[CachedAgentProxy] 创建工具调用消息: $toolName ($toolCallId)');

    // 创建工具调用消息：role 为 assistant（functionCall 是 assistant 发出的），
    // ID 使用前缀避免与远程同步的消息 ID 冲突
    final toolMessage = AgentMessage(
      id: localId,
      role: 'assistant',
      type: 'functionCall',
      toolCallId: toolCallId,
      toolName: toolName,
      toolArguments: arguments,
      toolCalls: [
        ToolCall(id: toolCallId, name: toolName, arguments: arguments ?? {})
      ],
      status: 'processing',
      createdAt: DateTime.now(),
      metadata: {'localToolCall': true},
    );

    // 保存到数据库（必须 await，确保 notify 时 DB 已写入）
    await _saveToolCallMessageToDb(toolMessage);

    // 本地模式：将工具调用消息保存到内存缓存
    if (_proxy.isLocalMode) {
      _inMemoryToolCallMessages[toolCallId] = toolMessage;
    }

    _notifyMessagesChanged();
  }

  /// 更新工具调用消息
  Future<void> _updateToolCallMessage(Map<String, dynamic> data) async {
    final toolCallId = data['toolCallId'] as String?;
    final result = data['result'] as String?;
    final isError = data['isError'] as bool? ?? false;

    if (toolCallId == null) return;

    print('[CachedAgentProxy] 更新工具调用消息: $toolCallId');

    // 根据错误类型确定状态
    String newStatus;
    if (!isError) {
      newStatus = 'completed';
    } else if (result != null && result.contains('权限被拒绝')) {
      newStatus = 'interrupted';
      print('[CachedAgentProxy] 工具调用被权限打断: $toolCallId');
    } else {
      newStatus = 'failed';
    }

    // 本地模式：从内存缓存更新
    if (_proxy.isLocalMode &&
        _inMemoryToolCallMessages.containsKey(toolCallId)) {
      final existing = _inMemoryToolCallMessages[toolCallId]!;
      _inMemoryToolCallMessages[toolCallId] = existing.copyWith(
        toolResult: result,
        status: newStatus,
        metadata: {
          ...?existing.metadata,
          'isError': isError,
          'updateTime': DateTime.now().toIso8601String(),
        },
      );
      _notifyMessagesChanged();
      return;
    }

    // 远程模式：在数据库中查找本地临时消息
    final localId = 'local_toolcall_$toolCallId';
    final existing = await _messageStore.getMessage(
        localId, deviceId: _deviceId);
    if (existing == null) return;

    final updatedMessage = _chatMessageToAgentMessage(existing).copyWith(
      toolResult: result,
      status: newStatus,
      metadata: {
        ...?existing.metadata,
        'isError': isError,
        'updateTime': DateTime.now().toIso8601String(),
      },
    );

    // 先更新数据库，再通知 UI（确保 UI 读到最新状态）
    await _updateToolCallMessageInDb(updatedMessage);
    _notifyMessagesChanged();
  }

  /// 保存工具调用消息到数据库
  ///
  /// 本地模式不持久化临时消息，因为：
  /// - 原始 assistant 消息已包含 toolCalls 数据并持久化
  /// - tool result 消息也会被持久化
  /// - 临时消息持久化会导致前端 _loadMessages 重复创建 functionCall
  Future<void> _saveToolCallMessageToDb(AgentMessage message) async {
    // 本地模式：DB 不需要临时工具调用消息
    if (_proxy.isLocalMode) return;
    try {
      final chatMsg = _agentMessageToChatMessage(message);
      await _messageStore.addMessage(
          chatMsg, deviceId: _deviceId, updateWatermark: false);
    } catch (e) {
      print('[CachedAgentProxy] 保存工具调用消息失败: $e');
    }
  }

  /// 更新数据库中的工具调用消息
  Future<void> _updateToolCallMessageInDb(AgentMessage message) async {
    try {
      final chatMsg = _agentMessageToChatMessage(message);
      await _messageStore.updateMessage(chatMsg, updateWatermark: false);
    } catch (e) {
      print('[CachedAgentProxy] 更新工具调用消息失败: $e');
    }
  }

  /// 清理已被远程消息取代的本地工具调用临时消息
  ///
  /// 远程同步拉取的消息中包含官方的 assistant 消息（含 toolCalls）和
  /// tool result 消息，与本地创建的 `local_toolcall_*` 临时消息重复。
  /// 此方法提取远程消息中的 toolCallId，删除对应的本地临时消息。
  Future<void> _cleanupSupersededLocalToolCalls(
      List<AgentMessage> syncedMessages) async {
    if (_proxy.isLocalMode) return;

    final toolCallIds = <String>{};
    for (final msg in syncedMessages) {
      // 从 assistant 消息的 toolCalls 字段提取
      if (msg.toolCalls != null) {
        for (final tc in msg.toolCalls!) {
          if (tc.id.isNotEmpty) toolCallIds.add(tc.id);
        }
      }
      // 从 tool result 消息的 toolCallId 字段提取
      if (msg.toolCallId != null && msg.toolCallId!.isNotEmpty) {
        toolCallIds.add(msg.toolCallId!);
      }
    }

    if (toolCallIds.isEmpty) return;

    int deletedCount = 0;
    for (final toolCallId in toolCallIds) {
      final localId = 'local_toolcall_$toolCallId';
      try {
        await _messageStore.hardDeleteMessage(localId, deviceId: _deviceId);
        deletedCount++;
      } catch (_) {
        // 消息不存在则忽略
      }
    }

    if (deletedCount > 0) {
      print(
          '[CachedAgentProxy] 已清理 $deletedCount 条被远程消息取代的本地工具调用临时消息');
    }
  }

  /// 处理权限请求事件
  void _handlePermissionRequest(Map<String, dynamic> data) {
    try {
      final request = AgentPermissionRequest.fromMap(data);
      _pendingPermissionRequests[request.requestId] = request;
      print('[CachedAgentProxy] 收到权限请求: ${request
          .requestId}, 函数: ${request.functionName}');

      // 通知客户端重新加载消息
      _notifyMessagesChanged();
    } catch (e) {
      print('[CachedAgentProxy] 处理权限请求失败: $e');
    }
  }

  /// 处理权限响应事件（其他设备已授权/拒绝，本地需清除缓存）
  void _handlePermissionResponse(Map<String, dynamic> data) {
    final requestId = data['requestId'] as String?;
    if (requestId == null) return;

    final removed = _pendingPermissionRequests.remove(requestId);
    if (removed != null) {
      print('[CachedAgentProxy] 收到权限响应（其他设备已处理）: $requestId');
      _notifyMessagesChanged();
    }
  }

  /// 处理消息被回复事件
  Future<void> _handleMessageReplied(Map<String, dynamic> data) async {
    final originalMessageId = data['originalMessageId'] as String?;
    final replyMessageId = data['replyMessageId'] as String?;

    if (originalMessageId == null || replyMessageId == null) return;

    print(
        '[CachedAgentProxy] 消息被回复: $originalMessageId -> $replyMessageId');

    // 从数据库查找并更新原消息
    final existing = await _messageStore.getMessage(
        originalMessageId, deviceId: _deviceId);
    if (existing != null) {
      final updatedChatMsg = existing.copyWith(
        metadata: {
          ...?existing.metadata,
          'replyMessageId': replyMessageId,
          'replied': true,
          'updateTime': DateTime.now().toIso8601String(),
        },
      );
      await _messageStore.updateMessage(updatedChatMsg, deviceId: _deviceId);
      _notifyMessagesChanged();
    }

    // 立即同步消息列表以获取最新的回复内容
    _syncMessagesFromRemote();
  }

  /// 处理队列中消息事件
  Future<void> _handleMessageQueued(Map<String, dynamic> data) async {
    final messageId = data['messageId'] as String?;
    final queuePosition = data['queuePosition'] as int?;

    if (messageId == null) return;

    print('[CachedAgentProxy] 消息进入队列: $messageId, 位置: $queuePosition');

    // 从数据库查找并更新消息状态
    final existing = await _messageStore.getMessage(
        messageId, deviceId: _deviceId);
    if (existing != null) {
      final updatedChatMsg = existing.copyWith(
        metadata: {
          ...?existing.metadata,
          'queuePosition': queuePosition,
          'updateTime': DateTime.now().toIso8601String(),
        },
      );
      await _messageStore.updateMessage(updatedChatMsg, deviceId: _deviceId);
      await _messageStore.updateMessageStatus(
        messageId, shared.MessageStatus.fromString('queued'),
      );
      _notifyMessagesChanged();
    }
  }

  /// 处理消息处理中事件
  void _handleMessageProcessing(Map<String, dynamic> data) {
    final messageId = data['messageId'] as String?;

    if (messageId == null) return;

    print('[CachedAgentProxy] 消息开始处理: $messageId');

    // 更新消息状态为processing
    _updateMessageStatus(messageId, 'processing');
  }

  /// 处理会话清空事件
  ///
  /// 远端某个客户端清空了会话，本地需要同步清空消息和重置水位线。
  Future<void> _handleSessionCleared(Map<String, dynamic> data) async {
    if (_proxy.isLocalMode) return;

    print('[CachedAgentProxy] 收到会话清空事件: employeeId=$_employeeId');

    // 设置清空保护标志，防止 idle 状态触发的 _debouncedSyncMessages 重新同步消息
    _sessionClearPending = true;
    _sessionClearGuardTimer?.cancel();
    _sessionClearGuardTimer = Timer(const Duration(seconds: 2), () {
      _sessionClearPending = false;
      _sessionClearGuardTimer = null;
    });

    _pendingPermissionRequests.clear();

    // 在删除前获取本地 maxSeq，用于设置 clearSeq = lastSeq = maxSeq
    final maxSeq = _messageStore.getMaxSeq(_employeeId);
    await _messageStore.deleteMessages(_employeeId, deviceId: _deviceId);
    if (maxSeq > 0) {
      _messageStore.resetLastSeq(_employeeId, maxSeq);
    }
    _notifyMessagesChanged();

    print('[CachedAgentProxy] 本地会话已清空，水位线: clearSeq=lastSeq=$maxSeq');
  }

  /// 处理状态变更
  void _handleStateChange(AgentStateSnapshot state) {
    print('[CachedAgentProxy] 状态变更: ${state.status}');

    // 会话清空保护期内，跳过消息同步
    if (_sessionClearPending) {
      print('[CachedAgentProxy] 会话清空保护期内，跳过状态变更同步');
      return;
    }

    // 根据状态决定是否触发消息同步
    if (state.status == AgentStatus.idle) {
      // Agent空闲时，使用 debounce 同步消息（避免与 agentStatusChanged 重复）
      _debouncedSyncMessages();
    } else if (state.status == AgentStatus.waitingPermission) {
      // Agent等待权限时，查询权限请求
      _queryPendingPermission();
    }
  }

  /// 查询待处理的权限请求
  Future<void> _queryPendingPermission() async {
    if (_isDisposed || _proxy.isLocalMode) return;

    try {
      print('[CachedAgentProxy] 查询待处理的权限请求...');

      final permissionRequest = await _proxy.getPendingPermissionRequestAsync();
      if (permissionRequest != null) {
        _pendingPermissionRequests[permissionRequest.requestId] =
            permissionRequest;
        print('[CachedAgentProxy] 已缓存权限请求: ${permissionRequest
            .requestId}');

        // 通知客户端重新加载消息
        _notifyMessagesChanged();
      }
    } catch (e) {
      print('[CachedAgentProxy] 查询权限请求失败: $e');
    }
  }

  /// 去抖同步远程消息（500ms 内只触发一次，避免短时间内多次调用）
  void _debouncedSyncMessages() {
    // 会话清空保护期内，跳过消息同步
    if (_sessionClearPending) {
      print('[CachedAgentProxy] 会话清空保护期内，跳过去抖同步');
      return;
    }
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (!_sessionClearPending) {
        _syncMessagesFromRemote();
      }
    });
  }

  /// 从远程同步消息（简化版）
  ///
  /// 流程：
  /// 1. 查询服务端 clearSeq，硬删除本地 seq < clearSeq 的消息
  /// 2. 查询本地消息 maxSeq，查询服务端 lastSeq，拉取差量消息直接写入
  Future<void> _syncMessagesFromRemote() async {
    if (_isDisposed || _proxy.isLocalMode) return;

    try {
      print('[CachedAgentProxy] 开始从远程同步消息...');

      // 1. 查询服务端 clearSeq，硬删除本地旧消息
      try {
        final remoteClearSeq = await _proxy.getClearSeq();
        if (remoteClearSeq > 0) {
          final deletedCount = _messageStore.deleteMessagesBeforeSeq(
            _employeeId, remoteClearSeq,
          );
          if (deletedCount > 0) {
            print(
                '[CachedAgentProxy] 根据 clearSeq=$remoteClearSeq 删除了 $deletedCount 条本地消息');
            _messageStore.resetLastSeq(_employeeId, remoteClearSeq);
          }
        }
      } catch (e) {
        print('[CachedAgentProxy] 获取远程 clearSeq 失败: $e');
      }

      // 2. 查询本地消息 maxSeq
      final localMaxSeq = _messageStore.getMaxSeq(_employeeId);

      // 3. 查询服务端 lastSeq
      int remoteLastSeq = -1;
      try {
        remoteLastSeq = await _proxy.getMaxSeq();
      } catch (e) {
        print('[CachedAgentProxy] 获取远程 lastSeq 失败: $e');
        return;
      }

      print(
          '[CachedAgentProxy] localMaxSeq=$localMaxSeq, remoteLastSeq=$remoteLastSeq');

      // 4. 增量拉取：远程有更新的消息时，拉取 seq > localMaxSeq 的消息
      if (remoteLastSeq > localMaxSeq) {
        const batchSize = 20;
        final allNewMessages = <AgentMessage>[];
        int currentSeq = localMaxSeq;

        while (true) {
          final batch = await _proxy.getMessagesAfterSeq(
            lastSeq: currentSeq,
            limit: batchSize,
          );

          if (batch.isEmpty) break;
          allNewMessages.addAll(batch);

          for (final msg in batch) {
            final seq = msg.metadata?['seq'] as int? ?? 0;
            if (seq > currentSeq) currentSeq = seq;
          }

          if (batch.length < batchSize) break;
        }

        // 5. 直接写入本地（INSERT OR REPLACE，无需比较）
        if (allNewMessages.isNotEmpty) {
          for (final message in allNewMessages) {
            final deletedRaw = message.metadata?['deleted'];
            final isDeleted = deletedRaw is bool
                ? deletedRaw
                : (deletedRaw is int ? deletedRaw != 0 : false);

            if (isDeleted) {
              try {
                await _messageStore.hardDeleteMessage(
                    message.id, deviceId: _deviceId);
              } catch (_) {}
              continue;
            }

            final forceRead = message.role == 'assistant' &&
                (shouldSaveAsReadCallback?.call() ?? false);
            final chatMsg = _agentMessageToChatMessage(
                message, forceRead: forceRead);
            await _messageStore.addMessage(chatMsg, deviceId: _deviceId);
          }

          // 清理已被远程消息取代的本地工具调用临时消息
          await _cleanupSupersededLocalToolCalls(allNewMessages);

          // 更新本地水位线
          _messageStore.updateLastSeq(_employeeId, currentSeq);
          _notifyMessagesChanged();

          print('[CachedAgentProxy] 同步完成: 拉取 ${allNewMessages
              .length} 条, lastSeq=$currentSeq');
        }
      } else {
        print('[CachedAgentProxy] 无新消息需要同步');
      }
    } catch (e, st) {
      print('[CachedAgentProxy] 同步远程消息失败: $e\n$st');
    }

    // 清理残留的本地工具调用临时消息
    _cleanupStaleToolCallMessages();
  }

  /// 清理残留的本地工具调用临时消息
  ///
  /// 当 agent 被重启或崩溃后，之前发出的工具调用可能永远没有结果返回。
  /// 这些残留的 `local_toolcall_*` 消息会一直处于 processing 状态。
  /// 在每次同步完成后，将这些消息标记为 failed（无结果）。
  void _cleanupStaleToolCallMessages() {
    if (_proxy.isLocalMode) return;

    final staleIds = _messageStore.getStaleLocalToolCallMessages(_employeeId);
    if (staleIds.isEmpty) return;

    for (final uuid in staleIds) {
      _messageStore.updateMessageStatus(
        uuid, shared.MessageStatus.failed,
        error: '工具调用无结果（agent 可能已重启）',
      );
    }
    print('[CachedAgentProxy] 已清理 ${staleIds.length} 条残留工具调用消息');
  }

  /// 重发待处理的标记已读队列
  ///
  /// 断线重连后，自动重新发送之前失败的标记已读请求。
  /// 每条请求独立发送，成功的立即移除，失败的保留等待下次重发。
  Future<void> _flushMarkAsReadQueue() async {
    if (_isDisposed || _proxy.isLocalMode) return;

    final pending = _markReadQueueStore.getPending(employeeId: _employeeId);
    if (pending.isEmpty) return;

    print(
        '[CachedAgentProxy] 开始重发 ${pending.length} 条待处理的标记已读请求');

    final successIds = <int>[];
    for (final entry in pending) {
      try {
        await _proxy.markMessagesAsRead(
          readerDeviceId: entry.readerDeviceId,
          messageIds: entry.messageIds,
        );
        successIds.add(entry.id);
      } catch (e) {
        // 单条失败不影响后续发送，保留在队列中等待下次重发
        print(
            '[CachedAgentProxy] 重发标记已读请求失败: ${entry.id}, error: $e');
      }
    }

    if (successIds.isNotEmpty) {
      _markReadQueueStore.removeAll(successIds);
      print('[CachedAgentProxy] 标记已读队列已清理 ${successIds
          .length} 条成功记录');
    }
  }

  /// 同步远程会话状态和权限请求
  ///
  /// 在初始化时查询远程 Agent 状态，如果正在等待权限，则查询并缓存权限请求。
  /// 同时同步远程的 Provider 配置和项目 UUID 到本地缓存。
  Future<void> _syncRemoteStateAndPermission() async {
    if (_isDisposed || _proxy.isLocalMode) return;

    try {
      print('[CachedAgentProxy] 开始同步远程会话状态和权限请求...');

      // 1. 查询远程 Agent 状态
      final stateSnapshot = await _proxy.getStateSnapshotAsync();
      print('[CachedAgentProxy] 远程 Agent 状态: ${stateSnapshot.status}');

      // 2. 同步远程 Provider 配置
      try {
        final providerConfig = await _proxy.getProviderConfigAsync();
        if (providerConfig != null) {
          print('[CachedAgentProxy] 远程 Provider 配置: ${providerConfig
              .provider} · ${providerConfig.model}');
        } else {
          print('[CachedAgentProxy] 远程无 Provider 配置');
        }
      } catch (e) {
        print('[CachedAgentProxy] 同步远程 Provider 配置失败: $e');
      }

      // 3. 同步远程项目 UUID
      try {
        final projectUuid = await _proxy.getCurrentProjectUuidAsync();
        print('[CachedAgentProxy] 远程项目 UUID: $projectUuid');
      } catch (e) {
        print('[CachedAgentProxy] 同步远程项目 UUID 失败: $e');
      }

      // 4. 同步远程技能配置
      try {
        final skills = await _proxy.getSkillsConfigAsync();
        print('[CachedAgentProxy] 远程技能配置: ${skills.length} 个');
      } catch (e) {
        print('[CachedAgentProxy] 同步远程技能配置失败: $e');
      }

      // 5. 同步远程 MCP 配置
      try {
        final mcpConfigs = await _proxy.getMcpConfigsAsync();
        print('[CachedAgentProxy] 远程 MCP 配置: ${mcpConfigs.length} 个');
      } catch (e) {
        print('[CachedAgentProxy] 同步远程 MCP 配置失败: $e');
      }

      print('[CachedAgentProxy] 远程状态同步完成');
    } catch (e) {
      print('[CachedAgentProxy] 同步远程会话状态失败: $e');
    }
  }

  /// 主动同步远程消息（供外部调用）
  ///
  /// 与 [syncFromRemote] 不同，此方法使用独立的 Completer，
  /// 不会被 [syncFromRemote] 的锁阻塞。
  Future<void> syncWithRemote() async {
    if (_proxy.isLocalMode) {
      return;
    }

    // 防止并发同步
    if (_syncCompleter != null) {
      return _syncCompleter!.future;
    }

    _syncCompleter = Completer<void>();
    _updateCacheState(CacheState.syncing);

    try {
      // 调用统一的同步逻辑
      await _syncMessagesFromRemote();

      _lastSyncTime = DateTime.now();
      _updateCacheState(CacheState.idle);

      _syncCompleter!.complete();
    } catch (e) {
      _updateCacheState(CacheState.error);
      _syncCompleter!.completeError(e);
    } finally {
      _syncCompleter = null;
    }
  }

  // ===== 内部方法（仅远程模式使用） =====

  /// 生成消息ID（标准UUID格式）
  String _generateMessageId() {
    return const Uuid().v4();
  }

  /// 获取消息的更新时间
  DateTime _getMessageUpdateTime(AgentMessage message) {
    // 优先使用metadata中的updateTime（始终为ISO8601字符串）
    final updateTime = message.metadata?['updateTime'];
    if (updateTime is String) {
      return DateTime.parse(updateTime);
    }

    // 其次使用createdAt
    return message.createdAt;
  }

  /// 添加消息到数据库并通知
  Future<void> _addMessageToCache(AgentMessage message,
      {bool updateWatermark = true}) async {
    await _saveMessageToDatabase(message, updateWatermark: updateWatermark);
    _notifyMessagesChanged();
  }

  /// 更新消息状态
  Future<void> _updateMessageStatus(String messageId, String status,
      {String? error}) async {
    await _messageStore.updateMessageStatus(
      messageId, shared.MessageStatus.fromString(status),
      error: error,
    );
    _notifyMessagesChanged();
  }

  /// 保存消息到数据库
  ///
  /// 本地临时消息（localOnly）不更新同步水位线，
  /// 避免本地分配的 seq 污染 LSN 增量同步。
  Future<void> _saveMessageToDatabase(AgentMessage message,
      {bool updateWatermark = true}) async {
    try {
      final forceRead = message.role == 'assistant' &&
          (shouldSaveAsReadCallback?.call() ?? false);
      final chatMsg = _agentMessageToChatMessage(message, forceRead: forceRead);
      await _messageStore.addMessage(
          chatMsg, deviceId: _deviceId, updateWatermark: updateWatermark);
    } catch (e) {
      print('保存消息到数据库失败: $e');
    }
  }

  /// 更新缓存状态
  void _updateCacheState(CacheState state) {
    if (_proxy.isLocalMode) return;

    _cacheState = state;
    _cacheStateController.add(state);
  }

  /// 通知消息变更（带 16ms 去抖，合并同一帧内的多次变更）
  void _notifyMessagesChanged() {
    if (_isDisposed) return;
    _notifyDebounceTimer?.cancel();
    _notifyDebounceTimer = Timer(const Duration(milliseconds: 16), () async {
      if (_isDisposed) return;
      final messages = await getMessages();
      _messagesController.add(List.unmodifiable(messages));
    });
  }

  // ===== 转换方法 =====

  /// ChatMessage → AgentMessage 桥接（MessageStore 返回 ChatMessage，缓存使用 AgentMessage）
  AgentMessage _chatMessageToAgentMessage(shared.ChatMessage cm) {
    final metadata = <String, dynamic>{};

    // 系统字段放入 metadata（AgentMessage 的兼容层）
    if (cm.seq > 0) metadata['seq'] = cm.seq;
    if (cm.deleted) metadata['deleted'] = 1;
    if (cm.updatedAt != null) {
      metadata['updateTime'] = cm.updatedAt!.toIso8601String();
    }
    if (cm.isRead) metadata['isRead'] = true;

    // 合并用户自定义 metadata
    if (cm.metadata != null) {
      metadata.addAll(cm.metadata!);
    }

    // toolResults 合并到 metadata（AgentMessage 消费者从 metadata 读取）
    if (cm.toolResults != null) {
      metadata['toolResults'] = cm.toolResults!.map((r) => r.toMap()).toList();
    }

    return AgentMessage(
      id: cm.id,
      role: cm.role.name,
      type: cm.type,
      content: cm.content,
      createdAt: cm.createdAt,
      toolCallId: cm.toolCallId,
      toolName: cm.toolName,
      toolArguments: cm.toolArguments,
      toolResult: cm.toolResult,
      toolCalls: cm.toolCalls?.map((tc) =>
          ToolCall(id: tc.id, name: tc.name, arguments: tc.arguments)).toList(),
      status: cm.status != shared.MessageStatus.none ? cm.status.name : null,
      metadata: metadata.isNotEmpty ? metadata : null,
    );
  }

  /// AgentMessage → ChatMessage 桥接（缓存 AgentMessage 保存到 MessageStore）
  shared.ChatMessage _agentMessageToChatMessage(AgentMessage am,
      {bool forceRead = false}) {
    // 从 metadata 提取同步系统字段（AgentImpl 注入到 metadata 中）
    final metadata = am.metadata;
    final seq = metadata?['seq'] as int? ?? 0;
    final deletedRaw = metadata?['deleted'];
    final deleted = deletedRaw is bool
        ? deletedRaw
        : (deletedRaw is int ? deletedRaw != 0 : false);
    final isReadRaw = metadata?['isRead'];
    final remoteIsRead = isReadRaw is bool
        ? isReadRaw
        : (isReadRaw is int ? isReadRaw != 0 : false);

    return shared.ChatMessage(
      id: am.id,
      employeeId: _employeeId,
      role: shared.MessageRole.fromString(am.role),
      type: am.type,
      content: am.content,
      createdAt: am.createdAt,
      updatedAt: _getMessageUpdateTime(am),
      toolCallId: am.toolCallId,
      toolName: am.toolName,
      toolArguments: am.toolArguments,
      toolResult: am.toolResult,
      toolCalls: am.toolCalls
          ?.map((tc) =>
          shared.ToolCall(id: tc.id, name: tc.name, arguments: tc.arguments))
          .toList(),
      status: shared.MessageStatus.fromString(am.status ?? 'none'),
      seq: seq,
      deleted: deleted,
      isRead: forceRead || remoteIsRead,
      deviceId: _deviceId,
      metadata: metadata,
    );
  }

  // ===== 代理方法（智能透传） =====

  /// 发送消息（优化版：事件驱动）
  Future<String> sendMessage(MessageInput input) async {
    // 1. 客户端生成UUID作为消息ID
    final messageId = input.id ?? _generateMessageId();
    print('[CachedAgentProxy] 客户端生成消息ID: $messageId');

    // 2. 创建本地消息（立即可见）
    final localMessage = AgentMessage(
      id: messageId,
      role: input.role ?? 'user',
      type: input.type,
      content: input.content,
      createdAt: input.createdAt ?? DateTime.now(),
      toolCallId: input.toolCallId,
      toolName: input.toolName,
      toolArguments: input.toolArguments,
      toolResult: input.toolResult,
      metadata: {
        ...?input.metadata,
        'localOnly': true, // 标记为本地消息
        'updateTime': DateTime.now().toIso8601String(),
      },
      status: 'pending',
    );

    print('[CachedAgentProxy] 创建本地消息: ID=${localMessage
        .id}, role=${localMessage.role}');

    // 3. 添加到本地缓存（立即可见，不更新同步水位线）
    await _addMessageToCache(localMessage, updateWatermark: false);

    // 4. 发送到远程（异步）
    try {
      // 传递生成的messageId，确保远程使用相同的ID
      final inputWithId = input.copyWith(id: messageId);
      print('[CachedAgentProxy] 发送消息到远程: ID=$messageId');

      final returnedId = await _proxy.sendMessage(inputWithId);

      print('[CachedAgentProxy] AgentProxy返回的消息ID: $returnedId');

      // 🔑 验证返回的ID是否一致
      if (returnedId != messageId) {
        print(
            '[CachedAgentProxy] ⚠️ 严重错误：AgentProxy返回了不同的ID！期望: $messageId, 实际: $returnedId');
        // 强制使用客户端生成的ID
      }

      // 发送成功，更新状态
      if (!_proxy.isLocalMode) {
        _updateMessageStatus(messageId, 'sent');
        print('[CachedAgentProxy] 消息状态更新为sent: ID=$messageId');
      }
    } catch (e) {
      // 发送失败，更新状态
      if (!_proxy.isLocalMode) {
        _updateMessageStatus(messageId, 'failed');
        print('[CachedAgentProxy] 消息发送失败: ID=$messageId, error: $e');
      }
      rethrow;
    }

    return messageId;
  }

  /// 获取消息（直接从数据库读取）
  Future<List<AgentMessage>> getMessages() async {
    final messageEntities = await _messageStore.getMessagesWithDeviceId(
      _deviceId,
      _employeeId,
    );

    var allMessages = messageEntities.map(_chatMessageToAgentMessage).toList();

    // 合并内存中的工具调用消息（本地模式）
    if (_inMemoryToolCallMessages.isNotEmpty) {
      final dbIds = allMessages.map((m) => m.id).toSet();
      for (final msg in _inMemoryToolCallMessages.values) {
        if (!dbIds.contains(msg.id)) {
          allMessages.add(msg);
        }
      }
    }

    if (allMessages.isEmpty) return [];

    // 按时间倒序排列（最新的在前）
    allMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // 统计用户消息，达到20条时停止
    int userMessageCount = 0;
    final selectedMessages = <AgentMessage>[];

    for (final message in allMessages) {
      selectedMessages.add(message);
      if (message.role == 'user') {
        userMessageCount++;
        if (userMessageCount >= 20) break;
      }
    }

    // 按时间正序排列
    selectedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return selectedMessages;
  }

  /// 获取消息（别名方法）
  Future<List<AgentMessage>> getSessionMessages() => getMessages();

  /// 获取消息（强制刷新）
  ///
  /// 立即同步远程消息并返回最新数据
  /// 建议在以下场景使用：
  /// - 监听到Agent状态变化时（processing -> idle）
  /// - 收到消息状态变更通知时
  /// - 需要确保数据最新时
  Future<List<AgentMessage>> getMessagesForceRefresh() async {
    if (_proxy.isLocalMode) {
      return await _proxy.getSessionMessages();
    }

    await syncWithRemote();
    return getMessages();
  }

  /// 主动同步远程消息（用于监听状态变化时调用）
  ///
  /// 建议在监听 `onStateChanged` 流时调用此方法：
  /// ```dart
  /// proxy.onStateChanged.listen((state) {
  ///   if (state.status == AgentStatus.idle) {
  ///     proxy.syncOnStateChange();
  ///   }
  /// });
  /// ```
  Future<void> syncOnStateChange() async {
    if (_proxy.isLocalMode) return;
    await syncWithRemote();
  }

  /// 中断当前处理
  Future<void> interrupt() => _proxy.interrupt();

  /// 撤回消息
  Future<void> revokeMessage(String messageId) async {
    await _proxy.revokeMessage(messageId);

    // 远程模式：通知更新
    if (!_proxy.isLocalMode) {
      _notifyMessagesChanged();
    }

    // 从数据库中删除消息
    try {
      await _messageStore.hardDeleteMessage(messageId, deviceId: _deviceId);
      print('[CachedAgentProxy] 已从数据库删除消息: $messageId');

      // 本地模式：还需要删除助手回复消息（它们的时间戳紧随用户消息之后）
      if (_proxy.isLocalMode) {
        // 获取所有消息
        final allMessages = await _proxy.getSessionMessages();

        // 找到用户消息
        final userMsgIndex = allMessages.indexWhere((m) => m.id == messageId);
        if (userMsgIndex >= 0) {
          // 删除用户消息之后的所有助手消息（直到遇到下一条用户消息）
          for (int i = userMsgIndex + 1; i < allMessages.length; i++) {
            final msg = allMessages[i];
            if (msg.role == 'assistant') {
              try {
                await _messageStore.hardDeleteMessage(
                    msg.id, deviceId: _deviceId);
                print('[CachedAgentProxy] 已从数据库删除助手消息: ${msg.id}');

                // 从 Agent 内存中删除助手消息
                await _proxy.removeMessageFromMemory(msg.id);
              } catch (e) {
                print('[CachedAgentProxy] 删除助手消息失败: $e');
              }
            } else {
              // 遇到下一条用户消息，停止删除
              break;
            }
          }
        }

        // 从 Agent 内存中删除用户消息
        await _proxy.removeMessageFromMemory(messageId);
      }
    } catch (e) {
      print('[CachedAgentProxy] 从数据库删除消息失败: $e');
    }
  }

  /// 获取当前权限请求
  AgentPermissionRequest? getPendingPermissionRequest() {
    // 远程模式：从缓存中获取
    if (!_proxy.isLocalMode && _pendingPermissionRequests.isNotEmpty) {
      return _pendingPermissionRequests.values.first;
    }
    // 本地模式：透传
    return _proxy.getPendingPermissionRequest();
  }

  /// 获取当前权限请求（异步版本）
  Future<AgentPermissionRequest?> getPendingPermissionRequestAsync() =>
      _proxy.getPendingPermissionRequestAsync();

  /// 清空当前会话
  ///
  /// 【修复】清空后重置本地水位线为 0，避免后续同步拉取大量无意义的删除事件。
  Future<void> clearCurrentSession() async {
    // 第一步：清空远程会话
    await _proxy.clearCurrentSession();

    // 第二步：清空本地数据库（远程模式）
    if (!_proxy.isLocalMode) {
      _pendingPermissionRequests.clear();
      // 使用正确的 deviceId 删除消息
      await _messageStore.deleteMessages(_employeeId, deviceId: _deviceId);
      // 【修复】重置水位线，避免后续增量同步拉取大量删除事件
      // 注意：updateLastSeq 使用 MAX 语义无法降为 0，必须用 resetLastSeq
      _messageStore.resetLastSeq(_employeeId, 0);
      print('[CachedAgentProxy] 会话已清空，水位线已重置为 0');
      _notifyMessagesChanged();
    }
  }

  /// 设置上下文
  Future<void> setContext(Map<String, dynamic> contextData) =>
      _proxy.setContext(contextData);

  /// 获取当前上下文
  Map<String, dynamic>? getCurrentContext() => _proxy.getCurrentContext();

  /// 设置Provider配置
  Future<void> setProvider(ProviderConfig providerConfig) =>
      _proxy.setProvider(providerConfig);

  /// 获取Provider配置
  ProviderConfig? getProviderConfig() => _proxy.getProviderConfig();

  /// 获取Provider配置（异步版本，支持远程 RPC）
  Future<ProviderConfig?> getProviderConfigAsync() =>
      _proxy.getProviderConfigAsync();

  // ===== 技能管理 =====

  /// 设置技能配置
  Future<void> setSkills(List<Map<String, dynamic>> skillMaps) =>
      _proxy.setSkills(skillMaps);

  /// 获取技能配置
  List<Map<String, dynamic>> getSkillsConfig() =>
      _proxy.getSkillsConfig();

  /// 获取技能配置（异步版本，支持远程 RPC）
  Future<List<Map<String, dynamic>>> getSkillsConfigAsync() =>
      _proxy.getSkillsConfigAsync();

  // ===== MCP 管理 =====

  /// 设置 MCP 服务器配置
  Future<void> setMcpConfigs(List<Map<String, dynamic>> mcpConfigMaps) =>
      _proxy.setMcpConfigs(mcpConfigMaps);

  /// 获取 MCP 服务器配置
  List<Map<String, dynamic>> getMcpConfigs() =>
      _proxy.getMcpConfigs();

  /// 获取 MCP 服务器配置（异步版本，支持远程 RPC）
  Future<List<Map<String, dynamic>>> getMcpConfigsAsync() =>
      _proxy.getMcpConfigsAsync();

  /// 设置项目
  Future<void> setProject(ProjectData? projectData) =>
      _proxy.setProject(projectData);

  /// 获取当前项目UUID
  String? getCurrentProjectUuid() => _proxy.getCurrentProjectUuid();

  /// 获取当前项目UUID（异步版本）
  Future<String?> getCurrentProjectUuidAsync() =>
      _proxy.getCurrentProjectUuidAsync();

  /// 检查路径是否存在于目标设备上（异步版本，支持远程 RPC）
  Future<PathExistsResult> checkPathExists(String path) =>
      _proxy.checkPathExists(path);

  /// 列出目录内容
  Future<DirectoryListingResult> listDirectory(String path) =>
      _proxy.listDirectory(path);

  /// 获取文件/目录信息
  Future<FileInfoResult> getFileInfo(String path) =>
      _proxy.getFileInfo(path);

  /// 创建目录
  Future<FileOpResult> createDirectory(String path) =>
      _proxy.createDirectory(path);

  /// 删除文件/目录
  Future<FileOpResult> deleteFile(String path) =>
      _proxy.deleteFile(path);

  /// 重命名/移动文件
  Future<FileOpResult> renameFile(String oldPath, String newPath) =>
      _proxy.renameFile(oldPath, newPath);

  /// 注册工具
  void registerTool(AgentTool tool) => _proxy.registerTool(tool);

  /// 注册多个工具
  void registerTools(List<AgentTool> tools) => _proxy.registerTools(tools);

  /// 注销工具
  void unregisterTool(String name) => _proxy.unregisterTool(name);

  /// 获取已注册的工具
  List<Map<String, dynamic>> getRegisteredTools() =>
      _proxy.getRegisteredTools();

  /// 响应权限请求
  Future<void> respondToPermission(String requestId,
      PermissionDecision decision) async {
    await _proxy.respondToPermission(requestId, decision);

    // 清除缓存的权限请求
    _pendingPermissionRequests.remove(requestId);
    print('[CachedAgentProxy] 已响应权限请求并清除缓存: $requestId');
  }

  /// 获取状态快照
  AgentStateSnapshot getStateSnapshot() => _proxy.getStateSnapshot();

  /// 获取状态快照（异步版本）
  Future<AgentStateSnapshot> getStateSnapshotAsync() =>
      _proxy.getStateSnapshotAsync();

  /// 获取正在调用的工具 callId 列表
  List<String> getCallingToolIds() => _proxy.getCallingToolIds();

  /// 获取正在调用的工具 callId 列表（异步版本）
  Future<List<String>> getCallingToolIdsAsync() =>
      _proxy.getCallingToolIdsAsync();

  // ===== 基础属性 =====

  String get employeeId => _employeeId;

  String get deviceId => _deviceId;

  bool get isLocalMode => _proxy.isLocalMode;

  AgentStatus get status => _proxy.status;

  bool get isAlive => _proxy.isAlive;

  bool get isSending => _proxy.isSending;

  Stream<AgentStateSnapshot> get onStateChanged => _proxy.onStateChanged;

  // ===== 消息已读标记 =====

  /// 查询当前会话的未读消息数量
  ///
  /// 从本地数据库统计 assistant 且 is_read=0 的消息数量
  Future<int> getUnreadCount() async {
    return _messageStore.getUnreadCount(_employeeId);
  }

  /// 查询当前会话的未读消息 ID 列表
  ///
  /// 从本地数据库查询 assistant 且 is_read=0 的消息 UUID 列表，
  /// 按创建时间升序排列。
  Future<List<String>> getUnreadMessageIds() async {
    return _messageStore.getUnreadMessageIds(_employeeId);
  }

  /// 标记当前会话的所有消息为已读
  ///
  /// 用户打开会话窗口时调用此方法，会：
  /// 1. 通过 [onMarkAsRead] 回调通知 DeviceClient（本地标记 + 跨设备广播）
  /// 2. 持久化标记已读请求到本地队列（确保断线重连后重发）
  /// 3. 通过 [_proxy] RPC 通知远程 Agent 记录已读状态
  void markMessagesAsRead({List<String>? messageIds}) {
    onMarkAsRead?.call(_employeeId, _deviceId);

    // 持久化到标记已读队列（远程模式）
    if (!_proxy.isLocalMode) {
      _markReadQueueStore.enqueue(
        employeeId: _employeeId,
        readerDeviceId: _deviceId,
        messageIds: messageIds,
      );
    }

    // 通知远程 Agent 记录已读状态（fire-and-forget）
    _proxy.markMessagesAsRead(
      readerDeviceId: _deviceId,
      messageIds: messageIds,
    ).then((_) {
      // 远程调用成功，清空该员工的队列
      _markReadQueueStore.clear(employeeId: _employeeId);
    }).catchError((_) {
      // 远程调用失败，队列保留，断线重连后会重发
      print('[CachedAgentProxy] 标记已读远程调用失败，已保留到队列等待重发');
    });
  }

  /// 清除当前会话的全部未读数量（将所有未读标记为已读）
  ///
  /// 与 [markMessagesAsRead] 不同，此方法同时：
  /// 1. 在本地数据库中批量更新 is_read=1
  /// 2. 触发 [markMessagesAsRead] 通知远程
  /// 3. 通知 UI 刷新消息列表
  Future<void> clearAllUnread() async {
    // 1. 本地数据库批量标记已读
    _messageStore.markAsReadInDb(_employeeId);

    // 2. 通知远程 Agent
    markMessagesAsRead();

    // 3. 通知 UI 刷新
    _notifyMessagesChanged();
  }

  /// 查询消息已读状态
  ///
  /// 设备重新打开时从 Agent 查询哪些消息已读
  Future<MessagesReadStatusResult> getMessagesReadStatus({
    required String deviceId,
  }) {
    return _proxy.getMessagesReadStatus(deviceId: deviceId);
  }

  // ===== 缓存相关属性（仅远程模式有效） =====

  /// 缓存状态流
  Stream<CacheState> get onCacheStateChanged {
    if (_proxy.isLocalMode) {
      // 本地模式返回空流
      return Stream.empty();
    }
    return _cacheStateController.stream;
  }

  /// 消息变更流（仅远程模式有效）
  ///
  /// 当消息缓存更新时，会通过此流通知监听者
  /// 包括：发送消息、同步远程消息、撤回消息等操作
  Stream<List<AgentMessage>> get onMessagesChanged {
    return _messagesController.stream;
  }

  /// 当前缓存状态
  CacheState get cacheState =>
      !_proxy.isLocalMode ? _cacheState : CacheState.idle;

  /// 缓存消息数量
  Future<int> get cachedMessageCount async {
    if (_proxy.isLocalMode) return 0;
    final messages = await _messageStore.getMessagesWithDeviceId(
        _deviceId, _employeeId);
    return messages.length;
  }

  /// 最后同步时间
  DateTime? get lastSyncTime => !_proxy.isLocalMode ? _lastSyncTime : null;

  /// 是否已同步
  bool get isSynced => !_proxy.isLocalMode && _lastSyncTime != null;

  /// 是否启用缓存
  bool get needCache => !_proxy.isLocalMode;

  // ===== 清理方法 =====

  /// 清除缓存
  Future<void> clearCache() async {
    if (_proxy.isLocalMode) return;

    _lastSyncTime = null;
    // 使用正确的 deviceId 删除消息
    await _messageStore.deleteMessages(_employeeId, deviceId: _deviceId);
  }

  /// 释放资源
  Future<void> dispose() async {
    _isDisposed = true;

    // 取消去抖定时器
    _syncDebounceTimer?.cancel();
    _notifyDebounceTimer?.cancel();
    _sessionClearGuardTimer?.cancel();

    // 取消事件订阅
    await _eventSubscription?.cancel();
    await _stateSubscription?.cancel();

    // 清除权限请求缓存
    _pendingPermissionRequests.clear();

    // 清除内存中的工具调用消息
    _inMemoryToolCallMessages.clear();

    if (!_proxy.isLocalMode) {
      await _cacheStateController.close();
      await _messagesController.close();
    }
  }
}
