part of 'llm_chat_adapter.dart';

/// 重试过程中用户取消操作的异常（内部使用）
///
/// 当用户在重试过程中取消了 LLM 请求时抛出此异常，
/// 用于在重试循环中区分取消和普通错误。
class _RetryCancelledException implements Exception {
  @override
  String toString() => 'Retry cancelled by user';
}

// ===== streamMessage 及其子方法 =====

extension _StreamHandler on LlmChatAdapter {
  /// 前置校验，返回 null 表示通过，否则返回错误信息
  String? validateStreamReady() {
    if (_chatCapability == null) {
      LlmChatAdapter._log.error('_chatCapability is null');
      return '未配置 LLM Provider，请先调用 updateProvider()';
    }
    if (_isStreaming) {
      LlmChatAdapter._log.error('already streaming');
      return '正在处理中，请等待当前请求完成';
    }
    if (currentEmployeeUuid == null) {
      LlmChatAdapter._log.error('currentEmployeeUuid is null');
      return '未初始化会话，请先调用 initSession()';
    }
    return null;
  }

  /// 添加用户消息到会话历史
  Future<void> addUserMessage(MessageInput message) async {
    final id = message.id ?? const Uuid().v4();
    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session != null && session.allMessages.any((m) => m.id == id)) {
      session.removeMessage(id);
      LlmChatAdapter._log.debug('用户消息已从内存移除，准备重新持久化: $id');
    }

    final userMessage = shared.ChatMessage.user(
      id: id,
      employeeId: currentEmployeeUuid!,
      content: message.content,
      createdAt: DateTime.now(),
    );
    memoryManager.addMessage(currentEmployeeUuid!, deviceId!, userMessage);
  }

  /// 准备上下文压缩
  void prepareCompression(String? systemPrompt) {
    if (_compressor == null) return;
    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session == null) return;
    final allMsgs = session.allMessages;
    _compressor!.prepareCompression(
      employeeId: currentEmployeeUuid!,
      allMessages: allMsgs,
      session: session,
      systemPrompt: systemPrompt,
    );
  }

  /// LLM 流式调用，返回 AI 文本、工具调用列表等
  Future<_LlmStreamResult> callLlmStream({
    required String? systemPrompt,
    required bool hasTools,
    required bool streamCancelled,
    CancellationToken? cancellationToken,
    Set<String>? allSentToolCallIds,
    void Function(String chunk)? onChunk,
  }) async {
    // 构建工具列表
    final List<llm.Tool>? llmTools;
    if (hasTools && _toolRegistry != null && _providerConfig != null) {
      llmTools = _toolRegistry!.getLlmDartTools(_providerConfig!.provider);
    } else {
      llmTools = null;
    }
    if (hasTools) {
      LlmChatAdapter._log.debug('已注册工具列表 (${_toolRegistry!.length} 个):');
    }

    List<llm.ChatMessage>? llmMessages;
    var lastEstimatedTokens = 0;

    String? rebuildLlmRequest() {
      // 构建消息列表
      final List<shared.ChatMessage> chatMsgs;
      if (_compressor != null) {
        final session = memoryManager.getSession(currentEmployeeUuid!);
        if (session == null) {
          return '未初始化会话，请先调用 initSession()';
        }
        final allMsgs = session.allMessages;
        chatMsgs = _compressor!.buildCompressedMessages(
          employeeId: currentEmployeeUuid!,
          allMessages: allMsgs,
          session: session,
          systemPrompt: systemPrompt,
        );
      } else {
        chatMsgs = memoryManager.buildMessages(
          employeeId: currentEmployeeUuid!,
          systemPrompt: systemPrompt,
        );
      }

      // 处理顺序：merge → sanitize → toLlmDartList
      // Anthropic 等提供商要求 tool_result 必须匹配紧邻前一条 assistant 消息的 tool_use blocks，
      // 因此需要启用 strictMode；DeepSeek/OpenAI 等兼容提供商不需要。
      final isStrictProvider =
          _providerConfig?.provider == LLMProvider.anthropic;
      final merged = shared.LlmMessageMapper.mergeConsecutiveToolResults(
        chatMsgs,
      );
      final sanitized = shared.LlmMessageMapper.sanitizeForLlm(
        merged,
        knownToolCallIds: allSentToolCallIds,
        strictMode: isStrictProvider,
      );
      final nextLlmMessages = shared.LlmMessageMapper.toLlmDartList(
        sanitized,
        provider: _providerConfig?.provider,
      );

      // 诊断日志
      _logDiagnosticSequence(nextLlmMessages);

      // 验证序列合规性
      final validationErrors = _validateLlmMessageSequence(nextLlmMessages);
      if (validationErrors.isNotEmpty) {
        final errorDetail = validationErrors.join('\n  ');
        final errorMsg =
            'LLM 消息序列不合规：tool_result 与 assistant(toolUse) 不匹配。\n$errorDetail';
        LlmChatAdapter._log.error(errorMsg);
        return errorMsg;
      }

      // Token 估算：在发送前估算总 token 数，提前检测超限
      final tokenEstimator = CharBasedTokenEstimator();
      lastEstimatedTokens = tokenEstimator.estimateMessagesTotal(chatMsgs);
      LlmChatAdapter._log.info(
        'calling LLM, messages count: ${nextLlmMessages.length}, '
        'hasTools: $hasTools, estimatedTokens: ~$lastEstimatedTokens',
      );

      // 预检：如果压缩器已启用但估算 token 仍超出预算，记录警告
      if (_compressor != null && _compressor!.config.enabled) {
        final budget = _compressor!.config.effectiveBudget;
        if (budget > 0 && lastEstimatedTokens > budget) {
          LlmChatAdapter._log.warn(
            '压缩后估算 token ($lastEstimatedTokens) 仍超出预算 ($budget)，'
            'LLM 可能返回 token 超限错误',
          );
        }
      }

      llmMessages = nextLlmMessages;
      return null;
    }

    final initialBuildError = rebuildLlmRequest();
    if (initialBuildError != null) {
      return _LlmStreamResult.error(initialBuildError);
    }

    final aiContentBuffer = StringBuffer();
    final thinkingContentBuffer = StringBuffer();
    llm.ChatResponse response;

    // 获取重试配置（未配置时使用默认值）
    final retryConfig = _providerConfig?.retryConfig ?? const RetryConfig();
    final retryErrors = <String>[];
    var contextOverflowDetected = false;
    var contextCompressedForOverflow = false;
    var rebuildErrorAfterCompression = false;

    bool compressAfterContextOverflow(Object error) {
      if (!RetryUtil.isContextOverflowError(error)) return false;
      contextOverflowDetected = true;

      if (_compressor == null || !_compressor!.config.enabled) {
        LlmChatAdapter._log.warn('检测到上下文溢出，但上下文压缩未启用: $error');
        return false;
      }
      if (contextCompressedForOverflow) {
        LlmChatAdapter._log.warn('上下文溢出后已压缩过一次，仍然失败: $error');
        return false;
      }

      final session = memoryManager.getSession(currentEmployeeUuid!);
      if (session == null) {
        LlmChatAdapter._log.warn('检测到上下文溢出，但会话不存在，无法压缩: $error');
        return false;
      }

      final compressed = _compressor!.forceCompress(
        employeeId: currentEmployeeUuid!,
        allMessages: session.allMessages,
        session: session,
        systemPrompt: systemPrompt,
      );
      if (!compressed) {
        LlmChatAdapter._log.warn('检测到上下文溢出，但压缩边界未发生变化: $error');
        return false;
      }

      contextCompressedForOverflow = true;
      final rebuildError = rebuildLlmRequest();
      if (rebuildError != null) {
        rebuildErrorAfterCompression = true;
        LlmChatAdapter._log.error('上下文压缩后重建 LLM 请求失败: $rebuildError');
        return false;
      }

      LlmChatAdapter._log.info(
        '检测到上下文溢出，已强制压缩上下文并准备重试；'
        'estimatedTokensAfterCompression=$lastEstimatedTokens',
      );
      return true;
    }

    try {
      // 使用重试机制包装 chatWithTools 调用
      response = await RetryUtil.executeWithRetry<llm.ChatResponse>(
        () async {
          // 每次重试前检查取消状态
          if (streamCancelled || cancellationToken?.isCancelled == true) {
            throw _RetryCancelledException();
          }
          return await _chatCapability!.chatWithTools(
            llmMessages!,
            llmTools,
            cancelToken: _dioCancelToken,
          );
        },
        config: retryConfig,
        shouldRetry: (error) {
          // StateError 和 TypeError 表示程序逻辑问题，不重试
          if (error is StateError || error is TypeError) {
            return false;
          }
          // _RetryCancelledException 表示取消，不重试
          if (error is _RetryCancelledException) {
            return false;
          }
          if (compressAfterContextOverflow(error)) {
            return true;
          }
          return RetryUtil.isRetryableError(error);
        },
        onRetry: (attempt, error, delay) async {
          retryErrors.add(error.toString());
          onRetryStatus?.call(
            isRetrying: true,
            attempt: attempt,
            maxRetries: retryConfig.maxRetries,
            error: error.toString(),
            errors: List.unmodifiable(retryErrors),
            delayMs: delay.inMilliseconds,
            contextOverflow: contextOverflowDetected,
            contextCompressed: contextCompressedForOverflow,
          );
          LlmChatAdapter._log.warn(
            'LLM 调用失败，${delay.inMilliseconds}ms 后重试第 $attempt 次: $error',
          );
        },
      );

      // 重试成功，恢复非重试状态
      onRetryStatus?.call(isRetrying: false);

      if (response.text != null && response.text!.isNotEmpty) {
        aiContentBuffer.write(response.text);
        onChunk?.call(response.text!);
        onStreamDelta?.call(response.text!);
      }

      if (response.thinking != null && response.thinking!.isNotEmpty) {
        thinkingContentBuffer.write(response.thinking);
        onThinkingDelta?.call(response.thinking!);
      }

      LlmChatAdapter._log.debug(
        'finalResponse:${response.text},${response.usage?.toString()},${response.toolCalls}',
      );

      // 采集 token 用量
      final usage = response.usage;
      if (usage != null) {
        onTokenUsage?.call(usage);
      }
    } on StateError catch (e, st) {
      onRetryStatus?.call(isRetrying: false, error: e.toString());
      LlmChatAdapter._log.error('LLM stream error (StateError): $e\n$st');
      return _LlmStreamResult.error('LLM 调用异常: $e');
    } on TypeError catch (e, st) {
      onRetryStatus?.call(isRetrying: false, error: e.toString());
      LlmChatAdapter._log.error('LLM stream error (TypeError): $e\n$st');
      return _LlmStreamResult.error('LLM 调用异常: $e');
    } on AggregateException catch (e) {
      LlmChatAdapter._log.error('LLM 调用在 ${e.errors.length} 次尝试后全部失败');
      final lastError = e.errors.isNotEmpty ? e.errors.last : '';
      // 如果最终错误是取消异常，返回取消状态
      if (lastError is _RetryCancelledException) {
        onRetryStatus?.call(isRetrying: false);
        return _LlmStreamResult.cancelled();
      }
      final allErrors = e.errors.map((err) => err.toString()).toList();
      final lastErrorMessage = lastError.toString();
      onRetryStatus?.call(
        isRetrying: false,
        attempt: retryConfig.maxRetries,
        maxRetries: retryConfig.maxRetries,
        error: lastErrorMessage,
        errors: allErrors,
        contextOverflow:
            contextOverflowDetected ||
            RetryUtil.isContextOverflowError(lastError),
        contextCompressed: contextCompressedForOverflow,
      );
      if (rebuildErrorAfterCompression) {
        return _LlmStreamResult.error(
          'LLM 最后一次错误: $lastErrorMessage\n'
          '上下文压缩后重建请求失败，请检查消息序列。',
        );
      }
      return _LlmStreamResult.error('LLM 最后一次错误: $lastErrorMessage');
    } catch (e, st) {
      onRetryStatus?.call(isRetrying: false, error: e.toString());
      LlmChatAdapter._log.error('LLM stream error: $e\n$st');
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

  /// 诊断日志：输出最终发送给 LLM 的消息序列
  static void _logDiagnosticSequence(List<llm.ChatMessage> messages) {
    if (messages.isEmpty) return;
    final buf = StringBuffer('=== LLM Message Sequence (diagnostic) ===\n');
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final roleStr = msg.role.name;
      final typeStr = msg.messageType.runtimeType.toString();

      String detail = '';
      if (msg.messageType is llm.ToolUseMessage) {
        final toolUse = msg.messageType as llm.ToolUseMessage;
        final ids = toolUse.toolCalls.map((tc) => tc.id).toList();
        detail = ' tool_use_ids=$ids';
      } else if (msg.messageType is llm.ToolResultMessage) {
        final toolResult = msg.messageType as llm.ToolResultMessage;
        final ids = toolResult.results.map((r) => r.id).toList();
        detail = ' tool_result_ids=$ids';
      }

      final contentLen = msg.content.length;
      final contentPreview = contentLen > 60
          ? '${msg.content.substring(0, 60)}...'
          : msg.content;
      final hasDeepseekExt = msg.hasExtension('deepseek');
      final hasReasoningContent =
          hasDeepseekExt &&
          (msg
                  .getExtension<Map<String, dynamic>>('deepseek')
                  ?.containsKey('reasoning_content') ??
              false);
      final extInfo = hasReasoningContent
          ? ' [HAS reasoning_content]'
          : (msg.role == llm.ChatRole.assistant
                ? ' [NO reasoning_content]'
                : '');
      buf.writeln(
        '  [$i] $roleStr ($typeStr)$detail$extInfo content="$contentPreview"',
      );
    }
    buf.write('=== End Sequence (${messages.length} messages) ===');
    LlmChatAdapter._log.debug(buf.toString());
  }

  /// 验证最终 llm_dart 消息序列的合规性
  static List<String> _validateLlmMessageSequence(
    List<llm.ChatMessage> messages,
  ) {
    final errors = <String>[];
    if (messages.isEmpty) return errors;

    Set<String>? prevToolUseIds;
    int? prevAssistantIndex;

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];

      if (msg.messageType is llm.ToolUseMessage) {
        final toolUse = msg.messageType as llm.ToolUseMessage;
        if (prevToolUseIds != null &&
            prevAssistantIndex != null &&
            prevToolUseIds.isNotEmpty) {
          final err =
              '_validateLlmMessageSequence: assistant[$prevAssistantIndex] 有未匹配的 tool_use_ids=$prevToolUseIds '
              '（紧随其后应为 tool_result，但遇到了新的 assistant[toolUse]）';
          errors.add(err);
          LlmChatAdapter._log.error(err);
        }
        prevToolUseIds = toolUse.toolCalls.map((tc) => tc.id).toSet();
        prevAssistantIndex = i;
      } else if (msg.messageType is llm.ToolResultMessage) {
        final toolResult = msg.messageType as llm.ToolResultMessage;
        final resultIds = toolResult.results.map((r) => r.id).toList();

        if (prevToolUseIds == null || prevToolUseIds.isEmpty) {
          final err =
              '_validateLlmMessageSequence: tool_result[$i] ids=$resultIds '
              '没有前序 assistant(toolUse) 消息！';
          errors.add(err);
          LlmChatAdapter._log.error(err);
          continue;
        }

        for (final rid in resultIds) {
          if (!prevToolUseIds.contains(rid)) {
            final err =
                '_validateLlmMessageSequence: tool_result[$i] id=$rid '
                '不在紧邻前一条 assistant[$prevAssistantIndex] 的 tool_use_ids=$prevToolUseIds 中！';
            errors.add(err);
            LlmChatAdapter._log.error(err);
          }
        }
        for (final rid in resultIds) {
          prevToolUseIds.remove(rid);
        }
      } else {
        if (prevToolUseIds != null && prevToolUseIds.isNotEmpty) {
          final err =
              '_validateLlmMessageSequence: ${msg.role.name}[$i] 出现在 assistant[$prevAssistantIndex] '
              '和其 tool_result 之间！未匹配的 tool_use_ids=$prevToolUseIds';
          errors.add(err);
          LlmChatAdapter._log.error(err);
        }
      }
    }

    return errors;
  }
}
