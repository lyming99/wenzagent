import '../../persistence/entities/compression_meta_entity.dart';
import '../../service/compression_meta_store.dart';
import '../../shared/shared.dart';
import '../../utils/logger.dart';
import 'context_compression_config.dart';
import 'session_memory_manager.dart';
import 'token_estimator.dart';

/// 消息轮次
///
/// 一个"轮次"从 user 消息开始，到下一个 user 消息之前结束。
/// 包含用户消息及其后续的所有 assistant/tool 消息。
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

/// 非阻塞异步锁，防止并发压缩
class _AsyncLock {
  bool _locked = false;

  /// 尝试获取锁，立即返回成功/失败
  bool tryLock() {
    if (_locked) return false;
    _locked = true;
    return true;
  }

  /// 释放锁
  void unlock() {
    _locked = false;
  }
}

/// 简单 LRU 缓存
class _LruCache<K, V> {
  final int maxSize;
  final Map<K, V> _map = {};

  _LruCache({required this.maxSize});

  V? get(K key) => _map[key];

  V putIfAbsent(K key, V Function() ifAbsent) {
    final existing = _map[key];
    if (existing != null) return existing;
    final value = ifAbsent();
    _map[key] = value;
    // 超出容量时移除最早的条目
    while (_map.length > maxSize) {
      _map.remove(_map.keys.first);
    }
    return value;
  }

  void remove(K key) {
    _map.remove(key);
  }

  void clear() {
    _map.clear();
  }
}

/// 上下文压缩器
///
/// 负责将超出 token 预算的对话历史进行本地压缩（裁剪内容）。
/// 不调用 LLM，纯本地处理：截断旧消息内容、剥离 tool calls。
/// AI 需要查看完整历史时，可通过 query_conversation_history 工具查询 DB。
///
/// 使用方法:
/// 1. 每轮用户消息后调用 [prepareCompression]（同步，计算压缩边界）
/// 2. Tool calling loop 中每次迭代调用 [buildCompressedMessages]（同步，应用裁剪）
class ContextCompressor {
  static final _log = Logger('ContextCompressor');

  final ContextCompressionConfig config;

  /// 压缩元数据持久化（可选）
  final CompressionMetaStore? compressionMetaStore;

  /// 当前设备 ID（用于 CompressionMetaStore 读写）
  final String? deviceId;

  /// token 估算器
  late final TokenEstimator _estimator = config.estimator;

  /// 每个会话的压缩锁，防止并发压缩
  final Map<String, _AsyncLock> _sessionLocks = {};

  /// Token 估算缓存：消息 ID → token 数
  final _tokenCache = _LruCache<String, int>(maxSize: 500);

  /// buildCompressedMessages 结果缓存
  List<ChatMessage>? _cachedCompressed;
  int _cacheGeneration = -1;

  /// 保留区内超长工具结果的截断阈值（字符数）
  static const int _maxToolResultCharsInContext = 2000;

  /// 时间冷却阈值：30 分钟（毫秒）
  static const int _timeCooldownThresholdMs = 30 * 60 * 1000;

  ContextCompressor({
    required this.config,
    this.compressionMetaStore,
    this.deviceId,
  });

  /// 判断是否需要触发压缩
  ///
  /// 同时检查 token 超限、消息数冷却期和时间冷却期。
  bool shouldCompress({
    required int totalTokens,
    required SessionHistory session,
  }) {
    if (!config.enabled) return false;
    if (totalTokens <= config.maxContextTokens) return false;

    // 消息数冷却期
    if (session.messagesSinceCompression < config.cooldownMessageCount) {
      // 补充：如果距离上次压缩超过 30 分钟，忽略消息数冷却
      if (session.lastCompressionTime > 0) {
        final elapsed =
            DateTime.now().millisecondsSinceEpoch - session.lastCompressionTime;
        if (elapsed < _timeCooldownThresholdMs) {
          return false;
        }
      } else {
        return false;
      }
    }
    return true;
  }

  /// 准备压缩（每轮用户消息调用一次）
  ///
  /// 分析当前消息历史，计算压缩边界（pruneStartId）。
  /// 纯本地操作，不调用 LLM。
  void prepareCompression({
    required String employeeId,
    required List<ChatMessage> allMessages,
    required SessionHistory session,
    String? systemPrompt,
  }) {
    if (!config.enabled || allMessages.isEmpty) return;

    // 估算总 token
    final totalTokens = _estimateMessagesTotalCached(allMessages);

    // 检查是否需要压缩（token 超限 + 冷却期已过）
    if (!shouldCompress(totalTokens: totalTokens, session: session)) return;

    // 非阻塞获取锁，失败则跳过（另一个压缩正在进行）
    final lock = _sessionLocks.putIfAbsent(employeeId, () => _AsyncLock());
    if (!lock.tryLock()) {
      _log.debug('prepareCompression: 会话 $employeeId 正在压缩中，跳过');
      return;
    }

    try {
      _doCompression(
        employeeId: employeeId,
        allMessages: allMessages,
        session: session,
        systemPrompt: systemPrompt,
      );
    } finally {
      lock.unlock();
    }
  }

  /// 强制触发一次上下文压缩。
  ///
  /// 用于真实 LLM 请求已经返回上下文长度溢出的场景。此时估算器可能偏低，
  /// 或模型的实际上下文窗口小于配置值，所以绕过 token 阈值和冷却期检查。
  /// 返回 true 表示压缩边界发生变化。
  bool forceCompress({
    required String employeeId,
    required List<ChatMessage> allMessages,
    required SessionHistory session,
    String? systemPrompt,
  }) {
    if (!config.enabled || allMessages.isEmpty) return false;

    final lock = _sessionLocks.putIfAbsent(employeeId, () => _AsyncLock());
    if (!lock.tryLock()) {
      _log.debug('forceCompress: 会话 $employeeId 正在压缩中，跳过');
      return false;
    }

    try {
      return _doCompression(
        employeeId: employeeId,
        allMessages: allMessages,
        session: session,
        systemPrompt: systemPrompt,
        forceAdvance: true,
      );
    } finally {
      lock.unlock();
    }
  }

  /// 执行实际压缩逻辑（纯本地，不调用 LLM）
  bool _doCompression({
    required String employeeId,
    required List<ChatMessage> allMessages,
    required SessionHistory session,
    String? systemPrompt,
    bool forceAdvance = false,
  }) {
    final budget = config.effectiveBudget;
    if (budget <= 0) return false;

    // 估算系统提示 token
    final systemTokens = systemPrompt != null
        ? _estimator.estimateTokens(systemPrompt) +
              4 // message overhead
        : 0;

    // 分组为轮次
    final turns = groupIntoTurns(allMessages);
    if (turns.length <= 1) return false; // 只有 0 或 1 个轮次，无法压缩

    // 最近 N 个轮次始终保留完整（由 recentTurnsKeep 配置）
    final recentTurnsCount = config.recentTurnsKeep.clamp(1, turns.length);
    final recentTurns = turns.sublist(turns.length - recentTurnsCount);
    final recentTokens = _estimateMessagesTotalCached(
      recentTurns.expand((t) => t.messages).toList(),
    );

    // 剩余预算给旧消息
    var remainingBudget = budget - systemTokens - recentTokens;
    if (remainingBudget <= 0) {
      // 连最近轮次都超了预算，无法压缩
      _log.warn(
        '最近 $recentTurnsCount 轮 ($recentTokens tokens) + 系统 ($systemTokens tokens) '
        '已超出预算 ($budget tokens)，无法压缩',
      );
      return false;
    }

    // 旧轮次（可压缩区域）
    final oldTurns = turns.sublist(0, turns.length - recentTurnsCount);
    if (oldTurns.isEmpty) return false;

    // 计算目标 token：压缩到 targetThreshold 附近
    final targetTokens = config.targetThreshold - systemTokens - recentTokens;
    if (targetTokens <= 0) return false;

    // 从尾部往前扫描旧轮次，找到压缩边界
    // 保留策略：保留原文的旧消息 + 最近轮次 必须在 budget 内
    var cumulativeTokens = 0;
    var cutIndex = 0; // [0, cutIndex) 的轮次将被丢弃

    for (var i = oldTurns.length - 1; i >= 0; i--) {
      // 估算该轮次的原始 token（不做裁剪）
      final turnTokens = _estimateMessagesTotalCached(oldTurns[i].messages);

      if (cumulativeTokens + turnTokens > targetTokens) {
        // 超出目标，从此轮次开始裁剪
        cutIndex = i + 1;
        break;
      }
      cumulativeTokens += turnTokens;

      // 如果已经遍历到第一个轮次，说明全部保留截断后就够了
      if (i == 0) {
        cutIndex = 0;
      }
    }

    // 确定保留区第一条消息的 ID（UUID）
    var newPruneStartId = '';
    if (cutIndex < oldTurns.length) {
      final cutTurn = oldTurns[cutIndex];
      newPruneStartId = cutTurn.messages.isNotEmpty
          ? cutTurn.messages.first.id
          : '';
    } else {
      // 所有旧轮次都在保留区内
      return false;
    }

    if (newPruneStartId.isEmpty) {
      _log.warn('压缩计算结果 pruneStartId 为空，跳过');
      return false;
    }

    // 如果新的 pruneStartId 和已有值相同，普通压缩无需更新；
    // 强制压缩场景下说明 API 已确认上下文仍溢出，再向后推进一个旧轮次。
    if (newPruneStartId == session.pruneStartId) {
      if (!forceAdvance) return false;
      final currentTurnIndex = turns.indexWhere(
        (turn) => turn.messages.any((m) => m.id == session.pruneStartId),
      );
      final lastCompressibleTurnIndex = turns.length - recentTurnsCount - 1;
      if (currentTurnIndex < 0 ||
          currentTurnIndex >= lastCompressibleTurnIndex) {
        return false;
      }
      final nextTurn = turns[currentTurnIndex + 1];
      if (nextTurn.messages.isEmpty) return false;
      newPruneStartId = nextTurn.messages.first.id;
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    // 可观测性：记录压缩指标
    final beforeTokens = _estimateMessagesTotalCached(allMessages);
    final pruneStartIdx = allMessages.indexWhere(
      (m) => m.id == newPruneStartId,
    );
    final prunedCount = pruneStartIdx >= 0 ? pruneStartIdx : 0;
    final turnsRetained = oldTurns.length - cutIndex + recentTurnsCount;

    // 更新 SessionHistory 压缩状态
    session.pruneStartId = newPruneStartId;
    session.messagesSinceCompression = 0;
    session.lastCompressionTime = now;

    // 持久化到 DB
    if (compressionMetaStore != null && deviceId != null) {
      compressionMetaStore!.saveMeta(
        CompressionMetaEntity(
          employeeId: employeeId,
          deviceId: deviceId!,
          pruneStartId: newPruneStartId,
          lastCompressionTime: now,
          messagesSinceCompression: 0,
          updateTime: now,
        ),
      );
    }

    // 清除 buildCompressedMessages 缓存
    _invalidateBuildCache();

    _log.info(
      '压缩完成: employeeId=$employeeId, '
      'pruneStartId=$newPruneStartId, '
      'cutIndex=$cutIndex/${oldTurns.length}, '
      'beforeTokens=$beforeTokens, '
      'recentTurns=$recentTurnsCount, '
      'turnsRetained=$turnsRetained, '
      'prunedMessages=$prunedCount',
    );

    return true;
  }

  /// 构建压缩后的消息列表（同步）
  ///
  /// 在 tool calling loop 的每次迭代中调用。
  /// 基于 [SessionHistory.pruneStartId] 决定哪些消息保留。
  ///
  /// - pruneStartId 之前的消息：完全丢弃，注入本地摘要
  /// - pruneStartId 及之后的消息：保留，但旧工具结果可能被截断
  List<ChatMessage> buildCompressedMessages({
    required String employeeId,
    required List<ChatMessage> allMessages,
    required SessionHistory session,
    String? systemPrompt,
  }) {
    if (!config.enabled || allMessages.isEmpty) {
      return _buildFullMessages(allMessages, systemPrompt);
    }

    final budget = config.effectiveBudget;
    if (budget <= 0) {
      return _buildFullMessages(allMessages, systemPrompt);
    }

    // 检查缓存是否有效
    final pruneId = session.pruneStartId;
    final pruneStartIdx = pruneId.isNotEmpty
        ? allMessages.indexWhere((m) => m.id == pruneId)
        : -1;
    final currentGeneration = allMessages.length * 10000 + pruneStartIdx;
    if (_cachedCompressed != null && _cacheGeneration == currentGeneration) {
      return _cachedCompressed!;
    }

    final result = <ChatMessage>[];

    // 1. 系统提示
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      result.add(
        ChatMessage.system(
          id: '',
          employeeId: employeeId,
          content: systemPrompt,
        ),
      );
    }

    // 2. 收集被省略的消息，生成本地摘要
    List<ChatMessage> omittedMessages = const [];
    if (pruneStartIdx > 0) {
      omittedMessages = allMessages.sublist(0, pruneStartIdx);
    }

    if (omittedMessages.isNotEmpty) {
      final summary = _buildLocalSummary(omittedMessages);
      result.add(
        ChatMessage.system(id: '', employeeId: employeeId, content: summary),
      );
    }

    // 3. 计算最近轮次的 seq 阈值（用于 toolResultMaxChars 截断）
    final recentSeqThreshold = _computeRecentSeqThresholdById(
      allMessages,
      pruneStartIdx,
    );

    // 4. 遍历消息：保留 pruneStartId 及之后的消息
    for (var i = 0; i < allMessages.length; i++) {
      if (pruneStartIdx >= 0 && i < pruneStartIdx) {
        continue; // 跳过被省略的消息
      }

      final msg = allMessages[i];
      // 对保留区内但非最近轮次的 tool result 做截断
      if (msg.role == MessageRole.tool && recentSeqThreshold > 0) {
        final truncated = _truncateToolResult(msg, recentSeqThreshold);
        result.add(truncated);
      } else {
        result.add(msg);
      }
    }

    // 5. 对保留区内超长工具结果做截断（防止单轮工具调用过多导致溢出）
    _truncateLargeToolResults(result, recentSeqThreshold);

    // 6. 合并连续的 tool result 消息（与非压缩路径 buildMessages 保持一致）
    final merged = LlmMessageMapper.mergeConsecutiveToolResults(result);

    // 7. 修复压缩边界处的 tool_call/tool_result 配对问题
    _ensureToolCallResultPairs(merged);

    // 更新缓存
    _cachedCompressed = merged;
    _cacheGeneration = currentGeneration;

    return merged;
  }

  /// 生成本地摘要（不调用 LLM）
  ///
  /// 从被压缩消息中提取 user 消息意图，格式化为结构化摘要。
  String _buildLocalSummary(List<ChatMessage> omittedMessages) {
    final buffer = StringBuffer();
    buffer.writeln('## 早期对话摘要');
    buffer.writeln('共省略 ${omittedMessages.length} 条消息。');

    // 提取用户历史意图
    final userIntents = omittedMessages
        .where((m) => m.role == MessageRole.user)
        .map((m) {
          final content = m.content ?? '';
          return content.length > 100
              ? '${content.substring(0, 100)}...'
              : content;
        })
        .toList();

    if (userIntents.isNotEmpty) {
      buffer.writeln('### 用户历史意图：');
      for (var i = 0; i < userIntents.length; i++) {
        buffer.writeln('${i + 1}. ${userIntents[i]}');
      }
    }

    // 提取关键 AI 结论（assistant 消息中有实质内容的）
    final aiConclusions = omittedMessages
        .where(
          (m) =>
              m.role == MessageRole.assistant &&
              m.toolCalls == null &&
              (m.content ?? '').trim().isNotEmpty,
        )
        .map((m) {
          final content = m.content!.trim();
          return content.length > 80
              ? '${content.substring(0, 80)}...'
              : content;
        })
        .toList();

    if (aiConclusions.isNotEmpty) {
      buffer.writeln('### AI 历史回复要点：');
      // 最多保留 5 条，避免摘要过长
      final displayConclusions = aiConclusions.length > 5
          ? aiConclusions.sublist(0, 5)
          : aiConclusions;
      for (var i = 0; i < displayConclusions.length; i++) {
        buffer.writeln('${i + 1}. ${displayConclusions[i]}');
      }
      if (aiConclusions.length > 5) {
        buffer.writeln('...（共 ${aiConclusions.length} 条，仅显示前 5 条）');
      }
    }

    buffer.writeln('如需查看完整历史，可使用 query_conversation_history 工具。');
    return buffer.toString();
  }

  /// 计算最近轮次的 seq 阈值（基于 index）
  ///
  /// 返回最近 N 个轮次（recentTurnsKeep）中最早消息的 seq。
  /// seq < 此阈值的 tool result 会被 toolResultMaxChars 截断。
  int _computeRecentSeqThresholdById(
    List<ChatMessage> allMessages,
    int pruneStartIdx,
  ) {
    if (pruneStartIdx < 0) return 0;

    final retainedMessages = allMessages.sublist(pruneStartIdx);
    if (retainedMessages.isEmpty) return 0;

    final turns = groupIntoTurns(retainedMessages);
    if (turns.length <= config.recentTurnsKeep) return 0;

    final recentTurns = turns.sublist(turns.length - config.recentTurnsKeep);
    return recentTurns.first.messages.first.seq;
  }

  /// 对保留区内但非最近轮次的 tool result 做 toolResultMaxChars 截断
  ChatMessage _truncateToolResult(ChatMessage msg, int recentSeqThreshold) {
    if (recentSeqThreshold <= 0 || msg.seq >= recentSeqThreshold) {
      return msg;
    }

    // 对非最近轮次的 tool result 做 toolResultMaxChars 截断
    if (msg.isToolResultGroup) {
      // 分组格式：截断每个 result 的内容
      final truncatedResults = msg.toolResults!.map((r) {
        if (r.content.length > config.toolResultMaxChars) {
          return ToolResult(
            toolCallId: r.toolCallId,
            content:
                '${r.content.substring(0, config.toolResultMaxChars)}...(truncated, total ${r.content.length} chars)',
            isError: r.isError,
            name: r.name,
          );
        }
        return r;
      }).toList();
      return msg.copyWith(toolResults: truncatedResults);
    } else {
      final content = msg.content ?? '';
      if (content.length > config.toolResultMaxChars) {
        return msg.copyWith(
          content:
              '${content.substring(0, config.toolResultMaxChars)}...(truncated, total ${content.length} chars)',
        );
      }
    }
    return msg;
  }

  /// 对保留区内的超长 tool_result 进行截断
  ///
  /// 防止单轮工具调用过多导致压缩失效。
  /// 使用更宽松的阈值 _maxToolResultCharsInContext（2000 字符）。
  void _truncateLargeToolResults(
    List<ChatMessage> messages,
    int recentSeqThreshold,
  ) {
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (msg.role != MessageRole.tool) continue;

      // 最近轮次内的消息不做截断
      if (recentSeqThreshold > 0 && msg.seq >= recentSeqThreshold) continue;

      if (msg.isToolResultGroup) {
        bool modified = false;
        final truncatedResults = msg.toolResults!.map((r) {
          if (r.content.length > _maxToolResultCharsInContext) {
            modified = true;
            return ToolResult(
              toolCallId: r.toolCallId,
              content:
                  '${r.content.substring(0, _maxToolResultCharsInContext)}\n'
                  '...[截断: 共${r.content.length}字符，'
                  '使用 query_conversation_history 查看完整内容]',
              isError: r.isError,
              name: r.name,
            );
          }
          return r;
        }).toList();
        if (modified) {
          messages[i] = msg.copyWith(toolResults: truncatedResults);
        }
      } else {
        final content = msg.content ?? '';
        if (content.length > _maxToolResultCharsInContext) {
          messages[i] = msg.copyWith(
            content:
                '${content.substring(0, _maxToolResultCharsInContext)}\n'
                '...[截断: 共${content.length}字符，'
                '使用 query_conversation_history 查看完整内容]',
          );
        }
      }
    }
  }

  /// 确保 tool_call / tool_result 严格配对
  ///
  /// 压缩边界可能将 assistant(toolCalls) 和对应的 tool_result 拆到不同区域，
  /// 导致 Anthropic 等 API 报 "unexpected tool_use_id" 错误。
  static void _ensureToolCallResultPairs(List<ChatMessage> result) {
    if (result.length < 2) return;

    final toRemove = <int>{};
    final toStrip = <int>{};

    Set<String>? prevToolCallIds;
    int? prevAssistantIdx;

    for (var i = 0; i < result.length; i++) {
      final msg = result[i];

      if (msg.role == MessageRole.assistant &&
          msg.toolCalls != null &&
          msg.toolCalls!.isNotEmpty) {
        if (prevToolCallIds != null &&
            prevToolCallIds.isNotEmpty &&
            prevAssistantIdx != null &&
            !toStrip.contains(prevAssistantIdx)) {
          toStrip.add(prevAssistantIdx);
        }
        prevToolCallIds = msg.toolCalls!.map((tc) => tc.id).toSet();
        prevAssistantIdx = i;
      } else if (msg.role == MessageRole.tool) {
        if (prevToolCallIds == null || prevToolCallIds.isEmpty) {
          toRemove.add(i);
        } else {
          final ids = prevToolCallIds;
          final matchIds = msg.isToolResultGroup
              ? msg.toolResults!
                    .where((r) => ids.contains(r.toolCallId))
                    .map((r) => r.toolCallId)
                    .toSet()
              : (ids.contains(msg.toolCallId ?? '')
                    ? {msg.toolCallId ?? ''}
                    : <String>{});

          if (matchIds.isEmpty) {
            toRemove.add(i);
          } else {
            for (final id in matchIds) {
              prevToolCallIds.remove(id);
            }
          }
        }
      } else {
        if (prevToolCallIds != null &&
            prevToolCallIds.isNotEmpty &&
            prevAssistantIdx != null &&
            !toStrip.contains(prevAssistantIdx)) {
          toStrip.add(prevAssistantIdx);
        }
        prevToolCallIds = null;
        prevAssistantIdx = null;
      }
    }

    if (prevToolCallIds != null &&
        prevToolCallIds.isNotEmpty &&
        prevAssistantIdx != null &&
        !toStrip.contains(prevAssistantIdx)) {
      toStrip.add(prevAssistantIdx);
    }

    for (final idx in toStrip) {
      _stripAssistantToolCallsInList(result, idx);
    }
    if (toRemove.isNotEmpty) {
      final sorted = toRemove.toList()..sort((a, b) => b.compareTo(a));
      for (final idx in sorted) {
        if (idx >= 0 && idx < result.length) {
          result.removeAt(idx);
        }
      }
    }
  }

  /// 在消息列表中 strip 指定索引处 assistant 消息的 toolCalls
  static void _stripAssistantToolCallsInList(
    List<ChatMessage> result,
    int index,
  ) {
    if (index < 0 || index >= result.length) return;
    final msg = result[index];
    if (msg.role != MessageRole.assistant ||
        msg.toolCalls == null ||
        msg.toolCalls!.isEmpty) {
      return;
    }
    final content = msg.content;
    final toolSummary = msg.toolCalls!
        .map((tc) {
          final args = tc.arguments;
          String argsPreview;
          if (args.length <= 3) {
            argsPreview = args.entries
                .map((e) => '${e.key}=${e.value}')
                .join(', ');
          } else {
            argsPreview = args.entries
                .take(3)
                .map((e) => '${e.key}=${e.value}')
                .join(', ');
            argsPreview += ', ...(共${args.length}个参数)';
          }
          return '${tc.name}($argsPreview)';
        })
        .join('; ');
    final inlineNote = '[已调用工具: $toolSummary，但结果因上下文压缩被移除，请勿重复调用]';

    final newContent = (content == null || content.trim().isEmpty)
        ? inlineNote
        : '$content\n$inlineNote';

    result[index] = msg.copyWith(
      clearToolCalls: true,
      type: 'text',
      content: newContent,
    );
  }

  /// 清除所有锁和缓存（会话销毁时调用）
  void dispose() {
    _sessionLocks.clear();
    _tokenCache.clear();
    _cachedCompressed = null;
    _cacheGeneration = -1;
  }

  // ===== Token 估算缓存 =====

  /// 带缓存的消息 token 估算
  int _estimateMessagesTotalCached(List<ChatMessage> messages) {
    var total = 0;
    for (final message in messages) {
      total += _estimateMessageTokensCached(message);
    }
    total += 3; // 请求 overhead
    return total;
  }

  /// 带缓存的单条消息 token 估算
  int _estimateMessageTokensCached(ChatMessage message) {
    if (message.id.isEmpty) {
      return _estimator.estimateMessageTokens(message);
    }
    return _tokenCache.putIfAbsent(
      message.id,
      () => _estimator.estimateMessageTokens(message),
    );
  }

  /// 使 buildCompressedMessages 缓存失效
  void _invalidateBuildCache() {
    _cachedCompressed = null;
    _cacheGeneration = -1;
  }

  // ===== 消息轮次分组 =====

  /// 将消息列表分组为对话轮次
  static List<MessageTurn> groupIntoTurns(List<ChatMessage> messages) {
    if (messages.isEmpty) return [];

    final turns = <MessageTurn>[];
    var currentStart = 0;
    var currentMessages = <ChatMessage>[];

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];

      if (msg.role == MessageRole.user && currentMessages.isNotEmpty) {
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

  // ===== 辅助方法 =====

  /// 不压缩的全量消息构建
  List<ChatMessage> _buildFullMessages(
    List<ChatMessage> allMessages,
    String? systemPrompt,
  ) {
    final result = <ChatMessage>[];
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      result.add(
        ChatMessage.system(id: '', employeeId: '', content: systemPrompt),
      );
    }
    result.addAll(allMessages);
    return result;
  }
}
