import 'context_compression_config.dart';
import 'retry_config.dart';

/// LLM 提供商类型
enum LLMProvider { openai, anthropic, google, ollama, deepseek }

/// LLM 提供商配置
class ProviderConfig {
  /// 提供商类型
  final LLMProvider provider;

  /// 模型标识
  final String model;

  /// API 密钥
  final String? apiKey;

  /// API 基础 URL
  final String? baseUrl;

  /// 模型参数
  final LLMOptions options;

  /// OpenAI 组织 ID
  final String? organization;

  /// 上下文压缩配置（可选）
  ///
  /// 设置后启用上下文压缩，控制发送给 LLM 的消息总 token 数。
  final ContextCompressionConfig? compressionConfig;

  /// 重试配置（可选）
  ///
  /// 设置后启用 LLM 调用的自动重试机制，应对频率限制（429）和临时服务端错误（5xx）。
  /// 使用指数退避策略。未设置时使用 [RetryConfig.defaultConfig]。
  final RetryConfig? retryConfig;

  /// 是否使用真实流式响应。
  ///
  /// 默认开启，使用真实流式接口实时读取文本、思考内容和工具调用。
  /// DeepSeek 默认关闭，使用非流式 [chatWithTools] 调用。
  /// 设置为 false 时回退到旧的非流式 [chatWithTools] 调用。
  final bool streamEnabled;

  /// 单次 LLM 请求超时时间。
  ///
  /// 未设置时：Ollama 默认 60 分钟，其他 provider 默认 30 分钟。
  final Duration? requestTimeout;

  const ProviderConfig({
    required this.provider,
    required this.model,
    this.apiKey,
    this.baseUrl,
    this.options = const LLMOptions(),
    this.organization,
    this.compressionConfig,
    this.retryConfig,
    bool? streamEnabled,
    this.requestTimeout,
  }) : streamEnabled =
           streamEnabled ?? (provider == LLMProvider.deepseek ? false : true);

  /// 从 Map 创建配置
  factory ProviderConfig.fromMap(Map<String, dynamic> map) {
    final providerStr = map['provider'] as String? ?? 'openai';
    final provider = LLMProvider.values.firstWhere(
      (e) => e.name == providerStr.toLowerCase(),
      orElse: () => LLMProvider.openai,
    );

    final optionsMap = map['options'] as Map<String, dynamic>? ?? {};
    final options = LLMOptions.fromMap(optionsMap);

    final compressionMap = map['compression'] as Map<String, dynamic>?;
    final compressionConfig = compressionMap != null
        ? ContextCompressionConfig.fromMap(compressionMap)
        : null;

    final retryMap = map['retry'] as Map<String, dynamic>?;
    final retryConfig = retryMap != null ? RetryConfig.fromMap(retryMap) : null;

    final timeoutMs = (map['requestTimeoutMs'] as num?)?.toInt();
    final timeoutSeconds = (map['timeoutSeconds'] as num?)?.toInt();
    final requestTimeout = timeoutMs != null
        ? Duration(milliseconds: timeoutMs)
        : timeoutSeconds != null
        ? Duration(seconds: timeoutSeconds)
        : null;

    // Ollama 专用默认值
    String? baseUrl = map['baseUrl'] as String?;
    String model = map['model'] as String? ?? 'gpt-4o';

    if (provider == LLMProvider.ollama) {
      // Ollama 默认 baseUrl
      if (baseUrl == null || baseUrl.isEmpty) {
        baseUrl = 'http://localhost:11434';
      }
      // Ollama 默认模型
      if (model == 'gpt-4o') {
        model = 'llama3';
      }
    }

    final streamEnabled = map.containsKey('streamEnabled')
        ? map['streamEnabled'] as bool?
        : map.containsKey('stream')
        ? map['stream'] as bool?
        : null;

    return ProviderConfig(
      provider: provider,
      model: model,
      apiKey: map['apiKey'] as String?,
      baseUrl: baseUrl,
      options: options,
      organization: map['organization'] as String?,
      compressionConfig: compressionConfig,
      retryConfig: retryConfig,
      streamEnabled: streamEnabled,
      requestTimeout: requestTimeout,
    );
  }

  /// 转换为 Map
  Map<String, dynamic> toMap() => {
    'provider': provider.name,
    'model': model,
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'options': options.toMap(),
    'organization': organization,
    if (compressionConfig != null) 'compression': compressionConfig!.toMap(),
    if (retryConfig != null) 'retry': retryConfig!.toMap(),
    'streamEnabled': streamEnabled,
    if (requestTimeout != null)
      'requestTimeoutMs': requestTimeout!.inMilliseconds,
  };

  /// 验证配置
  void validate() {
    if (model.isEmpty) {
      throw ArgumentError('model 不能为空');
    }

    switch (provider) {
      case LLMProvider.openai:
      case LLMProvider.anthropic:
      case LLMProvider.google:
      case LLMProvider.deepseek:
        if (apiKey == null || apiKey!.isEmpty) {
          throw ArgumentError('${provider.name} 需要 apiKey');
        }
        break;
      case LLMProvider.ollama:
        // Ollama 本地模型不需要 apiKey
        break;
    }
  }

  @override
  String toString() => 'ProviderConfig(provider: $provider, model: $model)';
}

/// LLM 模型参数
class LLMOptions {
  /// 温度 (0.0 - 2.0)
  final double temperature;

  /// 最大 token 数
  final int? maxTokens;

  /// Top-p 采样
  final double? topP;

  /// 推理努力程度 (minimal/low/medium/high/xhigh)
  final String? reasoningEffort;

  /// 停止序列
  final List<String>? stop;

  const LLMOptions({
    this.temperature = 0.7,
    this.maxTokens,
    this.topP,
    this.reasoningEffort,
    this.stop,
  });

  /// 从 Map 创建
  factory LLMOptions.fromMap(Map<String, dynamic> map) {
    return LLMOptions(
      temperature: (map['temperature'] as num?)?.toDouble() ?? 0.7,
      maxTokens: map['maxTokens'] as int?,
      topP: (map['topP'] as num?)?.toDouble(),
      reasoningEffort: map['reasoningEffort'] as String?,
      stop: (map['stop'] as List?)?.cast<String>(),
    );
  }

  /// 转换为 Map
  Map<String, dynamic> toMap() => {
    'temperature': temperature,
    if (maxTokens != null) 'maxTokens': maxTokens,
    if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
    if (topP != null) 'topP': topP,
    if (stop != null) 'stop': stop,
  };
}
