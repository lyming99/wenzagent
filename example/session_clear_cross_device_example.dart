/// 会话清空跨设备感知示例
///
/// 展示当设备 A 清空会话后，设备 B 如何通过事件流感知到并同步清理本地缓存。
///
/// 完整调用链（修复后）：
/// ```
/// 设备A (发起方)                       Host (服务器)                       设备B (感知方)
/// ─────────────                       ────────────                       ────────────────
/// CachedAgentProxy.clearCurrentSession()
///   │
///   ├─ RPC: agentClearSession ─────→ DeviceRpcHandler
///   │                                   │
///   │                                   └─ AgentImpl.clearCurrentSession()
///   │                                        │
///   │                                        ├─ 清空内存+DB ✅
///   │                                        │
///   │                                        └─ _eventController.add(sessionCleared)
///   │                                             │
///   │                                        DeviceAgentManager._subscribeAgentEvents
///   │                                             │
///   │                                             ├─ broadcastAgentEvent()
///   │                                             │   └─ LanMessageType.agentSessionCleared
///   │                                             │      └─ LAN 广播 ─────────────→ _handleAgentEvent()
///   │                                             │                                     │
///   │                                             │                                     └─ _stateHolder.eventController
///   │                                             │                                          │
///   │                                             │                                    AgentProxy._onRemoteEvent
///   │                                             │                                          │
///   │                                             │                                    _eventController.add(event)
///   │                                             │                                          │
///   │                                             │                                    CachedAgentProxy._handleAgentEvent
///   │                                             │                                          │
///   │                                             │                                    case sessionCleared:
///   │                                             │                                    _handleSessionCleared()
///   │                                             │                                      ├─ 删除本地DB消息
///   │                                             │                                      ├─ 重置水位线为 0
///   │                                             │                                      └─ _notifyMessagesChanged()
///   │                                             │                                           └─ UI 收到空消息列表 ✅
///   │                                             │
///   │                                             └─ _stateHolder.eventController.add(event)
///   │                                                  (Host 本地 Proxy 也能收到)
///   │
///   ├─ 本地清理 ✅                              ✅ Host 清理完成                    ✅ 设备B 清理完成
///   └─ _notifyMessagesChanged() ✅
/// ```
library;

import 'dart:async';

import 'package:wenzagent/wenzagent.dart';

// ============================================================================
// 场景 1：设备 A 清空会话（发起方）
// ============================================================================

/// 设备 A 的聊天窗口：用户点击"清空会话"按钮
Future<void> exampleDeviceAClearSession(CachedAgentProxy proxyA) async {
  print('=== 设备 A: 用户点击清空会话 ===');

  // 调用 clearCurrentSession()，内部会：
  // 1. RPC 通知 Host AgentImpl 清空服务端会话（内存+DB）
  // 2. 清空本地缓存 DB
  // 3. 重置本地同步水位线为 0
  // 4. 通知 UI 刷新（onMessagesChanged 触发，消息列表为空）
  await proxyA.clearCurrentSession();

  print('[设备A] 会话已清空，本地消息已清除');

  // 此时 Host 的 AgentImpl 会广播 sessionCleared 事件
  // 通过 LAN 转发到所有连接的设备
}

// ============================================================================
// 场景 2：设备 B 感知会话清空（被动方）
// ============================================================================

/// 设备 B 的聊天窗口示例
///
/// 通过监听 onMessagesChanged 流，自动感知远端清空事件。
class DeviceBChatPage {
  final CachedAgentProxy proxy;
  List<AgentMessage> messages = [];
  StreamSubscription? _messagesSub;

  DeviceBChatPage({required this.proxy});

  /// 窗口打开时注册监听
  void onWindowOpen() {
    // 监听消息变更流
    // 当设备 A 清空会话后，Host 广播 sessionCleared 事件，
    // 经 LAN → DeviceMessageHandler → _stateHolder.eventController →
    // AgentProxy._onRemoteEvent → CachedAgentProxy._handleSessionCleared
    // → _notifyMessagesChanged() → 此流收到空列表
    _messagesSub = proxy.onMessagesChanged.listen((updatedMessages) {
      messages = updatedMessages;

      if (messages.isEmpty) {
        print('[设备B] 收到会话清空通知，消息列表已清空');
        // TODO: setState(() {}) 或调用 UI 刷新
        // UI 应显示空白聊天窗口
      }
    });

    print('[设备B] 已注册消息变更监听');
  }

  /// 窗口关闭时取消监听
  void onWindowClose() {
    _messagesSub?.cancel();
    _messagesSub = null;
    print('[设备B] 已取消监听');
  }
}

// ============================================================================
// 场景 3：底层事件流详解（理解事件传播链路）
// ============================================================================

/// 演示完整的跨设备事件传播链路
///
/// 展示事件如何在各层之间流转，适用于调试和排错。
Future<void> exampleEventPropagationChain(
  CachedAgentProxy proxyB,
) async {
  print('\n=== 事件传播链路详解 ===');

  // 设备 B 的 CachedAgentProxy 在 initialize() 时已经订阅了：
  // 1. proxy.onEvent → _handleAgentEvent（处理所有事件类型，包括 sessionCleared）
  // 2. proxy.onStateChanged → _handleStateChange（处理状态变更）
  //
  // 当 sessionCleared 事件到达时，处理流程：
  //
  // Step 1: AgentProxy._onRemoteEvent 收到原始事件
  //   → _eventController.add(event)  // 广播给 CachedAgentProxy
  //
  // Step 2: CachedAgentProxy._handleAgentEvent
  //   → case AgentEventType.sessionCleared:
  //   → _handleSessionCleared(data)
  //
  // Step 3: _handleSessionCleared 执行：
  //   → _pendingPermissionRequests.clear()  // 清除权限缓存
  //   → _messageStore.deleteMessages(...)    // 清除本地 DB
  //   → _messageStore.resetLastSeq(..., 0)  // 重置水位线
  //   → _notifyMessagesChanged()            // 通知 UI
  //
  // Step 4: _notifyMessagesChanged → getMessages() → 返回空列表
  //   → _messagesController.add([])          // onMessagesChanged 流触发

  print('事件传播链路:');
  print('  LAN消息 → DeviceMessageHandler._handleAgentEvent');
  print('    → _stateHolder.eventController.add(AgentEvent)');
  print('      → AgentProxy._onRemoteEvent');
  print('        → _eventController.add(event)');
  print('          → CachedAgentProxy._handleAgentEvent');
  print('            → _handleSessionCleared');
  print('              → 清空DB + 重置水位线 + 通知UI');
}

// ============================================================================
// 场景 4：完整多设备测试示例
// ============================================================================

/// 完整的多设备会话清空测试流程
///
/// 模拟设备 A 清空会话后，设备 B 感知并同步的完整流程。
Future<void> exampleMultiDeviceSessionClear(
  CachedAgentProxy proxyA,
  CachedAgentProxy proxyB,
) async {
  print('\n===== 多设备会话清空完整示例 =====');

  // === Step 1: 初始化两个设备 ===
  print('\n--- Step 1: 初始化 ---');
  await proxyA.initialize();
  await proxyB.initialize();
  await proxyA.syncFromRemote();
  await proxyB.syncFromRemote();

  // 查看初始消息数量
  final messagesA = await proxyA.getMessages();
  final messagesB = await proxyB.getMessages();
  print('设备A 消息数: ${messagesA.length}');
  print('设备B 消息数: ${messagesB.length}');

  // === Step 2: 设备 B 注册监听 ===
  print('\n--- Step 2: 设备B注册监听 ---');
  var bCleared = false;
  final sub = proxyB.onMessagesChanged.listen((msgs) {
    if (msgs.isEmpty && !bCleared) {
      bCleared = true;
      print('[设备B] 感知到会话被清空! 消息列表已变为空');
    }
  });

  // === Step 3: 设备 A 发送消息并清空 ===
  print('\n--- Step 3: 设备A清空会话 ---');
  await proxyA.clearCurrentSession();
  print('[设备A] 会话已清空');

  // === Step 4: 等待事件传播 ===
  print('\n--- Step 4: 等待事件传播 ---');
  // 事件通过 LAN 异步传播，等待一小段时间
  await Future.delayed(const Duration(milliseconds: 500));

  // === Step 5: 验证结果 ===
  print('\n--- Step 5: 验证结果 ---');
  final messagesAAfter = await proxyA.getMessages();
  final messagesBAfter = await proxyB.getMessages();
  print('设备A 清空后消息数: ${messagesAAfter.length}');
  print('设备B 清空后消息数: ${messagesBAfter.length}');
  print('设备B 是否收到清空通知: $bCleared');

  // === Step 6: 验证水位线 ===
  print('\n--- Step 6: 验证水位线 ---');
  // 水位线应为 0（resetLastSeq），后续增量同步从 0 开始
  // 不会因为水位线残留而拉取到已清空的消息

  // === 清理 ===
  await sub.cancel();
  print('\n===== 测试完成 =====');
}

// ============================================================================
// 场景 5：UI 层完整集成示例
// ============================================================================

/// UI 层完整集成示例
///
/// 展示一个聊天窗口如何同时处理：
/// - 正常消息更新
/// - 远端清空会话事件
/// - 水位线重置
class ChatWindowWithClearAwareness {
  final CachedAgentProxy proxy;
  List<AgentMessage> messages = [];
  bool isSessionCleared = false;
  final List<StreamSubscription> _subscriptions = [];

  ChatWindowWithClearAwareness({required this.proxy});

  /// 打开窗口
  Future<void> open() async {
    // 1. 初始化并同步
    await proxy.initialize();
    await proxy.syncFromRemote();

    // 2. 加载初始消息
    messages = await proxy.getMessages();
    isSessionCleared = messages.isEmpty;

    // 3. 注册消息变更监听
    _subscriptions.add(
      proxy.onMessagesChanged.listen((updatedMessages) {
        messages = updatedMessages;

        // 检测会话是否被清空
        if (updatedMessages.isEmpty && !isSessionCleared) {
          isSessionCleared = true;
          _onSessionCleared();
        } else if (updatedMessages.isNotEmpty) {
          isSessionCleared = false;
        }

        // TODO: setState(() {}) 触发 UI 重建
      }),
    );

    // 4. 注册缓存状态监听
    _subscriptions.add(
      proxy.onCacheStateChanged.listen((state) {
        // 可在 UI 显示同步状态指示器
        print('[ChatWindow] 缓存状态: $state');
      }),
    );
  }

  /// 会话被清空的回调
  ///
  /// 当远端设备清空会话时触发。
  /// CachedAgentProxy._handleSessionCleared 已经自动完成：
  //  - 清空本地 DB
  //  - 重置同步水位线为 0
  //  - 清除权限请求缓存
  //  - 触发 onMessagesChanged 流
  void _onSessionCleared() {
    print('[ChatWindow] 会话已被远端清空');
    // UI 可显示提示："会话已被其他设备清空"
    // 或自动回到会话列表页
  }

  /// 用户主动清空会话
  Future<void> userClearSession() async {
    await proxy.clearCurrentSession();
    isSessionCleared = true;
    print('[ChatWindow] 用户清空了会话');
  }

  /// 关闭窗口
  void close() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }
}
