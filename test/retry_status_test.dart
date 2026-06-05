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

    test('AgentRetryProgress can be queried from snapshots', () {
      final nextRetryAt = DateTime.parse('2025-01-01T00:00:05.000Z');
      final updatedAt = DateTime.parse('2025-01-01T00:00:00.000Z');
      final snapshot = AgentStateSnapshot(
        status: AgentStatus.retrying,
        currentProcessingMessageId: 'msg-retry',
        retryProgress: AgentRetryProgress(
          attempt: 2,
          maxRetries: 5,
          error: 'HTTP 429',
          errors: const ['HTTP 500', 'HTTP 429'],
          delayMs: 5000,
          nextRetryAt: nextRetryAt,
          contextOverflow: true,
          contextCompressed: true,
          updatedAt: updatedAt,
        ),
      );

      final map = snapshot.toMap();
      final retryProgress = map['retryProgress'] as Map<String, dynamic>;

      expect(retryProgress['attempt'], equals(2));
      expect(retryProgress['maxRetries'], equals(5));
      expect(retryProgress['error'], equals('HTTP 429'));
      expect(retryProgress['errors'], equals(['HTTP 500', 'HTTP 429']));
      expect(retryProgress['delayMs'], equals(5000));
      expect(
        retryProgress['nextRetryAt'],
        equals(nextRetryAt.toIso8601String()),
      );
      expect(retryProgress['contextOverflow'], isTrue);
      expect(retryProgress['contextCompressed'], isTrue);
      expect(retryProgress['progress'], equals(0.4));

      final restored = AgentStateSnapshot.fromMap(map);
      expect(restored.retryProgress?.attempt, equals(2));
      expect(restored.retryProgress?.maxRetries, equals(5));
      expect(restored.retryProgress?.error, equals('HTTP 429'));
      expect(restored.retryProgress?.errors, equals(['HTTP 500', 'HTTP 429']));
      expect(restored.retryProgress?.delayMs, equals(5000));
      expect(restored.retryProgress?.nextRetryAt, equals(nextRetryAt));
      expect(restored.retryProgress?.contextOverflow, isTrue);
      expect(restored.retryProgress?.contextCompressed, isTrue);
      expect(restored.retryProgress?.updatedAt, equals(updatedAt));
    });

    test('AgentRetryProgress restores legacy single error as errors list', () {
      final restored = AgentRetryProgress.fromMap({
        'attempt': 1,
        'maxRetries': 3,
        'error': 'HTTP 503',
      });

      expect(restored.error, equals('HTTP 503'));
      expect(restored.errors, equals(['HTTP 503']));
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
