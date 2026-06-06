import 'package:test/test.dart';
import 'package:wenzagent/src/agent/adapter/retry_config.dart';

void main() {
  group('RetryConfig defaults', () {
    test('uses fixed 2/4/8/16/16 second retry delays', () {
      const config = RetryConfig();

      expect(config.maxRetries, 5);
      expect(config.baseDelayMs, 2000);
      expect(config.maxDelayMs, 16000);
      expect(config.jitter, isFalse);
      expect(List.generate(config.maxRetries, config.nextDelay), [
        2000,
        4000,
        8000,
        16000,
        16000,
      ]);
    });

    test('fromMap uses the same defaults when retry fields are omitted', () {
      final config = RetryConfig.fromMap({});

      expect(config.maxRetries, 5);
      expect(config.baseDelayMs, 2000);
      expect(config.maxDelayMs, 16000);
      expect(config.jitter, isFalse);
      expect(List.generate(config.maxRetries, config.nextDelay), [
        2000,
        4000,
        8000,
        16000,
        16000,
      ]);
    });
  });
}
