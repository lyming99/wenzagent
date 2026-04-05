import 'dart:async';

import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/prompts.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../agent_state.dart';
import '../processor/cancellation_token.dart';
import '../processor/message_processor.dart';
import '../tool/agent_tool.dart';
import '../tool/permission_manager.dart';
import '../tool/tool_registry.dart';
import 'chat_model_factory.dart';
import 'context_compressor.dart';
import 'provider_config.dart';
import 'session_memory_manager.dart';

/// Tool calling 循环最大迭代次数
const int _maxToolCallIterations = 25;

/// 基于 LangChain 的聊天适配器实现
///
/// 使用 LangChain Dart 库实现 IChatAdapter 接口，
/// 支持 OpenAI 等多种 LLM 提供商。
/// 支持 LLM Function Calling (Tool Use)。
class LangChainChatAdapter implements IChatAdapter {
  final Uuid _uuid = const Uuid();

  /// ChatModel 实例
  BaseChatModel? _chatModel;

  /// 提供商配置
  ProviderConfig? _providerConfig;

  /// 会话记忆管理器（protected，供子类访问）
  @protected
  final SessionMemoryManager memoryManager = SessionMemoryManager();

  /// 当前员工 UUID（同时作为会话 ID）
  @protected
  String? currentEmployeeUuid;

  /// 当前设备 ID（用于区分不同设备的消息记录）
  @protected
  String? deviceId;

  /// 当前上下文
  Map<String, dynamic>? _context;

  /// 是否正在流式输出
  bool _isStreaming = false;

  /// 工具注册器
  ToolRegistry? _toolRegistry;

  /// 权限管理器
  ToolPermissionManager? _permissionManager;

  /// 工具事件回调
  void Function(Map<String, dynamic> event)? _toolEventCallback;

  /// 上下文压缩器
  ContextCompressor? _compressor;

  LangChainChatAdapter();

  // ===== IChatAdapter 属性实现 =====

  String? get currentSessionUuid => currentEmployeeUuid;

  @override
  List<Map<String, dynamic>> get currentMessages {
    if (currentEmployeeUuid == null) return [];

    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session == null) return [];

    return session.allMessages.map(_chatMessageToMap).toList();
  }

  @override
  Map<String, dynamic>? get currentContext => _context;

  @override
  bool get isStreaming => _isStreaming;

  // ===== IChatAdapter 方法实现 =====

  @override
  Future<void> initSession({
    required String employeeUuid,
    String? employeeId,
  }) async {
    currentEmployeeUuid = employeeUuid;
    memoryManager.getOrCreateSession(employeeUuid);
  }

  @override
  Stream<StreamResponse> streamMessage(
    Map<String, dynamic> messageData, {
    CancellationToken? cancellationToken,
  }) async* {
    print('[LangChainChatAdapter] streamMessage called');
    print('[LangChainChatAdapter] _chatModel: $_chatModel');
    print('[LangChainChatAdapter] _providerConfig: $_providerConfig');
    print('[LangChainChatAdapter] currentEmployeeUuid: $currentEmployeeUuid');

    if (_chatModel == null) {
      print('[LangChainChatAdapter] ERROR: _chatModel is null');
      yield StreamResponse.error('未配置 LLM Provider，请先调用 updateProvider()');
      return;
    }

    if (_isStreaming) {
      print('[LangChainChatAdapter] ERROR: already streaming');
      yield StreamResponse.error('正在处理中，请等待当前请求完成');
      return;
    }

    if (currentEmployeeUuid == null) {
      print('[LangChainChatAdapter] ERROR: currentEmployeeUuid is null');
      yield StreamResponse.error('未初始化会话，请先调用 initSession()');
      return;
    }

    _isStreaming = true;

    try {
      // 获取用户输入
      final userContent = messageData['content'] as String? ?? '';
      if (userContent.isEmpty) {
        yield StreamResponse.error('消息内容不能为空');
        return;
      }

      // 添加用户消息到历史
      final userMessage = ChatMessage.humanText(userContent);
      memoryManager.addMessage(
        currentEmployeeUuid!,
        deviceId ?? 'default',
        userMessage,
      );

      // 检查是否有可用工具
      final hasTools = _toolRegistry != null && !_toolRegistry!.isEmpty;

      // 准备上下文压缩（每轮用户消息调用一次）
      final systemPrompt = _buildSystemPrompt();
      if (_compressor != null) {
        final session = memoryManager.getSession(currentEmployeeUuid!);
        if (session != null) {
          await _compressor!.prepareCompression(
            employeeId: currentEmployeeUuid!,
            allMessages: session.allMessages,
            session: session,
            systemPrompt: systemPrompt,
          );
        }
      }

      // Tool calling 循环
      for (var iteration = 0; iteration < _maxToolCallIterations; iteration++) {
        // 检查取消
        if (cancellationToken?.isCancelled == true) {
          yield StreamResponse.error('Cancelled');
          return;
        }

        // 构建消息列表（启用压缩时使用压缩器）
        final List<ChatMessage> messages;
        if (_compressor != null) {
          final session = memoryManager.getSession(currentEmployeeUuid!);
          messages = _compressor!.buildCompressedMessages(
            employeeId: currentEmployeeUuid!,
            allMessages: session?.allMessages ?? [],
            systemPrompt: systemPrompt,
          );
        } else {
          messages = memoryManager.buildMessages(
            employeeUuid: currentEmployeeUuid!,
            systemPrompt: systemPrompt,
          );
        }

        // 构建调用选项（带工具定义）
        final options = hasTools
            ? ChatModelFactory.createToolOptions(
                _providerConfig!.provider,
                _toolRegistry!.toolSpecs,
              )
            : null;

        print('[LangChainChatAdapter] calling LLM, messages count: ${messages.length}, hasTools: $hasTools');

        // 调用 LLM 流式接口并累积完整响应
        ChatResult? accumulatedResult;
        final aiContentBuffer = StringBuffer();

        bool cancelled = false;
        cancellationToken?.onCancel.listen((_) {
          cancelled = true;
        });

        try {
          final stream = _chatModel!.stream(
            PromptValue.chat(messages),
            options: options,
          );

          await for (final result in stream) {
            if (cancelled || cancellationToken?.isCancelled == true) {
              yield StreamResponse.error('Cancelled');
              return;
            }

            // 累积完整结果（含 toolCalls 合并）
            accumulatedResult = accumulatedResult == null
                ? result
                : accumulatedResult.concat(result);

            // 流式输出文本 chunk
            final chunk = result.output.content;
            if (chunk.isNotEmpty) {
              aiContentBuffer.write(chunk);
              yield StreamResponse.chunk(chunk);
            }
          }
        } catch (e, st) {
          print('[LangChainChatAdapter] LLM stream error: $e');
          print('[LangChainChatAdapter] stack trace: $st');
          yield StreamResponse.error('LLM 调用异常: $e');
          return;
        }

        // 检查取消
        if (cancellationToken?.isCancelled == true) {
          yield StreamResponse.error('Cancelled');
          return;
        }

        if (accumulatedResult == null) {
          yield StreamResponse.error('LLM 未返回任何响应');
          return;
        }

        final aiMessage = accumulatedResult.output;
        final toolCalls = aiMessage.toolCalls;

        if (toolCalls.isEmpty || !hasTools) {
          // 没有工具调用 → 将 AI 文本加入历史，结束循环
          final aiContent = aiContentBuffer.toString();
          if (aiContent.isNotEmpty) {
            memoryManager.addMessage(
              currentEmployeeUuid!,
              deviceId ?? 'default',
              ChatMessage.ai(aiContent),
            );
          }
          break;
        }

        // 有工具调用 → 将 AI 消息（含 toolCalls）加入历史
        memoryManager.addMessage(
          currentEmployeeUuid!,
          deviceId ?? 'default',
          aiMessage,
        );

        // 逐个执行工具调用
        for (final toolCall in toolCalls) {
          // 检查取消
          if (cancellationToken?.isCancelled == true) {
            yield StreamResponse.error('Cancelled');
            return;
          }

          final toolName = toolCall.name;
          final toolCallId = toolCall.id;
          final toolArguments = toolCall.arguments;

          // 广播工具调用开始事件
          yield StreamResponse.toolCallStart(
            toolCallId: toolCallId,
            toolName: toolName,
            arguments: toolArguments,
          );
          _toolEventCallback?.call({
            'type': 'toolCallStart',
            'data': {
              'toolCallId': toolCallId,
              'toolName': toolName,
              'arguments': toolArguments,
            },
          });

          // 查找工具
          final tool = _toolRegistry!.getTool(toolName);
          if (tool == null) {
            // 工具未找到
            final errorResult = '工具 "$toolName" 未注册';
            memoryManager.addMessage(
              currentEmployeeUuid!,
              deviceId ?? 'default',
              ToolChatMessage(toolCallId: toolCallId, content: errorResult),
            );
            yield StreamResponse.toolCallResult(
              toolCallId: toolCallId,
              toolName: toolName,
              result: errorResult,
              isError: true,
            );
            continue;
          }

          // 权限检查
          if (_permissionManager != null && tool.requiresPermission) {
            final decision = await _permissionManager!.checkPermission(
              tool,
              toolArguments,
            );

            if (decision == PermissionDecision.deny) {
              final denyResult = '权限被拒绝: 用户拒绝了工具 "$toolName" 的执行';
              memoryManager.addMessage(
                currentEmployeeUuid!,
                deviceId ?? 'default',
                ToolChatMessage(toolCallId: toolCallId, content: denyResult),
              );
              yield StreamResponse.toolCallResult(
                toolCallId: toolCallId,
                toolName: toolName,
                result: denyResult,
                isError: true,
              );
              continue;
            }
          }

          // 执行工具
          final stopwatch = Stopwatch()..start();
          ToolResult result;
          try {
            result = await tool.execute(toolArguments);
          } catch (e) {
            result = ToolResult.error('工具执行异常: $e');
          }
          stopwatch.stop();

          // 将工具结果加入历史
          memoryManager.addMessage(
            currentEmployeeUuid!,
            deviceId ?? 'default',
            ToolChatMessage(toolCallId: toolCallId, content: result.content),
          );

          // 广播工具调用结果事件
          yield StreamResponse.toolCallResult(
            toolCallId: toolCallId,
            toolName: toolName,
            result: result.content,
            isError: result.isError,
            durationMs: stopwatch.elapsedMilliseconds,
          );
          _toolEventCallback?.call({
            'type': 'toolCallResult',
            'data': {
              'toolCallId': toolCallId,
              'toolName': toolName,
              'result': result.content,
              'isError': result.isError,
              'durationMs': stopwatch.elapsedMilliseconds,
            },
          });
        }

        // 所有工具执行完毕，继续循环让 LLM 处理结果
      }

      // 发送完成信号
      yield StreamResponse.done();
    } catch (e) {
      yield StreamResponse.error('LLM 请求失败: $e');
    } finally {
      _isStreaming = false;
    }
  }

  @override
  Future<void> stopStreaming() async {
    _isStreaming = false;
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String employeeId,
  ) async {
    // employeeId 实际上就是 employeeUuid
    final session = memoryManager.getSession(employeeId);
    if (session == null) return [];

    return session.allMessages.map(_chatMessageToMap).toList();
  }

  @override
  Future<void> clearCurrentSession() async {
    if (currentEmployeeUuid != null) {
      memoryManager.clearSession(currentEmployeeUuid!);
    }
  }

  @override
  void setContext(Map<String, dynamic> contextData) {
    _context = {...?_context, ...contextData};
  }

  @override
  void clearContext() {
    _context = null;
  }

  @override
  Future<void> updateProvider(Map<String, dynamic> providerConfig) async {
    print('[LangChainChatAdapter] updateProvider called with: $providerConfig');
    final config = ProviderConfig.fromMap(providerConfig);
    print('[LangChainChatAdapter] parsed config: provider=${config.provider}, model=${config.model}, baseUrl=${config.baseUrl}');
    config.validate();
    print('[LangChainChatAdapter] config validated successfully');

    _chatModel = ChatModelFactory.create(config);
    _providerConfig = config;
    print('[LangChainChatAdapter] _chatModel created: $_chatModel');

    // 配置上下文压缩器
    final compression = config.compressionConfig;
    if (compression != null && compression.enabled) {
      _compressor = ContextCompressor(
        config: compression,
        onSummarize: (prompt) async {
          final result = await _chatModel!.invoke(
            PromptValue.chat([ChatMessage.humanText(prompt)]),
          );
          return result.output.content;
        },
      );
    } else {
      _compressor?.dispose();
      _compressor = null;
    }
  }

  @override
  Map<String, dynamic>? getProviderConfig() {
    return _providerConfig?.toMap();
  }

  @override
  Future<void> updateProjectContext(
    Map<String, dynamic>? projectContext,
  ) async {
    if (projectContext != null) {
      _context = {...?_context, ...projectContext};
    }
  }

  @override
  void setToolRegistry(ToolRegistry? registry) {
    _toolRegistry = registry;
  }

  @override
  void setPermissionManager(ToolPermissionManager? manager) {
    _permissionManager = manager;
  }

  @override
  void setToolEventCallback(
    void Function(Map<String, dynamic> event)? callback,
  ) {
    _toolEventCallback = callback;
  }

  @override
  void updateMessageStatus(
    String messageId,
    AgentMessageStatus status, {
    String? error,
  }) {
    // 内存适配器不需要持久化，子类 PersistentChatAdapter 可重写此方法
  }

  @override
  Future<void> dispose() async {
    await stopStreaming();
    memoryManager.dispose();
    _compressor?.dispose();
    _compressor = null;
    _chatModel = null;
    _providerConfig = null;
    _context = null;
    currentEmployeeUuid = null;
    _toolRegistry = null;
    _permissionManager = null;
    _toolEventCallback = null;
  }

  // ===== 内部方法 =====

  /// 构建系统提示词
  String? _buildSystemPrompt() {
    if (_context == null) return null;

    final parts = <String>[];

    final systemPrompt = _context!['systemPrompt'] as String?;
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      parts.add(systemPrompt);
    }

    final projectContext = _context!['projectContext'];
    if (projectContext != null) {
      parts.add('项目上下文:\n$projectContext');
    }

    final additionalInfo = _context!['additionalInfo'];
    if (additionalInfo != null) {
      parts.add('补充信息:\n$additionalInfo');
    }

    return parts.isEmpty ? null : parts.join('\n\n');
  }

  /// ChatMessage 转换为 Map
  Map<String, dynamic> _chatMessageToMap(ChatMessage message) {
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

    final map = <String, dynamic>{
      'id': 'msg-${_uuid.v4().substring(0, 8)}',
      'role': type == 'human'
          ? 'user'
          : type == 'ai'
          ? 'assistant'
          : type,
      'content': content,
      'createdAt': DateTime.now().toIso8601String(),
    };

    // AI 消息附加 toolCalls 信息
    if (message is AIChatMessage && message.toolCalls.isNotEmpty) {
      map['toolCalls'] = message.toolCalls
          .map(
            (tc) => {'id': tc.id, 'name': tc.name, 'arguments': tc.arguments},
          )
          .toList();
    }

    // Tool 消息附加 toolCallId
    if (message is ToolChatMessage) {
      map['toolCallId'] = message.toolCallId;
    }

    return map;
  }
}
