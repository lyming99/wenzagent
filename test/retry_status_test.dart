import 'package:test/test.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/entity/queued_message.dart';
import 'package:wenzagent/src/shared/chat_message.dart';

void main() {
  group('Retry status', () {
    test('AgentStatus.retrying round trips through snapshots', () {
      final snapshot = AgentStateSnapshot(
        status: AgentStatus.retrying,
        currentProcessingMessageId: 'msg-retry',
        queuedMessageIds: const ['msg-next'],
        queueLength: 1,
      );

      final restored = AgentStateSnapshot.fromMap(snapshot.toMap());

      expect(AgentStatus.fromString('retrying'), equals(AgentStatus.retrying));
      expect(restored.status, equals(AgentStatus.retrying));
      expect(restored.currentProcessingMessageId, equals('msg-retry'));
      expect(restored.queuedMessageIds, equals(['msg-next']));
      expect(restored.queueLength, equals(1));
    });

    test('message retrying status parses and converts consistently', () {
      expect(
        MessageStatus.fromString('retrying'),
        equals(MessageStatus.retrying),
      );

      expect(
        MessageProcessingStatus.values,
        contains(MessageProcessingStatus.retrying),
      );

      // ignore: deprecated_member_use
      expect(
        AgentMessageStatus.fromString('retrying'),
        AgentMessageStatus.retrying,
      );
      // ignore: deprecated_member_use
      expect(
        AgentMessageStatus.retrying.toMessageProcessingStatus(),
        equals(MessageProcessingStatus.retrying),
      );
      // ignore: deprecated_member_use
      expect(
        MessageProcessingStatus.retrying.toAgentMessageStatus(),
        // ignore: deprecated_member_use
        equals(AgentMessageStatus.retrying),
      );
    });
  });
}
