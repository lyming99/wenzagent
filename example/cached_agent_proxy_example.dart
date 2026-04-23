// ============================================================================
// CachedAgentProxy 前端集成示例
// ============================================================================
//
// 演示如何在前端使用 CachedAgentProxy 进行：
// 1. 窗口状态查询（Agent 状态、缓存状态）
// 2. 事件监听（状态变更、消息变更、缓存状态变更）
// 3. 工具调用监听（工具开始、工具结果）
// 4. 消息处理（发送、撤回、清空）
// 5. 消息排队（排队状态、处理进度）
// 6. 权限请求（接收、响应）
//
// 此示例为纯 Dart 代码，不依赖 Flutter，可直接用 `dart run` 执行。
// Flutter 中使用时，将 StreamSubscription 替换为 StreamBuilder 即可。
// ============================================================================

import 'dart:async';

import 'package:wenzagent/wenzagent.dart';

void main() async {
  // ============================================================
  // 0. 前置准备：构造 CachedAgentProxy
  // ============================================================
  //
  // 在实际项目中，你不需要手动创建这些底层对象。
  // DeviceClient 会为你管理 AgentProxy 和 CachedAgentProxy 的生命周期。
  //
  // 此处仅做示意，展示完整的构建过程。

  final employeeId = 'demo-employee-uuid';
  final deviceId = 'demo-device-uuid';

  // --- 远程模式构造（跨设备通信，前端最常用） ---
  // AgentProxy.remote 通过 RPC 回调与远程 Agent 通信
  final remoteProxy = AgentProxy.remote(
    employeeId: employeeId,
    deviceId: deviceId,
    rpcCall: (method, params) async {
      // 实际场景中，这里通过 WebSocket / HTTP 发送 RPC 请求到远端
      print('[RPC] $method -> ${params.keys.join(', ')}');
      return {'messageId': params['id'] ?? ''};
    },
    // remoteEventStream: webSocketStream,  // 实际从 WebSocket 接收事件流
  );

  // MessageStoreServiceImpl 基于 SQLite 存储，实际项目中由 DeviceClient 注入
  // 此处创建内存数据库实例用于演示
  final messageStore = MessageStoreServiceImpl(deviceId: deviceId);

  final cachedProxy = CachedAgentProxy(
    proxy: remoteProxy,
    messageStore: messageStore,
    deviceId: deviceId,
    employeeId: employeeId,
  );

  // ============================================================
  // 1. 初始化
  // ============================================================

  print('\n========== 1. 初始化 ==========');

  await cachedProxy.initialize();
  print('初始化完成，isLocalMode: ${cachedProxy.isLocalMode}');

  // 初始化后异步同步远程数据
  cachedProxy.syncFromRemote().then((_) {
    print('远程同步完成');
  });

  // ============================================================
  // 2. 状态查询
  // ============================================================

  print('\n========== 2. 状态查询 ==========');

  // --- 同步查询（直接读缓存） ---
  final currentStatus = cachedProxy.status;
  print('当前 Agent 状态: ${currentStatus.name}');

  final stateSnapshot = cachedProxy.getStateSnapshot();
  print('状态快照: status=${stateSnapshot.status.name}, '
      'queueLength=${stateSnapshot.queueLength}, '
      'isStreaming=${stateSnapshot.isStreaming}');

  // --- 异步查询（从远程拉取最新） ---
  final remoteSnapshot = await cachedProxy.getStateSnapshotAsync();
  print('远程状态快照: status=${remoteSnapshot.status.name}');

  // --- 缓存状态查询（仅远程模式） ---
  print('缓存状态: ${cachedProxy.cacheState.name}');
  print('是否已同步: ${cachedProxy.isSynced}');
  print('最后同步时间: ${cachedProxy.lastSyncTime}');
  print('缓存消息数: ${await cachedProxy.cachedMessageCount}');

  // --- 未读消息查询 ---
  final unreadCount = await cachedProxy.getUnreadCount();
  print('未读消息数: $unreadCount');

  // --- 正在调用的工具 ID 列表 ---
  final callingToolIds = cachedProxy.getCallingToolIds();
  print('正在调用的工具: $callingToolIds');

  // ============================================================
  // 3. 事件监听
  // ============================================================

  print('\n========== 3. 事件监听 ==========');

  // --- 3.1 监听 Agent 状态变更 ---
  // 最核心的监听：状态流转为 idle -> processing -> streaming -> idle
  final stateSub = cachedProxy.onStateChanged.listen((snapshot) {
    print('\n[状态变更] ${snapshot.status.name}');
    print('  处理中消息: ${snapshot.currentProcessingMessageId}');
    print('  排队消息数: ${snapshot.queueLength}');
    print('  排队消息IDs: ${snapshot.queuedMessageIds}');

    // 状态变为空闲时，主动同步最新消息
    if (snapshot.status == AgentStatus.idle) {
      cachedProxy.syncOnStateChange();
    }
  });

  // --- 3.2 监听消息变更 ---
  // 消息列表发生任何变化时触发（发送、接收、工具调用、状态更新等）
  final messagesSub = cachedProxy.onMessagesChanged.listen((messages) {
    print('\n[消息变更] 共 ${messages.length} 条消息');

    for (final msg in messages) {
      _printMessageSummary(msg);
    }

    // 检查是否有待处理的权限请求
    final permission = cachedProxy.getPendingPermissionRequest();
    if (permission != null) {
      _handlePermissionRequest(cachedProxy, permission);
    }
  });

  // --- 3.3 监听缓存状态变更 ---
  // 仅远程模式有效：idle -> loading -> syncing -> idle
  final cacheSub = cachedProxy.onCacheStateChanged.listen((state) {
    print('\n[缓存状态] ${state.name}');
    if (state == CacheState.error) {
      print('  缓存同步出错，可手动调用 syncWithRemote() 重试');
    }
  });

  // ============================================================
  // 4. 工具调用监听
  // ============================================================

  print('\n========== 4. 工具调用监听 ==========');

  // 工具调用事件通过 onMessagesChanged 体现：
  // - toolCallStart 时，消息列表会出现 type='functionCall' 的临时消息
  // - toolCallResult 时，该临时消息更新为 completed/failed 状态
  //
  // 在消息列表中过滤工具调用消息的示例：
  Future<void> inspectToolCalls() async {
    final messages = await cachedProxy.getMessages();
    final toolMessages = messages.where((m) =>
        m.type == 'functionCall' || m.type == 'functionResult').toList();

    if (toolMessages.isEmpty) {
      print('当前没有工具调用消息');
      return;
    }

    print('工具调用消息 (${toolMessages.length} 条):');
    for (final msg in toolMessages) {
      final statusIcon = switch (msg.status) {
        'processing' => '...',
        'completed' => 'OK',
        'failed' => 'ERR',
        'interrupted' => 'STOP',
        _ => '?',
      };
      print('  [$statusIcon] ${msg.toolName ?? "unknown"} '
          '(id: ${msg.toolCallId}, status: ${msg.status})');

      if (msg.toolArguments != null) {
        print('    参数: ${msg.toolArguments}');
      }
      if (msg.toolResult != null) {
        final preview = msg.toolResult!.length > 80
            ? '${msg.toolResult!.substring(0, 80)}...'
            : msg.toolResult;
        print('    结果: $preview');
      }
    }
  }

  // 监听工具调用的另一种方式：通过底层 proxy 的事件流
  final eventSub = cachedProxy.proxy.onEvent.listen((event) {
    switch (event.type) {
      case AgentEventType.toolCallStart:
        final toolName = event.data['toolName'] as String?;
        final toolCallId = event.data['toolCallId'] as String?;
        final args = event.data['arguments'] as Map<String, dynamic>?;
        print('\n[工具开始] $toolName ($toolCallId)');
        print('  参数: $args');

      case AgentEventType.toolCallResult:
        final toolName = event.data['toolName'] as String?;
        final toolCallId = event.data['toolCallId'] as String?;
        final result = event.data['result'] as String?;
        final isError = event.data['isError'] as bool? ?? false;
        final preview = result != null && result.length > 80
            ? '${result.substring(0, 80)}...'
            : result;
        print('\n[工具结果] $toolName ($toolCallId) '
            '${isError ? "失败" : "成功"}');
        print('  结果: $preview');

      case AgentEventType.toolPermissionRequest:
        // 权限请求也通过事件流推送
        final request = AgentPermissionRequest.fromMap(event.data);
        print('\n[权限请求] 函数: ${request.functionName}');
        print('  描述: ${request.description}');
        print('  权限类型: ${request.permissionType}');
        if (request.suggestedPattern != null) {
          print('  建议模式: ${request.suggestedPattern}');
        }

      case AgentEventType.toolPermissionResponse:
        final requestId = event.data['requestId'] as String?;
        final decision = event.data['decision'] as String?;
        print('\n[权限响应] $requestId -> $decision');

      default:
        break;
    }
  });

  // ============================================================
  // 5. 消息处理
  // ============================================================

  print('\n========== 5. 消息处理 ==========');

  // --- 5.1 发送消息 ---
  Future<void> sendUserMessage(String content) async {
    try {
      final messageId = await cachedProxy.sendMessage(
        MessageInput(content: content),
      );
      print('消息已发送: ID=$messageId');
    } catch (e) {
      print('消息发送失败: $e');
    }
  }

  // --- 5.2 发送工具结果 ---
  Future<void> sendToolResult({
    required String toolCallId,
    required String toolName,
    required String result,
  }) async {
    await cachedProxy.sendMessage(
      MessageInput(
        content: result,
        type: 'functionResult',
        role: 'tool',
        toolCallId: toolCallId,
        toolName: toolName,
      ),
    );
    print('工具结果已发送: toolCallId=$toolCallId');
  }

  // --- 5.3 获取消息列表 ---
  Future<void> loadMessages() async {
    // 普通加载（从本地缓存）
    final messages = await cachedProxy.getMessages();
    print('消息列表 (${messages.length} 条):');
    for (final msg in messages) {
      _printMessageSummary(msg);
    }
  }

  // --- 5.4 强制刷新（从远程同步最新数据） ---
  Future<void> refreshMessages() async {
    final messages = await cachedProxy.getMessagesForceRefresh();
    print('强制刷新后消息列表 (${messages.length} 条)');
  }

  // --- 5.5 撤回消息 ---
  Future<void> revokeUserMessage(String messageId) async {
    await cachedProxy.revokeMessage(messageId);
    print('消息已撤回: $messageId');
  }

  // --- 5.6 中断当前处理 ---
  Future<void> interruptAgent() async {
    await cachedProxy.interrupt();
    print('已中断 Agent 处理');
  }

  // --- 5.7 清空会话 ---
  Future<void> clearSession() async {
    await cachedProxy.clearCurrentSession();
    print('会话已清空');
  }

  // --- 5.8 标记已读 ---
  // 注意：标记已读应通过 DeviceClient 统一调用，不再通过 CachedAgentProxy
  // final client = DeviceClient.getInstance(deviceId);
  // client.markAllMessagesAsRead(employeeId: employeeId);
  void markAllAsRead() {
    print('已标记所有消息为已读（通过 DeviceClient.markAllMessagesAsRead）');
  }

  // ============================================================
  // 6. 消息排队状态
  // ============================================================

  print('\n========== 6. 消息排队 ==========');

  // 消息排队信息可以通过以下方式获取：

  // --- 6.1 通过状态快照查看队列 ---
  void inspectQueue() {
    final snapshot = cachedProxy.getStateSnapshot();
    print('排队消息数: ${snapshot.queueLength}');
    print('排队消息IDs: ${snapshot.queuedMessageIds}');
    print('当前处理消息: ${snapshot.currentProcessingMessageId}');
    print('是否流式输出: ${snapshot.isStreaming}');
  }

  // --- 6.2 在消息列表中查看每条消息的状态 ---
  Future<void> inspectMessageStatuses() async {
    final messages = await cachedProxy.getMessages();

    print('消息状态一览:');
    for (final msg in messages) {
      final status = msg.status ?? 'none';
      final isLocalOnly = msg.metadata?['localOnly'] == true;
      final queuePosition = msg.metadata?['queuePosition'];
      final error = msg.metadata?['error'];

      final badge = switch (status) {
        'pending' => '待发送',
        'sent' => '已发送',
        'queued' => '排队中${queuePosition != null ? ' (#$queuePosition)' : ''}',
        'processing' => '处理中',
        'completed' => '已完成',
        'failed' => '失败${error != null ? ': $error' : ''}',
        'interrupted' => '已中断',
        'revoked' => '已撤回',
        _ => status,
      };

      final localTag = isLocalOnly ? ' [本地]' : '';
      print('  ${msg.role}$localTag: $badge');
      if (msg.content != null) {
        final preview = msg.content!.length > 40
            ? '${msg.content!.substring(0, 40)}...'
            : msg.content;
        print('    内容: $preview');
      }
    }
  }

  // --- 6.3 通过事件流监听排队变化 ---
  // messageStarted 事件：消息开始处理时触发
  // messageStatusChanged 事件：消息状态变更时触发
  // streamDelta 事件：流式输出文本增量
  // thinkingDelta 事件：LLM 思考内容增量
  // 这些事件已经在 cachedProxy 内部处理并触发 onMessagesChanged

  // ============================================================
  // 7. 权限请求处理
  // ============================================================

  print('\n========== 7. 权限请求处理 ==========');

  // --- 7.1 检查当前权限请求 ---
  void checkPermission() {
    final request = cachedProxy.getPendingPermissionRequest();
    if (request == null) {
      print('当前没有待处理的权限请求');
      return;
    }
    _printPermissionDetail(request);
  }

  // --- 7.2 响应权限请求 ---
  Future<void> respondPermission({
    required String requestId,
    required PermissionDecision decision,
  }) async {
    await cachedProxy.respondToPermission(requestId, decision);
    print('权限请求已响应: $requestId -> ${decision.name}');
  }

  // --- 7.3 三种权限决策 ---
  // allow     - 仅本次允许
  // deny      - 拒绝
  // allowAlways - 允许并记住（后续相同权限自动通过）
  //
  // 使用示例：
  // await respondPermission(
  //   requestId: 'req_xxx',
  //   decision: PermissionDecision.allow,
  // );
  //
  // await respondPermission(
  //   requestId: 'req_yyy',
  //   decision: PermissionDecision.allowAlways,
  // );
  //
  // await respondPermission(
  //   requestId: 'req_zzz',
  //   decision: PermissionDecision.deny,
  // );

  // ============================================================
  // 8. 完整的前端窗口集成模式
  // ============================================================

  print('\n========== 8. 完整集成模式（伪代码） ==========');

  // 以下展示一个完整的前端窗口如何集成 CachedAgentProxy。
  // 在 Flutter 中，这通常是一个 StatefulWidget 或 ChangeNotifier。

  // /*
  // class ChatViewModel extends ChangeNotifier {
  //   final CachedAgentProxy _proxy;
  //   List<AgentMessage> _messages = [];
  //   AgentStatus _status = AgentStatus.idle;
  //   CacheState _cacheState = CacheState.idle;
  //   AgentPermissionRequest? _permissionRequest;
  //   String? _error;
  //
  //   // --- 初始化 ---
  //   Future<void> init() async {
  //     await _proxy.initialize();
  //
  //     // 监听消息变更（UI 刷新）
  //     _proxy.onMessagesChanged.listen((msgs) {
  //       _messages = msgs;
  //       _permissionRequest = _proxy.getPendingPermissionRequest();
  //       notifyListeners();
  //     });
  //
  //     // 监听状态变更
  //     _proxy.onStateChanged.listen((snapshot) {
  //       _status = snapshot.status;
  //       notifyListeners();
  //
  //       if (snapshot.status == AgentStatus.idle) {
  //         _proxy.syncOnStateChange();
  //       }
  //     });
  //
  //     // 监听缓存状态
  //     _proxy.onCacheStateChanged.listen((state) {
  //       _cacheState = state;
  //       notifyListeners();
  //     });
  //
  //     // 初始加载
  //     _messages = await _proxy.getMessages();
  //     notifyListeners();
  //
  //     // 后台同步远程数据
  //     _proxy.syncFromRemote();
  //   }
  //
  //   // --- 发送消息 ---
  //   Future<void> sendMessage(String text) async {
  //     try {
  //       _error = null;
  //       await _proxy.sendMessage(MessageInput(content: text));
  //     } catch (e) {
  //       _error = e.toString();
  //     }
  //     notifyListeners();
  //   }
  //
  //   // --- 撤回消息 ---
  //   Future<void> revokeMessage(String id) async {
  //     await _proxy.revokeMessage(id);
  //   }
  //
  //   // --- 响应权限 ---
  //   Future<void> approvePermission(String requestId) async {
  //     await _proxy.respondToPermission(
  //       requestId, PermissionDecision.allow);
  //   }
  //
  //   Future<void> denyPermission(String requestId) async {
  //     await _proxy.respondToPermission(
  //       requestId, PermissionDecision.deny);
  //   }
  //
  //   // --- 中断 ---
  //   Future<void> interrupt() async {
  //     await _proxy.interrupt();
  //   }
  //
  //   // --- 清空 ---
  //   Future<void> clearSession() async {
  //     await _proxy.clearCurrentSession();
  //   }
  //
  //   // --- 下拉刷新 ---
  //   Future<void> refresh() async {
  //     await _proxy.syncWithRemote();
  //   }
  //
  //   // --- 标记已读 ---
  //   void markAsRead() {
  //     _proxy.clearAllUnread();
  //   }
  //
  //   // --- 释放 ---
  //   void dispose() {
  //     _proxy.dispose();
  //   }
  //
  //   // --- 状态访问器 ---
  //   bool get isProcessing =>
  //       _status == AgentStatus.processing ||
  //       _status == AgentStatus.streaming;
  //
  //   bool get isWaitingPermission =>
  //       _status == AgentStatus.waitingPermission;
  //
  //   bool get isIdle => _status == AgentStatus.idle;
  //
  //   bool get hasPermissionRequest => _permissionRequest != null;
  // }
  // */

  // ============================================================
  // 9. 清理
  // ============================================================

  print('\n========== 9. 清理 ==========');

  // 取消所有订阅
  await stateSub.cancel();
  await messagesSub.cancel();
  await cacheSub.cancel();
  await eventSub.cancel();

  // 释放资源
  await cachedProxy.dispose();
  messageStore.dispose();

  print('资源已释放');
}

// ============================================================================
// 辅助函数
// ============================================================================

/// 打印消息摘要
void _printMessageSummary(AgentMessage msg) {
  final status = msg.status ?? 'none';
  final isLocalOnly = msg.metadata?['localOnly'] == true;
  final isTool = msg.metadata?['localToolCall'] == true;

  final role = msg.role;
  final type = msg.type;

  String tag;
  if (isTool && type == 'functionCall') {
    tag = '[工具调用]';
  } else if (type == 'functionResult') {
    tag = '[工具结果]';
  } else if (type == 'error') {
    tag = '[错误]';
  } else {
    tag = '[$role]';
  }

  final localTag = isLocalOnly ? ' (本地)' : '';
  final statusTag = status != 'none' ? ' <$status>' : '';

  final contentPreview = msg.content != null && msg.content!.isNotEmpty
      ? (msg.content!.length > 50
          ? '${msg.content!.substring(0, 50)}...'
          : msg.content!)
      : (msg.toolName ?? '(无内容)');

  print('  $tag$localTag$statusTag $contentPreview');

  if (msg.toolName != null && type != 'functionResult') {
    print('    tool: ${msg.toolName} (${msg.toolCallId})');
  }
}

/// 打印权限请求详情
void _printPermissionDetail(AgentPermissionRequest request) {
  print('权限请求详情:');
  print('  请求ID: ${request.requestId}');
  print('  类型: ${request.type}');
  print('  函数名: ${request.functionName}');
  print('  描述: ${request.description}');
  print('  权限模式: ${request.permissionPattern}');
  print('  权限类型: ${request.permissionType}');
  print('  参数Key: ${request.permissionArgKey}');
  print('  参数Value: ${request.permissionArgValue}');
  print('  建议模式: ${request.suggestedPattern}');
}

/// 处理权限请求（自动决策的示例）
void _handlePermissionRequest(
  CachedAgentProxy proxy,
  AgentPermissionRequest request,
) {
  print('\n>>> 收到权限请求，需要用户确认 <<<');
  _printPermissionDetail(request);

  // 实际场景中，这里应该弹出 UI 让用户选择：
  // 1. 允许 (PermissionDecision.allow)
  // 2. 拒绝 (PermissionDecision.deny)
  // 3. 始终允许 (PermissionDecision.allowAlways)
  //
  // 例如：
  // proxy.respondToPermission(
  //   request.requestId,
  //   PermissionDecision.allow,
  // );
}

// ============================================================================
// CachedAgentProxy API 速查表
// ============================================================================
//
// ┌───────────────────────────────────────────────────────────────────┐
// │                     属性 & 状态查询                               │
// ├───────────────────────────────────────────────────────────────────┤
// │ employeeId         员工 UUID                                     │
// │ deviceId           设备 ID                                       │
// │ isLocalMode        是否本地模式                                   │
// │ status             当前 Agent 状态 (AgentStatus)                  │
// │ isAlive            Agent 是否存活                                │
// │ isSending          是否正在发送                                   │
// │ cacheState         缓存状态 (CacheState)                         │
// │ isSynced           是否已完成远程同步                             │
// │ lastSyncTime       最后同步时间                                   │
// │ needCache          是否启用缓存                                   │
// ├───────────────────────────────────────────────────────────────────┤
// │                     消息操作                                     │
// ├───────────────────────────────────────────────────────────────────┤
// │ sendMessage(input)           发送消息 -> Future<String>          │
// │ getMessages()                获取消息列表 -> Future<List>         │
// │ getMessagesForceRefresh()    强制刷新 -> Future<List>            │
// │ revokeMessage(id)            撤回消息 -> Future<void>            │
// │ interrupt()                  中断处理 -> Future<void>            │
// │ clearCurrentSession()        清空会话 -> Future<void>            │
// ├───────────────────────────────────────────────────────────────────┤
// │                     权限操作                                     │
// ├───────────────────────────────────────────────────────────────────┤
// │ getPendingPermissionRequest()     获取权限请求 (同步)             │
// │ getPendingPermissionRequestAsync() 获取权限请求 (异步)            │
// │ respondToPermission(id, decision) 响应权限 -> Future<void>       │
// ├───────────────────────────────────────────────────────────────────┤
// │                     已读标记                                     │
// ├───────────────────────────────────────────────────────────────────┤
// │ getUnreadCount()            获取未读数 -> Future<int>             │
// │                     (标记已读通过 DeviceClient.markAllMessagesAsRead) │
// ├───────────────────────────────────────────────────────────────────┤
// │                     状态快照                                     │
// ├───────────────────────────────────────────────────────────────────┤
// │ getStateSnapshot()           获取状态快照 (同步)                  │
// │ getStateSnapshotAsync()      获取状态快照 (异步)                  │
// │ getCallingToolIds()          获取调用中的工具ID (同步)            │
// │ getCallingToolIdsAsync()     获取调用中的工具ID (异步)            │
// ├───────────────────────────────────────────────────────────────────┤
// │                     事件流 (Stream)                               │
// ├───────────────────────────────────────────────────────────────────┤
// │ onStateChanged        状态变更 -> Stream<AgentStateSnapshot>     │
// │ onMessagesChanged     消息变更 -> Stream<List<AgentMessage>>     │
// │ onCacheStateChanged   缓存变更 -> Stream<CacheState>             │
// │ proxy.onEvent         原始事件 -> Stream<AgentEvent>             │
// ├───────────────────────────────────────────────────────────────────┤
// │                     同步操作                                     │
// ├───────────────────────────────────────────────────────────────────┤
// │ initialize()           初始化 -> Future<void>                    │
// │ syncFromRemote()       后台同步 -> Future<void>                  │
// │ syncWithRemote()       手动同步 -> Future<void>                  │
// │ syncOnStateChange()    状态变化时同步 -> Future<void>            │
// ├───────────────────────────────────────────────────────────────────┤
// │                     生命周期                                     │
// ├───────────────────────────────────────────────────────────────────┤
// │ dispose()              释放资源 -> Future<void>                  │
// │ isDisposed             是否已释放 (bool)                         │
// └───────────────────────────────────────────────────────────────────┘
//
// AgentStatus 枚举值: idle, processing, streaming, waitingPermission, disposed
// CacheState 枚举值:   idle, loading, syncing, error
// PermissionDecision:   allow, deny, allowAlways
