/// ChatMessage ↔ llm_dart 转换器
///
/// 将统一消息模型转换为 llm_dart 库所需的格式，
/// 同时保留合并连续 tool result 的逻辑。
library;

import 'dart:convert';

import 'package:llm_dart/llm_dart.dart' as llm;

import '../agent/adapter/provider_config.dart';
import '../utils/logger.dart';
import 'chat_message.dart';
import 'message_sequence_report.dart';

final _log = Logger('LlmMessageMapper');

/// 内部辅助类：tool_result 消息信息
///
/// 用于 _validateStrictSequence 中收集和匹配 tool_result 与 assistant(toolCalls) 的关系。
class _ToolResultInfo {
  final String toolCallId;
  final ChatMessage msg;
  final ToolResult? result; // 分组中的单个 result（单条 tool result 时为 null）
  final int sourceIndex;
  final int resultIndex;

  const _ToolResultInfo({
    required this.toolCallId,
    required this.msg,
    required this.sourceIndex,
    required this.resultIndex,
    this.result,
  });
}

/// ChatMessage 与 llm_dart ChatMessage 的双向映射器
///
/// 职责：
/// 1. ChatMessage → llm.ChatMessage（发送给 LLM 前）
/// 2. llm.ChatMessage → ChatMessage（收到 LLM 响应后）
/// 3. 合并连续 tool result 消息（OpenAI 兼容性）
class LlmMessageMapper {
  // ── ChatMessage → llm_dart ──

  /// 将 ChatMessage 转换为 llm_dart 的 ChatMessage
  ///
  /// [provider] 可选的 LLM 提供商类型，用于决定是否回传 thinking 内容。
  /// DeepSeek 等提供商要求 reasoning_content 必须回传，Anthropic 通过 extension 回传。
  static llm.ChatMessage toLlmDart(ChatMessage msg, {LLMProvider? provider}) {
    switch (msg.role) {
      case MessageRole.user:
        return llm.ChatMessage.user(msg.content ?? '');

      case MessageRole.assistant:
        // 包含多工具调用
        if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
          // 防御性校验：过滤掉 name 为空的 ToolCall
          final validToolCalls = msg.toolCalls!
              .where((tc) => tc.name.trim().isNotEmpty)
              .toList();
          if (validToolCalls.isNotEmpty) {
            final toolUseMsg = llm.ChatMessage.toolUse(
              toolCalls: validToolCalls
                  .map(
                    (tc) => llm.ToolCall(
                      id: tc.id,
                      callType: 'function',
                      function: llm.FunctionCall(
                        name: tc.name,
                        arguments: tc.argumentsJson,
                      ),
                    ),
                  )
                  .toList(),
              content: msg.content ?? '',
            );
            // 回传 thinking 内容
            if (msg.thinking != null && msg.thinking!.isNotEmpty) {
              return _attachThinking(toolUseMsg, msg.thinking!, provider);
            }
            return toolUseMsg;
          } else {
            _log.warn(
              'toLlmDart: assistant 消息的所有 toolCall name 为空，降级为纯文本 (id=${msg.id})',
            );
            return _buildAssistantMessageWithThinking(msg, provider: provider);
          }
        }
        // 包含单工具调用（向后兼容）
        if (msg.toolCallId != null && msg.toolName != null) {
          // 防御性校验：name 为空时降级为纯文本
          if (msg.toolName!.trim().isEmpty) {
            _log.warn('toLlmDart: 单工具调用的 toolName 为空，降级为纯文本 (id=${msg.id})');
            return _buildAssistantMessageWithThinking(msg, provider: provider);
          }
          final argsJson = msg.toolArguments != null
              ? jsonEncode(msg.toolArguments)
              : '{}';
          final toolUseMsg = llm.ChatMessage.toolUse(
            toolCalls: [
              llm.ToolCall(
                id: msg.toolCallId!,
                callType: 'function',
                function: llm.FunctionCall(
                  name: msg.toolName!,
                  arguments: argsJson,
                ),
              ),
            ],
            content: msg.content ?? '',
          );
          // 回传 thinking 内容
          if (msg.thinking != null && msg.thinking!.isNotEmpty) {
            return _attachThinking(toolUseMsg, msg.thinking!, provider);
          }
          return toolUseMsg;
        }
        return _buildAssistantMessageWithThinking(msg, provider: provider);

      case MessageRole.system:
        return llm.ChatMessage.system(msg.content ?? '');

      case MessageRole.tool:
        if (msg.isToolResultGroup) {
          // 分组 tool result：将多个 ToolResult 合并为一条 llm.ChatMessage.toolResult
          final results = msg.toolResults!.map((r) {
            final resultArguments = r.isError
                ? jsonEncode({'error': r.content})
                : jsonEncode({'result': r.content});
            return llm.ToolCall(
              id: r.toolCallId,
              callType: 'function',
              function: llm.FunctionCall(
                name: r.name?.isNotEmpty == true ? r.name! : 'unknown',
                arguments: resultArguments,
              ),
            );
          }).toList();
          return llm.ChatMessage.toolResult(
            results: results,
            content: msg.toolResults!.map((r) => r.content).join('\n'),
          );
        }
        // 单条 tool result
        final resultArguments = msg.isError
            ? jsonEncode({'error': msg.content ?? ''})
            : jsonEncode({'result': msg.content ?? ''});
        // 防御性校验：确保 name 不为空
        final toolName = msg.toolName?.isNotEmpty == true
            ? msg.toolName!
            : 'unknown';
        final toolCallId = msg.toolCallId?.isNotEmpty == true
            ? msg.toolCallId!
            : '';
        return llm.ChatMessage.toolResult(
          results: [
            llm.ToolCall(
              id: toolCallId,
              callType: 'function',
              function: llm.FunctionCall(
                name: toolName,
                arguments: resultArguments,
              ),
            ),
          ],
          content: msg.content ?? '',
        );
    }
  }

  /// 批量转换 ChatMessage → llm_dart
  ///
  /// 会自动过滤掉空内容的 assistant 消息（既无 content 也无 tool_calls），
  /// 避免触发 API 错误 "assistant message must not be empty"。
  ///
  /// [provider] 可选的 LLM 提供商类型，用于决定 thinking 内容的回传方式。
  static List<llm.ChatMessage> toLlmDartList(
    List<ChatMessage> messages, {
    LLMProvider? provider,
  }) {
    final result = <llm.ChatMessage>[];
    for (final msg in messages) {
      // 跳过空内容的 assistant 消息（既无文本也无工具调用）
      // 但保留有 thinking 内容的消息，因为 DeepSeek 等提供商要求 reasoning_content
      // 在多轮对话中必须回传（"The reasoning_content in the thinking mode must be
      // passed back to the API"）
      if (msg.role == MessageRole.assistant) {
        final hasContent =
            msg.content != null && msg.content!.trim().isNotEmpty;
        final hasToolCalls = msg.toolCalls != null && msg.toolCalls!.isNotEmpty;
        final hasLegacyToolCall =
            msg.toolCallId != null && msg.toolName != null;
        final hasThinking =
            msg.thinking != null && msg.thinking!.trim().isNotEmpty;
        if (!hasContent &&
            !hasToolCalls &&
            !hasLegacyToolCall &&
            !hasThinking) {
          _log.warn('toLlmDartList: 跳过空 assistant 消息 (id=${msg.id})');
          continue;
        }
        // Debug: log assistant messages with thinking
        if (hasThinking) {
          _log.debug(
            'toLlmDartList: assistant 消息有 thinking (${msg.thinking!.length} chars), '
            'hasContent=$hasContent, hasToolCalls=$hasToolCalls, provider=$provider',
          );
        }
      }
      result.add(toLlmDart(msg, provider: provider));
    }
    return result;
  }

  // ── llm_dart → ChatMessage ──

  /// 从 llm_dart ChatMessage 创建 ChatMessage
  ///
  /// [employeeId] 必须由调用方提供。
  /// [id] 如果为 null 则自动生成。
  static ChatMessage fromLlmDart(
    llm.ChatMessage msg, {
    required String employeeId,
    String? id,
  }) {
    switch (msg.role) {
      case llm.ChatRole.user:
        return ChatMessage.user(
          id: id ?? '',
          employeeId: employeeId,
          content: msg.content,
        );

      case llm.ChatRole.assistant:
        // 检查是否是 tool_use 类型
        if (msg.messageType is llm.ToolUseMessage) {
          final toolUse = msg.messageType as llm.ToolUseMessage;
          return ChatMessage.assistant(
            id: id ?? '',
            employeeId: employeeId,
            content: msg.content,
            toolCalls: toolUse.toolCalls
                .map(
                  (tc) => ToolCall(
                    id: tc.id,
                    name: tc.function.name,
                    arguments: _parseArguments(tc.function.arguments),
                  ),
                )
                .toList(),
          );
        }
        return ChatMessage.assistant(
          id: id ?? '',
          employeeId: employeeId,
          content: msg.content,
        );

      case llm.ChatRole.system:
        return ChatMessage.system(
          id: id ?? '',
          employeeId: employeeId,
          content: msg.content,
          createdAt: DateTime.now(),
        );
    }
  }

  /// 从 llm_dart ChatResponse 创建 assistant ChatMessage（流式完成时）
  static ChatMessage fromLlmDartResponse(
    llm.ChatResponse response, {
    required String employeeId,
    String? id,
  }) {
    return ChatMessage.assistant(
      id: id ?? '',
      employeeId: employeeId,
      content: response.text ?? '',
      toolCalls: response.toolCalls
          ?.map(
            (tc) => ToolCall(
              id: tc.id,
              name: tc.function.name,
              arguments: _parseArguments(tc.function.arguments),
            ),
          )
          .toList(),
    );
  }

  // ── 连续 tool result 合并 ──

  /// 将连续的 tool 角色消息合并为分组消息
  ///
  /// 在 OpenAI 协议中，一轮 assistant tool_calls 后跟的多个 tool result
  /// 应作为一组传递，确保 tool_call_id 对应关系正确。
  /// 与原 SessionMemoryManager._mergeConsecutiveToolMessages 逻辑一致。
  static List<ChatMessage> mergeConsecutiveToolResults(
    List<ChatMessage> messages,
  ) {
    if (messages.isEmpty) return messages;

    final result = <ChatMessage>[];
    List<ToolResult>? pendingResults;

    for (final msg in messages) {
      if (msg.role == MessageRole.tool && !msg.isToolResultGroup) {
        // 单条 tool result → 加入待合并缓冲区
        pendingResults ??= [];
        pendingResults.add(
          ToolResult(
            toolCallId: msg.toolCallId ?? '',
            content: msg.content ?? '',
            isError: msg.isError,
            name: msg.toolName,
          ),
        );
      } else {
        // 非 tool 消息 → 先刷新缓冲区
        if (pendingResults != null) {
          result.add(
            ChatMessage.toolResultGroup(
              id: pendingResults.first.toolCallId.isEmpty
                  ? ''
                  : pendingResults.first.toolCallId,
              employeeId: '',
              results: pendingResults,
            ),
          );
          pendingResults = null;
        }
        result.add(msg);
      }
    }

    // 刷新末尾剩余的 tool results
    if (pendingResults != null) {
      result.add(
        ChatMessage.toolResultGroup(
          id: '',
          employeeId: '',
          results: pendingResults,
        ),
      );
    }

    return result;
  }

  // ── 消息序列校验 ──

  /// 校验并修复消息序列，确保每个 tool result 都能匹配到前述 assistant 的 tool_call_id
  ///
  /// 在消息发送给 LLM 前调用。处理以下异常场景：
  /// - 异步工具执行期间消息注入导致的顺序错乱
  /// - alreadyCallsSet 跳过执行但 assistant 消息已记录
  /// - 上下文压缩后保留孤立 tool result
  ///
  /// [knownToolCallIds] 可选的跨轮次累积 tool_call_id 集合，用于多轮 tool calling 场景。
  /// 当提供时，tool_result 只要在 knownToolCallIds 中即可保留，无需匹配最近一轮。
  ///
  /// [strictMode] 严格模式，适用于 Anthropic 等要求 tool_result 必须匹配**紧邻前一条**
  /// assistant 消息的 tool_use blocks 的提供商。
  /// - `true`：执行两阶段处理：
  ///   1. 阶段一（sanitize）：使用 [knownToolCallIds] 进行跨轮次匹配，保留有效的 tool_result
  ///   2. 阶段二（validate）：验证最终序列中每个 tool_result 的 tool_use_id 在紧邻的前一条
  ///      assistant 消息中存在，不满足则 strip 或丢弃
  /// - `false`（默认）：使用 [knownToolCallIds] 进行跨轮次累积匹配（OpenAI 兼容行为）。
  static List<ChatMessage> sanitizeForLlm(
    List<ChatMessage> messages, {
    Set<String>? knownToolCallIds,
    bool strictMode = false,
  }) {
    if (messages.isEmpty) return messages;

    // 判断是否启用跨轮次累积匹配模式
    // 注意：即使在 strictMode 下，knownToolCallIds 也用于阶段一的跨轮次匹配
    // 阶段二仍会执行紧邻验证，确保 Anthropic API 要求得到满足
    final useKnownIds = knownToolCallIds != null && knownToolCallIds.isNotEmpty;

    final result = <ChatMessage>[];
    final expectedIds = <String>{};

    for (final msg in messages) {
      if (msg.role == MessageRole.assistant &&
          msg.toolCalls != null &&
          msg.toolCalls!.isNotEmpty) {
        // 如果之前有未匹配的 tool_call_id
        if (expectedIds.isNotEmpty) {
          if (useKnownIds) {
            // 跨轮次模式：不清除上一轮的 toolCalls，保留所有 assistant(toolCalls)
            // 因为 knownToolCallIds 保证所有 tool_call_id 都已知，tool_result 可匹配任一轮次
            _log.debug(
              'sanitizeForLlm: 跨轮次模式，保留之前未匹配的 expectedIds=$expectedIds, '
              '新增 toolCallIds=${msg.toolCalls!.map((tc) => tc.id).toList()}',
            );
          } else {
            // 严格模式 / 旧行为：清除上一条 assistant 的 toolCalls
            _log.warn(
              'sanitizeForLlm: 新 assistant(toolCalls) 但有未匹配的 expectedIds=$expectedIds, '
              '新 toolCallIds=${msg.toolCalls!.map((tc) => tc.id).toList()}, '
              'strictMode=$strictMode, 触发 _stripLastAssistantToolCalls',
            );
            _stripLastAssistantToolCalls(result);
            expectedIds.clear();
          }
        }
        // 记录本轮所有 tool_call_id
        for (final tc in msg.toolCalls!) {
          expectedIds.add(tc.id);
        }
        result.add(msg);
      } else if (msg.role == MessageRole.tool) {
        if (msg.isToolResultGroup) {
          // 分组 tool result：只保留 expectedIds 或 knownToolCallIds 中存在的
          final validResults = msg.toolResults!
              .where(
                (r) =>
                    expectedIds.contains(r.toolCallId) ||
                    (useKnownIds && knownToolCallIds.contains(r.toolCallId)),
              )
              .toList();
          for (final r in validResults) {
            expectedIds.remove(r.toolCallId);
          }
          if (validResults.isEmpty) {
            _log.warn(
              'sanitizeForLlm: 丢弃孤立 tool result group (无匹配 toolCallId)',
            );
            continue;
          }
          if (validResults.length == msg.toolResults!.length) {
            result.add(msg);
          } else {
            _log.warn(
              'sanitizeForLlm: 部分 tool result 孤立，保留 ${validResults.length}/${msg.toolResults!.length} 条',
            );
            result.add(
              ChatMessage.toolResultGroup(
                id: msg.id,
                employeeId: msg.employeeId,
                results: validResults,
                createdAt: msg.createdAt,
                deviceId: msg.deviceId,
              ),
            );
          }
        } else {
          // 单条 tool result
          final toolCallId = msg.toolCallId ?? '';
          final isValid =
              expectedIds.contains(toolCallId) ||
              (useKnownIds && knownToolCallIds.contains(toolCallId));
          if (toolCallId.isEmpty || !isValid) {
            _log.warn(
              'sanitizeForLlm: 丢弃孤立 tool result (toolCallId=$toolCallId)',
            );
            continue;
          }
          expectedIds.remove(toolCallId);
          result.add(msg);
        }
      } else {
        // user / system 等非 tool 消息
        if (expectedIds.isNotEmpty) {
          if (useKnownIds) {
            // 跨轮次模式：不干预，保留未匹配的 expectedIds
            // 因为 tool_result 可能出现在后续消息中
            _log.debug(
              'sanitizeForLlm: 跨轮次模式，遇到 ${msg.role} 消息时保留未匹配的 expectedIds=$expectedIds',
            );
          } else {
            // 严格模式 / 旧行为：清除上一条 assistant 的 toolCalls
            _log.warn(
              'sanitizeForLlm: 遇到 ${msg.role} 消息但有未匹配的 toolCallIds=$expectedIds, '
              'msgId=${msg.id}, content=${_truncate(msg.content ?? '', 60)}, '
              'strictMode=$strictMode, 触发 _stripLastAssistantToolCalls',
            );
            _stripLastAssistantToolCalls(result);
            expectedIds.clear();
          }
        }
        result.add(msg);
      }
    }

    // 序列末尾：处理残留未匹配的 expectedIds
    if (expectedIds.isNotEmpty && !useKnownIds) {
      _log.warn(
        'sanitizeForLlm: 序列末尾仍有未匹配的 toolCallIds=$expectedIds, '
        '总消息数=${messages.length}, strictMode=$strictMode, 触发 _stripLastAssistantToolCalls',
      );
      _stripLastAssistantToolCalls(result);
    }

    // ═══════════════════════════════════════════
    // 阶段二：验证最终序列中每个 tool_result 的 tool_use_id
    // 必须在紧邻的前一条 assistant 消息的 tool_use blocks 中存在
    //
    // 始终执行此验证（不仅限于 strictMode），因为：
    // - Anthropic API 严格要求紧邻配对
    // - OpenAI 兼容 API 通常也能接受紧邻配对
    // - 跨轮次匹配仅在阶段一使用 knownToolCallIds 时保留 tool_result，
    //   但最终输出仍需满足紧邻要求，否则 Anthropic 会报
    //   "unexpected tool_use_id found in tool_result blocks" 错误
    // ═══════════════════════════════════════════
    return _validateStrictSequence(result);
  }

  /// strictMode 阶段二：验证消息序列中每个 tool_result 的 tool_use_id
  /// 必须在紧邻的前一条 assistant(toolCalls) 消息中存在。
  ///
  /// 核心策略：**重排而非丢弃**。
  ///
  /// 当遇到 assistant(toolCalls) → user/system → tool_result 的序列时，
  /// 将 tool_result **提前**到 user/system 消息之前，确保 Anthropic API 的
  /// 紧邻配对要求得到满足，同时不丢失任何 tool_result 数据。
  ///
  /// 仅在以下情况才 strip/discard：
  /// - 序列末尾有未配对的 assistant(toolCalls)（无后续 tool_result 可等待）
  /// - 孤立的 tool_result（无任何前序 assistant(toolCalls) 可匹配）
  static List<ChatMessage> _validateStrictSequence(List<ChatMessage> messages) {
    // 第一遍：收集 assistant(toolCalls) 和 tool_result 之间的配对关系
    // 然后重排消息序列，确保每个 tool_result 紧跟其对应的 assistant(toolCalls)

    // 收集所有 tool_result 并记录它们对应的 toolCallId
    final toolResultInfos = <_ToolResultInfo>[];
    for (var sourceIndex = 0; sourceIndex < messages.length; sourceIndex++) {
      final msg = messages[sourceIndex];
      if (msg.role == MessageRole.tool) {
        if (msg.isToolResultGroup) {
          for (
            var resultIndex = 0;
            resultIndex < msg.toolResults!.length;
            resultIndex++
          ) {
            final r = msg.toolResults![resultIndex];
            toolResultInfos.add(
              _ToolResultInfo(
                toolCallId: r.toolCallId,
                msg: msg,
                sourceIndex: sourceIndex,
                resultIndex: resultIndex,
                result: r,
              ),
            );
          }
        } else {
          toolResultInfos.add(
            _ToolResultInfo(
              toolCallId: msg.toolCallId ?? '',
              msg: msg,
              sourceIndex: sourceIndex,
              resultIndex: 0,
              result: null,
            ),
          );
        }
      }
    }

    // 建立 toolCallId → tool_result 消息的映射
    final toolCallIdToResults = <String, List<_ToolResultInfo>>{};
    for (final info in toolResultInfos) {
      toolCallIdToResults.putIfAbsent(info.toolCallId, () => []).add(info);
    }

    // 第二遍：构建重排后的消息序列
    final result = <ChatMessage>[];
    final usedToolCallIds = <String>{};
    final usedToolResultKeys = <String>{}; // 已处理过的 tool result 条目

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];

      if (msg.role == MessageRole.assistant &&
          msg.toolCalls != null &&
          msg.toolCalls!.isNotEmpty) {
        // 收集本轮所有 toolCallId
        final roundToolCallIds = <String>{};
        for (final tc in msg.toolCalls!) {
          roundToolCallIds.add(tc.id);
        }

        // 查找属于本轮的 tool_result（按原始消息顺序）
        final roundResultInfos = <_ToolResultInfo>[];
        final matchedIds = <String>{};

        for (final tcId in roundToolCallIds) {
          final results = toolCallIdToResults[tcId];
          if (results != null && results.isNotEmpty) {
            var matched = false;
            for (final info in results) {
              if (!usedToolResultKeys.contains(_toolResultKey(info))) {
                roundResultInfos.add(info);
                matched = true;
              }
            }
            if (matched) {
              matchedIds.add(tcId);
            }
          }
        }

        // 添加 assistant 消息
        // 如果有未匹配的 toolCalls（没有对应的 tool_result），strip 它们
        final unmatchedIds = roundToolCallIds.difference(matchedIds);
        if (unmatchedIds.isNotEmpty && matchedIds.isEmpty) {
          // 全部未匹配 → strip 所有 toolCalls，转为纯文本 assistant 消息
          _log.warn(
            '_validateStrictSequence: assistant(toolCalls) 全部未匹配 '
            'tool_use_ids=$roundToolCallIds，strip 所有 toolCalls',
          );
          // 先添加消息，再 strip
          result.add(msg);
          _stripAssistantToolCallsAt(result, result.length - 1);
          // 不需要添加 tool_result（因为没有匹配的）
        } else if (unmatchedIds.isNotEmpty) {
          // 部分匹配 → 仅保留已匹配的 toolCalls，strip 未匹配的
          _log.warn(
            '_validateStrictSequence: assistant(toolCalls) 部分未匹配 '
            'matched=$matchedIds, unmatched=$unmatchedIds，strip 未匹配的 toolCalls',
          );
          // 先添加 assistant 消息（后续会修改）
          result.add(msg);
          _stripUnmatchedToolCallsAt(result, result.length - 1, unmatchedIds);
          // 添加匹配的 tool_results
          result.addAll(
            _consumeToolResultInfos(roundResultInfos, usedToolResultKeys),
          );
        } else {
          // 全部匹配 → 正常添加
          result.add(msg);
          // 添加 tool_results
          result.addAll(
            _consumeToolResultInfos(roundResultInfos, usedToolResultKeys),
          );
        }

        for (final tcId in matchedIds) {
          usedToolCallIds.add(tcId);
        }
      } else if (msg.role == MessageRole.tool) {
        // tool_result：仅添加尚未被提前消费的
        if (!_allToolResultsConsumed(msg, i, usedToolResultKeys)) {
          // 检查是否为孤立 tool_result（没有对应的 assistant(toolCalls)）
          bool hasMatchingAssistant = false;
          if (msg.isToolResultGroup) {
            for (final r in msg.toolResults!) {
              if (usedToolCallIds.contains(r.toolCallId)) {
                hasMatchingAssistant = true;
                break;
              }
            }
          } else {
            if (usedToolCallIds.contains(msg.toolCallId ?? '')) {
              hasMatchingAssistant = true;
            }
          }

          if (hasMatchingAssistant) {
            // 已被提前消费，跳过
            _markAllToolResultsConsumed(msg, i, usedToolResultKeys);
          } else {
            // 孤立 tool_result，丢弃
            final ids = msg.isToolResultGroup
                ? msg.toolResults!.map((r) => r.toolCallId).toList()
                : [msg.toolCallId ?? ''];
            _log.warn(
              '_validateStrictSequence: 丢弃孤立 tool_result '
              'tool_use_ids=$ids（无匹配的 assistant(toolCalls)）',
            );
            _markAllToolResultsConsumed(msg, i, usedToolResultKeys);
          }
        }
      } else {
        // user / system 等非 tool 消息：直接添加
        result.add(msg);
      }
    }

    return result;
  }

  static String _toolResultKey(_ToolResultInfo info) {
    return '${info.sourceIndex}:${info.resultIndex}';
  }

  static bool _allToolResultsConsumed(
    ChatMessage msg,
    int sourceIndex,
    Set<String> usedToolResultKeys,
  ) {
    if (!msg.isToolResultGroup) {
      return usedToolResultKeys.contains('$sourceIndex:0');
    }
    return msg.toolResults!.asMap().entries.every(
      (entry) => usedToolResultKeys.contains('$sourceIndex:${entry.key}'),
    );
  }

  static void _markAllToolResultsConsumed(
    ChatMessage msg,
    int sourceIndex,
    Set<String> usedToolResultKeys,
  ) {
    if (!msg.isToolResultGroup) {
      usedToolResultKeys.add('$sourceIndex:0');
      return;
    }
    for (final entry in msg.toolResults!.asMap().entries) {
      usedToolResultKeys.add('$sourceIndex:${entry.key}');
    }
  }

  static List<ChatMessage> _consumeToolResultInfos(
    List<_ToolResultInfo> infos,
    Set<String> usedToolResultKeys,
  ) {
    final groupedInfos = <int, List<_ToolResultInfo>>{};
    final groupOrder = <int>[];

    for (final info in infos) {
      final key = _toolResultKey(info);
      if (usedToolResultKeys.contains(key)) continue;

      groupedInfos
          .putIfAbsent(info.sourceIndex, () {
            groupOrder.add(info.sourceIndex);
            return [];
          })
          .add(info);
      usedToolResultKeys.add(key);
    }

    final messages = <ChatMessage>[];
    for (final sourceIndex in groupOrder) {
      final group = groupedInfos[sourceIndex]!;
      final source = group.first.msg;

      if (source.isToolResultGroup) {
        final results = group
            .map((info) => info.result)
            .whereType<ToolResult>()
            .toList();
        if (results.isEmpty) continue;

        messages.add(
          ChatMessage.toolResultGroup(
            id: source.id,
            employeeId: source.employeeId,
            results: results,
            createdAt: source.createdAt,
            deviceId: source.deviceId,
          ),
        );
      } else {
        messages.add(source);
      }
    }

    return messages;
  }

  /// 在指定索引处，仅 strip assistant 消息中未匹配的 toolCalls
  ///
  /// 与 [_stripAssistantToolCallsAt]（strip 全部 toolCalls）不同，
  /// 此方法仅移除 [unmatchedIds] 中的 toolCalls，保留已匹配的。
  /// 这确保 Anthropic 收到的 assistant 消息的 tool_use blocks
  /// 与紧随其后的 tool_result 完全对应。
  static void _stripUnmatchedToolCallsAt(
    List<ChatMessage> result,
    int index,
    Set<String> unmatchedIds,
  ) {
    if (index < 0 || index >= result.length) return;
    final msg = result[index];
    if (msg.role != MessageRole.assistant ||
        msg.toolCalls == null ||
        msg.toolCalls!.isEmpty) {
      return;
    }

    // 过滤掉未匹配的 toolCalls，保留已匹配的
    final remainingToolCalls = msg.toolCalls!
        .where((tc) => !unmatchedIds.contains(tc.id))
        .toList();

    if (remainingToolCalls.isEmpty) {
      // 全部未匹配 → strip 所有 toolCalls，转为内联文本
      _stripAssistantToolCallsAt(result, index);
      return;
    }

    // 部分匹配 → 仅保留已匹配的 toolCalls
    final unmatchedToolCalls = msg.toolCalls!
        .where((tc) => unmatchedIds.contains(tc.id))
        .toList();

    // 为被 strip 的 toolCalls 生成内联描述
    final strippedSummary = unmatchedToolCalls
        .map((tc) {
          final args = tc.arguments;
          String argsPreview;
          if (args.length <= 3) {
            argsPreview = args.entries
                .map((e) => '${e.key}=${_truncate('${e.value}', 80)}')
                .join(', ');
          } else {
            argsPreview = args.entries
                .take(3)
                .map((e) => '${e.key}=${_truncate('${e.value}', 80)}')
                .join(', ');
            argsPreview += ', ...(共${args.length}个参数)';
          }
          return '${tc.name}($argsPreview)';
        })
        .join('; ');
    final inlineNote = '[已调用工具: $strippedSummary，但结果因消息序列修复被移除，请勿重复调用]';

    final content = msg.content;
    final newContent = (content == null || content.trim().isEmpty)
        ? inlineNote
        : '$content\n$inlineNote';

    result[index] = msg.copyWith(
      toolCalls: remainingToolCalls,
      content: newContent,
      // Note: Do NOT clear thinking. DeepSeek thinking mode requires
      // reasoning_content to be passed back in multi-turn conversations.
    );
  }

  /// 在指定索引处 strip assistant 消息的 toolCalls，转为内联文本描述
  static void _stripAssistantToolCallsAt(List<ChatMessage> result, int index) {
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
                .map((e) => '${e.key}=${_truncate('${e.value}', 80)}')
                .join(', ');
          } else {
            argsPreview = args.entries
                .take(3)
                .map((e) => '${e.key}=${_truncate('${e.value}', 80)}')
                .join(', ');
            argsPreview += ', ...(共${args.length}个参数)';
          }
          return '${tc.name}($argsPreview)';
        })
        .join('; ');
    final inlineNote = '[已调用工具: $toolSummary，但结果因消息序列修复被移除，请勿重复调用]';

    final newContent = (content == null || content.trim().isEmpty)
        ? inlineNote
        : '$content\n$inlineNote';

    result[index] = msg.copyWith(
      clearToolCalls: true,
      // Note: Do NOT clear thinking. DeepSeek thinking mode requires
      // reasoning_content to be passed back in multi-turn conversations.
      type: 'text',
      content: newContent,
    );
  }

  // ── 消息序列诊断 ──

  /// 分析消息序列，收集诊断信息（不修复，仅报告）
  ///
  /// 复用 `sanitizeForLlm` 的核心逻辑，但只收集问题而不修改消息。
  static MessageSequenceReport analyzeMessageSequence(
    List<ChatMessage> messages,
  ) {
    final issues = <MessageSequenceIssue>[];
    final summaries = <MessageSummary>[];
    final chains = <ToolCallChain>[];

    // toolCallId -> (toolName, assistantIndex)
    final pendingToolCalls = <String, (String, int)>{};
    // 已匹配的 toolCallId set（用于追踪未匹配的）
    final matchedToolCallIds = <String>{};

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];

      // 生成消息摘要
      summaries.add(
        MessageSummary(
          index: i,
          role: msg.role.name,
          type: msg.type,
          toolCallId: msg.toolCallId,
          contentPreview: _truncate(msg.content ?? '', 80),
        ),
      );

      if (msg.role == MessageRole.assistant &&
          msg.toolCalls != null &&
          msg.toolCalls!.isNotEmpty) {
        // 如果之前有未匹配的 toolCallIds，报告问题
        if (pendingToolCalls.isNotEmpty) {
          for (final entry in pendingToolCalls.entries) {
            issues.add(
              MessageSequenceIssue(
                type: 'unmatched_tool_call',
                index: entry.value.$2,
                description:
                    'assistant 消息中的 toolCall ${entry.key} (${entry.value.$1}) 没有对应的 toolResult',
                toolCallId: entry.key,
              ),
            );
            chains.add(
              ToolCallChain(
                toolCallId: entry.key,
                toolName: entry.value.$1,
                assistantIndex: entry.value.$2,
                matched: false,
              ),
            );
          }
          pendingToolCalls.clear();
        }
        // 记录本轮所有 toolCall
        for (final tc in msg.toolCalls!) {
          pendingToolCalls[tc.id] = (tc.name, i);
        }
      } else if (msg.role == MessageRole.tool) {
        if (msg.isToolResultGroup) {
          for (final r in msg.toolResults!) {
            final info = pendingToolCalls.remove(r.toolCallId);
            if (info == null) {
              issues.add(
                MessageSequenceIssue(
                  type: 'orphaned_tool_result',
                  index: i,
                  description:
                      'toolResult ${r.toolCallId} (${r.name ?? 'unknown'}) 没有匹配的 toolCall',
                  toolCallId: r.toolCallId,
                ),
              );
              chains.add(
                ToolCallChain(
                  toolCallId: r.toolCallId,
                  toolName: r.name ?? 'unknown',
                  resultIndex: i,
                  matched: false,
                ),
              );
            } else {
              matchedToolCallIds.add(r.toolCallId);
              chains.add(
                ToolCallChain(
                  toolCallId: r.toolCallId,
                  toolName: info.$1,
                  assistantIndex: info.$2,
                  resultIndex: i,
                  matched: true,
                ),
              );
            }
          }
        } else {
          final toolCallId = msg.toolCallId ?? '';
          final info = pendingToolCalls.remove(toolCallId);
          if (info == null && toolCallId.isNotEmpty) {
            issues.add(
              MessageSequenceIssue(
                type: 'orphaned_tool_result',
                index: i,
                description:
                    'toolResult $toolCallId (${msg.toolName ?? 'unknown'}) 没有匹配的 toolCall',
                toolCallId: toolCallId,
              ),
            );
            chains.add(
              ToolCallChain(
                toolCallId: toolCallId,
                toolName: msg.toolName ?? 'unknown',
                resultIndex: i,
                matched: false,
              ),
            );
          } else if (info != null) {
            matchedToolCallIds.add(toolCallId);
            chains.add(
              ToolCallChain(
                toolCallId: toolCallId,
                toolName: info.$1,
                assistantIndex: info.$2,
                resultIndex: i,
                matched: true,
              ),
            );
          }
        }
      } else {
        // user / system 等非 tool 消息
        if (pendingToolCalls.isNotEmpty) {
          for (final entry in pendingToolCalls.entries) {
            issues.add(
              MessageSequenceIssue(
                type: 'unexpected_message_order',
                index: i,
                description:
                    '在 toolCall ${entry.key} (${entry.value.$1}) 与其 toolResult 之间出现了 ${msg.role.name} 消息',
                toolCallId: entry.key,
              ),
            );
            chains.add(
              ToolCallChain(
                toolCallId: entry.key,
                toolName: entry.value.$1,
                assistantIndex: entry.value.$2,
                matched: false,
              ),
            );
          }
          pendingToolCalls.clear();
        }
      }
    }

    // 序列末尾残留未匹配的 toolCalls
    if (pendingToolCalls.isNotEmpty) {
      for (final entry in pendingToolCalls.entries) {
        issues.add(
          MessageSequenceIssue(
            type: 'unmatched_tool_call',
            index: entry.value.$2,
            description: '序列末尾仍有未匹配的 toolCall ${entry.key} (${entry.value.$1})',
            toolCallId: entry.key,
          ),
        );
        chains.add(
          ToolCallChain(
            toolCallId: entry.key,
            toolName: entry.value.$1,
            assistantIndex: entry.value.$2,
            matched: false,
          ),
        );
      }
    }

    return MessageSequenceReport(
      issues: issues,
      messageSummaries: summaries,
      toolCallChains: chains,
    );
  }

  /// 截断字符串到指定长度
  static String _truncate(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}...';
  }

  /// 构建 assistant 消息，并在有 thinking 内容时回传
  ///
  /// 根据提供商不同，采用不同的回传方式：
  /// - Anthropic：通过 anthropic extension 的 contentBlocks 回传
  /// - DeepSeek/OpenAI：直接通过 llm_dart 的 thinking 扩展回传
  static llm.ChatMessage _buildAssistantMessageWithThinking(
    ChatMessage msg, {
    LLMProvider? provider,
  }) {
    // For DeepSeek thinking mode, content must not be empty when reasoning_content is present.
    // If content is empty/null but thinking is present, provide a placeholder.
    final content = msg.content;
    final effectiveContent = (content == null || content.trim().isEmpty)
        ? ' ' // Single space placeholder to avoid empty assistant content
        : content;
    final assistantMsg = llm.ChatMessage.assistant(effectiveContent);
    if (msg.thinking != null && msg.thinking!.isNotEmpty) {
      return _attachThinking(assistantMsg, msg.thinking!, provider);
    }
    return assistantMsg;
  }

  /// 根据 provider 类型附加 thinking 内容到 llm.ChatMessage
  ///
  /// - Anthropic：通过 anthropic extension 的 contentBlocks 回传
  /// - 其他（DeepSeek/OpenAI）：通过 deepseek extension 的 reasoning_content 回传
  static llm.ChatMessage _attachThinking(
    llm.ChatMessage baseMsg,
    String thinking,
    LLMProvider? provider,
  ) {
    if (provider == LLMProvider.anthropic) {
      return baseMsg.withExtension('anthropic', {
        'contentBlocks': [
          {'type': 'thinking', 'thinking': thinking},
        ],
      });
    }
    // DeepSeek/OpenAI 等提供商：通过 deepseek extension 回传 reasoning_content
    // llm_dart DeepSeek provider 会读取此扩展
    return baseMsg.withExtension('deepseek', {'reasoning_content': thinking});
  }

  /// 从 result 列表中找到最后一条含 toolCalls 的 assistant 消息，
  /// 将 toolCalls 转为内联文本描述（而非静默丢弃），确保 LLM 能感知历史工具调用，
  /// 避免因丢失记忆而重复发起相同的工具调用。
  ///
  /// 如果清除 toolCalls 后 content 为空，填充工具调用描述文本以避免 API 报错
  /// （OpenAI 等要求 assistant 消息不能为空：必须有 content 或 tool_calls）
  static void _stripLastAssistantToolCalls(List<ChatMessage> result) {
    for (var i = result.length - 1; i >= 0; i--) {
      final msg = result[i];
      if (msg.role == MessageRole.assistant &&
          msg.toolCalls != null &&
          msg.toolCalls!.isNotEmpty) {
        final content = msg.content;
        // 将 toolCalls 转为可读的内联文本描述，让 LLM 知道之前调用了什么
        final toolSummary = msg.toolCalls!
            .map((tc) {
              final args = tc.arguments;
              // 提取关键参数用于摘要，避免过长
              String argsPreview;
              if (args.length <= 3) {
                argsPreview = args.entries
                    .map((e) => '${e.key}=${_truncate('${e.value}', 80)}')
                    .join(', ');
              } else {
                argsPreview = args.entries
                    .take(3)
                    .map((e) => '${e.key}=${_truncate('${e.value}', 80)}')
                    .join(', ');
                argsPreview += ', ...(共${args.length}个参数)';
              }
              return '${tc.name}($argsPreview)';
            })
            .join('; ');
        final inlineNote = '[已调用工具: $toolSummary，但结果因消息序列修复被移除，请勿重复调用]';

        final newContent = (content == null || content.trim().isEmpty)
            ? inlineNote
            : '$content\n$inlineNote';

        result[i] = msg.copyWith(
          clearToolCalls: true,
          // Note: Do NOT clear thinking here.
          // DeepSeek new models (deepseek-v4-flash/pro) use thinking mode by default
          // and require reasoning_content to be passed back in multi-turn conversations.
          // Clearing thinking would cause: "The reasoning_content in the thinking mode
          // must be passed back to the API."
          type: 'text',
          content: newContent,
        );
        return;
      }
    }
  }

  // ── 内部工具 ──

  /// 解析工具参数 JSON 字符串为 Map
  static Map<String, dynamic> _parseArguments(String argumentsJson) {
    if (argumentsJson.isEmpty) return {};
    try {
      return jsonDecode(argumentsJson) as Map<String, dynamic>;
    } catch (e) {
      _log.debug('parse tool arguments failed, using empty map: $e');
      return {};
    }
  }
}
