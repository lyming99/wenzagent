import 'dart:async';
import 'dart:convert';

import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/prompts.dart';
import 'package:meta/meta.dart';

import '../agent_state.dart';
import '../entity/entity.dart';
import '../processor/cancellation_token.dart';
import '../processor/message_processor.dart';
import '../tool/agent_tool.dart';
import '../tool/cancellable_tool_executor.dart';
import '../tool/permission_manager.dart';
import '../tool/tool_registry.dart';
import 'chat_model_factory.dart';
import 'context_compressor.dart';
import 'error_tool_chat_message.dart';
import 'session_memory_manager.dart';

/// Tool calling 循环最大迭代次数
const int _maxToolCallIterations = 100;

/// 基于 LangChain 的聊天适配器实现
///
/// 使用 LangChain Dart 库实现 IChatAdapter 接口，
/// 支持 OpenAI 等多种 LLM 提供商。
/// 支持 LLM Function Calling (Tool Use)。
class LangChainChatAdapter implements IChatAdapter {
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

  /// 当前正在执行的工具（用于取消）
  AgentTool? _currentTool;

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

    return session.allMessages.map(_messageWrapperToMap).toList();
  }

  @override
  Map<String, dynamic>? get currentContext => _context;

  @override
  bool get isStreaming => _isStreaming;

  // ===== IChatAdapter 方法实现 =====

  @override
  Future<void> initSession({required String employeeId}) async {
    currentEmployeeUuid = employeeId;
    memoryManager.getOrCreateSession(employeeId);
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
      // 🔑 关键：使用客户端提供的消息ID，而不是生成新的UUID
      final userMessage = ChatMessage.humanText(userContent);
      final userMessageId = messageData['id'] as String?;
      if (userMessageId != null) {
        print('[LangChainChatAdapter] 使用客户端提供的消息ID: $userMessageId');
        memoryManager.addMessage(
          currentEmployeeUuid!,
          deviceId ?? 'default',
          userMessage,
          messageId: userMessageId,
        );
      } else {
        print('[LangChainChatAdapter] 没有提供消息ID，自动生成');
        memoryManager.addMessage(
          currentEmployeeUuid!,
          deviceId ?? 'default',
          userMessage,
        );
      }

      // 检查是否有可用工具
      final hasTools = _toolRegistry != null && !_toolRegistry!.isEmpty;

      // 准备上下文压缩（每轮用户消息调用一次）
      final systemPrompt = _buildSystemPrompt();
      if (_compressor != null) {
        final session = memoryManager.getSession(currentEmployeeUuid!);
        if (session != null) {
          // 从 MessageWrapper 列表中提取 ChatMessage
          final chatMessages = session.allMessages
              .map((wrapper) => wrapper.message)
              .toList();
          await _compressor!.prepareCompression(
            employeeId: currentEmployeeUuid!,
            allMessages: chatMessages,
            session: session,
            systemPrompt: systemPrompt,
          );
        }
      }

      // Tool calling 循环
      bool completedNormally = false;

      // 重复工具调用检测：记录最近一轮的工具调用签名，防止死循环
      // 当 LLM 连续两轮发出完全相同的工具调用时，说明它陷入了死循环
      String? lastToolCallsSignature;
      const int maxConsecutiveDuplicateRounds = 3;
      int consecutiveDuplicateCount = 0;

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
          // ✅ 从 MessageWrapper 列表中提取 ChatMessage
          final chatMessages =
              session?.allMessages.map((wrapper) => wrapper.message).toList() ??
              [];
          messages = _compressor!.buildCompressedMessages(
            employeeId: currentEmployeeUuid!,
            allMessages: chatMessages,
            systemPrompt: systemPrompt,
          );
        } else {
          messages = memoryManager.buildMessages(
            employeeId: currentEmployeeUuid!,
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

        if (hasTools) {
          print('[LangChainChatAdapter] 已注册工具列表 (${_toolRegistry!.length} 个):');
          for (final toolName in _toolRegistry!.toolNames) {
            print('[LangChainChatAdapter]   - $toolName');
          }
        }
        print(
          '[LangChainChatAdapter] calling LLM, messages count: ${messages.length}, hasTools: $hasTools',
        );

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

        print(
          '[LangChainChatAdapter] LLM response: content="${aiContentBuffer.toString()}", toolCalls=${toolCalls.length}',
        );

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
          completedNormally = true;
          break;
        }

        // 有工具调用 → 将 AI 消息（含 toolCalls）加入历史
        // 修复：流式模式下 AIChatMessage.concat() 只累积 argumentsRaw（字符串拼接），
        // arguments Map 始终为 {}（因为每个 InputJsonBlockDelta 块的 arguments 都是 const {}）。
        // 如果直接存储 arguments={}, 下次发送给 Claude 时 tool_use block 的 input 为空，
        // Claude 会看到自己之前用空参数调用了工具，导致后续调用参数混乱。
        final fixedAiMessage = _fixToolCallArguments(aiMessage);
        memoryManager.addMessage(
          currentEmployeeUuid!,
          deviceId ?? 'default',
          fixedAiMessage,
        );

        // 重复工具调用检测：生成当前工具调用的签名并比较
        final currentSignature = toolCalls.map((tc) {
          final args = tc.argumentsRaw.isNotEmpty ? tc.argumentsRaw : jsonEncode(tc.arguments);
          return '${tc.name}:$args';
        }).join('|');

        if (currentSignature == lastToolCallsSignature) {
          consecutiveDuplicateCount++;
          print(
            '[LangChainChatAdapter] 检测到重复工具调用 (第 $consecutiveDuplicateCount 次): '
            '$currentSignature',
          );
          if (consecutiveDuplicateCount >= maxConsecutiveDuplicateRounds) {
            print(
              '[LangChainChatAdapter] 连续 $maxConsecutiveDuplicateRounds 轮重复工具调用，'
              '强制终止循环',
            );
            yield StreamResponse.error(
              '检测到工具调用死循环：LLM 连续 '
              '$maxConsecutiveDuplicateRounds 轮发出相同的工具调用。'
              '请尝试修改您的需求或手动提供相关信息。',
            );
            return;
          }
        } else {
          consecutiveDuplicateCount = 0;
        }
        lastToolCallsSignature = currentSignature;

        // 逐个执行工具调用
        for (final toolCall in toolCalls) {
          // 检查取消
          if (cancellationToken?.isCancelled == true) {
            yield StreamResponse.error('Cancelled');
            return;
          }

          final toolName = toolCall.name;
          final toolCallId = toolCall.id;
          // Anthropic 流式模式下 arguments 为空 Map，正确数据在 argumentsRaw 中
          Map<String, dynamic> toolArguments = toolCall.arguments;
          if (toolArguments.isEmpty && toolCall.argumentsRaw.isNotEmpty) {
            try {
              toolArguments =
                  jsonDecode(toolCall.argumentsRaw) as Map<String, dynamic>;
            } catch (_) {
              // JSON 解析失败时保留原始空 Map
            }
          }

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
              ErrorToolChatMessage(toolCallId: toolCallId, content: errorResult, isError: true),
              metadata: {'toolName': toolName},
            );
            yield StreamResponse.toolCallResult(
              toolCallId: toolCallId,
              toolName: toolName,
              result: errorResult,
              isError: true,
            );
            _toolEventCallback?.call({
              'type': 'toolCallResult',
              'data': {
                'toolCallId': toolCallId,
                'toolName': toolName,
                'result': errorResult,
                'isError': true,
              },
            });
            continue;
          }

          // 权限检查
          if (_permissionManager != null && tool.requiresPermission) {
            final decision = await _permissionManager!.checkPermission(
              tool,
              toolArguments,
            );

            if (decision == PermissionDecision.deny) {
              // 区分黑名单拒绝和用户拒绝
              final denyResult =
                  _permissionManager!.lastDenyMessage ??
                  '权限被拒绝: 用户拒绝了工具 "$toolName" 的执行';
              memoryManager.addMessage(
                currentEmployeeUuid!,
                deviceId ?? 'default',
                ErrorToolChatMessage(toolCallId: toolCallId, content: denyResult, isError: true),
                metadata: {
                  'toolName': toolName,
                  'denyReason': _permissionManager!.lastDenyMessage != null
                      ? 'blacklist'
                      : 'user',
                },
              );
              yield StreamResponse.toolCallResult(
                toolCallId: toolCallId,
                toolName: toolName,
                result: denyResult,
                isError: true,
              );
              _toolEventCallback?.call({
                'type': 'toolCallResult',
                'data': {
                  'toolCallId': toolCallId,
                  'toolName': toolName,
                  'result': denyResult,
                  'isError': true,
                  'denyReason': _permissionManager!.lastDenyMessage != null
                      ? 'blacklist'
                      : 'user',
                },
              });
              continue;
            }
          }

          // 执行工具
          final stopwatch = Stopwatch()..start();
          ToolResult result;
          _currentTool = tool; // 记录当前工具用于取消
          print(
            '[LangChainChatAdapter] 执行工具: $toolName, arguments: $toolArguments',
          );
          try {
            // 使用可取消的执行器（cancellationToken 为 null 时用默认值）
            final token = cancellationToken ?? CancellationToken();
            final executor = CancellableToolExecutor(tool, token);
            result = await executor.execute(toolArguments);
          } on ToolCancelledException {
            yield StreamResponse.error('Cancelled');
            return;
          } catch (e) {
            result = ToolResult.error('工具执行异常: $e');
          } finally {
            _currentTool = null; // 清除当前工具
          }
          stopwatch.stop();
          final resultPreview = result.content.length > 100
              ? '${result.content.substring(0, 100)}...(truncated, total ${result.content.length} chars)'
              : result.content;
          print(
            '[LangChainChatAdapter] 工具执行完成: $toolName, isError=${result.isError}, '
            'duration=${stopwatch.elapsedMilliseconds}ms, result=$resultPreview',
          );

          // 将工具结果加入历史
          memoryManager.addMessage(
            currentEmployeeUuid!,
            deviceId ?? 'default',
            ErrorToolChatMessage(toolCallId: toolCallId, content: result.content, isError: result.isError),
          metadata: {'toolName': toolName},
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

          // 工具调用出错时，yield 提示给用户看到
          if (result.isError) {
            final userHint =
                '\n⚠️ 工具 $toolName 执行失败: ${result.content.split('\n').first}';
            yield StreamResponse.chunk(userHint);
          }
        }

        // 所有工具执行完毕，继续循环让 LLM 处理结果
      }

      // 达到最大迭代次数限制
      if (!completedNormally) {
        final errorMsg =
            '已达到最大工具调用轮次（$_maxToolCallIterations 次），请尝试简化您的需求或拆分为多个问题';
        yield StreamResponse.error(errorMsg);
        return;
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

    // 取消正在执行的工具
    if (_currentTool != null) {
      _currentTool!.cancel();
      _currentTool = null;
    }
  }

  @override
  Future<List<AgentMessage>> getSessionMessages(String employeeId) async {
    // employeeId 实际上就是 employeeId
    final session = memoryManager.getSession(employeeId);
    if (session == null) return [];

    // ✅ 使用 _messageWrapperToMap 而不是 _chatMessageToMap
    final messages = session.allMessages.map(_messageWrapperToMap).toList();
    return messages.map((m) => AgentMessage.fromMap(m)).toList();
  }

  @override
  Future<void> clearCurrentSession() async {
    if (currentEmployeeUuid != null) {
      memoryManager.clearSession(currentEmployeeUuid!);
      // 同步清除上下文压缩器的缓存，防止旧摘要泄露到新会话
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

  /// 从内存中删除指定消息
  ///
  /// 注意：此方法仅删除内存中的消息，不会删除数据库中的消息
  /// 返回是否成功删除
  bool removeMessageFromMemory(String messageId) {
    if (currentEmployeeUuid == null) {
      print(
        '[LangChainChatAdapter] removeMessageFromMemory: currentEmployeeUuid is null',
      );
      return false;
    }

    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session == null) {
      print(
        '[LangChainChatAdapter] removeMessageFromMemory: session not found',
      );
      return false;
    }

    return session.removeMessage(messageId);
  }

  @override
  Future<void> updateProvider(Map<String, dynamic> providerConfig) async {
    print('[LangChainChatAdapter] updateProvider called with: $providerConfig');
    final config = ProviderConfig.fromMap(providerConfig);
    print(
      '[LangChainChatAdapter] parsed config: provider=${config.provider}, model=${config.model}, baseUrl=${config.baseUrl}',
    );
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
  Future<String> invokeOnce(String prompt) async {
    if (_chatModel == null) {
      throw Exception('未配置 LLM Provider');
    }
    final result = await _chatModel!.invoke(
      PromptValue.chat([ChatMessage.humanText(prompt)]),
    );
    return result.output.content;
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

  /// 修复流式累积导致的 toolCall.arguments 丢失问题
  ///
  /// langchain_anthropic 的 MessageStreamEventTransformer 在处理
  /// InputJsonBlockDelta 事件时，每个 chunk 的 arguments 都是 const {}，
  /// 实际数据只累积在 argumentsRaw（字符串拼接）。
  /// AIChatMessage.concat() 合并 Map 时 {...?, ...?} 不会填充数据，
  /// 导致最终 arguments 仍为空 Map。
  ///
  /// 如果将空 arguments 的 AI 消息存入历史，下次发送给 Claude 时
  /// tool_use block 的 input 为空，Claude 会误认为自己之前用空参数调用了工具。
  static AIChatMessage _fixToolCallArguments(AIChatMessage msg) {
    final needsFix = msg.toolCalls.any(
      (tc) => tc.arguments.isEmpty && tc.argumentsRaw.isNotEmpty,
    );
    if (!needsFix) return msg;

    return AIChatMessage(
      content: msg.content,
      toolCalls: msg.toolCalls.map((tc) {
        if (tc.arguments.isEmpty && tc.argumentsRaw.isNotEmpty) {
          try {
            final parsed =
                jsonDecode(tc.argumentsRaw) as Map<String, dynamic>;
            return AIChatMessageToolCall(
              id: tc.id,
              name: tc.name,
              argumentsRaw: tc.argumentsRaw,
              arguments: parsed,
            );
          } catch (e) {
            // JSON 解析失败保留原对象
            print(e);
          }
        }
        return tc;
      }).toList(),
    );
  }

  /// 构建系统提示词
  ///
  /// 将系统提示词与项目上下文组装为完整的系统提示，
  /// 确保Agent明确知道当前工作项目和工作路径，并围绕该项目展开工作。
  String? _buildSystemPrompt() {
    if (_context == null) return null;

    final parts = <String>[];

    // 1. 基础系统提示词（Employee配置或设备覆盖）
    final systemPrompt = _context!['systemPrompt'] as String?;
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      parts.add(systemPrompt);
    }

    // 2. 项目上下文 —— 明确告诉Agent当前工作项目
    final projectName = _context!['projectName'] as String?;
    final projectContext = _context!['projectContext'];
    final projectUuid = _context!['projectUuid'] as String?;
    final workPath = _context!['workPath'] as String?;

    final hasProject =
        (projectName != null && projectName.isNotEmpty) ||
        projectContext != null ||
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
      if (projectContext != null) {
        projectLines.add('项目上下文:\n$projectContext');
      }

      parts.add(
        '## 当前工作项目\n'
        '${projectLines.join('\n')}\n\n'
        '请基于以上项目信息进行工作。所有操作和回答都应围绕此项目展开，'
        '如果用户没有特别指定，默认在当前项目范围内执行任务。'
        '${workPath != null && workPath.isNotEmpty ? '\n读写文件时请优先使用工作路径 $workPath 作为根目录。' : ''}',
      );
    }

    // 4. 补充信息
    final additionalInfo = _context!['additionalInfo'];
    if (additionalInfo != null) {
      parts.add('补充信息:\n$additionalInfo');
    }

    return parts.isEmpty ? null : parts.join('\n\n');
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

    // ✅ 使用 MessageWrapper 的稳定 UUID，而不是每次生成新 ID
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
      map['toolCalls'] = message.toolCalls
          .map(
            (tc) => {'id': tc.id, 'name': tc.name, 'arguments': tc.arguments},
          )
          .toList();
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

    // 从 wrapper.metadata 读取 status
    if (wrapper.metadata != null && wrapper.metadata!['status'] != null) {
      map['status'] = wrapper.metadata!['status'];
    }

    return map;
  }
}
