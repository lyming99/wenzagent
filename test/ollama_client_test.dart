import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'package:wenzagent/wenzagent.dart';

void main() {
  group('OllamaModelInfo', () {
    test('fromMap parses all fields correctly', () {
      final map = {
        'name': 'llama3:latest',
        'model': 'llama3:latest',
        'modified_at': '2024-01-15T10:30:00Z',
        'size': 4661224676,
        'digest': 'abc123def456',
      };

      final info = OllamaModelInfo.fromMap(map);

      expect(info.name, 'llama3:latest');
      expect(info.model, 'llama3:latest');
      expect(info.modifiedAt, isNotNull);
      expect(info.size, 4661224676);
      expect(info.digest, 'abc123def456');
    });

    test('fromMap handles missing fields gracefully', () {
      final map = <String, dynamic>{};

      final info = OllamaModelInfo.fromMap(map);

      expect(info.name, '');
      expect(info.model, '');
      expect(info.modifiedAt, isNull);
      expect(info.size, isNull);
      expect(info.digest, isNull);
    });

    test('fromMap handles int timestamp for modified_at', () {
      final map = {
        'name': 'test',
        'model': 'test',
        'modified_at': 1705312200000,
      };

      final info = OllamaModelInfo.fromMap(map);

      expect(info.modifiedAt, isNotNull);
    });

    test('toMap produces correct output', () {
      final info = OllamaModelInfo(
        name: 'llama3:latest',
        model: 'llama3:latest',
        size: 1000,
      );

      final map = info.toMap();

      expect(map['name'], 'llama3:latest');
      expect(map['model'], 'llama3:latest');
      expect(map['size'], 1000);
      expect(map['modifiedAt'], isNull);
    });

    test('toString contains model name', () {
      final info = OllamaModelInfo(name: 'qwen2.5:7b', model: 'qwen2.5:7b');
      expect(info.toString(), contains('qwen2.5:7b'));
    });
  });

  group('OllamaModelDetail', () {
    test('fromMap parses details correctly', () {
      final map = {
        'name': 'llama3:latest',
        'modified_at': '2024-01-15T10:30:00Z',
        'details': {
          'family': 'llama',
          'parameter_size': '8B',
          'quantization_level': 'Q4_0',
        },
        'model_info': {
          'llama.context_length': 8192,
          'llama.embedding_length': 4096,
        },
        'system': 'You are a helpful assistant.',
        'template': '{{ .Prompt }}',
      };

      final detail = OllamaModelDetail.fromMap(map);

      expect(detail.name, 'llama3:latest');
      expect(detail.family, 'llama');
      expect(detail.parameterSize, '8B');
      expect(detail.quantizationLevel, 'Q4_0');
      expect(detail.contextLength, 8192);
      expect(detail.system, 'You are a helpful assistant.');
      expect(detail.template, '{{ .Prompt }}');
    });

    test('fromMap handles missing details gracefully', () {
      final map = <String, dynamic>{
        'name': 'test-model',
      };

      final detail = OllamaModelDetail.fromMap(map);

      expect(detail.name, 'test-model');
      expect(detail.family, isNull);
      expect(detail.parameterSize, isNull);
      expect(detail.quantizationLevel, isNull);
      expect(detail.contextLength, isNull);
    });

    test('fromMap extracts context_length from model_info', () {
      final map = {
        'name': 'qwen2.5:7b',
        'model_info': {
          'qwen2.context_length': 131072,
        },
      };

      final detail = OllamaModelDetail.fromMap(map);

      expect(detail.contextLength, 131072);
    });

    test('displayName formats correctly with details', () {
      final detail = OllamaModelDetail(
        name: 'llama3:latest',
        parameterSize: '8B',
        quantizationLevel: 'Q4_0',
      );

      expect(detail.displayName, 'llama3:latest (8B, Q4_0)');
    });

    test('displayName formats correctly without details', () {
      final detail = OllamaModelDetail(name: 'llama3:latest');

      expect(detail.displayName, 'llama3:latest');
    });

    test('toMap roundtrip preserves data', () {
      final detail = OllamaModelDetail(
        name: 'test',
        family: 'llama',
        parameterSize: '7B',
        quantizationLevel: 'Q4_0',
        contextLength: 4096,
      );

      final map = detail.toMap();

      expect(map['name'], 'test');
      expect(map['family'], 'llama');
      expect(map['parameterSize'], '7B');
      expect(map['quantizationLevel'], 'Q4_0');
      expect(map['contextLength'], 4096);
    });
  });

  group('OllamaHealthResult', () {
    test('healthy result toString', () {
      final result = OllamaHealthResult(
        isHealthy: true,
        version: '0.1.20',
        modelCount: 5,
        latencyMs: 42,
      );

      final str = result.toString();
      expect(str, contains('✅'));
      expect(str, contains('5 个模型'));
      expect(str, contains('v0.1.20'));
    });

    test('unhealthy result toString', () {
      final result = OllamaHealthResult(
        isHealthy: false,
        error: 'Connection refused',
        latencyMs: 100,
      );

      final str = result.toString();
      expect(str, contains('❌'));
      expect(str, contains('Connection refused'));
    });
  });

  group('OllamaClient', () {
    test('default baseUrl is http://localhost:11434', () {
      final client = OllamaClient();
      expect(client.baseUrl, 'http://localhost:11434');
      client.dispose();
    });

    test('custom baseUrl strips trailing slashes', () {
      final client = OllamaClient(baseUrl: 'http://192.168.1.100:11434///');
      expect(client.baseUrl, 'http://192.168.1.100:11434');
      client.dispose();
    });

    test('null baseUrl uses default', () {
      final client = OllamaClient(baseUrl: null);
      expect(client.baseUrl, 'http://localhost:11434');
      client.dispose();
    });
  });

  group('ProviderConfig Ollama defaults', () {
    test('Ollama auto-fills default baseUrl', () {
      final config = ProviderConfig.fromMap({
        'provider': 'ollama',
        'model': 'llama3',
      });

      expect(config.provider, LLMProvider.ollama);
      expect(config.baseUrl, 'http://localhost:11434');
    });

    test('Ollama respects explicit baseUrl', () {
      final config = ProviderConfig.fromMap({
        'provider': 'ollama',
        'model': 'llama3',
        'baseUrl': 'http://192.168.1.100:11434',
      });

      expect(config.baseUrl, 'http://192.168.1.100:11434');
    });

    test('Ollama auto-fills default model when gpt-4o', () {
      final config = ProviderConfig.fromMap({
        'provider': 'ollama',
      });

      expect(config.model, 'llama3');
    });

    test('Ollama keeps explicit model name', () {
      final config = ProviderConfig.fromMap({
        'provider': 'ollama',
        'model': 'qwen2.5:7b',
      });

      expect(config.model, 'qwen2.5:7b');
    });

    test('Ollama validation passes without apiKey', () {
      final config = ProviderConfig.fromMap({
        'provider': 'ollama',
        'model': 'llama3',
      });

      // Should not throw
      expect(() => config.validate(), returnsNormally);
    });

    test('OpenAI still requires apiKey', () {
      final config = ProviderConfig.fromMap({
        'provider': 'openai',
      });

      expect(() => config.validate(), throwsArgumentError);
    });
  });

  group('OllamaClient.formatDioError', () {
    test('connection error with refused produces helpful message', () {
      final error = DioException(
        type: DioExceptionType.connectionError,
        message: 'Connection refused',
        requestOptions: RequestOptions(path: '/test'),
      );

      final msg = OllamaClient.formatDioError(error);
      expect(msg, contains('ollama serve'));
    });

    test('timeout produces helpful message', () {
      final error = DioException(
        type: DioExceptionType.connectionTimeout,
        requestOptions: RequestOptions(path: '/test'),
      );

      final msg = OllamaClient.formatDioError(error);
      expect(msg, contains('超时'));
    });

    test('404 produces model not found message', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/test'),
          statusCode: 404,
        ),
        requestOptions: RequestOptions(path: '/test'),
      );

      final msg = OllamaClient.formatDioError(error);
      expect(msg, contains('ollama pull'));
    });
  });
}
