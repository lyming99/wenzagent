import 'package:dio/dio.dart';

import '../../utils/logger.dart';
import 'retry_config.dart';

/// 聚合异常，包含多次重试中收集到的所有错误
class AggregateException implements Exception {
  /// 所有抛出的错误列表
  final List<Object> errors;

  /// 最终的操作（如获取最后一条错误消息）
  String get lastErrorMessage =>
      errors.isNotEmpty ? errors.last.toString() : '未知错误';

  /// 所有错误的完整描述
  String get allMessages =>
      errors.asMap().entries.map((e) => '  [${e.key}] ${e.value}').join('\n');

  const AggregateException(this.errors);

  @override
  String toString() {
    if (errors.isEmpty) return 'AggregateException: 无错误信息';
    if (errors.length == 1) return 'AggregateException: ${errors.first}';
    return 'AggregateException (${errors.length} errors):\n$allMessages';
  }
}

/// 重试工具函数
///
/// 提供泛型重试方法 [executeWithRetry]，以及错误判断工具 [isRetryableError]。
class RetryUtil {
  static final _log = Logger('RetryUtil');

  /// 使用指数退避策略执行异步函数，支持自动重试
  ///
  /// [fn] 要执行的异步函数
  /// [config] 重试配置，默认为 [RetryConfig.defaultConfig]
  /// [shouldRetry] 可选的自定义重试判断函数，返回 true 表示需要重试
  /// [onRetry] 每次重试前的回调，可用于日志记录
  ///
  /// 返回 [fn] 的成功结果。
  /// 如果所有重试都失败，抛出 [AggregateException]。
  static Future<T> executeWithRetry<T>(
    Future<T> Function() fn, {
    RetryConfig config = const RetryConfig(),
    bool Function(Object error)? shouldRetry,
    Future<void> Function(int attempt, Object error, Duration delay)?
    onRetry,
  }) async {
    final errors = <Object>[];

    for (var attempt = 0; attempt <= config.maxRetries; attempt++) {
      try {
        if (attempt > 0) {
          // 计算重试延迟
          final delayMs = config.nextDelay(attempt - 1);
          final delay = Duration(milliseconds: delayMs);
          _log.warn(
            'LLM 调用重试第 $attempt/$config.maxRetries 次，'
            '延迟 ${delayMs}ms，上一错误: ${errors.last}',
          );

          // 调用重试回调
          if (onRetry != null) {
            await onRetry(attempt, errors.last, delay);
          }

          await Future.delayed(delay);
        }

        return await fn();
      } catch (e) {
        // 记录错误
        errors.add(e);

        // 如果是最后一次尝试，不再判断可重试性
        if (attempt >= config.maxRetries) {
          break;
        }

        // 判断是否可重试
        final retryable = shouldRetry?.call(e) ?? isRetryableError(e);
        if (!retryable) {
          // 不可重试的错误，立即抛出聚合异常
          break;
        }
      }
    }

    throw AggregateException(errors);
  }

  /// 判断错误是否可重试
  ///
  /// 以下错误可重试：
  /// - [DioException] 类型为 connectionError, connectionTimeout, sendTimeout, receiveTimeout
  /// - [DioException] 类型为 badResponse 且状态码在可重试列表中（408, 429, 5xx）
  /// - [DioException] 类型为 unknown 且为临时性网络错误（连接重置、DNS 失败等）
  /// - 其他非 [StateError]、[TypeError]、[ArgumentError] 的异常
  ///
  /// 以下错误**不可重试**：
  /// - 上下文长度超限（context_length_exceeded / maximum context length）
  /// - 429 配额用尽（insufficient_quota / billing 相关）
  /// - 无效请求（400）中包含 token 超限信息
  static bool isRetryableError(Object error) {
    // 先检查错误消息中是否包含 token/上下文超限关键词
    // 这类错误重试无意义，只会浪费时间和 API 配额
    if (_isTokenLimitError(error)) {
      _log.warn('检测到 token 超限错误，不重试: $error');
      return false;
    }

    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return true;
        case DioExceptionType.badResponse:
          final statusCode = error.response?.statusCode;
          if (statusCode != null) {
            // 429 频率限制：但需排除配额用尽的情况
            if (statusCode == 429) {
              if (_isQuotaExhaustedError(error)) {
                _log.warn('检测到 API 配额用尽，不重试: $error');
                return false;
              }
              return true;
            }
            // 408 请求超时，5xx 服务端错误
            return statusCode == 408 ||
                (statusCode >= 500 && statusCode < 600);
          }
          return false;
        case DioExceptionType.cancel:
        case DioExceptionType.badCertificate:
          return false;
        case DioExceptionType.unknown:
          // 检查是否为临时性网络错误（连接重置、DNS 失败等），这些值得重试
          return _isTransientNetworkError(error);
      }
    }

    // StateError 和 TypeError 通常表示程序逻辑问题，不重试
    if (error is StateError || error is TypeError || error is ArgumentError) {
      return false;
    }

    // 其他未知异常，尝试重试
    return true;
  }

  /// 检查错误是否为 token/上下文长度超限错误
  ///
  /// 各提供商的错误消息模式：
  /// - OpenAI: "This model's maximum context length is XXXXX tokens"
  /// - Anthropic: "prompt is too long" / "max_tokens to be less than"
  /// - Google: "Request too large" / "exceeds the maximum number of tokens"
  /// - 通用: "context_length_exceeded" / "token limit" / "maximum context"
  static bool _isTokenLimitError(Object error) {
    final errorStr = error.toString().toLowerCase();

    // 常见的 token/上下文超限关键词
    const tokenLimitPatterns = [
      'maximum context length',
      'context_length_exceeded',
      'token limit',
      'maximum number of tokens',
      'requested', // "requested XXXXX tokens" 常出现在超限消息中
      'prompt is too long',
      'max_tokens to be less than',
      'request too large',
      'reduce the length', // "reduce the length of the messages"
    ];

    // 必须同时包含 "token" 或 "context" 或 "length" 等上下文相关词
    // 避免误匹配其他类型的 "requested" 错误
    const contextKeywords = [
      'token',
      'context',
      'length',
      'prompt',
      'max_tokens',
      'maxtokens',
    ];

    final hasContextKeyword =
        contextKeywords.any((kw) => errorStr.contains(kw));
    if (!hasContextKeyword) return false;

    return tokenLimitPatterns.any((p) => errorStr.contains(p));
  }

  /// 检查 429 错误是否为配额用尽（而非频率限制）
  ///
  /// OpenAI 429 响应体中可能包含：
  /// - "insufficient_quota" / "billing_hard_limit_reached"
  /// - "You exceeded your current quota"
  /// - "Please check your plan and billing details"
  ///
  /// 配额用尽不应重试（重试只会浪费延迟），而频率限制可以等待后重试。
  static bool _isQuotaExhaustedError(DioException error) {
    final responseBody = error.response?.data;
    final errorStr = responseBody?.toString().toLowerCase() ??
        error.message?.toLowerCase() ??
        '';

    const quotaPatterns = [
      'insufficient_quota',
      'billing_hard_limit_reached',
      'exceeded your current quota',
      'check your plan and billing',
      'billing limit',
      'account has been deactivated',
      'api key has been revoked',
    ];

    return quotaPatterns.any((p) => errorStr.contains(p));
  }

  /// 检查 DioExceptionType.unknown 是否为临时性网络错误
  ///
  /// unknown 类型的 DioException 可能包含各种底层错误，
  /// 其中一些是临时性的（如连接重置、DNS 解析失败），值得重试；
  /// 而另一些（如 SSL 证书错误、文件不存在）则不应重试。
  static bool _isTransientNetworkError(DioException error) {
    final errorMsg = error.error?.toString().toLowerCase() ?? '';
    final messageStr = error.message?.toLowerCase() ?? '';
    final combined = '$errorMsg $messageStr';

    // 临时性网络错误模式 → 可重试
    const transientPatterns = [
      'connection reset',
      'broken pipe',
      'connection refused',
      'network is unreachable',
      'no route to host',
      'software caused connection abort',
      'connection timed out',
      'timed out',
      'recv failure',
      'send failure',
      'connection aborted',
      'name resolution', // DNS 解析临时失败
      'temporary failure in name resolution',
      'host lookup failed',
      'errno =', // 系统级网络错误
      'socket exception',
      'handshake error', // TLS 握手临时失败
      'connection closed prematurely',
    ];

    final isTransient = transientPatterns.any((p) => combined.contains(p));

    if (isTransient) {
      _log.info('检测到临时性网络错误，将重试: $errorMsg');
      return true;
    }

    // 无法判断的 unknown 错误，保守不重试
    _log.warn('DioExceptionType.unknown，无法确认为临时错误，不重试: $errorMsg');
    return false;
  }
}
