import 'dart:async';

import 'package:uuid/uuid.dart';

import '../persistence/persistence.dart';

/// 消息变更类型
enum MessageChangeType {
  added,
  updated,
  deleted,
}

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
    String employeeId, {
    int? limit,
    int? offset,
  });

  /// 获取会话消息列表（指定 deviceId）
  Future<List<ChatMessage>> getMessagesWithDeviceId(
    String? deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  });

  /// 获取单条消息
  Future<ChatMessage?> getMessage(String uuid, {String? deviceId});

  /// 添加消息
  ///
  /// [updateWatermark] 是否更新同步水位线，默认 true。
  /// 本地临时消息应传 false，避免本地分配的 seq 污染同步水位线。
  Future<ChatMessage> addMessage(
    ChatMessage message, {
    String? deviceId,
    bool updateWatermark = true,
  });

  /// 批量添加消息
  Future<void> addMessages(
    List<ChatMessage> messages, {
    String? deviceId,
  });

  /// 更新消息
  Future<void> updateMessage(
    ChatMessage message, {
    String? deviceId,
    bool updateWatermark = true,
  });

  /// 更新消息状态
  Future<void> updateMessageStatus(
    String uuid,
    MessageStatus status, {
    String? error,
  });

  /// 批量更新消息（减少逐条 await 的开销）
  ///
  /// 适用于 markAllAsRead 等场景，内部逐条更新但不逐条广播变更事件，
  /// 只在最后发送一次聚合通知。
  Future<void> batchUpdateMessages(
    List<ChatMessage> messages, {
    String? deviceId,
  });

  /// 删除会话的所有消息
  ///
  /// [deviceId] 设备ID，为null时使用实例默认deviceId
  /// [employeeId] 员工ID
  Future<void> deleteMessages(String employeeId, {String? deviceId});

  /// 软删除单条消息（更新 seq，使删除事件可通过 LSN 增量拉取同步）
  ///
  /// [uuid] 消息UUID
  Future<void> softDeleteMessage(String uuid);

  /// 软删除会话所有消息（更新 seq，使删除事件可通过 LSN 增量拉取同步）
  ///
  /// [employeeId] 员工ID
  Future<void> softDeleteBySession(String employeeId);

  /// 删除指定会话中 seq < beforeSeq 的所有消息（硬删除）
  ///
  /// 用于清空水位线场景：服务端设置 clear_seq 后，
  /// 客户端同步时删除本地所有 seq < clearSeq 的消息。
  /// 返回被删除的消息数量。
  int deleteMessagesBeforeSeq(String employeeId, int beforeSeq);

  /// 获取指定会话的最大 seq（含已软删除的消息）
  ///
  /// 用于清空会话时设置清空水位线。
  int getMaxSeq(String employeeId);

  /// 硬删除单条消息（从数据库直接删除，非软删除）
  ///
  /// [uuid] 消息UUID
  /// [deviceId] 设备ID，为null时使用实例默认deviceId
  Future<void> hardDeleteMessage(String uuid, {String? deviceId});

  /// 获取最后一条消息
  Future<ChatMessage?> getLastMessage(String employeeId);

  /// 统计指定员工的未读消息数量（assistant 且 is_read=0 且 deleted=0）
  ///
  /// [deviceId] 可选，传入时仅统计指定设备的消息，不传则统计所有设备。
  int getUnreadCount(String employeeId, {String? deviceId});

  /// 批量标记指定员工的消息为已读（SQL 直接更新，返回受影响行数）
  int markAsReadInDb(String employeeId);

  /// 获取指定员工的未读消息 ID 列表
  List<String> getUnreadMessageIds(String employeeId);

  /// 获取指定员工中仍处于 processing 状态的本地工具调用消息 ID 列表
  List<String> getStaleLocalToolCallMessages(String employeeId);

  /// 消息变更通知流
  Stream<MessageChangeEvent> get onMessageChanged;

  /// 获取同步水位线（lastSeq）
  int getLastSeq(String employeeId);

  /// 更新同步水位线（MAX 语义，防止回退）
  void updateLastSeq(String employeeId, int lastSeq);

  /// 强制重置同步水位线（不受 MAX 语义限制，用于清空会话场景）
  void resetLastSeq(String employeeId, int lastSeq);
}

/// 消息存储服务实现
class MessageStoreServiceImpl implements MessageStoreService {
  final MessageStore _store;
  final String? _deviceId;
  final _changeController = StreamController<MessageChangeEvent>.broadcast();

  MessageStoreServiceImpl({
    MessageStore? store,
    String? deviceId,
  })  : _store = store ?? MessageStore(deviceId: deviceId),
        _deviceId = deviceId;

  @override
  Future<List<ChatMessage>> getMessages(
    String employeeId, {
    int? limit,
    int? offset,
  }) async {
    return _store.getMessages(_deviceId, employeeId,
        limit: limit, offset: offset);
  }

  @override
  Future<List<ChatMessage>> getMessagesWithDeviceId(
    String? deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  }) async {
    return _store.getMessages(deviceId, employeeId,
        limit: limit, offset: offset);
  }

  @override
  Future<ChatMessage?> getMessage(
    String uuid, {
    String? deviceId,
  }) async {
    return _store.find(deviceId ?? _deviceId, uuid);
  }

  @override
  Future<ChatMessage> addMessage(
    ChatMessage message, {
    String? deviceId,
    bool updateWatermark = true,
  }) async {
    await _store.addWithDeviceId(deviceId ?? _deviceId, message, updateWatermark: updateWatermark);
    _notifyChange(MessageChangeType.added, message);
    return message;
  }

  @override
  Future<void> addMessages(
    List<ChatMessage> messages, {
    String? deviceId,
  }) async {
    for (final message in messages) {
      await _store.addWithDeviceId(deviceId ?? _deviceId, message);
      _notifyChange(MessageChangeType.added, message);
    }
  }

  @override
  Future<void> updateMessage(
    ChatMessage message, {
    String? deviceId,
    bool updateWatermark = true,
  }) async {
    final updated = message.copyWith(
      updatedAt: DateTime.now(),
    );
    await _store.updateWithDeviceId(deviceId ?? _deviceId, updated, updateWatermark: updateWatermark);
    _notifyChange(MessageChangeType.updated, updated);
  }

  @override
  Future<void> updateMessageStatus(
    String uuid,
    MessageStatus status, {
    String? error,
  }) async {
    await _store.updateStatus(_deviceId, uuid, status, error: error);
    final message = await getMessage(uuid);
    if (message != null) {
      _notifyChange(MessageChangeType.updated, message);
    }
  }

  /// 更新消息状态（指定 deviceId）
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
  Future<void> batchUpdateMessages(
    List<ChatMessage> messages, {
    String? deviceId,
  }) async {
    final now = DateTime.now();
    final updated = messages.map((m) => m.copyWith(updatedAt: now)).toList();
    await _store.batchUpdateWithDeviceId(deviceId ?? _deviceId, updated);
    // 只广播一次聚合事件，而非逐条广播
    if (updated.isNotEmpty) {
      _notifyChange(MessageChangeType.updated, updated.last);
    }
  }

  @override
  Future<void> deleteMessages(String employeeId, {String? deviceId}) async {
    await _store.deleteBySession(deviceId ?? _deviceId, employeeId);
  }

  @override
  Future<void> softDeleteMessage(String uuid) async {
    _store.softDeleteForSync(uuid);
    // 查找实体用于通知
    final message = await _store.find(_deviceId, uuid);
    if (message != null) {
      _notifyChange(MessageChangeType.deleted, message);
    }
  }

  @override
  Future<void> softDeleteBySession(String employeeId) async {
    await _store.softDeleteBySessionForSync(employeeId, deviceId: _deviceId ?? '');
  }

  @override
  int deleteMessagesBeforeSeq(String employeeId, int beforeSeq) {
    return _store.deleteBeforeSeq(employeeId, beforeSeq, deviceId: _deviceId ?? '');
  }

  @override
  int getMaxSeq(String employeeId) {
    return _store.getMaxSeqForEmployeeAll(employeeId, deviceId: _deviceId ?? '');
  }

  @override
  Future<void> hardDeleteMessage(String uuid, {String? deviceId}) async {
    await _store.delete(deviceId ?? _deviceId, uuid);
  }

  @override
  Future<ChatMessage?> getLastMessage(String employeeId) async {
    return _store.getLastMessage(_deviceId, employeeId);
  }

  @override
  int getUnreadCount(String employeeId, {String? deviceId}) {
    return _store.getUnreadCount(employeeId, deviceId: deviceId);
  }

  @override
  int markAsReadInDb(String employeeId) {
    return _store.markAsReadByEmployee(employeeId, deviceId: _deviceId ?? '');
  }

  @override
  List<String> getUnreadMessageIds(String employeeId) {
    return _store.getUnreadMessageIds(employeeId, deviceId: _deviceId ?? '');
  }

  @override
  List<String> getStaleLocalToolCallMessages(String employeeId) {
    return _store.getStaleLocalToolCallMessages(employeeId, deviceId: _deviceId ?? '');
  }

  @override
  Stream<MessageChangeEvent> get onMessageChanged =>
      _changeController.stream;

  @override
  int getLastSeq(String employeeId) {
    final store = SyncWatermarkStore(dbManager: _store.dbManager);
    return store.getLastSeq(employeeId, deviceId: _deviceId ?? '');
  }

  @override
  void updateLastSeq(String employeeId, int lastSeq) {
    final store = SyncWatermarkStore(dbManager: _store.dbManager);
    store.updateLastSeq(employeeId, lastSeq, deviceId: _deviceId ?? '');
  }

  @override
  void resetLastSeq(String employeeId, int lastSeq) {
    final store = SyncWatermarkStore(dbManager: _store.dbManager);
    store.resetLastSeq(employeeId, lastSeq, deviceId: _deviceId ?? '');
  }

  void _notifyChange(MessageChangeType type, ChatMessage message) {
    _changeController.add(MessageChangeEvent(
      type: type,
      messageUuid: message.id,
      employeeId: message.employeeId,
      message: message,
    ));
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

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}
