/// ChatMessage ↔ llm_dart 转换器
///
/// 将统一消息模型转换为 llm_dart 库所需的格式，
/// 同时保留合并连续 tool result 的逻辑。
library;

import 'dart:convert';

import 'package:llm_dart/llm_dart.dart' as llm;

import '../utils/logger.dart';
import 'chat_message.dart';
import 'message_sequence_report.dart';

final _log = Logger('LlmMessageMapper');

/// ChatMessage 与 llm_dart ChatMessage 的双向映射器
///
/// 职责：
/// 1. ChatMessage → llm.ChatMessage（发送给 LLM 前）
/// 2. llm.ChatMessage → ChatMessage（收到 LLM 响应后）
/// 3. 合并连续 tool result 消息（OpenAI 兼容性）
class LlmMessageMapper {
  // ── ChatMessage → llm_dart ──

  /// 将 ChatMessage 转换为 llm_dart 的 ChatMessage
  static llm.ChatMessage toLlmDart(ChatMessage msg) {
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
            return llm.ChatMessage.toolUse(
              toolCalls: validToolCalls.map((tc) => llm.ToolCall(
                    id: tc.id,
                    callType: 'function',
                    function: llm.FunctionCall(
                      name: tc.name,
                      arguments: tc.argumentsJson,
                    ),
                  )).toList(),
              content: msg.content ?? '',
            );
          } else {
            _log.warn('toLlmDart: assistant 消息的所有 toolCall name 为空，降级为纯文本 (id=${msg.id})');
            return llm.ChatMessage.assistant(msg.content ?? '');
          }
        }
        // 包含单工具调用（向后兼容）
        if (msg.toolCallId != null && msg.toolName != null) {
          // 防御性校验：name 为空时降级为纯文本
          if (msg.toolName!.trim().isEmpty) {
            _log.warn('toLlmDart: 单工具调用的 toolName 为空，降级为纯文本 (id=${msg.id})');
            return llm.ChatMessage.assistant(msg.content ?? '');
          }
          final argsJson = msg.toolArguments != null
              ? jsonEncode(msg.toolArguments)
              : '{}';
          return llm.ChatMessage.toolUse(
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
        }
        return llm.ChatMessage.assistant(msg.content ?? '');

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
        final toolName = msg.toolName?.isNotEmpty == true ? msg.toolName! : 'unknown';
        final toolCallId = msg.toolCallId?.isNotEmpty == true ? msg.toolCallId! : '';
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
  static List<llm.ChatMessage> toLlmDartList(List<ChatMessage> messages) {
    final result = <llm.ChatMessage>[];
    for (final msg in messages) {
      // 跳过空内容的 assistant 消息（既无文本也无工具调用）
      if (msg.role == MessageRole.assistant) {
        final hasContent =
            msg.content != null && msg.content!.trim().isNotEmpty;
        final hasToolCalls =
            msg.toolCalls != null && msg.toolCalls!.isNotEmpty;
        final hasLegacyToolCall =
            msg.toolCallId != null && msg.toolName != null;
        if (!hasContent && !hasToolCalls && !hasLegacyToolCall) {
          _log.warn('toLlmDartList: 跳过空 assistant 消息 (id=${msg.id})');
          continue;
        }
      }
      result.add(toLlmDart(msg));
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
            toolCalls: toolUse.toolCalls.map((tc) => ToolCall(
                  id: tc.id,
                  name: tc.function.name,
                  arguments: _parseArguments(tc.function.arguments),
                )).toList(),
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
      toolCalls: response.toolCalls?.map((tc) => ToolCall(
            id: tc.id,
            name: tc.function.name,
            arguments: _parseArguments(tc.function.arguments),
          )).toList(),
    );
  }

  // ── 连续 tool result 合并 ──

  /// 将连续的 tool 角色消息合并为分组消息
  ///
  /// 在 OpenAI 协议中，一轮 assistant tool_calls 后跟的多个 tool result
  /// 应作为一组传递，确保 tool_call_id 对应关系正确。
  /// 与原 SessionMemoryManager._mergeConsecutiveToolMessages 逻辑一致。
  static List<ChatMessage> mergeConsecutiveToolResults(
      List<ChatMessage> messages) {
    if (messages.isEmpty) return messages;

    final result = <ChatMessage>[];
    List<ToolResult>? pendingResults;

    for (final msg in messages) {
      if (msg.role == MessageRole.tool && !msg.isToolResultGroup) {
        // 单条 tool result → 加入待合并缓冲区
        pendingResults ??= [];
        pendingResults.add(ToolResult(
          toolCallId: msg.toolCallId ?? '',
          content: msg.content ?? '',
          isError: msg.isError,
          name: msg.toolName,
        ));
      } else {
        // 非 tool 消息 → 先刷新缓冲区
        if (pendingResults != null) {
          result.add(ChatMessage.toolResultGroup(
            id: result.isEmpty ? '' : '', // ID 由调用方按需赋值
            employeeId: '',
            results: pendingResults,
            createdAt: msg.createdAt,
          ));
          pendingResults = null;
        }
        result.add(msg);
      }
    }

    // 刷新末尾剩余的 tool results
    if (pendingResults != null) {
      result.add(ChatMessage.toolResultGroup(
        id: '',
        employeeId: '',
        results: pendingResults,
      ));
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
  static List<ChatMessage> sanitizeForLlm(List<ChatMessage> messages) {
    if (messages.isEmpty) return messages;

    final result = <ChatMessage>[];
    final expectedIds = <String>{};

    for (final msg in messages) {
      if (msg.role == MessageRole.assistant &&
          msg.toolCalls != null &&
          msg.toolCalls!.isNotEmpty) {
        // 如果之前有未匹配的 tool_call_id，清除上一条 assistant 的 toolCalls
        if (expectedIds.isNotEmpty) {
          _log.warn(
            'sanitizeForLlm: 新 assistant(toolCalls) 但有未匹配的 expectedIds=$expectedIds, '
            '新 toolCallIds=${msg.toolCalls!.map((tc) => tc.id).toList()}, '
            '触发 _stripLastAssistantToolCalls',
          );
          _stripLastAssistantToolCalls(result);
          expectedIds.clear();
        }
        // 记录本轮所有 tool_call_id
        for (final tc in msg.toolCalls!) {
          expectedIds.add(tc.id);
        }
        result.add(msg);
      } else if (msg.role == MessageRole.tool) {
        if (msg.isToolResultGroup) {
          // 分组 tool result：只保留 expectedIds 中存在的
          final validResults = msg.toolResults!
              .where((r) => expectedIds.contains(r.toolCallId))
              .toList();
          for (final r in validResults) {
            expectedIds.remove(r.toolCallId);
          }
          if (validResults.isEmpty) {
            _log.warn('sanitizeForLlm: 丢弃孤立 tool result group (无匹配 toolCallId)');
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
          if (toolCallId.isEmpty || !expectedIds.contains(toolCallId)) {
            _log.warn('sanitizeForLlm: 丢弃孤立 tool result (toolCallId=$toolCallId)');
            continue;
          }
          expectedIds.remove(toolCallId);
          result.add(msg);
        }
      } else {
        // user / system 等非 tool 消息
        if (expectedIds.isNotEmpty) {
          _log.warn(
            'sanitizeForLlm: 遇到 ${msg.role} 消息但有未匹配的 toolCallIds=$expectedIds, '
            'msgId=${msg.id}, content=${_truncate(msg.content ?? '', 60)}, '
            '触发 _stripLastAssistantToolCalls',
          );
          _stripLastAssistantToolCalls(result);
          expectedIds.clear();
        }
        result.add(msg);
      }
    }

    // 序列末尾：处理残留未匹配的 expectedIds
    if (expectedIds.isNotEmpty) {
      _log.warn(
        'sanitizeForLlm: 序列末尾仍有未匹配的 toolCallIds=$expectedIds, '
        '总消息数=${messages.length}, 触发 _stripLastAssistantToolCalls',
      );
      _stripLastAssistantToolCalls(result);
    }

    return result;
  }

  // ── 消息序列诊断 ──

  /// 分析消息序列，收集诊断信息（不修复，仅报告）
  ///
  /// 复用 `sanitizeForLlm` 的核心逻辑，但只收集问题而不修改消息。
  static MessageSequenceReport analyzeMessageSequence(
      List<ChatMessage> messages) {
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
      summaries.add(MessageSummary(
        index: i,
        role: msg.role.name,
        type: msg.type,
        toolCallId: msg.toolCallId,
        contentPreview: _truncate(msg.content ?? '', 80),
      ));

      if (msg.role == MessageRole.assistant &&
          msg.toolCalls != null &&
          msg.toolCalls!.isNotEmpty) {
        // 如果之前有未匹配的 toolCallIds，报告问题
        if (pendingToolCalls.isNotEmpty) {
          for (final entry in pendingToolCalls.entries) {
            issues.add(MessageSequenceIssue(
              type: 'unmatched_tool_call',
              index: entry.value.$2,
              description:
                  'assistant 消息中的 toolCall ${entry.key} (${entry.value.$1}) 没有对应的 toolResult',
              toolCallId: entry.key,
            ));
            chains.add(ToolCallChain(
              toolCallId: entry.key,
              toolName: entry.value.$1,
              assistantIndex: entry.value.$2,
              matched: false,
            ));
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
              issues.add(MessageSequenceIssue(
                type: 'orphaned_tool_result',
                index: i,
                description:
                    'toolResult ${r.toolCallId} (${r.name ?? 'unknown'}) 没有匹配的 toolCall',
                toolCallId: r.toolCallId,
              ));
              chains.add(ToolCallChain(
                toolCallId: r.toolCallId,
                toolName: r.name ?? 'unknown',
                resultIndex: i,
                matched: false,
              ));
            } else {
              matchedToolCallIds.add(r.toolCallId);
              chains.add(ToolCallChain(
                toolCallId: r.toolCallId,
                toolName: info.$1,
                assistantIndex: info.$2,
                resultIndex: i,
                matched: true,
              ));
            }
          }
        } else {
          final toolCallId = msg.toolCallId ?? '';
          final info = pendingToolCalls.remove(toolCallId);
          if (info == null && toolCallId.isNotEmpty) {
            issues.add(MessageSequenceIssue(
              type: 'orphaned_tool_result',
              index: i,
              description:
                  'toolResult $toolCallId (${msg.toolName ?? 'unknown'}) 没有匹配的 toolCall',
              toolCallId: toolCallId,
            ));
            chains.add(ToolCallChain(
              toolCallId: toolCallId,
              toolName: msg.toolName ?? 'unknown',
              resultIndex: i,
              matched: false,
            ));
          } else if (info != null) {
            matchedToolCallIds.add(toolCallId);
            chains.add(ToolCallChain(
              toolCallId: toolCallId,
              toolName: info.$1,
              assistantIndex: info.$2,
              resultIndex: i,
              matched: true,
            ));
          }
        }
      } else {
        // user / system 等非 tool 消息
        if (pendingToolCalls.isNotEmpty) {
          for (final entry in pendingToolCalls.entries) {
            issues.add(MessageSequenceIssue(
              type: 'unexpected_message_order',
              index: i,
              description:
                  '在 toolCall ${entry.key} (${entry.value.$1}) 与其 toolResult 之间出现了 ${msg.role.name} 消息',
              toolCallId: entry.key,
            ));
            chains.add(ToolCallChain(
              toolCallId: entry.key,
              toolName: entry.value.$1,
              assistantIndex: entry.value.$2,
              matched: false,
            ));
          }
          pendingToolCalls.clear();
        }
      }
    }

    // 序列末尾残留未匹配的 toolCalls
    if (pendingToolCalls.isNotEmpty) {
      for (final entry in pendingToolCalls.entries) {
        issues.add(MessageSequenceIssue(
          type: 'unmatched_tool_call',
          index: entry.value.$2,
          description:
              '序列末尾仍有未匹配的 toolCall ${entry.key} (${entry.value.$1})',
          toolCallId: entry.key,
        ));
        chains.add(ToolCallChain(
          toolCallId: entry.key,
          toolName: entry.value.$1,
          assistantIndex: entry.value.$2,
          matched: false,
        ));
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
                argsPreview = args.entries.take(3)
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
