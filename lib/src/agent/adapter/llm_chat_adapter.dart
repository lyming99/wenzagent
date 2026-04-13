import 'dart:async';
import 'dart:convert';

import 'package:llm_dart/llm_dart.dart' as llm;
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../agent_state.dart';
import '../entity/entity.dart';
import '../processor/cancellation_token.dart';
import '../processor/message_processor.dart';
import '../tool/agent_tool.dart';
import '../tool/cancellable_tool_executor.dart';
import '../tool/permission_manager.dart';
import '../tool/tool_registry.dart';
import '../../shared/shared.dart' as shared;
import 'context_compressor.dart';
import 'session_memory_manager.dart';

/// Tool calling 循环最大迭代次数
const int _maxToolCallIterations = 100;

class _NotReplyRecord {
  int notReplyCount = 0;
  int maxNotReplyCount = 3;

  _NotReplyRecord({this.maxNotReplyCount = 3});

  bool tooLongNotReply() {
    notReplyCount++;
    return notReplyCount >= maxNotReplyCount;
  }

  void reset() {
    notReplyCount = 0;
  }
}

/// 并行工具执行结果（内部使用）
class _ToolExecResult {
  final llm.ToolCall toolCall;
  final String toolName;
  final ToolResult result;
  final int durationMs;
  final bool wasCancelled;

  const _ToolExecResult({
    required this.toolCall,
    required this.toolName,
    required this.result,
    required this.durationMs,
    this.wasCancelled = false,
  });
}

/// LLM 流式调用结果（内部使用）
class _LlmStreamResult {
  final StringBuffer aiContentBuffer;
  final StringBuffer aiThinkingBuffer;
  final List<llm.ToolCall> toolCalls;
  final bool cancelled;
  final String? error;
  final bool isDone;

  _LlmStreamResult({
    required this.aiContentBuffer,
    required this.aiThinkingBuffer,
    required this.toolCalls,
    required this.isDone,
    this.cancelled = false,
    this.error,
  });

  factory _LlmStreamResult.cancelled() => _LlmStreamResult(
    aiContentBuffer: StringBuffer(),
    aiThinkingBuffer: StringBuffer(),
    isDone: true,
    toolCalls: const [],
    cancelled: true,
  );

  factory _LlmStreamResult.error(String msg) => _LlmStreamResult(
    aiContentBuffer: StringBuffer(),
    aiThinkingBuffer: StringBuffer(),
    isDone: true,
    toolCalls: const [],
    error: msg,
  );
}

/// 重复工具调用检测结果（内部使用）
class _DuplicateCheckResult {
  final String updatedSignature;
  final int updatedCount;
  final bool isDeadLoop;

  const _DuplicateCheckResult({
    required this.updatedSignature,
    required this.updatedCount,
    required this.isDeadLoop,
  });
}

/// 工具执行汇总结果（内部使用）
class _ToolExecSummary {
  final bool cancelled;
  final List<shared.ToolResult> results;

  const _ToolExecSummary({required this.cancelled, required this.results});
}

/// 基于 llm_dart 的聊天适配器实现
///
/// 使用 llm_dart 库实现 IChatAdapter 接口，
/// 支持 OpenAI、Anthropic、Google AI、Ollama 等多种 LLM 提供商。
class LlmChatAdapter implements IChatAdapter {
  /// llm_dart ChatCapability 实例
  llm.ChatCapability? _chatCapability;

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
  void Function(ToolEvent event)? _toolEventCallback;

  /// 当前正在并行执行的工具列表（用于取消）
  final List<AgentTool> _runningTools = [];

  /// 上下文压缩器
  ContextCompressor? _compressor;

  /// dio CancelToken（用于取消 LLM 流式请求）
  llm.CancelToken? _dioCancelToken;

  LlmChatAdapter();

  // ===== IChatAdapter 属性实现 =====

  String? get currentSessionUuid => currentEmployeeUuid;

  @override
  List<Map<String, dynamic>> get currentMessages {
    if (currentEmployeeUuid == null) return [];

    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session == null) return [];

    return session.allMessages.map((m) => m.toJson()).toList();
  }

  @override
  Map<String, dynamic>? get currentContext => _context;

  @override
  bool get isStreaming => _isStreaming;

  // ===== IChatAdapter 方法实现 =====

  @override
  Future<void> initSession({
    required String employeeId,
    int? recentLimit,
  }) async {
    currentEmployeeUuid = employeeId;
    memoryManager.getOrCreateSession(employeeId);
  }

  @override
  Future<void> loadRemainingMessages() async {
    // 基类无持久化，无需加载
  }

  @override
  Stream<StreamResponse> streamMessage(
    MessageInput message, {
    CancellationToken? cancellationToken,
  }) {
    final controller = StreamController<StreamResponse>();
    print('[LlmChatAdapter] stream start, model: ${_providerConfig?.model}');
    () async {
      // 前置校验
      final error = _validateStreamReady();
      if (error != null) {
        controller.add(StreamResponse.error(error));
        await controller.close();
        return;
      }

      if (message.content.isEmpty) {
        controller.add(StreamResponse.error('消息内容不能为空'));
        await controller.close();
        return;
      }

      _isStreaming = true;
      _dioCancelToken = llm.CancelToken();
      StreamSubscription? cancelSubscription;

      try {
        // 添加用户消息到历史
        _addUserMessage(message);

        final hasTools = _toolRegistry != null && !_toolRegistry!.isEmpty;
        final systemPrompt = _buildSystemPrompt();
        await _prepareCompression(systemPrompt);

        // Tool calling 循环
        bool streamCancelled = false;
        cancelSubscription = cancellationToken?.onCancel.listen((_) {
          streamCancelled = true;
          _dioCancelToken?.cancel('User cancelled');
        });

        // 重复工具调用检测状态
        String? lastToolCallsSignature;
        int consecutiveDuplicateCount = 0;
        var notReplyRecord = _NotReplyRecord(maxNotReplyCount: 5);
        var alreadyCallsSet = <String>{};
        for (
          var iteration = 0;
          iteration < _maxToolCallIterations;
          iteration++
        ) {
          if (cancellationToken?.isCancelled == true) {
            controller.add(StreamResponse.error('Cancelled'));
            return;
          }

          // 调用 LLM 流式接口，通过 onChunk 实时推送文本
          final llmResult = await _callLlmStream(
            systemPrompt: systemPrompt,
            hasTools: hasTools,
            streamCancelled: streamCancelled,
            cancellationToken: cancellationToken,
            onChunk: (chunk) => controller.add(StreamResponse.chunk(chunk)),
          );

          if (llmResult.cancelled) {
            controller.add(StreamResponse.error('Cancelled'));
            return;
          }
          if (llmResult.error != null) {
            controller.add(StreamResponse.error(llmResult.error!));
            return;
          }

          // 没有工具调用 → 记录 AI 文本，结束循环
          if (llmResult.toolCalls.isEmpty || !hasTools) {
            final aiContent = llmResult.aiContentBuffer.toString();
            if (aiContent.isNotEmpty) {
              memoryManager.addMessage(
                currentEmployeeUuid!,
                deviceId ?? 'default',
                shared.ChatMessage.assistant(
                  id: const Uuid().v4(),
                  employeeId: currentEmployeeUuid!,
                  content: aiContent,
                ),
              );
            }
            print('[LlmChatAdapter] tool use empty, stop tool calling loop');
            if (llmResult.isDone) {
              print(
                '[LlmChatAdapter] ai call tool done: ${llmResult.aiContentBuffer.toString()}',
              );
              break;
            } else {
              if (notReplyRecord.tooLongNotReply()) {
                print('[LlmChatAdapter] ai not reply, too long no reply:${notReplyRecord.notReplyCount}');
                break;
              }
              print('[LlmChatAdapter] ai not reply, wait for ai reply');
              await Future.delayed(Duration(seconds: 3));
              continue;
            }
          }
          notReplyRecord.reset();
          // 有工具调用 → 记录 AI 消息（含 toolCalls）到历史
          _recordAssistantToolCallMessage(
            llmResult.aiContentBuffer.toString(),
            llmResult.toolCalls,
          );

          // 重复工具调用检测
          final duplicateError = _checkDuplicateToolCalls(
            llmResult.toolCalls,
            lastToolCallsSignature,
            consecutiveDuplicateCount,
          );
          if (duplicateError != null) {
            lastToolCallsSignature = duplicateError.updatedSignature;
            consecutiveDuplicateCount = duplicateError.updatedCount;

            if (duplicateError.isDeadLoop) {
              controller.add(
                StreamResponse.error(
                  '检测到工具调用死循环：LLM 连续 $duplicateError.updatedCount 轮发出相同的工具调用。'
                  '请尝试修改您的需求或手动提供相关信息。',
                ),
              );
              return;
            }
          } else {
            lastToolCallsSignature = null;
            consecutiveDuplicateCount = 0;
          }

          // 权限检查 + 并行执行工具
          final execResult = await _executeToolCalls(
            llmResult.toolCalls,
            alreadyCallsSet: alreadyCallsSet,
            streamCancelled: streamCancelled,
            cancellationToken: cancellationToken,
          );

          if (execResult.cancelled) {
            controller.add(StreamResponse.error('Cancelled'));
            return;
          }

          // 推送工具调用结果事件 + 错误提示
          for (final r in execResult.results) {
            controller.add(
              StreamResponse.toolCallResult(
                toolCallId: r.toolCallId,
                toolName: r.name ?? '',
                result: r.content,
                isError: r.isError,
              ),
            );
            _toolEventCallback?.call(
              ToolCallResultEvent(
                toolCallId: r.toolCallId,
                toolName: r.name ?? '',
                result: r.content,
                isError: r.isError,
              ),
            );
            if (r.isError) {
              controller.add(
                StreamResponse.chunk(
                  '\n⚠️ 工具 ${r.name} 执行失败: ${r.content.split('\n').first}',
                ),
              );
            }
          }
          if (iteration == _maxToolCallIterations - 1) {
            controller.add(
              StreamResponse.error(
                '已达到最大工具调用轮次（$_maxToolCallIterations 次），请尝试简化您的需求或拆分为多个问题',
              ),
            );
            print(
              '[LlmChatAdapter] ERROR: 已达到最大工具调用轮次（$_maxToolCallIterations 次），请尝试简化您的需求或拆分为多个问题',
            );
            return;
          }
        }

        controller.add(StreamResponse.done());
        print('[LlmChatAdapter] done');
      } catch (e) {
        controller.add(StreamResponse.error('LLM 请求失败: $e'));

        print('[LlmChatAdapter] ERROR: $e');
      } finally {
        cancelSubscription?.cancel();
        _isStreaming = false;
        _dioCancelToken = null;
        _runningTools.clear();
        await controller.close();
      }
    }();

    return controller.stream;
  }

  @override
  Future<void> stopStreaming() async {
    _isStreaming = false;
    _dioCancelToken?.cancel('User stopped streaming');
    _dioCancelToken = null;

    // 取消正在执行的工具
    for (final tool in _runningTools) {
      tool.cancel();
    }
    _runningTools.clear();
  }

  @override
  Future<List<AgentMessage>> getSessionMessages(String employeeId) async {
    final session = memoryManager.getSession(employeeId);
    if (session == null) return [];

    final messages = session.allMessages.map((m) => m.toJson()).toList();
    return messages.map((m) => AgentMessage.fromMap(m)).toList();
  }

  @override
  Future<void> clearCurrentSession() async {
    if (currentEmployeeUuid != null) {
      memoryManager.clearSession(currentEmployeeUuid!);
      _compressor?.clearCache(currentEmployeeUuid!);
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
  bool removeMessageFromMemory(String messageId) {
    if (currentEmployeeUuid == null) {
      print(
        '[LlmChatAdapter] removeMessageFromMemory: currentEmployeeUuid is null',
      );
      return false;
    }

    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session == null) {
      print('[LlmChatAdapter] removeMessageFromMemory: session not found');
      return false;
    }

    return session.removeMessage(messageId);
  }

  @override
  Future<void> updateProvider(Map<String, dynamic> providerConfig) async {
    final config = ProviderConfig.fromMap(providerConfig);
    print(
      '[LlmChatAdapter] parsed config: provider=${config.provider}, model=${config.model}, baseUrl=${config.baseUrl}',
    );
    config.validate();
    print('[LlmChatAdapter] config validated successfully');

    _chatCapability = await _buildChatCapability(config);
    _providerConfig = config;
    print('[LlmChatAdapter] _chatCapability created: $_chatCapability');

    // 配置上下文压缩器
    final compression = config.compressionConfig;
    if (compression != null && compression.enabled) {
      _compressor = ContextCompressor(
        config: compression,
        onSummarize: (prompt) async {
          final messages = [llm.ChatMessage.user(prompt)];
          final response = await _chatCapability!.chat(messages);
          return response.text ?? '';
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
  void setToolEventCallback(void Function(ToolEvent event)? callback) {
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
  Future<String> invokeOnce(String prompt) async {
    if (_chatCapability == null) {
      throw Exception('未配置 LLM Provider');
    }
    final messages = [llm.ChatMessage.user(prompt)];
    final response = await _chatCapability!.chat(messages);
    return response.text ?? '';
  }

  @override
  Future<void> dispose() async {
    await stopStreaming();
    memoryManager.dispose();
    _compressor?.dispose();
    _compressor = null;
    _chatCapability = null;
    _providerConfig = null;
    _context = null;
    currentEmployeeUuid = null;
    _toolRegistry = null;
    _permissionManager = null;
    _toolEventCallback = null;
  }

  // ===== streamMessage 子方法 =====

  /// 前置校验，返回 null 表示通过，否则返回错误信息
  String? _validateStreamReady() {
    if (_chatCapability == null) {
      print('[LlmChatAdapter] ERROR: _chatCapability is null');
      return '未配置 LLM Provider，请先调用 updateProvider()';
    }
    if (_isStreaming) {
      print('[LlmChatAdapter] ERROR: already streaming');
      return '正在处理中，请等待当前请求完成';
    }
    if (currentEmployeeUuid == null) {
      print('[LlmChatAdapter] ERROR: currentEmployeeUuid is null');
      return '未初始化会话，请先调用 initSession()';
    }
    return null;
  }

  /// 添加用户消息到会话历史
  void _addUserMessage(MessageInput message) {
    final id = message.id ?? const Uuid().v4();
    final userMessage = shared.ChatMessage.user(
      id: id,
      employeeId: currentEmployeeUuid!,
      content: message.content,
    );
    memoryManager.addMessage(
      currentEmployeeUuid!,
      deviceId ?? 'default',
      userMessage,
    );
  }

  /// 准备上下文压缩
  Future<void> _prepareCompression(String? systemPrompt) async {
    if (_compressor == null) return;
    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session == null) return;
    final allMsgs = session.allMessages;
    await _compressor!.prepareCompression(
      employeeId: currentEmployeeUuid!,
      allMessages: allMsgs,
      session: session,
      systemPrompt: systemPrompt,
    );
  }

  /// LLM 流式调用，返回 AI 文本、工具调用列表等
  ///
  /// 通过 [onChunk] 回调逐块推送文本给调用方。
  Future<_LlmStreamResult> _callLlmStream({
    required String? systemPrompt,
    required bool hasTools,
    required bool streamCancelled,
    CancellationToken? cancellationToken,
    void Function(String chunk)? onChunk,
  }) async {
    // 构建消息列表
    final List<shared.ChatMessage> chatMsgs;
    if (_compressor != null) {
      final session = memoryManager.getSession(currentEmployeeUuid!);
      final allMsgs = session?.allMessages ?? [];
      chatMsgs = _compressor!.buildCompressedMessages(
        employeeId: currentEmployeeUuid!,
        allMessages: allMsgs,
        systemPrompt: systemPrompt,
      );
    } else {
      chatMsgs = memoryManager.buildMessages(
        employeeId: currentEmployeeUuid!,
        systemPrompt: systemPrompt,
      );
    }

    final llmMessages = shared.LlmMessageMapper.toLlmDartList(chatMsgs);

    // 构建工具列表
    final List<llm.Tool>? llmTools;
    if (hasTools && _toolRegistry != null && _providerConfig != null) {
      llmTools = _toolRegistry!.getLlmDartTools(_providerConfig!.provider);
    } else {
      llmTools = null;
    }
    if (hasTools) {
      print('[LlmChatAdapter] 已注册工具列表 (${_toolRegistry!.length} 个):');
    }
    print(
      '[LlmChatAdapter] calling LLM, messages count: ${llmMessages.length}, hasTools: $hasTools',
    );

    final aiContentBuffer = StringBuffer();
    final thinkingContentBuffer = StringBuffer();
    final toolCallAggregator = llm.ToolCallAggregator();
    llm.ChatResponse? finalResponse;

    try {
      final stream = _chatCapability!.chatStream(
        llmMessages,
        tools: llmTools,
        cancelToken: _dioCancelToken,
      );

      await for (final event in stream) {
        if (streamCancelled || cancellationToken?.isCancelled == true) {
          return _LlmStreamResult.cancelled();
        }
        switch (event) {
          case llm.TextDeltaEvent():
            final chunk = event.delta;
            if (chunk.isNotEmpty) {
              aiContentBuffer.write(chunk);
              onChunk?.call(chunk);
            }
            break;
          case llm.ToolCallDeltaEvent():
            toolCallAggregator.addDelta(event.toolCall);
            break;
          case llm.ThinkingDeltaEvent():
            if (event.delta.isNotEmpty) {
              thinkingContentBuffer.write(event.delta);
            }
            break;
          case llm.CompletionEvent():
            finalResponse = event.response;
            print('[LlmChatAdapter] finalResponse:${finalResponse.text},${finalResponse.usage.toString()},${finalResponse.toolCalls}');
            break;
          case llm.ErrorEvent():
            print('[LlmChatAdapter] LLM stream error event: ${event.error}');
            return _LlmStreamResult.error('LLM 调用异常: ${event.error.message}');
        }
      }
    } catch (e) {
      print('[LlmChatAdapter] LLM stream error: $e');
      return _LlmStreamResult.error('LLM 调用异常: $e');
    }

    if (cancellationToken?.isCancelled == true) {
      return _LlmStreamResult.cancelled();
    }

    var aToolCalls = toolCallAggregator.completedCalls;
    var toolCalls = finalResponse?.toolCalls ?? <llm.ToolCall>[];
    if (toolCalls.isEmpty) {
      toolCalls = aToolCalls;
    }
    return _LlmStreamResult(
      aiContentBuffer: aiContentBuffer,
      aiThinkingBuffer: thinkingContentBuffer,
      isDone: aiContentBuffer.toString().trim().isNotEmpty,
      toolCalls: toolCalls,
    );
  }

  /// 记录 assistant 消息（含 toolCalls）到会话历史
  void _recordAssistantToolCallMessage(
    String aiContent,
    List<llm.ToolCall> toolCalls,
  ) {
    final chatToolCalls = toolCalls
        .map((tc) => shared.ToolCall(
              id: tc.id,
              name: tc.function.name,
              arguments: _parseArguments(tc.function.arguments),
            ))
        .toList();
    memoryManager.addMessage(
      currentEmployeeUuid!,
      deviceId ?? 'default',
      shared.ChatMessage.assistant(
        id: const Uuid().v4(),
        employeeId: currentEmployeeUuid!,
        content: aiContent,
        toolCalls: chatToolCalls,
      ),
    );
  }

  /// 重复工具调用检测
  ///
  /// 返回 null 表示无重复；返回非 null 表示检测到重复，包含更新后的签名和计数。
  _DuplicateCheckResult? _checkDuplicateToolCalls(
    List<llm.ToolCall> toolCalls,
    String? lastSignature,
    int currentCount,
  ) {
    const maxConsecutiveDuplicateRounds = 3;

    final currentSignature = toolCalls
        .map((tc) => '${tc.function.name}:${tc.function.arguments}')
        .join('|');

    if (currentSignature == lastSignature) {
      final newCount = currentCount + 1;
      print('[LlmChatAdapter] 检测到重复工具调用 (第 $newCount 次): $currentSignature');
      return _DuplicateCheckResult(
        updatedSignature: currentSignature,
        updatedCount: newCount,
        isDeadLoop: newCount >= maxConsecutiveDuplicateRounds,
      );
    }

    return null;
  }

  /// 工具权限检查 + 并行执行
  ///
  /// 返回执行结果列表。如果被取消，[cancelled] 为 true。
  Future<_ToolExecSummary> _executeToolCalls(
    List<llm.ToolCall> toolCalls, {
    required Set<String> alreadyCallsSet,
    required bool streamCancelled,
    CancellationToken? cancellationToken,
  }) async {
    // Phase 1: 权限检查（串行）+ 收集待执行工具
    final pendingExecutions =
        <({llm.ToolCall call, AgentTool tool, Map<String, dynamic> args})>[];
    final allToolResults = <shared.ToolResult>[];

    for (final toolCall in toolCalls) {
      if (streamCancelled || cancellationToken?.isCancelled == true) {
        return _ToolExecSummary(cancelled: true, results: []);
      }
      if(alreadyCallsSet.contains(toolCall.id)){
        continue;
      }
      alreadyCallsSet.add(toolCall.id);

      final toolName = toolCall.function.name;
      final toolCallId = toolCall.id;
      Map<String, dynamic> toolArguments;
      try {
        toolArguments =
            jsonDecode(toolCall.function.arguments) as Map<String, dynamic>;
      } catch (_) {
        toolArguments = {};
      }

      // 广播工具调用开始事件
      _toolEventCallback?.call(
        ToolCallStartEvent(
          toolCallId: toolCallId,
          toolName: toolName,
          arguments: toolArguments,
        ),
      );

      // 查找工具
      final tool = _toolRegistry!.getTool(toolName);
      if (tool == null) {
        final errorResult = '工具 "$toolName" 未注册';
        allToolResults.add(
          shared.ToolResult(
            toolCallId: toolCallId,
            content: errorResult,
            isError: true,
            name: toolName,
          ),
        );
        _toolEventCallback?.call(
          ToolCallResultEvent(
            toolCallId: toolCallId,
            toolName: toolName,
            result: errorResult,
            isError: true,
          ),
        );
        continue;
      }

      // 权限检查（串行，因为可能需要等待用户交互）
      if (_permissionManager != null && tool.requiresPermission) {
        final decision = await _permissionManager!.checkPermission(
          tool,
          toolArguments,
        );
        if (decision == PermissionDecision.deny) {
          final denyResult =
              _permissionManager!.lastDenyMessage ??
              '权限被拒绝: 用户拒绝了工具 "$toolName" 的执行';
          allToolResults.add(
            shared.ToolResult(
              toolCallId: toolCallId,
              content: denyResult,
              isError: true,
              name: toolName,
            ),
          );
          _toolEventCallback?.call(
            ToolCallResultEvent(
              toolCallId: toolCallId,
              toolName: toolName,
              result: denyResult,
              isError: true,
            ),
          );
          continue;
        }
      }

      pendingExecutions.add((call: toolCall, tool: tool, args: toolArguments));
    }

    if (pendingExecutions.isEmpty) {
      _persistToolResults(allToolResults);
      return _ToolExecSummary(cancelled: false, results: []);
    }

    // Phase 2: 并行执行已批准的工具
    _runningTools.addAll(pendingExecutions.map((e) => e.tool));

    final results = await Future.wait(
      pendingExecutions.map(
        (exec) => _executeSingleTool(exec, cancellationToken),
      ),
    );

    _runningTools.clear();

    // 如果因取消导致所有工具被终止，直接退出
    if (results.any((r) => r.wasCancelled) &&
        (streamCancelled || cancellationToken?.isCancelled == true)) {
      for (final r in results) {
        if (r.wasCancelled) {
          allToolResults.add(
            shared.ToolResult(
              toolCallId: r.toolCall.id,
              content: r.result.content,
              isError: true,
              name: r.toolName,
            ),
          );
        }
      }
      _persistToolResults(allToolResults);
      return _ToolExecSummary(cancelled: true, results: []);
    }

    // 收集执行结果
    for (final r in results) {
      allToolResults.add(
        shared.ToolResult(
          toolCallId: r.toolCall.id,
          content: r.result.content,
          isError: r.result.isError,
          name: r.toolName,
        ),
      );
    }

    _persistToolResults(allToolResults);

    return _ToolExecSummary(cancelled: false, results: allToolResults);
  }

  /// 执行单个工具调用
  Future<_ToolExecResult> _executeSingleTool(
    ({llm.ToolCall call, AgentTool tool, Map<String, dynamic> args}) exec,
    CancellationToken? cancellationToken,
  ) async {
    final stopwatch = Stopwatch()..start();
    final toolName = exec.tool.name;
    ToolResult result;
    bool wasCancelled = false;
    try {
      final token = cancellationToken ?? CancellationToken();
      final executor = CancellableToolExecutor(exec.tool, token);
      result = await executor.execute(exec.args);
    } on ToolCancelledException {
      result = ToolResult.error('工具调用已取消: $toolName');
      wasCancelled = true;
    } catch (e) {
      result = ToolResult.error('工具执行异常: $e');
    } finally {
      stopwatch.stop();
    }
    final resultPreview = result.content.length > 100
        ? '${result.content.substring(0, 100)}...(truncated, total ${result.content.length} chars)'
        : result.content;
    print(
      '[LlmChatAdapter] 工具执行完成: $toolName, isError=${result.isError}, '
      'duration=${stopwatch.elapsedMilliseconds}ms, result=$resultPreview',
    );
    return _ToolExecResult(
      toolCall: exec.call,
      toolName: toolName,
      result: result,
      durationMs: stopwatch.elapsedMilliseconds,
      wasCancelled: wasCancelled,
    );
  }

  /// 将工具结果合并写入会话历史
  void _persistToolResults(List<shared.ToolResult> results) {
    if (results.isEmpty) return;
    final msg = shared.ChatMessage.toolResultGroup(
      id: const Uuid().v4(),
      employeeId: currentEmployeeUuid!,
      results: results,
    ).copyWith(metadata: {'toolNames': results.map((r) => r.name).toList()});
    memoryManager.addMessage(
      currentEmployeeUuid!,
      deviceId ?? 'default',
      msg,
    );
  }

  // ===== 其他内部方法 =====

  /// 构建聊天能力
  Future<llm.ChatCapability> _buildChatCapability(ProviderConfig config) async {
    final builder = llm.ai();

    switch (config.provider) {
      case LLMProvider.openai:
        builder.openai();
      case LLMProvider.anthropic:
        builder.anthropic();
      case LLMProvider.google:
        builder.google();
      case LLMProvider.ollama:
        builder.ollama();
    }

    builder.model(config.model);

    if (config.apiKey != null && config.apiKey!.isNotEmpty) {
      builder.apiKey(config.apiKey!);
    }

    if (config.baseUrl != null && config.baseUrl!.isNotEmpty) {
      builder.baseUrl(config.baseUrl!);
    }

    builder.temperature(config.options.temperature);

    if (config.options.maxTokens != null) {
      builder.maxTokens(config.options.maxTokens!);
    } else {
      builder.maxTokens(32000);
    }
    builder.reasoning(false);

    if (config.options.topP != null) {
      builder.topP(config.options.topP!);
    }

    if (config.options.stop != null && config.options.stop!.isNotEmpty) {
      builder.stopSequences(config.options.stop!);
    }
    builder.enableLogging(true);
    builder.timeout(Duration(minutes: 30));
    return await builder.build();
  }

  /// 构建系统提示词
  String? _buildSystemPrompt() {
    if (_context == null) return null;

    final parts = <String>[];

    final systemPrompt = _context!['systemPrompt'] as String?;
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      parts.add(systemPrompt);
    }

    final projectName = _context!['projectName'] as String?;
    final projectUuid = _context!['projectUuid'] as String?;
    final workPath = _context!['workPath'] as String?;

    final hasProject =
        (projectName != null && projectName.isNotEmpty) ||
        (projectUuid != null && projectUuid.isNotEmpty) ||
        (workPath != null && workPath.isNotEmpty);

    if (hasProject) {
      final projectLines = <String>[];

      if (projectName != null && projectName.isNotEmpty) {
        projectLines.add('当前工作项目: $projectName');
      }
      if (projectUuid != null && projectUuid.isNotEmpty) {
        projectLines.add('项目ID: $projectUuid');
      }
      if (workPath != null && workPath.isNotEmpty) {
        projectLines.add('项目工作路径: $workPath');
      }

      parts.add(
        '## 当前工作项目\n'
        '${projectLines.join('\n')}\n\n'
        '请基于以上项目信息进行工作。所有操作和回答都应围绕此项目展开，'
        '如果用户没有特别指定，默认在当前项目范围内执行任务。'
        '${workPath != null && workPath.isNotEmpty ? '\n读写文件时请优先使用工作路径 $workPath 作为根目录。' : ''}',
      );
    }

    final additionalInfo = _context!['additionalInfo'];
    if (additionalInfo != null) {
      parts.add('补充信息:\n$additionalInfo');
    }

    return parts.isEmpty ? null : parts.join('\n\n');
  }

  /// 解析工具参数 JSON 字符串为 Map
  static Map<String, dynamic> _parseArguments(String argumentsJson) {
    if (argumentsJson.isEmpty) return {};
    try {
      return jsonDecode(argumentsJson) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}
