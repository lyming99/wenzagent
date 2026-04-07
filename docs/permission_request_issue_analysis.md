# 权限请求消息卡片不显示问题分析

## 问题描述

在远程模式下，当 Agent 需要权限确认时，客户端没有显示权限请求消息卡片，而本地模式正常。

## 问题根源

### 1. AgentProxy 的同步方法不支持远程模式

在 `agent_proxy.dart` 第213-218行，`getPendingPermissionRequest()` 方法在远程模式下直接返回 `null`：

```dart
AgentPermissionRequest? getPendingPermissionRequest() {
  if (isLocalMode && _localAgent != null) {
    return _localAgent.getPendingPermissionRequest();
  }
  return null;  // ❌ 远程模式下直接返回null
}
```

虽然提供了异步版本 `getPendingPermissionRequestAsync()` 支持远程 RPC 调用，但客户端代码使用的是同步版本。

### 2. CachedAgentProxy 未处理权限请求事件

**这是核心问题！**

#### 权限请求事件的产生（agent_impl.dart 第130-135行）

当 Agent 需要权限时，会广播 `toolPermissionRequest` 事件：

```dart
// 广播权限请求事件
_eventController.add({
  'type': 'toolPermissionRequest',
  'data': request.toMap(),
  'employeeId': employeeId,
});
```

#### 事件的传递路径

**本地模式：**
```
AgentImpl._eventController 
  → AgentProxy._eventController (本地Agent直接调用)
    → CachedAgentProxy._proxy.onEvent
      → CachedAgentProxy._handleAgentEvent
```

**远程模式：**
```
AgentImpl._eventController 
  → 网络传输 
    → AgentProxy._onRemoteEvent 
      → AgentProxy._eventController.add(eventData)
        → CachedAgentProxy._proxy.onEvent
          → CachedAgentProxy._handleAgentEvent
```

#### CachedAgentProxy 的事件处理缺失

在 `cached_agent_proxy.dart` 第249-284行，`_handleAgentEvent` 方法处理了多种事件：

```dart
void _handleAgentEvent(Map<String, dynamic> event) {
  final type = event['type'] as String?;
  
  switch (type) {
    case 'messageStatusChanged':
      _handleMessageStatusChanged(data);
      break;
    case 'agentStatusChanged':
      _handleAgentStatusChanged(data);
      break;
    case 'toolCallStart':
    case 'toolCallResult':
      _handleToolEvent(type, data);
      break;
    case 'messageReplied':
      _handleMessageReplied(data);
      break;
    case 'messageQueued':
      _handleMessageQueued(data);
      break;
    case 'messageProcessing':
      _handleMessageProcessing(data);
      break;
  }
}
```

**缺少 `toolPermissionRequest` 事件的处理！**

### 3. 客户端代码的依赖

客户端代码（controller.dart 第479-515行）在加载消息时检查权限请求：

```dart
final agentState = _agentProxy!.getStateSnapshot();
if (agentState.status == agent.AgentStatus.waitingPermission) {
  final pendingPermission = _agentProxy!.getPendingPermissionRequest();
  if (pendingPermission != null) {
    // 将权限请求转换为 ChatMessage
    final permissionMessage = ChatMessage.permissionRequest(...);
    _messages.add(permissionMessage);
  }
}
```

由于远程模式下 `getPendingPermissionRequest()` 返回 `null`，导致无法显示权限请求卡片。

## 问题流程图

```
┌─────────────────────────────────────────────────────────────┐
│                    远程 Agent 执行工具                        │
│                  (需要权限，如文件操作)                        │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  AgentImpl._permissionManager.onPermissionRequest 触发      │
│  1. 保存权限请求到 _pendingPermissionRequests               │
│  2. 设置状态为 waitingPermission                            │
│  3. 广播事件: type='toolPermissionRequest'                  │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  事件通过网络传输到客户端                                     │
│  type: 'toolPermissionRequest'                              │
│  data: { requestId, description, functionName, ... }        │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  AgentProxy._onRemoteEvent 接收事件                          │
│  ✅ 广播到 _eventController                                  │
│  ✅ 更新状态为 waitingPermission (通过状态快照)               │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  CachedAgentProxy._handleAgentEvent 处理事件                 │
│  ❌ 没有 case 'toolPermissionRequest' 分支                   │
│  ❌ 权限请求信息丢失                                          │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  客户端 ChatViewController._loadMessages                    │
│  1. 检查状态: status == waitingPermission ✅                 │
│  2. 获取权限请求: getPendingPermissionRequest()              │
│     ❌ 远程模式返回 null                                     │
│  3. 无法创建权限请求消息卡片                                 │
└─────────────────────────────────────────────────────────────┘
```

## 解决方案

### 方案1：在 CachedAgentProxy 中缓存权限请求（推荐）

在 `CachedAgentProxy` 中添加权限请求缓存和处理逻辑：

```dart
class CachedAgentProxy {
  // 添加权限请求缓存
  final Map<String, AgentPermissionRequest> _pendingPermissionRequests = {};
  
  void _handleAgentEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    
    switch (type) {
      // ... 其他事件处理 ...
      
      case 'toolPermissionRequest':  // ✅ 新增
        _handlePermissionRequest(data);
        break;
    }
  }
  
  void _handlePermissionRequest(Map<String, dynamic> data) {
    final request = AgentPermissionRequest.fromMap(data);
    _pendingPermissionRequests[request.requestId] = request;
    print('[CachedAgentProxy] 收到权限请求: ${request.requestId}');
    
    // 通知客户端重新加载消息
    _notifyMessagesChanged();
  }
  
  // 修改 getPendingPermissionRequest 方法
  AgentPermissionRequest? getPendingPermissionRequest() {
    // 远程模式：从缓存中获取
    if (_needCache && _pendingPermissionRequests.isNotEmpty) {
      return _pendingPermissionRequests.values.first;
    }
    // 本地模式：透传
    return _proxy.getPendingPermissionRequest();
  }
  
  // 在响应权限后清除缓存
  Future<void> respondToPermission(String requestId, PermissionDecision decision) async {
    await _proxy.respondToPermission(requestId, decision);
    
    // 清除缓存
    _pendingPermissionRequests.remove(requestId);
  }
}
```

### 方案2：在 AgentProxy 中实现同步缓存

在 `AgentProxy` 中缓存权限请求，支持同步访问：

```dart
class AgentProxy {
  // 远程权限请求缓存
  AgentPermissionRequest? _cachedPermissionRequest;
  
  void _onRemoteEvent(Map<String, dynamic> eventData) {
    final type = eventData['type'] as String?;
    
    switch (type) {
      case 'toolPermissionRequest':
        final data = eventData['data'] as Map<String, dynamic>? ?? {};
        _cachedPermissionRequest = AgentPermissionRequest.fromMap(data);
        _eventController.add(eventData);
        break;
        
      case 'toolPermissionResponse':
        _cachedPermissionRequest = null;
        break;
    }
  }
  
  AgentPermissionRequest? getPendingPermissionRequest() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getPendingPermissionRequest();
    }
    return _cachedPermissionRequest;
  }
}
```

### 方案3：修改客户端使用异步方法

客户端监听权限请求事件，使用异步方法获取：

```dart
// 监听 Agent 事件
_deviceEventSubscription = deviceClient.onAgentEvent.listen((event) {
  final type = event['type'] as String?;
  
  if (type == 'toolPermissionRequest') {
    // 权限请求事件，重新加载消息
    _loadMessages().then((_) => updateView());
  }
});

// 在 _loadMessages 中使用异步方法
Future<void> _loadMessages() async {
  // ...
  
  if (agentState.status == agent.AgentStatus.waitingPermission) {
    final pendingPermission = await _agentProxy!.getPendingPermissionRequestAsync();
    if (pendingPermission != null) {
      // ...
    }
  }
}
```

## 推荐方案

**推荐使用方案1**，原因：

1. ✅ 保持同步 API，客户端代码无需修改
2. ✅ 统一在缓存层处理，符合 CachedAgentProxy 的设计理念
3. ✅ 减少不必要的 RPC 调用，性能更好
4. ✅ 支持离线查看权限请求历史（如果需要）

## 本地模式 vs 远程模式对比

| 特性 | 本地模式 | 远程模式 |
|------|---------|---------|
| Agent 状态 | ✅ 实时同步 | ✅ 通过事件流同步 |
| 权限请求事件 | ✅ 广播到客户端 | ✅ 广播到客户端 |
| 权限请求缓存 | ✅ 存储在 AgentImpl | ❌ 未缓存（问题所在） |
| getPendingPermissionRequest() | ✅ 返回权限请求 | ❌ 返回 null |
| 权限请求卡片显示 | ✅ 正常显示 | ❌ 不显示 |

## 测试验证

修复后需要测试：

1. ✅ 本地模式：权限请求正常显示
2. ✅ 远程模式：权限请求正常显示
3. ✅ 权限请求完成后，卡片更新状态
4. ✅ 用户拒绝权限，卡片显示拒绝状态
5. ✅ 用户允许权限，卡片显示允许状态
6. ✅ 多个权限请求排队时，正确显示

## 已实施的修改

已按照**方案1**完成修改，具体变更如下：

### 1. 添加权限请求缓存字段（第62-64行）

```dart
/// 权限请求缓存（远程模式使用）
final Map<String, AgentPermissionRequest> _pendingPermissionRequests = {};
```

### 2. 处理权限请求事件（第268-270行）

在 `_handleAgentEvent` 方法中添加事件处理：

```dart
case 'toolPermissionRequest':
  _handlePermissionRequest(data);
  break;
```

### 3. 实现权限请求处理方法（第330-342行）

```dart
/// 处理权限请求事件
void _handlePermissionRequest(Map<String, dynamic> data) {
  try {
    final request = AgentPermissionRequest.fromMap(data);
    _pendingPermissionRequests[request.requestId] = request;
    print('[CachedAgentProxy] 收到权限请求: ${request.requestId}, 函数: ${request.functionName}');
    
    // 通知客户端重新加载消息
    _notifyMessagesChanged();
  } catch (e) {
    print('[CachedAgentProxy] 处理权限请求失败: $e');
  }
}
```

### 4. 修改 getPendingPermissionRequest() 方法（第882-890行）

```dart
/// 获取当前权限请求
AgentPermissionRequest? getPendingPermissionRequest() {
  // 远程模式：从缓存中获取
  if (_needCache && _pendingPermissionRequests.isNotEmpty) {
    return _pendingPermissionRequests.values.first;
  }
  // 本地模式：透传
  return _proxy.getPendingPermissionRequest();
}
```

### 5. 修改 respondToPermission() 方法（第937-943行）

```dart
/// 响应权限请求
Future<void> respondToPermission(String requestId, PermissionDecision decision) async {
  await _proxy.respondToPermission(requestId, decision);
  
  // 清除缓存的权限请求
  _pendingPermissionRequests.remove(requestId);
  print('[CachedAgentProxy] 已响应权限请求并清除缓存: $requestId');
}
```

### 6. 清理缓存（第891-903行，第1009-1021行）

在 `clearCurrentSession()` 和 `dispose()` 方法中清除权限请求缓存：

```dart
_pendingPermissionRequests.clear();
```

## 测试结果

✅ 所有单元测试通过（test/permission_request_test.dart）

测试覆盖：
- ✅ 权限请求的创建和序列化
- ✅ 权限请求缓存Map操作
- ✅ 权限决策枚举
- ✅ AgentStatus 包含 waitingPermission 状态

## 相关代码文件

- `lib/src/agent/impl/agent_impl.dart` - Agent 实现，产生权限请求事件
- `lib/src/agent/client/agent_proxy.dart` - AgentProxy，远程代理
- `lib/src/agent/client/cached_agent_proxy.dart` - CachedAgentProxy，缓存层
- `wenzflow_flutter/lib/view/mobile/ai/chat/controller.dart` - 客户端控制器
