// ============================================================================
// 聊天窗口示例
// ============================================================================
//
// 演示如何在前端实现：
// 1. 打开聊天：加载本地数据 -> 订阅事件 -> 同步远程
// 2. 发送消息（客户端生成 UUID）
// 3. 清空会话
// 4. 删除消息（撤回）
// 5. 处理 Agent 状态变化（idle/processing/streaming）
// 6. 处理权限请求和授权流程
// 7. 工具调用状态刷新
// 8. 项目/模型选择
// 9. 状态恢复（重启后查询聊天状态）
//
// 依赖：wenzagent (DeviceClient, CachedAgentProxy)
// 此示例为伪代码，展示集成模式。Flutter 中将 Stream 替换为 StreamBuilder 即可。
// ============================================================================

import 'dart:async';

import 'package:wenzagent/wenzagent.dart';

void main() async {
  final deviceId = 'my-phone';
  final employeeId = 'employee-uuid-1';

  // ============================================================
  // 1. 初始化并连接
  // ============================================================

  final client = DeviceClient.getInstance(deviceId);
  await client.initialize(DeviceClientConfig(
    dbPath: '/tmp/wenzagent_db',
    host: '192.168.1.100',
    port: 9527,
    topic: 'default',
    deviceName: 'My Phone',
  ));
  await client.connect();

  // ============================================================
  // 2. App 重启后恢复聊天状态
  // ============================================================
  //
  // 重启后调用 restoreUnreadStatus() 恢复未读计数，
  // 然后打开聊天窗口时查询最新消息。

  await client.restoreUnreadStatus();

  // ============================================================
  // 3. 打开聊天：加载本地数据 -> 订阅事件 -> 同步远程
  // ============================================================

  // 3a. 获取或创建 AgentProxy（自动初始化并加载本地缓存）
  print('[聊天窗口] 获取 AgentProxy...');
  final proxy = await client.getOrCreateAgentProxy(
    employeeId: employeeId,
  );

  // 3b. 初始化（加载本地缓存消息，会触发 onMessagesChanged）
  await proxy.initialize();
  print('[聊天窗口] 初始化完成');

  // 3c. 订阅消息变更（远程模式下，新消息通过此流推送）
  final messagesSub = proxy.onMessagesChanged.listen((messages) {
    print('[聊天窗口] 收到消息更新: ${messages.length} 条');

    // 检查工具调用状态消息
    for (final msg in messages) {
      if (msg.type == 'functionCall') {
        print('[聊天窗口] 工具调用: ${msg.toolName} 状态: ${msg.status}');
        // Flutter: 显示工具调用进度 UI（processing -> completed/failed）
      }
    }
    // Flutter: setState(() { messages = messages; });
  });

  // 3d. 订阅 Agent 状态变化
  final stateSub = proxy.onStateChanged.listen((state) {
    print('[聊天窗口] Agent 状态: ${state.status}');
    switch (state.status) {
      case AgentStatus.idle:
        // 处理完成：隐藏 loading、启用输入框
        print('[聊天窗口] Agent 空闲，可以发送新消息');
      case AgentStatus.processing:
        // 显示 loading 动画
        print('[聊天窗口] Agent 处理中...');
      case AgentStatus.streaming:
        // 流式输出中
        print('[聊天窗口] Agent 流式输出中...');
      case AgentStatus.waitingPermission:
        // 显示权限请求 UI
        print('[聊天窗口] Agent 等待权限确认...');
        _handlePermissionRequest(proxy);
      default:
        break;
    }
    // Flutter: setState(() { agentState = state.status; });
  });

  // 3e. 打开会话时标记已读 + 后台同步远程
  client.notificationHub.shouldAutoMarkAsReadCallback = ({
    required String employeeId,
    String? fromDeviceId,
  }) {
    return true; // 当前会话窗口已打开
  };
  await client.setCurrentOpenSession(employeeId: employeeId);
  await proxy.clearAllUnread();

  // 3f. 后台同步远程最新消息（增量 LSN 同步）
  proxy.syncFromRemote().then((_) {
    print('[聊天窗口] 远程同步完成');
  });

  // ============================================================
  // 4. 加载并显示消息
  // ============================================================

  final messages = await proxy.getMessages();
  print('\n=== 聊天消息 (${messages.length} 条) ===');
  for (final msg in messages) {
    final status = msg.status ?? '';
    if (msg.type == 'functionCall') {
      print('[${msg.role}] 工具: ${msg.toolName} $status');
    } else {
      final preview = msg.content?.substring(0, 30) ?? '';
      print('[${msg.role}] $preview $status');
    }
  }

  // ============================================================
  // 5. 发送消息
  // ============================================================

  // 客户端生成 UUID，确保本地图缓存的 ID 与服务端一致
  final messageId = await proxy.sendMessage(MessageInput(
    content: '你好，请介绍一下你自己',
    role: 'user',
  ));
  print('\n[聊天窗口] 已发送消息: $messageId');

  // 消息发送后，等待 onMessagesChanged 推送更新
  // （Agent 会异步处理并推送 assistant 回复）
  print('[聊天窗口] 等待 Agent 回复...');

  // ============================================================
  // 6. 处理权限请求
  // ============================================================
  //
  // 当 Agent 调用需要权限的工具时，前端需要：
  // 1. 从 getPendingPermissionRequest() 获取权限详情
  // 2. 向用户展示请求
  // 3. 用户批准或拒绝
  // 4. 调用 respondToPermission() 通知 Agent

  // 主动查询权限请求（处理重启后恢复场景）
  _handlePermissionRequest(proxy);

  // ============================================================
  // 7. 工具调用状态刷新
  // ============================================================
  //
  // 工具调用状态通过 onMessagesChanged 推送：
  // - toolCallStart: 创建 functionCall 类型的 processing 消息
  // - toolCallResult: 更新为 completed/failed/interrupted
  //
  // 本地模式下，工具调用消息通过内存缓存可见（不持久化到数据库）。
  // 远程模式下，工具调用消息保存到本地数据库。
  // 两种模式下 getMessages() 都返回包含工具调用状态的完整消息列表。

  // 查询正在调用的工具 ID 列表（用于显示 loading 指示器）
  final callingToolIds = proxy.getCallingToolIds();
  if (callingToolIds.isNotEmpty) {
    print('[聊天窗口] 正在调用的工具: ${callingToolIds.join(', ')}');
  }

  // ============================================================
  // 8. 项目/模型选择
  // ============================================================
  //
  // 切换项目或模型后，变更会自动广播到其他设备
  // （DeviceRpcHandler 在 methodSetProject/methodSetProvider 后调用
  //  DataSyncManager.broadcastEmployeeToAllDevices）。

  // 查询当前项目
  final currentProject = proxy.getCurrentProjectUuid();
  print('[聊天窗口] 当前项目: $currentProject');

  // 切换项目（变更自动同步到其他设备）
  // await proxy.setProject(ProjectData(
  //   projectUuid: 'new-project-uuid',
  //   projectName: 'New Project',
  //   workPath: '/path/to/project',
  // ));

  // 查询当前模型
  final currentProvider = proxy.getProviderConfig();
  print('[聊天窗口] 当前模型: ${currentProvider?.provider} · ${currentProvider?.model}');

  // 切换模型（变更自动同步到其他设备）
  // await proxy.setProvider(ProviderConfig(
  //   provider: LlmProvider.openai,
  //   model: 'gpt-4o',
  //   apiKey: 'sk-...',
  // ));

  // ============================================================
  // 9. 撤回消息（删除用户消息及其助手回复）
  // ============================================================

  // await proxy.revokeMessage(messageId);
  // print('[聊天窗口] 已撤回消息: $messageId');

  // ============================================================
  // 10. 清空会话
  // ============================================================

  // await proxy.clearCurrentSession();
  // print('[聊天窗口] 会话已清空');

  // ============================================================
  // 11. 清理
  // ============================================================

  // 模拟等待用户操作
  await Future.delayed(const Duration(seconds: 2));

  client.clearCurrentOpenSession();
  await messagesSub.cancel();
  await stateSub.cancel();

  // 注意：不要 dispose proxy，由 DeviceClient 管理
  await client.disconnect();

  print('\n=== 示例结束 ===');
}

/// 处理权限请求
///
/// 从 proxy 获取当前待处理的权限请求，展示给用户并等待响应。
/// 此方法可在以下场景调用：
/// 1. 收到 waitingPermission 状态变更事件时
/// 2. 重启 App 后主动查询是否有未处理的权限请求
Future<void> _handlePermissionRequest(CachedAgentProxy proxy) async {
  final permissionRequest = proxy.getPendingPermissionRequest();
  if (permissionRequest == null) return;

  print('\n[聊天窗口] 收到权限请求:');
  print('  函数: ${permissionRequest.functionName}');
  print('  描述: ${permissionRequest.description}');
  if (permissionRequest.permissionArgKey != null) {
    print('  ${permissionRequest.permissionArgKey}: ${permissionRequest.permissionArgValue}');
  }
  if (permissionRequest.suggestedPattern != null) {
    print('  建议模式: ${permissionRequest.suggestedPattern}');
  }

  // 用户选择：
  // - allow: 仅本次允许
  // - allowAlways: 允许并记住（后续相同权限自动允许）
  // - deny: 拒绝

  // 示例：批准本次
  await proxy.respondToPermission(
    permissionRequest.requestId,
    PermissionDecision.allow,
  );
  print('[聊天窗口] 已批准权限请求');

  // 清理：respondToPermission 内部自动清除缓存的权限请求
}
