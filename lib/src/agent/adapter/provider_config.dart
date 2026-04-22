import 'context_compression_config.dart';

/// LLM 提供商类型
enum LLMProvider { openai, anthropic, google, ollama }

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

  const ProviderConfig({
    required this.provider,
    required this.model,
    this.apiKey,
    this.baseUrl,
    this.options = const LLMOptions(),
    this.organization,
    this.compressionConfig,
  });

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

    return ProviderConfig(
      provider: provider,
      model: model,
      apiKey: map['apiKey'] as String?,
      baseUrl: baseUrl,
      options: options,
      organization: map['organization'] as String?,
      compressionConfig: compressionConfig,
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

  /// 停止序列
  final List<String>? stop;

  const LLMOptions({
    this.temperature = 0.7,
    this.maxTokens,
    this.topP,
    this.stop,
  });

  /// 从 Map 创建
  factory LLMOptions.fromMap(Map<String, dynamic> map) {
    return LLMOptions(
      temperature: (map['temperature'] as num?)?.toDouble() ?? 0.7,
      maxTokens: map['maxTokens'] as int?,
      topP: (map['topP'] as num?)?.toDouble(),
      stop: (map['stop'] as List?)?.cast<String>(),
    );
  }

  /// 转换为 Map
  Map<String, dynamic> toMap() => {
    'temperature': temperature,
    if (maxTokens != null) 'maxTokens': maxTokens,
    if (topP != null) 'topP': topP,
    if (stop != null) 'stop': stop,
  };
}
