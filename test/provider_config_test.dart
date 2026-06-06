import 'package:test/test.dart';
import 'package:wenzagent/src/agent/adapter/provider_config.dart';

void main() {
  group('ProviderConfig streamEnabled defaults', () {
    test('DeepSeek direct config defaults to non-streaming', () {
      const config = ProviderConfig(
        provider: LLMProvider.deepseek,
        model: 'deepseek-chat',
        apiKey: 'test-key',
      );

      expect(config.streamEnabled, isFalse);
    });

    test('DeepSeek fromMap defaults to non-streaming', () {
      final config = ProviderConfig.fromMap({
        'provider': 'deepseek',
        'model': 'deepseek-chat',
        'apiKey': 'test-key',
      });

      expect(config.streamEnabled, isFalse);
    });

    test('DeepSeek can explicitly enable streaming', () {
      final config = ProviderConfig.fromMap({
        'provider': 'deepseek',
        'model': 'deepseek-chat',
        'apiKey': 'test-key',
        'streamEnabled': true,
      });

      expect(config.streamEnabled, isTrue);
    });

    test('Other providers default to streaming', () {
      const config = ProviderConfig(
        provider: LLMProvider.openai,
        model: 'gpt-4o',
        apiKey: 'test-key',
      );

      expect(config.streamEnabled, isTrue);
    });
  });
}
