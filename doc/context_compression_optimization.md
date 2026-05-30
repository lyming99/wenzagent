# 上下文压缩系统优化方案

---

## 一、当前系统分析

### 1.1 核心架构

```
┌─────────────────────────────────────────────────────────────┐
│                    LlmChatAdapter                            │
│  prepareCompression() ──→ ContextCompressor                  │
│  buildCompressedMessages() ──→ ContextCompressor              │
└──────────────────────────┬──────────────────────────────────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
┌─────────────────┐ ┌──────────────┐ ┌──────────────────┐
│ ContextCompressor│ │SessionHistory│ │CompressionMetaStore│
│ ·shouldCompress │ │·pruneStartSeq│ │·getMeta()          │
│ ·prepareCompres │ │·messagesSince│ │·saveMeta()         │
│ ·buildCompresse │ │·lastCompTime │ │·incrementCoolDown()│
└─────────────────┘ └──────────────┘ └──────────────────┘
```

### 1.2 当前压缩策略

| 策略 | 实现 | 说明 |
|---|---|---|
| **触发条件** | token > maxContextTokens | 滞后双阈值防止震荡 |
| **保留策略** | 最近 1 轮完整保留 | 旧消息完全丢弃 |
| **压缩方式** | 本地裁剪，不调 LLM | 零 API 费用 |
| **防频繁** | 冷却期 + AsyncLock | 三重防护 |
| **历史查询** | query_conversation_history 工具 | AI 可查完整历史 |

---

## 二、潜在问题识别

### 2.1 配置参数未使用

**问题描述：**

`ContextCompressionConfig` 中定义了两个参数但实际代码中未使用：

```dart
// context_compression_config.dart
final int recentTurnsKeep;      // 默认值 3，但代码中硬编码为 1
final int toolResultMaxChars;   // 默认值 200，但代码中未使用
```

**影响：**
- 用户配置 `recentTurnsKeep: 5` 不会生效
- 旧工具结果无法按预期截断

**位置：**
- `context_compressor.dart` 第 120 行：`final recentTurn = turns.last;` 硬编码保留最后 1 轮
- `context_compressor.dart`：未实现 toolResultMaxChars 截断逻辑

---

### 2.2 Token 估算不精确

**问题描述：**

使用 `CharBasedTokenEstimator` 基于字符数估算，默认 `charsPerToken = 3.5`：

```dart
// token_estimator.dart
class CharBasedTokenEstimator extends TokenEstimator {
  final double charsPerToken;  // 默认 3.5
  
  @override
  int estimateTokens(String text) {
    return (text.length / charsPerToken).ceil();
  }
}
```

**问题：**
- 中文文本实际约 1.5-2 chars/token，但使用 3.5 会**低估**约 50%
- 代码/JSON 实际约 3-4 chars/token，估算相对准确
- 英文文本实际约 4 chars/token，使用 3.5 会**高估**约 15%

**影响：**
- 中文对话场景下，实际 token 可能超出预算 50%，导致 LLM 返回超限错误
- 英文对话场景下，过度压缩，浪费上下文空间

---

### 2.3 压缩策略过于激进

**问题描述：**

当前策略是**完全丢弃**旧消息，只保留最近 1 轮：

```dart
// context_compressor.dart
// 最近 1 个轮次始终保留完整
final recentTurn = turns.last;
```

**问题：**
- 丢弃所有旧消息，可能丢失重要上下文（如用户偏好、项目信息）
- AI 需要频繁调用 `query_conversation_history` 查询历史，增加工具调用开销
- 对话连贯性下降，用户体验差

**场景示例：**

```
用户: 我的项目使用 Flutter 3.0，Dart 3.0
AI: 好的，我会基于这个版本开发
... (10 轮对话后)
用户: 帮我创建一个新页面
AI: (已忘记 Flutter 版本，可能使用错误的语法)
```

---

### 2.4 轮次分组逻辑简单

**问题描述：**

轮次分组只按 `user` 消息分割：

```dart
// context_compressor.dart
static List<MessageTurn> groupIntoTurns(List<ChatMessage> messages) {
  for (var i = 0; i < messages.length; i++) {
    final msg = messages[i];
    if (msg.role == MessageRole.user && currentMessages.isNotEmpty) {
      // 新轮次开始
    }
  }
}
```

**问题：**
- 工具调用链可能跨越多个 user 消息
- 复杂任务（如多步骤文件操作）可能被错误分割

**场景示例：**

```
用户: 读取文件 A
AI: [调用 file_read] → 返回内容
用户: 修改文件 A 的第 10 行
AI: [调用 file_write] → 修改成功
用户: 验证修改结果
AI: [调用 file_read] → 返回修改后内容
```

如果在"修改文件 A"和"验证修改结果"之间压缩，工具调用链会被打断。

---

### 2.5 缺少消息重要性评估

**问题描述：**

当前压缩对所有旧消息一视同仁，没有区分重要性：

- 系统提示（system prompt）：高重要性
- 用户指令：高重要性
- AI 回复：中重要性
- 工具结果：低重要性（可能包含大量日志）

**影响：**
- 可能丢弃包含关键信息的用户指令
- 保留大量冗长的工具结果日志

---

### 2.6 缺少摘要功能

**问题描述：**

当前压缩是**硬删除**，旧消息完全丢弃：

```dart
// context_compressor.dart
for (final msg in allMessages) {
  if (pruneSeq > 0 && msg.seq > 0 && msg.seq < pruneSeq) {
    continue; // 跳过被省略的消息
  }
  result.add(msg);
}
```

**问题：**
- 没有生成摘要来保留关键信息
- AI 只知道"有 N 条消息被省略"，不知道省略了什么
- 需要频繁调用工具查询历史，增加延迟

---

## 三、优化方案

### 3.1 修复配置参数未使用问题

**优先级：高** | **工作量：小**

#### 3.1.1 实现 recentTurnsKeep

```dart
// context_compressor.dart
void _doCompression({...}) {
  // ...
  
  // 修改：使用配置的 recentTurnsKeep
  final recentTurnsCount = config.recentTurnsKeep.clamp(1, turns.length);
  final recentTurns = turns.sublist(turns.length - recentTurnsCount);
  final recentTokens = recentTurns.fold<int>(
    0, (sum, turn) => sum + _estimator.estimateMessagesTotal(turn.messages),
  );
  
  // 旧轮次（可压缩区域）
  final oldTurns = turns.sublist(0, turns.length - recentTurnsCount);
  // ...
}
```

#### 3.1.2 实现 toolResultMaxChars

```dart
// context_compressor.dart
List<ChatMessage> buildCompressedMessages({...}) {
  // ...
  
  // 对旧消息中的工具结果进行截断
  for (final msg in allMessages) {
    if (pruneSeq > 0 && msg.seq > 0 && msg.seq < pruneSeq) {
      continue;
    }
    
    // 新增：截断旧工具结果
    if (msg.role == MessageRole.tool && 
        msg.seq < pruneSeq + recentTurnsKeepThreshold) {
      result.add(_truncateToolResult(msg, config.toolResultMaxChars));
    } else {
      result.add(msg);
    }
  }
}

ChatMessage _truncateToolResult(ChatMessage msg, int maxChars) {
  if (msg.content != null && msg.content!.length > maxChars) {
    return msg.copyWith(
      content: '${msg.content!.substring(0, maxChars)}...(已截断)',
    );
  }
  return msg;
}
```

---

### 3.2 改进 Token 估算

**优先级：高** | **工作量：中**

#### 3.2.1 多语言自适应估算器

```dart
// token_estimator.dart
class AdaptiveTokenEstimator extends TokenEstimator {
  /// 中文字符占比阈值
  static const double _chineseThreshold = 0.3;
  
  /// 代码特征检测
  static final _codePatterns = RegExp(
    r'[\{\}\[\]();]|=>|->|\bfunction\b|\bclass\b|\bdef\b',
  );

  @override
  int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    
    // 检测语言特征
    final chineseRatio = _calculateChineseRatio(text);
    final isCode = _codePatterns.hasMatch(text);
    
    // 根据特征选择 charsPerToken
    double charsPerToken;
    if (chineseRatio > _chineseThreshold) {
      // 中文为主：1.5-2 chars/token
      charsPerToken = 1.8;
    } else if (isCode) {
      // 代码：3-4 chars/token
      charsPerToken = 3.5;
    } else {
      // 英文为主：4 chars/token
      charsPerToken = 4.0;
    }
    
    return (text.length / charsPerToken).ceil();
  }
  
  double _calculateChineseRatio(String text) {
    if (text.isEmpty) return 0;
    int chineseCount = 0;
    for (final char in text.runes) {
      if (char >= 0x4E00 && char <= 0x9FFF) {
        chineseCount++;
      }
    }
    return chineseCount / text.length;
  }
}
```

#### 3.2.2 实际 Token 反馈机制

```dart
// token_estimator.dart
class FeedbackTokenEstimator extends TokenEstimator {
  final AdaptiveTokenEstimator _baseEstimator = AdaptiveTokenEstimator();
  
  /// 历史估算误差记录
  final List<double> _errorRatios = [];
  
  /// 使用 LLM 响应中的 usage 信息校准
  void calibrate(int estimatedTokens, int actualTokens) {
    if (actualTokens > 0) {
      final ratio = estimatedTokens / actualTokens;
      _errorRatios.add(ratio);
      // 保留最近 100 条记录
      if (_errorRatios.length > 100) {
        _errorRatios.removeAt(0);
      }
    }
  }
  
  @override
  int estimateTokens(String text) {
    final baseEstimate = _baseEstimator.estimateTokens(text);
    
    // 应用校准系数
    if (_errorRatios.length >= 10) {
      final avgRatio = _errorRatios.reduce((a, b) => a + b) / _errorRatios.length;
      return (baseEstimate / avgRatio).ceil();
    }
    
    return baseEstimate;
  }
}
```

---

### 3.3 分层压缩策略

**优先级：高** | **工作量：大**

#### 3.3.1 消息重要性分类

```dart
// message_importance.dart
enum MessageImportance {
  critical,   // 系统提示、用户核心指令
  high,       // 用户消息、AI 关键回复
  medium,     // AI 普通回复
  low,        // 工具结果、调试日志
}

class MessageImportanceClassifier {
  /// 分类消息重要性
  static MessageImportance classify(ChatMessage message) {
    switch (message.role) {
      case MessageRole.system:
        return MessageImportance.critical;
        
      case MessageRole.user:
        // 检测是否包含关键指令
        if (_containsKeyInstruction(message.content)) {
          return MessageImportance.critical;
        }
        return MessageImportance.high;
        
      case MessageRole.assistant:
        // 检测是否包含工具调用
        if (message.toolCalls != null && message.toolCalls!.isNotEmpty) {
          return MessageImportance.medium;
        }
        return MessageImportance.high;
        
      case MessageRole.tool:
        // 工具结果默认低重要性
        return MessageImportance.low;
        
      default:
        return MessageImportance.medium;
    }
  }
  
  static bool _containsKeyInstruction(String? content) {
    if (content == null) return false;
    // 检测关键指令模式
    final patterns = [
      RegExp(r'(请|帮我|务必|一定要|记住|不要忘记)'),
      RegExp(r'(配置|设置|版本|环境|项目)'),
      RegExp(r'(bug|错误|问题|修复)'),
    ];
    return patterns.any((p) => p.hasMatch(content));
  }
}
```

#### 3.3.2 分层压缩实现

```dart
// context_compressor.dart
void _doLayeredCompression({...}) {
  // ...
  
  // 按重要性分组
  final criticalMessages = <ChatMessage>[];
  final highMessages = <ChatMessage>[];
  final mediumMessages = <ChatMessage>[];
  final lowMessages = <ChatMessage>[];
  
  for (final msg in oldMessages) {
    final importance = MessageImportanceClassifier.classify(msg);
    switch (importance) {
      case MessageImportance.critical:
        criticalMessages.add(msg);
        break;
      case MessageImportance.high:
        highMessages.add(msg);
        break;
      case MessageImportance.medium:
        mediumMessages.add(msg);
        break;
      case MessageImportance.low:
        lowMessages.add(msg);
        break;
    }
  }
  
  // 压缩策略：
  // 1. critical 消息：始终保留
  // 2. high 消息：保留最近 N 条
  // 3. medium 消息：保留摘要
  // 4. low 消息：优先丢弃
  
  var remainingBudget = targetTokens;
  
  // 1. 保留所有 critical 消息
  for (final msg in criticalMessages) {
    retainedMessages.add(msg);
    remainingBudget -= _estimator.estimateMessageTokens(msg);
  }
  
  // 2. 保留最近的 high 消息
  final recentHigh = highMessages.take(_config.recentHighMessagesCount);
  for (final msg in recentHigh) {
    retainedMessages.add(msg);
    remainingBudget -= _estimator.estimateMessageTokens(msg);
  }
  
  // 3. 为 medium 消息生成摘要
  if (remainingBudget > 100) {
    final summary = _generateSummary(mediumMessages, remainingBudget);
    retainedMessages.add(ChatMessage.system(
      content: '早期对话摘要: $summary',
    ));
  }
  
  // 4. low 消息全部丢弃
}
```

---

### 3.4 LLM 摘要生成

**优先级：中** | **工作量：大**

#### 3.4.1 异步摘要生成器

```dart
// llm_summarizer.dart
class LlmSummarizer {
  final llm.ChatCapability _chatCapability;
  final int _maxSummaryTokens;
  
  LlmSummarizer({
    required llm.ChatCapability chatCapability,
    int maxSummaryTokens = 500,
  }) : _chatCapability = chatCapability,
       _maxSummaryTokens = maxSummaryTokens;
  
  /// 生成对话摘要
  Future<String> generateSummary(List<ChatMessage> messages) async {
    if (messages.isEmpty) return '';
    
    // 构建摘要请求
    final summaryPrompt = _buildSummaryPrompt(messages);
    
    final response = await _chatCapability.chat([
      llm.ChatMessage.user(summaryPrompt),
    ]);
    
    return response.text ?? '';
  }
  
  String _buildSummaryPrompt(List<ChatMessage> messages) {
    final buffer = StringBuffer();
    buffer.writeln('请将以下对话总结为简洁的摘要，保留关键信息：');
    buffer.writeln('---');
    
    for (final msg in messages) {
      final role = msg.role == MessageRole.user ? '用户' : 'AI';
      buffer.writeln('$role: ${msg.content}');
    }
    
    buffer.writeln('---');
    buffer.writeln('摘要要求：');
    buffer.writeln('1. 保留用户的核心需求和偏好');
    buffer.writeln('2. 保留重要的技术决策和配置');
    buffer.writeln('3. 保留未完成的任务');
    buffer.writeln('4. 长度不超过 $_maxSummaryTokens 字');
    
    return buffer.toString();
  }
}
```

#### 3.4.2 摘要缓存机制

```dart
// summary_cache.dart
class SummaryCache {
  /// 摘要缓存：key = 员工ID，value = 摘要文本
  final Map<String, String> _cache = {};
  
  /// 摘要覆盖的消息范围
  final Map<String, int> _summarizedUpToSeq = {};
  
  /// 获取缓存的摘要
  String? getSummary(String employeeId) => _cache[employeeId];
  
  /// 更新摘要
  void updateSummary(String employeeId, String summary, int upToSeq) {
    _cache[employeeId] = summary;
    _summarizedUpToSeq[employeeId] = upToSeq;
  }
  
  /// 检查是否需要更新摘要
  bool needsUpdate(String employeeId, int currentSeq) {
    final lastSeq = _summarizedUpToSeq[employeeId] ?? 0;
    // 如果新消息超过 10 条，需要更新摘要
    return currentSeq - lastSeq > 10;
  }
}
```

---

### 3.5 智能轮次分组

**优先级：中** | **工作量：中**

#### 3.5.1 工具调用链感知

```dart
// context_compressor.dart
static List<MessageTurn> groupIntoTurns(List<ChatMessage> messages) {
  if (messages.isEmpty) return [];
  
  final turns = <MessageTurn>[];
  var currentStart = 0;
  var currentMessages = <ChatMessage>[];
  var inToolChain = false;
  
  for (var i = 0; i < messages.length; i++) {
    final msg = messages[i];
    
    // 检测工具调用链开始
    if (msg.role == MessageRole.assistant && 
        msg.toolCalls != null && 
        msg.toolCalls!.isNotEmpty) {
      inToolChain = true;
    }
    
    // 在工具调用链中，不分割轮次
    if (inToolChain) {
      currentMessages.add(msg);
      
      // 工具调用链结束：收到最终 AI 回复（无工具调用）
      if (msg.role == MessageRole.assistant && 
          (msg.toolCalls == null || msg.toolCalls!.isEmpty)) {
        inToolChain = false;
      }
      continue;
    }
    
    // 正常轮次分割
    if (msg.role == MessageRole.user && currentMessages.isNotEmpty) {
      turns.add(MessageTurn(
        startIndex: currentStart,
        endIndex: i - 1,
        messages: List.unmodifiable(currentMessages),
      ));
      currentStart = i;
      currentMessages = [];
    }
    
    currentMessages.add(msg);
  }
  
  // 添加最后一个轮次
  if (currentMessages.isNotEmpty) {
    turns.add(MessageTurn(
      startIndex: currentStart,
      endIndex: messages.length - 1,
      messages: List.unmodifiable(currentMessages),
    ));
  }
  
  return turns;
}
```

---

### 3.6 增量压缩优化

**优先级：中** | **工作量：中**

#### 3.6.1 压缩边界平滑

```dart
// context_compressor.dart
int _calculateSmoothCutIndex(List<MessageTurn> oldTurns, int targetTokens) {
  var cumulativeTokens = 0;
  var cutIndex = 0;
  
  // 从尾部往前扫描，找到压缩边界
  for (var i = oldTurns.length - 1; i >= 0; i--) {
    final turnTokens = _estimator.estimateMessagesTotal(oldTurns[i].messages);
    
    if (cumulativeTokens + turnTokens > targetTokens) {
      // 尝试找到一个更好的切割点
      // 优先在用户消息边界切割，而不是在工具调用链中间
      cutIndex = _findBetterCutPoint(oldTurns, i, targetTokens);
      break;
    }
    
    cumulativeTokens += turnTokens;
    
    if (i == 0) {
      cutIndex = 0;
    }
  }
  
  return cutIndex;
}

int _findBetterCutPoint(List<MessageTurn> turns, int suggestedIndex, int budget) {
  // 向后搜索：找到最近的用户消息开始的轮次
  for (var i = suggestedIndex; i < turns.length; i++) {
    if (turns[i].messages.first.role == MessageRole.user) {
      return i;
    }
  }
  
  // 向前搜索
  for (var i = suggestedIndex; i >= 0; i--) {
    if (turns[i].messages.first.role == MessageRole.user) {
      return i;
    }
  }
  
  return suggestedIndex;
}
```

---

## 四、优化优先级排序

| 优先级 | 优化项 | 工作量 | 预期收益 |
|---|---|---|---|
| **P0** | 修复 recentTurnsKeep 配置未生效 | 小 | 用户可配置保留轮次数 |
| **P0** | 修复 toolResultMaxChars 配置未生效 | 小 | 可截断冗长工具结果 |
| **P1** | 改进 Token 估算（多语言自适应） | 中 | 减少中文场景超限错误 |
| **P1** | 实现分层压缩策略 | 大 | 保留重要上下文 |
| **P2** | 实现 LLM 摘要生成 | 大 | 保留关键信息摘要 |
| **P2** | 改进轮次分组逻辑 | 中 | 保持工具调用链完整 |
| **P3** | 实现增量压缩优化 | 中 | 平滑压缩边界 |

---

## 五、实施建议

### 5.1 第一阶段：修复配置问题（1-2 天）

1. 修复 `recentTurnsKeep` 配置未生效问题
2. 修复 `toolResultMaxChars` 配置未生效问题
3. 添加相关单元测试

### 5.2 第二阶段：改进 Token 估算（2-3 天）

1. 实现 `AdaptiveTokenEstimator` 多语言自适应估算器
2. 添加语言特征检测逻辑
3. 集成到 `ContextCompressor`
4. 添加测试用例

### 5.3 第三阶段：分层压缩策略（5-7 天）

1. 实现 `MessageImportanceClassifier` 消息重要性分类器
2. 实现分层压缩逻辑
3. 配置化压缩策略参数
4. 集成测试

### 5.4 第四阶段：LLM 摘要生成（5-7 天）

1. 实现 `LlmSummarizer` 摘要生成器
2. 实现 `SummaryCache` 摘要缓存
3. 异步摘要生成（不阻塞主流程）
4. 摘要持久化到 DB

### 5.5 第五阶段：高级优化（3-5 天）

1. 改进轮次分组逻辑
2. 实现增量压缩优化
3. 性能测试和调优

---

## 六、配置参数扩展

```dart
class ContextCompressionConfig {
  // 现有参数...
  
  // 新增参数
  
  /// 压缩策略模式
  final CompressionStrategy strategy;
  
  /// 保留的高重要性消息数量
  final int recentHighMessagesCount;
  
  /// 是否启用 LLM 摘要
  final bool enableLlmSummary;
  
  /// 摘要最大 token 数
  final int summaryMaxTokens;
  
  /// 是否保留用户指令（始终不压缩）
  final bool preserveUserInstructions;
}

enum CompressionStrategy {
  /// 简单裁剪（当前实现）
  simple,
  
  /// 分层压缩
  layered,
  
  /// LLM 摘要
  llmSummary,
  
  /// 混合模式（分层 + 摘要）
  hybrid,
}
```

---

## 七、测试策略

### 7.1 单元测试

- Token 估算器精度测试（中/英/代码）
- 消息重要性分类器测试
- 轮次分组边界测试
- 配置参数生效测试

### 7.2 集成测试

- 端到端压缩流程测试
- 压缩后 LLM 调用测试
- 历史查询工具测试
- 持久化恢复测试

### 7.3 性能测试

- 大量消息（1000+）压缩性能
- Token 估算精度对比
- 内存占用测试

---

## 八、风险评估

| 风险 | 影响 | 缓解措施 |
|---|---|---|
| LLM 摘要生成增加延迟 | 用户体验下降 | 异步生成，不阻塞主流程 |
| 分层压缩增加复杂度 | 维护成本上升 | 充分测试，渐进式引入 |
| Token 估算不准确 | 压缩效果不理想 | 反馈机制持续校准 |
| 配置参数过多 | 用户困惑 | 提供合理默认值，文档说明 |

---

## 九、总结

当前上下文压缩系统架构合理，但存在以下主要问题：

1. **配置参数未完全使用**：`recentTurnsKeep` 和 `toolResultMaxChars` 未生效
2. **Token 估算不精确**：中文场景会低估约 50%
3. **压缩策略过于激进**：完全丢弃旧消息，丢失重要上下文
4. **缺少摘要功能**：旧消息完全丢弃，没有保留关键信息

建议按优先级分阶段实施优化：

1. **P0**：修复配置问题（小工作量，立即见效）
2. **P1**：改进 Token 估算（中等工作量，减少超限错误）
3. **P1**：分层压缩策略（大工作量，显著提升质量）
4. **P2**：LLM 摘要生成（大工作量，保留关键信息）

通过这些优化，可以显著提升上下文压缩的质量和用户体验，同时保持系统的可维护性和性能。
