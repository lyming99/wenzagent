import 'package:test/test.dart';
import 'package:wenzagent/src/shared/chat_message.dart';
import 'package:wenzagent/src/shared/message_record.dart';

void main() {
  test('ChatMessage.fromJson restores tool results from metadata fallback', () {
    final json = {
      'id': 'tool-results-json',
      'employeeId': 'employee-1',
      'role': 'tool',
      'type': 'functionResult',
      'content': 'result',
      'createdAt': DateTime.fromMillisecondsSinceEpoch(1000).toIso8601String(),
      'metadata': {
        'toolResults': [
          {
            'toolCallId': 'call-read',
            'content': 'read result',
            'name': 'file_read',
          },
        ],
      },
    };

    final restored = ChatMessage.fromJson(json);

    expect(restored.isToolResultGroup, isTrue);
    expect(restored.toolResults!.single.toolCallId, 'call-read');
    expect(restored.metadata, isNull);
    expect((json['metadata'] as Map)['toolResults'], isNotNull);
  });

  test('MessageMapper preserves grouped tool results through SQL params', () {
    final message =
        ChatMessage.toolResultGroup(
          id: 'tool-results-1',
          employeeId: 'employee-1',
          results: const [
            ToolResult(
              toolCallId: 'call-read',
              content: 'read result',
              name: 'file_read',
            ),
            ToolResult(
              toolCallId: 'call-list',
              content: 'list result',
              name: 'file_list',
            ),
          ],
          createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ).copyWith(
          metadata: const {
            'toolNames': ['file_read', 'file_list'],
          },
        );

    final params = MessageMapper.toSqlParams(message, deviceId: 'device-1');
    final row = <String, Object?>{
      'uuid': params[0],
      'employee_id': params[1],
      'device_id': params[2],
      'role': params[3],
      'type': params[4],
      'content': params[5],
      'tool_call_id': params[6],
      'tool_name': params[7],
      'tool_arguments': params[8],
      'tool_result': params[9],
      'tool_calls': params[10],
      'processing_status': params[11],
      'processing_error': params[12],
      'input_tokens': params[13],
      'output_tokens': params[14],
      'is_read': params[15],
      'metadata': params[16],
      'deleted': params[17],
      'create_time': params[18],
      'update_time': params[19],
      'seq': params[20],
    };

    final restored = MessageMapper.fromRow(row);

    expect(restored.isToolResultGroup, isTrue);
    expect(restored.toolResults!.map((result) => result.toolCallId), [
      'call-read',
      'call-list',
    ]);
    expect(restored.toolResults!.map((result) => result.content), [
      'read result',
      'list result',
    ]);
    expect(restored.metadata, {
      'toolNames': ['file_read', 'file_list'],
    });
  });
}
