import '../hive_manager.dart';
import '../entities/message_entity.dart';

/// 消息数据存储
class MessageStore {
  final HiveManager _hiveManager;

  MessageStore({HiveManager? hiveManager})
      : _hiveManager = hiveManager ?? HiveManager.instance;

  /// 获取会话的消息列表
  Future<List<AiEmployeeMessageEntity>> getMessages(
    String? spaceId,
    String employeeId, {
    int? limit,
    int? offset,
  }) async {
    final box = _hiveManager.messageBox;
    final indexBox = _hiveManager.sessionMessagesBox;

    // 获取消息UUID列表
    final indexKey = _hiveManager.buildSessionMessagesKey(spaceId, employeeId);
    List<dynamic> messageUuids = indexBox.get(indexKey) ?? [];

    // 应用偏移和限制
    if (offset != null && offset > 0) {
      messageUuids = messageUuids.skip(offset).toList();
    }
    if (limit != null && limit > 0) {
      messageUuids = messageUuids.take(limit).toList();
    }

    // 获取消息实体
    final messages = <AiEmployeeMessageEntity>[];
    for (final uuid in messageUuids) {
      final key = _hiveManager.buildMessageKey(spaceId, uuid as String);
      final msg = box.get(key);
      if (msg != null && msg.deleted != 1) {
        messages.add(msg);
      }
    }

    return messages;
  }

  /// 获取单条消息
  Future<AiEmployeeMessageEntity?> find(String? spaceId, String uuid) async {
    final box = _hiveManager.messageBox;
    final key = _hiveManager.buildMessageKey(spaceId, uuid);
    return box.get(key);
  }

  /// 添加消息
  Future<void> add(AiEmployeeMessageEntity entity) async {
    final box = _hiveManager.messageBox;
    final key = _hiveManager.buildMessageKey(entity.employeeId.split('-').first, entity.uuid);
    // 从employeeId推断spaceId，实际使用时应该传入
    await box.put(key, entity);

    // 更新会话消息索引
    await _updateSessionMessagesIndex(entity);
  }

  /// 使用明确spaceId添加消息
  Future<void> addWithSpaceId(String? spaceId, AiEmployeeMessageEntity entity) async {
    final box = _hiveManager.messageBox;
    final key = _hiveManager.buildMessageKey(spaceId, entity.uuid);
    await box.put(key, entity);

    // 更新会话消息索引
    await _updateSessionMessagesIndexWithSpaceId(spaceId, entity);
  }

  /// 更新会话消息索引
  Future<void> _updateSessionMessagesIndex(AiEmployeeMessageEntity entity) async {
    // 从employeeId推断spaceId（简化处理）
    final parts = entity.employeeId.split('-');
    final spaceId = parts.isNotEmpty ? parts.first : null;
    await _updateSessionMessagesIndexWithSpaceId(spaceId, entity);
  }

  /// 使用明确spaceId更新会话消息索引
  Future<void> _updateSessionMessagesIndexWithSpaceId(
    String? spaceId,
    AiEmployeeMessageEntity entity,
  ) async {
    final indexBox = _hiveManager.sessionMessagesBox;
    final indexKey = _hiveManager.buildSessionMessagesKey(spaceId, entity.employeeId);

    List<dynamic> messageUuids = indexBox.get(indexKey) ?? [];
    if (!messageUuids.contains(entity.uuid)) {
      messageUuids = [...messageUuids, entity.uuid];
      await indexBox.put(indexKey, messageUuids);
    }
  }

  /// 更新消息
  Future<void> update(AiEmployeeMessageEntity entity) async {
    final box = _hiveManager.messageBox;
    final key = _hiveManager.buildMessageKey(entity.employeeId.split('-').first, entity.uuid);
    await box.put(key, entity);
  }

  /// 使用明确spaceId更新消息
  Future<void> updateWithSpaceId(String? spaceId, AiEmployeeMessageEntity entity) async {
    final box = _hiveManager.messageBox;
    final key = _hiveManager.buildMessageKey(spaceId, entity.uuid);
    await box.put(key, entity);
  }

  /// 更新消息状态
  Future<void> updateStatus(
    String? spaceId,
    String uuid,
    String status, {
    String? error,
  }) async {
    final msg = await find(spaceId, uuid);
    if (msg != null) {
      final updated = msg.copyWith(
        processingStatus: status,
        processingError: error,
        updateTime: DateTime.now(),
      );
      await updateWithSpaceId(spaceId, updated);
    }
  }

  /// 删除会话的所有消息
  Future<void> deleteBySession(String? spaceId, String employeeId) async {
    final indexBox = _hiveManager.sessionMessagesBox;
    final box = _hiveManager.messageBox;

    final indexKey = _hiveManager.buildSessionMessagesKey(spaceId, employeeId);
    List<dynamic> messageUuids = indexBox.get(indexKey) ?? [];

    for (final uuid in messageUuids) {
      final key = _hiveManager.buildMessageKey(spaceId, uuid as String);
      await box.delete(key);
    }

    await indexBox.delete(indexKey);
  }

  /// 获取最后一条消息
  Future<AiEmployeeMessageEntity?> getLastMessage(
    String? spaceId,
    String employeeId,
  ) async {
    final messages = await getMessages(spaceId, employeeId, limit: 1);
    if (messages.isEmpty) return null;
    return messages.first;
  }

  /// 获取消息数量
  Future<int> count(String? spaceId, String employeeId) async {
    final indexBox = _hiveManager.sessionMessagesBox;
    final indexKey = _hiveManager.buildSessionMessagesKey(spaceId, employeeId);
    List<dynamic> messageUuids = indexBox.get(indexKey) ?? [];
    return messageUuids.length;
  }
}
