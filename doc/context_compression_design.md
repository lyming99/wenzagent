# 上下文压缩系统 — 设计文档与关键代码

---

## 一、设计概述

### 1.1 核心思路

对话太长时，把**早期消息完全丢弃**，只在提示词里告诉 AI"有多少条历史消息被省略了"。**新消息原文全发，不做任何裁剪。** AI 需要查看被丢弃的历史时，通过 `query_conversation_history` 内置工具查询 DB 中的完整原始消息。

```
DB 原始消息（永不删除）:
  msg_1  msg_2  msg_3  msg_4  msg_5  msg_6  msg_7  msg_8
  ✅     ✅     ✅     ✅     ✅     ✅     ✅     ✅

发给 LLM 的消息:
  [system: "当前会话共有 8 条历史消息，前 5 条已被省略。如需查看历史内容，可使用 query_conversation_history 工具。"]
  msg_4  msg_5  msg_6  msg_7  msg_8    ← 原文全发
  ✅     ✅     ✅     ✅     ✅
```

### 1.2 设计原则

| 原则 | 说明 |
|---|---|
| **不调 LLM** | 压缩完全本地完成，零 API 费用、无延迟 |
| **原始消息永不删除** | DB 中的消息完整保留，压缩只影响发给 LLM 的消息视图 |
| **AI 可查完整历史** | 通过 `query_conversation_history` 内置工具查询 DB 原始消息 |
| **DB 只存压缩位置** | 只记录 `prune_start_seq` + 冷却状态 |

### 1.3 三重防频繁压缩

```
                    ▲ token
  maxContextTokens ─┼─── 触发线（如 32000）
                    │
  targetThreshold  ─┼─── 目标线（32000 × 0.7 = 22400）
                    │
                    │   ← 间距 9600 token，防止震荡
                    │
                0 ──┴───────────────────────► 时间
```

| 防护机制 | 说明 |
|---|---|
| **滞后双阈值** | 触发线 maxContextTokens，目标线 × 0.7，间距防止反复压缩 |
| **冷却期** | 压缩后至少 10 条新消息才允许再次压缩 |
| **AsyncLock** | 上次压缩未完成则跳过，不堆积并发请求 |

---

## 二、文件清单

### 2.1 新建文件（4 个）

| 文件 | 说明 |
|---|---|
| `lib/src/persistence/entities/compression_meta_entity.dart` | 压缩元数据 Entity |
| `lib/src/persistence/migrations/v22_migration.dart` | 建表 migration |
| `lib/src/service/compression_meta_store.dart` | 压缩元数据 Store |
| `lib/src/agent/tool/builtin/query_conversation_history_tool.dart` | 历史查询内置工具 |

### 2.2 修改文件（5 个）

| 文件 | 变更 |
|---|---|
| `context_compressor.dart` | 压缩核心逻辑重写 |
| `context_compression_config.dart` | 新增冷却和目标比率参数 |
| `session_memory_manager.dart` | 新增压缩状态字段 + 启动恢复 |
| `llm_chat_adapter.dart` | 注入 CompressionMetaStore |
| `builtin_tools.dart` | 注册新工具 |

---

## 三、数据库设计

### 3.1 表结构：`context_compression_meta`

```sql
CREATE TABLE IF NOT EXISTS context_compression_meta (
  employee_id   TEXT NOT NULL,
  device_id     TEXT NOT NULL,
  prune_start_seq  INTEGER NOT NULL DEFAULT 0,  -- 压缩边界 seq
  last_compression_time INTEGER NOT NULL DEFAULT 0,  -- 上次压缩时间 (ms)
  messages_since_compression INTEGER NOT NULL DEFAULT 0,  -- 冷却计数
  update_time  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (employee_id, device_id)
);
```

### 3.2 Entity

```dart
class CompressionMetaEntity {
  final String employeeId;
  final String deviceId;
  int pruneStartSeq;            // 压缩边界
  int lastCompressionTime;      // 上次压缩时间
  int messagesSinceCompression; // 冷却计数
  int updateTime;

  bool get isCompressed => pruneStartSeq > 0;

  Map<String, dynamic> toMap() => {
    'employee_id': employeeId,
    'device_id': deviceId,
    'prune_start_seq': pruneStartSeq,
    'last_compression_time': lastCompressionTime,
    'messages_since_compression': messagesSinceCompression,
    'update_time': updateTime,
  };

  factory CompressionMetaEntity.fromMap(Map<String, dynamic> map) {
    return CompressionMetaEntity(
      employeeId: (map['employee_id'] ?? '') as String,
      deviceId: (map['device_id'] ?? '') as String,
      pruneStartSeq: (map['prune_start_seq'] ?? 0) as int,
      lastCompressionTime: (map['last_compression_time'] ?? 0) as int,
      messagesSinceCompression: (map['messages_since_compression'] ?? 0) as int,
      updateTime: (map['update_time'] ?? 0) as int,
    );
  }
}
```

### 3.3 Store

```dart
class CompressionMetaStore {
  final DatabaseManager _dbManager;

  /// 读取压缩元数据
  CompressionMetaEntity? getMeta(String employeeId, String deviceId) {
    final result = _db.select(
      'SELECT * FROM context_compression_meta WHERE employee_id = ? AND device_id = ?',
      [employeeId, deviceId],
    );
    if (result.isEmpty) return null;
    return CompressionMetaEntity.fromMap(result.first);
  }

  /// 保存压缩元数据（UPSERT）
  void saveMeta(CompressionMetaEntity meta) {
    final now = DateTime.now().millisecondsSinceEpoch;
    meta.updateTime = now;
    _db.execute('''
      INSERT INTO context_compression_meta (
        employee_id, device_id, prune_start_seq,
        last_compression_time, messages_since_compression, update_time
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(employee_id, device_id) DO UPDATE SET
        prune_start_seq = excluded.prune_start_seq,
        last_compression_time = excluded.last_compression_time,
        messages_since_compression = excluded.messages_since_compression,
        update_time = excluded.update_time
    ''', [meta.employeeId, meta.deviceId, meta.pruneStartSeq,
          meta.lastCompressionTime, meta.messagesSinceCompression, meta.updateTime]);
  }

  /// 递增冷却计数
  void incrementCoolDown(String employeeId, String deviceId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'UPDATE context_compression_meta SET messages_since_compression = messages_since_compression + 1, update_time = ? WHERE employee_id = ? AND device_id = ?',
      [now, employeeId, deviceId],
    );
  }

  /// 重置冷却计数
  void resetCoolDown(String employeeId, String deviceId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'UPDATE context_compression_meta SET messages_since_compression = 0, last_compression_time = ?, update_time = ? WHERE employee_id = ? AND device_id = ?',
      [now, now, employeeId, deviceId],
    );
  }

  /// 删除压缩元数据
  void deleteMeta(String employeeId, String deviceId) {
    _db.execute(
      'DELETE FROM context_compression_meta WHERE employee_id = ? AND device_id = ?',
      [employeeId, deviceId],
    );
  }
}
```

---

## 四、核心压缩逻辑

### 4.1 ContextCompressor — 触发判断

```dart
/// 判断是否需要触发压缩
bool shouldCompress({
  required int totalTokens,
  required SessionHistory session,
}) {
  if (!config.enabled) return false;                        // 压缩未启用
  if (totalTokens <= config.maxContextTokens) return false; // token 未超阈值
  if (session.messagesSinceCompression < config.cooldownMessageCount) {
    return false;                                            // 冷却期未过
  }
  return true;
}
```

### 4.2 ContextCompressor — 压缩执行（纯本地，不调 LLM）

```dart
void _doCompression({
  required String employeeId,
  required List<ChatMessage> allMessages,
  required SessionHistory session,
  String? systemPrompt,
}) {
  final budget = config.effectiveBudget;
  if (budget <= 0) return;

  // 估算系统提示 + 最近 1 轮的 token
  final systemTokens = systemPrompt != null
      ? _estimator.estimateTokens(systemPrompt) + 4 : 0;
  final turns = groupIntoTurns(allMessages);
  if (turns.length <= 1) return;

  final recentTurn = turns.last;
  final recentTokens = _estimator.estimateMessagesTotal(recentTurn.messages);
  final targetTokens = config.targetThreshold - systemTokens - recentTokens;
  if (targetTokens <= 0) return;

  // 从尾部往前扫描旧轮次，找到压缩边界
  final oldTurns = turns.sublist(0, turns.length - 1);
  var cumulativeTokens = 0;
  var cutIndex = 0;

  for (var i = oldTurns.length - 1; i >= 0; i--) {
    final turnTokens = _estimator.estimateMessagesTotal(oldTurns[i].messages);
    if (cumulativeTokens + turnTokens > targetTokens) {
      cutIndex = i + 1;
      break;
    }
    cumulativeTokens += turnTokens;
    if (i == 0) cutIndex = 0;
  }

  // 确定保留区第一条消息的 seq
  int newPruneStartSeq;
  if (cutIndex < oldTurns.length) {
    final cutTurn = oldTurns[cutIndex];
    newPruneStartSeq = cutTurn.messages.isNotEmpty
        ? cutTurn.messages.first.seq : 0;
  } else {
    return; // 所有旧轮次都在保留区内
  }

  if (newPruneStartSeq <= 0) return;
  if (newPruneStartSeq == session.pruneStartSeq) return;

  final now = DateTime.now().millisecondsSinceEpoch;

  // 更新内存状态
  session.pruneStartSeq = newPruneStartSeq;
  session.messagesSinceCompression = 0;
  session.lastCompressionTime = now;

  // 持久化到 DB
  if (compressionMetaStore != null && deviceId != null) {
    compressionMetaStore!.saveMeta(CompressionMetaEntity(
      employeeId: employeeId,
      deviceId: deviceId!,
      pruneStartSeq: newPruneStartSeq,
      lastCompressionTime: now,
      messagesSinceCompression: 0,
      updateTime: now,
    ));
  }
}
```

### 4.3 ContextCompressor — 构建发给 LLM 的消息

```dart
List<ChatMessage> buildCompressedMessages({
  required String employeeId,
  required List<ChatMessage> allMessages,
  required SessionHistory session,
  String? systemPrompt,
}) {
  if (!config.enabled || allMessages.isEmpty) {
    return _buildFullMessages(allMessages, systemPrompt);
  }

  final result = <ChatMessage>[];

  // 1. 系统提示
  if (systemPrompt != null && systemPrompt.isNotEmpty) {
    result.add(ChatMessage.system(
      id: '', employeeId: employeeId, content: systemPrompt,
    ));
  }

  final pruneSeq = session.pruneStartSeq;

  // 2. 统计被省略的消息数，注入提示词
  int omittedCount = 0;
  if (pruneSeq > 0) {
    for (final msg in allMessages) {
      if (msg.seq > 0 && msg.seq < pruneSeq) omittedCount++;
    }
  }

  if (omittedCount > 0) {
    result.add(ChatMessage.system(
      id: '', employeeId: employeeId,
      content: '当前会话共有 ${allMessages.length} 条历史消息，'
          '前 $omittedCount 条已被省略。'
          '如需查看历史内容，可使用 query_conversation_history 工具。',
    ));
  }

  // 3. 只保留 seq >= pruneStartSeq 的消息（原文）
  for (final msg in allMessages) {
    if (pruneSeq > 0 && msg.seq > 0 && msg.seq < pruneSeq) {
      continue; // 跳过被省略的消息
    }
    result.add(msg);
  }

  // 4. 合并连续 tool result + 修复配对
  final merged = LlmMessageMapper.mergeConsecutiveToolResults(result);
  _ensureToolCallResultPairs(merged);
  return merged;
}
```

---

## 五、SessionHistory 扩展

### 5.1 新增字段

```dart
class SessionHistory {
  // ── 压缩状态字段 ──

  /// 压缩边界 seq：seq < 此值的消息不发给 LLM
  /// 0 表示未压缩
  int pruneStartSeq;

  /// 压缩后新增的消息数（冷却期计数）
  int messagesSinceCompression;

  /// 上次压缩时间戳（epoch ms）
  int lastCompressionTime;

  // ... 构造函数、toMap、fromMap、clear 均包含这三个字段
}
```

### 5.2 启动恢复

```dart
// SessionMemoryManager.loadFromDb() 末尾：
if (_compressionMetaStore != null) {
  final meta = _compressionMetaStore!.getMeta(employeeId, _deviceId!);
  if (meta != null) {
    session.pruneStartSeq = meta.pruneStartSeq;
    session.messagesSinceCompression = meta.messagesSinceCompression;
    session.lastCompressionTime = meta.lastCompressionTime;
  }
}
```

### 5.3 冷却计数递增

```dart
// SessionMemoryManager.addMessage() 中：
final session = _sessions[employeeId];
if (session != null) {
  session.addMessage(deviceId, message);
  session.messagesSinceCompression++;  // 每条新消息递增
}
```

---

## 六、配置参数

```dart
const config = ContextCompressionConfig(
  maxContextTokens: 32000,          // 触发线
  compressionTargetRatio: 0.7,      // 目标比率（压缩到 70%）
  reservedOutputTokens: 4096,       // 预留输出 token
  recentTurnsKeep: 1,               // 最近 1 轮完整保留
  cooldownMessageCount: 10,         // 压缩后 10 条消息内不检查
);
```

```dart
class ContextCompressionConfig {
  final int maxContextTokens;
  final int reservedOutputTokens;
  final int recentTurnsKeep;
  final int cooldownMessageCount;
  final double compressionTargetRatio;

  bool get enabled => maxContextTokens > 0;
  int get effectiveBudget => maxContextTokens - reservedOutputTokens;
  int get targetThreshold => (maxContextTokens * compressionTargetRatio).round();
}
```

---

## 七、内置工具：query_conversation_history

### 7.1 定位

查询 **DB 中的完整原始消息**，不受压缩影响。AI Agent 需要回顾被压缩掉的历史时调用。

### 7.2 工具定义

```dart
class QueryConversationHistoryTool extends AgentTool {
  @override
  String get name => 'query_conversation_history';

  @override
  String get description => '查询当前会话的历史对话消息。'
      '返回 DB 中的完整原始消息，不受上下文压缩影响。'
      '支持关键词搜索、角色过滤、seq 范围过滤和分页。';

  // 参数：keyword, role, limit(默认20), offset(默认0), beforeSeq, afterSeq

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    // 解析参数
    final keyword = arguments['keyword'] as String?;
    final role = arguments['role'] as String?;
    final limit = _parseInt(arguments['limit'], defaultValue: 20, max: 100);
    final offset = _parseInt(arguments['offset'], defaultValue: 0);
    final beforeSeq = arguments['beforeSeq'] as int?;
    final afterSeq = arguments['afterSeq'] as int?;

    // 通过回调查询 DB（由 AgentImpl 注入）
    final result = await queryMessages!(
      employeeId: employeeId!,
      keyword: keyword, role: role,
      limit: limit, offset: offset,
      beforeSeq: beforeSeq, afterSeq: afterSeq,
    );

    return ToolResult.success(jsonEncode(result));
  }
}
```

### 7.3 AgentImpl 注入

```dart
void _injectQueryConversationHistoryCallbacks() {
  final tool = _toolRegistry.getTool('query_conversation_history');
  if (tool is! QueryConversationHistoryTool) return;

  tool.employeeId = employeeId;
  tool.queryMessages = ({required String employeeId, ...}) async {
    final adapter = _chatAdapter as LlmChatAdapter;
    final session = adapter.memoryManager.getSession(employeeId);
    if (session == null) return {'messages': [], 'total': 0, 'hasMore': false};

    var allMsgs = session.allMessages;

    // 应用过滤：role、beforeSeq、afterSeq、keyword
    // ...

    // 分页
    final paged = allMsgs.skip(offset).take(limit).toList();
    return {
      'messages': paged.map((m) => {
        'seq': m.seq, 'role': m.role.name,
        'content': m.content, 'createdAt': m.createdAt.toIso8601String(),
      }).toList(),
      'total': total,
      'hasMore': offset + limit < total,
    };
  };
}
```

---

## 八、测试覆盖

### 8.1 测试结果

```
00:00 +20: All tests passed!
```

### 8.2 测试矩阵

| 分组 | 测试 | 验证内容 |
|---|---|---|
| CompressionMetaStore | getMeta 不存在→null | 基础查询 |
| | saveMeta + getMeta | CRUD |
| | incrementCoolDown / resetCoolDown | 冷却计数 |
| | deleteMeta | 删除 |
| shouldCompress | token 未超→false | 阈值判断 |
| | 冷却期未过→false | 冷却判断 |
| | 满足条件→true | 正常触发 |
| | 禁用→false | 全局开关 |
| buildCompressedMessages | pruneStartSeq=0→全量 | 无压缩 |
| | pruneStartSeq>0→丢弃+提示词 | 核心压缩逻辑 |
| | system prompt 在提示词之前 | 消息顺序 |
| groupIntoTurns | 按 user 分组 | 轮次分组 |
| | 空列表→空 | 边界 |
| SessionHistory | 默认值 | 初始化 |
| | toMap / fromMap | 序列化 |
| | clear() | 重置 |
| 集成 | 持久化恢复 | 重启后状态正确 |
| | 冷却期重启仍生效 | 冷却持久化 |
| Config | 默认值 | 初始化 |
| | toMap / fromMap | 序列化 |

### 8.3 关键测试用例

```dart
test('pruneStartSeq>0 → 旧消息被丢弃，注入提示词，新消息原文保留', () {
  final session = SessionHistory(employeeId: 'emp-1');
  session.pruneStartSeq = 3;

  final messages = [
    _userMsg('emp-1', 'm1', '旧消息1', seq: 1),
    _asstMsg('emp-1', 'm2', '旧回复1', seq: 2),
    _userMsg('emp-1', 'm3', '新消息', seq: 3),
    _asstMsg('emp-1', 'm4', '新回复', seq: 4),
  ];

  final result = compressor.buildCompressedMessages(
    employeeId: 'emp-1', allMessages: messages, session: session,
  );

  // 结果：提示词 + 新消息
  expect(result.length, 3);

  // 第一条是提示词
  expect(result[0].role, MessageRole.system);
  expect(result[0].content, contains('前 2 条已被省略'));
  expect(result[0].content, contains('query_conversation_history'));

  // 后两条是新消息原文
  expect(result[1].content, '新消息');
  expect(result[2].content, '新回复');
});
```

---

## 九、完整数据流

### 9.1 正常对话（未超阈值）

```
用户发消息
  → addMessage → session.messagesSinceCompression++
  → prepareCompression → shouldCompress? → NO（token 未超）
  → buildCompressedMessages → 全量消息
  → 调用 LLM
```

### 9.2 触发压缩

```
用户发消息
  → addMessage → session.messagesSinceCompression++
  → prepareCompression → shouldCompress? → YES
    → AsyncLock.tryLock → 成功
    → 分轮次 → 从尾部往前贪心选择 → 计算 pruneStartSeq
    → 更新 session 状态
    → 持久化到 DB (context_compression_meta)
    → AsyncLock.unlock
  → buildCompressedMessages
    → 注入提示词 "前 N 条已被省略"
    → 只保留 seq >= pruneStartSeq 的消息
  → 调用 LLM
```

### 9.3 冷却期内

```
用户发消息
  → addMessage → session.messagesSinceCompression++
  → prepareCompression → shouldCompress? → NO（冷却期）
  → buildCompressedMessages → 使用上次的 pruneStartSeq
  → 调用 LLM
```

### 9.4 AI 查询历史

```
AI 调用 query_conversation_history(keyword="xxx", limit=20)
  → 从 SessionHistory.allMessages 查询 DB 原始消息
  → 应用过滤（role、keyword、seq 范围）
  → 分页返回完整消息
```

### 9.5 重启恢复

```
应用启动
  → loadFromDb()
    → 加载消息到内存（完整）
    → CompressionMetaStore.getMeta()
      → session.pruneStartSeq = meta.pruneStartSeq
      → session.messagesSinceCompression = meta.messagesSinceCompression
    → buildCompressedMessages 正常工作
```

---

## 十、架构总览

```
┌─────────────────────────────────────────────────────────────┐
│                    LlmChatAdapter                            │
│                                                              │
│  prepareCompression() ──→ ContextCompressor                  │
│  buildCompressedMessages() ──→ ContextCompressor              │
│  configurePersistence() ──→ CompressionMetaStore              │
└──────────────────────────┬──────────────────────────────────┘
                           │
          ┌────────────────┼────────────────┐
          │                │                │
          ▼                ▼                ▼
┌─────────────────┐ ┌──────────────┐ ┌──────────────────┐
│ ContextCompressor│ │SessionHistory│ │CompressionMetaStore│
│                 │ │              │ │                    │
│ ·shouldCompress │ │·pruneStartSeq│ │·getMeta()          │
│ ·prepareCompres │ │·messagesSince│ │·saveMeta()         │
│ ·buildCompresse │ │·lastCompTime │ │·incrementCoolDown()│
│ ·groupIntoTurns │ │              │ │·resetCoolDown()    │
└─────────────────┘ └──────────────┘ └──────────────────┘
          │                                      │
          ▼                                      ▼
┌─────────────────────────────────────────────────────────────┐
│           context_compression_meta 表 (SQLite)               │
│                                                             │
│  PK(employee_id, device_id)                                 │
│  prune_start_seq | last_compression_time                    │
│  messages_since_compression | update_time                   │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│         QueryConversationHistoryTool (内置工具)              │
│                                                             │
│  查询 DB 原始消息（不受压缩影响）                            │
│  参数: keyword, role, limit, offset, beforeSeq, afterSeq    │
│  AI 需要查看被压缩掉的历史时自动调用                         │
└─────────────────────────────────────────────────────────────┘
```
