import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'agent_proxy.dart';
import '../entity/entity.dart';
import '../agent_state.dart';
import '../tool/agent_tool.dart';
import '../../shared/chat_message.dart' show ToolCall;
import '../../shared/shared.dart' as shared;
import '../../service/message_store_service.dart';
import '../../service/session_manager.dart';
import '../../persistence/persistence.dart';
import '../../utils/logger.dart';

part 'cached_proxy_event_handler.dart';

part 'cached_proxy_message_sync.dart';

part 'cached_proxy_permission.dart';

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

/// 缓存代理的抽象基类，声明 mixin 需要访问的内部成员
abstract class _CachedAgentProxyBase {
  // ===== 静态成员 =====
  static final _log = Logger('CachedAgentProxy');

  // ===== 实例成员（通过 getter/setter 暴露给 mixin） =====
  AgentProxy get _proxy;

  MessageStoreService get _messageStore;

  String get _deviceId;

  String get _employeeId;

  // ===== 回调 =====

  void Function(String employeeId, Map<String, dynamic> summaryData)?
  get onSessionSummaryUpdated;

  // ===== 缓存状态 =====
  CacheState get _cacheState;

  set _cacheState(CacheState value);

  StreamController<CacheState> get _cacheStateController;

  StreamController<List<AgentMessage>> get _messagesController;

  // ===== 同步控制 =====
  DateTime? get _lastSyncTime;

  set _lastSyncTime(DateTime? value);

  Completer<void>? get _syncCompleter;

  set _syncCompleter(Completer<void>? value);

  Completer<void>? get _initCompleter;

  set _initCompleter(Completer<void>? value);

  Timer? get _syncDebounceTimer;

  set _syncDebounceTimer(Timer? value);

  Timer? get _notifyDebounceTimer;

  set _notifyDebounceTimer(Timer? value);

  int get _syncVersion;

  set _syncVersion(int value);

  // ===== 权限与内存缓存 =====
  Map<String, AgentPermissionRequest> get _pendingPermissionRequests;

  Map<String, AgentConfirmRequest> get _pendingConfirmRequests;

  Map<String, AgentMessage> get _inMemoryToolCallMessages;

  // ===== 事件订阅 =====
  StreamSubscription<AgentEvent>? get _eventSubscription;

  set _eventSubscription(StreamSubscription<AgentEvent>? value);

  StreamSubscription<AgentStateSnapshot>? get _stateSubscription;

  set _stateSubscription(StreamSubscription<AgentStateSnapshot>? value);

  // ===== 生命周期标志 =====
  bool get _isDisposed;

  set _isDisposed(bool value);

  bool get _sessionClearPending;

  set _sessionClearPending(bool value);

  Timer? get _sessionClearGuardTimer;

  set _sessionClearGuardTimer(Timer? value);

  // ===== 状态缓存 =====
  String? get _currentProcessingMessageId;

  set _currentProcessingMessageId(String? value);

  List<String> get _queuedMessageIds;

  set _queuedMessageIds(List<String> value);

  List<String> get _callingToolIdsCache;

  set _callingToolIdsCache(List<String> value);

  // ===== 抽象方法（由 CachedAgentProxy 或其他 mixin 实现） =====
  void _notifyMessagesChanged();

  Future<void> _updateMessageStatus(
    String messageId,
    String status, {
    String? error,
  });

  Future<void> _addMessageToCache(
    AgentMessage message, {
    bool updateWatermark = true,
  });

  void _updateCacheState(CacheState state);

  Future<void> _saveMessageToDatabase(
    AgentMessage message, {
    bool updateWatermark = true,
  });

  DateTime _getMessageUpdateTime(AgentMessage message);

  String _generateMessageId();

  AgentMessage _chatMessageToAgentMessage(shared.ChatMessage cm);

  shared.ChatMessage _agentMessageToChatMessage(
    AgentMessage am, {
    bool forceRead = false,
  });

  Future<void> _saveToolCallMessageToDb(AgentMessage message);

  Future<void> _updateToolCallMessageInDb(AgentMessage message);

  Future<void> _queryPendingPermission();

  Future<void> _queryPendingConfirm();

  void _debouncedSyncMessages({
    Duration delay = const Duration(milliseconds: 500),
  });

  Future<void> _syncMessagesFromRemote();

  Future<void> _syncSessionSummaryFromRemote();

  Future<void> _cleanupSupersededLocalToolCalls(
    List<AgentMessage> syncedMessages,
  );

  void _cleanupStaleToolCallMessages();

  Future<void> _syncRemoteStateAndPermission();
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
class CachedAgentProxy extends _CachedAgentProxyBase
    with
        _CachedProxyEventHandler,
        _CachedProxyMessageSync,
        _CachedProxyPermission {
  @override
  final AgentProxy _proxy;
  @override
  final MessageStoreService _messageStore;
  @override
  final String _deviceId;
  @override
  final String _employeeId;

  /// 底层 AgentProxy 实例（供需要直接访问RPC的调用方使用）
  AgentProxy get proxy => _proxy;

  /// 会话摘要更新回调（由 DeviceAgentManager 注入）
  ///
  /// 当从远程同步到会话摘要时，回调通知 DeviceAgentManager 更新本地持久化和内存缓存。
  @override
  final void Function(String employeeId, Map<String, dynamic> summaryData)?
  onSessionSummaryUpdated;

  /// 缓存状态（仅远程模式使用）
  @override
  CacheState _cacheState = CacheState.idle;
  @override
  final StreamController<CacheState> _cacheStateController =
      StreamController<CacheState>.broadcast();

  /// 消息变更通知流（仅远程模式使用）
  @override
  final StreamController<List<AgentMessage>> _messagesController =
      StreamController<List<AgentMessage>>.broadcast();

  @override
  DateTime? _lastSyncTime;

  /// 同步锁
  @override
  Completer<void>? _syncCompleter;

  /// 初始化锁（防止重复初始化）
  @override
  Completer<void>? _initCompleter;

  /// 同步去抖定时器（避免短时间内重复触发远程消息同步）
  @override
  Timer? _syncDebounceTimer;

  /// 消息变更通知去抖定时器（避免高频事件下短时间内多次通知 UI）
  @override
  Timer? _notifyDebounceTimer;

  /// 同步版本号（用于检测并发同步请求，确保不丢失）
  @override
  int _syncVersion = 0;

  /// 权限请求缓存（远程模式使用）
  @override
  final Map<String, AgentPermissionRequest> _pendingPermissionRequests = {};

  /// 确认请求缓存（远程模式使用）
  @override
  final Map<String, AgentConfirmRequest> _pendingConfirmRequests = {};

  /// 内存中的工具调用消息（本地模式使用，DB不保存临时消息）
  @override
  final Map<String, AgentMessage> _inMemoryToolCallMessages = {};

  // ===== 状态缓存（仅远程模式使用） =====
  @override
  String? _currentProcessingMessageId;
  @override
  List<String> _queuedMessageIds = [];
  @override
  List<String> _callingToolIdsCache = [];

  /// 当前处理中的消息ID
  String? get currentProcessingMessageId => _currentProcessingMessageId;

  /// 排队中的消息ID列表
  List<String> get queuedMessageIds => List.unmodifiable(_queuedMessageIds);

  /// 正在调用的工具 callId 列表
  List<String> get callingToolIds => List.unmodifiable(_callingToolIdsCache);

  /// 事件订阅
  @override
  StreamSubscription<AgentEvent>? _eventSubscription;
  @override
  StreamSubscription<AgentStateSnapshot>? _stateSubscription;

  /// 是否已释放
  @override
  bool _isDisposed = false;

  /// 会话清空标志：sessionCleared 事件处理中设为 true，
  /// 防止 _debouncedSyncMessages 在清空后立即重新同步消息
  @override
  bool _sessionClearPending = false;

  /// 会话清空保护定时器：清空后短时间内跳过消息同步
  @override
  Timer? _sessionClearGuardTimer;

  /// 是否已释放
  bool get isDisposed => _isDisposed;

  CachedAgentProxy({
    required AgentProxy proxy,
    required MessageStoreService messageStore,
    required String deviceId,
    required String employeeId,
    this.onSessionSummaryUpdated,
  }) : _proxy = proxy,
       _messageStore = messageStore,
       _deviceId = deviceId,
       _employeeId = employeeId {
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
  /// 使用版本号机制：并发请求会等待当前同步完成，然后检查是否需要重新同步。
  Future<void> syncFromRemote() async {
    if (_isDisposed || _proxy.isLocalMode) return;

    // 如果已有同步正在进行，递增版本号并等待
    if (_syncCompleter != null) {
      _syncVersion++;
      _CachedAgentProxyBase._log.debug(
        'syncFromRemote: 同步进行中，递增版本号至 $_syncVersion',
      );
      return _syncCompleter!.future;
    }

    _syncCompleter = Completer<void>();
    final myVersion = ++_syncVersion;

    try {
      try {
        // 同步远程消息
        await _syncMessagesFromRemote();
      } catch (e) {
        _CachedAgentProxyBase._log.error('同步远程消息失败: $e');
      }

      // 同步远程状态和权限请求
      try {
        await _syncRemoteStateAndPermission();
        _CachedAgentProxyBase._log.info('同步远程状态成功');
      } catch (e) {
        _CachedAgentProxyBase._log.error('同步远程状态失败', e);
      }

      // 检查是否有更新的同步请求
      if (_syncVersion > myVersion) {
        _CachedAgentProxyBase._log.debug(
          'syncFromRemote: 检测到新请求(v$_syncVersion > v$myVersion)，重新同步',
        );
        _syncCompleter!.complete();
        _syncCompleter = null;
        // 递归重新同步（最多3次，防止无限递归）
        if (myVersion <= 3) {
          return syncFromRemote();
        }
        return;
      }

      _syncCompleter!.complete();
      _syncCompleter = null;
    } catch (e, st) {
      _CachedAgentProxyBase._log.error('unknown error', e);
      _syncCompleter?.completeError(e, st);
      _syncCompleter = null;
    }
  }

  /// 初始化事件监听
  void _initializeEventListeners() {
    _CachedAgentProxyBase._log.debug('初始化事件监听...');

    // 监听Agent事件（本地和远程模式都需要）
    _eventSubscription = _proxy.onEvent.listen((event) {
      _handleAgentEvent(event);
    });

    // 监听状态变更
    _stateSubscription = _proxy.onStateChanged.listen((state) {
      _handleStateChange(state);
    });
  }

  // ===== 内部方法（仅远程模式使用） =====

  /// 生成消息ID（标准UUID格式）
  @override
  String _generateMessageId() {
    return const Uuid().v4();
  }

  /// 获取消息的更新时间
  @override
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
  @override
  Future<void> _addMessageToCache(
    AgentMessage message, {
    bool updateWatermark = true,
  }) async {
    await _saveMessageToDatabase(message, updateWatermark: updateWatermark);
    _notifyMessagesChanged();
  }

  /// 更新消息状态
  @override
  Future<void> _updateMessageStatus(
    String messageId,
    String status, {
    String? error,
  }) async {
    await _messageStore.updateMessageStatus(
      _deviceId,
      messageId,
      shared.MessageStatus.fromString(status),
      error: error,
    );
    _notifyMessagesChanged();
  }

  /// 保存消息到数据库
  ///
  /// 本地临时消息（localOnly）不更新同步水位线，
  /// 避免本地分配的 seq 污染 LSN 增量同步。
  @override
  Future<void> _saveMessageToDatabase(
    AgentMessage message, {
    bool updateWatermark = true,
  }) async {
    try {
      // 消息始终以未读写入，由打开聊天窗口时 markMessagesAsRead 统一标记已读
      final chatMsg = _agentMessageToChatMessage(message, forceRead: false);
      await _messageStore.addMessage(
        _deviceId,
        chatMsg,
        updateWatermark: updateWatermark,
      );
    } catch (e) {
      _CachedAgentProxyBase._log.error('保存消息到数据库失败', e);
    }
  }

  /// 更新缓存状态
  @override
  void _updateCacheState(CacheState state) {
    if (_proxy.isLocalMode) return;

    _cacheState = state;
    _cacheStateController.add(state);
  }

  /// 通知消息变更（带 16ms 去抖，合并同一帧内的多次变更）
  @override
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
  @override
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
      toolCalls: cm.toolCalls
          ?.map(
            (tc) => ToolCall(id: tc.id, name: tc.name, arguments: tc.arguments),
          )
          .toList(),
      status: cm.status != shared.MessageStatus.none ? cm.status.name : null,
      metadata: metadata.isNotEmpty ? metadata : null,
    );
  }

  /// AgentMessage → ChatMessage 桥接（缓存 AgentMessage 保存到 MessageStore）
  @override
  shared.ChatMessage _agentMessageToChatMessage(
    AgentMessage am, {
    bool forceRead = false,
  }) {
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
          ?.map(
            (tc) => shared.ToolCall(
              id: tc.id,
              name: tc.name,
              arguments: tc.arguments,
            ),
          )
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
    _CachedAgentProxyBase._log.debug('客户端生成消息ID: $messageId');

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

    _CachedAgentProxyBase._log.debug(
      '创建本地消息: ID=${localMessage.id}, role=${localMessage.role}',
    );

    // 3. 添加到本地缓存（立即可见，不更新同步水位线）
    await _addMessageToCache(localMessage, updateWatermark: false);

    // 4. 发送到远程（异步）
    try {
      // 传递生成的messageId，确保远程使用相同的ID
      final inputWithId = input.copyWith(id: messageId);
      _CachedAgentProxyBase._log.debug('发送消息到远程: ID=$messageId');

      final returnedId = await _proxy.sendMessage(inputWithId);

      _CachedAgentProxyBase._log.debug('AgentProxy返回的消息ID: $returnedId');

      // 验证返回的ID是否一致
      if (returnedId != messageId) {
        _CachedAgentProxyBase._log.warn(
          '严重错误：AgentProxy返回了不同的ID！期望: $messageId, 实际: $returnedId',
        );
        // 强制使用客户端生成的ID
      }

      // 发送成功，更新状态
      if (!_proxy.isLocalMode) {
        _updateMessageStatus(messageId, 'sent');
        _CachedAgentProxyBase._log.debug('消息状态更新为sent: ID=$messageId');
      }
    } catch (e) {
      // 发送失败，更新状态
      if (!_proxy.isLocalMode) {
        _updateMessageStatus(messageId, 'failed');
        _CachedAgentProxyBase._log.error('消息发送失败: ID=$messageId', e);
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

    // 按时间正序排列
    allMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return allMessages;
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

  /// 主动同步远程消息（供外部调用）
  ///
  /// 与 [syncFromRemote] 不同，此方法更轻量，仅同步消息不同步状态。
  /// 使用版本号机制：并发请求会等待当前同步完成，然后检查是否需要重新同步。
  Future<void> syncWithRemote() async {
    if (_proxy.isLocalMode) {
      return;
    }

    // 如果已有同步正在进行，递增版本号并等待
    if (_syncCompleter != null) {
      _syncVersion++;
      _CachedAgentProxyBase._log.debug(
        'syncWithRemote: 同步进行中，递增版本号至 $_syncVersion',
      );
      return _syncCompleter!.future;
    }

    _syncCompleter = Completer<void>();
    _updateCacheState(CacheState.syncing);
    final myVersion = ++_syncVersion;

    try {
      // 调用统一的同步逻辑
      await _syncMessagesFromRemote();

      _lastSyncTime = DateTime.now();
      _updateCacheState(CacheState.idle);

      // 检查是否有更新的同步请求
      if (_syncVersion > myVersion) {
        _CachedAgentProxyBase._log.debug(
          'syncWithRemote: 检测到新请求(v$_syncVersion > v$myVersion)，重新同步',
        );
        _syncCompleter!.complete();
        _syncCompleter = null;
        // 递归重新同步（最多3次，防止无限递归）
        if (myVersion <= 3) {
          return syncWithRemote();
        }
        return;
      }

      _syncCompleter!.complete();
    } catch (e) {
      _updateCacheState(CacheState.error);
      _syncCompleter!.completeError(e);
    } finally {
      _syncCompleter = null;
    }
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
      await _messageStore.hardDeleteMessage(_deviceId, messageId);
      _CachedAgentProxyBase._log.info('已从数据库删除消息: $messageId');

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
                await _messageStore.hardDeleteMessage(_deviceId, msg.id);
                _CachedAgentProxyBase._log.info('已从数据库删除助手消息: ${msg.id}');

                // 从 Agent 内存中删除助手消息
                await _proxy.removeMessageFromMemory(msg.id);
              } catch (e) {
                _CachedAgentProxyBase._log.error('删除助手消息失败', e);
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
      _CachedAgentProxyBase._log.error('从数据库删除消息失败', e);
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

  /// 获取当前确认请求
  AgentConfirmRequest? getPendingConfirmRequest() {
    // 远程模式：从缓存中获取
    if (!_proxy.isLocalMode && _pendingConfirmRequests.isNotEmpty) {
      return _pendingConfirmRequests.values.first;
    }
    // 本地模式：透传
    return _proxy.getPendingConfirmRequest();
  }

  /// 获取当前确认请求（异步版本）
  Future<AgentConfirmRequest?> getPendingConfirmRequestAsync() =>
      _proxy.getPendingConfirmRequestAsync();

  /// 响应确认请求
  Future<void> respondToConfirm(String requestId, String selectedOption) async {
    await _proxy.respondToConfirm(requestId, selectedOption);
    // 清除缓存的确认请求
    _pendingConfirmRequests.remove(requestId);
    _CachedAgentProxyBase._log.info('已响应确认请求并清除缓存: $requestId');
  }

  /// 清空当前会话
  ///
  /// 清空后重置本地水位线为 0，避免后续同步拉取大量无意义的删除事件。
  Future<void> clearCurrentSession() async {
    // 第一步：清空远程会话
    await _proxy.clearCurrentSession();

    // 第二步：清空本地数据库（远程模式）
    if (!_proxy.isLocalMode) {
      _pendingPermissionRequests.clear();
      _pendingConfirmRequests.clear();
      // 使用正确的 deviceId 删除消息
      await _messageStore.deleteMessages(_deviceId, _employeeId);
      // 重置水位线，避免后续增量同步拉取大量删除事件
      // 注意：updateLastSeq 使用 MAX 语义无法降为 0，必须用 resetLastSeq
      _messageStore.resetLastSeq(_deviceId, _employeeId, 0);
      _CachedAgentProxyBase._log.info('会话已清空，水位线已重置为 0');
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
  List<Map<String, dynamic>> getSkillsConfig() => _proxy.getSkillsConfig();

  /// 获取技能配置（异步版本，支持远程 RPC）
  Future<List<Map<String, dynamic>>> getSkillsConfigAsync() =>
      _proxy.getSkillsConfigAsync();

  // ===== MCP 管理 =====

  /// 设置 MCP 服务器配置
  Future<void> setMcpConfigs(List<Map<String, dynamic>> mcpConfigMaps) =>
      _proxy.setMcpConfigs(mcpConfigMaps);

  /// 获取 MCP 服务器配置
  List<Map<String, dynamic>> getMcpConfigs() => _proxy.getMcpConfigs();

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
  Future<FileInfoResult> getFileInfo(String path) => _proxy.getFileInfo(path);

  /// 创建目录
  Future<FileOpResult> createDirectory(String path) =>
      _proxy.createDirectory(path);

  /// 删除文件/目录
  Future<FileOpResult> deleteFile(String path) => _proxy.deleteFile(path);

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
  Future<void> respondToPermission(
    String requestId,
    PermissionDecision decision, {
    PermissionApprovalScope scope = PermissionApprovalScope.once,
    String? customPattern,
  }) async {
    await _proxy.respondToPermission(
      requestId,
      decision,
      scope: scope,
      customPattern: customPattern,
    );

    // 清除缓存的权限请求
    _pendingPermissionRequests.remove(requestId);
    _CachedAgentProxyBase._log.info('已响应权限请求并清除缓存: $requestId');
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

  /// 更新远程状态缓存（由 DeviceMessageHandler 调用）
  ///
  /// 当收到远程 LAN 广播的 agentStatusChanged / toolCall 事件时，
  /// 更新本地内存缓存，确保 UI 能实时显示远程 Agent 的处理状态。
  void updateRemoteStateCache({
    String? currentProcessingMessageId,
    List<String>? queuedMessageIds,
    List<String>? callingToolIds,
    bool clearProcessing = false,
    bool clearQueued = false,
    bool clearCallingToolIds = false,
  }) {
    if (currentProcessingMessageId != null) {
      _currentProcessingMessageId = currentProcessingMessageId;
    } else if (clearProcessing) {
      _currentProcessingMessageId = null;
    }
    if (queuedMessageIds != null) {
      _queuedMessageIds = queuedMessageIds;
    } else if (clearQueued) {
      _queuedMessageIds = [];
    }
    if (callingToolIds != null) {
      _callingToolIdsCache = callingToolIds;
    } else if (clearCallingToolIds) {
      _callingToolIdsCache = [];
    }
  }

  /// 添加远程工具调用 ID（由 DeviceMessageHandler 调用）
  void addRemoteCallingToolId(String toolCallId) {
    if (!_callingToolIdsCache.contains(toolCallId)) {
      _callingToolIdsCache = [..._callingToolIdsCache, toolCallId];
    }
  }

  /// 移除远程工具调用 ID（由 DeviceMessageHandler 调用）
  void removeRemoteCallingToolId(String toolCallId) {
    _callingToolIdsCache = _callingToolIdsCache
        .where((id) => id != toolCallId)
        .toList();
  }

  // ===== Todo 管理 =====

  /// 获取当前待办主题
  Future<List<Map<String, dynamic>>> getCurrentTopics() =>
      _proxy.getCurrentTopics();

  /// 获取未完成待办主题
  Future<List<Map<String, dynamic>>> getPendingTopics() =>
      _proxy.getPendingTopics();

  /// 获取所有待办主题
  Future<List<Map<String, dynamic>>> getAllTopics() => _proxy.getAllTopics();

  /// 获取已完成主题
  Future<List<Map<String, dynamic>>> getCompletedTopics({int limit = 50}) =>
      _proxy.getCompletedTopics(limit: limit);

  /// 获取待办统计信息
  Future<Map<String, dynamic>> getTodoStats() => _proxy.getTodoStats();

  // ===== Todo 写操作 =====

  /// 更新主题内容
  Future<void> updateTopicContent(
    String topicId, {
    String? title,
    String? description,
  }) => _proxy.updateTopicContent(
    topicId,
    title: title,
    description: description,
  );

  /// 删除主题
  Future<void> deleteTopic(String topicId) => _proxy.deleteTopic(topicId);

  /// 更新主题状态
  Future<void> updateTopicStatus(String topicId, String status) =>
      _proxy.updateTopicStatus(topicId, status);

  /// 批量更新主题排序
  Future<void> reorderTopics(List<String> topicIds) =>
      _proxy.reorderTopics(topicIds);

  /// 清除已完成主题
  Future<void> clearCompletedTopics() => _proxy.clearCompletedTopics();

  /// 获取主题下的任务子项
  Future<List<Map<String, dynamic>>> getTaskItemsByTopic(String topicId) =>
      _proxy.getTaskItemsByTopic(topicId);

  /// 更新任务子项状态
  Future<void> updateTaskItemStatus(String taskId, String status) =>
      _proxy.updateTaskItemStatus(taskId, status);

  /// 更新任务子项内容
  Future<void> updateTaskItemContent(
    String taskId, {
    String? title,
    String? content,
  }) => _proxy.updateTaskItemContent(taskId, title: title, content: content);

  /// 删除任务子项
  Future<void> deleteTaskItem(String taskId) => _proxy.deleteTaskItem(taskId);

  /// 批量更新任务子项排序
  Future<void> reorderTaskItems(List<String> taskItemIds) =>
      _proxy.reorderTaskItems(taskItemIds);

  // ===== Spec 管理 =====

  /// 获取活跃 spec 项
  Future<List<Map<String, dynamic>>> getActiveSpecs() =>
      _proxy.getActiveSpecs();

  /// 获取已完成 spec 项
  Future<List<Map<String, dynamic>>> getCompletedSpecs({int limit = 50}) =>
      _proxy.getCompletedSpecs(limit: limit);

  /// 获取 spec 统计信息
  Future<Map<String, dynamic>> getSpecStats() => _proxy.getSpecStats();

  // ===== Spec 写操作 =====

  /// 更新 spec 状态
  Future<void> updateSpecStatus(String specId, String status) =>
      _proxy.updateSpecStatus(specId, status);

  /// 更新 spec 内容
  Future<void> updateSpecContent(String specId, String content) =>
      _proxy.updateSpecContent(specId, content);

  /// 删除 spec 项
  Future<void> deleteSpec(String specId) => _proxy.deleteSpec(specId);

  /// 清除所有已完成 spec
  Future<void> clearCompletedSpecs() => _proxy.clearCompletedSpecs();

  /// 批量更新 spec 排序
  Future<void> reorderSpecs(List<String> specIds) =>
      _proxy.reorderSpecs(specIds);

  // ===== 文件操作追踪 =====

  /// 获取文件操作记录
  Future<List<Map<String, dynamic>>> getFileOperations({
    int limit = 100,
    int offset = 0,
  }) => _proxy.getFileOperations(limit: limit, offset: offset);

  /// 获取指定消息关联的文件操作记录
  Future<List<Map<String, dynamic>>> getFileOperationsByMessage(
    String messageId,
  ) => _proxy.getFileOperationsByMessage(messageId);

  /// 清除文件操作记录
  Future<void> clearFileOperations() => _proxy.clearFileOperations();

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
    return _messageStore.getUnreadCount(_deviceId, _employeeId);
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
      _deviceId,
      _employeeId,
    );
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
    await _messageStore.deleteMessages(_deviceId, _employeeId);
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

    // 清除确认请求缓存
    _pendingConfirmRequests.clear();

    // 清除内存中的工具调用消息
    _inMemoryToolCallMessages.clear();

    // 清除状态缓存
    _callingToolIdsCache.clear();
    _queuedMessageIds.clear();
    _currentProcessingMessageId = null;

    if (!_proxy.isLocalMode) {
      await _cacheStateController.close();
      await _messagesController.close();
    }
  }
}
