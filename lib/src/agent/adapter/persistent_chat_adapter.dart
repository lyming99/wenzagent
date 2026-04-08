import 'dart:async';
import 'dart:convert';

import 'package:langchain_core/chat_models.dart';

import '../agent_state.dart';
import '../entity/entity.dart';
import '../processor/cancellation_token.dart';
import '../processor/message_processor.dart';
import '../processor/persistence_queue.dart';
import 'langchain_chat_adapter.dart';
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
                  // 使用 MessageWrapper 创建方法，传入稳定的 UUID
                  // 获取 processingStatus 作为 status
                  final processingStatus = msgData['processingStatus'] as String?;
                  
                  final wrapper = MessageWrapper(
                    uuid: msgId,
                    message: chatMessage,
                    createdAt: msgCreatedAt,
                    metadata: processingStatus != null 
                        ? {'status': processingStatus} 
                        : null,
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
    print(
      '[PersistentChatAdapter] streamMessage called: ${messageData['content']?.toString().substring(0, (messageData['content']?.toString().length ?? 0).clamp(0, 50))}',
    );
    print('[PersistentChatAdapter] currentSessionUuid: $currentSessionUuid');
    print('[PersistentChatAdapter] providerConfig: ${getProviderConfig()}');

    // ✅ 直接从 SessionHistory 获取消息数量，避免触发 ID 重新生成
    final session = memoryManager.getSession(currentSessionUuid!);
    final messagesBefore = session?.messageCount ?? 0;
    print('[PersistentChatAdapter] messages before: $messagesBefore');

    try {
      // 调用父类的流式消息方法
      await for (final response in super.streamMessage(
        messageData,
        cancellationToken: cancellationToken,
      )) {
        print(
          '[PersistentChatAdapter] response: ${response.isDone
              ? "DONE"
              : response.error != null
              ? "ERROR: ${response.error}"
              : "CHUNK: ${response.content?.substring(0, (response.content?.length ?? 0).clamp(0, 30))}"}',
        );
        yield response;

        // ✅ 直接从 SessionHistory 获取消息数量
        final messagesNow = session?.messageCount ?? 0;
        if (messagesNow > messagesBefore) {
          print(
            '[PersistentChatAdapter] persisting new messages immediately, before: $messagesBefore, now: $messagesNow',
          );
          _persistNewMessages(session, messagesBefore);
        }
      }

      // 流完成后再次检查是否有新消息
      final messagesAfter = session?.messageCount ?? 0;
      if (messagesAfter > messagesBefore) {
        print(
          '[PersistentChatAdapter] stream completed, persisting any remaining messages',
        );
        await _persistNewMessages(session, messagesBefore);
      }
    } catch (e) {
      print('[PersistentChatAdapter] error in streamMessage: $e');
      rethrow;
    } finally {
      // 确保无论流如何结束，都持久化新增的消息
      // 这处理了父类在异常情况下提前 return 的情况
      final messagesAfter = session?.messageCount ?? 0;
      if (messagesAfter > messagesBefore) {
        print(
          '[PersistentChatAdapter] finally block: persisting ${messagesAfter - messagesBefore} new messages',
        );
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

    print(
      '[PersistentChatAdapter] _persistNewMessages: before=$messagesBefore, after=$messagesNow',
    );

    if (messagesNow <= messagesBefore) {
      print(
        '[PersistentChatAdapter] _persistNewMessages: no new messages, skipping',
      );
      return;
    }

    // ✅ 只持久化新增的消息，直接使用 MessageWrapper
    print(
      '[PersistentChatAdapter] _persistNewMessages: persisting ${messagesNow - messagesBefore} new messages',
    );
    for (var i = messagesBefore; i < messagesNow; i++) {
      final wrapper = allMessages[i];
      // ✅ 使用 MessageWrapper 的稳定 UUID
      final messageId = wrapper.uuid;

      if (!_persistedMessageIds.contains(messageId)) {
        print(
          '[PersistentChatAdapter] _persistNewMessages: persisting message $messageId',
        );
        // ✅ 直接持久化 MessageWrapper，使用 _messageWrapperToMap
        final messageMap = _messageWrapperToMap(wrapper);
        // 不等待持久化完成，将任务加入队列
        _persistMessage(messageMap);
        _persistedMessageIds.add(messageId);
      } else {
        print(
          '[PersistentChatAdapter] _persistNewMessages: message $messageId already persisted, skipping',
        );
      }
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

    // Tool 消息附加 toolCallId
    if (message is ToolChatMessage) {
      map['toolCallId'] = message.toolCallId;
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
