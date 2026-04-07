# 权限请求使用示例

## 客户端使用方式

### 1. 初始化 AgentProxy

```dart
// 创建 CachedAgentProxy
final agentProxy = CachedAgentProxy(
  proxy: agentProxy,
  messageStore: messageStore,
  deviceId: deviceId,
  employeeId: employeeId,
);

// 初始化（会自动查询远程状态和权限请求）
await agentProxy.initialize();
```

### 2. 监听状态变更

```dart
// 监听 Agent 状态变更
agentProxy.onStateChanged.listen((state) {
  print('Agent 状态: ${state.status}');
  
  if (state.status == AgentStatus.waitingPermission) {
    // Agent 正在等待权限，重新加载消息以显示权限请求卡片
    _loadMessages();
  }
});
```

### 3. 加载消息并检查权限请求

```dart
Future<void> _loadMessages() async {
  // 获取消息
  final messages = await agentProxy.getSessionMessages();
  
  // 检查是否有待处理的权限请求
  final state = agentProxy.getStateSnapshot();
  if (state.status == AgentStatus.waitingPermission) {
    final permissionRequest = agentProxy.getPendingPermissionRequest();
    if (permissionRequest != null) {
      // 将权限请求转换为 UI 消息卡片
      final permissionMessage = ChatMessage.permissionRequest(
        requestId: permissionRequest.requestId,
        description: permissionRequest.description,
        functionName: permissionRequest.functionName,
        permissionPattern: permissionRequest.permissionPattern,
        permissionType: permissionRequest.permissionType,
        args: permissionRequest.data,
      );
      
      // 添加到消息列表
      messages.add(permissionMessage);
    }
  }
  
  // 更新 UI
  setState(() {
    _messages = messages;
  });
}
```

### 4. 用户响应权限请求

```dart
void handlePermissionDecision(String requestId, PermissionDecision decision) async {
  try {
    // 发送权限决策到远程 Agent
    await agentProxy.respondToPermission(requestId, decision);
    
    // 本地缓存会自动清除
    print('已响应权限请求: $requestId, 决策: $decision');
    
    // 重新加载消息
    await _loadMessages();
  } catch (e) {
    print('响应权限请求失败: $e');
  }
}
```

### 5. UI 层显示权限请求卡片

```dart
Widget buildPermissionRequestCard(ChatMessage message) {
  if (message.type != ChatMessageType.permissionRequest) {
    return SizedBox.shrink();
  }
  
  final requestId = message.metadata?['requestId'] as String;
  final description = message.metadata?['description'] as String;
  final functionName = message.metadata?['functionName'] as String;
  
  return Card(
    child: Column(
      children: [
        ListTile(
          leading: Icon(Icons.security, color: Colors.orange),
          title: Text('权限请求'),
          subtitle: Text(description),
        ),
        Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('函数: $functionName'),
              SizedBox(height: 8),
              Text('描述: $description'),
            ],
          ),
        ),
        ButtonBar(
          children: [
            TextButton(
              child: Text('拒绝'),
              onPressed: () => handlePermissionDecision(
                requestId,
                PermissionDecision.deny,
              ),
            ),
            ElevatedButton(
              child: Text('允许'),
              onPressed: () => handlePermissionDecision(
                requestId,
                PermissionDecision.allow,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
```

## 完整示例

```dart
class ChatViewController extends MvcController {
  CachedAgentProxy? _agentProxy;
  List<ChatMessage> _messages = [];
  
  /// 初始化会话
  Future<void> loadSession() async {
    // 1. 获取 AgentProxy
    _agentProxy = await deviceClient.getOrCreateAgentProxy(
      employeeId: employeeId,
      deviceId: deviceId,
    );
    
    // 2. 初始化（自动查询远程状态和权限请求）
    await _agentProxy!.initialize();
    
    // 3. 监听状态变更
    _agentProxy!.onStateChanged.listen((state) {
      _handleStateChange(state);
    });
    
    // 4. 加载消息
    await _loadMessages();
    
    updateView();
  }
  
  /// 处理状态变更
  void _handleStateChange(AgentStateSnapshot state) {
    if (state.status == AgentStatus.waitingPermission) {
      // Agent 正在等待权限，重新加载消息
      _loadMessages().then((_) => updateView());
    }
  }
  
  /// 加载消息
  Future<void> _loadMessages() async {
    if (_agentProxy == null) return;
    
    // 获取消息
    final messages = await _agentProxy!.getSessionMessages();
    
    // 检查权限请求
    final state = _agentProxy!.getStateSnapshot();
    if (state.status == AgentStatus.waitingPermission) {
      final permission = _agentProxy!.getPendingPermissionRequest();
      if (permission != null) {
        // 添加权限请求卡片
        final permissionMessage = ChatMessage.permissionRequest(
          requestId: permission.requestId,
          description: permission.description,
          functionName: permission.functionName,
          permissionPattern: permission.permissionPattern,
          permissionType: permission.permissionType,
          args: permission.data,
        );
        messages.add(permissionMessage);
      }
    }
    
    _messages = messages;
  }
  
  /// 响应权限请求
  Future<void> handlePermissionDecision(
    String requestId,
    PermissionDecision decision,
  ) async {
    if (_agentProxy == null) return;
    
    await _agentProxy!.respondToPermission(requestId, decision);
    
    // 重新加载消息
    await _loadMessages();
    updateView();
  }
  
  /// 发送消息
  Future<void> sendMessage(String content) async {
    if (_agentProxy == null) return;
    
    await _agentProxy!.sendMessage(MessageInput(
      content: content,
      metadata: {'sessionId': sessionId},
    ));
    
    // 不需要立即加载消息，依赖状态变更事件自动触发
  }
}
```

## 关键点说明

### 1. 自动初始化同步

调用 `initialize()` 时，会自动：
- 查询远程 Agent 状态
- 如果正在等待权限，查询并缓存权限请求
- 无需手动调用其他方法

### 2. 事件驱动更新

权限请求通过以下方式更新：
- **事件驱动**：接收 `toolPermissionRequest` 事件
- **状态驱动**：状态变为 `waitingPermission` 时主动查询
- **双重保障**：确保权限请求不丢失

### 3. 同步访问

`getPendingPermissionRequest()` 是同步方法：
- 本地模式：直接返回本地 Agent 的权限请求
- 远程模式：返回缓存的权限请求
- 无需异步等待，UI 层可直接使用

### 4. 自动清理

权限响应后自动清理缓存：
```dart
await agentProxy.respondToPermission(requestId, decision);
// 缓存已自动清除，无需手动操作
```

### 5. 状态通知

权限请求缓存更新后，会自动通知：
```dart
_notifyMessagesChanged(); // 触发消息变更流
```

客户端可以监听 `onMessagesChanged` 流获取更新。

## 最佳实践

1. **初始化时总是调用 `initialize()`**
   ```dart
   await agentProxy.initialize();
   ```

2. **监听状态变更以更新 UI**
   ```dart
   agentProxy.onStateChanged.listen((state) {
     if (state.status == AgentStatus.waitingPermission) {
       _loadMessages();
     }
   });
   ```

3. **使用同步方法获取权限请求**
   ```dart
   final permission = agentProxy.getPendingPermissionRequest();
   // 无需 await
   ```

4. **响应权限后自动清理**
   ```dart
   await agentProxy.respondToPermission(requestId, decision);
   // 缓存已自动清除
   ```

5. **清理时释放资源**
   ```dart
   await agentProxy.dispose();
   // 所有缓存和订阅都会清理
   ```
