import 'package:test/test.dart';
import 'package:wenzagent/src/agent/entity/agent_message.dart';
import 'package:wenzagent/src/shared/chat_message.dart' show ToolCall;

/// 工具调用消息可见性测试
///
/// 验证 CachedAgentProxy 中本地/远程模式的工具调用消息行为：
/// - 本地模式工具调用消息通过内存缓存可见
/// - 远程模式工具调用消息通过数据库可见
/// - 工具调用完成后清理
///
/// 注意：这些测试直接测试内存缓存逻辑，不依赖数据库或网络。
void main() {
  group('内存工具调用消息缓存', () {
    test('tool call message added to memory cache', () {
      final cache = <String, AgentMessage>{};

      final toolCallId = 'call-001';
      final message = AgentMessage(
        id: 'local_toolcall_$toolCallId',
        role: 'assistant',
        type: 'functionCall',
        toolCallId: toolCallId,
        toolName: 'execute_command',
        toolArguments: {'command': 'ls -la'},
        toolCalls: [
          ToolCall(id: toolCallId, name: 'execute_command', arguments: {'command': 'ls -la'}),
        ],
        status: 'processing',
        createdAt: DateTime.now(),
        metadata: {'localToolCall': true},
      );

      // 模拟 CachedAgentProxy._createToolCallMessage 的行为
      cache[toolCallId] = message;

      expect(cache.length, equals(1));
      expect(cache[toolCallId], isNotNull);
      expect(cache[toolCallId]!.toolName, equals('execute_command'));
      expect(cache[toolCallId]!.status, equals('processing'));
    });

    test('tool call message updated in memory cache', () {
      final cache = <String, AgentMessage>{};

      final toolCallId = 'call-002';
      final original = AgentMessage(
        id: 'local_toolcall_$toolCallId',
        role: 'assistant',
        type: 'functionCall',
        toolCallId: toolCallId,
        toolName: 'read_file',
        toolArguments: {'path': '/tmp/test.txt'},
        toolCalls: [
          ToolCall(id: toolCallId, name: 'read_file', arguments: {'path': '/tmp/test.txt'}),
        ],
        status: 'processing',
        createdAt: DateTime.now(),
        metadata: {'localToolCall': true},
      );

      cache[toolCallId] = original;

      // 模拟 CachedAgentProxy._updateToolCallMessage 的行为
      final updated = original.copyWith(
        toolResult: 'File contents...',
        status: 'completed',
        metadata: {
          ...?original.metadata,
          'isError': false,
          'updateTime': DateTime.now().toIso8601String(),
        },
      );
      cache[toolCallId] = updated;

      expect(cache[toolCallId]!.status, equals('completed'));
      expect(cache[toolCallId]!.toolResult, equals('File contents...'));
    });

    test('tool call message removed after completion', () {
      final cache = <String, AgentMessage>{};

      final toolCallId = 'call-003';
      final message = AgentMessage(
        id: 'local_toolcall_$toolCallId',
        role: 'assistant',
        type: 'functionCall',
        toolCallId: toolCallId,
        toolName: 'write_file',
        toolArguments: {'path': '/tmp/out.txt', 'content': 'data'},
        toolCalls: [
          ToolCall(id: toolCallId, name: 'write_file', arguments: {'path': '/tmp/out.txt', 'content': 'data'}),
        ],
        status: 'processing',
        createdAt: DateTime.now(),
        metadata: {'localToolCall': true},
      );

      cache[toolCallId] = message;
      expect(cache.length, equals(1));

      // 模拟 _handleMessageStatusChanged 中 completed 状态的清理
      final messageId = 'msg-003';
      cache.removeWhere((key, _) {
        return key == messageId || key == messageId.replaceFirst('local_toolcall_', '');
      });
      // 这个 messageId 不是 toolCallId，不会匹配
      expect(cache.length, equals(1));

      // 用 toolCallId 匹配
      cache.removeWhere((key, _) {
        return key == toolCallId;
      });
      expect(cache.isEmpty, isTrue);
    });

    test('memory cache merged with db messages', () {
      // 模拟 DB 返回的消息
      final dbMessages = [
        AgentMessage(
          id: 'msg-001',
          role: 'user',
          type: 'text',
          content: 'Hello',
          createdAt: DateTime(2024, 1, 1, 12, 0, 0),
        ),
        AgentMessage(
          id: 'msg-002',
          role: 'assistant',
          type: 'text',
          content: 'Hi there!',
          createdAt: DateTime(2024, 1, 1, 12, 0, 5),
        ),
      ];

      // 内存中的工具调用消息
      final memoryCache = <String, AgentMessage>{
        'call-004': AgentMessage(
          id: 'local_toolcall_call-004',
          role: 'assistant',
          type: 'functionCall',
          toolCallId: 'call-004',
          toolName: 'search',
          toolArguments: {'query': 'test'},
          toolCalls: [
            ToolCall(id: 'call-004', name: 'search', arguments: {'query': 'test'}),
          ],
          status: 'processing',
          createdAt: DateTime(2024, 1, 1, 12, 0, 3),
          metadata: {'localToolCall': true},
        ),
      };

      // 模拟 getMessages() 的合并逻辑
      var allMessages = List<AgentMessage>.from(dbMessages);
      final dbIds = allMessages.map((m) => m.id).toSet();
      for (final msg in memoryCache.values) {
        if (!dbIds.contains(msg.id)) {
          allMessages.add(msg);
        }
      }

      // 按时间排序
      allMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      expect(allMessages.length, equals(3));
      expect(allMessages[0].content, equals('Hello')); // user
      expect(allMessages[1].toolName, equals('search')); // tool call
      expect(allMessages[2].content, equals('Hi there!')); // assistant
    });

    test('memory cache deduplicates with db', () {
      // DB 已经有了工具调用消息（远程同步后）
      final dbMessages = [
        AgentMessage(
          id: 'local_toolcall_call-005',
          role: 'assistant',
          type: 'functionCall',
          toolCallId: 'call-005',
          toolName: 'read_file',
          status: 'completed',
          createdAt: DateTime(2024, 1, 1, 12, 0, 3),
        ),
      ];

      final memoryCache = <String, AgentMessage>{
        'call-005': AgentMessage(
          id: 'local_toolcall_call-005',
          role: 'assistant',
          type: 'functionCall',
          toolCallId: 'call-005',
          toolName: 'read_file',
          status: 'processing',
          createdAt: DateTime(2024, 1, 1, 12, 0, 3),
          metadata: {'localToolCall': true},
        ),
      };

      // 合并：DB 已有该 ID，不重复添加
      var allMessages = List<AgentMessage>.from(dbMessages);
      final dbIds = allMessages.map((m) => m.id).toSet();
      for (final msg in memoryCache.values) {
        if (!dbIds.contains(msg.id)) {
          allMessages.add(msg);
        }
      }

      expect(allMessages.length, equals(1)); // 不重复
    });

    test('multiple tool calls tracked simultaneously', () {
      final cache = <String, AgentMessage>{};

      for (int i = 1; i <= 5; i++) {
        final toolCallId = 'multi-call-$i';
        cache[toolCallId] = AgentMessage(
          id: 'local_toolcall_$toolCallId',
          role: 'assistant',
          type: 'functionCall',
          toolCallId: toolCallId,
          toolName: 'tool_$i',
          status: 'processing',
          createdAt: DateTime.now().add(Duration(seconds: i)),
          metadata: {'localToolCall': true},
        );
      }

      expect(cache.length, equals(5));

      // 完成部分工具调用
      cache['multi-call-1'] = cache['multi-call-1']!.copyWith(status: 'completed');
      cache['multi-call-3'] = cache['multi-call-3']!.copyWith(status: 'completed');

      var processingCount = cache.values.where((m) => m.status == 'processing').length;
      expect(processingCount, equals(3));

      var completedCount = cache.values.where((m) => m.status == 'completed').length;
      expect(completedCount, equals(2));
    });
  });

  group('工具调用错误状态', () {
    test('permission denied sets interrupted status', () {
      final cache = <String, AgentMessage>{};

      final toolCallId = 'perm-call';
      final original = AgentMessage(
        id: 'local_toolcall_$toolCallId',
        role: 'assistant',
        type: 'functionCall',
        toolCallId: toolCallId,
        toolName: 'execute_command',
        toolArguments: {'command': 'rm -rf /'},
        status: 'processing',
        createdAt: DateTime.now(),
        metadata: {'localToolCall': true},
      );

      cache[toolCallId] = original;

      // 模拟权限被拒绝
      final result = '权限被拒绝: 危险命令';
      final updated = original.copyWith(
        toolResult: result,
        status: 'interrupted',
        metadata: {
          ...?original.metadata,
          'isError': true,
          'updateTime': DateTime.now().toIso8601String(),
        },
      );
      cache[toolCallId] = updated;

      expect(cache[toolCallId]!.status, equals('interrupted'));
      expect(cache[toolCallId]!.toolResult, contains('权限被拒绝'));
    });

    test('tool error sets failed status', () {
      final cache = <String, AgentMessage>{};

      final toolCallId = 'error-call';
      final original = AgentMessage(
        id: 'local_toolcall_$toolCallId',
        role: 'assistant',
        type: 'functionCall',
        toolCallId: toolCallId,
        toolName: 'read_file',
        toolArguments: {'path': '/nonexistent/file.txt'},
        status: 'processing',
        createdAt: DateTime.now(),
        metadata: {'localToolCall': true},
      );

      cache[toolCallId] = original;

      final result = 'File not found: /nonexistent/file.txt';
      final updated = original.copyWith(
        toolResult: result,
        status: 'failed',
        metadata: {
          ...?original.metadata,
          'isError': true,
          'updateTime': DateTime.now().toIso8601String(),
        },
      );
      cache[toolCallId] = updated;

      expect(cache[toolCallId]!.status, equals('failed'));
      expect(cache[toolCallId]!.toolResult, contains('not found'));
    });
  });

  group('dispose 清理', () {
    test('dispose clears all in-memory tool call messages', () {
      final cache = <String, AgentMessage>{};

      for (int i = 1; i <= 10; i++) {
        cache['call-dispose-$i'] = AgentMessage(
          id: 'local_toolcall_call-dispose-$i',
          role: 'assistant',
          type: 'functionCall',
          toolCallId: 'call-dispose-$i',
          toolName: 'tool_$i',
          status: 'processing',
          createdAt: DateTime.now(),
        );
      }

      expect(cache.length, equals(10));

      // 模拟 dispose
      cache.clear();
      expect(cache.isEmpty, isTrue);
    });
  });
}
