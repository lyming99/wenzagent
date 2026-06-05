import 'package:test/test.dart';
import 'package:wenzagent/src/shared/chat_message.dart';
import 'package:wenzagent/src/shared/llm_message_mapper.dart';

void main() {
  group('sanitizeForLlm', () {
    // ===== 辅助方法 =====

    ChatMessage userMsg(String id, String content) =>
        ChatMessage.user(id: id, employeeId: 'emp1', content: content);

    ChatMessage systemMsg(String id, String content) =>
        ChatMessage.system(id: id, employeeId: 'emp1', content: content);

    ChatMessage assistantMsg(
      String id,
      String content, {
      List<ToolCall>? toolCalls,
    }) => ChatMessage.assistant(
      id: id,
      employeeId: 'emp1',
      content: content,
      toolCalls: toolCalls,
    );

    ChatMessage toolResultGroup(String id, List<ToolResult> results) =>
        ChatMessage.toolResultGroup(
          id: id,
          employeeId: 'emp1',
          results: results,
        );

    ChatMessage toolResultMsg(
      String id,
      String toolCallId,
      String content, {
      bool isError = false,
      String? toolName,
    }) => ChatMessage.toolResult(
      id: id,
      employeeId: 'emp1',
      toolCallId: toolCallId,
      content: content,
      isError: isError,
      toolName: toolName,
    );

    ToolCall tc(String id, String name) =>
        ToolCall(id: id, name: name, arguments: {});

    ToolResult tr(
      String toolCallId,
      String content, {
      bool isError = false,
      String? name,
    }) => ToolResult(
      toolCallId: toolCallId,
      content: content,
      isError: isError,
      name: name,
    );

    // ===== 基础场景：正常序列不应被修改 =====

    test('正常单轮 tool calling 序列保持不变', () {
      final messages = [
        userMsg('u1', 'hello'),
        assistantMsg('a1', '', toolCalls: [tc('tc1', 'file_read')]),
        toolResultGroup('r1', [tr('tc1', 'file content')]),
        assistantMsg('a2', 'here is the file'),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(messages);
      expect(result.length, equals(4));
      expect(result[1].toolCalls, isNotNull);
      expect(result[1].toolCalls!.length, equals(1));
    });

    // ===== strictMode=true 场景（Anthropic 行为）=====

    test('strictMode=true: 多轮 tool calling 时，孤立 tool_result 被丢弃', () {
      // 模拟：第一轮 assistant(toolCalls) 的 tool_result 丢失，
      // 第二轮 assistant(toolCalls) 出现后，第一轮的 tool_result 才出现
      final messages = [
        userMsg('u1', 'read file'),
        assistantMsg('a1', 'reading', toolCalls: [tc('tc1', 'file_read')]),
        assistantMsg(
          'a2',
          'also writing',
          toolCalls: [tc('tc2', 'file_write')],
        ),
        toolResultGroup('r1', [tr('tc1', 'file content')]),
        toolResultGroup('r2', [tr('tc2', 'write ok')]),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        strictMode: true,
      );

      // strictMode 下：遇到 a2(toolCalls) 时，tc1 未匹配 → strip a1 的 toolCalls
      // tc1 的 tool_result (r1) 在阶段二被丢弃（因为 a1 已被 strip）
      // 只保留 tc2 的 tool_result (r2)
      expect(
        result.any((m) => m.id == 'r1'),
        isFalse,
        reason: 'tc1 的 tool_result 应被丢弃（因为 a1 的 toolCalls 被 strip 了）',
      );
      expect(
        result.any((m) => m.id == 'r2'),
        isTrue,
        reason: 'tc2 的 tool_result 应被保留',
      );
    });

    test('strictMode=true: 正常多轮 tool calling 序列保持不变', () {
      final messages = [
        userMsg('u1', 'read and write'),
        assistantMsg('a1', 'reading', toolCalls: [tc('tc1', 'file_read')]),
        toolResultGroup('r1', [tr('tc1', 'file content')]),
        assistantMsg('a2', 'writing', toolCalls: [tc('tc2', 'file_write')]),
        toolResultGroup('r2', [tr('tc2', 'write ok')]),
        assistantMsg('a3', 'done'),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        strictMode: true,
      );

      // 正常序列经过两阶段处理后，所有 toolCalls 和 tool_result 都正确配对
      expect(result.length, equals(6));
      expect(result[1].toolCalls, isNotNull);
      expect(result[1].toolCalls!.isNotEmpty, isTrue);
      expect(result[3].toolCalls, isNotNull);
      expect(result[3].toolCalls!.isNotEmpty, isTrue);
    });

    test('strictMode=true: 序列末尾未匹配的 toolCalls 被 strip', () {
      final messages = [
        userMsg('u1', 'read file'),
        assistantMsg('a1', 'reading', toolCalls: [tc('tc1', 'file_read')]),
        // 没有 tool_result
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        strictMode: true,
      );

      expect(result.length, equals(2));
      // a1 的 toolCalls 应被 strip（转为文本描述）
      expect(result[1].toolCalls, isNull);
      expect(result[1].content, contains('已调用工具'));
    });

    // ===== strictMode 阶段二验证场景 =====

    test('strictMode=true: tool_result 出现在 system 消息之后被丢弃', () {
      // 模拟：上下文压缩后，system 消息插入在 assistant(toolCalls) 和 tool_result 之间
      // messages.2 = tool_result 引用了 messages.1 的 tool_use_id
      // 但 messages.1 和 messages.2 之间插入了 system 消息
      final messages = [
        systemMsg('sys1', 'system prompt'),
        assistantMsg('a1', 'reading', toolCalls: [tc('call_001', 'file_read')]),
        systemMsg('sys2', 'injected system message'), // 插入！
        toolResultGroup('r1', [tr('call_001', 'file content')]),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        strictMode: true,
      );

      // 阶段一：expectedIds 包含 call_001，遇到 system 消息时 strip a1
      // 阶段二：tool_result(call_001) 前面没有 assistant(toolCalls) → 丢弃
      expect(
        result.any((m) => m.id == 'r1'),
        isFalse,
        reason: 'tool_result 出现在 system 消息之后，不再是紧邻 assistant，应被丢弃',
      );
      // a1 应被 strip
      final a1Result = result.firstWhere((m) => m.id == 'a1');
      expect(a1Result.toolCalls, isNull, reason: 'a1 的 toolCalls 应被 strip');
    });

    test('strictMode=true: 多个 tool_result group 只保留紧邻的', () {
      // 模拟：两个 assistant(toolCalls) 的 tool_result 交错
      final messages = [
        userMsg('u1', 'do stuff'),
        assistantMsg('a1', '', toolCalls: [tc('tc1', 'tool_a')]),
        assistantMsg('a2', '', toolCalls: [tc('tc2', 'tool_b')]),
        toolResultGroup('r1', [tr('tc1', 'result a')]),
        toolResultGroup('r2', [tr('tc2', 'result b')]),
        assistantMsg('a3', 'done'),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        strictMode: true,
      );

      // 阶段一：遇到 a2 时 strip a1
      // 阶段二：r1(call_001) 前面的 a1 已被 strip，无 assistant(toolCalls) → 丢弃
      // r2(call_002) 前面是 a2(toolCalls: [tc2]) → 匹配，保留
      expect(
        result.any((m) => m.id == 'r1'),
        isFalse,
        reason: 'r1 的 tool_use_id 不在紧邻的前一条 assistant 中',
      );
      expect(
        result.any((m) => m.id == 'r2'),
        isTrue,
        reason: 'r2 的 tool_use_id 在紧邻的前一条 assistant 中',
      );
    });

    test('strictMode=true: 部分匹配的 tool_result_group 被拆分', () {
      // 一个 tool_result_group 中部分 id 匹配、部分不匹配
      final messages = [
        userMsg('u1', 'multi tool'),
        assistantMsg('a1', '', toolCalls: [tc('tc1', 'tool_a')]),
        toolResultGroup('r1', [
          tr('tc1', 'result a'),
          tr('tc_orphan', 'orphan result'),
        ]),
        assistantMsg('a2', 'done'),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        strictMode: true,
      );

      // 阶段一：tc1 匹配 expectedIds，tc_orphan 不匹配 → 拆分
      // 阶段二：tc1 在紧邻的 a1 中 → 保留
      expect(result.any((m) => m.id == 'r1'), isTrue);
      final r1Result = result.firstWhere((m) => m.id == 'r1');
      expect(
        r1Result.toolResults!.length,
        equals(1),
        reason: '只有 tc1 的 result 被保留',
      );
      expect(r1Result.toolResults!.first.toolCallId, equals('tc1'));
    });

    test('strictMode=true: 注入 assistant 消息后 tool_result 变孤立', () {
      // 模拟：injectAssistantMessage 导致在 assistant(toolCalls) 和 tool_result 之间
      // 插入了一条纯文本 assistant 消息
      final messages = [
        userMsg('u1', 'read'),
        assistantMsg('a1', 'reading', toolCalls: [tc('call_001', 'file_read')]),
        assistantMsg('a_inject', 'injected message'), // 注入的纯文本
        toolResultGroup('r1', [tr('call_001', 'file content')]),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        strictMode: true,
      );

      // 阶段一：expectedIds={call_001}，遇到 assistant(无 toolCalls) 时
      //   进入 else 分支，strip a1 的 toolCalls，expectedIds 清空
      // 阶段二：r1(call_001) 前面没有 assistant(toolCalls) → 丢弃
      expect(
        result.any((m) => m.id == 'r1'),
        isFalse,
        reason: 'tool_result 不紧邻 assistant(toolCalls)，应被丢弃',
      );
    });

    // ===== strictMode=false + knownToolCallIds 场景（OpenAI 行为）=====

    test('strictMode=false + knownToolCallIds: 跨轮次匹配保留 tool_result', () {
      final allSentToolCallIds = {'tc1', 'tc2'};

      final messages = [
        userMsg('u1', 'read and write'),
        assistantMsg('a1', 'reading', toolCalls: [tc('tc1', 'file_read')]),
        assistantMsg('a2', 'writing', toolCalls: [tc('tc2', 'file_write')]),
        toolResultGroup('r1', [tr('tc1', 'file content')]),
        toolResultGroup('r2', [tr('tc2', 'write ok')]),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        knownToolCallIds: allSentToolCallIds,
        strictMode: false,
      );

      // 跨轮次模式下：
      // 阶段一：tc1 在 knownToolCallIds 中，其 tool_result 被保留
      // 阶段二：r1(tc1) 不在紧邻的 a2(toolCalls=[tc2]) 中 → 被丢弃
      // 这是正确的修复行为，避免 Anthropic API "unexpected tool_use_id" 错误
      expect(
        result.any((m) => m.id == 'r1'),
        isFalse,
        reason: 'tc1 的 tool_result 在阶段二验证时因不满足紧邻要求被丢弃',
      );
      expect(
        result.any((m) => m.id == 'r2'),
        isTrue,
        reason: 'tc2 的 tool_result 紧邻 a2(toolCalls) 应被保留',
      );
      // a2 的 toolCalls 中 tc2 有匹配的 r2，保留
      expect(
        result
            .where(
              (m) =>
                  m.role == MessageRole.assistant &&
                  m.toolCalls != null &&
                  m.toolCalls!.isNotEmpty,
            )
            .length,
        equals(1),
        reason: '只有 a2 保留 toolCalls（a1 被 strip 因为其 tc1 无紧邻 tool_result）',
      );
    });

    test('strictMode=false + knownToolCallIds: 孤立 tool_result 被丢弃', () {
      final allSentToolCallIds = {'tc1'};

      final messages = [
        userMsg('u1', 'read'),
        assistantMsg('a1', 'reading', toolCalls: [tc('tc1', 'file_read')]),
        toolResultGroup('r1', [tr('tc1', 'file content')]),
        toolResultGroup('r2', [tr('tc_unknown', 'unknown result')]),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        knownToolCallIds: allSentToolCallIds,
        strictMode: false,
      );

      expect(result.any((m) => m.id == 'r1'), isTrue);
      expect(
        result.any((m) => m.id == 'r2'),
        isFalse,
        reason: '未知 toolCallId 的 tool_result 应被丢弃',
      );
    });

    // ===== 默认行为（无 knownToolCallIds, strictMode=false）=====

    test('默认模式: 无 knownToolCallIds 时等同于旧行为', () {
      final messages = [
        userMsg('u1', 'read file'),
        assistantMsg('a1', 'reading', toolCalls: [tc('tc1', 'file_read')]),
        assistantMsg(
          'a2',
          'also writing',
          toolCalls: [tc('tc2', 'file_write')],
        ),
        toolResultGroup('r1', [tr('tc1', 'file content')]),
        toolResultGroup('r2', [tr('tc2', 'write ok')]),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(messages);

      // 旧行为：遇到 a2(toolCalls) 时 strip a1 的 toolCalls
      // tc1 的 tool_result 变成孤立 → 被丢弃
      expect(result.any((m) => m.id == 'r1'), isFalse);
      expect(result.any((m) => m.id == 'r2'), isTrue);
    });

    // ===== 边界场景 =====

    test('strictMode=true 忽略 knownToolCallIds', () {
      // 即使提供了 knownToolCallIds，strictMode=true 也应禁用跨轮次匹配
      final allSentToolCallIds = {'tc1', 'tc2'};

      final messages = [
        userMsg('u1', 'read and write'),
        assistantMsg('a1', 'reading', toolCalls: [tc('tc1', 'file_read')]),
        assistantMsg('a2', 'writing', toolCalls: [tc('tc2', 'file_write')]),
        toolResultGroup('r1', [tr('tc1', 'file content')]),
        toolResultGroup('r2', [tr('tc2', 'write ok')]),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        knownToolCallIds: allSentToolCallIds,
        strictMode: true,
      );

      // strictMode=true 时，knownToolCallIds 应被忽略
      // tc1 的 tool_result 应被丢弃
      expect(
        result.any((m) => m.id == 'r1'),
        isFalse,
        reason: 'strictMode=true 时应忽略 knownToolCallIds',
      );
      expect(result.any((m) => m.id == 'r2'), isTrue);
    });

    test('空消息列表返回空', () {
      final result = LlmMessageMapper.sanitizeForLlm([]);
      expect(result, isEmpty);
    });

    test('单条 tool result 而非 group', () {
      final messages = [
        userMsg('u1', 'read'),
        assistantMsg('a1', '', toolCalls: [tc('tc1', 'file_read')]),
        toolResultMsg('r1', 'tc1', 'file content'),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        strictMode: true,
      );
      expect(result.length, equals(3));
    });

    test('单条孤立 tool result 被丢弃', () {
      final messages = [
        userMsg('u1', 'read'),
        toolResultMsg('r1', 'tc_unknown', 'orphan'),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        strictMode: true,
      );
      expect(result.length, equals(1), reason: '孤立的 tool result 应被丢弃');
    });

    test('strictMode=true: 复杂交错序列（模拟实际 bug 场景）', () {
      // 模拟实际 bug：messages.2 是 tool_result，引用了 messages.1 的 tool_use_id
      // 但 messages.1 和 messages.2 之间可能有其他消息插入
      final messages = [
        systemMsg('sys1', 'You are a helpful assistant.'),
        userMsg('u1', '请帮我搜索文件'),
        assistantMsg(
          'a1',
          '我来搜索',
          toolCalls: [tc('call_00_abc123', 'content_search')],
        ),
        assistantMsg('a_inject', '正在处理...'), // 注入的 assistant 消息
        toolResultGroup('r1', [tr('call_00_abc123', '搜索结果')]),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        strictMode: true,
      );

      // 阶段一：expectedIds={call_00_abc123}，遇到 a_inject(无 toolCalls) →
      //   进入 else 分支，strip a1 的 toolCalls，清空 expectedIds
      // 阶段二：r1 前面没有 assistant(toolCalls) → 丢弃
      expect(
        result.any((m) => m.id == 'r1'),
        isFalse,
        reason: 'tool_result 不紧邻 assistant(toolCalls)',
      );

      // 验证最终序列不包含任何 toolCalls
      for (final m in result) {
        if (m.role == MessageRole.assistant) {
          expect(m.toolCalls, isNull, reason: '最终序列中不应有残留的 toolCalls');
        }
      }
    });

    test('strictMode=true: 连续多条 tool_result 紧邻同一 assistant', () {
      // 一个 assistant(toolCalls) 后跟多个 tool_result（分组合并后的场景）
      final messages = [
        userMsg('u1', 'multi tool'),
        assistantMsg(
          'a1',
          '',
          toolCalls: [tc('tc1', 'tool_a'), tc('tc2', 'tool_b')],
        ),
        toolResultGroup('r1', [tr('tc1', 'result a')]),
        toolResultGroup('r2', [tr('tc2', 'result b')]),
        assistantMsg('a2', 'done'),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        strictMode: true,
      );

      // 阶段一：tc1 和 tc2 都在 expectedIds 中，r1 和 r2 都匹配
      // 阶段二：r1 紧邻 a1(toolCalls: [tc1, tc2])，tc1 在其中 → 保留
      //         r2 紧邻 r1，但前一条 assistant(toolCalls) 仍是 a1，tc2 在其中 → 保留
      expect(result.any((m) => m.id == 'r1'), isTrue);
      expect(result.any((m) => m.id == 'r2'), isTrue);
      expect(result.length, equals(5));
    });

    test('跨轮次合并的 tool_result group 会按 assistant 拆分配对', () {
      final messages = [
        userMsg('u1', 'do two steps'),
        assistantMsg('a1', 'step one', toolCalls: [tc('tc1', 'tool_a')]),
        assistantMsg('a2', 'step two', toolCalls: [tc('tc2', 'tool_b')]),
        toolResultGroup('r_merged', [
          tr('tc1', 'result a'),
          tr('tc2', 'result b'),
        ]),
        assistantMsg('a3', 'done'),
      ];

      final result = LlmMessageMapper.sanitizeForLlm(
        messages,
        knownToolCallIds: {'tc1', 'tc2'},
      );

      expect(result.length, equals(6));
      expect(result[1].id, equals('a1'));
      expect(result[2].role, equals(MessageRole.tool));
      expect(result[2].toolResults!.map((r) => r.toolCallId), equals(['tc1']));
      expect(result[3].id, equals('a2'));
      expect(result[4].role, equals(MessageRole.tool));
      expect(result[4].toolResults!.map((r) => r.toolCallId), equals(['tc2']));
      expect(result[5].id, equals('a3'));
    });
  });
}
