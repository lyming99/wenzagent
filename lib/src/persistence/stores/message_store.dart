import 'dart:convert';

import '../hive_manager.dart';
import '../entities/message_entity.dart';

/// 消息数据存储
///
/// 使用 Hive putString/getString 读写 JSON 字符串，
/// 所有 key 带 wenz_ 前缀避免与旧二进制数据冲突。
class MessageStore {
  final HiveManager _hiveManager;

  MessageStore({HiveManager? hiveManager})
      : _hiveManager = hiveManager ?? HiveManager.instance;

  /// 从 JSON 字符串解码为 AiEmployeeMessageEntity
  AiEmployeeMessageEntity _decodeEntity(String jsonString) {
    final map = jsonDecode(jsonString) as Map<String, dynamic>;
    return AiEmployeeMessageEntity.fromMessageMap(map);
  }

  /// 获取会话的消息列表
  Future<List<AiEmployeeMessageEntity>> getMessages(
    String? deviceId,
    String employeeId, {
    int? limit,
    int? offset,
  }) async {
    final box = _hiveManager.messageBox;
    final indexBox = _hiveManager.sessionMessagesBox;

    // 获取消息UUID列表
    final indexKey = _hiveManager.buildSessionMessagesKey(deviceId, employeeId);
    List<dynamic> messageUuids = indexBox.get(indexKey) ?? [];

    // 应用偏移和限制
    if (offset != null && offset > 0) {
      messageUuids = messageUuids.skip(offset).toList();
    }
    if (limit != null && limit > 0) {
      messageUuids = messageUuids.take(limit).toList();
    }

    // 获取消息实体（从 JSON 字符串解码）
    final messages = <AiEmployeeMessageEntity>[];
    for (final uuid in messageUuids) {
      final key = _hiveManager.buildMessageKey(deviceId, uuid as String);
      final jsonString = box.get(key);
      if (jsonString is String && jsonString.isNotEmpty) {
        try {
          final entity = _decodeEntity(jsonString);
          if (entity.deleted != 1) {
            messages.add(entity);
          }
        } catch (e) {
          // JSON 解析失败，跳过此条消息
        }
      }
    }

    // 按 createTime 排序，时间相同时按 uuid 排序保证稳定性
    messages.sort((a, b) {
      final timeCompare = a.createTime.compareTo(b.createTime);
      if (timeCompare != 0) return timeCompare;
      return a.uuid.compareTo(b.uuid);
    });

    return messages;
  }

  /// 获取单条消息
  Future<AiEmployeeMessageEntity?> find(String? deviceId, String uuid) async {
    final box = _hiveManager.messageBox;
    final key = _hiveManager.buildMessageKey(deviceId, uuid);
    final jsonString = box.get(key);
    if (jsonString is String && jsonString.isNotEmpty) {
      try {
        return _decodeEntity(jsonString);
      } catch (_) {}
    }
    return null;
  }

  /// 添加消息
  Future<void> add(AiEmployeeMessageEntity entity) async {
    final box = _hiveManager.messageBox;
    final key = _hiveManager.buildMessageKey(
      entity.employeeId.split('-').first,
      entity.uuid,
    );
    // 从employeeId推断deviceId，实际使用时应该传入
    await box.put(key, jsonEncode(entity.toMessageMap()));

    // 更新会话消息索引
    await _updateSessionMessagesIndex(entity);
  }

  /// 使用明确deviceId添加消息
  Future<void> addWithDeviceId(
    String? deviceId,
    AiEmployeeMessageEntity entity,
  ) async {
    final box = _hiveManager.messageBox;
    final key = _hiveManager.buildMessageKey(deviceId, entity.uuid);
    await box.put(key, jsonEncode(entity.toMessageMap()));

    // 更新会话消息索引
    await _updateSessionMessagesIndexWithDeviceId(deviceId, entity);
  }

  /// 更新会话消息索引
  Future<void> _updateSessionMessagesIndex(
    AiEmployeeMessageEntity entity,
  ) async {
    // 从employeeId推断deviceId（简化处理）
    final parts = entity.employeeId.split('-');
    final deviceId = parts.isNotEmpty ? parts.first : null;
    await _updateSessionMessagesIndexWithDeviceId(deviceId, entity);
  }

  /// 使用明确deviceId更新会话消息索引
  Future<void> _updateSessionMessagesIndexWithDeviceId(
    String? deviceId,
    AiEmployeeMessageEntity entity,
  ) async {
    final indexBox = _hiveManager.sessionMessagesBox;
    final indexKey = _hiveManager.buildSessionMessagesKey(
      deviceId,
      entity.employeeId,
    );

    List<dynamic> messageUuids = indexBox.get(indexKey) ?? [];
    if (!messageUuids.contains(entity.uuid)) {
      messageUuids = [...messageUuids, entity.uuid];
      await indexBox.put(indexKey, messageUuids);
    }
  }

  /// 更新消息
  Future<void> update(AiEmployeeMessageEntity entity) async {
    final box = _hiveManager.messageBox;
    final key = _hiveManager.buildMessageKey(
      entity.employeeId.split('-').first,
      entity.uuid,
    );
    await box.put(key, jsonEncode(entity.toMessageMap()));
  }

  /// 使用明确deviceId更新消息
  Future<void> updateWithDeviceId(
    String? deviceId,
    AiEmployeeMessageEntity entity,
  ) async {
    final box = _hiveManager.messageBox;
    final key = _hiveManager.buildMessageKey(deviceId, entity.uuid);
    await box.put(key, jsonEncode(entity.toMessageMap()));
  }

  /// 更新消息状态
  Future<void> updateStatus(
    String? deviceId,
    String uuid,
    String status, {
    String? error,
  }) async {
    final msg = await find(deviceId, uuid);
    if (msg != null) {
      final updated = msg.copyWith(
        processingStatus: status,
        processingError: error,
        updateTime: DateTime.now(),
      );
      await updateWithDeviceId(deviceId, updated);
    }
  }

  /// 删除会话的所有消息
  Future<void> deleteBySession(String? deviceId, String employeeId) async {
    final indexBox = _hiveManager.sessionMessagesBox;
    final box = _hiveManager.messageBox;

    final indexKey = _hiveManager.buildSessionMessagesKey(deviceId, employeeId);
    List<dynamic> messageUuids = indexBox.get(indexKey) ?? [];

    for (final uuid in messageUuids) {
      final key = _hiveManager.buildMessageKey(deviceId, uuid as String);
      await box.delete(key);
    }

    await indexBox.delete(indexKey);
  }
  
  /// 删除单条消息（硬删除）
  Future<void> delete(String? deviceId, String uuid) async {
    final box = _hiveManager.messageBox;
    final key = _hiveManager.buildMessageKey(deviceId, uuid);
    
    // 从消息存储中删除
    await box.delete(key);
  }

  /// 获取最后一条消息
  Future<AiEmployeeMessageEntity?> getLastMessage(
    String? deviceId,
    String employeeId,
  ) async {
    final messages = await getMessages(deviceId, employeeId, limit: 1);
    if (messages.isEmpty) return null;
    return messages.first;
  }

  /// 获取消息数量
  Future<int> count(String? deviceId, String employeeId) async {
    final indexBox = _hiveManager.sessionMessagesBox;
    final indexKey = _hiveManager.buildSessionMessagesKey(deviceId, employeeId);
    List<dynamic> messageUuids = indexBox.get(indexKey) ?? [];
    return messageUuids.length;
  }
}
