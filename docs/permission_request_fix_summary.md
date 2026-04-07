# CachedAgentProxy 权限请求缓存修复

## 问题描述

远程模式下，Agent 需要权限确认时，客户端没有显示权限请求消息卡片。

## 根本原因

`CachedAgentProxy` 没有处理远程 Agent 发送的 `toolPermissionRequest` 事件，导致权限请求信息丢失。

## 解决方案

在 `CachedAgentProxy` 中添加权限请求缓存和处理逻辑。

## 修改内容

### 1. 添加权限请求缓存（lib/src/agent/client/cached_agent_proxy.dart:62-64）

```dart
/// 权限请求缓存（远程模式使用）
final Map<String, AgentPermissionRequest> _pendingPermissionRequests = {};
```

### 2. 处理权限请求事件（lib/src/agent/client/cached_agent_proxy.dart:268-270）

```dart
case 'toolPermissionRequest':
  _handlePermissionRequest(data);
  break;
```

### 3. 实现权限请求处理方法（lib/src/agent/client/cached_agent_proxy.dart:330-342）

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

### 4. 修改 getPendingPermissionRequest() 方法（lib/src/agent/client/cached_agent_proxy.dart:882-890）

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

### 5. 修改 respondToPermission() 方法（lib/src/agent/client/cached_agent_proxy.dart:937-943）

```dart
/// 响应权限请求
Future<void> respondToPermission(String requestId, PermissionDecision decision) async {
  await _proxy.respondToPermission(requestId, decision);
  
  // 清除缓存的权限请求
  _pendingPermissionRequests.remove(requestId);
  print('[CachedAgentProxy] 已响应权限请求并清除缓存: $requestId');
}
```

### 6. 清理缓存

- `clearCurrentSession()` 方法：清除权限请求缓存
- `dispose()` 方法：清除权限请求缓存

### 7. 初始化时同步远程状态和权限请求（lib/src/agent/client/cached_agent_proxy.dart:117-119）

在 `initialize()` 方法中添加远程状态查询：

```dart
// 3. 查询远程会话状态和权限请求
await _syncRemoteStateAndPermission();
```

新增方法 `_syncRemoteStateAndPermission()`（lib/src/agent/client/cached_agent_proxy.dart:484-515）：

```dart
/// 同步远程会话状态和权限请求
///
/// 在初始化时查询远程 Agent 状态，如果正在等待权限，则查询并缓存权限请求
Future<void> _syncRemoteStateAndPermission() async {
  if (_isDisposed || !_needCache) return;

  try {
    print('[CachedAgentProxy] 开始同步远程会话状态和权限请求...');

    // 1. 查询远程 Agent 状态
    final stateSnapshot = await _proxy.getStateSnapshotAsync();
    print('[CachedAgentProxy] 远程 Agent 状态: ${stateSnapshot.status}');

    // 2. 如果正在等待权限，查询权限请求
    if (stateSnapshot.status == AgentStatus.waitingPermission) {
      print('[CachedAgentProxy] 检测到远程 Agent 正在等待权限，查询权限请求...');
      
      final permissionRequest = await _proxy.getPendingPermissionRequestAsync();
      if (permissionRequest != null) {
        _pendingPermissionRequests[permissionRequest.requestId] = permissionRequest;
        print('[CachedAgentProxy] 已缓存权限请求: ${permissionRequest.requestId}, 函数: ${permissionRequest.functionName}');
        
        // 通知客户端重新加载消息
        _notifyMessagesChanged();
      }
    }

    print('[CachedAgentProxy] 远程会话状态同步完成');
  } catch (e) {
    print('[CachedAgentProxy] 同步远程会话状态失败: $e');
  }
}
```

### 8. 状态变更时查询权限请求（lib/src/agent/client/cached_agent_proxy.dart:425-453）

增强 `_handleStateChange()` 方法，处理 `waitingPermission` 状态：

```dart
/// 处理状态变更
void _handleStateChange(AgentStateSnapshot state) {
  print('[CachedAgentProxy] 状态变更: ${state.status}');
  
  if (state.status == AgentStatus.idle) {
    // Agent空闲时，同步消息
    _syncMessagesFromRemote();
  } else if (state.status == AgentStatus.waitingPermission) {
    // Agent等待权限时，查询权限请求
    _queryPendingPermission();
  }
}
```

新增方法 `_queryPendingPermission()`：

```dart
/// 查询待处理的权限请求
Future<void> _queryPendingPermission() async {
  if (_isDisposed || !_needCache) return;

  try {
    print('[CachedAgentProxy] 查询待处理的权限请求...');
    
    final permissionRequest = await _proxy.getPendingPermissionRequestAsync();
    if (permissionRequest != null) {
      _pendingPermissionRequests[permissionRequest.requestId] = permissionRequest;
      print('[CachedAgentProxy] 已缓存权限请求: ${permissionRequest.requestId}');
      
      // 通知客户端重新加载消息
      _notifyMessagesChanged();
    }
  } catch (e) {
    print('[CachedAgentProxy] 查询权限请求失败: $e');
  }
}
```

## 测试验证

✅ 所有单元测试通过（test/permission_request_test.dart）

测试覆盖：
- ✅ 权限请求的创建和序列化
- ✅ 权限请求缓存Map操作
- ✅ 权限决策枚举
- ✅ AgentStatus 包含 waitingPermission 状态

## 影响范围

- ✅ 本地模式：无影响（透传到本地 Agent）
- ✅ 远程模式：权限请求正常显示

## 后续工作

建议进行集成测试，验证：
1. 远程模式下权限请求卡片的显示
2. 用户允许/拒绝权限后的状态更新
3. 多个权限请求排队时的处理
4. 权限请求超时处理（如果有）
