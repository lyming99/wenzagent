/// LLM 聊天适配器模块
///
/// 提供基于 llm_dart 的 IChatAdapter 实现，
/// 支持多种 LLM 提供商（OpenAI、Anthropic、Google AI、Ollama 等）。
///
/// Ollama 额外支持模型发现和健康检查，参见 [OllamaClient]。
library;

export 'llm_chat_adapter.dart';
export 'sub_agent_llm_chat_adapter.dart';
export 'session_memory_manager.dart';
export 'provider_config.dart';
export 'token_estimator.dart';
export 'context_compression_config.dart';
export 'context_compressor.dart';
export 'ai_connection_tester.dart';
export 'ollama_client.dart';
