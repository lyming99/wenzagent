import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import '../../service/message_store_service.dart';
import '../../shared/shared.dart' as shared;
import '../../utils/logger.dart';
import 'context_compressor.dart';
import 'session_memory_manager.dart';

part 'llm_stream_handler.dart';

part 'llm_tool_calling_loop.dart';

/// Tool calling 循环最大迭代次数
const int _maxToolCallIterations = 1000;

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
  static final _log = Logger('LlmChatAdapter');

  /// llm_dart ChatCapability 实例
  llm.ChatCapability? _chatCapability;

  /// 提供商配置
  ProviderConfig? _providerConfig;

  /// 会话记忆管理器
  final SessionMemoryManager memoryManager = SessionMemoryManager();

  /// 当前员工 UUID（同时作为会话 ID）
  @protected
  String? currentEmployeeUuid;

  /// 当前设备 ID（用于区分不同设备的消息记录）
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

  /// 配置持久化（由 DeviceAgentManager/AgentFactoryImpl 调用）
  void configurePersistence({
    required MessageStoreService messageStore,
    required String deviceId,
  }) {
    memoryManager.configurePersistence(
      messageStore: messageStore,
      deviceId: deviceId,
    );
  }

  /// 会话清空回调（由 DeviceAgentManager 注入，用于设置 clearSeq/lastSeq 和清理通知）
  ///
  /// [maxSeq] 清空前消息的最大 seq，用于设置 clearSeq = lastSeq = maxSeq
  Future<void> Function(String employeeId, int maxSeq)? onSessionCleared;

  /// Provider 配置变更回调（由 DeviceAgentManager 注入）
  void Function(Map<String, dynamic> providerConfig)? onProviderConfigChanged;

  /// 项目 UUID 变更回调
  void Function(String uuid)? onProjectUuidChanged;

  /// Agent 处理完成事件回调（end 工具调用 / 正常结束 / 异常）
  ///
  /// 由 DeviceAgentManager 注入，用于推送通知提醒用户响铃。
  /// 在 streamMessage 的 try/finally 中统一调用，保证所有退出路径都会触发。
  /// [status] 结束状态：'end'（正常结束）、'error'（异常）、'cancelled'（取消）
  /// [content] end 工具调用时携带的结束内容，可为空。
  void Function({required String status, String? content})? onEndEvent;

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
    // 从 DB 分页加载全部消息，确保 AI 有完整上下文避免幻觉
    await memoryManager.loadFromDb(employeeId);
  }

  @override
  Future<void> loadRemainingMessages() async {
    // initSession 已加载全部消息，此处无需重复加载
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
      final error = validateStreamReady();
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
      String? endContent;
      bool hadError = false;

      try {
        // 添加用户消息到历史
        await addUserMessage(message);

        final hasTools = _toolRegistry != null && !_toolRegistry!.isEmpty;
        final systemPrompt = _buildSystemPrompt();
        await prepareCompression(systemPrompt);

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
          final llmResult = await callLlmStream(
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
              endContent = aiContent;
              memoryManager.addMessage(
                currentEmployeeUuid!,
                deviceId!,
                shared.ChatMessage.assistant(
                  id: const Uuid().v4(),
                  employeeId: currentEmployeeUuid!,
                  content: aiContent,
                ),
              );
            }
            _log.info('tool use empty, stop tool calling loop');
            if (llmResult.isDone) {
              _log.debug(
                'ai call tool done: ${llmResult.aiContentBuffer.toString()}',
              );
              break;
            } else {
              if (notReplyRecord.tooLongNotReply()) {
                _log.warn(
                  'ai not reply, too long no reply:${notReplyRecord.notReplyCount}',
                );
                break;
              }
              _log.debug('ai not reply, wait for ai reply');
              await Future.delayed(Duration(seconds: 3));
              continue;
            }
          }
          notReplyRecord.reset();
          // 有工具调用 → 立即写入 assistant 消息，让前端能及时看到 AI 的文本回复
          final chatToolCalls = llmResult.toolCalls
              .map(
                (tc) => shared.ToolCall(
                  id: tc.id,
                  name: tc.function.name,
                  arguments: LlmChatAdapter._parseArguments(
                    tc.function.arguments,
                  ),
                ),
              )
              .toList();
          final pendingAssistantMsg = shared.ChatMessage.assistant(
            id: const Uuid().v4(),
            employeeId: currentEmployeeUuid!,
            content: llmResult.aiContentBuffer.toString(),
            toolCalls: chatToolCalls,
          );

          // 重复工具调用检测
          final duplicateError = checkDuplicateToolCalls(
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

          // 立即持久化 assistant 消息（含文本 + toolCalls），前端可即时看到 AI 回复
          memoryManager.addMessage(
            currentEmployeeUuid!,
            deviceId!,
            pendingAssistantMsg,
          );

          // 权限检查 + 并行执行工具
          final execResult = await executeToolCalls(
            llmResult.toolCalls,
            alreadyCallsSet: alreadyCallsSet,
            streamCancelled: streamCancelled,
            cancellationToken: cancellationToken,
          );

          if (execResult.cancelled) {
            controller.add(StreamResponse.error('Cancelled'));
            return;
          }

          // 工具执行完毕后，持久化 toolResult 消息
          persistToolResults(execResult.results);

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
              endContent = endResult.content;
              controller.add(StreamResponse.chunk(endResult.content));
              memoryManager.addMessage(
                currentEmployeeUuid!,
                deviceId!,
                shared.ChatMessage.assistant(
                  id: const Uuid().v4(),
                  employeeId: currentEmployeeUuid!,
                  content: endResult.content,
                ),
              );
            }
            break;
          }

          if (iteration == _maxToolCallIterations - 1) {
            controller.add(
              StreamResponse.error(
                '已达到最大工具调用轮次（$_maxToolCallIterations 次），请尝试简化您的需求或拆分为多个问题',
              ),
            );
            _log.error(
              '已达到最大工具调用轮次（$_maxToolCallIterations 次），请尝试简化您的需求或拆分为多个问题',
            );
            return;
          }
        }

        controller.add(StreamResponse.done());
        _log.debug('stream done');
      } catch (e) {
        controller.add(StreamResponse.error('LLM 请求失败: $e'));

        _log.error('stream error', e);
        hadError = true;
      } finally {
        cancelSubscription?.cancel();
        _isStreaming = false;
        _dioCancelToken = null;
        _runningTools.clear();
        onEndEvent?.call(
          status: hadError ? 'error' : 'end',
          content: endContent,
        );
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
      final empId = currentEmployeeUuid!;
      // 在删除前获取 maxSeq，用于设置 clearSeq = lastSeq
      final maxSeq = memoryManager.getMaxSeq(empId);
      await memoryManager.clearSessionFromDb(empId);
      _compressor?.clearCache(empId);
      await onSessionCleared?.call(empId, maxSeq);
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
      _log.warn('removeMessageFromMemory: currentEmployeeUuid is null');
      return false;
    }

    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session == null) {
      _log.warn('removeMessageFromMemory: session not found');
      return false;
    }

    return session.removeMessage(messageId);
  }

  @override
  Future<void> updateProvider(Map<String, dynamic> providerConfig) async {
    final config = ProviderConfig.fromMap(providerConfig);
    _log.debug(
      'parsed config: provider=${config.provider}, model=${config.model}, baseUrl=${config.baseUrl}',
    );
    config.validate();
    _log.debug('config validated successfully');

    _chatCapability = await _buildChatCapability(config);
    _providerConfig = config;
    _log.debug('_chatCapability created: $_chatCapability');

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
    memoryManager.updateMessageStatusInDb(messageId, status.name, error: error);
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

  /// 固定的系统提示词前缀（智能切换架构 + 系统信息）
  static const String _fixedSystemPromptPrefix =
      '## 系统环境\n\n'
      '你运行在以下平台上，请根据操作系统选择正确的命令和工具。\n'
      '例如：Windows 使用 `dir`，Linux/macOS 使用 `ls`；Windows 使用 `where`，Linux/macOS 使用 `which`；'
      'Windows 使用 `cmd /c`，Linux/macOS 使用 `sh -c`；Windows 使用反斜杠 `\\` 路径，Linux/macOS 使用正斜杠 `/`。\n\n'
      '## 你的角色：智能任务执行者\n\n'
      '你是**主 Agent**，拥有所有工具的直接访问权限。你可以根据任务复杂度自主决定执行方式：\n'
      '- **简单任务**（读文件、查信息、简单问答）：直接使用工具执行，无需规划。\n'
      '- **中/复杂任务**（多文件修改、架构变更、功能开发）：使用 spec>todo>impl 规划工作流。\n\n'
      '### 可用工具\n\n'
      '**规划工具：**\n'
      '- `task_complexity`：分析任务复杂度，确定最佳执行策略。\n'
      '- `todo_manage`：创建和管理待办列表，跟踪任务分解。\n'
      '- `spec_manage`：创建和管理需求规格说明，用于复杂任务。\n'
      '- `spawn_sub_agent`：将子任务委派给子 Agent（适用于需要独立上下文的复杂多步骤任务）。\n'
      '- `schedule_task`：安排定时任务。\n'
      '- `end`：结束对话循环。\n\n'
      '**执行工具：**\n'
      '- `file_read`：读取文件内容。\n'
      '- `file_write`：写入文件。\n'
      '- `file_patch`：对文件应用补丁。\n'
      '- `file_list`：列出目录内容。\n'
      '- `file_info`：获取文件/目录详细信息。\n'
      '- `file_delete`：删除文件或目录。\n'
      '- `directory_create`：创建目录。\n'
      '- `command_execute`：执行命令。\n'
      '- `bg_command`：执行后台命令。\n'
      '- `content_search`：搜索文件内容。\n'
      '- `code_symbols`：分析代码摘要结构。\n'
      '- `git_operations`：执行 Git 操作。\n'
      '- `env_info`：获取环境信息。\n'
      '- `web_fetch`：获取网页内容(http请求)。\n'
      '- `web_search`：搜索互联网。\n\n'
      '### 工作流程\n\n'
      '对于每个用户任务，根据复杂度选择策略：\n\n'
      '**简单任务（直接执行）：**\n'
      '读取文件、查询信息、简单修改等单步操作，直接使用对应的执行工具完成。\n\n'
      '**普通/复杂任务（规划工作流）：**\n'
      '1. **分析**：使用 `task_complexity` 评估任务范围和复杂度。\n'
      '2. **规划**：根据复杂度：\n'
      '   - **普通任务**：使用 `todo_manage` 拆分为子项，逐个执行或通过 `spawn_sub_agent` 委派。\n'
      '   - **复杂任务**：先使用 `spec_manage` 创建规格说明，与用户讨论对齐后，再拆分为待办并执行。\n'
      '3. **执行**：对每个待办项，可直接执行或通过 `spawn_sub_agent` 委派（提供清晰详细的任务描述）。\n'
      '4. **验收**：检查结果的质量和需求满足度。不满意则修正或重新执行。\n'
      '5. **汇报**：所有待办完成后，向用户总结整体结果，然后调用 `end` 结束。\n\n';

  /// 构建运行时系统环境信息段落（动态获取平台信息，无法使用 const）
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
        '- **CPU 核心数**: ${Platform.numberOfProcessors}\n'
        '- **工作目录**: ${Directory.current.path}\n';
  }

  /// 构建系统提示词
  String? _buildSystemPrompt() {
    if (_context == null) return null;

    final parts = <String>[];

    // 固定前缀：任务分级执行流程 + 平台说明
    parts.add(_fixedSystemPromptPrefix);
    // 运行时系统环境信息（OS、Shell、路径分隔符等）
    parts.add(_buildSystemInfoSection());

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
    } catch (e) {
      _log.debug('failed to parse arguments JSON, using empty map: $e');
      return {};
    }
  }

  /// 注入一条 assistant 消息到当前会话
  Future<void> injectAssistantMessage(
    String messageId,
    String content,
    String deviceIdentifier,
  ) async {
    final chatMessage = shared.ChatMessage.assistant(
      id: messageId,
      employeeId: currentEmployeeUuid!,
      content: content,
      createdAt: DateTime.now(),
      metadata: {'status': 'completed'},
    );
    memoryManager.addMessage(
      currentEmployeeUuid!,
      deviceIdentifier,
      chatMessage,
    );
  }

  /// 注入一条 system 消息到当前会话
  void injectSystemMessage(
    String messageId,
    String content,
    String deviceIdentifier,
  ) {
    final chatMessage = shared.ChatMessage.system(
      id: messageId,
      employeeId: currentEmployeeUuid!,
      content: content,
      createdAt: DateTime.now(),
    ).copyWith(metadata: {'status': 'completed', 'trigger': 'scheduled_task'});
    memoryManager.addMessage(
      currentEmployeeUuid!,
      deviceIdentifier,
      chatMessage,
    );
  }

  /// 删除单条消息（从内存和数据库中删除）
  Future<void> deleteMessage(String messageId) async {
    final success = removeMessageFromMemory(messageId);
    if (success) {
      await memoryManager.softDeleteMessage(messageId);
    }
  }

  /// 保存 Provider 配置并持久化到数据库
  Future<void> saveProviderConfig(ProviderConfig config) async {
    await updateProvider(config.toMap());
    onProviderConfigChanged?.call(config.toMap());
  }

  /// 设置当前项目 UUID
  Future<void> setCurrentProjectUuid(String uuid) async {
    onProjectUuidChanged?.call(uuid);
  }
}
