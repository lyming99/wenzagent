import 'package:langchain_core/chat_models.dart';

import 'context_compression_config.dart';
import 'session_memory_manager.dart';
import 'token_estimator.dart';

/// LLM 摘要回调类型
///
/// 由 [LangChainChatAdapter] 注入，用于调用 LLM 生成对话摘要。
typedef SummarizeCallback = Future<String> Function(String prompt);

/// 消息轮次
///
/// 一个"轮次"从 HumanChatMessage 开始，到下一个 HumanChatMessage 之前结束。
/// 包含用户消息及其后续的所有 AI/Tool 消息。
class MessageTurn {
  /// 在原始消息列表中的起始索引
  final int startIndex;

  /// 在原始消息列表中的结束索引（包含）
  final int endIndex;

  /// 本轮次包含的消息
  final List<ChatMessage> messages;

  const MessageTurn({
    required this.startIndex,
    required this.endIndex,
    required this.messages,
  });

  /// 消息数量
  int get length => messages.length;
}

/// 压缩缓存
class _CompressionCache {
  /// 缓存的摘要文本
  String? summary;

  /// 摘要覆盖到的原始消息索引
  int summarizedUpToIndex;

  /// 生成缓存时的消息总数（用于检测过期）
  int messagesCountWhenCached;

  _CompressionCache({this.summary, this.summarizedUpToIndex = 0})
    : messagesCountWhenCached = 0;
}

/// 上下文压缩器
///
/// 负责将超出 token 预算的对话历史进行智能压缩。
/// 采用两阶段策略:
/// 1. Phase 1: 截断旧工具结果内容（便宜、同步）
/// 2. Phase 2: 用 LLM 对最早的轮次生成摘要（按需、异步、缓存）
///
/// 使用方法:
/// 1. 每轮用户消息后调用 [prepareCompression]（异步，可能触发 LLM 摘要）
/// 2. Tool calling loop 中每次迭代调用 [buildCompressedMessages]（同步，使用缓存）
class ContextCompressor {
  final ContextCompressionConfig config;
  final SummarizeCallback onSummarize;

  /// token 估算器
  late final TokenEstimator _estimator = config.estimator;

  /// 每个会话的压缩缓存
  final Map<String, _CompressionCache> _sessionCaches = {};

  ContextCompressor({required this.config, required this.onSummarize});

  /// 准备压缩（每轮用户消息调用一次）
  ///
  /// 分析当前消息历史，决定压缩策略，必要时生成 LLM 摘要。
  /// 结果缓存供后续 [buildCompressedMessages] 使用。
  Future<void> prepareCompression({
    required String employeeId,
    required List<ChatMessage> allMessages,
    required SessionHistory session,
    String? systemPrompt,
  }) async {
    if (!config.enabled || allMessages.isEmpty) return;

    final budget = config.effectiveBudget;
    if (budget <= 0) return;

    // 估算系统提示 token
    final systemTokens = systemPrompt != null
        ? _estimator.estimateTokens(systemPrompt) +
              4 // message overhead
        : 0;

    // 分组为轮次
    final turns = groupIntoTurns(allMessages);
    if (turns.isEmpty) return;

    // 确定最近保留窗口
    final recentCount = config.recentTurnsKeep.clamp(1, turns.length);
    final recentStart = turns.length - recentCount;

    // 获取或创建缓存
    final cache = _sessionCaches.putIfAbsent(
      employeeId,
      () => _CompressionCache(
        summary: session.conversationSummary,
        summarizedUpToIndex: session.summarizedUpToIndex,
      ),
    );

    // 估算最近轮次的 token（始终保留完整）
    final recentMessages = <ChatMessage>[];
    for (var i = recentStart; i < turns.length; i++) {
      recentMessages.addAll(turns[i].messages);
    }
    final recentTokens = _estimator.estimateMessagesTotal(recentMessages);

    // 剩余预算给旧消息和摘要
    var remainingBudget = budget - systemTokens - recentTokens;

    if (remainingBudget <= 0) {
      // 连最近轮次都超了预算，只能全部保留最近轮次（无法再压缩）
      return;
    }

    // 收集旧轮次（最近窗口之前的）
    if (recentStart <= 0) {
      // 没有旧轮次需要压缩
      return;
    }

    // Phase 1: 对旧轮次的工具结果进行截断，估算 token
    final oldTurns = turns.sublist(0, recentStart);
    final truncatedOldMessages = _truncateToolResults(oldTurns);
    final oldTokens = _estimator.estimateMessagesTotal(truncatedOldMessages);

    if (oldTokens <= remainingBudget) {
      // Phase 1 截断后就在预算内了，不需要摘要
      // 清除过期的摘要缓存（如果有的话，旧轮次已经可以全部保留）
      return;
    }

    // Phase 2: 需要摘要压缩
    // 检查已有摘要是否足够新
    final needsResummarize = _needsResummarize(
      cache: cache,
      totalMessages: allMessages.length,
      oldTurnsEndIndex: oldTurns.last.endIndex,
    );

    if (needsResummarize) {
      await _generateSummary(
        cache: cache,
        session: session,
        oldTurns: oldTurns,
        remainingBudget: remainingBudget,
      );
    }
  }

  /// 构建压缩后的消息列表（同步，使用缓存）
  ///
  /// 在 tool calling loop 的每次迭代中调用。
  List<ChatMessage> buildCompressedMessages({
    required String employeeId,
    required List<ChatMessage> allMessages,
    String? systemPrompt,
  }) {
    if (!config.enabled || allMessages.isEmpty) {
      // 未启用压缩，回退到全量
      return _buildFullMessages(allMessages, systemPrompt);
    }

    final budget = config.effectiveBudget;
    if (budget <= 0) {
      return _buildFullMessages(allMessages, systemPrompt);
    }

    final result = <ChatMessage>[];

    // 1. 系统提示
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      result.add(ChatMessage.system(systemPrompt));
    }

    // 分组为轮次
    final turns = groupIntoTurns(allMessages);
    if (turns.isEmpty) return result;

    final recentCount = config.recentTurnsKeep.clamp(1, turns.length);
    final recentStart = turns.length - recentCount;

    // 2. 获取缓存
    final cache = _sessionCaches[employeeId];

    // 3. 注入摘要（如果有）
    if (cache?.summary != null && cache!.summary!.isNotEmpty) {
      result.add(
        ChatMessage.system('[Prior Conversation Summary]\n${cache.summary}'),
      );
    }

    // 4. 处理旧轮次（摘要覆盖之后、最近窗口之前）
    if (recentStart > 0) {
      final summarizedEndIndex = cache?.summarizedUpToIndex ?? 0;

      // 收集摘要未覆盖的旧轮次
      for (var i = 0; i < recentStart; i++) {
        final turn = turns[i];
        if (turn.endIndex < summarizedEndIndex) {
          // 这个轮次已被摘要覆盖，跳过
          continue;
        }
        // 对工具消息进行截断后加入
        for (final msg in turn.messages) {
          result.add(_maybeTrancateToolMessage(msg));
        }
      }
    }

    // 5. 最近轮次完整保留
    for (var i = recentStart; i < turns.length; i++) {
      result.addAll(turns[i].messages);
    }

    return result;
  }

  /// 清除指定会话的压缩缓存
  void clearCache(String employeeId) {
    _sessionCaches.remove(employeeId);
  }

  /// 清除所有缓存
  void dispose() {
    _sessionCaches.clear();
  }

  // ===== 消息轮次分组 =====

  /// 将消息列表分组为对话轮次
  ///
  /// 每遇到 HumanChatMessage 开始一个新轮次。
  /// 轮次包含该 Human 消息及后续所有 AI/Tool 消息直到下一个 Human。
  /// AI(toolCalls) + 对应 ToolChatMessage(s) 永远在同一轮次内。
  ///
  /// 对于开头的非 Human 消息（如果有），归入第一个虚拟轮次。
  static List<MessageTurn> groupIntoTurns(List<ChatMessage> messages) {
    if (messages.isEmpty) return [];

    final turns = <MessageTurn>[];
    var currentStart = 0;
    var currentMessages = <ChatMessage>[];

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];

      if (msg is HumanChatMessage && currentMessages.isNotEmpty) {
        // 遇到新的 Human 消息，结束当前轮次
        turns.add(
          MessageTurn(
            startIndex: currentStart,
            endIndex: i - 1,
            messages: List.unmodifiable(currentMessages),
          ),
        );
        currentStart = i;
        currentMessages = [];
      }

      currentMessages.add(msg);
    }

    // 最后一个轮次
    if (currentMessages.isNotEmpty) {
      turns.add(
        MessageTurn(
          startIndex: currentStart,
          endIndex: messages.length - 1,
          messages: List.unmodifiable(currentMessages),
        ),
      );
    }

    return turns;
  }

  // ===== 工具结果截断 =====

  /// 对旧轮次中的 ToolChatMessage 内容进行截断
  List<ChatMessage> _truncateToolResults(List<MessageTurn> turns) {
    final result = <ChatMessage>[];
    for (final turn in turns) {
      for (final msg in turn.messages) {
        result.add(_maybeTrancateToolMessage(msg));
      }
    }
    return result;
  }

  /// 如果是 ToolChatMessage 且内容过长，截断之
  ChatMessage _maybeTrancateToolMessage(ChatMessage message) {
    if (message is! ToolChatMessage) return message;

    final content = message.contentAsString;
    final maxChars = config.toolResultMaxChars;

    if (content.length <= maxChars) return message;

    final truncated =
        '${content.substring(0, maxChars)}'
        '\n...[truncated, ${content.length} chars total]';

    return ToolChatMessage(toolCallId: message.toolCallId, content: truncated);
  }

  // ===== 摘要生成 =====

  /// 判断是否需要重新生成摘要
  bool _needsResummarize({
    required _CompressionCache cache,
    required int totalMessages,
    required int oldTurnsEndIndex,
  }) {
    // 没有摘要 → 需要生成
    if (cache.summary == null || cache.summary!.isEmpty) return true;

    // 摘要覆盖的范围相对于旧消息范围太少（新消息翻倍以上）
    final uncoveredOld = oldTurnsEndIndex - cache.summarizedUpToIndex;
    if (uncoveredOld > cache.summarizedUpToIndex && uncoveredOld > 10) {
      return true;
    }

    return false;
  }

  /// 使用 LLM 生成对话摘要
  Future<void> _generateSummary({
    required _CompressionCache cache,
    required SessionHistory session,
    required List<MessageTurn> oldTurns,
    required int remainingBudget,
  }) async {
    // 确定需要摘要的轮次范围：从开头到能让剩余轮次在预算内的位置
    // 贪心策略：从最旧的轮次开始摘要，直到剩余能放下
    var turnsToSummarize = 0;
    var turnsToKeepTokens = 0;

    // 先算出所有旧轮次截断后的 token
    final truncatedPerTurn = <int>[];
    for (final turn in oldTurns) {
      final truncated = <ChatMessage>[];
      for (final msg in turn.messages) {
        truncated.add(_maybeTrancateToolMessage(msg));
      }
      truncatedPerTurn.add(_estimator.estimateMessagesTotal(truncated));
    }

    // 预留摘要 token
    final summaryBudget =
        _estimator.estimateTokens('A' * (config.summaryMaxTokens * 3)) + 10;
    final keepBudget = remainingBudget - summaryBudget;

    // 从最后一个旧轮次往前，尽量多保留
    turnsToKeepTokens = 0;
    for (var i = oldTurns.length - 1; i >= 0; i--) {
      final newTotal = turnsToKeepTokens + truncatedPerTurn[i];
      if (newTotal > keepBudget) {
        turnsToSummarize = i + 1;
        break;
      }
      turnsToKeepTokens = newTotal;
    }

    // 至少摘要 1 个轮次
    if (turnsToSummarize == 0) turnsToSummarize = 1;

    // 构建摘要 prompt
    final messagesToSummarize = <ChatMessage>[];
    for (var i = 0; i < turnsToSummarize; i++) {
      messagesToSummarize.addAll(oldTurns[i].messages);
    }

    final formattedMessages = _formatMessagesForSummary(messagesToSummarize);
    final prompt =
        'Please provide a concise summary of the following conversation '
        'between a user and an AI assistant.\n'
        'Preserve: key facts, user requests, important decisions, tool call results and outcomes.\n'
        'Omit: verbatim tool outputs, redundant details.\n'
        'Keep the summary concise (under ${config.summaryMaxTokens} tokens).\n\n'
        'Conversation:\n---\n$formattedMessages\n---\n\nSummary:';

    try {
      final summary = await onSummarize(prompt);
      final summarizedEndIndex = oldTurns[turnsToSummarize - 1].endIndex + 1;

      cache.summary = summary;
      cache.summarizedUpToIndex = summarizedEndIndex;
      cache.messagesCountWhenCached = messagesToSummarize.length;

      // 同步到 SessionHistory
      session.conversationSummary = summary;
      session.summarizedUpToIndex = summarizedEndIndex;
    } catch (_) {
      // 摘要生成失败，回退到仅截断模式（不报错，降级处理）
    }
  }

  /// 将消息格式化为适合摘要的文本
  String _formatMessagesForSummary(List<ChatMessage> messages) {
    final buffer = StringBuffer();

    for (final msg in messages) {
      final role = switch (msg) {
        HumanChatMessage() => 'User',
        AIChatMessage() => 'Assistant',
        ToolChatMessage() => 'Tool Result',
        SystemChatMessage() => 'System',
        _ => 'Other',
      };

      var content = msg.contentAsString;

      // 截断过长的内容（摘要 prompt 本身也不能太长）
      if (content.length > 500) {
        content = '${content.substring(0, 500)}...[truncated]';
      }

      // 对 AI 消息附加工具调用信息
      if (msg is AIChatMessage && msg.toolCalls.isNotEmpty) {
        final toolNames = msg.toolCalls.map((tc) => tc.name).join(', ');
        buffer.writeln('$role: $content');
        buffer.writeln('  [Called tools: $toolNames]');
      } else if (msg is ToolChatMessage) {
        buffer.writeln('$role (${msg.toolCallId}): $content');
      } else {
        buffer.writeln('$role: $content');
      }
    }

    return buffer.toString();
  }

  // ===== 辅助方法 =====

  /// 不压缩的全量消息构建
  List<ChatMessage> _buildFullMessages(
    List<ChatMessage> allMessages,
    String? systemPrompt,
  ) {
    final result = <ChatMessage>[];
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      result.add(ChatMessage.system(systemPrompt));
    }
    result.addAll(allMessages);
    return result;
  }
}
