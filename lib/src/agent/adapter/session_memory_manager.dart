import 'package:uuid/uuid.dart';

import '../../service/message_store_service.dart';
import '../../shared/shared.dart';

/// 会话消息历史
///
/// [messagesMap] 按 deviceId 分组存储 [ChatMessage]。
/// ChatMessage 自身已包含 uuid、createdAt、metadata 等字段，
/// 无需再使用 MessageWrapper 包装。
class SessionHistory {
  final String employeeId;
  final String? title;
  final DateTime createdAt;

  /// 消息映射：按设备ID区分不同设备的消息记录
  final Map<String, List<ChatMessage>> messagesMap;

  /// 缓存的 LLM 生成的对话摘要
  String? conversationSummary;

  /// 摘要覆盖的消息范围: messages[0..summarizedUpToIndex-1]
  int summarizedUpToIndex;

  SessionHistory({
    required this.employeeId,
    this.title,
    DateTime? createdAt,
    Map<String, List<ChatMessage>>? messagesMap,
    this.conversationSummary,
    this.summarizedUpToIndex = 0,
  }) : createdAt = createdAt ?? DateTime.now(),
       messagesMap = messagesMap ?? {};

  /// 获取所有设备的所有消息（合并），按 createdAt 升序排列
  List<ChatMessage> get allMessages {
    final all = <ChatMessage>[];
    for (final messages in messagesMap.values) {
      all.addAll(messages);
    }
    all.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return all;
  }

  /// 获取指定设备的消息列表
  List<ChatMessage> getMessagesForDevice(String deviceId) {
    return messagesMap[deviceId] ?? [];
  }

  /// 添加消息到指定设备
  ///
  /// [messageId] 可选的消息ID，如果不提供则自动生成
  /// [metadata] 可选的元数据，用于携带额外信息（如 toolName）
  void addMessage(String deviceId, ChatMessage message) {
    messagesMap.putIfAbsent(deviceId, () => []).add(message);
  }

  /// 按时间升序排列指定设备的消息
  void sortMessages(String deviceId) {
    messagesMap[deviceId]?.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  /// 添加 ChatMessage 到指定设备（与 addMessage 相同，保留语义）
  void addChatMessage(String deviceId, ChatMessage message) {
    messagesMap.putIfAbsent(deviceId, () => []).add(message);
  }

  /// 清空所有设备的消息
  void clear() {
    messagesMap.clear();
    conversationSummary = null;
    summarizedUpToIndex = 0;
  }

  /// 清空指定设备的消息
  void clearDevice(String deviceId) {
    messagesMap.remove(deviceId);
  }

  /// 删除指定消息
  ///
  /// 从所有设备中删除指定 ID 的消息
  /// 返回是否成功删除
  bool removeMessage(String messageId) {
    bool removed = false;
    for (final deviceId in messagesMap.keys) {
      final messages = messagesMap[deviceId]!;
      final index = messages.indexWhere((m) => m.id == messageId);
      if (index >= 0) {
        messages.removeAt(index);
        removed = true;
        print('[SessionHistory] 已删除消息: $messageId (设备: $deviceId)');
      }
    }
    return removed;
  }

  /// 获取所有设备ID列表
  List<String> get deviceIds => messagesMap.keys.toList()..sort();

  /// 获取消息总数（所有设备）
  int get messageCount => messagesMap.values.fold(0, (sum, list) => sum + list.length);

  /// 转换为 Map（用于持久化）
  Map<String, dynamic> toMap() => {
    'employeeId': employeeId,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'messagesMap': messagesMap.map(
      (deviceId, messages) => MapEntry(
        deviceId,
        messages.map((m) => m.toJson()).toList(),
      ),
    ),
    if (conversationSummary != null) 'conversationSummary': conversationSummary,
    if (summarizedUpToIndex > 0) 'summarizedUpToIndex': summarizedUpToIndex,
  };

  /// 从 Map 创建
  static SessionHistory fromMap(Map<String, dynamic> map) {
    final messagesMapData = map['messagesMap'] as Map? ?? {};
    final messagesMap = <String, List<ChatMessage>>{};

    for (final entry in messagesMapData.entries) {
      final deviceId = entry.key as String;
      final messagesList = entry.value as List? ?? [];
      messagesMap[deviceId] = messagesList
          .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
          .toList();
    }

    return SessionHistory(
      employeeId: map['employeeId'] as String,
      title: map['title'] as String?,
      createdAt: map['createdAt'] != null
          ? DateTime.parse(map['createdAt'] as String)
          : null,
      messagesMap: messagesMap,
      conversationSummary: map['conversationSummary'] as String?,
      summarizedUpToIndex: map['summarizedUpToIndex'] as int? ?? 0,
    );
  }
}

/// 会话记忆管理器
class SessionMemoryManager {
  /// 会话历史映射（key: employeeId）
  final Map<String, SessionHistory> _sessions = {};

  MessageStoreService? _messageStore;
  String? _deviceId;

  /// 判断是否已配置持久化
  bool get isPersisted => _messageStore != null;

  /// isRead 判断回调（由外部注入，用于 assistant 消息立即标记已读）
  bool Function(String employeeId)? shouldMarkAsRead;

  /// 配置持久化（由 DeviceAgentManager/AgentFactoryImpl 调用）
  void configurePersistence({
    required MessageStoreService messageStore,
    required String deviceId,
  }) {
    _messageStore = messageStore;
    _deviceId = deviceId;
  }

  /// 获取或创建会话历史
  SessionHistory getOrCreateSession(
    String employeeId, {
    String? title,
  }) {
    return _sessions.putIfAbsent(
      employeeId,
      () => SessionHistory(
        employeeId: employeeId,
        title: title,
      ),
    );
  }

  /// 获取会话历史
  SessionHistory? getSession(String employeeId) {
    return _sessions[employeeId];
  }

  /// 获取员工的所有会话
  List<SessionHistory> getSessionsByEmployee(String employeeId) {
    final session = _sessions[employeeId];
    return session != null ? [session] : [];
  }

  /// 获取会话在指定设备上的消息
  List<ChatMessage> getMessagesForDevice(
    String employeeId,
    String deviceId,
  ) {
    final session = _sessions[employeeId];
    if (session == null) return [];
    return session.getMessagesForDevice(deviceId);
  }

  /// 清空会话在指定设备上的消息
  void clearDeviceSession(String employeeId, String deviceId) {
    final session = _sessions[employeeId];
    if (session != null) {
      session.clearDevice(deviceId);
    }
  }

  /// 添加消息到会话
  ///
  /// [employeeId] 员工ID（作为会话ID）
  /// [deviceId] 设备ID，用于区分不同设备上的消息
  /// [message] ChatMessage（调用方负责设置 id 和 employeeId）
  void addMessage(
    String employeeId,
    String deviceId,
    ChatMessage message,
  ) {
    final session = _sessions[employeeId];
    if (session != null) {
      session.addMessage(deviceId, message);
    }
    // 同步写入 DB
    if (_messageStore != null && _deviceId != null) {
      var msgToSave = message;
      if (message.role == MessageRole.assistant &&
          shouldMarkAsRead?.call(employeeId) == true) {
        msgToSave = message.copyWith(isRead: true);
      }
      _messageStore!.addMessage(msgToSave, deviceId: _deviceId!);
    }
  }

  /// 清空会话消息
  void clearSession(String employeeId) {
    _sessions[employeeId]?.clear();
  }

  /// 删除会话
  void deleteSession(String employeeId) {
    _sessions.remove(employeeId);
  }

  /// 构建发送给 LLM 的消息列表
  ///
  /// 返回 [systemPrompt?, ...session.allMessages]。
  /// 包含所有设备上的消息，按设备ID排序后合并。
  /// 调用方需要在调用此方法前将用户消息加入 session history。
  ///
  /// 连续的 tool 角色消息会被合并为一条分组消息（ChatMessage.toolResultGroup），
  /// 以确保 OpenAI 兼容性。
  List<ChatMessage> buildMessages({
    required String employeeId,
    String? systemPrompt,
  }) {
    final messages = <ChatMessage>[];

    // 添加系统提示
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      messages.add(ChatMessage.system(
        id: const Uuid().v4(),
        employeeId: employeeId,
        content: systemPrompt,
      ));
    }

    // 添加历史消息（已包含最新的用户消息）
    final session = _sessions[employeeId];
    if (session != null) {
      // 提取所有消息，并合并连续的 tool 消息
      final rawMessages = session.allMessages;
      messages.addAll(LlmMessageMapper.mergeConsecutiveToolResults(rawMessages));
    }

    return messages;
  }

  /// 从 DB 加载消息到内存（初始化时调用）
  ///
  /// [limit] 限制加载条数；为 null 时通过分页加载全部消息。
  Future<void> loadFromDb(String employeeId, {int? limit}) async {
    if (_messageStore == null || _deviceId == null) return;
    final session = getOrCreateSession(employeeId);

    if (limit != null) {
      final messages = await _messageStore!.getMessagesWithDeviceId(
        _deviceId!, employeeId, limit: limit,
      );
      for (final msg in messages) {
        session.addMessage(_deviceId!, msg);
      }
    } else {
      // 分页加载全部消息，避免单次查询过大
      const pageSize = 200;
      int offset = 0;
      while (true) {
        final messages = await _messageStore!.getMessagesWithDeviceId(
          _deviceId!, employeeId, limit: pageSize, offset: offset,
        );
        if (messages.isEmpty) break;
        for (final msg in messages) {
          session.addMessage(_deviceId!, msg);
        }
        if (messages.length < pageSize) break;
        offset += pageSize;
      }
    }

    // 按时间排序，确保消息顺序正确
    session.sortMessages(_deviceId!);
  }

  /// 清空会话（内存 + DB）
  Future<void> clearSessionFromDb(String employeeId) async {
    clearSession(employeeId);
    if (_messageStore != null) {
      await _messageStore!.deleteMessages(employeeId, deviceId: _deviceId);
    }
  }

  /// 获取指定 employee 的最大 seq（含已软删除的消息）
  int getMaxSeq(String employeeId) {
    return _messageStore?.getMaxSeq(employeeId) ?? 0;
  }

  /// 更新消息状态（写 DB）
  Future<void> updateMessageStatusInDb(
    String messageId, String status, {String? error}
  ) async {
    await _messageStore?.updateMessageStatus(
      messageId, MessageStatus.fromString(status), error: error,
    );
  }

  /// 软删除消息（写 DB）
  Future<void> softDeleteMessage(String messageId) async {
    await _messageStore?.softDeleteMessage(messageId);
  }

  /// 清理所有会话
  void dispose() {
    _sessions.clear();
  }
}
