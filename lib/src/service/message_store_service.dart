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
  /// 获取会话消息列表（使用默认 deviceId）
  Future<List<AiEmployeeMessageEntity>> getMessages(
    String employeeId, {
    int? limit,
    int? offset,
  });

  /// 获取会话消息列表（指定 deviceId）
  Future<List<AiEmployeeMessageEntity>> getMessagesWithDeviceId(
    String? deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  });

  /// 获取单条消息
  Future<AiEmployeeMessageEntity?> getMessage(String uuid, {String? deviceId});

  /// 添加消息
  Future<AiEmployeeMessageEntity> addMessage(
    AiEmployeeMessageEntity message, {
    String? deviceId,
  });

  /// 批量添加消息
  Future<void> addMessages(
    List<AiEmployeeMessageEntity> messages, {
    String? deviceId,
  });

  /// 更新消息
  Future<void> updateMessage(
    AiEmployeeMessageEntity message, {
    String? deviceId,
  });

  /// 更新消息状态
  Future<void> updateMessageStatus(
    String uuid,
    String status, {
    String? error,
  });

  /// 批量更新消息（减少逐条 await 的开销）
  ///
  /// 适用于 markAllAsRead 等场景，内部逐条更新但不逐条广播变更事件，
  /// 只在最后发送一次聚合通知。
  Future<void> batchUpdateMessages(
    List<AiEmployeeMessageEntity> messages, {
    String? deviceId,
  });

  /// 删除会话的所有消息
  ///
  /// [deviceId] 设备ID，为null时使用实例默认deviceId
  /// [employeeId] 员工ID
  Future<void> deleteMessages(String employeeId, {String? deviceId});
  
  /// 硬删除单条消息（从数据库直接删除，非软删除）
  ///
  /// [uuid] 消息UUID
  /// [deviceId] 设备ID，为null时使用实例默认deviceId
  Future<void> hardDeleteMessage(String uuid, {String? deviceId});

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
  Future<List<AiEmployeeMessageEntity>> getMessagesWithDeviceId(
    String? deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  }) async {
    return _store.getMessages(deviceId, employeeId,
        limit: limit, offset: offset);
  }

  @override
  Future<AiEmployeeMessageEntity?> getMessage(
    String uuid, {
    String? deviceId,
  }) async {
    return _store.find(deviceId ?? _deviceId, uuid);
  }

  @override
  Future<AiEmployeeMessageEntity> addMessage(
    AiEmployeeMessageEntity message, {
    String? deviceId,
  }) async {
    await _store.addWithDeviceId(deviceId ?? _deviceId, message);
    _notifyChange(MessageChangeType.added, message);
    return message;
  }

  @override
  Future<void> addMessages(
    List<AiEmployeeMessageEntity> messages, {
    String? deviceId,
  }) async {
    for (final message in messages) {
      await _store.addWithDeviceId(deviceId ?? _deviceId, message);
      _notifyChange(MessageChangeType.added, message);
    }
  }

  @override
  Future<void> updateMessage(
    AiEmployeeMessageEntity message, {
    String? deviceId,
  }) async {
    final updated = message.copyWith(
      updateTime: DateTime.now(),
    );
    await _store.updateWithDeviceId(deviceId ?? _deviceId, updated);
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
  Future<void> batchUpdateMessages(
    List<AiEmployeeMessageEntity> messages, {
    String? deviceId,
  }) async {
    final now = DateTime.now();
    final updated = messages.map((m) => m.copyWith(updateTime: now)).toList();
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
  Future<void> hardDeleteMessage(String uuid, {String? deviceId}) async {
    await _store.delete(deviceId ?? _deviceId, uuid);
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
