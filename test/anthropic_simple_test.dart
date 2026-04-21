import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:llm_dart/llm_dart.dart';
import 'package:test/test.dart';

void main() {
  // 从环境变量读取配置
  final apiUrl = Platform.environment['anthropic_api_url'];
  final apiKey = Platform.environment['anthropic_api_key'];
  final apiModel = Platform.environment['anthropic_api_model'];

  setUpAll(() {
    // 校验环境变量
    if (apiUrl == null || apiUrl.isEmpty) {
      throw TestFailure('环境变量 anthropic_api_url 未设置');
    }
    if (apiKey == null || apiKey.isEmpty) {
      throw TestFailure('环境变量 anthropic_api_key 未设置');
    }
    if (apiModel == null || apiModel.isEmpty) {
      throw TestFailure('环境变量 anthropic_api_model 未设置');
    }

    print('配置信息:');
    print('  API URL : $apiUrl');
    print('  API Key : ${apiKey.substring(0, 8)}...');
    print('  API Model: $apiModel');
  });

  /// 构建 Anthropic provider（每个 test 独立创建，避免状态污染）
  Future<ChatCapability> buildProvider() async {
    return ai()
        .anthropic()
        .apiKey(apiKey!)
        .model(apiModel!)
        .baseUrl(apiUrl!)
        .temperature(0.7)
        .maxTokens(1024)
        .build();
  }

  group('非流式问答', () {
    test('简单问答 - 你好', () async {
      final provider = await buildProvider();

      final messages = [ChatMessage.user('你好，请用一句话介绍你自己。')];
      final response = await provider.chat(messages);

      print('回复: ${response.text}');
      expect(response.text, isNotEmpty);
    });

    test('简单问答 - 数学计算', () async {
      final provider = await buildProvider();

      final messages = [ChatMessage.user('123 + 456 等于多少？只回答数字。')];
      final response = await provider.chat(messages);

      print('回复: ${response.text}');
      expect(response.text, contains('579'));
    });

    test('简单问答 - 多轮对话', () async {
      final provider = await buildProvider();

      final messages = [
        ChatMessage.user('我最喜欢的颜色是蓝色。请记住这个信息。'),
        ChatMessage.assistant('好的，我记住了，你最喜欢的颜色是蓝色。'),
        ChatMessage.user('我最喜欢的颜色是什么？'),
      ];
      final response = await provider.chat(messages);

      print('回复: ${response.text}');
      expect(response.text?.toLowerCase(), contains('蓝色'));
    });
  });

  group('流式问答', () {
    /// 手动发送 Anthropic SSE 流式请求并解析事件
    ///
    /// 注：Kimi API 返回 `data:` 而非标准 `data: `（冒号后无空格），
    /// 导致 llm_dart 的 Anthropic provider 流式解析失败。
    /// 这里使用手动 SSE 解析作为 workaround。
    Stream<ChatStreamEvent> chatStreamManual(
      String url,
      String key,
      String model,
      List<ChatMessage> messages,
    ) async* {
      final dio = Dio();
      dio.options.validateStatus = (s) => true;

      final normalizedUrl = url.endsWith('/') ? url : '$url/';

      final response = await dio.post(
        '${normalizedUrl}messages',
        data: {
          'model': model,
          'max_tokens': 1024,
          'stream': true,
          'temperature': 0.7,
          'messages': messages
              .where((m) => m.role != ChatRole.system)
              .map((m) => {
                    'role': m.role.name,
                    'content': [
                      {'type': 'text', 'text': m.content}
                    ],
                  })
              .toList(),
        },
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': key,
            'anthropic-version': '2023-06-01',
            'Accept': 'text/event-stream',
          },
        ),
      );

      if (response.statusCode != 200) {
        yield ErrorEvent(GenericError(
            'HTTP ${response.statusCode}: ${response.data}'));
        return;
      }

      final responseBody = response.data;
      Stream<List<int>> rawStream;
      if (responseBody is ResponseBody) {
        rawStream = responseBody.stream;
      } else {
        rawStream = responseBody as Stream<List<int>>;
      }

      final decoder = Utf8StreamDecoder();
      final buffer = StringBuffer();

      await for (final chunk in rawStream) {
        final decoded = decoder.decode(chunk);
        if (decoded.isNotEmpty) {
          buffer.write(decoded);
        }

        // 尝试解析已缓冲的完整行
        final content = buffer.toString();
        final lastNewline = content.lastIndexOf('\n');
        if (lastNewline == -1) continue;

        final completeLines = content.substring(0, lastNewline);
        buffer.clear();
        buffer.write(content.substring(lastNewline + 1));

        for (final line in completeLines.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          if (trimmed.startsWith('event:')) continue;

          // 兼容 "data:" 和 "data: " 两种格式
          String? dataContent;
          if (trimmed.startsWith('data: ')) {
            dataContent = trimmed.substring(6);
          } else if (trimmed.startsWith('data:')) {
            dataContent = trimmed.substring(5);
          }

          if (dataContent == null) continue;
          if (dataContent.isEmpty || dataContent == '[DONE]') continue;

          try {
            final json = jsonDecode(dataContent) as Map<String, dynamic>;
            final type = json['type'] as String?;

            if (type == 'content_block_delta') {
              final delta = json['delta'] as Map<String, dynamic>?;
              final text = delta?['text'] as String?;
              if (text != null) {
                yield TextDeltaEvent(text);
              }
            } else if (type == 'message_delta') {
              // 完成
            } else if (type == 'message_start') {
              final message =
                  json['message'] as Map<String, dynamic>?;
              if (message != null) {
                final usage = message['usage'] as Map<String, dynamic>?;
                if (usage != null) {
                  yield CompletionEvent(AnthropicChatResponse({
                    'content': [],
                    'usage': usage,
                  }));
                }
              }
            }
          } catch (_) {
            // 跳过解析失败的行
          }
        }
      }

      // flush decoder
      final remaining = decoder.flush();
      if (remaining.isNotEmpty) {
        buffer.write(remaining);
      }

      // 解析 buffer 中剩余的内容
      for (final line in buffer.toString().split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('event:')) continue;

        String? dataContent;
        if (trimmed.startsWith('data: ')) {
          dataContent = trimmed.substring(6);
        } else if (trimmed.startsWith('data:')) {
          dataContent = trimmed.substring(5);
        }
        if (dataContent == null ||
            dataContent.isEmpty ||
            dataContent == '[DONE]') continue;

        try {
          final json = jsonDecode(dataContent) as Map<String, dynamic>;
          final type = json['type'] as String?;
          if (type == 'content_block_delta') {
            final delta = json['delta'] as Map<String, dynamic>?;
            final text = delta?['text'] as String?;
            if (text != null) yield TextDeltaEvent(text);
          }
        } catch (_) {}
      }
    }

    test('流式问答 - 你好', () async {
      final stream = chatStreamManual(
        apiUrl!,
        apiKey!,
        apiModel!,
        [ChatMessage.user('你好，请用一句话介绍你自己。')],
      );

      final buffer = StringBuffer();
      int eventCount = 0;

      await for (final event in stream) {
        eventCount++;
        if (event is TextDeltaEvent) {
          buffer.write(event.delta);
        }
      }

      final fullText = buffer.toString();
      print('流式回复: $fullText');
      expect(fullText, isNotEmpty);
      expect(eventCount, greaterThan(0));
    });

    test('流式问答 - 数学计算', () async {
      final stream = chatStreamManual(
        apiUrl!,
        apiKey!,
        apiModel!,
        [ChatMessage.user('123 + 456 等于多少？只回答数字。')],
      );

      final chunks = <String>[];
      await for (final event in stream) {
        if (event is TextDeltaEvent) {
          chunks.add(event.delta);
        }
      }

      final fullText = chunks.join();
      print('流式回复: $fullText');
      expect(fullText, contains('579'));
      expect(chunks.length, greaterThan(0), reason: '流式应返回 chunk');
    });

    test('流式问答 - 多轮对话', () async {
      final stream = chatStreamManual(
        apiUrl!,
        apiKey!,
        apiModel!,
        [
          ChatMessage.user('我最喜欢的颜色是红色。请记住。'),
          ChatMessage.assistant('好的，我记住了，你最喜欢的颜色是红色。'),
          ChatMessage.user('我最喜欢的颜色是什么？'),
        ],
      );

      final buffer = StringBuffer();
      await for (final event in stream) {
        if (event is TextDeltaEvent) {
          buffer.write(event.delta);
        }
      }

      final fullText = buffer.toString();
      print('流式回复: $fullText');
      expect(fullText, contains('红色'));
    });
  });
}
