import 'dart:async';
import 'dart:convert';

import 'package:langchain_core/chat_models.dart';

import '../agent_state.dart';
import '../processor/cancellation_token.dart';
import '../processor/message_processor.dart';
import 'langchain_chat_adapter.dart';

/// 持久化回调函数类型
typedef PersistMessageFunc = Future<void> Function(Map<String, dynamic> message);
typedef PersistSessionFunc = Future<void> Function(Map<String, dynamic> session);
typedef LoadSessionFunc = Future<Map<String, dynamic>?> Function(String sessionUuid);
typedef LoadMessagesFunc = Future<List<Map<String, dynamic>>> Function(String sessionUuid);
typedef UpdateMessageStatusFunc = Future<void> Function(String messageId, AgentMessageStatus status, {String? error});

/// 持久化聊天适配器
///
/// 继承 [LangChainChatAdapter]，在内存操作的基础上添加持久化回调。
/// 每次会话/消息变更后自动调用回调函数持久化到数据库。
class PersistentChatAdapter extends LangChainChatAdapter {
  /// 持久化会话回调
  PersistSessionFunc? persistSession;

  /// 持久化消息回调
  PersistMessageFunc? persistMessage;

  /// 加载会话回调
  LoadSessionFunc? loadSession;

  /// 加载消息回调
  LoadMessagesFunc? loadMessages;

  /// 更新消息状态回调
  UpdateMessageStatusFunc? updateMessageStatusCallback;

  /// 已持久化的消息 ID 集合（避免重复持久化）
  final Set<String> _persistedMessageIds = {};

  PersistentChatAdapter();

  @override
  Future<void> initSession({
    required String employeeUuid,
    String? sessionUuid,
  }) async {
    await super.initSession(employeeUuid: employeeUuid, sessionUuid: sessionUuid);

    // 如果提供了会话UUID且存在加载回调，尝试从数据库加载
    if (sessionUuid != null && loadSession != null) {
      final sessionData = await loadSession!(sessionUuid);
      if (sessionData != null) {
        // 恢复会话配置（如 provider_config 等）
        final providerConfig = sessionData['providerConfig'];
        if (providerConfig != null && getProviderConfig() == null) {
          try {
            await updateProvider(Map<String, dynamic>.from(providerConfig));
          } catch (_) {
            // 忽略模型加载失败
          }
        }
      }
    }

    // 持久化会话
    await _notifyPersistSession();
  }

  @override
  Future<String> createNewSession({
    required String employeeUuid,
    String? title,
  }) async {
    final sessionUuid = await super.createNewSession(
      employeeUuid: employeeUuid,
      title: title,
    );

    // 持久化新会话
    await _notifyPersistSession();

    return sessionUuid;
  }

  @override
  Future<void> switchSession(String sessionUuid) async {
    // 停止流式输出
    if (isStreaming) {
      await stopStreaming();
    }

    // 尝试从内存获取会话
    var session = memoryManager.getSession(sessionUuid);

    // 如果内存中不存在，尝试从数据库加载
    if (session == null && loadSession != null) {
      final sessionData = await loadSession!(sessionUuid);
      if (sessionData != null) {
        // 从数据库加载会话到内存
        final employeeUuid = sessionData['employeeUuid'] as String? ??
            currentSessionUuid?.split('-').last ?? 'unknown';
        session = memoryManager.getOrCreateSession(sessionUuid, employeeUuid);
        // 不再调用 _notifyPersistSession，避免重复创建
      }
    }

    // 如果仍然不存在，创建新会话但不持久化（让调用方决定是否持久化）
    if (session == null) {
      final employeeUuid = currentSessionUuid?.split('-').last ?? 'unknown';
      session = memoryManager.getOrCreateSession(sessionUuid, employeeUuid);
      // 注意：这里不调用 _notifyPersistSession()，避免自动持久化
    }

    // 更新当前会话 UUID
    currentSessionUuidValue = sessionUuid;

    // 从数据库加载消息到内存（如果有加载回调）
    final loadCb = loadMessages;
    if (loadCb == null) return;

    try {
      final messagesData = await loadCb(sessionUuid);
      if (messagesData.isEmpty) return;

      // 清空现有消息并加载新消息
      session.messages.clear();
      for (final msgData in messagesData) {
        final chatMessage = _mapToChatMessage(msgData);
        if (chatMessage != null) {
          session.messages.add(chatMessage);
          // 记录已持久化的消息 ID
          final msgId = msgData['id'] as String?;
          if (msgId != null) {
            _persistedMessageIds.add(msgId);
          }
        }
      }
    } catch (_) {
      // 忽略加载失败
    }
  }

  @override
  Future<void> clearCurrentSession() async {
    await super.clearCurrentSession();
    await _notifyPersistSession();
  }

  @override
  Future<void> updateProvider(Map<String, dynamic> providerConfig) async {
    await super.updateProvider(providerConfig);
    // 模型配置变更后持久化会话
    await _notifyPersistSession();
  }

  @override
  Future<void> updateProjectContext(Map<String, dynamic>? projectContext) async {
    await super.updateProjectContext(projectContext);
    await _notifyPersistSession();
  }

  @override
  void setContext(Map<String, dynamic> contextData) {
    super.setContext(contextData);
    // 同步持久化（不等待）
    _notifyPersistSession();
  }

  @override
  void updateMessageStatus(
    String messageId,
    AgentMessageStatus status, {
    String? error,
  }) {
    // 调用持久化回调
    updateMessageStatusCallback?.call(messageId, status, error: error);
  }

  @override
  Stream<StreamResponse> streamMessage(
    Map<String, dynamic> messageData, {
    CancellationToken? cancellationToken,
  }) async* {
    print('[PersistentChatAdapter] streamMessage called: ${messageData['content']?.toString().substring(0, (messageData['content']?.toString().length ?? 0).clamp(0, 50))}');
    print('[PersistentChatAdapter] currentSessionUuid: $currentSessionUuid');
    print('[PersistentChatAdapter] providerConfig: ${getProviderConfig()}');

    // 记录持久化前的消息数量
    final messagesBefore = currentMessages.length;
    print('[PersistentChatAdapter] messages before: $messagesBefore');

    // 调用父类的流式消息方法
    await for (final response in super.streamMessage(
      messageData,
      cancellationToken: cancellationToken,
    )) {
      print('[PersistentChatAdapter] response: ${response.isDone ? "DONE" : response.error != null ? "ERROR: ${response.error}" : "CHUNK: ${response.content?.substring(0, (response.content?.length ?? 0).clamp(0, 30))}"}');
      yield response;

      // 流完成后持久化新消息
      if (response.isDone) {
        print('[PersistentChatAdapter] persisting new messages, before: $messagesBefore, after: ${currentMessages.length}');
        await _persistNewMessages(messagesBefore);
      }
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String sessionUuid,
  ) async {
    // 直接返回内存中的消息，不触发持久化
    return await super.getSessionMessages(sessionUuid);
  }

  /// 持久化新添加的消息
  Future<void> _persistNewMessages(int messagesBefore) async {
    final currentMsgs = currentMessages;
    if (currentMsgs.length <= messagesBefore) return;

    // 只持久化新增的消息
    for (var i = messagesBefore; i < currentMsgs.length; i++) {
      final message = currentMsgs[i];
      final messageId = message['id'] as String?;
      if (messageId != null && !_persistedMessageIds.contains(messageId)) {
        await _persistMessage(message);
        _persistedMessageIds.add(messageId);
      }
    }
  }

  /// 持久化单条消息
  Future<void> _persistMessage(Map<String, dynamic> message) async {
    if (persistMessage == null) return;

    try {
      // 添加 sessionUuid
      final messageWithSession = {
        ...message,
        'sessionUuid': currentSessionUuid,
      };
      await persistMessage!(messageWithSession);
    } catch (_) {
      // 忽略持久化失败，不影响内存操作
    }
  }

  /// 通知持久化会话
  Future<void> _notifyPersistSession() async {
    if (persistSession == null) return;

    try {
      final sessionData = _buildSessionData();
      await persistSession!(sessionData);
    } catch (_) {
      // 忽略持久化失败，不影响内存操作
    }
  }

  /// 构建会话数据用于持久化
  Map<String, dynamic> _buildSessionData() {
    final sessionUuid = currentSessionUuid ?? '';
    final context = currentContext ?? {};

    return {
      'uuid': sessionUuid,
      'title': context['title'] ?? '新对话',
      'contextData': context['contextData'],
      'providerConfig': getProviderConfig(),
      'projectUuid': context['projectUuid'],
      'updateTime': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// 将数据库消息格式转换为 LangChain ChatMessage
  ChatMessage? _mapToChatMessage(Map<String, dynamic> map) {
    final role = map['role'] as String? ?? 'user';
    final content = map['content'] as String? ?? '';
    final type = map['type'] as String? ?? 'text';

    // 处理工具消息
    if (type == 'functionResult' || role == 'tool') {
      final toolCallId = map['toolCallId'] as String? ??
          map['id'] as String? ??
          '';
      return ToolChatMessage(
        toolCallId: toolCallId,
        content: content,
      );
    }

    // 解析 toolCalls
    List<AIChatMessageToolCall>? parsedToolCalls;
    final toolCalls = map['toolCalls'] as List?;
    if (toolCalls != null && toolCalls.isNotEmpty) {
      parsedToolCalls = toolCalls.map((tc) {
        final tcMap = tc as Map<String, dynamic>;
        final argsStr = tcMap['arguments'] as String? ?? '{}';
        Map<String, dynamic> argsMap = {};
        try {
          argsMap = jsonDecode(argsStr) as Map<String, dynamic>? ?? {};
        } catch (_) {}
        return AIChatMessageToolCall(
          id: tcMap['id'] as String? ?? '',
          name: tcMap['name'] as String? ?? '',
          argumentsRaw: argsStr,
          arguments: argsMap,
        );
      }).toList();
    }

    // 处理函数调用消息
    if (type == 'functionCall' && parsedToolCalls != null) {
      return AIChatMessage(
        content: content,
        toolCalls: parsedToolCalls,
      );
    }

    // 根据角色创建消息
    switch (role) {
      case 'user':
        return ChatMessage.humanText(content);
      case 'assistant':
        if (parsedToolCalls != null && parsedToolCalls.isNotEmpty) {
          return AIChatMessage(
            content: content,
            toolCalls: parsedToolCalls,
          );
        }
        return ChatMessage.ai(content);
      case 'system':
        return ChatMessage.system(content);
      default:
        // 默认作为用户消息
        return ChatMessage.humanText(content);
    }
  }
}
