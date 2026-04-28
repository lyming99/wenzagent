import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llm_dart/llm_dart.dart' as llm;
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
import '../../utils/logger.dart';
import 'retry_config.dart';
import 'retry_util.dart';

/// 重试过程中如果检测到取消操作，抛出此异常以终止重试
class _SubRetryCancelledException implements Exception {
  const _SubRetryCancelledException();
}

/// 子 Agent 专用 LLM 聊天适配器
///
/// 轻量级 [IChatAdapter] 实现，专为子 Agent 临时执行场景设计：
/// - 不依赖数据库持久化（纯内存）
/// - 不依赖 [SessionMemoryManager]
/// - 不支持上下文压缩
/// - 用完即销毁
///
/// 与 [LlmChatAdapter] 的区别：
/// - 无 DB 读写，无会话持久化
/// - 无上下文压缩
/// - 无多设备消息隔离
/// - 内部使用简单的消息列表管理上下文
/// - 无 injectAssistantMessage / injectSystemMessage 等持久化相关方法
class SubAgentLlmChatAdapter implements IChatAdapter {
  static final _log = Logger('SubAgentLlmChatAdapter');

  /// llm_dart ChatCapability 实例
  llm.ChatCapability? _chatCapability;

  /// 提供商配置
  ProviderConfig? _providerConfig;

  /// 内存中的消息列表（纯内存，不持久化）
  final List<shared.ChatMessage> _messages = [];

  /// 当前上下文（systemPrompt + 项目信息等）
  Map<String, dynamic>? _context;

  /// 是否正在流式输出
  bool _isStreaming = false;

  /// 工具注册器
  ToolRegistry? _toolRegistry;

  /// 权限管理器
  ToolPermissionManager? _permissionManager;

  /// 工具事件回调
  void Function(ToolEvent event)? _toolEventCallback;

  /// 流式输出文本增量回调（由 AgentImpl 注入，发射 streamDelta 事件）
  @override
  void Function(String chunk)? onStreamDelta;

  /// LLM 思考内容增量回调（由 AgentImpl 注入，发射 thinkingDelta 事件）
  @override
  void Function(String delta)? onThinkingDelta;

  /// Token 用量回调（由 AgentImpl 注入，每次 LLM 调用后触发）
  void Function(llm.UsageInfo usage)? onTokenUsage;

  /// 当前正在并行执行的工具列表（用于取消）
  final List<AgentTool> _runningTools = [];

  /// dio CancelToken（用于取消 LLM 流式请求）
  llm.CancelToken? _dioCancelToken;

  /// 内部会话 ID
  String? _sessionId;

  /// 工具调用循环最大迭代次数
  static const int _maxToolCallIterations = 100;

  SubAgentLlmChatAdapter();

  // ===== IChatAdapter 属性实现 =====

  @override
  List<Map<String, dynamic>> get currentMessages {
    return _messages.map((m) => m.toJson()).toList();
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
    _sessionId = employeeId;
    _messages.clear();
  }

  @override
  Future<void> loadRemainingMessages() async {
    // 子 Agent 不需要加载历史消息
  }

  @override
  Stream<StreamResponse> streamMessage(
    MessageInput message, {
    CancellationToken? cancellationToken,
  }) {
    final controller = StreamController<StreamResponse>();
    _log.debug('stream start, model: ${_providerConfig?.model}');
    () async {
      // 前置校验
      if (_chatCapability == null) {
        controller.add(StreamResponse.error('未配置 LLM Provider'));
        await controller.close();
        return;
      }
      if (_isStreaming) {
        controller.add(StreamResponse.error('正在处理中，请等待当前请求完成'));
        await controller.close();
        return;
      }
      if (_sessionId == null) {
        controller.add(StreamResponse.error('未初始化会话'));
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
        // 添加用户消息到内存
        final userMessage = shared.ChatMessage.user(
          id: message.id ?? const Uuid().v4(),
          employeeId: _sessionId!,
          content: message.content,
          createdAt: DateTime.now(),
        );
        _messages.add(userMessage);

        final hasTools = _toolRegistry != null && !_toolRegistry!.isEmpty;
        final systemPrompt = _buildSystemPrompt();

        // Tool calling 循环
        bool streamCancelled = false;
        cancelSubscription = cancellationToken?.onCancel.listen((_) {
          streamCancelled = true;
          _dioCancelToken?.cancel('User cancelled');
        });

        // 重复工具调用检测状态
        String? lastToolCallsSignature;
        int consecutiveDuplicateCount = 0;
        final notReplyRecord = _NotReplyRecord(maxNotReplyCount: 5);
        final alreadyCallsSet = <String>{};

        for (
          var iteration = 0;
          iteration < _maxToolCallIterations;
          iteration++
        ) {
          if (cancellationToken?.isCancelled == true) {
            controller.add(StreamResponse.error('Cancelled'));
            return;
          }

          // 构建消息列表
          final llmMessages = _buildLlmMessages(systemPrompt);

          // 构建工具列表
          final List<llm.Tool>? llmTools;
          if (hasTools && _toolRegistry != null && _providerConfig != null) {
            llmTools = _toolRegistry!.getLlmDartTools(
              _providerConfig!.provider,
            );
          } else {
            llmTools = null;
          }

          _log.debug(
            'calling LLM, messages: ${llmMessages.length}, hasTools: $hasTools, iteration: $iteration',
          );

          // 调用 LLM 流式接口
          final llmResult = await _callLlmStream(
            llmMessages: llmMessages,
            llmTools: llmTools,
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
              _messages.add(
                shared.ChatMessage.assistant(
                  id: const Uuid().v4(),
                  employeeId: _sessionId!,
                  content: aiContent,
                  // 必须保存 thinking，DeepSeek V4 等模型要求 reasoning_content
                  // 在多轮对话中必须回传
                  thinking: llmResult.aiThinkingBuffer.isNotEmpty
                      ? llmResult.aiThinkingBuffer.toString()
                      : null,
                ),
              );
            }
            _log.info('tool use empty, stop tool calling loop');
            if (llmResult.isDone) {
              _log.debug('ai done: ${llmResult.aiContentBuffer.toString()}');
              break;
            } else {
              if (notReplyRecord.tooLongNotReply()) {
                _log.warn(
                  'ai not reply, too long: ${notReplyRecord.notReplyCount}',
                );
                break;
              }
              _log.debug('ai not reply, waiting...');
              await Future.delayed(const Duration(seconds: 3));
              continue;
            }
          }
          notReplyRecord.reset();

          // 有工具调用 → 暂存 assistant 消息
          final chatToolCalls = llmResult.toolCalls
              .map(
                (tc) => shared.ToolCall(
                  id: tc.id,
                  name: tc.function.name,
                  arguments: _parseArguments(tc.function.arguments),
                ),
              )
              .toList();
          final pendingAssistantMsg = shared.ChatMessage.assistant(
            id: const Uuid().v4(),
            employeeId: _sessionId!,
            content: llmResult.aiContentBuffer.toString(),
            toolCalls: chatToolCalls,
            thinking: llmResult.aiThinkingBuffer.isNotEmpty
                ? llmResult.aiThinkingBuffer.toString()
                : null,
          );

          // 重复工具调用检测
          final duplicateResult = _checkDuplicateToolCalls(
            llmResult.toolCalls,
            lastToolCallsSignature,
            consecutiveDuplicateCount,
          );
          if (duplicateResult != null) {
            lastToolCallsSignature = duplicateResult.updatedSignature;
            consecutiveDuplicateCount = duplicateResult.updatedCount;

            if (duplicateResult.isDeadLoop) {
              controller.add(
                StreamResponse.error(
                  '检测到工具调用死循环：LLM 连续 ${duplicateResult.updatedCount} 轮发出相同的工具调用。',
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

          // 写入 assistant 消息 + tool results
          _messages.add(pendingAssistantMsg);
          if (execResult.results.isNotEmpty) {
            _messages.add(
              shared.ChatMessage.toolResultGroup(
                id: const Uuid().v4(),
                employeeId: _sessionId!,
                results: execResult.results,
              ).copyWith(
                metadata: {
                  'toolNames': execResult.results.map((r) => r.name).toList(),
                },
              ),
            );
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

          var endResult = execResult.results
              .where((r) => r.name == 'end')
              .firstOrNull;
          // 检测 end 工具调用 → 主动结束循环
          if (endResult != null) {
            _log.info(
              'end tool called, breaking tool-calling loop:${endResult.content}',
            );
            if (endResult.content.isNotEmpty) {
              controller.add(
                StreamResponse.chunk('\n执行结束,结果如下:\n${endResult.content}'),
              );
            }
            break;
          }
          if (iteration == _maxToolCallIterations - 1) {
            controller.add(
              StreamResponse.error('已达到最大工具调用轮次（$_maxToolCallIterations 次）'),
            );
            return;
          }
        }

        controller.add(StreamResponse.done());
        _log.debug('stream done');
      } catch (e, st) {
        controller.add(StreamResponse.error('LLM 请求失败: $e'));
        _log.error('stream error', e, st);
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

    for (final tool in _runningTools) {
      tool.cancel();
    }
    _runningTools.clear();
  }

  @override
  Future<List<AgentMessage>> getSessionMessages(String employeeId) async {
    return _messages.map((m) => AgentMessage.fromMap(m.toJson())).toList();
  }

  @override
  Future<void> clearCurrentSession() async {
    _messages.clear();
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
    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index >= 0) {
      _messages.removeAt(index);
      return true;
    }
    return false;
  }

  @override
  Future<void> updateProvider(Map<String, dynamic> providerConfig) async {
    final config = ProviderConfig.fromMap(providerConfig);
    _log.debug(
      'parsed config: provider=${config.provider}, model=${config.model}',
    );
    config.validate();

    _chatCapability = await _buildChatCapability(config);
    _providerConfig = config;
    _log.debug('_chatCapability created: $_chatCapability');
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
    // 子 Agent 不持久化消息状态，忽略
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
    _messages.clear();
    _chatCapability = null;
    _providerConfig = null;
    _context = null;
    _sessionId = null;
    _toolRegistry = null;
    _permissionManager = null;
    _toolEventCallback = null;
  }

  // ===== 内部方法 =====

  /// 构建 ChatCapability
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
      case LLMProvider.deepseek:
        builder.deepseek();
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
      // Ollama 本地模型上下文窗口通常较小，使用保守默认值
      final defaultMaxTokens =
          config.provider == LLMProvider.ollama ? 4096 : 32000;
      builder.maxTokens(defaultMaxTokens);
    }
    builder.reasoning(false);

    if (config.options.topP != null) {
      builder.topP(config.options.topP!);
    }

    if (config.options.stop != null && config.options.stop!.isNotEmpty) {
      builder.stopSequences(config.options.stop!);
    }
    builder.enableLogging(true);
    // Ollama 本地推理可能较慢，适当延长超时
    final timeout = config.provider == LLMProvider.ollama
        ? const Duration(minutes: 60)
        : const Duration(minutes: 30);
    builder.timeout(timeout);
    return await builder.build();
  }

  /// 与主 Agent 一致的固定系统提示词前缀
  static const String _fixedSystemPromptPrefix =
      '## 系统环境\n\n'
      '你运行在以下平台上，请根据操作系统选择正确的命令和工具。\n'
      '例如：Windows 使用 `dir`，Linux/macOS 使用 `ls`；Windows 使用 `where`，Linux/macOS 使用 `which`；'
      'Windows 使用 `cmd /c`，Linux/macOS 使用 `sh -c`；Windows 使用反斜杠 `\\` 路径，Linux/macOS 使用正斜杠 `/`。\n\n';

  /// 构建运行时系统环境信息段落
  static String _buildSystemInfoSection() {
    final os = Platform.operatingSystem;
    final osVersion = Platform.operatingSystemVersion;
    final pathSep = Platform.pathSeparator;
    final isWindows = Platform.isWindows;
    final shell = isWindows
        ? 'cmd /c (Windows Command Prompt / PowerShell)'
        : 'sh -c (Unix shell)';
    return '## 运行时系统信息\n\n'
        '- **操作系统**: $os\n'
        '- **系统版本**: $osVersion\n'
        '- **路径分隔符**: "$pathSep"\n'
        '- **Shell**: $shell\n'
        '- **CPU 核心数**: ${Platform.numberOfProcessors}\n';
  }

  /// 构建系统提示词（与主 Agent 保持一致的结构）
  String? _buildSystemPrompt() {
    final parts = <String>[];

    // 固定前缀：任务分级执行流程 + 平台说明
    parts.add(_fixedSystemPromptPrefix);
    // 运行时系统环境信息
    parts.add(_buildSystemInfoSection());

    if (_context == null) {
      return parts.join('\n\n');
    }

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

    return parts.join('\n\n');
  }

  /// 构建 LLM 消息列表
  List<llm.ChatMessage> _buildLlmMessages(String? systemPrompt) {
    // Anthropic 等提供商要求 tool_result 必须匹配紧邻前一条 assistant 消息的 tool_use blocks，
    // 因此需要启用 strictMode 禁用跨轮次匹配，避免 "unexpected tool_use_id" 错误。
    final isStrictProvider = _providerConfig?.provider == LLMProvider.anthropic;
    final sanitized = shared.LlmMessageMapper.sanitizeForLlm(
      shared.LlmMessageMapper.mergeConsecutiveToolResults(_messages),
      strictMode: isStrictProvider,
    );
    final llmMessages = shared.LlmMessageMapper.toLlmDartList(sanitized, provider: _providerConfig?.provider);

    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      llmMessages.insert(0, llm.ChatMessage.system(systemPrompt));
    }

    return llmMessages;
  }

  /// LLM 调用（非流式，使用 chatWithTools）
  Future<_LlmStreamResult> _callLlmStream({
    required List<llm.ChatMessage> llmMessages,
    required List<llm.Tool>? llmTools,
    required bool streamCancelled,
    CancellationToken? cancellationToken,
    void Function(String chunk)? onChunk,
  }) async {
    final aiContentBuffer = StringBuffer();
    final thinkingContentBuffer = StringBuffer();
    llm.ChatResponse response;

    try {
      response = await RetryUtil.executeWithRetry<llm.ChatResponse>(
        () async {
          // 每次重试前检查取消状态
          if (cancellationToken?.isCancelled == true || streamCancelled) {
            throw _SubRetryCancelledException();
          }
          return await _chatCapability!.chatWithTools(
            llmMessages,
            llmTools,
            cancelToken: _dioCancelToken,
          );
        },
        config: _providerConfig?.retryConfig ?? const RetryConfig(),
        shouldRetry: (error) {
          if (error is StateError ||
              error is TypeError ||
              error is _SubRetryCancelledException) {
            return false;
          }
          return RetryUtil.isRetryableError(error);
        },
        onRetry: (attempt, error, delay) async {
          _log.warn('LLM 调用重试第 $attempt 次，错误: $error');
        },
      );

      if (response.text != null && response.text!.isNotEmpty) {
        aiContentBuffer.write(response.text);
        onChunk?.call(response.text!);
        onStreamDelta?.call(response.text!);
      }

      if (response.thinking != null && response.thinking!.isNotEmpty) {
        thinkingContentBuffer.write(response.thinking);
        onThinkingDelta?.call(response.thinking!);
      }

      _log.debug(
        'finalResponse: ${response.text}, ${response.usage}, ${response.toolCalls}',
      );

      // 采集 token 用量
      final usage = response.usage;
      if (usage != null) {
        onTokenUsage?.call(usage);
      }
    } on AggregateException catch (e) {
      // AggregateException 中的最终错误如果是取消异常，返回取消结果
      if (e.errors.isNotEmpty && e.errors.last is _SubRetryCancelledException) {
        return _LlmStreamResult.cancelled();
      }
      _log.error('LLM stream error after retries', e);
      return _LlmStreamResult.error('LLM 调用异常: $e');
    } catch (e) {
      _log.error('LLM stream error', e);
      return _LlmStreamResult.error('LLM 调用异常: $e');
    }

    if (cancellationToken?.isCancelled == true) {
      return _LlmStreamResult.cancelled();
    }

    return _LlmStreamResult(
      aiContentBuffer: aiContentBuffer,
      aiThinkingBuffer: thinkingContentBuffer,
      isDone: aiContentBuffer.toString().trim().isNotEmpty,
      toolCalls: response.toolCalls ?? <llm.ToolCall>[],
    );
  }

  /// 重复工具调用检测
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
      _log.warn('检测到重复工具调用 (第 $newCount 次): $currentSignature');
      return _DuplicateCheckResult(
        updatedSignature: currentSignature,
        updatedCount: newCount,
        isDeadLoop: newCount >= maxConsecutiveDuplicateRounds,
      );
    }

    return null;
  }

  /// 工具权限检查 + 并行执行
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

      if (alreadyCallsSet.contains(toolCall.id)) {
        _log.warn('检测到重复 toolCallId: ${toolCall.id}, 生成跳过结果');
        final skipResult = shared.ToolResult(
          toolCallId: toolCall.id,
          content: '工具调用已跳过: 重复的 toolCallId ${toolCall.id}',
          isError: true,
          name: toolCall.function.name,
        );
        allToolResults.add(skipResult);
        _toolEventCallback?.call(
          ToolCallResultEvent(
            toolCallId: toolCall.id,
            toolName: toolCall.function.name,
            result: skipResult.content,
            isError: true,
          ),
        );
        continue;
      }
      alreadyCallsSet.add(toolCall.id);

      final toolName = toolCall.function.name;
      final toolCallId = toolCall.id;
      Map<String, dynamic> toolArguments;
      try {
        toolArguments =
            jsonDecode(toolCall.function.arguments) as Map<String, dynamic>;
      } catch (e) {
        _log.debug('failed to parse tool arguments, using empty map: $e');
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

      // 权限检查
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
      return _ToolExecSummary(cancelled: false, results: allToolResults);
    }

    // Phase 2: 并行执行已批准的工具
    _runningTools.addAll(pendingExecutions.map((e) => e.tool));

    final results = await Future.wait(
      pendingExecutions.map(
        (exec) => _executeSingleTool(exec, cancellationToken),
      ),
    );

    _runningTools.clear();

    // 取消处理
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
      return _ToolExecSummary(cancelled: true, results: allToolResults);
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
    _log.debug(
      '工具执行完成: $toolName, isError=${result.isError}, '
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

  /// 解析工具参数 JSON
  static Map<String, dynamic> _parseArguments(String argumentsJson) {
    if (argumentsJson.isEmpty) return {};
    try {
      return jsonDecode(argumentsJson) as Map<String, dynamic>;
    } catch (e) {
      _log.debug('failed to parse arguments JSON, using empty map: $e');
      return {};
    }
  }
}

// ===== 内部辅助类 =====

class _NotReplyRecord {
  int notReplyCount = 0;
  final int maxNotReplyCount;

  _NotReplyRecord({this.maxNotReplyCount = 3});

  bool tooLongNotReply() {
    notReplyCount++;
    return notReplyCount >= maxNotReplyCount;
  }

  void reset() {
    notReplyCount = 0;
  }
}

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

class _ToolExecSummary {
  final bool cancelled;
  final List<shared.ToolResult> results;

  const _ToolExecSummary({required this.cancelled, required this.results});
}
