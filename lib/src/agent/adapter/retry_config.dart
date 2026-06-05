/// 重试配置
///
/// 控制 LLM 调用重试的行为。通过 [ProviderConfig.retryConfig] 传入。
/// 当遇到频率限制（429）或服务端临时错误（5xx）时自动进行指数退避重试。
class RetryConfig {
  /// 最大重试次数
  ///
  /// 默认 5 次（即最多尝试 6 次：1 次原始调用 + 5 次重试）。
  final int maxRetries;

  /// 基础延迟（毫秒）
  ///
  /// 指数退避的初始延迟时间，默认 5000ms（5 秒）。
  final int baseDelayMs;

  /// 最大延迟（毫秒）
  ///
  /// 指数退避的上限，默认 20000ms（20 秒）。
  final int maxDelayMs;

  /// 是否添加随机抖动
  ///
  /// 为 true 时在延迟上添加随机抖动（0~当前退避值之间），
  /// 避免多个请求同时重试造成雪崩效应。默认 true。
  final bool jitter;

  /// 可重试的 HTTP 状态码
  ///
  /// 默认包含：408（请求超时）、429（频率限制）、500、502、503、504（服务端错误）。
  final List<int> retryableStatusCodes;

  const RetryConfig({
    this.maxRetries = 5,
    this.baseDelayMs = 5000,
    this.maxDelayMs = 20000,
    this.jitter = true,
    this.retryableStatusCodes = const [408, 429, 500, 502, 503, 504],
  });

  /// 计算第 [attempt] 次重试的延迟时间（毫秒）
  ///
  /// [attempt] 从 0 开始，表示第 1 次重试。
  /// 公式：delay = min(baseDelay * 2^attempt, maxDelay)
  /// 如果启用抖动，结果在 [0, delay] 之间随机。
  int nextDelay(int attempt) {
    if (attempt < 0) return 0;
    // 指数退避：baseDelay * 2^attempt
    double delay = (baseDelayMs * (1 << attempt)).toDouble();
    if (delay > maxDelayMs) {
      delay = maxDelayMs.toDouble();
    }
    if (jitter) {
      // 添加随机抖动：0 ~ delay 之间的随机值
      delay = _randomDouble() * delay;
    }
    return delay.round();
  }

  /// 从 Map 创建配置
  factory RetryConfig.fromMap(Map<String, dynamic> map) {
    return RetryConfig(
      maxRetries: (map['maxRetries'] as num?)?.toInt() ?? 5,
      baseDelayMs: (map['baseDelayMs'] as num?)?.toInt() ?? 5000,
      maxDelayMs: (map['maxDelayMs'] as num?)?.toInt() ?? 20000,
      jitter: (map['jitter'] as bool?) ?? true,
      retryableStatusCodes:
          (map['retryableStatusCodes'] as List<dynamic>?)
              ?.map((e) => e as int)
              .toList() ??
          const [408, 429, 500, 502, 503, 504],
    );
  }

  /// 转换为 Map
  Map<String, dynamic> toMap() => {
    'maxRetries': maxRetries,
    'baseDelayMs': baseDelayMs,
    'maxDelayMs': maxDelayMs,
    'jitter': jitter,
    'retryableStatusCodes': retryableStatusCodes,
  };

  /// 默认配置
  static const RetryConfig defaultConfig = RetryConfig();

  static double _randomDouble() {
    // 使用简单的伪随机，避免引入 dart:math 依赖
    return (DateTime.now().microsecondsSinceEpoch % 9973) / 9973.0;
  }

  @override
  String toString() =>
      'RetryConfig(maxRetries: $maxRetries, baseDelayMs: $baseDelayMs, '
      'maxDelayMs: $maxDelayMs, jitter: $jitter, '
      'retryableStatusCodes: $retryableStatusCodes)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RetryConfig &&
          maxRetries == other.maxRetries &&
          baseDelayMs == other.baseDelayMs &&
          maxDelayMs == other.maxDelayMs &&
          jitter == other.jitter;

  @override
  int get hashCode => Object.hash(maxRetries, baseDelayMs, maxDelayMs, jitter);
}
