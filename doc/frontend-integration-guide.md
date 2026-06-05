# Wenzagent 前端接入文档

> 版本：v1.0 | 更新日期：2025-06-18

本文档面向前端开发者，介绍如何基于 `DeviceClient` + `CachedAgentProxy` + `AgentNotificationHub` 三大核心 API 接入 wenzagent SDK，实现多设备 LAN 同步的 AI Agent 对话系统。

---

## 目录

1. [架构概览](#1-架构概览)
2. [快速开始](#2-快速开始)
3. [核心对象生命周期](#3-核心对象生命周期)
4. [会话窗口 API（CachedAgentProxy）](#4-会话窗口-api)
5. [通知中心 API（AgentNotificationHub）](#5-通知中心-api)
6. [设备级 API（DeviceClient）](#6-设备级-api)
7. [Todo 数据同步](#7-todo-数据同步)
8. [Spec 数据同步](#8-spec-数据同步)
9. [会话摘要与未读计数](#9-会话摘要与未读计数)
10. [事件类型速查表](#10-事件类型速查表)
11. [状态枚举速查表](#11-状态枚举速查表)
12. [前端集成模式推荐](#12-前端集成模式推荐)
13. [常见问题](#13-常见问题)

---

## 1. 架构概览

```
┌──────────────────────────────────────────────────────┐
│                     Flutter 前端                       │
│  ┌─────────┐  ┌──────────┐  ┌──────────┐  ┌────────┐ │
│  │ 会话列表  │  │ 聊天窗口  │  │ Todo面板  │  │Spec面板│ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───┬────┘ │
│       │              │              │             │      │
│  ┌────▼──────────────▼──────────────▼─────────────▼───┐ │
│  │              DeviceClient（设备级入口）                │ │
│  │  ┌──────────────┐  ┌──────────────────────────────┐ │ │
│  │  │NotificationHub│  │    CachedAgentProxy（会话代理）│ │ │
│  │  │  事件分发中心   │  │  消息收发 / 状态查询 / 缓存   │ │ │
│  │  └──────────────┘  └──────────────────────────────┘ │ │
│  │  ┌──────────────┐  ┌──────────────────────────────┐ │ │
│  │  │ DataSyncMgr  │  │    AgentProxy（底层通信）      │ │ │
│  │  │ 跨设备同步    │  │    RPC 调用 / 事件流          │ │ │
│  │  └──────────────┘  └──────────────────────────────┘ │ │
│  └─────────────────────────────────────────────────────┘ │
│       │ LAN (MQTT/WebSocket)                            │
└───────┼──────────────────────────────────────────────────┘
        │
   ┌────▼────┐
   │ 其他设备  │ （数据自动同步）
   └─────────┘
```

**核心概念：**

| 概念 | 说明 |
|------|------|
| `DeviceClient` | 设备级单例入口，管理连接、员工、会话、同步 |
| `CachedAgentProxy` | 会话窗口代理，封装消息收发、缓存、状态查询 |
| `AgentNotificationHub` | 事件分发中心，所有 UI 更新通过事件流驱动 |
| `employeeId` | 员工 UUID，等价于会话 ID |
| `deviceId` | 设备 ID，数据隔离维度 |

---

## 2. 快速开始

### 2.1 初始化

```dart
import 'package:wenzagent/wenzagent.dart';

// 1. 获取 DeviceClient 实例
final deviceId = 'my-device-001'; // 通常使用设备唯一标识
final client = DeviceClient.getInstance(deviceId);

// 2. 初始化（必须在使用前调用）
await client.initialize(DeviceClientConfig(
  storagePath: '/path/to/app/data',   // 存储根路径（必填）
  // dbPath: '/path/to/app/data/db',  // 可选，默认 {storagePath}/db
  // skillsDir: '/path/to/app/data/skills/folder',  // 可选，默认 {storagePath}/skills/folder
  host: '192.168.1.100',         // LAN 服务器地址
  port: 9090,                    // 端口，默认 9090
  deviceName: '我的电脑',          // 设备名称（可选）
));

// 3. 连接到 LAN 服务器
await client.connect();

// 4. 启动后恢复状态
client.restorePendingRequests(); // 恢复 pending 权限/确认请求
await client.restoreUnreadStatus(); // 恢复未读计数
```

### 2.2 创建/获取会话代理

```dart
// 获取或创建 CachedAgentProxy（核心交互对象）
final proxy = await client.getOrCreateAgentProxy(
  employeeId: 'employee-uuid-001',
);

// 初始化代理
await proxy.initialize();

// 从远程同步消息（首次打开时调用）
await proxy.syncFromRemote();
```

### 2.3 发送消息

```dart
final messageId = await proxy.sendMessage(MessageInput(
  role: 'user',
  type: 'text',
  content: '你好，请帮我分析这段代码',
));
print('消息已发送，ID: $messageId');
```

### 2.4 监听事件

```dart
// 订阅所有事件（推荐用于调试）
final subscription = client.notificationHub.subscribe(
  (event) {
    switch (event) {
      case AgentMessageArrivedEvent(:final message, :final employeeId):
        print('新消息: ${message.content} 来自会话: $employeeId');
      case AgentUnreadCountChangedEvent(:final employeeId, :final unreadCount):
        print('未读变更: $employeeId -> $unreadCount');
      case AgentStatusNotifyEvent(:final employeeId, :final status):
        print('状态变更: $employeeId -> $status');
      // ... 更多事件
    }
  },
  employeeId: 'employee-uuid-001', // 可选：只监听特定会话
);
```

### 2.5 销毁

```dart
// 销毁会话代理
await client.destroyAgentProxy('employee-uuid-001');

// 断开连接
await client.disconnect();

// 完全释放
await client.dispose();
```

---

## 3. 核心对象生命周期

```
DeviceClient.initialize()
    │
    ├── DatabaseManager 初始化
    ├── AppContext 创建（依赖注入容器）
    ├── 子模块初始化（连接管理、设备注册、通知等）
    │
    ▼
DeviceClient.connect()
    │
    ├── LAN 连接建立
    ├── 设备注册 & 发现
    ├── 数据同步启动
    │
    ▼
client.getOrCreateAgentProxy(employeeId)
    │
    ├── 创建 AgentProxy（local 或 remote）
    ├── 包装为 CachedAgentProxy
    ├── proxy.initialize()
    ├── proxy.syncFromRemote()
    │
    ▼
使用 proxy 交互（发消息、查状态、监听事件）
    │
    ▼
client.destroyAgentProxy(employeeId)
    └── 释放代理资源
```

---

## 4. 会话窗口 API

`CachedAgentProxy` 是前端最常用的 API，每个会话窗口持有一个实例。

### 4.1 消息收发

```dart
// ── 发送消息 ──
final messageId = await proxy.sendMessage(MessageInput(
  role: 'user',              // 'user' | 'system'
  type: 'text',              // 'text' | 'image' | 'file' | 'tool_result'
  content: '消息内容',
));

// ── 获取消息列表 ──
final messages = await proxy.getMessages();        // 从本地缓存
final freshMessages = await proxy.getMessagesForceRefresh(); // 强制从远程刷新

// ── 消息分页 ──
final page1 = await proxy.getSessionMessagesPaged(pageSize: 20, offset: 0);

// ── 撤回消息 ──
await proxy.revokeMessage(messageId);
```

### 4.2 状态查询

```dart
// ── 同步查询（读本地缓存，无网络延迟） ──
final status = proxy.status;               // AgentStatus 枚举
final snapshot = proxy.getStateSnapshot(); // 完整状态快照
final isStreaming = snapshot.isStreaming;
final queueLength = snapshot.queueLength;
final toolIds = proxy.getCallingToolIds();  // 正在调用的工具 ID 列表

// ── 异步查询（从远程拉取最新） ──
final remoteSnapshot = await proxy.getStateSnapshotAsync();
final remoteToolIds = await proxy.getCallingToolIdsAsync();

// ── 缓存状态（仅远程模式） ──
final cacheState = proxy.cacheState;     // CacheState 枚举
final isSynced = proxy.isSynced;
final lastSync = proxy.lastSyncTime;
final msgCount = await proxy.cachedMessageCount;

// ── 模式判断 ──
final isLocal = proxy.isLocalMode;       // true = 本地 Agent，false = 远程
```

### 4.3 配置操作

```dart
// ── 设置 Provider（LLM 模型配置）──
await proxy.setProvider(ProviderConfig(
  provider: 'openai',
  model: 'gpt-4o',
  apiKey: 'sk-xxx',
  baseUrl: 'https://api.openai.com/v1',
));

// ── 获取当前 Provider 配置 ──
final config = proxy.getProviderConfig();          // 同步（缓存）
final config2 = await proxy.getProviderConfigAsync(); // 异步（远程）

// ── 设置上下文数据 ──
await proxy.setContext({'key': 'value'});

// ── 设置技能 ──
await proxy.setSkills([
  {'name': 'code_review', 'description': '代码审查'},
]);

// ── 设置 MCP 配置 ──
await proxy.setMcpConfigs([
  {'name': 'my_server', 'command': 'npx', 'args': ['server']},
]);

// ── 设置项目 ──
await proxy.setProject(ProjectData(
  uuid: 'project-uuid',
  path: '/home/user/project',
  name: 'My Project',
));
```

### 4.4 权限与确认

```dart
// ── 查询 pending 权限请求 ──
final permReq = proxy.getPendingPermissionRequest();
final permReqAsync = await proxy.getPendingPermissionRequestAsync();

// ── 响应权限请求 ──
await proxy.respondToPermission(
  requestId,
  PermissionDecision.approved,
  approvalSettings: PermissionApprovalSettings(
    duration: PermissionDuration.always,
  ),
);

// ── 查询 pending 确认请求 ──
final confirmReq = proxy.getPendingConfirmRequest();
final confirmReqAsync = await proxy.getPendingConfirmRequestAsync();

// ── 响应确认请求 ──
await proxy.respondToConfirm(requestId, 'selected_option_key');
```

### 4.5 会话操作

```dart
// ── 清空当前会话 ──
await proxy.clearCurrentSession();

// ── 中断当前处理 ──
await proxy.interrupt();

// ── 清除缓存 ──
await proxy.clearCache();
```

### 4.6 未读消息

```dart
final unreadCount = await proxy.getUnreadCount();
final unreadIds = await proxy.getUnreadMessageIds();

proxy.markMessagesAsRead(messageIds: ['msg-1', 'msg-2']);
proxy.markMessagesAsReadBySeq(readerDeviceId: deviceId, readSeq: 100);

await proxy.clearAllUnread();
```

---

## 5. 通知中心 API

`AgentNotificationHub` 是 UI 实时更新的核心，通过事件流驱动。

### 5.1 订阅方式

```dart
// 方式一：通用订阅（可按 employeeId / fromDeviceId 过滤）
final sub = client.notificationHub.subscribe(
  (event) => handleEvent(event),
  employeeId: 'emp-001',       // 可选：只接收该会话的事件
  fromDeviceId: 'dev-001',     // 可选：只接收该设备的事件
);

// 方式二：便捷订阅 — 只监听新消息
final msgSub = client.notificationHub.subscribeMessages(
  (event) => print('新消息: ${event.message.content}'),
  employeeId: 'emp-001',
);

// 方式三：便捷订阅 — 只监听未读计数变化
final unreadSub = client.notificationHub.subscribeUnreadCount(
  (event) => print('未读: ${event.unreadCount}'),
  employeeId: 'emp-001',
);

// 取消订阅
sub.cancel();
msgSub.cancel();
```

### 5.2 事件类型速查

| 事件类 | 触发时机 | 关键字段 |
|--------|----------|----------|
| `AgentMessageArrivedEvent` | 新消息到达（本地/远程） | `message`, `employeeId`, `isRemote` |
| `AgentUnreadCountChangedEvent` | 未读数变化 | `employeeId`, `unreadCount` |
| `AgentLatestMessageUpdatedEvent` | 会话最新消息更新 | `latestMessage`, `unreadCount` |
| `AgentLatestMessageClearedEvent` | 会话消息被清空 | `employeeId` |
| `AgentStatusNotifyEvent` | Agent 状态变更 | `status` (idle/processing/streaming/retrying/waitingPermission) |
| `AgentPermissionPendingEvent` | 权限请求待处理 | `permissionJson` |
| `AgentPermissionResolvedEvent` | 权限请求已处理 | `requestId` |
| `AgentConfirmPendingEvent` | 确认请求待处理 | `confirmJson` |
| `AgentConfirmResolvedEvent` | 确认请求已处理 | `requestId` |
| `AgentMessageReadStatusChangedEvent` | 消息已读状态变更 | `messageId`, `isRead` |

### 5.3 Dart 3 模式匹配示例

```dart
void handleEvent(AgentNotificationEvent event) {
  switch (event) {
    case AgentMessageArrivedEvent(:final message, :final employeeId, :final isRemote):
      // 新消息到达 → 刷新聊天窗口
      _addMessageToChat(employeeId, message);

    case AgentUnreadCountChangedEvent(:final employeeId, :final unreadCount):
      // 未读变更 → 更新会话列表红点
      _updateUnreadBadge(employeeId, unreadCount);

    case AgentLatestMessageUpdatedEvent(:final employeeId, :final latestMessage, :final unreadCount):
      // 最新消息更新 → 刷新会话列表预览
      _updateSessionPreview(employeeId, latestMessage, unreadCount);

    case AgentStatusNotifyEvent(:final employeeId, :final status):
      // Agent 状态变更 → 更新 UI 状态指示器
      _updateAgentStatus(employeeId, status);

    case AgentPermissionPendingEvent(:final employeeId, :final permissionJson):
      // 权限请求 → 弹出权限确认对话框
      _showPermissionDialog(employeeId, permissionJson);

    case AgentConfirmPendingEvent(:final employeeId, :final confirmJson):
      // 确认请求 → 弹出确认对话框
      _showConfirmDialog(employeeId, confirmJson);

    case AgentLatestMessageClearedEvent(:final employeeId):
      // 会话清空 → 清除预览
      _clearSessionPreview(employeeId);

    case AgentPermissionResolvedEvent(:final requestId):
      // 权限已处理 → 关闭对话框
      _dismissPermissionDialog(requestId);

    case AgentConfirmResolvedEvent(:final requestId):
      // 确认已处理 → 关闭对话框
      _dismissConfirmDialog(requestId);

    case AgentMessageReadStatusChangedEvent(:final messageId, :final isRead):
      // 已读状态变更 → 更新消息气泡样式
      _updateMessageReadStatus(messageId, isRead);
  }
}
```

---

## 6. 设备级 API

`DeviceClient` 提供设备级别的全局操作。

### 6.1 连接管理

```dart
// 连接
await client.connect();

// 重连（可指定新地址）
await client.reconnect(newHost: '192.168.1.200', newPort: 9091);

// 断开
await client.disconnect();

// 连接状态
final isConnected = client.isConnected; // bool
final state = client.connectionState;   // DeviceConnectionState 枚举
```

### 6.2 员工管理

```dart
// ── 员工在线检测 ──
final isOnline = await client.pingEmployee('emp-001');
final cachedOnline = client.isEmployeeOnline('emp-001');

// ── 删除员工（软删除 + 广播同步）──
await client.deleteEmployee('emp-001');

// ── 员工数据同步 ──
await client.syncEmployeesFromDevices();            // 同步所有员工
await client.syncAllFromDevices();                   // 同步全部数据
final emp = await client.syncEmployeeFromDevice(     // 同步单个员工
  employeeId: 'emp-001',
);
await client.broadcastEmployeeToAllDevices('emp-001'); // 广播员工到所有设备
await client.syncEmployeeToDevice(                   // 同步到指定设备
  employeeId: 'emp-001',
  targetDeviceId: 'dev-002',
);
```

### 6.3 会话管理

```dart
// ── 删除会话（软删除 + 广播同步）──
await client.deleteSession('emp-001');

// ── 会话数据同步 ──
await client.syncSessionsFromDevices();
await client.broadcastSessionToAllDevices('emp-001');

// ── 当前打开的会话 ──
await client.setCurrentOpenSession(employeeId: 'emp-001');
client.clearCurrentOpenSession();
final isOpen = client.isSessionOpen(employeeId: 'emp-001');
```

### 6.4 设备管理

```dart
// ── 获取在线设备列表 ──
final devices = await client.getOnlineDevices();
for (final d in devices) {
  print('设备: ${d.deviceId} 名称: ${d.deviceName}');
}

// ── 获取设备及其绑定的员工 ──
final devicesWithEmps = await client.getOnlineDevicesWithEmployees();
for (final d in devicesWithEmps) {
  print('设备: ${d.deviceName}, 员工数: ${d.employees.length}');
}

// ── 刷新设备列表 ──
await client.refreshDeviceList();
```

### 6.5 设备配置

```dart
// ── 获取配置 ──
final config = await client.getDeviceConfig();
print('环境变量: ${config.environmentVariables}');

// ── 更新设备信息 ──
await client.updateDeviceInfo(DeviceInfoConfig(
  name: '我的电脑',
  type: 'desktop',
  os: 'Windows 11',
));

// ── 环境变量操作 ──
await client.setEnvironmentVariable('API_KEY', 'sk-xxx');
await client.deleteEnvironmentVariable('API_KEY');
await client.updateEnvironmentVariables({'KEY1': 'v1', 'KEY2': 'v2'});
```

### 6.6 文件传输

```dart
// 上传文件
final fileId = await client.uploadFile('/path/to/file', onProgress: (p) {
  print('上传进度: ${(p * 100).toStringAsFixed(1)}%');
});

// 下载文件
await client.downloadFile(fileId, '/save/to/path', onProgress: (p) {
  print('下载进度: ${(p * 100).toStringAsFixed(1)}%');
});
```

---

## 7. Todo 数据同步

Todo 采用 **Topic（主题）+ TaskItem（子项）** 双层结构，支持跨设备同步。

### 7.1 通过 CachedAgentProxy 操作

```dart
final proxy = client.getAgentProxy('emp-001')!;

// ── Topic 操作 ──

// 更新主题内容
await proxy.updateTopicContent('topic-001', title: '新标题', description: '新描述');

// 更新主题状态
await proxy.updateTopicStatus('topic-001', 'in_progress'); // pending | in_progress | completed

// 删除主题（软删除）
await proxy.deleteTopic('topic-001');

// 重新排序主题
await proxy.reorderTopics(['topic-3', 'topic-1', 'topic-2']);

// 清除所有已完成主题
await proxy.clearCompletedTopics();

// ── TaskItem 操作 ──

// 更新子项状态
await proxy.updateTaskItemStatus('task-001', 'completed'); // pending | in_progress | completed

// 更新子项内容
await proxy.updateTaskItemContent('task-001', title: '新标题', content: '新内容');

// 删除子项（软删除）
await proxy.deleteTaskItem('task-001');

// 重新排序子项
await proxy.reorderTaskItems(['task-2', 'task-1']);
```

### 7.2 Todo 事件监听

```dart
// 通过 AgentEventType 监听（在 AgentProxy 的事件流中）
proxy.eventStream.listen((event) {
  switch (event.type) {
    case AgentEventType.todoTopicChanged:
      // 主题变更 → 刷新 Todo 列表
      _refreshTodoTopics();
    case AgentEventType.todoTaskItemChanged:
      // 子项变更 → 刷新子项列表
      _refreshTaskItems();
    default:
      break;
  }
});
```

### 7.3 Todo 数据模型

```
TodoTopicEntity
├── id: String (UUID)
├── employeeId: String
├── title: String
├── description: String
├── status: String ('pending' | 'in_progress' | 'completed')
├── sortOrder: int
├── deleted: int (0 | 1, 软删除标记)
├── completedAt: DateTime?
├── createTime: DateTime
└── updateTime: DateTime

TodoTaskItemEntity
├── id: String (UUID)
├── employeeId: String
├── topicId: String (关联的 Topic ID)
├── title: String
├── content: String
├── status: String ('pending' | 'in_progress' | 'completed')
├── sortOrder: int
├── deleted: int (0 | 1)
├── completedAt: DateTime?
├── createTime: DateTime
└── updateTime: DateTime
```

### 7.4 状态推导规则

Topic 的 `status` 由子项状态自动推导（`recalculateTopicStatus`）：

| 子项状态 | 推导的 Topic 状态 |
|----------|-------------------|
| 无子项 | `pending` |
| 有任一 `in_progress` | `in_progress` |
| 全部 `completed` | `completed` |
| 其他（如混合 pending + completed）| `pending` |

---

## 8. Spec 数据同步

Spec（规格说明）采用扁平结构，支持跨设备同步。

### 8.1 通过 CachedAgentProxy 操作

```dart
final proxy = client.getAgentProxy('emp-001')!;

// 更新 Spec 状态
await proxy.updateSpecStatus('spec-001', 'in_progress');
// 状态值: 'draft' | 'pending' | 'in_progress' | 'completed'

// 更新 Spec 内容（可只传 title 或 content）
await proxy.updateSpecContent('spec-001', '新内容');

// 删除 Spec（软删除）
await proxy.deleteSpec('spec-001');

// 清除所有已完成 Spec
await proxy.clearCompletedSpecs();

// 重新排序
await proxy.reorderSpecs(['spec-3', 'spec-1', 'spec-2']);
```

### 8.2 Spec 事件监听

```dart
proxy.eventStream.listen((event) {
  if (event.type == AgentEventType.specChanged) {
    // Spec 变更 → 刷新 Spec 列表
    _refreshSpecs();
  }
});
```

### 8.3 Spec 数据模型

```
SpecItemEntity
├── id: String (UUID)
├── employeeId: String
├── title: String
├── content: String
├── status: String ('draft' | 'pending' | 'in_progress' | 'completed')
├── priority: String ('low' | 'medium' | 'high')
├── tags: String (逗号分隔)
├── sortOrder: int
├── deleted: int (0 | 1)
├── createTime: DateTime
└── updateTime: DateTime
```

---

## 9. 会话摘要与未读计数

### 9.1 查询会话摘要

```dart
// ── 获取所有会话摘要（用于会话列表）──
final summaries = client.getSessionSummaries();
for (final s in summaries) {
  print('会话: ${s.employeeId}, 最新消息: ${s.latestMessageContent}, '
        '未读: ${s.unreadCount}, 状态: ${s.agentStatus}');
}

// ── 获取单个会话摘要 ──
final summary = client.getSessionSummary(employeeId: 'emp-001');

// ── 获取有未读消息的会话 ──
final unreadSessions = client.getUnreadSessions();

// ── 获取有 pending 请求的会话 ──
final pendingSessions = client.getPendingSessions();
```

### 9.2 未读计数操作

```dart
// ── 查询 ──
final count = client.getUnreadCount(employeeId: 'emp-001');
final total = client.getTotalUnreadCount(); // 所有会话总未读

// ── 标记已读 ──
client.markAllMessagesAsRead(employeeId: 'emp-001');     // 标记某会话全部已读
client.markAllMessagesAsReadGlobal();                    // 全部已读

// ── 同步已读状态 ──
await client.syncReadStatusFromAgent(employeeId: 'emp-001');
```

### 9.3 SessionSummaryEntity 关键字段

```
SessionSummaryEntity
├── employeeId: String
├── deviceId: String
├── latestMessageContent: String?     // 最新消息预览文本
├── latestMessageTime: DateTime?      // 最新消息时间
├── unreadCount: int                  // 未读数
├── agentStatus: String               // Agent 当前状态
├── hasPendingPermission: bool        // 是否有 pending 权限请求
├── hasPendingConfirm: bool           // 是否有 pending 确认请求
├── pendingPermissionJson: String?    // 权限请求 JSON
├── pendingConfirmJson: String?       // 确认请求 JSON
└── updateTime: DateTime
```

---

## 10. 事件类型速查表

`AgentEventType` 枚举值（用于 `AgentEvent.type`）：

| 枚举值 | 说明 | 前端处理建议 |
|--------|------|-------------|
| `agentStatusChanged` | Agent 状态变更 | 更新状态指示器 |
| `messageStatusChanged` | 消息状态变更（queued/processing/retrying/streaming/completed/failed/interrupted/revoked） | 更新消息气泡 |
| `messageReadStatusChanged` | 消息已读状态变更 | 更新已读/未读样式 |
| `toolCallStart` | 工具调用开始 | 显示工具调用进度 |
| `toolCallResult` | 工具调用结果 | 显示工具结果 |
| `toolPermissionRequest` | 权限请求 | 弹出权限对话框 |
| `toolPermissionResponse` | 权限响应 | 关闭权限对话框 |
| `confirmRequest` | 确认请求 | 弹出确认对话框 |
| `confirmResponse` | 确认响应 | 关闭确认对话框 |
| `messageStarted` | 消息开始处理 | 显示 loading |
| `streamDelta` | 流式文本增量 | 追加到消息气泡 |
| `thinkingDelta` | 思考内容增量 | 显示思考过程 |
| `sessionCleared` | 会话被清空 | 清空聊天记录 |
| `sessionSummaryChanged` | 会话摘要变更 | 刷新会话列表 |
| `todoTopicChanged` | Todo 主题变更 | 刷新 Todo 面板 |
| `todoTaskItemChanged` | Todo 子项变更 | 刷新子项列表 |
| `specChanged` | Spec 变更 | 刷新 Spec 面板 |
| `configChanged` | 配置变更 | 重新加载配置 |

---

## 11. 状态枚举速查表

### AgentStatus

```dart
enum AgentStatus {
  idle,              // 空闲
  processing,        // 处理中
  streaming,         // 流式输出中
  retrying,          // LLM 调用失败，正在重试
  waitingPermission, // 等待权限确认
}
```

### DeviceConnectionState

```dart
enum DeviceConnectionState {
  disconnected,  // 已断开
  connecting,    // 连接中
  connected,     // 已连接
  reconnecting,  // 重连中
}
```

### CacheState（CachedAgentProxy 远程模式）

```dart
enum CacheState {
  idle,       // 空闲
  syncing,    // 同步中
  synced,     // 已同步
  error,      // 同步失败
}
```

### Todo/Spec 状态值

| 数据类型 | 状态值 |
|---------|--------|
| Todo Topic | `pending` → `in_progress` → `completed` |
| Todo TaskItem | `pending` → `in_progress` → `completed` |
| Spec | `draft` → `pending` → `in_progress` → `completed` |

---

## 12. 前端集成模式推荐

### 12.1 Flutter 状态管理集成

推荐使用 `StreamBuilder` 或 Riverpod 的 `StreamNotifier` 监听事件流：

```dart
// 方式一：StreamBuilder
StreamBuilder<AgentNotificationEvent>(
  stream: client.notificationHub.stream(employeeId: empId),
  builder: (context, snapshot) {
    if (!snapshot.hasData) return const SizedBox.shrink();
    final event = snapshot.data!;
    if (event is AgentMessageArrivedEvent) {
      return MessageBubble(message: event.message);
    }
    return const SizedBox.shrink();
  },
)

// 方式二：在 initState 中订阅
class _ChatWindowState extends State<ChatWindow> {
  AgentNotificationSubscription? _sub;
  final List<AgentMessage> _messages = [];

  @override
  void initState() {
    super.initState();
    _sub = client.notificationHub.subscribeMessages(
      (event) => setState(() => _messages.add(event.message)),
      employeeId: widget.employeeId,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
```

### 12.2 会话列表页面

```dart
class SessionListPage extends StatefulWidget { ... }

class _SessionListPageState extends State<SessionListPage> {
  List<SessionSummaryEntity> _summaries = [];
  AgentNotificationSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _loadSummaries();
    // 监听摘要变更 → 自动刷新列表
    _sub = client.notificationHub.subscribe(
      (event) {
        if (event is AgentLatestMessageUpdatedEvent ||
            event is AgentUnreadCountChangedEvent ||
            event is AgentSessionSummaryChangedEvent) {
          _loadSummaries();
        }
      },
    );
  }

  void _loadSummaries() {
    setState(() {
      _summaries = client.getSessionSummaries();
      // 按 updateTime 降序排列
      _summaries.sort((a, b) =>
          (b.updateTime).compareTo(a.updateTime));
    });
  }
}
```

### 12.3 聊天窗口页面

```dart
class ChatWindowPage extends StatefulWidget {
  final String employeeId;
  const ChatWindowPage({required this.employeeId});
}

class _ChatWindowPageState extends State<ChatWindowPage> {
  CachedAgentProxy? _proxy;
  final List<AgentMessage> _messages = [];

  @override
  void initState() {
    super.initState();
    _initProxy();
  }

  Future<void> _initProxy() async {
    _proxy = await client.getOrCreateAgentProxy(
      employeeId: widget.employeeId,
    );
    await _proxy!.initialize();
    await _proxy!.syncFromRemote();

    // 标记当前会话已打开
    await client.setCurrentOpenSession(employeeId: widget.employeeId);
    // 标记全部已读
    _proxy!.markMessagesAsRead();

    // 加载历史消息
    final msgs = await _proxy!.getMessages();
    setState(() => _messages.addAll(msgs));
  }

  Future<void> _sendMessage(String text) async {
    await _proxy?.sendMessage(MessageInput(
      role: 'user',
      type: 'text',
      content: text,
    ));
  }
}
```

### 12.4 Todo 面板页面

```dart
class TodoPanel extends StatefulWidget {
  final CachedAgentProxy proxy;
  const TodoPanel({required this.proxy});
}

class _TodoPanelState extends State<TodoPanel> {
  StreamSubscription<AgentEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    _eventSub = widget.proxy.eventStream.listen((event) {
      if (event.type == AgentEventType.todoTopicChanged ||
          event.type == AgentEventType.todoTaskItemChanged) {
        setState(() {}); // 触发重建
      }
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }
}
```

---

## 13. 常见问题

### Q1: 初始化时报 `DeviceClient 未初始化` 错误

**原因：** 未调用 `initialize()` 或调用顺序错误。

**解决：** 确保 `initialize()` 在 `connect()` 之前调用，且 `await` 完成。

```dart
await client.initialize(config);  // 必须先初始化
await client.connect();            // 再连接
```

### Q2: 远程 Agent 消息收不到

**排查步骤：**
1. 检查 `client.isConnected` 是否为 `true`
2. 检查 `proxy.isLocalMode` 是否为 `false`（远程模式）
3. 确认已调用 `proxy.initialize()` 和 `proxy.syncFromRemote()`
4. 检查 `notificationHub.subscribe` 是否正确设置了 `employeeId` 过滤

### Q3: 会话列表未读数不准确

**解决：** App 启动时调用恢复方法：

```dart
await client.restoreUnreadStatus();
await client.syncSessionSummariesFromDevices();
```

### Q4: 跨设备数据不同步

**排查步骤：**
1. 确认两台设备连接到同一个 LAN 服务器
2. 检查 `client.getOnlineDevices()` 是否能看到对端设备
3. 手动触发同步：`await client.syncAllFromDevices()`

### Q5: CachedAgentProxy 的同步查询 vs 异步查询怎么选？

| 场景 | 推荐 | 原因 |
|------|------|------|
| UI 实时展示 | 同步（`proxy.status`） | 零延迟，读本地缓存 |
| 首次加载/定时刷新 | 异步（`await proxy.getStateSnapshotAsync()`） | 获取远程最新数据 |
| 事件驱动更新 | 事件流（`notificationHub`） | 被动推送，最实时 |

### Q6: Todo/Spec 操作后 UI 没更新？

**原因：** Todo/Spec 变更通过 `AgentEventType.todoTopicChanged` / `specChanged` 事件通知，不是通过 `AgentNotificationHub`。

**解决：** 监听 `proxy.eventStream`：

```dart
proxy.eventStream.listen((event) {
  if (event.type == AgentEventType.todoTopicChanged) {
    _refreshTodoUI();
  }
});
```

---

## 附录：import 路径

```dart
// 核心入口
import 'package:wenzagent/wenzagent.dart';

// 常用类型（通常通过 wenzagent.dart 导出）
import 'package:wenzagent/src/device/device_client.dart';
import 'package:wenzagent/src/agent/client/cached_agent_proxy.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_hub.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_event.dart';
import 'package:wenzagent/src/agent/entity/agent_event.dart';
import 'package:wenzagent/src/agent/entity/agent_message.dart';
import 'package:wenzagent/src/agent/entity/message_input.dart';
import 'package:wenzagent/src/persistence/entities/todo_topic_entity.dart';
import 'package:wenzagent/src/persistence/entities/todo_task_item_entity.dart';
import 'package:wenzagent/src/persistence/entities/spec_item_entity.dart';
import 'package:wenzagent/src/persistence/entities/session_summary_entity.dart';
```
