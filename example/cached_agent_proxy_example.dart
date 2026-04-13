/// CachedAgentProxy 使用示例
///
/// 覆盖 7 个典型场景：
/// 1. 聊天窗口打开：初始化 + 同步 + 注册监听器
/// 2. 聊天窗口关闭：取消监听器
/// 3. 查询未读数量
/// 4. 查询最新消息
/// 5. 查询正在调用的工具 ID（toolCallingIds）
/// 6. 查询聊天状态（思考、回复、空闲）
/// 7. 更新已读状态
///
/// 本文件以一个 Flutter ChatPage 组件的生命周期为线索，
/// 展示 CachedAgentProxy 在真实 UI 场景中的完整用法。
library;

import 'dart:async';

import 'package:wenzagent/wenzagent.dart';

// ============================================================================
// 前置：如何创建 CachedAgentProxy（由 DeviceClient / DeviceAgentManager 管理）
// ============================================================================

/// 创建一个 CachedAgentProxy 实例
///
/// 通常由 [DeviceAgentManager] 在 Agent 连接时创建，UI 层不需要直接调用。
/// 这里仅展示构造方式，实际使用中从管理器获取即可。
CachedAgentProxy createCachedAgentProxy({
  required AgentProxy proxy,
  required MessageStoreService messageStore,
  required String deviceId,
  required String employeeId,
  required void Function(String employeeId, String? fromDeviceId) onMarkAsRead,
  required bool Function() shouldSaveAsRead,
}) {
  return CachedAgentProxy(
    proxy: proxy,
    messageStore: messageStore,
    deviceId: deviceId,
    employeeId: employeeId,
    onMarkAsRead: onMarkAsRead,
    shouldSaveAsReadCallback: shouldSaveAsRead,
  );
}

// ============================================================================
// 场景 1 & 2：聊天窗口打开/关闭 —— 生命周期管理
// ============================================================================

/// 聊天页面示例（伪 Flutter Widget，重点展示 CachedAgentProxy 用法）
///
/// ```
/// 窗口打开 → initialize → syncFromRemote → 注册监听器 → UI 渲染
/// 窗口关闭 → 取消监听器（dispose 不在这里调用，由管理器管理）
/// ```
class ChatPageExample {
  final CachedAgentProxy proxy;

  /// 消息列表（供 UI 渲染）
  List<AgentMessage> messages = [];

  /// 聊天状态（供 UI 渲染）
  AgentStatus currentStatus = AgentStatus.idle;

  /// 缓存同步状态（供 UI 渲染 loading 指示器）
  CacheState cacheState = CacheState.idle;

  /// 活跃的流订阅（窗口关闭时统一取消）
  final List<StreamSubscription> _subscriptions = [];

  ChatPageExample({required this.proxy});

  // ------ 场景 1：聊天窗口打开 ------

  /// 窗口打开时调用
  ///
  /// 流程：初始化 → 同步远程消息 → 注册监听器 → 标记已读
  Future<void> onWindowOpen() async {
    // 1. 初始化（加载本地缓存消息，初始化事件监听）
    await proxy.initialize();
    print('[ChatPage] 初始化完成');

    // 2. 同步远程最新消息（后台异步，不阻塞 UI）
    //    内部会通过 onMessagesChanged 通知 UI 刷新
    proxy.syncFromRemote().then((_) {
      print('[ChatPage] 远程同步完成');
    });

    // 3. 读取本地缓存消息立即显示（首屏渲染）
    messages = await proxy.getMessages();
    print('[ChatPage] 本地消息: ${messages.length} 条');

    // 4. 注册消息变更监听器
    _subscribeMessagesChanged();

    // 5. 注册聊天状态变更监听器
    _subscribeStateChanged();

    // 6. 注册缓存状态监听器（仅远程模式有效）
    _subscribeCacheStateChanged();

    // 7. 标记所有消息为已读（用户打开了窗口）
    proxy.clearAllUnread();
  }

  /// 注册消息变更监听器
  ///
  /// 当有新消息、消息状态变更、工具调用更新等，都会通过此流通知。
  /// 这是 UI 刷新消息列表的主要数据源。
  void _subscribeMessagesChanged() {
    final sub = proxy.onMessagesChanged.listen((updatedMessages) {
      messages = updatedMessages;
      print('[ChatPage] 消息列表更新: ${updatedMessages.length} 条');
      // TODO: 调用 setState() 触发 UI 重建
      // setState(() {});
    });
    _subscriptions.add(sub);
  }

  /// 注册聊天状态变更监听器
  ///
  /// 状态变化：idle → processing → streaming → idle
  /// UI 可据此显示加载指示器、流式输出光标等。
  void _subscribeStateChanged() {
    final sub = proxy.onStateChanged.listen((state) {
      currentStatus = state.status;
      print('[ChatPage] 状态变更: ${state.status}'
          '${state.isStreaming ? " (streaming)" : ""}'
          '${state.queueLength > 0 ? " queue=${state.queueLength}" : ""}');
      // TODO: setState(() {});

      // 当 Agent 回到空闲状态时，可以做额外的刷新
      if (state.status == AgentStatus.idle) {
        print('[ChatPage] Agent 空闲，可做最终刷新');
      }
    });
    _subscriptions.add(sub);
  }

  /// 注册缓存状态监听器（仅远程模式）
  ///
  /// 可用于 UI 显示同步进度条：
  /// - loading: 正在加载本地缓存
  /// - syncing: 正在同步远程消息
  /// - idle: 同步完成
  /// - error: 同步失败
  void _subscribeCacheStateChanged() {
    final sub = proxy.onCacheStateChanged.listen((state) {
      cacheState = state;
      print('[ChatPage] 缓存状态: $state');
      // TODO: setState(() {});
    });
    _subscriptions.add(sub);
  }

  // ------ 场景 2：聊天窗口关闭 ------

  /// 窗口关闭时调用
  ///
  /// 注意：只取消 UI 监听器，不 dispose CachedAgentProxy 本身。
  /// CachedAgentProxy 的生命周期由 DeviceAgentManager 管理。
  void onWindowClose() {
    // 统一取消所有流订阅
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    print('[ChatPage] 窗口关闭，已取消所有监听器');
  }
}

// ============================================================================
// 场景 3：查询未读数量
// ============================================================================

/// 查询未读消息数量
///
/// 适用于：
/// - 会话列表页显示未读气泡
/// - Tab 栏显示未读总数
/// - 判断是否需要推送通知
Future<void> exampleQueryUnreadCount(CachedAgentProxy proxy) async {
  // 方式 1：获取未读数量
  final unreadCount = await proxy.getUnreadCount();
  print('[未读] 数量: $unreadCount');

  // 方式 2：获取未读消息 ID 列表
  final unreadIds = await proxy.getUnreadMessageIds();
  print('[未读] 消息ID: $unreadIds');
}

// ============================================================================
// 场景 4：查询最新消息
// ============================================================================

/// 查询最新消息
///
/// 有三种方式，按使用场景选择：
Future<void> exampleQueryLatestMessages(CachedAgentProxy proxy) async {
  // 方式 1：从本地缓存读取（最快，适合日常 UI 渲染）
  final localMessages = await proxy.getMessages();
  print('[消息] 本地缓存: ${localMessages.length} 条');
  if (localMessages.isNotEmpty) {
    final latest = localMessages.last;
    final content = latest.content ?? '';
    print('[消息] 最新一条: role=${latest.role}, '
        'content=${content.length > 50 ? '${content.substring(0, 50)}...' : content}');
  }

  // 方式 2：强制从远程同步后读取（适合确保数据最新的场景）
  final freshMessages = await proxy.getMessagesForceRefresh();
  print('[消息] 强制刷新后: ${freshMessages.length} 条');

  // 方式 3：别名方法（与 getMessages 完全一致）
  final aliasMessages = await proxy.getSessionMessages();
  print('[消息] 别名方法: ${aliasMessages.length} 条');
}

// ============================================================================
// 场景 5：查询 toolCallingIds
// ============================================================================

/// 查询正在调用的工具 ID
///
/// 适用于：
/// - UI 显示工具调用进度指示器
/// - 判断 Agent 是否在执行工具
/// - 超时检测
Future<void> exampleQueryToolCallingIds(CachedAgentProxy proxy) async {
  // 方式 1：同步获取（本地模式直接返回，远程模式返回缓存）
  final localIds = proxy.getCallingToolIds();
  print('[工具调用] 本地缓存: $localIds');

  // 方式 2：异步获取（远程模式通过 RPC 查询，确保最新）
  final asyncIds = await proxy.getCallingToolIdsAsync();
  print('[工具调用] 异步查询: $asyncIds');

  // 从消息列表中筛选工具调用消息
  final messages = await proxy.getMessages();
  final toolCallMessages = messages
      .where((m) => m.type == 'functionCall' || m.toolCalls != null)
      .toList();
  print('[工具调用] 消息中的工具调用: ${toolCallMessages.length} 条');
  for (final msg in toolCallMessages) {
    final toolNames = msg.toolCalls?.map((tc) => tc.name).toList() ?? [];
    print('  - ${msg.id}: tools=$toolNames, status=${msg.status}');
  }
}

// ============================================================================
// 场景 6：查询聊天状态（思考、回复、空闲）
// ============================================================================

/// 查询聊天状态
///
/// AgentStatus 枚举值含义：
/// - idle: 空闲，等待用户输入
/// - processing: 正在处理消息（可能在做工具调用、等待 LLM 响应）
/// - streaming: 正在流式输出文本
/// - waitingPermission: 等待用户授权工具执行
/// - disposed: 已销毁
Future<void> exampleQueryChatStatus(CachedAgentProxy proxy) async {
  // 方式 1：同步获取当前状态（轻量，适合 UI 轮询）
  final status = proxy.status;
  _printStatus(status);

  // 方式 2：获取完整状态快照
  final snapshot = proxy.getStateSnapshot();
  print('[状态] 快照: status=${snapshot.status}, '
      'streaming=${snapshot.isStreaming}, '
      'queue=${snapshot.queueLength}, '
      'processingMsg=${snapshot.currentProcessingMessageId}');

  // 方式 3：异步获取远程最新状态（远程模式通过 RPC 查询）
  final asyncSnapshot = await proxy.getStateSnapshotAsync();
  print('[状态] 异步快照: ${asyncSnapshot.status}');

  // 方式 4：isSending 便捷属性（= processing 或 streaming）
  final isSending = proxy.isSending;
  print('[状态] 是否正在发送: $isSending');
}

void _printStatus(AgentStatus status) {
  switch (status) {
    case AgentStatus.idle:
      print('[状态] 空闲 —— 等待用户输入');
    case AgentStatus.processing:
      print('[状态] 处理中 —— 正在调用工具或等待 LLM 响应');
    case AgentStatus.streaming:
      print('[状态] 流式输出 —— 正在生成回复文本');
    case AgentStatus.waitingPermission:
      print('[状态] 等待权限 —— 需要用户确认工具执行');
    case AgentStatus.disposed:
      print('[状态] 已销毁');
  }
}

// ============================================================================
// 场景 7：更新已读状态
// ============================================================================

/// 更新已读状态
///
/// 有三种方式，按场景选择：
Future<void> exampleMarkAsRead(CachedAgentProxy proxy) async {
  // 方式 1：标记全部已读 + 本地 DB 更新 + 远程通知（推荐）
  //
  // 适用场景：用户打开聊天窗口
  // 效果：
  //   1. 本地 DB 批量更新 is_read=1
  //   2. 通知远程 Agent 记录已读状态（fire-and-forget）
  //   3. 触发 UI 刷新
  await proxy.clearAllUnread();
  print('[已读] clearAllUnread: 本地+远程全部标记已读');

  // 方式 2：仅通知远程已读（不改本地 DB）
  //
  // 适用场景：用户已读特定消息，需跨设备同步已读状态
  // 效果：
  //   1. 持久化到本地队列（断线重连后重发）
  //   2. RPC 通知远程 Agent
  proxy.markMessagesAsRead();
  print('[已读] markMessagesAsRead: 通知远程已读');

  // 方式 3：标记指定消息已读
  //
  // 适用场景：部分消息已读
  proxy.markMessagesAsRead(
    messageIds: ['msg-uuid-1', 'msg-uuid-2'],
  );
  print('[已读] markMessagesAsRead: 指定消息已读');
}

// ============================================================================
// 完整生命周期示例
// ============================================================================

/// 完整的聊天窗口生命周期示例
///
/// 演示从打开到关闭的完整流程。
Future<void> exampleFullLifecycle(CachedAgentProxy proxy) async {
  final page = ChatPageExample(proxy: proxy);

  // === 窗口打开 ===
  print('\n===== 窗口打开 =====');
  await page.onWindowOpen();

  // === 查询未读 ===
  print('\n===== 查询未读 =====');
  await exampleQueryUnreadCount(proxy);

  // === 查询最新消息 ===
  print('\n===== 查询消息 =====');
  await exampleQueryLatestMessages(proxy);

  // === 查询工具调用 ===
  print('\n===== 查询工具调用 =====');
  await exampleQueryToolCallingIds(proxy);

  // === 查询状态 ===
  print('\n===== 查询状态 =====');
  await exampleQueryChatStatus(proxy);

  // === 标记已读 ===
  print('\n===== 标记已读 =====');
  await exampleMarkAsRead(proxy);

  // === 发送消息 ===
  print('\n===== 发送消息 =====');
  final msgId = await proxy.sendMessage(
    MessageInput(content: '你好，请帮我分析一下项目结构'),
  );
  print('[发送] 消息ID: $msgId');

  // 等待一下，让事件流处理完
  await Future.delayed(const Duration(seconds: 2));

  // === 再次查询状态（可能正在处理） ===
  print('\n===== 处理中状态 =====');
  _printStatus(proxy.status);
  print('isSending: ${proxy.isSending}');

  // === 窗口关闭 ===
  print('\n===== 窗口关闭 =====');
  page.onWindowClose();
}
