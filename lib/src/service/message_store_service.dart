import 'dart:async';

import 'package:uuid/uuid.dart';

import '../persistence/persistence.dart';

/// 消息变更类型
enum MessageChangeType { added, updated, deleted }

/// 消息变更事件
class MessageChangeEvent {
  final MessageChangeType type;
  final String messageUuid;
  final String employeeId;
  final ChatMessage? message;

  MessageChangeEvent({
    required this.type,
    required this.messageUuid,
    required this.employeeId,
    this.message,
  });
}

/// 消息存储服务接口
abstract class MessageStoreService {
  static final Map<String, MessageStoreService> _instances = {};

  /// 按 deviceId 获取单例，不存在则自动创建
  static MessageStoreService getInstance(String deviceId) {
    return _instances.putIfAbsent(
      deviceId,
      () => MessageStoreServiceImpl(deviceId: deviceId),
    );
  }

  /// 移除指定 deviceId 的实例
  static void removeInstance(String deviceId) => _instances.remove(deviceId);

  /// 获取会话消息列表（使用默认 deviceId）
  Future<List<ChatMessage>> getMessages(
    String deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  });

  /// 获取会话消息列表（指定 deviceId）
  Future<List<ChatMessage>> getMessagesWithDeviceId(
    String deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  });

  /// 获取单条消息
  Future<ChatMessage?> getMessage(String deviceId, String uuid);

  /// 添加消息
  ///
  /// [updateWatermark] 是否更新同步水位线，默认 true。
  /// 本地临时消息应传 false，避免本地分配的 seq 污染同步水位线。
  Future<ChatMessage> addMessage(
    String deviceId,
    ChatMessage message, {
    bool updateWatermark = true,
  });

  /// 批量添加消息
  Future<void> addMessages(String deviceId, List<ChatMessage> messages);

  /// 更新消息
  Future<void> updateMessage(
    String deviceId,
    ChatMessage message, {
    bool updateWatermark = true,
  });

  /// 更新消息状态
  Future<void> updateMessageStatus(
    String deviceId,
    String uuid,
    MessageStatus status, {
    String? error,
  });

  /// 批量更新消息（减少逐条 await 的开销）
  ///
  /// 适用于 markAllAsRead 等场景，内部逐条更新但不逐条广播变更事件，
  /// 只在最后发送一次聚合通知。
  Future<void> batchUpdateMessages(String deviceId, List<ChatMessage> messages);

  /// 删除会话的所有消息
  ///
  /// [deviceId] 设备ID，为null时使用实例默认deviceId
  /// [employeeId] 员工ID
  Future<void> deleteMessages(String deviceId, String employeeId);

  /// 软删除单条消息（更新 seq，使删除事件可通过 LSN 增量拉取同步）
  ///
  /// [uuid] 消息UUID
  Future<void> softDeleteMessage(String deviceId, String uuid);

  /// 软删除会话所有消息（更新 seq，使删除事件可通过 LSN 增量拉取同步）
  ///
  /// [employeeId] 员工ID
  Future<void> softDeleteBySession(String deviceId, String employeeId);

  /// 删除指定会话中 seq < beforeSeq 的所有消息（硬删除）
  ///
  /// 用于清空水位线场景：服务端设置 clear_seq 后，
  /// 客户端同步时删除本地所有 seq < clearSeq 的消息。
  /// 返回被删除的消息数量。
  int deleteMessagesBeforeSeq(
    String deviceId,
    String employeeId,
    int beforeSeq,
  );

  /// 获取指定会话的最大 seq（含已软删除的消息）
  ///
  /// 用于清空会话时设置清空水位线。
  int getMaxSeq(String deviceId, String employeeId);

  /// 硬删除单条消息（从数据库直接删除，非软删除）
  ///
  /// [uuid] 消息UUID
  /// [deviceId] 设备ID，为null时使用实例默认deviceId
  Future<void> hardDeleteMessage(String deviceId, String uuid);

  /// 获取最后一条消息
  Future<ChatMessage?> getLastMessage(String deviceId, String employeeId);

  /// 统计指定员工的未读消息数量（从 session_summary 表读取，O(1)）
  int getUnreadCount(String deviceId, String employeeId);

  /// 全局未读总数（从 session_summary 表 SUM 聚合，O(S)）
  int getTotalUnreadCount({String deviceId});

  /// 获取最新消息摘要（从 session_summary 表读取，O(1)）
  SessionSummaryEntity? getLatestMessageSummary(String deviceId, String employeeId);

  /// 批量获取所有会话摘要（从 session_summary 表读取）
  List<SessionSummaryEntity> getAllSummaries({String deviceId = ''});

  /// 批量标记指定员工的消息为已读（SQL 直接更新，返回受影响行数）
  ///
  /// 同时将 session_summary.unread_count 置为 0。
  int markAsReadInDb(String deviceId, String employeeId);

  /// 基于 seq 批量标记已读
  int markAsReadBySeqInDb(String deviceId, String employeeId, int readSeq);

  /// 获取指定员工的未读消息 ID 列表
  List<String> getUnreadMessageIds(String deviceId, String employeeId);

  /// 获取指定员工中仍处于 processing 状态的本地工具调用消息 ID 列表
  List<String> getStaleLocalToolCallMessages(
    String deviceId,
    String employeeId,
  );

  /// 消息变更通知流
  Stream<MessageChangeEvent> get onMessageChanged;

  /// 获取同步水位线（lastSeq）
  int getLastSeq(String deviceId, String employeeId);

  /// 更新同步水位线（MAX 语义，防止回退）
  void updateLastSeq(String deviceId, String employeeId, int lastSeq);

  /// 强制重置同步水位线（不受 MAX 语义限制，用于清空会话场景）
  void resetLastSeq(String deviceId, String employeeId, int lastSeq);

  /// 从远程数据合并本地摘要（智能合并：仅当远程数据更新时覆盖，未读数取最大值）
  void upsertSummaryFromRemote(SessionSummaryEntity remote);
}

/// 消息存储服务实现
class MessageStoreServiceImpl implements MessageStoreService {
  final MessageStore _store;
  final SessionSummaryStore _summaryStore;
  final _changeController = StreamController<MessageChangeEvent>.broadcast();

  MessageStoreServiceImpl({MessageStore? store, String? deviceId})
      : _store = store ?? MessageStore(deviceId: deviceId),
        _summaryStore = SessionSummaryStore(deviceId: deviceId);

  @override
  Future<List<ChatMessage>> getMessages(
    String deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  }) async {
    return _store.getMessages(
      deviceId,
      employeeId,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<List<ChatMessage>> getMessagesWithDeviceId(
    String deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  }) async {
    return _store.getMessages(
      deviceId,
      employeeId,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<ChatMessage?> getMessage(String deviceId, String uuid) async {
    return _store.find(deviceId, uuid);
  }

  @override
  Future<ChatMessage> addMessage(
    String deviceId,
    ChatMessage message, {
    bool updateWatermark = true,
  }) async {
    await _store.addWithDeviceId(
      deviceId,
      message,
      updateWatermark: updateWatermark,
    );

    // 同步更新摘要（O(1)）
    _summaryStore.onMessageAdded(
      employeeId: message.employeeId,
      deviceId: deviceId,
      role: message.role.name,
      isRead: message.isRead,
      messageId: message.id,
      createTime: message.createdAt.millisecondsSinceEpoch,
      seq: message.seq,
      content: message.content,
    );

    _notifyChange(MessageChangeType.added, message);
    return message;
  }

  @override
  Future<void> addMessages(String deviceId, List<ChatMessage> messages) async {
    // 批量更新摘要（减少 DB 调用）
    final summaryMessages = messages.map((m) {
      return <String, dynamic>{
        'employeeId': m.employeeId,
        'deviceId': deviceId,
        'role': m.role.name,
        'isRead': m.isRead,
        'messageId': m.id,
        'createTime': m.createdAt.millisecondsSinceEpoch,
        'seq': m.seq,
        'content': m.content,
      };
    }).toList();
    _summaryStore.onMessagesAdded(summaryMessages);

    for (final message in messages) {
      await _store.addWithDeviceId(deviceId, message);
      _notifyChange(MessageChangeType.added, message);
    }
  }

  @override
  Future<void> updateMessage(
    String deviceId,
    ChatMessage message, {
    bool updateWatermark = true,
  }) async {
    final updated = message.copyWith(updatedAt: DateTime.now());
    await _store.updateWithDeviceId(
      deviceId,
      updated,
      updateWatermark: updateWatermark,
    );
    _notifyChange(MessageChangeType.updated, updated);
  }

  @override
  Future<void> updateMessageStatus(
    String deviceId,
    String uuid,
    MessageStatus status, {
    String? error,
  }) async {
    await _store.updateStatus(deviceId, uuid, status, error: error);
    final message = await _store.find(deviceId, uuid);
    if (message != null) {
      _notifyChange(MessageChangeType.updated, message);
    }
  }

  /// 更新消息状态（指定 deviceId，兼容旧调用）
  Future<void> updateMessageStatusWithDeviceId(
    String? deviceId,
    String uuid,
    MessageStatus status, {
    String? error,
  }) async {
    await _store.updateStatus(deviceId, uuid, status, error: error);
    final message = await _store.find(deviceId, uuid);
    if (message != null) {
      _notifyChange(MessageChangeType.updated, message);
    }
  }

  @override
  Future<void> batchUpdateMessages(String deviceId, List<ChatMessage> messages) async {
    final now = DateTime.now();
    final updated = messages.map((m) => m.copyWith(updatedAt: now)).toList();
    await _store.batchUpdateWithDeviceId(deviceId, updated);
    // 只广播一次聚合事件，而非逐条广播
    if (updated.isNotEmpty) {
      _notifyChange(MessageChangeType.updated, updated.last);
    }
  }

  @override
  Future<void> deleteMessages(String deviceId, String employeeId) async {
    await _store.deleteBySession(deviceId, employeeId);
    // 同步删除摘要
    _summaryStore.deleteSummary(employeeId, deviceId: deviceId);
  }

  @override
  Future<void> softDeleteMessage(String deviceId, String uuid) async {
    // 先查询消息信息，用于更新摘要
    final message = await _store.find(deviceId, uuid);

    _store.softDeleteForSync(uuid, deviceId: deviceId);

    // 更新摘要
    if (message != null) {
      final summary = _summaryStore.getSummary(message.employeeId, deviceId: deviceId);
      final wasLatest = summary?.lastMsgId == uuid;
      final wasUnread = !message.isRead && message.role == MessageRole.assistant;

      // 如果被删除的是最新消息，查询前一条消息
      String? prevMsgId, prevMsgRole, prevMsgContent;
      int? prevMsgTime, prevMsgSeq;
      if (wasLatest) {
        final prevMsg = await _store.getLastMessage(deviceId, message.employeeId);
        if (prevMsg != null) {
          prevMsgId = prevMsg.id;
          prevMsgRole = prevMsg.role.name;
          prevMsgContent = prevMsg.content;
          prevMsgTime = prevMsg.createdAt.millisecondsSinceEpoch;
          prevMsgSeq = prevMsg.seq;
        }
      }

      _summaryStore.onMessageSoftDeleted(
        employeeId: message.employeeId,
        deviceId: deviceId,
        wasUnread: wasUnread,
        wasLatest: wasLatest,
        previousMsgId: prevMsgId,
        previousMsgRole: prevMsgRole,
        previousMsgContent: prevMsgContent,
        previousMsgTime: prevMsgTime,
        previousMsgSeq: prevMsgSeq,
      );
    }

    if (message != null) {
      _notifyChange(MessageChangeType.deleted, message);
    }
  }

  @override
  Future<void> softDeleteBySession(String deviceId, String employeeId) async {
    await _store.softDeleteBySessionForSync(
      employeeId,
      deviceId: deviceId,
    );
    // 会话全部软删除，清零未读计数，重建摘要
    _summaryStore.markAsRead(employeeId, deviceId: deviceId);
    _summaryStore.rebuildSummary(employeeId, deviceId: deviceId);
  }

  @override
  int deleteMessagesBeforeSeq(String deviceId, String employeeId, int beforeSeq) {
    final deleted = _store.deleteBeforeSeq(
      employeeId,
      beforeSeq,
      deviceId: deviceId,
    );
    // 有消息被删除，重建摘要以保持一致
    if (deleted > 0) {
      _summaryStore.rebuildSummary(employeeId, deviceId: deviceId);
    }
    return deleted;
  }

  @override
  int getMaxSeq(String deviceId, String employeeId) {
    return _store.getMaxSeqForEmployeeAll(
      employeeId,
      deviceId: deviceId,
    );
  }

  @override
  Future<void> hardDeleteMessage(String deviceId, String uuid) async {
    await _store.delete(deviceId, uuid);
  }

  @override
  Future<ChatMessage?> getLastMessage(String deviceId, String employeeId) async {
    return _store.getLastMessage(deviceId, employeeId);
  }

  @override
  int getUnreadCount(String deviceId, String employeeId) {
    // 委托给摘要表（O(1) PK 查找）
    return _summaryStore.getUnreadCount(employeeId, deviceId: deviceId);
  }

  @override
  int getTotalUnreadCount({String deviceId = ''}) {
    return _summaryStore.getTotalUnreadCount(deviceId: deviceId);
  }

  @override
  SessionSummaryEntity? getLatestMessageSummary(String deviceId, String employeeId) {
    return _summaryStore.getSummary(employeeId, deviceId: deviceId);
  }

  @override
  List<SessionSummaryEntity> getAllSummaries({String deviceId = ''}) {
    return _summaryStore.getAllSummaries(deviceId: deviceId);
  }

  @override
  int markAsReadInDb(String deviceId, String employeeId) {
    final affected = _store.markAsReadByEmployee(employeeId, deviceId: deviceId);
    // 同步将摘要表未读计数置为 0（O(1)）
    _summaryStore.markAsRead(employeeId, deviceId: deviceId);
    return affected;
  }

  @override
  int markAsReadBySeqInDb(String deviceId, String employeeId, int readSeq) {
    final affected = _store.markAsReadBySeq(employeeId, readSeq, deviceId: deviceId);
    _summaryStore.markAsReadBySeq(employeeId, readSeq, deviceId: deviceId);
    return affected;
  }

  @override
  List<String> getUnreadMessageIds(String deviceId, String employeeId) {
    return _store.getUnreadMessageIds(employeeId, deviceId: deviceId);
  }

  @override
  List<String> getStaleLocalToolCallMessages(String deviceId, String employeeId) {
    return _store.getStaleLocalToolCallMessages(
      employeeId,
      deviceId: deviceId,
    );
  }

  @override
  Stream<MessageChangeEvent> get onMessageChanged => _changeController.stream;

  @override
  int getLastSeq(String deviceId, String employeeId) {
    final store = SyncWatermarkStore(dbManager: _store.dbManager);
    return store.getLastSeq(employeeId, deviceId: deviceId);
  }

  @override
  void updateLastSeq(String deviceId, String employeeId, int lastSeq) {
    final store = SyncWatermarkStore(dbManager: _store.dbManager);
    store.updateLastSeq(employeeId, lastSeq, deviceId: deviceId);
  }

  @override
  void resetLastSeq(String deviceId, String employeeId, int lastSeq) {
    final store = SyncWatermarkStore(dbManager: _store.dbManager);
    store.resetLastSeq(employeeId, lastSeq, deviceId: deviceId);
  }

  void _notifyChange(MessageChangeType type, ChatMessage message) {
    _changeController.add(
      MessageChangeEvent(
        type: type,
        messageUuid: message.id,
        employeeId: message.employeeId,
        message: message,
      ),
    );
  }

  /// 创建新消息
  ChatMessage createMessage({
    required String employeeId,
    required MessageRole role,
    String type = 'text',
    String? content,
    String? toolCallId,
    String? toolName,
    Map<String, dynamic>? toolArguments,
    String? toolResult,
    List<ToolCall>? toolCalls,
    String? deviceId,
  }) {
    final uuid = const Uuid().v4();
    final now = DateTime.now();
    return ChatMessage(
      id: uuid,
      employeeId: employeeId,
      role: role,
      type: type,
      content: content,
      createdAt: now,
      updatedAt: now,
      toolCallId: toolCallId,
      toolName: toolName,
      toolArguments: toolArguments,
      toolResult: toolResult,
      toolCalls: toolCalls,
      deviceId: deviceId,
    );
  }

  /// 从 JSON Map 创建消息
  ChatMessage fromJson(Map<String, dynamic> json) {
    return ChatMessage.fromJson(json);
  }

  /// 从远程数据合并本地摘要（智能合并：仅当远程数据更新时覆盖，未读数取最大值）
  @override
  void upsertSummaryFromRemote(SessionSummaryEntity remote) {
    _summaryStore.upsertFromRemote(remote);
  }

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}
