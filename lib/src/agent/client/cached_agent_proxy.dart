import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'agent_proxy.dart';
import '../entity/entity.dart';
import '../agent_state.dart';
import '../tool/agent_tool.dart';
import '../../persistence/entities/message_entity.dart';
import '../../persistence/stores/sync_watermark_store.dart';
import '../../service/message_store_service.dart';

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

  /// 是否需要缓存（仅远程模式需要）
  late final bool _needCache;

  /// 缓存状态（仅远程模式使用）
  CacheState _cacheState = CacheState.idle;
  final StreamController<CacheState> _cacheStateController =
      StreamController<CacheState>.broadcast();

  /// 消息变更通知流（仅远程模式使用）
  final StreamController<List<AgentMessage>> _messagesController =
      StreamController<List<AgentMessage>>.broadcast();

  /// 消息缓存（仅远程模式使用）
  List<AgentMessage> _cachedMessages = [];
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

  /// 事件订阅
  StreamSubscription<AgentEvent>? _eventSubscription;
  StreamSubscription<AgentStateSnapshot>? _stateSubscription;

  /// 是否已释放
  bool _isDisposed = false;

  CachedAgentProxy({
    required AgentProxy proxy,
    required MessageStoreService messageStore,
    required String deviceId,
    required String employeeId,
    this.onMarkAsRead,
    this.shouldSaveAsReadCallback,
  }) : _proxy = proxy,
       _messageStore = messageStore,
       _deviceId = deviceId,
       _employeeId = employeeId {
    // 关键：只在远程模式下启用缓存
    _needCache = !_proxy.isLocalMode;
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

      // 本地模式：只加载本地缓存
      if (!_needCache) {
        await _loadLocalMessagesByUserCount();
        _notifyMessagesChanged();
        return;
      }

      // 远程模式：只加载本地缓存
      _updateCacheState(CacheState.loading);

      try {
        await _loadLocalMessagesByUserCount();
      } catch (e) {
        print('[CachedAgentProxy] 加载本地缓存失败: $e');
      }

      _updateCacheState(CacheState.idle);
      // 通知 UI 本地缓存已就绪
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
    if (_isDisposed || !_needCache) return;

    // 双重锁：快速判断 + Completer 复用
    if (_syncCompleter != null) return _syncCompleter!.future;

    _syncCompleter = Completer<void>();

    try {
      // 同步远程消息
      if (_cachedMessages.isEmpty) {
        print('[CachedAgentProxy] 本地缓存为空，使用基础同步方法');
        await _syncMessagesFromRemoteBasic();
      } else {
        print('[CachedAgentProxy] 本地缓存不为空，尝试同步未接收消息');
        await _syncMessagesFromRemote();
      }
    } catch (e) {
      print('[CachedAgentProxy] 同步远程消息失败: $e');
    }

    // 同步远程状态和权限请求
    try {
      await _syncRemoteStateAndPermission();
    } catch (e) {
      print('[CachedAgentProxy] 同步远程状态失败: $e');
    }

    _syncCompleter!.complete();
    _syncCompleter = null;
  }

  /// 从本地缓存加载消息（按用户消息计数统计）
  Future<void> _loadLocalMessagesByUserCount() async {
    try {
      final messageEntities = await _messageStore.getMessagesWithDeviceId(
        _deviceId,
        _employeeId,
      );

      // 按用户消息计数统计
      final allMessages = messageEntities.map(_entityToMessage).toList();

      if (allMessages.isEmpty) {
        _cachedMessages = [];
        return;
      }

      // 按时间倒序排列（最新的在前）
      allMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      // 统计用户消息，达到20条时停止
      int userMessageCount = 0;
      final selectedMessages = <AgentMessage>[];

      for (final message in allMessages) {
        selectedMessages.add(message);

        // 统计用户消息
        if (message.role == 'user') {
          userMessageCount++;

          // 达到限制时停止
          if (userMessageCount >= 20) {
            break;
          }
        }
      }

      // 按时间正序排列
      selectedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      _cachedMessages = selectedMessages;
      print('[CachedAgentProxy] 从本地缓存加载 ${_cachedMessages.length} 条消息（用户消息计数）');
    } catch (e) {
      print('[CachedAgentProxy] 加载本地缓存失败: $e');
      _cachedMessages = [];
    }
  }

  /// 合并未接收消息
  Future<void> _mergeUnreceivedMessages(List<AgentMessage> unreceivedMessages) async {
    print('[CachedAgentProxy] 开始合并未接收消息...');

    for (final message in unreceivedMessages) {
      // 检查是否为远程删除事件（deleted=1 由 Host 端软删除同步过来）
      final isDeleted = message.metadata?['deleted'] == 1;

      if (isDeleted) {
        // 远程删除：从本地缓存和数据库中删除对应消息
        final existingIndex = _cachedMessages.indexWhere((m) => m.id == message.id);
        if (existingIndex != -1) {
          _cachedMessages.removeAt(existingIndex);
          try {
            await _messageStore.hardDeleteMessage(message.id, deviceId: _deviceId);
            print('[CachedAgentProxy] 同步删除消息: ${message.id}');
          } catch (e) {
            print('[CachedAgentProxy] 同步删除消息失败: ${message.id}, $e');
          }
        }
        continue;
      }

      // 检查是否已存在
      final existingIndex = _cachedMessages.indexWhere((m) => m.id == message.id);

      if (existingIndex == -1) {
        // 新消息，添加到缓存
        _cachedMessages.add(message);
        final forceRead = message.role == 'assistant' &&
            (shouldSaveAsReadCallback?.call() ?? false);
        final entity = _messageToEntity(message, forceRead: forceRead);
        await _messageStore.addMessage(entity, deviceId: _deviceId);
        print('[CachedAgentProxy] 添加新消息: ${message.id}');
      } else {
        // 已存在，根据updateTime更新
        final existingMessage = _cachedMessages[existingIndex];
        final existingUpdateTime = _getMessageUpdateTime(existingMessage);
        final newUpdateTime = _getMessageUpdateTime(message);

        if (newUpdateTime.isAfter(existingUpdateTime)) {
          // 更新消息
          _cachedMessages[existingIndex] = message;
          final entity = _messageToEntity(message);
          await _messageStore.updateMessage(entity, deviceId: _deviceId);
          print('[CachedAgentProxy] 更新消息: ${message.id}');
        }
      }
    }

    // 清理已被远程消息替代的本地临时工具调用消息
    _cleanupLocalToolCallMessages(unreceivedMessages);

    // 排序
    _cachedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // 通知界面
    _notifyMessagesChanged();

    print('[CachedAgentProxy] 未接收消息合并完成，共 ${_cachedMessages.length} 条消息');
  }

  /// 清理本地临时工具调用消息
  ///
  /// 当远程同步的 assistant 消息已包含对应的 toolCalls 时，
  /// 移除之前创建的本地临时 functionCall 消息，避免重复显示
  void _cleanupLocalToolCallMessages(List<AgentMessage> remoteMessages) {
    // 收集远程消息中所有 toolCalls 的 ID
    final remoteToolCallIds = <String>{};
    for (final msg in remoteMessages) {
      if (msg.role == 'assistant' && msg.toolCalls != null) {
        for (final tc in msg.toolCalls!) {
          remoteToolCallIds.add(tc.id);
        }
      }
    }

    if (remoteToolCallIds.isEmpty) return;

    // 移除本地临时消息中 toolCallId 已被远程消息覆盖的条目
    final before = _cachedMessages.length;
    _cachedMessages.removeWhere((m) =>
      m.metadata?['localToolCall'] == true &&
      m.toolCallId != null &&
      remoteToolCallIds.contains(m.toolCallId));

    final removed = before - _cachedMessages.length;
    if (removed > 0) {
      print('[CachedAgentProxy] 清理了 $removed 条本地临时工具调用消息（已被远程消息替代）');
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
      case 'messageStatusChanged':
        _handleMessageStatusChanged(data);
        break;
      case 'agentStatusChanged':
        _handleAgentStatusChanged(data);
        break;
      case 'toolCallStart':
      case 'toolCallResult':
        _handleToolEvent(type, data);
        break;
      case 'toolPermissionRequest':
        _handlePermissionRequest(data);
        break;
      case 'messageReplied':
        _handleMessageReplied(data);
        break;
      case 'messageQueued':
        _handleMessageQueued(data);
        break;
      case 'messageProcessing':
        _handleMessageProcessing(data);
        break;
    }
  }

  /// 处理消息状态变更事件
  void _handleMessageStatusChanged(Map<String, dynamic> data) {
    final messageId = data['messageId'] as String?;
    final status = data['status'] as String?;
    final error = data['error'] as String?;

    if (messageId == null || status == null) return;

    print('[CachedAgentProxy] 消息状态变更: $messageId -> $status${error != null ? ", error: $error" : ""}');

    // 更新本地缓存中的消息状态（包含错误信息）
    _updateMessageStatus(messageId, status, error: error);

    // 如果是失败状态且有错误信息，创建一条错误消息返回给客户端
    if (status == 'failed' && error != null) {
      _createErrorMessage(messageId, error);
    }

    // 如果是完成或失败状态，触发消息列表查询
    if (status == 'completed' || status == 'failed' || status == 'interrupted') {
      // 使用 debounce 统一触发，避免与 idle/toolCallResult 等重复
      _debouncedSyncMessages();
    }
  }

  /// 创建错误消息（当消息处理失败时，生成一条 assistant 类型的错误消息给客户端可见）
  void _createErrorMessage(String originalMessageId, String errorContent) {
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
    _addMessageToCache(errorMessage);

    // 保存到数据库（仅远程模式）
    if (_needCache) {
      _saveMessageToDatabase(errorMessage);
    }

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
  void _createToolCallMessage(Map<String, dynamic> data) {
    final toolCallId = data['toolCallId'] as String?;
    final toolName = data['toolName'] as String?;
    final arguments = data['arguments'] as Map<String, dynamic>?;

    if (toolCallId == null || toolName == null) return;

    // 去重检查：避免重复创建相同 toolCallId 的临时消息
    final exists = _cachedMessages.any(
      (m) => m.metadata?['localToolCall'] == true && m.toolCallId == toolCallId,
    );
    if (exists) {
      print('[CachedAgentProxy] 工具调用临时消息已存在，跳过: $toolName ($toolCallId)');
      return;
    }

    print('[CachedAgentProxy] 创建工具调用消息: $toolName ($toolCallId)');

    // 创建工具调用消息：role 为 assistant（functionCall 是 assistant 发出的），
    // ID 使用前缀避免与远程同步的消息 ID 冲突
    final toolMessage = AgentMessage(
      id: 'local_toolcall_$toolCallId',
      role: 'assistant',
      type: 'functionCall',
      toolCallId: toolCallId,
      toolName: toolName,
      toolArguments: arguments,
      toolCalls: [ToolCall(id: toolCallId, name: toolName, arguments: arguments ?? {})],
      status: 'processing',
      createdAt: DateTime.now(),
      metadata: {'localToolCall': true},
    );

    // 添加到缓存
    _cachedMessages.add(toolMessage);
    _notifyMessagesChanged();

    // 保存到数据库
    _saveToolCallMessageToDb(toolMessage);
  }

  /// 更新工具调用消息
  void _updateToolCallMessage(Map<String, dynamic> data) {
    final toolCallId = data['toolCallId'] as String?;
    final result = data['result'] as String?;
    final isError = data['isError'] as bool? ?? false;

    if (toolCallId == null) return;

    print('[CachedAgentProxy] 更新工具调用消息: $toolCallId');

    // 在缓存中查找并更新：优先匹配本地临时消息（通过 metadata 标记 + toolCallId）
    final index = _cachedMessages.indexWhere((m) =>
      m.metadata?['localToolCall'] == true && m.toolCallId == toolCallId);
    if (index != -1) {
      final message = _cachedMessages[index];

      // 根据错误类型确定状态
      String newStatus;
      if (!isError) {
        newStatus = 'completed';
      } else if (result != null && result.contains('权限被拒绝')) {
        // 权限被拒绝，标记为中断状态
        newStatus = 'interrupted';
        print('[CachedAgentProxy] 工具调用被权限打断: $toolCallId');
      } else {
        // 其他错误，标记为失败
        newStatus = 'failed';
      }

      final updatedMessage = message.copyWith(
        toolResult: result,
        status: newStatus,
        metadata: {
          ...?message.metadata,
          'isError': isError,
          'updateTime': DateTime.now().toIso8601String(),
        },
      );
      _cachedMessages[index] = updatedMessage;
      _notifyMessagesChanged();

      // 更新数据库
      _updateToolCallMessageInDb(updatedMessage);
    }
  }

  /// 保存工具调用消息到数据库
  ///
  /// 本地模式不持久化临时消息，因为：
  /// - 原始 assistant 消息已包含 toolCalls 数据并持久化
  /// - tool result 消息也会被持久化
  /// - 临时消息持久化会导致前端 _loadMessages 重复创建 functionCall
  Future<void> _saveToolCallMessageToDb(AgentMessage message) async {
    // 本地模式：DB 不需要临时工具调用消息
    if (!_needCache) return;
    try {
      final entity = _agentMessageToEntity(message);
      await _messageStore.addMessage(entity, deviceId: _deviceId);
    } catch (e) {
      print('[CachedAgentProxy] 保存工具调用消息失败: $e');
    }
  }

  /// 更新数据库中的工具调用消息
  Future<void> _updateToolCallMessageInDb(AgentMessage message) async {
    try {
      final entity = _agentMessageToEntity(message);
      await _messageStore.updateMessage(entity);
    } catch (e) {
      print('[CachedAgentProxy] 更新工具调用消息失败: $e');
    }
  }

  /// 将 AgentMessage 转换为 AiEmployeeMessageEntity
  AiEmployeeMessageEntity _agentMessageToEntity(AgentMessage message) {
    final map = <String, dynamic>{
      'uuid': message.id,
      'employeeId': _employeeId,
      'role': message.role,
      'type': message.type,
      'content': message.content,
      'toolCallId': message.toolCallId,
      'toolName': message.toolName,
      'toolArguments': message.toolArguments,
      'toolResult': message.toolResult,
      'toolCalls': message.toolCalls?.map((tc) => tc.toMap()).toList(),
      'processingStatus': message.status ?? 'none',
      'createTime': message.createdAt.millisecondsSinceEpoch,
      'metadata': message.metadata,
    };
    return AiEmployeeMessageEntity.fromMessageMap(map);
  }

  /// 处理权限请求事件
  void _handlePermissionRequest(Map<String, dynamic> data) {
    try {
      final request = AgentPermissionRequest.fromMap(data);
      _pendingPermissionRequests[request.requestId] = request;
      print('[CachedAgentProxy] 收到权限请求: ${request.requestId}, 函数: ${request.functionName}');

      // 通知客户端重新加载消息
      _notifyMessagesChanged();
    } catch (e) {
      print('[CachedAgentProxy] 处理权限请求失败: $e');
    }
  }

  /// 处理消息被回复事件
  void _handleMessageReplied(Map<String, dynamic> data) {
    final originalMessageId = data['originalMessageId'] as String?;
    final replyMessageId = data['replyMessageId'] as String?;

    if (originalMessageId == null || replyMessageId == null) return;

    print('[CachedAgentProxy] 消息被回复: $originalMessageId -> $replyMessageId');

    // 更新原消息的metadata，添加回复信息
    final index = _cachedMessages.indexWhere((m) => m.id == originalMessageId);
    if (index != -1) {
      final message = _cachedMessages[index];
      final updatedMessage = message.copyWith(
        metadata: {
          ...?message.metadata,
          'replyMessageId': replyMessageId,
          'replied': true,
          'updateTime': DateTime.now().toIso8601String(),
        },
      );
      _cachedMessages[index] = updatedMessage;
      _notifyMessagesChanged();
      _updateMessageInDatabase(updatedMessage);
    }

    // 同步消息列表以获取最新的回复内容（使用 debounce 避免重复）
    _debouncedSyncMessages();
  }

  /// 处理队列中消息事件
  void _handleMessageQueued(Map<String, dynamic> data) {
    final messageId = data['messageId'] as String?;
    final queuePosition = data['queuePosition'] as int?;

    if (messageId == null) return;

    print('[CachedAgentProxy] 消息进入队列: $messageId, 位置: $queuePosition');

    // 更新消息状态为queued
    final index = _cachedMessages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      final message = _cachedMessages[index];
      final updatedMessage = message.copyWith(
        status: 'queued',
        metadata: {
          ...?message.metadata,
          'queuePosition': queuePosition,
          'updateTime': DateTime.now().toIso8601String(),
        },
      );
      _cachedMessages[index] = updatedMessage;
      _notifyMessagesChanged();
      _updateMessageInDatabase(updatedMessage);
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

  /// 处理状态变更
  void _handleStateChange(AgentStateSnapshot state) {
    print('[CachedAgentProxy] 状态变更: ${state.status}');

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
    if (_isDisposed || !_needCache) return;

    try {
      print('[CachedAgentProxy] 查询待处理的权限请求...');

      final permissionRequest = await _proxy.getPendingPermissionRequestAsync();
      if (permissionRequest != null) {
        _pendingPermissionRequests[permissionRequest.requestId] = permissionRequest;
        print('[CachedAgentProxy] 已缓存权限请求: ${permissionRequest.requestId}');

        // 通知客户端重新加载消息
        _notifyMessagesChanged();
      }
    } catch (e) {
      print('[CachedAgentProxy] 查询权限请求失败: $e');
    }
  }

  /// 去抖同步远程消息（500ms 内只触发一次，避免短时间内多次调用）
  void _debouncedSyncMessages() {
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _syncMessagesFromRemote();
    });
  }

  /// 从远程同步消息（基于 LSN 增量同步）
  Future<void> _syncMessagesFromRemote() async {
    if (_isDisposed || !_needCache) return;

    try {
      print('[CachedAgentProxy] 开始从远程同步消息（LSN 增量）...');

      // 1. 读取本地水位线
      final watermarkStore = SyncWatermarkStore(deviceId: _deviceId);
      final lastSeq = watermarkStore.getLastSeq(_employeeId);

      // 2. 获取服务端最大 seq
      int remoteMaxSeq = -1; // -1 表示获取失败
      bool maxSeqObtained = false;
      try {
        remoteMaxSeq = await _proxy.getMaxSeq();
        maxSeqObtained = true;
      } catch (e) {
        print('[CachedAgentProxy] 获取远程 maxSeq 失败: $e');
      }

      print('[CachedAgentProxy] 本地水位线: lastSeq=$lastSeq, 服务端 maxSeq=${maxSeqObtained ? remoteMaxSeq : "获取失败"}');

      // 3. 水位线校验：本地 > 服务端说明服务端被清空，需重置本地
      //    【修复】仅在 maxSeq 获取成功（> 0）时才执行校验，
      //    避免网络超时/失败时 remoteMaxSeq=0 误触发清空
      if (maxSeqObtained && remoteMaxSeq > 0 && lastSeq > 0 && lastSeq > remoteMaxSeq) {
        print('[CachedAgentProxy] 本地水位线($lastSeq) > 服务端 maxSeq($remoteMaxSeq)，'
            '检测到服务端数据已清空，重置本地数据...');

        // 清空本地缓存和数据库
        await _messageStore.deleteMessages(_employeeId, deviceId: _deviceId);
        _cachedMessages.clear();

        // 重置水位线
        watermarkStore.updateLastSeq(_employeeId, 0);

        // 降级为基础同步（全量拉取）
        await _syncMessagesFromRemoteBasic();
        return;
      }

      // maxSeq 获取失败时跳过本次同步，等待下次触发
      if (!maxSeqObtained) {
        print('[CachedAgentProxy] 无法获取服务端 maxSeq，跳过本次同步');
        return;
      }

      // 4. 分批拉取 seq > lastSeq 的消息
      const batchSize = 20;
      final allNewMessages = <AgentMessage>[];
      int currentSeq = lastSeq;

      while (true) {
        final batch = await _proxy.getMessagesAfterSeq(
          lastSeq: currentSeq,
          limit: batchSize,
        );

        if (batch.isEmpty) break;
        allNewMessages.addAll(batch);

        // 取本批次最大 seq 作为下一批的起点
        for (final msg in batch) {
          final seq = msg.metadata?['seq'] as int? ?? 0;
          if (seq > currentSeq) currentSeq = seq;
        }

        if (batch.length < batchSize) break;
      }

      print('[CachedAgentProxy] 从远程获取到 ${allNewMessages.length} 条新消息');

      // 5. 合并消息到本地缓存
      if (allNewMessages.isNotEmpty) {
        await _mergeUnreceivedMessages(allNewMessages);

        // 6. 更新本地水位线
        watermarkStore.updateLastSeq(_employeeId, currentSeq);
        print('[CachedAgentProxy] 水位线已更新: lastSeq=$currentSeq');
      }

      print('[CachedAgentProxy] 消息同步完成，共 ${_cachedMessages.length} 条消息');
    } catch (e) {
      print('[CachedAgentProxy] 同步远程消息失败: $e');
    }
  }

  /// 从远程同步消息（基础方法，用于初始化时本地缓存为空的情况）
  Future<void> _syncMessagesFromRemoteBasic() async {
    if (_isDisposed || !_needCache) return;

    try {
      print('[CachedAgentProxy] 开始从远程同步消息（基础方法）...');

      // 1. 根据用户消息计数查询远程消息
      final remoteMessages = await _proxy.getSessionMessagesByUserCount(
        userMessageLimit: 20,
      );

      print('[CachedAgentProxy] 从远程获取到 ${remoteMessages.length} 条消息');

      // 2. 清空本地缓存
      await _messageStore.deleteMessages(_employeeId, deviceId: _deviceId);
      _cachedMessages.clear();

      print('[CachedAgentProxy] 已清空本地缓存');

      // 3. 将远程消息存入缓存
      final shouldSaveAsRead = shouldSaveAsReadCallback?.call() ?? false;
      for (final message in remoteMessages) {
        final forceRead = message.role == 'assistant' && shouldSaveAsRead;
        final entity = _messageToEntity(message, forceRead: forceRead);
        await _messageStore.addMessage(entity, deviceId: _deviceId);
        _cachedMessages.add(message);
      }

      // 4. 排序
      _cachedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      // 5. 通知界面
      _notifyMessagesChanged();

      // 6. 初始化本地水位线
      //    【修复】使用本次实际拉取到的消息中的最大 seq，而非全局 maxSeq，
      //    避免水位线跳跃导致早期消息永远无法被同步到。
      int maxSeqFromPulled = 0;
      for (final msg in remoteMessages) {
        final seq = msg.metadata?['seq'] as int? ?? 0;
        if (seq > maxSeqFromPulled) maxSeqFromPulled = seq;
      }

      if (maxSeqFromPulled > 0) {
        final watermarkStore = SyncWatermarkStore(deviceId: _deviceId);
        watermarkStore.updateLastSeq(_employeeId, maxSeqFromPulled);
        print('[CachedAgentProxy] 水位线已初始化: lastSeq=$maxSeqFromPulled (基于本次拉取消息)');
      } else {
        // 远程消息不含 seq（正常不会发生），降级到获取全局 maxSeq
        try {
          final maxSeq = await _proxy.getMaxSeq();
          if (maxSeq > 0) {
            final watermarkStore = SyncWatermarkStore(deviceId: _deviceId);
            watermarkStore.updateLastSeq(_employeeId, maxSeq);
            print('[CachedAgentProxy] 水位线已初始化: lastSeq=$maxSeq (降级为全局maxSeq)');
          }
        } catch (e) {
          print('[CachedAgentProxy] 获取 maxSeq 失败，水位线未初始化: $e');
        }
      }

      print('[CachedAgentProxy] 消息同步完成，共 ${_cachedMessages.length} 条消息');
    } catch (e) {
      print('[CachedAgentProxy] 同步远程消息失败: $e');
    }
  }

  /// 同步远程会话状态和权限请求
  ///
  /// 在初始化时查询远程 Agent 状态，如果正在等待权限，则查询并缓存权限请求。
  /// 同时同步远程的 Provider 配置和项目 UUID 到本地缓存。
  Future<void> _syncRemoteStateAndPermission() async {
    if (_isDisposed || !_needCache) return;

    try {
      print('[CachedAgentProxy] 开始同步远程会话状态和权限请求...');

      // 1. 查询远程 Agent 状态
      final stateSnapshot = await _proxy.getStateSnapshotAsync();
      print('[CachedAgentProxy] 远程 Agent 状态: ${stateSnapshot.status}');

      // 2. 同步远程 Provider 配置
      try {
        final providerConfig = await _proxy.getProviderConfigAsync();
        if (providerConfig != null) {
          print('[CachedAgentProxy] 远程 Provider 配置: ${providerConfig.provider} · ${providerConfig.model}');
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
        if (skills != null) {
          print('[CachedAgentProxy] 远程技能配置: ${skills.length} 个');
        }
      } catch (e) {
        print('[CachedAgentProxy] 同步远程技能配置失败: $e');
      }

      // 5. 同步远程 MCP 配置
      try {
        final mcpConfigs = await _proxy.getMcpConfigsAsync();
        if (mcpConfigs != null) {
          print('[CachedAgentProxy] 远程 MCP 配置: ${mcpConfigs.length} 个');
        }
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
    if (!_needCache) {
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

  /// 添加消息到缓存
  void _addMessageToCache(AgentMessage message) {
    // 检查是否已存在
    final existingIndex = _cachedMessages.indexWhere((m) => m.id == message.id);
    if (existingIndex != -1) {
      // 已存在，更新
      _cachedMessages[existingIndex] = message;
    } else {
      // 不存在，添加
      _cachedMessages.add(message);
    }

    // 排序
    _cachedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // 通知
    _notifyMessagesChanged();
  }

  /// 更新消息状态
  void _updateMessageStatus(String messageId, String status, {String? error}) {
    final index = _cachedMessages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      final message = _cachedMessages[index];
      final updatedMessage = message.copyWith(
        status: status,
        metadata: {
          ...?message.metadata,
          'updateTime': DateTime.now().toIso8601String(),
          ...?error != null ? {'error': error} : null,
        },
      );
      _cachedMessages[index] = updatedMessage;
      _notifyMessagesChanged();
      _updateMessageInDatabase(updatedMessage);
    }
  }

  /// 保存消息到数据库
  Future<void> _saveMessageToDatabase(AgentMessage message) async {
    try {
      final forceRead = message.role == 'assistant' &&
          (shouldSaveAsReadCallback?.call() ?? false);
      final entity = _messageToEntity(message, forceRead: forceRead);
      await _messageStore.addMessage(entity, deviceId: _deviceId);
    } catch (e) {
      print('保存消息到数据库失败: $e');
    }
  }

  /// 更新数据库中的消息
  Future<void> _updateMessageInDatabase(AgentMessage message) async {
    try {
      final entity = _messageToEntity(message);
      await _messageStore.updateMessage(entity, deviceId: _deviceId);
    } catch (e) {
      print('更新数据库消息失败: $e');
    }
  }

  /// 应用分页
  List<AgentMessage> _applyPagination(
    List<AgentMessage> messages,
    int? limit,
    int? offset,
  ) {
    var result = messages;

    if (offset != null && offset > 0) {
      result = result.skip(offset).toList();
    }

    if (limit != null && limit > 0) {
      result = result.take(limit).toList();
    }

    return result;
  }

  /// 更新缓存状态
  void _updateCacheState(CacheState state) {
    if (!_needCache) return;

    _cacheState = state;
    _cacheStateController.add(state);
  }

  /// 通知消息变更（带 16ms 去抖，合并同一帧内的多次变更）
  void _notifyMessagesChanged() {
    if (_isDisposed) return;
    _notifyDebounceTimer?.cancel();
    _notifyDebounceTimer = Timer(const Duration(milliseconds: 16), () {
      if (_isDisposed) return;
      _messagesController.add(List.unmodifiable(_cachedMessages));
    });
  }

  // ===== 转换方法 =====

  AgentMessage _entityToMessage(AiEmployeeMessageEntity entity) {
    // 从 entity.toMessageMap() 还原完整消息数据
    // toMessageMap() 以 jsonData 为基础还原，确保 toolResults 等扩展字段不丢失
    final messageMap = entity.toMessageMap();

    // 解析 toolCalls（可能是 JSON 字符串或已解析的 List）
    List<ToolCall>? toolCalls;
    final rawToolCalls = messageMap['toolCalls'];
    if (rawToolCalls != null) {
      if (rawToolCalls is String && rawToolCalls.isNotEmpty) {
        toolCalls = (jsonDecode(rawToolCalls) as List)
            .map((tc) => ToolCall.fromMap(tc as Map<String, dynamic>))
            .toList();
      } else if (rawToolCalls is List) {
        toolCalls = rawToolCalls
            .map((tc) => ToolCall.fromMap(tc as Map<String, dynamic>))
            .toList();
      }
    }

    // 解析 toolArguments（可能是 JSON 字符串或已解析的 Map）
    Map<String, dynamic>? toolArguments;
    final rawToolArgs = messageMap['toolArguments'];
    if (rawToolArgs != null) {
      if (rawToolArgs is String && rawToolArgs.isNotEmpty) {
        toolArguments = jsonDecode(rawToolArgs) as Map<String, dynamic>;
      } else if (rawToolArgs is Map) {
        toolArguments = Map<String, dynamic>.from(rawToolArgs);
      }
    }

    // 构建 metadata：保留 toMessageMap() 中的 toolResults 等扩展字段
    final metadata = <String, dynamic>{
      'updateTime': entity.updateTime.toIso8601String(),
    };

    // 从 messageMap 中提取 toolResults 等扩展字段到 metadata
    final mapMetadata = messageMap['metadata'] as Map<String, dynamic>?;
    if (mapMetadata != null) {
      metadata.addAll(mapMetadata);
    }
    // toMessageMap() 中 toolResults 可能是 JSON 字符串（来自 PersistentChatAdapter 的 jsonEncode）
    if (messageMap['toolResults'] != null && !metadata.containsKey('toolResults')) {
      final rawToolResults = messageMap['toolResults'];
      if (rawToolResults is String && rawToolResults.isNotEmpty) {
        try {
          metadata['toolResults'] = jsonDecode(rawToolResults);
        } catch (_) {
          // 解析失败，保留原始值
          metadata['toolResults'] = rawToolResults;
        }
      } else if (rawToolResults is List) {
        metadata['toolResults'] = rawToolResults;
      }
    }

    return AgentMessage(
      id: entity.uuid,
      role: entity.role,
      type: entity.type,
      content: entity.content,
      createdAt: entity.createTime,
      toolCallId: entity.toolCallId,
      toolName: entity.toolName,
      toolArguments: toolArguments,
      toolResult: entity.toolResult,
      toolCalls: toolCalls,
      status: entity.processingStatus,
      metadata: metadata,
    );
  }

  AiEmployeeMessageEntity _messageToEntity(AgentMessage message, {bool? forceRead}) {
    final map = <String, dynamic>{
      'uuid': message.id,
      'employeeId': _employeeId,
      'role': message.role,
      'type': message.type,
      'content': message.content,
      'toolCallId': message.toolCallId,
      'toolName': message.toolName,
      'toolArguments': message.toolArguments,
      'toolResult': message.toolResult,
      'toolCalls': message.toolCalls?.map((tc) => tc.toMap()).toList(),
      'processingStatus': message.status ?? 'none',
      'createTime': message.createdAt.millisecondsSinceEpoch,
      'updateTime': _getMessageUpdateTime(message).millisecondsSinceEpoch,
      'isRead': (forceRead == true) ? 1 : null,
    };
    return AiEmployeeMessageEntity.fromMessageMap(map);
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
        'localOnly': true,  // 标记为本地消息
        'updateTime': DateTime.now().toIso8601String(),
      },
      status: 'pending',
    );

    print('[CachedAgentProxy] 创建本地消息: ID=${localMessage.id}, role=${localMessage.role}');

    // 3. 添加到本地缓存（立即可见）
    if (_needCache) {
      _addMessageToCache(localMessage);
      // 异步保存到数据库
      _saveMessageToDatabase(localMessage);
    }

    // 4. 发送到远程（异步）
    try {
      // 传递生成的messageId，确保远程使用相同的ID
      final inputWithId = input.copyWith(id: messageId);
      print('[CachedAgentProxy] 发送消息到远程: ID=$messageId');

      final returnedId = await _proxy.sendMessage(inputWithId);

      print('[CachedAgentProxy] AgentProxy返回的消息ID: $returnedId');

      // 🔑 验证返回的ID是否一致
      if (returnedId != messageId) {
        print('[CachedAgentProxy] ⚠️ 严重错误：AgentProxy返回了不同的ID！期望: $messageId, 实际: $returnedId');
        // 强制使用客户端生成的ID
      }

      // 发送成功，更新状态
      if (_needCache) {
        _updateMessageStatus(messageId, 'sent');
        print('[CachedAgentProxy] 消息状态更新为sent: ID=$messageId');
      }
    } catch (e) {
      // 发送失败，更新状态
      if (_needCache) {
        _updateMessageStatus(messageId, 'failed');
        print('[CachedAgentProxy] 消息发送失败: ID=$messageId, error: $e');
      }
      rethrow;
    }

    return messageId;
  }

  /// 获取消息
  Future<List<AgentMessage>> getMessages() async {
    if (!_needCache) {
      return await _proxy.getSessionMessages();
    }
    return _cachedMessages;
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
    if (!_needCache) {
      return await _proxy.getSessionMessages();
    }

    await syncWithRemote();
    return _cachedMessages;
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
    if (!_needCache) return;
    await syncWithRemote();
  }

  /// 中断当前处理
  Future<void> interrupt() => _proxy.interrupt();

  /// 撤回消息
  Future<void> revokeMessage(String messageId) async {
    await _proxy.revokeMessage(messageId);

    // 远程模式：从缓存中移除并通知
    if (_needCache) {
      _cachedMessages.removeWhere((m) => m.id == messageId);
      _notifyMessagesChanged();
    }

    // 从数据库中删除消息
    try {
      await _messageStore.hardDeleteMessage(messageId, deviceId: _deviceId);
      print('[CachedAgentProxy] 已从数据库删除消息: $messageId');

      // 本地模式：还需要删除助手回复消息（它们的时间戳紧随用户消息之后）
      if (!_needCache) {
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
                await _messageStore.hardDeleteMessage(msg.id, deviceId: _deviceId);
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
    if (_needCache && _pendingPermissionRequests.isNotEmpty) {
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

    // 第二步：清空本地缓存（远程模式）
    if (_needCache) {
      _cachedMessages.clear();
      _pendingPermissionRequests.clear();
      // 使用正确的 deviceId 删除消息
      await _messageStore.deleteMessages(_employeeId, deviceId: _deviceId);
      // 【修复】重置水位线，避免后续增量同步拉取大量删除事件
      final watermarkStore = SyncWatermarkStore(deviceId: _deviceId);
      watermarkStore.updateLastSeq(_employeeId, 0);
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
  List<Map<String, dynamic>> getRegisteredTools() => _proxy.getRegisteredTools();

  /// 响应权限请求
  Future<void> respondToPermission(String requestId, PermissionDecision decision) async {
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

  // ===== 基础属性 =====

  String get employeeId => _employeeId;
  String get deviceId => _deviceId;
  bool get isLocalMode => _proxy.isLocalMode;
  AgentStatus get status => _proxy.status;
  bool get isAlive => _proxy.isAlive;
  bool get isSending => _proxy.isSending;
  Stream<AgentStateSnapshot> get onStateChanged => _proxy.onStateChanged;

  // ===== 消息已读标记 =====

  /// 标记当前会话的所有消息为已读
  ///
  /// 用户打开会话窗口时调用此方法，会：
  /// 1. 通过 [onMarkAsRead] 回调通知 DeviceClient（本地标记 + 跨设备广播）
  /// 2. 通过 [_proxy] RPC 通知远程 Agent 记录已读状态（Agent 会广播给所有设备）
  void markMessagesAsRead() {
    onMarkAsRead?.call(_employeeId, _deviceId);
    // 通知远程 Agent 记录已读状态（fire-and-forget）
    _proxy.markMessagesAsRead(
      readerDeviceId: _deviceId,
    ).catchError((_) {});
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
    if (!_needCache) {
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
  CacheState get cacheState => _needCache ? _cacheState : CacheState.idle;

  /// 缓存消息数量
  int get cachedMessageCount => _needCache ? _cachedMessages.length : 0;

  /// 最后同步时间
  DateTime? get lastSyncTime => _needCache ? _lastSyncTime : null;

  /// 是否已同步
  bool get isSynced => _needCache && _lastSyncTime != null;

  /// 是否启用缓存
  bool get needCache => _needCache;

  // ===== 清理方法 =====

  /// 清除缓存
  Future<void> clearCache() async {
    if (!_needCache) return;

    _cachedMessages.clear();
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

    // 取消事件订阅
    await _eventSubscription?.cancel();
    await _stateSubscription?.cancel();

    // 清除权限请求缓存
    _pendingPermissionRequests.clear();

    if (_needCache) {
      await _cacheStateController.close();
      await _messagesController.close();
    }
  }
}
