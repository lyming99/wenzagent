part of 'llm_chat_adapter.dart';

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
  ///
  /// 如果消息已被 AgentImpl.sendMessage 提前持久化（存在于内存中），
  /// 则先从内存移除，再用当前时间重新创建并持久化，
  /// 确保 createdAt 和 seq 反映实际发送顺序而非排队顺序。
  Future<void> addUserMessage(MessageInput message) async {
    final id = message.id ?? const Uuid().v4();
    // 如果消息已存在于内存中（被 AgentImpl.sendMessage 提前持久化），
    // 先从内存中移除，避免 streamMessage 时上下文混乱
    final session = memoryManager.getSession(currentEmployeeUuid!);
    if (session != null && session.allMessages.any((m) => m.id == id)) {
      session.removeMessage(id);
      LlmChatAdapter._log.debug('用户消息已从内存移除，准备重新持久化: $id');
    }

    // 用当前时间创建消息，确保 createdAt 和 seq 反映实际发送顺序
    final userMessage = shared.ChatMessage.user(
      id: id,
      employeeId: currentEmployeeUuid!,
      content: message.content,
      createdAt: DateTime.now(),
    );
    memoryManager.addMessage(
      currentEmployeeUuid!,
      deviceId!,
      userMessage,
    );
  }

  /// 准备上下文压缩
  Future<void> prepareCompression(String? systemPrompt) async {
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
  /// [allSentToolCallIds] 当前会话已发送给 LLM 的所有 tool_call_id 集合（跨轮次累积），
  /// 用于 sanitizeForLlm 时确保 tool_result 能匹配到正确的 tool_call。
  Future<_LlmStreamResult> callLlmStream({
    required String? systemPrompt,
    required bool hasTools,
    required bool streamCancelled,
    CancellationToken? cancellationToken,
    Set<String>? allSentToolCallIds,
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

    final sanitized = shared.LlmMessageMapper.sanitizeForLlm(
      chatMsgs,
      knownToolCallIds: allSentToolCallIds,
    );
    final llmMessages = shared.LlmMessageMapper.toLlmDartList(sanitized);

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
    LlmChatAdapter._log.debug('calling LLM, messages count: ${llmMessages.length}, hasTools: $hasTools');

    final aiContentBuffer = StringBuffer();
    final thinkingContentBuffer = StringBuffer();
    llm.ChatResponse response;

    try {
      response = await _chatCapability!.chatWithTools(
        llmMessages,
        llmTools,
        cancelToken: _dioCancelToken,
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

      LlmChatAdapter._log.debug('finalResponse:${response.text},${response.usage?.toString()},${response.toolCalls}');
    } catch (e) {
      LlmChatAdapter._log.error('LLM stream error', e);
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
}
