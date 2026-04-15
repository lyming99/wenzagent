part of 'llm_chat_adapter.dart';

// ===== 工具调用循环相关方法 =====

extension _ToolCallingLoop on LlmChatAdapter {
  /// 记录 assistant 消息（含 toolCalls）到会话历史
  void recordAssistantToolCallMessage(
    String aiContent,
    List<llm.ToolCall> toolCalls,
  ) {
    final chatToolCalls = toolCalls
        .map((tc) => shared.ToolCall(
              id: tc.id,
              name: tc.function.name,
              arguments: LlmChatAdapter._parseArguments(tc.function.arguments),
            ))
        .toList();
    memoryManager.addMessage(
      currentEmployeeUuid!,
      deviceId!,
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
  _DuplicateCheckResult? checkDuplicateToolCalls(
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
      LlmChatAdapter._log.warn('检测到重复工具调用 (第 $newCount 次): $currentSignature');
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
  Future<_ToolExecSummary> executeToolCalls(
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
        // 重复 tool call ID：生成错误 result 确保序列完整，而非直接跳过
        LlmChatAdapter._log.warn('检测到重复 toolCallId: ${toolCall.id}, 生成跳过结果');
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
        LlmChatAdapter._log.debug('failed to parse tool arguments as JSON, using empty map: $e');
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
      persistToolResults(allToolResults);
      return _ToolExecSummary(cancelled: false, results: []);
    }

    // Phase 2: 并行执行已批准的工具
    _runningTools.addAll(pendingExecutions.map((e) => e.tool));

    final results = await Future.wait(
      pendingExecutions.map(
        (exec) => executeSingleTool(exec, cancellationToken),
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
      persistToolResults(allToolResults);
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

    persistToolResults(allToolResults);

    return _ToolExecSummary(cancelled: false, results: allToolResults);
  }

  /// 执行单个工具调用
  Future<_ToolExecResult> executeSingleTool(
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
    LlmChatAdapter._log.debug(
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

  /// 将工具结果合并写入会话历史
  void persistToolResults(List<shared.ToolResult> results) {
    if (results.isEmpty) return;
    final msg = shared.ChatMessage.toolResultGroup(
      id: const Uuid().v4(),
      employeeId: currentEmployeeUuid!,
      results: results,
    ).copyWith(metadata: {'toolNames': results.map((r) => r.name).toList()});
    memoryManager.addMessage(
      currentEmployeeUuid!,
      deviceId!,
      msg,
    );
  }
}
