/// ChatMessage ↔ llm_dart 转换器
///
/// 将统一消息模型转换为 llm_dart 库所需的格式，
/// 同时保留合并连续 tool result 的逻辑。
library;

import 'dart:convert';

import 'package:llm_dart/llm_dart.dart' as llm;

import '../utils/logger.dart';
import 'chat_message.dart';

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
          return llm.ChatMessage.toolUse(
            toolCalls: msg.toolCalls!.map((tc) => llm.ToolCall(
                  id: tc.id,
                  callType: 'function',
                  function: llm.FunctionCall(
                    name: tc.name,
                    arguments: tc.argumentsJson,
                  ),
                )).toList(),
            content: msg.content ?? '',
          );
        }
        // 包含单工具调用（向后兼容）
        if (msg.toolCallId != null && msg.toolName != null) {
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
                name: r.name ?? '',
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
        return llm.ChatMessage.toolResult(
          results: [
            llm.ToolCall(
              id: msg.toolCallId ?? '',
              callType: 'function',
              function: llm.FunctionCall(
                name: msg.toolName ?? '',
                arguments: resultArguments,
              ),
            ),
          ],
          content: msg.content ?? '',
        );
    }
  }

  /// 批量转换 ChatMessage → llm_dart
  static List<llm.ChatMessage> toLlmDartList(List<ChatMessage> messages) {
    return messages.map(toLlmDart).toList();
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
            'sanitizeForLlm: 遇到非 tool 消息但有未匹配的 toolCallIds，清除上一条 assistant toolCalls',
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
        'sanitizeForLlm: 序列末尾仍有未匹配的 toolCallIds: $expectedIds，清除最后一条 assistant toolCalls',
      );
      _stripLastAssistantToolCalls(result);
    }

    return result;
  }

  /// 从 result 列表中找到最后一条含 toolCalls 的 assistant 消息，
  /// 用 copyWith(clearToolCalls: true, type: 'text') 去掉其 toolCalls
  static void _stripLastAssistantToolCalls(List<ChatMessage> result) {
    for (var i = result.length - 1; i >= 0; i--) {
      final msg = result[i];
      if (msg.role == MessageRole.assistant &&
          msg.toolCalls != null &&
          msg.toolCalls!.isNotEmpty) {
        result[i] = msg.copyWith(
          clearToolCalls: true,
          type: 'text',
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
