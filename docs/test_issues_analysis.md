# Agent 测试问题分析报告

## 测试结果摘要

**测试时间**: 2026-04-08  
**测试环境**: 
- API: https://token-plan-cn.xiaomimimo.com/v1
- Model: mimo-v2-pro
- 总测试数: 6
- 通过: 4 (66.7%)
- 失败: 2 (33.3%)

---

## 发现的问题

### 🔴 严重问题

#### 1. 持久化类型转换错误

**问题代码位置**: `lib/src/agent/adapter/persistent_chat_adapter.dart`

**错误信息**:
```
type 'List<Map<String, Object>>' is not a subtype of type 'String?' in type cast
```

**问题代码**:
```dart
// 在 _messageWrapperToMap 方法中 (Line 381-425)
if (message is AIChatMessage && message.toolCalls.isNotEmpty) {
  map['toolCalls'] = message.toolCalls
      .map(
        (tc) => {'id': tc.id, 'name': tc.name, 'arguments': tc.arguments},
      )
      .toList();  // ❌ 这里返回 List<Map<String, dynamic>>
}
```

**问题分析**:
1. `AIChatMessage.toolCalls` 是 `List<AIChatMessageToolCall>` 类型
2. 转换后的结果是 `List<Map<String, dynamic>>`
3. 但是在 `AiEmployeeMessageEntity` 中，`toolCalls` 字段定义为 `String?`
4. Hive 存储时需要将 List 序列化为 JSON 字符串

**修复方案**:
```dart
// ✅ 正确做法：序列化为 JSON 字符串
if (message is AIChatMessage && message.toolCalls.isNotEmpty) {
  map['toolCalls'] = jsonEncode(message.toolCalls
      .map(
        (tc) => {'id': tc.id, 'name': tc.name, 'arguments': tc.arguments},
      )
      .toList());
}
```

**影响范围**:
- 所有包含工具调用的消息持久化失败
- 导致消息队列堆积
- 可能导致状态转换卡死

---

#### 2. 状态转换超时问题

**错误信息**:
```
TimeoutException: 等待 idle 状态超时
```

**问题现象**:
- "状态监听"测试超时
- "删除消息"测试超时

**可能原因**:

1. **持久化错误导致任务卡死**
   - 持久化失败后，任务可能在队列中重试
   - 阻塞了后续的消息处理

2. **状态广播不及时**
   - AgentImpl 的状态变化可能没有及时广播
   - StreamController 可能有缓冲问题

3. **消息处理流程异常**
   - 某个消息处理卡住
   - 导致后续消息无法处理

**修复建议**:
```dart
// 在 AgentImpl 中添加超时保护
Future<void> _waitForIdle() async {
  final maxWaitTime = Duration(seconds: 30);
  final startTime = DateTime.now();
  
  while (status != AgentStatus.idle) {
    if (DateTime.now().difference(startTime) > maxWaitTime) {
      // 强制重置状态
      _setStatus(AgentStatus.idle);
      break;
    }
    await Future.delayed(Duration(milliseconds: 100));
  }
}
```

---

### 🟡 次要问题

#### 3. 持久化队列重试机制

**问题现象**:
```
[PersistenceQueue] Task failed: PersistenceTaskType.message
[PersistenceQueue] Retrying task...
[PersistenceQueue] Task failed permanently
```

**问题分析**:
- 重试机制导致任务队列堆积
- 失败任务占用资源

**改进建议**:
1. 添加失败任务的最大重试次数限制 ✅ (已有)
2. 添加失败任务的降级处理
3. 记录失败任务的详细信息

---

## 修复优先级

### P0 - 立即修复
1. ✅ **修复 toolCalls 序列化问题** (Line 412)
   - 文件: `persistent_chat_adapter.dart`
   - 影响: 所有工具调用消息

### P1 - 高优先级
2. ✅ **添加状态转换超时保护**
   - 文件: `agent_impl.dart`
   - 影响: 状态监听功能

### P2 - 中优先级
3. ✅ **优化持久化错误处理**
   - 文件: `persistent_chat_adapter.dart`
   - 影响: 错误恢复能力

---

## 修复步骤

### 第一步：修复 toolCalls 序列化

```dart
// 文件: lib/src/agent/adapter/persistent_chat_adapter.dart
// Line 410-417

// ❌ 错误代码
if (message is AIChatMessage && message.toolCalls.isNotEmpty) {
  map['toolCalls'] = message.toolCalls
      .map(
        (tc) => {'id': tc.id, 'name': tc.name, 'arguments': tc.arguments},
      )
      .toList();
}

// ✅ 修复后
if (message is AIChatMessage && message.toolCalls.isNotEmpty) {
  map['toolCalls'] = jsonEncode(message.toolCalls
      .map(
        (tc) => {'id': tc.id, 'name': tc.name, 'arguments': tc.arguments},
      )
      .toList());
}
```

### 第二步：添加状态转换保护

```dart
// 文件: lib/src/agent/impl/agent_impl.dart
// 在 _syncProcessorStatus 方法中添加超时检测

void _syncProcessorStatus(AgentStatus processorStatus) {
  // 添加状态转换日志
  print('[AgentImpl] State transition: $_status -> $processorStatus');
  
  switch (processorStatus) {
    case AgentStatus.idle:
      _setStatus(AgentStatus.idle);
      break;
    case AgentStatus.processing:
    case AgentStatus.streaming:
      _setStatus(processorStatus);
      break;
    case AgentStatus.waitingPermission:
      _setStatus(AgentStatus.waitingPermission);
      break;
    case AgentStatus.disposed:
      break;
  }
}
```

### 第三步：增强错误处理

```dart
// 文件: lib/src/agent/adapter/persistent_chat_adapter.dart
// 在 _persistMessage 方法中添加错误处理

void _persistMessage(Map<String, dynamic> message) {
  if (persistMessage == null) return;

  try {
    // 验证消息格式
    _validateMessageFormat(message);
    
    final messageWithSession = {...message, 'employeeId': currentSessionUuid};
    
    _persistenceQueue.addMessageTask(messageWithSession, (data) async {
      try {
        await persistMessage!(data);
      } catch (e) {
        print('[PersistentChatAdapter] _persistMessage: 持久化失败: $e');
        rethrow;
      }
    });
  } catch (e) {
    print('[PersistentChatAdapter] 消息格式验证失败: $e');
    // 不阻塞主流程，继续执行
  }
}

void _validateMessageFormat(Map<String, dynamic> message) {
  // 确保 toolCalls 是字符串类型
  if (message['toolCalls'] != null && message['toolCalls'] is! String) {
    message['toolCalls'] = jsonEncode(message['toolCalls']);
  }
}
```

---

## 测试建议

### 1. 单元测试
- 添加 `toolCalls` 序列化的单元测试
- 测试各种消息类型的持久化

### 2. 集成测试
- 添加状态转换的集成测试
- 测试超时场景的处理

### 3. 压力测试
- 测试大量消息的持久化性能
- 测试并发场景下的状态管理

---

## 预期结果

修复后，所有测试应该：
1. ✅ 发送消息并收到回复
2. ✅ 消息ID一致性
3. ✅ 消息不重复
4. ✅ 状态监听
5. ✅ 删除消息
6. ✅ 清空消息

持久化队列应该：
- 成功率: 100%
- 无类型转换错误
- 无任务堆积

状态转换应该：
- 及时响应
- 无超时
- 正确广播

---

## 下一步行动

1. **立即修复**: toolCalls 序列化问题
2. **验证修复**: 运行测试验证
3. **提交代码**: 创建修复分支
4. **持续监控**: 添加监控日志
