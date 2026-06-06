part of 'llm_chat_adapter.dart';

// ===== 工具调用循环相关方法 =====

extension _ToolCallingLoop on LlmChatAdapter {
  /// 重复工具调用检测
  ///
  /// 返回更新后的签名和重复计数。
  _DuplicateCheckResult checkDuplicateToolCalls(
    List<llm.ToolCall> toolCalls,
    String? lastSignature,
    int currentCount,
  ) {
    const maxConsecutiveDuplicateRounds = 5;

    // 只比较工具名+参数（排除 toolCallId，因为 LLM 每次会生成不同的 id）
    final currentSignature = toolCalls
        .map((tc) => '${tc.function.name}:${tc.function.arguments}')
        .join('|');

    LlmChatAdapter._log.debug(
      'checkDuplicateToolCalls: signature=${currentSignature.length > 200 ? '${currentSignature.substring(0, 200)}...' : currentSignature}, '
      'lastSignature=${lastSignature != null ? (lastSignature.length > 200 ? '${lastSignature.substring(0, 200)}...' : lastSignature) : 'null'}, '
      'currentCount=$currentCount',
    );

    if (currentSignature == lastSignature) {
      final newCount = currentCount + 1;
      LlmChatAdapter._log.warn('检测到重复工具调用 (第 $newCount 次): $currentSignature');
      return _DuplicateCheckResult(
        updatedSignature: currentSignature,
        updatedCount: newCount,
        isDeadLoop: newCount >= maxConsecutiveDuplicateRounds,
      );
    }

    return _DuplicateCheckResult(
      updatedSignature: currentSignature,
      updatedCount: 0,
      isDeadLoop: false,
    );
  }

  /// 工具权限检查 + 串行执行
  ///
  /// 返回执行结果列表，结果顺序与 [toolCalls] 保持一致。
  /// 如果被取消，[cancelled] 为 true。
  Future<_ToolExecSummary> executeToolCalls(
    List<llm.ToolCall> toolCalls, {
    required Set<String> alreadyCallsSet,
    required bool streamCancelled,
    CancellationToken? cancellationToken,
  }) async {
    // 使用 Map 存储结果（以 toolCallId 为键），最后按 toolCalls 原始顺序输出
    final resultMap = <String, shared.ToolResult>{};
    var cancelled = false;

    for (final toolCall in toolCalls) {
      if (streamCancelled || cancellationToken?.isCancelled == true) {
        cancelled = true;
        break;
      }
      if (alreadyCallsSet.contains(toolCall.id)) {
        // 重复 tool call ID：生成错误 result 确保序列完整，而非直接跳过
        LlmChatAdapter._log.warn('检测到重复 toolCallId: ${toolCall.id}, 生成跳过结果');
        final skipResult = shared.ToolResult(
          toolCallId: toolCall.id,
          content: '工具调用已跳过: 重复的 toolCallId ${toolCall.id}',
          isError: true,
          name: toolCall.function.name,
        );
        resultMap[toolCall.id] = skipResult;
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
      LlmChatAdapter._log.info(
        '执行工具调用: $toolName, toolCallId=$toolCallId, alreadyCallsSet.size=${alreadyCallsSet.length}',
      );
      Map<String, dynamic> toolArguments;
      try {
        toolArguments =
            jsonDecode(toolCall.function.arguments) as Map<String, dynamic>;
      } catch (e) {
        LlmChatAdapter._log.debug(
          'failed to parse tool arguments as JSON, using empty map: $e',
        );
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
        resultMap[toolCallId] = shared.ToolResult(
          toolCallId: toolCallId,
          content: errorResult,
          isError: true,
          name: toolName,
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
          resultMap[toolCallId] = shared.ToolResult(
            toolCallId: toolCallId,
            content: denyResult,
            isError: true,
            name: toolName,
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

      if (streamCancelled || cancellationToken?.isCancelled == true) {
        cancelled = true;
        break;
      }

      _runningTools.add(tool);
      final execResult = await executeSingleTool((
        call: toolCall,
        tool: tool,
        args: toolArguments,
      ), cancellationToken);
      _runningTools.remove(tool);

      resultMap[execResult.toolCall.id] = shared.ToolResult(
        toolCallId: execResult.toolCall.id,
        content: execResult.result.content,
        isError: execResult.result.isError || execResult.wasCancelled,
        name: execResult.toolName,
      );

      // 如果因取消导致当前工具被终止，标记为 cancelled 并停止后续工具
      if (execResult.wasCancelled &&
          (streamCancelled || cancellationToken?.isCancelled == true)) {
        cancelled = true;
        break;
      }
    }

    _runningTools.clear();

    // 如果取消发生在权限检查阶段，仍为未处理的 tool_call 生成结果，
    // 避免结果排序时因缺失条目抛出空断言异常。
    if (cancelled) {
      for (final toolCall in toolCalls) {
        resultMap.putIfAbsent(
          toolCall.id,
          () => shared.ToolResult(
            toolCallId: toolCall.id,
            content: '工具调用已取消: ${toolCall.function.name}',
            isError: true,
            name: toolCall.function.name,
          ),
        );
      }
    }

    // 按原始 toolCalls 顺序构建结果列表
    return _ToolExecSummary(
      cancelled: cancelled,
      results: _resultsInOrder(toolCalls, resultMap),
    );
  }

  /// 按原始 toolCalls 顺序输出结果列表，确保结果顺序与调用顺序一致
  List<shared.ToolResult> _resultsInOrder(
    List<llm.ToolCall> toolCalls,
    Map<String, shared.ToolResult> resultMap,
  ) {
    return toolCalls.map((tc) => resultMap[tc.id]!).toList(growable: false);
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
    memoryManager.addMessage(currentEmployeeUuid!, deviceId!, msg);
  }
}
