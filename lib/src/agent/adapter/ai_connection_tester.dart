import 'dart:async';

import 'package:dio/dio.dart' as dio;
import 'package:llm_dart/llm_dart.dart' as llm;

import 'ollama_client.dart';
import 'provider_config.dart';

/// AI 连接测试结果
class AiConnectionTestResult {
  /// 是否连接成功
  final bool success;

  /// 成功时的回复文本
  final String? response;

  /// 失败时的错误信息
  final String? error;

  /// 请求耗时（毫秒）
  final int latencyMs;

  const AiConnectionTestResult({
    required this.success,
    this.response,
    this.error,
    required this.latencyMs,
  });

  @override
  String toString() {
    if (success) {
      return '✅ 成功 (${latencyMs}ms): ${response ?? '(空回复)'}';
    }
    return '❌ 失败 (${latencyMs}ms): ${error ?? '未知错误'}';
  }
}

/// AI 连接测试器
///
/// 使用 [llm_dart] 发送一条简短消息验证 API 连通性，
/// 供 AIConfigView 的「测试连接」按钮调用。
///
/// 用法：
/// ```dart
/// final result = await AiConnectionTester.testConnection(
///   ProviderConfig(provider: LLMProvider.openai, model: 'gpt-4o-mini', apiKey: 'sk-xxx'),
/// );
/// if (result.success) {
///   print('连接成功: ${result.response}');
/// } else {
///   print('连接失败: ${result.error}');
/// }
/// ```
class AiConnectionTester {
  /// 默认测试消息（简短，最小化 token 消耗）
  static const String defaultTestMessage = 'Hi';

  /// 默认超时时间
  static const Duration defaultTimeout = Duration(seconds: 30);

  /// 测试 AI 连接
  ///
  /// 使用 [config] 构建 ChatCapability 并发送一条简短的非流式消息。
  ///
  /// [testMessage] 测试消息内容，默认为 "Hi"。
  /// [timeout] 请求超时时间，默认为 30 秒。
  ///
  /// 返回 [AiConnectionTestResult]，包含成功/失败状态、回复内容、错误信息和耗时。
  static Future<AiConnectionTestResult> testConnection(
    ProviderConfig config, {
    String testMessage = defaultTestMessage,
    Duration timeout = defaultTimeout,
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      // 1. 构建前校验
      config.validate();

      // 2. 构建 ChatCapability（与 llm_chat_adapter._buildChatCapability 逻辑一致）
      final capability = await _buildChatCapability(config).timeout(timeout);

      // 3. 发送非流式测试消息
      final messages = [llm.ChatMessage.user(testMessage)];
      final response = await capability.chat(messages).timeout(timeout);

      stopwatch.stop();

      final text = response.text;
      if (text == null || text.trim().isEmpty) {
        return AiConnectionTestResult(
          success: false,
          error: 'API 返回空回复',
          latencyMs: stopwatch.elapsedMilliseconds,
        );
      }

      return AiConnectionTestResult(
        success: true,
        response: text.trim(),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on ArgumentError catch (e) {
      stopwatch.stop();
      return AiConnectionTestResult(
        success: false,
        error: '配置校验失败: ${e.message}',
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on TimeoutException {
      stopwatch.stop();
      return AiConnectionTestResult(
        success: false,
        error: config.provider == LLMProvider.ollama
            ? '连接 Ollama 超时 (${timeout.inSeconds}s)，请检查 ollama serve 是否正常运行'
            : '请求超时 (${timeout.inSeconds}s)',
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on dio.DioException catch (e) {
      stopwatch.stop();
      return AiConnectionTestResult(
        success: false,
        error: _formatProviderError(config.provider, e),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } catch (e) {
      stopwatch.stop();
      return AiConnectionTestResult(
        success: false,
        error: _formatGenericError(config.provider, e),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  /// 构建 ChatCapability
  ///
  /// 逻辑与 llm_chat_adapter.dart 中的 _buildChatCapability 保持一致。
  static Future<llm.ChatCapability> _buildChatCapability(
    ProviderConfig config,
  ) async {
    final builder = llm.ai();

    switch (config.provider) {
      case LLMProvider.openai:
        builder.openai();
      case LLMProvider.anthropic:
        builder.anthropic();
      case LLMProvider.google:
        builder.google();
      case LLMProvider.ollama:
        builder.ollama();
    }

    builder.model(config.model);

    if (config.apiKey != null && config.apiKey!.isNotEmpty) {
      builder.apiKey(config.apiKey!);
    }

    if (config.baseUrl != null && config.baseUrl!.isNotEmpty) {
      builder.baseUrl(config.baseUrl!);
    }

    builder.temperature(config.options.temperature);

    if (config.options.maxTokens != null) {
      builder.maxTokens(config.options.maxTokens!);
    } else {
      builder.maxTokens(1024); // 测试连接不需要大 token 数
    }

    builder.reasoning(false);

    if (config.options.topP != null) {
      builder.topP(config.options.topP!);
    }

    if (config.options.stop != null && config.options.stop!.isNotEmpty) {
      builder.stopSequences(config.options.stop!);
    }

    builder.enableLogging(false); // 测试连接不需要日志
    // Ollama 本地推理可能较慢，测试连接给予更长超时
    final timeout = config.provider == LLMProvider.ollama
        ? const Duration(minutes: 10)
        : const Duration(minutes: 5);
    builder.timeout(timeout);

    return await builder.build();
  }

  /// 格式化 DioException 为提供商相关的错误信息
  ///
  /// 针对 Ollama 提供更友好的错误提示。
  static String _formatProviderError(
    LLMProvider provider,
    dio.DioException e,
  ) {
    if (provider == LLMProvider.ollama) {
      return OllamaClient.formatDioError(e);
    }

    // 通用错误格式化
    switch (e.type) {
      case dio.DioExceptionType.connectionError:
        return '连接被拒绝，请检查 API 地址是否正确';
      case dio.DioExceptionType.connectionTimeout:
      case dio.DioExceptionType.sendTimeout:
      case dio.DioExceptionType.receiveTimeout:
        return '连接超时，请检查网络或 API 地址';
      case dio.DioExceptionType.badResponse:
        final statusCode = e.response?.statusCode;
        if (statusCode == 401) {
          return 'API 密钥无效或已过期';
        }
        return 'API 返回错误 (HTTP $statusCode): ${e.response?.statusMessage ?? '未知'}';
      default:
        return '连接失败: ${e.message ?? e.type.toString()}';
    }
  }

  /// 格式化通用异常，针对 Ollama 提供更友好的提示
  static String _formatGenericError(LLMProvider provider, Object e) {
    if (provider == LLMProvider.ollama) {
      final msg = e.toString();
      // 检测常见 Ollama 错误
      if (msg.contains('Connection refused') || msg.contains('connection refused')) {
        return 'Ollama 服务未启动，请先运行 `ollama serve`';
      }
      if (msg.contains('model not found') || msg.contains('404')) {
        return '模型不存在，请先运行 `ollama pull <model>` 拉取模型';
      }
      return 'Ollama 连接失败: $msg';
    }
    return e.toString();
  }
}
