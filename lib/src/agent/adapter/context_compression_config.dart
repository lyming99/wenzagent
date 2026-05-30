import 'token_estimator.dart';

/// 上下文压缩配置
///
/// 控制消息历史的压缩行为。通过 [ProviderConfig.compressionConfig] 传入。
/// 当 [maxContextTokens] > 0 时启用压缩。
class ContextCompressionConfig {
  /// 上下文总 token 硬限制
  ///
  /// 包含 system prompt + 历史消息 + 摘要的总 token 上限。
  /// 典型值: 8000, 16000, 32000, 128000。
  /// 设为 0 或负数表示禁用压缩。
  final int maxContextTokens;

  /// 预留给模型输出的 token 数
  ///
  /// 实际可用预算 = [maxContextTokens] - [reservedOutputTokens]。
  final int reservedOutputTokens;

  /// 最近保留完整的对话轮次数
  ///
  /// 最近 N 轮对话始终保持原文不压缩。
  /// 一个"轮次" = 一条 HumanChatMessage + 后续所有 AI/Tool 消息。
  final int recentTurnsKeep;

  /// 旧工具结果的截断字符数
  ///
  /// 超出此长度的旧工具结果内容会被截断。
  /// 仅影响最近轮次之外的 ToolChatMessage。
  final int toolResultMaxChars;

  /// LLM 摘要的最大 token 数
  ///
  /// 控制生成的对话摘要长度。
  final int summaryMaxTokens;

  /// 自定义 Token 估算器
  ///
  /// 为 null 时使用默认的 [CharBasedTokenEstimator]。
  final TokenEstimator? tokenEstimator;

  /// 压缩后冷却期消息数
  ///
  /// 压缩后至少经过 N 条新消息才允许再次压缩，防止频繁压缩。
  final int cooldownMessageCount;

  /// 压缩目标比率
  ///
  /// 压缩后 token 数约为 maxContextTokens * compressionTargetRatio。
  /// 默认 0.7（压缩到 70%），可配置为 0.5（严格减半）。
  final double compressionTargetRatio;

  const ContextCompressionConfig({
    required this.maxContextTokens,
    this.reservedOutputTokens = 4096,
    this.recentTurnsKeep = 3,
    this.toolResultMaxChars = 200,
    this.summaryMaxTokens = 500,
    this.tokenEstimator,
    this.cooldownMessageCount = 10,
    this.compressionTargetRatio = 0.7,
  });

  /// 是否启用压缩
  bool get enabled => maxContextTokens > 0;

  /// 实际可用的 token 预算
  int get effectiveBudget => maxContextTokens - reservedOutputTokens;

  /// 压缩目标 token 数
  ///
  /// 压缩后 token 数应接近此值：maxContextTokens * compressionTargetRatio
  int get targetThreshold => (maxContextTokens * compressionTargetRatio).round();

  /// 获取 token 估算器（未指定时使用自适应估算器）
  TokenEstimator get estimator => tokenEstimator ?? AdaptiveTokenEstimator();

  /// 从 Map 创建配置
  factory ContextCompressionConfig.fromMap(Map<String, dynamic> map) {
    return ContextCompressionConfig(
      maxContextTokens: map['maxContextTokens'] as int? ?? 0,
      reservedOutputTokens: map['reservedOutputTokens'] as int? ?? 4096,
      recentTurnsKeep: map['recentTurnsKeep'] as int? ?? 3,
      toolResultMaxChars: map['toolResultMaxChars'] as int? ?? 200,
      summaryMaxTokens: map['summaryMaxTokens'] as int? ?? 500,
      cooldownMessageCount: map['cooldownMessageCount'] as int? ?? 10,
      compressionTargetRatio: (map['compressionTargetRatio'] as num?)?.toDouble() ?? 0.7,
    );
  }

  /// 转换为 Map
  Map<String, dynamic> toMap() {
    return {
      'maxContextTokens': maxContextTokens,
      'reservedOutputTokens': reservedOutputTokens,
      'recentTurnsKeep': recentTurnsKeep,
      'toolResultMaxChars': toolResultMaxChars,
      'summaryMaxTokens': summaryMaxTokens,
      'cooldownMessageCount': cooldownMessageCount,
      'compressionTargetRatio': compressionTargetRatio,
    };
  }

  @override
  String toString() =>
      'ContextCompressionConfig('
      'maxContextTokens: $maxContextTokens, '
      'reservedOutputTokens: $reservedOutputTokens, '
      'recentTurnsKeep: $recentTurnsKeep, '
      'toolResultMaxChars: $toolResultMaxChars)';
}
