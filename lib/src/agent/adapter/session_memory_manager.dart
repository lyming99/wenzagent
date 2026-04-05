import 'package:langchain_core/chat_models.dart';

/// 会话消息历史
class SessionHistory {
  final String employeeUuid;
  final String? title;
  final DateTime createdAt;

  /// 消息映射：按设备ID区分不同设备的消息记录
  /// key: deviceId, value: 该设备上的消息列表
  final Map<String, List<ChatMessage>> messagesMap;

  /// 缓存的 LLM 生成的对话摘要
  String? conversationSummary;

  /// 摘要覆盖的消息范围: messages[0..summarizedUpToIndex-1]
  int summarizedUpToIndex;

  SessionHistory({
    required this.employeeUuid,
    this.title,
    DateTime? createdAt,
    Map<String, List<ChatMessage>>? messagesMap,
    this.conversationSummary,
    this.summarizedUpToIndex = 0,
  }) : createdAt = createdAt ?? DateTime.now(),
       messagesMap = messagesMap ?? {};

  /// 获取所有设备的所有消息（合并）
  List<ChatMessage> get allMessages {
    final all = <ChatMessage>[];
    // 按设备ID排序，保持一致性
    final sortedDeviceIds = messagesMap.keys.toList()..sort();
    for (final deviceId in sortedDeviceIds) {
      all.addAll(messagesMap[deviceId]!);
    }
    return all;
  }

  /// 获取指定设备的消息列表
  List<ChatMessage> getMessagesForDevice(String deviceId) {
    return messagesMap[deviceId] ?? [];
  }

  /// 添加消息到指定设备
  void addMessage(String deviceId, ChatMessage message) {
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

  /// 获取所有设备ID列表
  List<String> get deviceIds => messagesMap.keys.toList()..sort();

  /// 获取消息总数（所有设备）
  int get messageCount => messagesMap.values.fold(0, (sum, list) => sum + list.length);

  /// 转换为 Map（用于持久化）
  Map<String, dynamic> toMap() => {
    'employeeUuid': employeeUuid,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'messagesMap': messagesMap.map(
      (deviceId, messages) => MapEntry(
        deviceId,
        messages.map((m) => m.toMap()).toList(),
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
          .map((m) => ChatMessage.fromMap(m as Map<String, dynamic>))
          .toList();
    }

    return SessionHistory(
      employeeUuid: map['employeeUuid'] as String,
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
  /// 会话历史映射（key: employeeUuid）
  final Map<String, SessionHistory> _sessions = {};

  /// 获取或创建会话历史
  SessionHistory getOrCreateSession(
    String employeeUuid, {
    String? title,
  }) {
    return _sessions.putIfAbsent(
      employeeUuid,
      () => SessionHistory(
        employeeUuid: employeeUuid,
        title: title,
      ),
    );
  }

  /// 获取会话历史
  SessionHistory? getSession(String employeeUuid) {
    return _sessions[employeeUuid];
  }

  /// 获取员工的所有会话
  List<SessionHistory> getSessionsByEmployee(String employeeUuid) {
    final session = _sessions[employeeUuid];
    return session != null ? [session] : [];
  }

  /// 获取会话在指定设备上的消息
  List<ChatMessage> getMessagesForDevice(
    String employeeUuid,
    String deviceId,
  ) {
    final session = _sessions[employeeUuid];
    if (session == null) return [];
    return session.getMessagesForDevice(deviceId);
  }

  /// 清空会话在指定设备上的消息
  void clearDeviceSession(String employeeUuid, String deviceId) {
    final session = _sessions[employeeUuid];
    if (session != null) {
      session.clearDevice(deviceId);
    }
  }

  /// 添加消息到会话
  ///
  /// [employeeUuid] 员工UUID（作为会话ID）
  /// [deviceId] 设备ID，用于区分不同设备上的消息
  void addMessage(String employeeUuid, String deviceId, ChatMessage message) {
    final session = _sessions[employeeUuid];
    if (session != null) {
      session.addMessage(deviceId, message);
    }
  }

  /// 清空会话消息
  void clearSession(String employeeUuid) {
    _sessions[employeeUuid]?.clear();
  }

  /// 删除会话
  void deleteSession(String employeeUuid) {
    _sessions.remove(employeeUuid);
  }

  /// 构建发送给 LLM 的消息列表
  ///
  /// 返回 [systemPrompt?, ...session.allMessages]。
  /// 包含所有设备上的消息，按设备ID排序后合并。
  /// 调用方需要在调用此方法前将用户消息加入 session history。
  List<ChatMessage> buildMessages({
    required String employeeUuid,
    String? systemPrompt,
  }) {
    final messages = <ChatMessage>[];

    // 添加系统提示
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      messages.add(ChatMessage.system(systemPrompt));
    }

    // 添加历史消息（已包含最新的用户消息）
    final session = _sessions[employeeUuid];
    if (session != null) {
      messages.addAll(session.allMessages);
    }

    return messages;
  }

  /// 清理所有会话
  void dispose() {
    _sessions.clear();
  }
}
