# CachedAgentProxy 前端开发指南

## 概述

`CachedAgentProxy` 是前端与 Agent 交互的核心入口，封装了消息收发、状态监听、已读管理、同步等全部能力。

它有两种工作模式，前端**无需感知差异**，API 完全一致：

| 模式 | 说明 | 消息来源 |
|------|------|----------|
| 本地模式 `isLocalMode=true` | 本机员工，Agent 运行在同一进程 | Agent 内存 |
| 远程模式 `isLocalMode=false` | 远程员工，Agent 运行在局域网 Host 设备 | 本地 SQLite 缓存 + 远程同步 |

---

## 1. 生命周期

```dart
// 1. 创建（由 DeviceAgentManager 完成，前端无需手动创建）
final proxy = CachedAgentProxy(
  proxy: agentProxy,
  messageStore: messageStoreService,
  deviceId: myDeviceId,
  employeeId: targetEmployeeId,
);

// 2. 初始化（加载本地缓存 + 启动事件监听）
await proxy.initialize();

// 3. 远程模式下，连接成功后同步远程数据
await proxy.syncFromRemote();

// 4. 页面销毁时释放
await proxy.dispose();
```

---

## 2. 核心 API

### 2.1 发送消息

```dart
final messageId = await proxy.sendMessage(
  MessageInput(
    content: '你好',
    type: 'text',      // 可选，默认 'text'
    // role: 'user',   // 可选，默认 user，一般不需要传
  ),
);
// 返回消息 ID（UUID）
```

**消息生命周期**：

```
pending（本地写入）→ sent（RPC 成功）→ queued（入队）→ processing（处理中）
  → completed / failed / interrupted
```

> 发送后消息**立即可见**（本地先写入数据库再发远程），无需等待 RPC 返回。

### 2.2 获取消息列表

```dart
// 获取消息（从本地数据库读取，最近 20 轮对话）
final messages = await proxy.getMessages();

// 强制刷新（先同步远程再返回）
final messages = await proxy.getMessagesForceRefresh();
```

**`getMessages()` 返回规则**：
- 按时间正序排列
- 最多包含最近 20 条 `role='user'` 消息及其对应的所有 assistant 消息
- 过滤 `deleted=true` 的消息

### 2.3 监听消息变化（推荐）

```dart
// 监听消息列表变化流，UI 自动刷新
proxy.onMessagesChanged.listen((List<AgentMessage> messages) {
  // messages 是完整的新消息列表，直接替换 UI 数据源
  updateUI(messages);
});
```

**触发时机**：发送消息、远程同步完成、状态变更、清空会话、标记已读等。

> 去抖机制：16ms 内合并多次变更，避免高频刷新。

### 2.4 监听缓存状态

```dart
proxy.onCacheStateChanged.listen((CacheState state) {
  // idle / loading / syncing / error
});
```

---

## 3. Agent 状态

```dart
// 当前状态
final status = proxy.status;        // AgentStatus 枚举
final isSending = proxy.isSending;  // 是否正在处理消息
final isAlive = proxy.isAlive;      // Agent 是否存活

// 监听状态变化
proxy.onStateChanged.listen((AgentStateSnapshot snapshot) {
  // snapshot.status: idle / processing / streaming / waitingPermission / disposed
  // snapshot.currentProcessingMessageId: 当前处理的消息 ID
  // snapshot.queuedMessageIds: 队列中的消息 ID 列表
  // snapshot.queueLength: 队列长度
});

// 获取完整状态快照（异步，远程模式走 RPC）
final snapshot = await proxy.getStateSnapshotAsync();
```

### AgentStatus 枚举

| 值 | 含义 |
|----|------|
| `idle` | 空闲，等待消息 |
| `processing` | 正在处理消息 |
| `streaming` | 流式输出中 |
| `waitingPermission` | 等待工具权限确认 |
| `disposed` | 已释放 |

---

## 4. 未读消息

```dart
// 获取未读数量
final count = await proxy.getUnreadCount();

// 获取未读消息 ID 列表
final ids = await proxy.getUnreadMessageIds();

// 标记当前会话消息为已读（用户打开会话窗口时调用）
proxy.markMessagesAsRead();

// 标记指定消息为已读
proxy.markMessagesAsRead(messageIds: ['msg-id-1', 'msg-id-2']);

// 清除全部未读（本地 DB 立即更新 + 通知远程）
await proxy.clearAllUnread();
```

> **已读可靠性**：远程模式下，标记已读请求会持久化到本地队列。断线重连后自动重发，保证最终一致性。

---

## 5. 会话操作

### 5.1 清空会话

```dart
await proxy.clearCurrentSession();
// 本地消息清空 + 水位线重置 + 远程清空 + 广播通知其他客户端
```

### 5.2 撤回消息

```dart
await proxy.revokeMessage(messageId);
// 远程撤回 + 本地删除 + 删除关联的助手回复（本地模式）
```

### 5.3 中断处理

```dart
await proxy.interrupt();
// 中断当前正在处理的消息
```

---

## 6. 工具调用

### 6.1 权限请求

当 Agent 需要用户确认工具调用权限时：

```dart
// 获取当前权限请求（同步，从缓存读取）
final request = proxy.getPendingPermissionRequest();
if (request != null) {
  // request.requestId
  // request.functionName
  // request.description
  // request.arguments
}

// 响应权限
await proxy.respondToPermission(
  requestId,
  PermissionDecision.allowOnce,   // allowOnce / allowAlways / deny
);
```

### 6.2 查询正在调用的工具

```dart
// 本地模式
final toolIds = proxy.getCallingToolIds();

// 远程模式（走 RPC）
final toolIds = await proxy.getCallingToolIdsAsync();
```

---

## 7. 消息数据结构

### AgentMessage

前端渲染消息使用的核心类型：

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `String` | 消息唯一 ID（UUID） |
| `role` | `String` | 角色：`user` / `assistant` / `system` / `tool` |
| `type` | `String` | 类型：`text` / `functionCall` / `functionResult` / `error` |
| `content` | `String?` | 消息文本内容 |
| `status` | `String?` | 状态：见下表 |
| `createdAt` | `DateTime` | 创建时间 |
| `toolCallId` | `String?` | 工具调用 ID |
| `toolName` | `String?` | 工具名称 |
| `toolArguments` | `Map?` | 工具参数 |
| `toolResult` | `String?` | 工具结果 |
| `toolCalls` | `List<ToolCall>?` | 多工具调用列表 |
| `metadata` | `Map?` | 扩展字段，见下文 |

### 消息状态（status）

| 值 | 含义 | 是否持久化 |
|----|------|-----------|
| `pending` | 发送中（本地写入） | 是 |
| `sent` | 已发送到远程 | 否（很快被覆盖） |
| `queued` | 排队中 | 否 |
| `processing` | 处理中 | 否 |
| `completed` | 处理完成 | 是 |
| `failed` | 处理失败 | 是 |
| `interrupted` | 被中断 | 是 |

### metadata 常用字段

| key | 说明 |
|-----|------|
| `seq` | 同步序列号（内部使用，前端一般不需要） |
| `localOnly` | 是否为本地临时消息 |
| `localToolCall` | 是否为本地临时工具调用消息 |
| `isRead` | 是否已读 |
| `updateTime` | 更新时间（ISO8601） |
| `queuePosition` | 队列位置 |
| `replyMessageId` | 回复的消息 ID |
| `replied` | 是否已被回复 |
| `error` | 是否为错误消息 |
| `originalMessageId` | 错误消息对应的原始消息 ID |

---

## 8. Provider / 技能 / MCP 配置

```dart
// Provider
await proxy.setProvider(ProviderConfig(provider: 'openai', model: 'gpt-4'));
final config = proxy.getProviderConfig();
final config = await proxy.getProviderConfigAsync();  // 远程模式

// 技能
await proxy.setSkills([{'name': 'web_search', ...}]);
final skills = proxy.getSkillsConfig();
final skills = await proxy.getSkillsConfigAsync();

// MCP
await proxy.setMcpConfigs([{...}]);
final mcps = proxy.getMcpConfigs();
final mcps = await proxy.getMcpConfigsAsync();

// 项目
await proxy.setProject(ProjectData(projectUuid: 'xxx', projectName: 'demo'));
final uuid = proxy.getCurrentProjectUuid();
final uuid = await proxy.getCurrentProjectUuidAsync();

// 上下文
await proxy.setContext({'key': 'value'});
final ctx = proxy.getCurrentContext();
```

---

## 9. 文件操作（远程模式下操作目标设备文件）

```dart
final exists = await proxy.checkPathExists('/path/to/file');
final listing = await proxy.listDirectory('/path/to/dir');
final info = await proxy.getFileInfo('/path/to/file');
await proxy.createDirectory('/path/to/dir');
await proxy.deleteFile('/path/to/file');
await proxy.renameFile('/old/path', '/new/path');
```

---

## 10. 典型页面集成示例

```dart
class ChatPage extends StatefulWidget { ... }

class _ChatPageState extends State<ChatPage> {
  List<AgentMessage> _messages = [];
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = proxy.onMessagesChanged.listen((messages) {
      setState(() => _messages = messages);
    });
    // 首次加载
    proxy.getMessages().then((m) => setState(() => _messages = m));
  }

  Future<void> _onSend(String text) async {
    await proxy.sendMessage(MessageInput(content: text));
    // 消息列表会通过 onMessagesChanged 自动更新
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: _messages.length,
      itemBuilder: (_, i) => MessageBubble(_messages[i]),
    );
  }
}
```

---

## 11. 线程安全说明

| API | 线程安全 | 说明 |
|-----|---------|------|
| `sendMessage` | 并发安全 | 内部有锁，重复调用会排队 |
| `syncFromRemote` | 并发安全 | Completer 锁，重复调用复用首次 Future |
| `getMessages` | 无锁 | 只读操作，可以任意时刻调用 |
| `onMessagesChanged` | 单订阅安全 | broadcast 流，可多处监听 |

---

## 12. 注意事项

1. **必须先 `initialize()`**：使用任何 API 前必须调用，否则事件监听未启动。
2. **远程模式必须 `syncFromRemote()`**：`initialize()` 只加载本地缓存，需要额外调用同步远程数据。
3. **`onMessagesChanged` 是推荐的刷新方式**：不要手动轮询 `getMessages()`，监听流即可。
4. **`clearCurrentSession` 会广播**：所有客户端（包括发起者）都会清空本地消息。
5. **`markMessagesAsRead` 不需要 await**：内部 fire-and-forget，失败会自动重试。
6. **错误消息**：消息处理失败时，会自动创建一条 `type='error'` 的 assistant 消息，ID 格式为 `error_{originalId}`。
7. **工具调用临时消息**：ID 格式为 `local_toolcall_{toolCallId}`，同步后会被远程消息替换。
