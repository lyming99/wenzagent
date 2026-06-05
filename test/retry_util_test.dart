import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:wenzagent/src/agent/adapter/retry_util.dart';

void main() {
  final _reqOpts = RequestOptions();

  group('RetryUtil.isRetryableError', () {
    test('连接错误可重试', () {
      expect(
        RetryUtil.isRetryableError(
          DioException(
            requestOptions: _reqOpts,
            type: DioExceptionType.connectionError,
            message: 'Connection refused',
          ),
        ),
        isTrue,
      );
    });

    test('429 频率限制可重试', () {
      expect(
        RetryUtil.isRetryableError(
          DioException(
            requestOptions: _reqOpts,
            type: DioExceptionType.badResponse,
            message: 'Too Many Requests',
            response: Response(requestOptions: _reqOpts, statusCode: 429),
          ),
        ),
        isTrue,
      );
    });

    test('500 服务端错误可重试', () {
      expect(
        RetryUtil.isRetryableError(
          DioException(
            requestOptions: _reqOpts,
            type: DioExceptionType.badResponse,
            message: 'Internal Server Error',
            response: Response(requestOptions: _reqOpts, statusCode: 500),
          ),
        ),
        isTrue,
      );
    });

    test('取消异常不可重试', () {
      expect(
        RetryUtil.isRetryableError(
          DioException(
            requestOptions: _reqOpts,
            type: DioExceptionType.cancel,
            message: 'Cancelled',
          ),
        ),
        isFalse,
      );
    });

    test('StateError 不可重试', () {
      expect(RetryUtil.isRetryableError(StateError('bad state')), isFalse);
    });

    test('TypeError 不可重试', () {
      expect(RetryUtil.isRetryableError(TypeError()), isFalse);
    });

    // ===== Token 超限错误场景 =====

    group('token 超限错误不重试', () {
      test('OpenAI context_length 超限不重试', () {
        // 真实错误消息：
        // "Invalid request: This model's maximum context length is 1048576 tokens.
        //  However, you requested 1529666 tokens (1497666 in the messages,
        //  32000 in the completion). Please reduce the length of the messages or completion."
        expect(
          RetryUtil.isRetryableError(
            DioException(
              requestOptions: _reqOpts,
              type: DioExceptionType.badResponse,
              message:
                  "Invalid request: This model's maximum context length is "
                  "1048576 tokens. However, you requested 1529666 tokens "
                  "(1497666 in the messages, 32000 in the completion). "
                  "Please reduce the length of the messages or completion.",
              response: Response(requestOptions: _reqOpts, statusCode: 400),
            ),
          ),
          isFalse,
          reason: 'OpenAI context length 超限不应重试',
        );
      });

      test('OpenAI 简短 context_length 超限不重试', () {
        expect(
          RetryUtil.isRetryableError(
            DioException(
              requestOptions: _reqOpts,
              type: DioExceptionType.badResponse,
              message: "This model's maximum context length is 8192 tokens",
              response: Response(requestOptions: _reqOpts, statusCode: 400),
            ),
          ),
          isFalse,
          reason: '简短 context length 超限不应重试',
        );
      });

      test('context_length_exceeded 不重试', () {
        final error = DioException(
          requestOptions: _reqOpts,
          type: DioExceptionType.badResponse,
          message: 'context_length_exceeded: Token limit exceeded',
          response: Response(requestOptions: _reqOpts, statusCode: 400),
        );

        expect(
          RetryUtil.isRetryableError(error),
          isFalse,
          reason: 'context_length_exceeded 不应重试',
        );
        expect(
          RetryUtil.isContextOverflowError(error),
          isTrue,
          reason: '适配器应能单独识别 context overflow 以触发压缩补救',
        );
      });

      test('response body 中的 context overflow 可识别', () {
        final error = DioException(
          requestOptions: _reqOpts,
          type: DioExceptionType.badResponse,
          message: 'Bad request',
          response: Response(
            requestOptions: _reqOpts,
            statusCode: 400,
            data: {
              'error': {
                'code': 'context_length_exceeded',
                'message': 'Please reduce the length of the messages.',
              },
            },
          ),
        );

        expect(RetryUtil.isRetryableError(error), isFalse);
        expect(RetryUtil.isContextOverflowError(error), isTrue);
      });

      test('Anthropic prompt is too long 不重试', () {
        expect(
          RetryUtil.isRetryableError(
            DioException(
              requestOptions: _reqOpts,
              type: DioExceptionType.badResponse,
              message: 'prompt is too long: 200000 tokens > 190000 max',
              response: Response(requestOptions: _reqOpts, statusCode: 400),
            ),
          ),
          isFalse,
          reason: 'Anthropic prompt too long 不应重试',
        );
      });

      test('Google request too large 不重试', () {
        expect(
          RetryUtil.isRetryableError(
            DioException(
              requestOptions: _reqOpts,
              type: DioExceptionType.badResponse,
              message:
                  'Request too large: exceeds the maximum number of tokens per request',
              response: Response(requestOptions: _reqOpts, statusCode: 400),
            ),
          ),
          isFalse,
          reason: 'Google request too large 不应重试',
        );
      });

      test('非 token 超限的 400 错误不重试', () {
        // 400 本身不可重试（不在 429 或 5xx 范围内）
        expect(
          RetryUtil.isRetryableError(
            DioException(
              requestOptions: _reqOpts,
              type: DioExceptionType.badResponse,
              message: 'Bad request: invalid parameter',
              response: Response(requestOptions: _reqOpts, statusCode: 400),
            ),
          ),
          isFalse,
          reason: '普通 400 错误不应重试',
        );
      });

      test('普通字符串异常（非 token 超限）可重试', () {
        expect(
          RetryUtil.isRetryableError(Exception('unknown network issue')),
          isTrue,
          reason: '非 token 超限的未知异常应可重试',
        );
      });

      test('reduce the length 关键词不重试', () {
        expect(
          RetryUtil.isRetryableError(
            Exception(
              'Please reduce the length of the messages. Token limit exceeded.',
            ),
          ),
          isFalse,
          reason: '包含 reduce the length + token 关键词不应重试',
        );
      });

      test('不含上下文关键词的 requested 错误仍可重试', () {
        // "requested" 单独出现不应触发 token 超限判断
        expect(
          RetryUtil.isRetryableError(Exception('The server requested a retry')),
          isTrue,
          reason: '不含 token/context/length 关键词的 requested 错误应可重试',
        );
      });
    });
  });
}
