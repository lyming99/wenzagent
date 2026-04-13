# Agent 工具调用状态查询 - 前端调整说明

## 新增能力

Agent 新增 **工具调用状态查询** 能力，前端可获取当前正在执行中的工具 `callId` 列表，用于：
- 判断哪些工具尚在运行，避免重复提交
- 显示工具调用中的加载状态
- `interrupt` 后确认所有工具已终止

## API 接口

### 同步查询（仅本地模式准确）

```dart
// CachedAgentProxy / AgentProxy 均可用
List<String> callIds = proxy.getCallingToolIds();
// 返回当前正在调用中的 callId 列表（不可变）
// 空列表 = 没有工具在运行
```

### 异步查询（本地 + 远程均准确）

```dart
// 推荐使用，远程模式下通过 RPC 查询 Agent 端真实状态
List<String> callIds = await proxy.getCallingToolIdsAsync();
```

## 事件流（已有能力，无需改动）

前端已通过 `onEvent` 流收到工具调用事件，这些事件与状态查询的数据来源一致：

| 事件类型 | 触发时机 | 数据字段 |
|----------|----------|----------|
| `toolCallStart` | 工具开始执行 | `toolCallId`, `toolName`, `arguments` |
| `toolCallResult` | 工具执行完成 | `toolCallId`, `toolName`, `result`, `isError` |

## 推荐前端使用方式

### 场景 1：显示工具加载状态

```dart
// 监听事件流 + 查询状态结合
proxy.onEvent.listen((event) {
  if (event.type == AgentEventType.toolCallStart ||
      event.type == AgentEventType.toolCallResult) {
    // 刷新 UI：查询当前正在调用的工具
    final callingIds = proxy.getCallingToolIds();
    updateToolStatus(callingIds);
  }
});

// 页面初始化或恢复时，主动查询一次
final callingIds = await proxy.getCallingToolIdsAsync();
```

### 场景 2：interrupt 后确认清理

```dart
await proxy.interrupt();
// interrupt 会清空所有工具调用状态
final callingIds = proxy.getCallingToolIds();
assert(callingIds.isEmpty); // 一定为空
```

### 场景 3：判断 Agent 是否完全空闲

```dart
final isCompletelyIdle = proxy.status == AgentStatus.idle
    && proxy.getCallingToolIds().isEmpty;
```

## 注意事项

1. **本地模式**下同步方法 `getCallingToolIds()` 返回实时数据，可直接使用
2. **远程模式**下同步方法返回空列表，必须使用异步方法 `getCallingToolIdsAsync()` 获取真实状态
3. `getCallingToolIds()` 返回的是不可变副本，每次调用都是快照
4. 工具调用状态在 `interrupt` 和 `dispose` 时会自动清空
