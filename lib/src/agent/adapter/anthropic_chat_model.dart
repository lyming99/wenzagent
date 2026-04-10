/// 支持工具错误传播的 Anthropic ChatModel
///
/// 继承 [BaseChatModel] 实现 Anthropic Messages API 的调用，
/// 核心功能是将 [ErrorToolChatMessage.isError] 传播到
/// Anthropic API 的 `tool_result.is_error` 字段。
///
/// 当 Claude 收到 `is_error: true` 的 tool_result 时，
/// 会正确识别工具调用失败并调整策略，避免死循环重试同一调用。
library;

import 'dart:convert';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as a;
import 'package:collection/collection.dart' show IterableExtension;
import 'package:http/http.dart' as http;
import 'package:langchain_anthropic/langchain_anthropic.dart';
import 'package:langchain_anthropic/src/chat_models/mappers.dart'
    show MessageStreamEventTransformer;
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/language_models.dart';
import 'package:langchain_core/prompts.dart';
import 'package:langchain_core/tools.dart';

import 'error_tool_chat_message.dart';

class AnthropicErrorAwareChatModel extends BaseChatModel<ChatAnthropicOptions> {
  final a.AnthropicClient _client;

  /// 默认模型
  static const defaultModel = 'claude-3-5-sonnet-20241022';

  /// 默认最大输出 token 数
  static const defaultMaxTokens = 1024;

  AnthropicErrorAwareChatModel({
    required String apiKey,
    String baseUrl = 'https://api.anthropic.com/v1',
    Map<String, String>? headers,
    Map<String, dynamic>? queryParams,
    http.Client? client,
    super.defaultOptions = const ChatAnthropicOptions(
      model: defaultModel,
      maxTokens: defaultMaxTokens,
    ),
  }) : _client = a.AnthropicClient(
         apiKey: apiKey,
         baseUrl: baseUrl,
         headers: headers,
         queryParams: queryParams,
         client: client,
       );

  @override
  String get modelType => 'anthropic-chat-error-aware';

  @override
  Future<ChatResult> invoke(
    final PromptValue input, {
    final ChatAnthropicOptions? options,
  }) async {
    final request = _buildRequest(
      input.toChatMessages(),
      options: options,
      stream: false,
    );
    final completion = await _client.createMessage(request: request);
    return _messageToChatResult(completion);
  }

  @override
  Stream<ChatResult> stream(
    final PromptValue input, {
    final ChatAnthropicOptions? options,
  }) {
    final request = _buildRequest(
      input.toChatMessages(),
      options: options,
      stream: true,
    );
    return _client
        .createMessageStream(request: request)
        .where(_isNotThinkingEvent)
        .transform(MessageStreamEventTransformer());
  }

  /// 过滤掉扩展思考（Extended Thinking）相关的事件
  ///
  /// Claude 的 thinking 内容不应发送给用户，否则会出现乱码。
  /// 需要过滤的事件类型：
  /// - ContentBlockStartEvent 中的 ThinkingBlock / RedactedThinkingBlock
  /// - ContentBlockDeltaEvent 中的 ThinkingBlockDelta / SignatureBlockDelta
  static bool _isNotThinkingEvent(final a.MessageStreamEvent event) {
    return switch (event) {
      final a.ContentBlockStartEvent e =>
        e.contentBlock is! a.ThinkingBlock &&
            e.contentBlock is! a.RedactedThinkingBlock,
      final a.ContentBlockDeltaEvent e =>
        e.delta is! a.ThinkingBlockDelta &&
            e.delta is! a.SignatureBlockDelta,
      _ => true,
    };
  }

  @override
  void close() {
    _client.endSession();
  }

  @override
  Future<List<int>> tokenize(
    final PromptValue promptValue, {
    final ChatAnthropicOptions? options,
  }) async {
    // Anthropic 不提供 tokenizer API，返回空列表
    return [];
  }

  // ===== 内部方法 =====

  /// 构建带错误支持的 Anthropic 请求
  a.CreateMessageRequest _buildRequest(
    final List<ChatMessage> messages, {
    required final ChatAnthropicOptions? options,
    required final bool stream,
  }) {
    final systemMsg = messages.firstOrNull is SystemChatMessage
        ? messages.firstOrNull?.contentAsString
        : null;

    final messagesDtos = _mapMessages(messages);
    final toolChoice = options?.toolChoice ?? defaultOptions.toolChoice;
    final toolChoiceDto = _mapToolChoice(toolChoice);
    final tools = options?.tools ?? defaultOptions.tools;
    final toolsDtos =
        tools?.map(_mapTool).toList(growable: false);
    final thinking = options?.thinking ?? defaultOptions.thinking;
    final thinkingDto = thinking?.toThinkingConfig();

    return a.CreateMessageRequest(
      model: a.Model.modelId(
        options?.model ?? defaultOptions.model ?? defaultModel,
      ),
      messages: messagesDtos,
      maxTokens:
          options?.maxTokens ??
          defaultOptions.maxTokens ??
          defaultMaxTokens,
      stopSequences: options?.stopSequences ?? defaultOptions.stopSequences,
      system: systemMsg != null
          ? a.CreateMessageRequestSystem.text(systemMsg)
          : null,
      temperature: options?.temperature ?? defaultOptions.temperature,
      topK: options?.topK ?? defaultOptions.topK,
      topP: options?.topP ?? defaultOptions.topP,
      metadata: a.CreateMessageRequestMetadata(
        userId: options?.userId ?? defaultOptions.userId,
      ),
      tools: toolsDtos,
      toolChoice: toolChoiceDto,
      thinking: thinkingDto,
      stream: stream,
    );
  }

  /// 将 ChatMessage 列表映射为 Anthropic API 消息（支持 isError 传播）
  List<a.Message> _mapMessages(final List<ChatMessage> messages) {
    final List<a.Message> result = [];
    final List<ToolChatMessage> consecutiveToolMessages = [];

    void flushToolMessages() {
      if (consecutiveToolMessages.isNotEmpty) {
        result.add(_mapToolMessages(consecutiveToolMessages));
        consecutiveToolMessages.clear();
      }
    }

    for (final message in messages) {
      switch (message) {
        case SystemChatMessage():
          flushToolMessages();
          continue;
        case final HumanChatMessage msg:
          flushToolMessages();
          result.add(_mapHumanMessage(msg));
        case final AIChatMessage msg:
          flushToolMessages();
          result.add(_mapAIMessage(msg));
        case final ToolChatMessage msg:
          consecutiveToolMessages.add(msg);
        case CustomChatMessage():
          throw UnsupportedError('Anthropic does not support custom messages');
      }
    }

    flushToolMessages();
    return result;
  }

  /// 映射工具结果消息（核心差异：支持 ErrorToolChatMessage 的 isError 传播）
  a.Message _mapToolMessages(final List<ToolChatMessage> msgs) {
    return a.Message(
      role: a.MessageRole.user,
      content: a.MessageContent.blocks(
        msgs
            .map(
              (msg) => a.Block.toolResult(
                toolUseId: msg.toolCallId,
                content: a.ToolResultBlockContent.text(msg.content),
                // 🔑 关键：将 ErrorToolChatMessage.isError 传播到 API 的 is_error 字段
                isError:
                    msg is ErrorToolChatMessage && msg.isError ? true : null,
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  a.Message _mapHumanMessage(final HumanChatMessage msg) {
    return a.Message(
      role: a.MessageRole.user,
      content: switch (msg.content) {
        final ChatMessageContentText t => a.MessageContent.text(t.text),
        final ChatMessageContentImage i => a.MessageContent.blocks([
            _mapImage(i),
          ]),
        final ChatMessageContentMultiModal mm => a.MessageContent.blocks(
            mm.parts
                .map(
                  (final part) => switch (part) {
                    final ChatMessageContentText t =>
                      a.Block.text(text: t.text),
                    final ChatMessageContentImage i => _mapImage(i),
                    ChatMessageContentMultiModal() => throw ArgumentError(
                      'Cannot have multimodal content in multimodal content',
                    ),
                  },
                )
                .toList(growable: false),
          ),
      },
    );
  }

  a.Block _mapImage(ChatMessageContentImage i) {
    return a.Block.image(
      source: a.ImageBlockSource.base64ImageSource(
        type: 'base64',
        mediaType: switch (i.mimeType) {
          'image/jpeg' => a.Base64ImageSourceMediaType.imageJpeg,
          'image/png' => a.Base64ImageSourceMediaType.imagePng,
          'image/gif' => a.Base64ImageSourceMediaType.imageGif,
          'image/webp' => a.Base64ImageSourceMediaType.imageWebp,
          _ => throw AssertionError(
            'Unsupported image MIME type: ${i.mimeType}',
          ),
        },
        data: i.data.startsWith('http')
            ? throw AssertionError(
                'Anthropic only supports base64-encoded images',
              )
            : i.data,
      ),
    );
  }

  a.Message _mapAIMessage(final AIChatMessage msg) {
    if (msg.toolCalls.isEmpty) {
      return a.Message(
        role: a.MessageRole.assistant,
        content: a.MessageContent.text(msg.content),
      );
    } else {
      return a.Message(
        role: a.MessageRole.assistant,
        content: a.MessageContent.blocks(
          msg.toolCalls
              .map(
                (final toolCall) => a.Block.toolUse(
                  id: toolCall.id,
                  name: toolCall.name,
                  input: toolCall.arguments,
                ),
              )
              .toList(growable: false),
        ),
      );
    }
  }

  a.ToolChoice? _mapToolChoice(final ChatToolChoice? toolChoice) {
    return switch (toolChoice) {
      null => null,
      ChatToolChoiceNone() => const a.ToolChoice(type: a.ToolChoiceType.auto),
      ChatToolChoiceAuto() => const a.ToolChoice(type: a.ToolChoiceType.auto),
      ChatToolChoiceRequired() =>
        const a.ToolChoice(type: a.ToolChoiceType.any),
      final ChatToolChoiceForced t => a.ToolChoice(
        type: a.ToolChoiceType.tool,
        name: t.name,
      ),
    };
  }

  a.Tool _mapTool(final ToolSpec tool) {
    return a.Tool.custom(
      name: tool.name,
      description: tool.description,
      inputSchema: tool.inputJsonSchema,
    );
  }

  /// 将 Anthropic Message 转换为 ChatResult
  ChatResult _messageToChatResult(final a.Message msg) {
    final (content, toolCalls) = _extractMessageContent(msg.content);
    return ChatResult(
      id: msg.id ?? '',
      output: AIChatMessage(content: content, toolCalls: toolCalls),
      finishReason: _mapFinishReason(msg.stopReason),
      metadata: {'model': msg.model, 'stop_sequence': msg.stopSequence},
      usage: _mapUsage(msg.usage),
    );
  }

  (String content, List<AIChatMessageToolCall> toolCalls) _extractMessageContent(
    final a.MessageContent content,
  ) =>
      switch (content) {
        final a.MessageContentText t =>
          (t.value, const <AIChatMessageToolCall>[]),
        final a.MessageContentBlocks b => (
          b.text,
          b.value
              .whereType<a.ToolUseBlock>()
              .map(
                (toolUse) => AIChatMessageToolCall(
                  id: toolUse.id,
                  name: toolUse.name,
                  argumentsRaw:
                      toolUse.input.isNotEmpty
                          ? json.encode(toolUse.input)
                          : '',
                  arguments: toolUse.input,
                ),
              )
              .toList(growable: false),
        ),
      };

  FinishReason _mapFinishReason(final a.StopReason? reason) => switch (reason) {
    a.StopReason.endTurn => FinishReason.stop,
    a.StopReason.maxTokens => FinishReason.length,
    a.StopReason.stopSequence => FinishReason.stop,
    a.StopReason.toolUse => FinishReason.toolCalls,
    a.StopReason.pauseTurn => FinishReason.unspecified,
    a.StopReason.refusal => FinishReason.contentFilter,
    null => FinishReason.unspecified,
  };

  LanguageModelUsage _mapUsage(final a.Usage? usage) {
    return LanguageModelUsage(
      promptTokens: usage?.inputTokens,
      responseTokens: usage?.outputTokens,
      totalTokens:
          usage?.inputTokens != null && usage?.outputTokens != null
              ? usage!.inputTokens + usage.outputTokens
              : null,
    );
  }
}
