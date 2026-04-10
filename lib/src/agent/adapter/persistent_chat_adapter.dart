import 'dart:async';
import 'dart:convert';

import 'package:langchain_core/chat_models.dart';

import '../agent_state.dart';
import '../entity/entity.dart';
import '../processor/cancellation_token.dart';
import '../processor/message_processor.dart';
import '../processor/persistence_queue.dart';
import 'langchain_chat_adapter.dart';
import 'error_tool_chat_message.dart';
import 'session_memory_manager.dart';

/// 持久化回调函数类型
typedef PersistMessageFunc =
    Future<void> Function(Map<String, dynamic> message);
typedef PersistSessionFunc =
    Future<void> Function(Map<String, dynamic> session);
typedef LoadSessionFunc =
    Future<Map<String, dynamic>?> Function(String employeeId);
typedef LoadMessagesFunc =
    Future<List<Map<String, dynamic>>> Function(String employeeId);
typedef UpdateMessageStatusFunc =
    Future<void> Function(
      String messageId,
      AgentMessageStatus status, {
      String? error,
    });
typedef DeleteMessagesFunc = Future<void> Function(String employeeId);

/// 删除单条消息回调
typedef DeleteMessageFunc = Future<void> Function(String messageId);

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

  /// 删除消息回调
  DeleteMessagesFunc? deleteMessagesCallback;

  /// 删除单条消息回调
  DeleteMessageFunc? deleteMessageCallback;

  /// 已持久化的消息 ID 集合（避免重复持久化）
  final Set<String> _persistedMessageIds = {};

  /// 持久化队列（用于异步处理持久化任务，避免阻塞）
  final PersistenceQueue _persistenceQueue = PersistenceQueue();

  PersistentChatAdapter() {
    // 持久化最终失败时，通知上层（仅消息类型任务）
    _persistenceQueue.onTaskFailed = (task, error) {
      if (task.type == PersistenceTaskType.message && task.messageData != null) {
        final messageId = task.messageData!['id'] as String?;
        if (messageId != null && updateMessageStatusCallback != null) {
          updateMessageStatusCallback!(
            messageId,
            AgentMessageStatus.failed,
            error: '消息持久化失败: $error',
          );
        }
      }
    };
  }

  @override
  Future<void> initSession({required String employeeId}) async {
    await super.initSession(employeeId: employeeId);

    // 如果提供了会话UUID且存在加载回调，尝试从数据库加载
    if (loadSession != null) {
      final sessionData = await loadSession!(employeeId);
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

    // 从数据库加载消息历史到内存（如果有加载回调）
    if (loadMessages != null) {
      final session = memoryManager.getSession(employeeId);
      if (session != null) {
        try {
          final messagesData = await loadMessages!(employeeId);
          if (messagesData.isNotEmpty) {
            // 加载历史消息
            for (final msgData in messagesData) {
              final chatMessage = _mapToChatMessage(msgData);
              if (chatMessage != null) {
                // 获取设备ID，如果没有则使用默认设备
                final msgDeviceId = msgData['deviceId'] as String? ?? 'default';

                // ✅ 创建 MessageWrapper，使用数据库中的稳定 UUID
                // 注意：数据库中使用 'uuid' 字段，而不是 'id'
                final msgId = (msgData['uuid'] ?? msgData['id']) as String?;

                // 兼容 createTime 和 createdAt 两种字段名
                // 数据库实体 toMap() 使用 createTime，内存消息使用 createdAt
                dynamic msgCreateTimeValue =
                    msgData['createTime'] ?? msgData['createdAt'];
                DateTime msgCreatedAt;
                if (msgCreateTimeValue is String) {
                  msgCreatedAt = DateTime.parse(msgCreateTimeValue);
                } else if (msgCreateTimeValue is int) {
                  msgCreatedAt = DateTime.fromMillisecondsSinceEpoch(
                    msgCreateTimeValue,
                  );
                } else if (msgCreateTimeValue is DateTime) {
                  msgCreatedAt = msgCreateTimeValue;
                } else {
                  msgCreatedAt = DateTime.now();
                }

                if (msgId != null) {
                  // 构建 metadata：保留 toolName（工具结果消息需要）和 processingStatus
                  Map<String, dynamic>? wrapperMetadata;
                  final toolName = msgData['toolName'] as String?;
                  if (toolName != null) {
                    wrapperMetadata = {'toolName': toolName};
                  }
                  final processingStatus = msgData['processingStatus'] as String?;
                  if (processingStatus != null) {
                    wrapperMetadata = {
                      ...?wrapperMetadata,
                      'status': processingStatus,
                    };
                  }

                  final wrapper = MessageWrapper(
                    uuid: msgId,
                    message: chatMessage,
                    createdAt: msgCreatedAt,
                    metadata: wrapperMetadata,
                  );
                  session.addMessageWrapper(msgDeviceId, wrapper);

                  // 记录已持久化的消息 ID，避免重复持久化
                  _persistedMessageIds.add(msgId);
                }
              }
            }
            print(
              '[PersistentChatAdapter] initSession: 已从数据库加载 ${messagesData.length} 条历史消息',
            );
          }
        } catch (e) {
          print('[PersistentChatAdapter] initSession: 加载历史消息失败: $e');
        }
      }
    }

    // 持久化会话
    _notifyPersistSession();
  }

  @override
  Future<void> clearCurrentSession() async {
    await super.clearCurrentSession();

    // 删除 Hive 中的消息
    if (deleteMessagesCallback != null && currentSessionUuid != null) {
      try {
        await deleteMessagesCallback!(currentSessionUuid!);
        print('[PersistentChatAdapter] clearCurrentSession: 已删除 Hive 中的消息');
      } catch (e) {
        print('[PersistentChatAdapter] clearCurrentSession: 删除 Hive 消息失败: $e');
      }
    }

    // 清空已持久化消息 ID 集合
    _persistedMessageIds.clear();

    _notifyPersistSession();
  }

  @override
  Future<void> updateProvider(Map<String, dynamic> providerConfig) async {
    await super.updateProvider(providerConfig);
    // 模型配置变更后持久化会话
    _notifyPersistSession();
  }

  @override
  Future<void> updateProjectContext(
    Map<String, dynamic>? projectContext,
  ) async {
    await super.updateProjectContext(projectContext);
    _notifyPersistSession();
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
    final session = memoryManager.getSession(currentSessionUuid!);
    final messagesBefore = session?.messageCount ?? 0;

    try {
      await for (final response in super.streamMessage(
        messageData,
        cancellationToken: cancellationToken,
      )) {
        yield response;

        final messagesNow = session?.messageCount ?? 0;
        if (messagesNow > messagesBefore) {
          _persistNewMessages(session, messagesBefore);
        }
      }

      // 流完成后确保所有新消息都已持久化
      final messagesAfter = session?.messageCount ?? 0;
      if (messagesAfter > messagesBefore) {
        await _persistNewMessages(session, messagesBefore);
      }
    } catch (e) {
      print('[PersistentChatAdapter] streamMessage error: $e');
      rethrow;
    } finally {
      final messagesAfter = session?.messageCount ?? 0;
      if (messagesAfter > messagesBefore) {
        _persistNewMessages(session, messagesBefore);
      }
    }
  }

  @override
  Future<List<AgentMessage>> getSessionMessages(
    String employeeId,
  ) async {
    // 直接返回内存中的消息，不触发持久化
    return await super.getSessionMessages(employeeId);
  }

  /// 注入一条 assistant 消息到当前会话
  ///
  /// 不触发 LLM，直接写入 session 内存 + 持久化到 Hive。
  /// 用于定时任务、系统通知等场景。
  void injectAssistantMessage(String messageId, String content, String deviceIdentifier) {
    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session == null) return;

    final now = DateTime.now();
    final wrapper = MessageWrapper(
      uuid: messageId,
      message: ChatMessage.ai(content),
      createdAt: now,
      metadata: {'status': 'completed'},
    );
    session.addMessageWrapper(deviceIdentifier, wrapper);

    // 持久化到 Hive
    final messageMap = _messageWrapperToMap(wrapper);
    _persistedMessageIds.add(messageId);
    _persistMessage(messageMap);
  }

  /// 注入一条 system 消息到当前会话
  ///
  /// 不触发 LLM，直接写入 session 内存 + 持久化到 Hive。
  /// 用于定时任务触发等场景，将任务指令以 system 角色注入会话，
  /// 之后由 AgentImpl 触发一次 sendMessage 让 LLM 处理。
  void injectSystemMessage(String messageId, String content, String deviceIdentifier) {
    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session == null) return;

    final now = DateTime.now();
    final wrapper = MessageWrapper(
      uuid: messageId,
      message: ChatMessage.system(content),
      createdAt: now,
      metadata: {'status': 'completed', 'trigger': 'scheduled_task'},
    );
    session.addMessageWrapper(deviceIdentifier, wrapper);

    // 持久化到 Hive
    final messageMap = _messageWrapperToMap(wrapper);
    _persistedMessageIds.add(messageId);
    _persistMessage(messageMap);
  }

  /// 持久化新添加的消息
  Future<void> _persistNewMessages(
    SessionHistory? session,
    int messagesBefore,
  ) async {
    if (session == null) {
      print(
        '[PersistentChatAdapter] _persistNewMessages: session is null, skipping',
      );
      return;
    }

    final allMessages = session.allMessages;
    final messagesNow = allMessages.length;

    if (messagesNow <= messagesBefore) {
      return;
    }

    for (var i = messagesBefore; i < messagesNow; i++) {
      final wrapper = allMessages[i];
      final messageId = wrapper.uuid;

      if (_persistedMessageIds.contains(messageId)) {
        // 已持久化，跳过（静默处理，避免日志刷屏）
        continue;
      }

      final messageMap = _messageWrapperToMap(wrapper);
      _persistMessage(messageMap);
      _persistedMessageIds.add(messageId);
      print(
        '[PersistentChatAdapter] _persistNewMessages: persisted $messageId',
      );
    }
  }

  /// 持久化单条消息
  void _persistMessage(Map<String, dynamic> message) {
    if (persistMessage == null) return;

    // 添加 employeeId
    final messageWithSession = {...message, 'employeeId': currentSessionUuid};

    // 将持久化任务加入队列，不阻塞主流程
    _persistenceQueue.addMessageTask(messageWithSession, (data) async {
      try {
        await persistMessage!(data);
      } catch (e) {
        // 队列会自动处理重试
        print('[PersistentChatAdapter] _persistMessage: 持久化失败: $e');
        rethrow;
      }
    });
  }

  /// 通知持久化会话
  void _notifyPersistSession() {
    if (persistSession == null) return;

    final sessionData = _buildSessionData();

    // 将持久化任务加入队列，不阻塞主流程
    _persistenceQueue.addSessionTask(sessionData, (data) async {
      try {
        await persistSession!(data);
      } catch (e) {
        // 队列会自动处理重试
        print('[PersistentChatAdapter] _notifyPersistSession: 持久化失败: $e');
        rethrow;
      }
    });
  }

  /// 构建会话数据用于持久化
  Map<String, dynamic> _buildSessionData() {
    final employeeId = currentSessionUuid ?? '';
    final context = currentContext ?? {};

    return {
      'uuid': employeeId,
      'title': context['title'] ?? '新对话',
      'contextData': context['contextData'],
      'providerConfig': getProviderConfig(),
      'projectUuid': context['projectUuid'],
      'updateTime': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// 将 MessageWrapper 转换为 Map（用于持久化）
  Map<String, dynamic> _messageWrapperToMap(MessageWrapper wrapper) {
    final message = wrapper.message;

    // 获取消息类型
    final type = switch (message) {
      SystemChatMessage() => 'system',
      HumanChatMessage() => 'human',
      AIChatMessage() => 'ai',
      ToolChatMessage() => 'tool',
      CustomChatMessage() => 'custom',
    };

    // 获取内容
    final content = message.contentAsString;

    // ✅ 使用 MessageWrapper 的稳定 UUID
    // 🔑 同时设置 'uuid' 和 'id' 字段，确保数据库存储和查询一致
    final map = <String, dynamic>{
      'uuid': wrapper.uuid,
      'id': wrapper.uuid,
      'role': type == 'human'
          ? 'user'
          : type == 'ai'
          ? 'assistant'
          : type,
      'content': content,
      'createdAt': wrapper.createdAt.toIso8601String(),
    };

    // AI 消息附加 toolCalls 信息
    if (message is AIChatMessage && message.toolCalls.isNotEmpty) {
      // ✅ 序列化为 JSON 字符串，避免类型转换错误
      map['toolCalls'] = jsonEncode(message.toolCalls
          .map(
            (tc) => {'id': tc.id, 'name': tc.name, 'arguments': tc.arguments},
          )
          .toList());
    }

    // Tool 消息附加 toolCallId、toolName 和 type
    if (message is ToolChatMessage) {
      map['toolCallId'] = message.toolCallId;
      map['type'] = 'functionResult';
      // 从 metadata 中获取 toolName（工具执行时通过 metadata 传入）
      final toolName = wrapper.metadata?['toolName'] as String?;
      if (toolName != null) {
        map['toolName'] = toolName;
      }
      // ErrorToolChatMessage 的 isError 标记
      if (message is ErrorToolChatMessage && message.isError) {
        map['isError'] = true;
      }
    }

    return map;
  }

  /// 将数据库消息格式转换为 LangChain ChatMessage
  ChatMessage? _mapToChatMessage(Map<String, dynamic> map) {
    final role = map['role'] as String? ?? 'user';
    final content = map['content'] as String? ?? '';
    final type = map['type'] as String? ?? 'text';

    // 处理工具消息
    if (type == 'functionResult' || role == 'tool') {
      final toolCallId =
          map['toolCallId'] as String? ?? map['id'] as String? ?? '';
      final isError = map['isError'] == true;
      if (isError) {
        return ErrorToolChatMessage(toolCallId: toolCallId, content: content, isError: true);
      }
      return ToolChatMessage(toolCallId: toolCallId, content: content);
    }

    // 解析 toolCalls
    List<AIChatMessageToolCall>? parsedToolCalls;
    final toolCalls = map['toolCalls'];
    List<dynamic>? toolCallsList;

    // toolCalls 可能是 List（来自内存）或 String（来自 Hive JSON 字符串）
    if (toolCalls is List && toolCalls.isNotEmpty) {
      toolCallsList = toolCalls;
    } else if (toolCalls is String && toolCalls.isNotEmpty) {
      try {
        toolCallsList = jsonDecode(toolCalls) as List<dynamic>;
      } catch (e) {
        print('[PersistentChatAdapter] _mapToChatMessage: 解析 toolCalls 失败: $e');
      }
    }

    if (toolCallsList != null && toolCallsList.isNotEmpty) {
      parsedToolCalls = toolCallsList.map((tc) {
        final tcMap = tc as Map<String, dynamic>;

        // arguments 可能是 String（JSON字符串）或 Map（已解析）
        String argsStr = '{}';
        Map<String, dynamic> argsMap = {};

        final args = tcMap['arguments'];
        if (args is String && args.isNotEmpty) {
          argsStr = args;
          try {
            argsMap = jsonDecode(args) as Map<String, dynamic>? ?? {};
          } catch (_) {}
        } else if (args is Map) {
          argsMap = args as Map<String, dynamic>;
          argsStr = jsonEncode(args);
        }

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
      return AIChatMessage(content: content, toolCalls: parsedToolCalls);
    }

    // 根据角色创建消息
    switch (role) {
      case 'user':
        return ChatMessage.humanText(content);
      case 'assistant':
        if (parsedToolCalls != null && parsedToolCalls.isNotEmpty) {
          return AIChatMessage(content: content, toolCalls: parsedToolCalls);
        }
        return ChatMessage.ai(content);
      case 'system':
        return ChatMessage.system(content);
      default:
        // 默认作为用户消息
        return ChatMessage.humanText(content);
    }
  }

  @override
  Future<void> dispose() async {
    // 释放持久化队列
    await _persistenceQueue.dispose();
    // 调用父类 dispose
    await super.dispose();
  }
}
