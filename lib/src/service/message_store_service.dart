import 'dart:async';
import 'dart:convert';

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
  final AiEmployeeMessageEntity? message;

  MessageChangeEvent({
    required this.type,
    required this.messageUuid,
    required this.employeeId,
    this.message,
  });
}

/// 消息存储服务接口
abstract class MessageStoreService {
  /// 获取会话消息列表
  Future<List<AiEmployeeMessageEntity>> getMessages(
    String employeeId, {
    int? limit,
    int? offset,
  });

  /// 获取单条消息
  Future<AiEmployeeMessageEntity?> getMessage(String uuid);

  /// 添加消息
  Future<AiEmployeeMessageEntity> addMessage(AiEmployeeMessageEntity message);

  /// 批量添加消息
  Future<void> addMessages(List<AiEmployeeMessageEntity> messages);

  /// 更新消息
  Future<void> updateMessage(AiEmployeeMessageEntity message);

  /// 更新消息状态
  Future<void> updateMessageStatus(
    String uuid,
    String status, {
    String? error,
  });

  /// 删除会话的所有消息
  Future<void> deleteMessages(String employeeId);

  /// 获取最后一条消息
  Future<AiEmployeeMessageEntity?> getLastMessage(String employeeId);

  /// 消息变更通知流
  Stream<MessageChangeEvent> get onMessageChanged;
}

/// 消息存储服务实现
class MessageStoreServiceImpl implements MessageStoreService {
  final MessageStore _store;
  final String? _deviceId;
  final _changeController = StreamController<MessageChangeEvent>.broadcast();

  MessageStoreServiceImpl({
    MessageStore? store,
    String? deviceId,
  })  : _store = store ?? MessageStore(),
        _deviceId = deviceId;

  @override
  Future<List<AiEmployeeMessageEntity>> getMessages(
    String employeeId, {
    int? limit,
    int? offset,
  }) async {
    return _store.getMessages(_deviceId, employeeId,
        limit: limit, offset: offset);
  }

  @override
  Future<AiEmployeeMessageEntity?> getMessage(String uuid) async {
    return _store.find(_deviceId, uuid);
  }

  @override
  Future<AiEmployeeMessageEntity> addMessage(
      AiEmployeeMessageEntity message) async {
    await _store.addWithDeviceId(_deviceId, message);
    _notifyChange(MessageChangeType.added, message);
    return message;
  }

  @override
  Future<void> addMessages(List<AiEmployeeMessageEntity> messages) async {
    for (final message in messages) {
      await _store.addWithDeviceId(_deviceId, message);
      _notifyChange(MessageChangeType.added, message);
    }
  }

  @override
  Future<void> updateMessage(AiEmployeeMessageEntity message) async {
    final updated = message.copyWith(
      updateTime: DateTime.now(),
    );
    await _store.updateWithDeviceId(_deviceId, updated);
    _notifyChange(MessageChangeType.updated, updated);
  }

  @override
  Future<void> updateMessageStatus(
    String uuid,
    String status, {
    String? error,
  }) async {
    await _store.updateStatus(_deviceId, uuid, status, error: error);
    final message = await getMessage(uuid);
    if (message != null) {
      _notifyChange(MessageChangeType.updated, message);
    }
  }

  @override
  Future<void> deleteMessages(String employeeId) async {
    await _store.deleteBySession(_deviceId, employeeId);
  }

  @override
  Future<AiEmployeeMessageEntity?> getLastMessage(String employeeId) async {
    return _store.getLastMessage(_deviceId, employeeId);
  }

  @override
  Stream<MessageChangeEvent> get onMessageChanged =>
      _changeController.stream;

  void _notifyChange(MessageChangeType type, AiEmployeeMessageEntity message) {
    _changeController.add(MessageChangeEvent(
      type: type,
      messageUuid: message.uuid,
      employeeId: message.employeeId,
      message: message,
    ));
  }

  /// 创建新消息实体
  AiEmployeeMessageEntity createMessage({
    required String employeeId,
    required String role,
    required String type,
    String? content,
    String? toolCallId,
    String? toolName,
    String? toolArguments,
    String? toolResult,
    String? toolCalls,
  }) {
    final uuid = const Uuid().v4();
    final now = DateTime.now();
    return AiEmployeeMessageEntity(
      uuid: uuid,
      employeeId: employeeId,
      role: role,
      type: type,
      content: content,
      toolCallId: toolCallId,
      toolName: toolName,
      toolArguments: toolArguments,
      toolResult: toolResult,
      toolCalls: toolCalls,
      createTime: now,
      updateTime: now,
    );
  }

  /// 从Map创建消息实体
  AiEmployeeMessageEntity fromMap(Map<String, dynamic> map) {
    return AiEmployeeMessageEntity.fromMap(map);
  }

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}
