import 'package:langchain_anthropic/langchain_anthropic.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/tools.dart';
// import 'package:langchain_google/langchain_google.dart';  // 暂时禁用：存在 googleai_dart API 兼容性问题
import 'package:langchain_openai/langchain_openai.dart';

import 'provider_config.dart';

/// ChatModel 工厂类
///
/// 根据配置创建对应的 LLM ChatModel 实例
class ChatModelFactory {
  /// 创建 ChatModel
  static BaseChatModel create(ProviderConfig config) {
    config.validate();

    switch (config.provider) {
      case LLMProvider.openai:
        return _createOpenAI(config);

      case LLMProvider.anthropic:
        return _createAnthropic(config);

      case LLMProvider.google:
        return _createGoogle(config);

      case LLMProvider.ollama:
        return _createOllama(config);
    }
  }

  /// 根据提供商类型创建包含工具定义的 ChatModelOptions
  static ChatModelOptions? createToolOptions(
    LLMProvider provider,
    List<ToolSpec>? toolSpecs,
  ) {
    if (toolSpecs == null || toolSpecs.isEmpty) return null;
    switch (provider) {
      case LLMProvider.openai:
      case LLMProvider.ollama:
        return ChatOpenAIOptions(tools: toolSpecs);
      case LLMProvider.anthropic:
        return ChatAnthropicOptions(tools: toolSpecs);
      case LLMProvider.google:
        // 暂时禁用：存在 googleai_dart API 兼容性问题
        // return ChatGoogleGenerativeAIOptions(tools: toolSpecs);
        throw UnimplementedError('Google AI support is temporarily disabled');
    }
  }

  /// 创建 OpenAI ChatModel
  static ChatOpenAI _createOpenAI(ProviderConfig config) {
    return ChatOpenAI(
      apiKey: config.apiKey,
      baseUrl: config.baseUrl ?? 'https://api.openai.com/v1',
      defaultOptions: ChatOpenAIOptions(
        model: config.model,
        temperature: config.options.temperature,
        maxTokens: config.options.maxTokens,
        topP: config.options.topP,
        stop: config.options.stop,
      ),
    );
  }

  /// 创建 Anthropic ChatModel (Claude)
  static ChatAnthropic _createAnthropic(ProviderConfig config) {
    return ChatAnthropic(
      apiKey: config.apiKey!,
      defaultOptions: ChatAnthropicOptions(
        model: config.model,
        temperature: config.options.temperature,
        maxTokens: config.options.maxTokens,
        topP: config.options.topP,
        stopSequences: config.options.stop,
      ),
    );
  }

  /// 创建 Google AI ChatModel (Gemini)
  /// 暂时禁用：存在 googleai_dart API 兼容性问题
  static BaseChatModel _createGoogle(ProviderConfig config) {
    // 暂时使用 OpenAI 兼容 API 作为替代
    // TODO: 恢复 Google AI 支持当 langchain_google 修复后
    throw UnimplementedError(
      'Google AI support is temporarily disabled due to langchain_google compatibility issues. '
      'Use OpenAI or Anthropic provider instead.',
    );
    // return ChatGoogleGenerativeAI(
    //   apiKey: config.apiKey!,
    //   defaultOptions: ChatGoogleGenerativeAIOptions(
    //     model: config.model,
    //     temperature: config.options.temperature,
    //     maxOutputTokens: config.options.maxTokens,
    //     topP: config.options.topP,
    //     stopSequences: config.options.stop,
    //   ),
    // );
  }

  /// 创建 Ollama ChatModel (本地模型)
  static ChatOpenAI _createOllama(ProviderConfig config) {
    // Ollama 使用 OpenAI 兼容的 API
    final baseUrl = config.baseUrl ?? 'http://localhost:11434/v1';

    return ChatOpenAI(
      baseUrl: baseUrl,
      defaultOptions: ChatOpenAIOptions(
        model: config.model,
        temperature: config.options.temperature,
        maxTokens: config.options.maxTokens,
        topP: config.options.topP,
        stop: config.options.stop,
      ),
    );
  }
}
