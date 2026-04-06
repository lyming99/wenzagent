# getPendingPermissionRequest() 方法使用指南

## 方法签名

### 同步版本（仅本地模式）

```dart
AgentPermissionRequest? getPendingPermissionRequest()
```

**适用场景**：
- ✅ 本地模式 (`isLocalMode = true`)
- ❌ 远程模式（返回 `null`）

### 异步版本（支持本地和远程）

```dart
Future<AgentPermissionRequest?> getPendingPermissionRequestAsync()
```

**适用场景**：
- ✅ 本地模式
- ✅ 远程模式（通过 RPC 调用）

## 返回值类型

### AgentPermissionRequest

```dart
class AgentPermissionRequest {
  /// 请求ID
  final String requestId;
  
  /// 权限类型
  final String type;
  
  /// 请求描述
  final String description;
  
  /// 函数名称
  final String functionName;
  
  /// 权限模式（可选）
  final String? permissionPattern;
  
  /// 权限类型分类（可选）
  final String? permissionType;
  
  /// 附加数据（可选）
  final Map<String, dynamic>? data;
}
```

## 使用示例

### 1. 本地模式查询

```dart
// 创建本地 AgentProxy
final agentProxy = AgentProxy.local(
  employeeId: 'employee-123',
  deviceId: 'device-456',
  localAgent: localAgent,
);

// 同步查询（推荐用于本地模式）
final pendingRequest = agentProxy.getPendingPermissionRequest();
if (pendingRequest != null) {
  print('有待处理的权限请求:');
  print('  请求ID: ${pendingRequest.requestId}');
  print('  权限类型: ${pendingRequest.type}');
  print('  函数名称: ${pendingRequest.functionName}');
  print('  描述: ${pendingRequest.description}');
} else {
  print('当前没有待处理的权限请求');
}
```

### 2. 远程模式查询

```dart
// 创建远程 AgentProxy
final agentProxy = AgentProxy.remote(
  employeeId: 'employee-123',
  deviceId: 'device-456',
  rpcCall: (method, params) async {
    // 实现远程调用逻辑
    return await someRemoteCall(method, params);
  },
  remoteEventStream: eventStream,
);

// 异步查询（必须用于远程模式）
final pendingRequest = await agentProxy.getPendingPermissionRequestAsync();
if (pendingRequest != null) {
  print('远程 Agent 有待处理的权限请求:');
  print('  请求ID: ${pendingRequest.requestId}');
  print('  权限类型: ${pendingRequest.type}');
  print('  函数名称: ${pendingRequest.functionName}');
} else {
  print('远程 Agent 没有待处理的权限请求');
}
```

### 3. 响应权限请求

```dart
// 获取待处理权限请求
final request = await agentProxy.getPendingPermissionRequestAsync();
if (request != null) {
  // 用户决定是否授权
  final decision = PermissionDecision.allow; // 或 deny, allowAlways
  
  // 响应权限请求
  await agentProxy.respondToPermission(
    request.requestId,
    decision,
  );
}
```

## 常见使用场景

### 场景1：定期检查权限请求

```dart
Timer.periodic(Duration(seconds: 1), (timer) async {
  final request = await agentProxy.getPendingPermissionRequestAsync();
  if (request != null) {
    // 显示权限请求对话框
    showPermissionDialog(request);
  }
});
```

### 场景2：状态监听时检查权限

```dart
agentProxy.onStateChanged.listen((snapshot) async {
  // 当 Agent 进入 waiting_for_permission 状态时
  if (snapshot.status == AgentStatus.waitingForPermission) {
    final request = await agentProxy.getPendingPermissionRequestAsync();
    if (request != null) {
      handlePermissionRequest(request);
    }
  }
});
```

### 场景3：UI 显示权限请求详情

```dart
Widget buildPermissionUI() {
  return FutureBuilder<AgentPermissionRequest?>(
    future: agentProxy.getPendingPermissionRequestAsync(),
    builder: (context, snapshot) {
      if (!snapshot.hasData || snapshot.data == null) {
        return Text('无待处理权限请求');
      }
      
      final request = snapshot.data!;
      return Card(
        child: Column(
          children: [
            Text('权限请求: ${request.type}'),
            Text('函数: ${request.functionName}'),
            Text('描述: ${request.description}'),
            Row(
              children: [
                ElevatedButton(
                  onPressed: () => respondAndRefresh(request.requestId, PermissionDecision.allow),
                  child: Text('允许'),
                ),
                ElevatedButton(
                  onPressed: () => respondAndRefresh(request.requestId, PermissionDecision.deny),
                  child: Text('拒绝'),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
```

## 注意事项

### ⚠️ 同步 vs 异步

- **本地模式**：可以使用同步或异步版本
  - 同步：`getPendingPermissionRequest()` - 性能更好
  - 异步：`getPendingPermissionRequestAsync()` - 统一接口
  
- **远程模式**：必须使用异步版本
  - 同步版本会直接返回 `null`
  - 异步版本通过 RPC 远程调用

### ⚠️ 关闭后状态

根据之前的测试结果，`dispose()` 后：
- 权限请求状态会被正确清理
- 不会再有新的权限请求
- 查询返回 `null`

### ⚠️ 空值检查

始终检查返回值是否为 `null`：

```dart
final request = await agentProxy.getPendingPermissionRequestAsync();
if (request == null) {
  // 无待处理权限请求
  return;
}
// 处理权限请求
```

## 完整示例

```dart
import 'package:wenzagent/agent.dart';

void main() async {
  // 创建 AgentProxy
  final agentProxy = AgentProxy.local(
    employeeId: 'emp-001',
    deviceId: 'dev-001',
    localAgent: createLocalAgent(),
  );
  
  // 检查权限请求
  print('=== 检查权限请求 ===');
  final request = agentProxy.getPendingPermissionRequest();
  
  if (request != null) {
    print('发现待处理权限请求:');
    print('  ID: ${request.requestId}');
    print('  类型: ${request.type}');
    print('  函数: ${request.functionName}');
    print('  描述: ${request.description}');
    
    // 用户授权
    print('\n授权该请求...');
    await agentProxy.respondToPermission(
      request.requestId,
      PermissionDecision.allow,
    );
    print('已授权');
  } else {
    print('当前无待处理权限请求');
  }
  
  // 再次检查
  final recheck = agentProxy.getPendingPermissionRequest();
  print('\n再次检查: ${recheck == null ? "无权限请求" : "仍有权限请求"}');
  
  // 清理
  await agentProxy.dispose();
}
```

## 相关方法

- `respondToPermission(requestId, decision)` - 响应权限请求
- `onStateChanged` - 监听状态变化
- `status` - 获取当前状态

## 相关类型

- `PermissionDecision` 枚举:
  - `allow` - 允许
  - `deny` - 拒绝
  - `allowAlways` - 允许并记住
