import 'dart:async';

import '../agent_state.dart';
import '../i_agent.dart';
import '../rpc/agent_rpc_config.dart';
import '../tool/agent_tool.dart';

/// RPC 调用回调类型
typedef RpcCall =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

/// Agent Proxy（纯 Dart）
///
/// 统一本地和远程调用入口，对上层透明。
///
/// 两种工作模式：
/// - 本地模式：直接调用 [IAgent] 实例
/// - 远程模式：通过 RPC 回调调用远程 Agent
class AgentProxy {
  /// 员工UUID
  final String employeeId;

  /// 设备ID
  final String deviceId;

  /// 是否为本地模式
  final bool isLocalMode;

  /// 本地 Agent 实例（本地模式使用）
  final IAgent? _localAgent;

  /// RPC 调用回调（远程模式使用）
  final RpcCall? _rpcCall;

  /// 远程状态缓存
  final _RemoteStateCache _remoteCache = _RemoteStateCache();

  /// 状态变更通知
  final StreamController<AgentStateSnapshot> _stateController =
      StreamController<AgentStateSnapshot>.broadcast();

  /// 远程事件流订阅取消器
  StreamSubscription<Map<String, dynamic>>? _remoteEventSubscription;

  /// 创建本地模式 Proxy
  AgentProxy.local({
    required this.employeeId,
    required this.deviceId,
    required IAgent localAgent,
  }) : isLocalMode = true,
       _localAgent = localAgent,
       _rpcCall = null;

  /// 创建远程模式 Proxy
  AgentProxy.remote({
    required this.employeeId,
    required this.deviceId,
    required RpcCall rpcCall,
    Stream<Map<String, dynamic>>? remoteEventStream,
  }) : isLocalMode = false,
       _localAgent = null,
       _rpcCall = rpcCall {
    if (remoteEventStream != null) {
      _subscribeRemoteEvents(remoteEventStream);
    }
  }

  /// 状态变更流
  Stream<AgentStateSnapshot> get onStateChanged {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.onStateChanged;
    }
    return _stateController.stream;
  }

  /// 当前状态
  AgentStatus get status {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.status;
    }
    return _remoteCache.status;
  }

  /// 是否存活
  bool get isAlive {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.isAlive;
    }
    return _remoteCache.status != AgentStatus.disposed;
  }

  // ===== 对话操作 =====

  /// 发送消息
  Future<String> sendMessage(Map<String, dynamic> messageData) async {
    print('[AgentProxy] sendMessage isLocalMode: $isLocalMode');
    if (isLocalMode && _localAgent != null) {
      print('[AgentProxy] calling local agent sendMessage');
      return _localAgent.sendMessage(messageData);
    }
    print('[AgentProxy] calling RPC sendMessage');
    final result = await _rpc(AgentRpcConfig.methodSendMessage, {
      'employeeId': employeeId,
      'messageData': messageData,
    });
    return result['messageId'] as String? ?? '';
  }

  /// 中断当前处理
  Future<void> interrupt() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.interrupt();
    }
    await _rpc(AgentRpcConfig.methodInterrupt, {'employeeId': employeeId});
  }

  /// 撤回消息
  Future<void> revokeMessage(String messageId) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.revokeMessage(messageId);
    }
    await _rpc(AgentRpcConfig.methodRevokeMessage, {
      'employeeId': employeeId,
      'messageId': messageId,
    });
  }

  /// 获取当前权限请求（如果有，同步版本仅适用于本地模式）
  AgentPermissionRequest? getPendingPermissionRequest() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getPendingPermissionRequest();
    }
    return null;
  }

  /// 获取当前权限请求（异步版本，支持远程 RPC）
  Future<AgentPermissionRequest?> getPendingPermissionRequestAsync() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getPendingPermissionRequest();
    }
    final result = await _rpc(AgentRpcConfig.methodGetPendingPermission, {
      'employeeId': employeeId,
    });
    final requestData = result['request'] as Map<String, dynamic>?;
    if (requestData == null) return null;
    return AgentPermissionRequest.fromMap(requestData);
  }

  // ===== 会话消息 =====

  /// 获取会话消息
  ///
  /// [employeeId] 可选，不提供时使用 Agent 当前活跃会话
  Future<List<Map<String, dynamic>>> getSessionMessages() async {
    if (isLocalMode && _localAgent != null) {
      final uuid = _localAgent.employeeId;
      return _localAgent.getSessionMessages(uuid);
    }
    final result = await _rpc(AgentRpcConfig.methodGetSessionMessages, {
      'employeeId': employeeId,
    });
    return (result['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// 清空当前会话
  Future<void> clearCurrentSession() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.clearCurrentSession();
    }
    await _rpc(AgentRpcConfig.methodClearSession, {'employeeId': employeeId});
  }

  // ===== 上下文管理 =====

  Future<void> setContext(Map<String, dynamic> contextData) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.setContext(contextData);
    }
    await _rpc(AgentRpcConfig.methodSetContext, {
      'employeeId': employeeId,
      'contextData': contextData,
    });
  }

  Map<String, dynamic>? getCurrentContext() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getCurrentContext();
    }
    return _remoteCache.contextData;
  }

  // ===== 模型管理 =====

  Future<void> setProvider(Map<String, dynamic> providerConfig) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.setProvider(providerConfig);
    }
    await _rpc(AgentRpcConfig.methodSetProvider, {
      'employeeId': employeeId,
      'providerConfig': providerConfig,
    });
  }

  Map<String, dynamic>? getProviderConfig() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getProviderConfig();
    }
    return _remoteCache.providerConfig;
  }

  // ===== 项目管理 =====

  Future<void> setProject(Map<String, dynamic>? projectData) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.setProject(projectData);
    }
    await _rpc(AgentRpcConfig.methodSetProject, {
      'employeeId': employeeId,
      'projectData': projectData,
    });
  }

  String? getCurrentProjectUuid() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getCurrentProjectUuid();
    }
    return _remoteCache.projectUuid;
  }

  // ===== 工具管理 =====

  void registerTool(AgentTool tool) {
    if (isLocalMode && _localAgent != null) {
      _localAgent.registerTool(tool);
    }
  }

  void registerTools(List<AgentTool> tools) {
    if (isLocalMode && _localAgent != null) {
      _localAgent.registerTools(tools);
    }
  }

  void unregisterTool(String name) {
    if (isLocalMode && _localAgent != null) {
      _localAgent.unregisterTool(name);
    }
  }

  List<Map<String, dynamic>> getRegisteredTools() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getRegisteredTools();
    }
    return [];
  }

  // ===== 权限管理 =====

  Future<void> respondToPermission(
    String requestId,
    PermissionDecision decision,
  ) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.respondToPermission(requestId, decision);
    }
    await _rpc(AgentRpcConfig.methodRespondPermission, {
      'employeeId': employeeId,
      'requestId': requestId,
      'decision': decision.name,
    });
  }

  // ===== 状态查询 =====

  AgentStateSnapshot getStateSnapshot() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getStateSnapshot();
    }
    return _remoteCache.snapshot ?? AgentStateSnapshot.idle();
  }

  /// 获取当前状态快照（异步版本，支持远程 RPC）
  Future<AgentStateSnapshot> getStateSnapshotAsync() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getStateSnapshot();
    }
    final result = await _rpc(AgentRpcConfig.methodGetState, {
      'employeeId': employeeId,
    });
    if (result == null) return AgentStateSnapshot.idle();
    return AgentStateSnapshot.fromMap(result as Map<String, dynamic>);
  }

  bool get isSending {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.isSending;
    }
    return _remoteCache.status == AgentStatus.processing ||
        _remoteCache.status == AgentStatus.streaming;
  }

  // ===== 引用计数 =====

  void attach() {
    if (isLocalMode && _localAgent != null) {
      _localAgent.attach();
    }
  }

  void detach() {
    if (isLocalMode && _localAgent != null) {
      _localAgent.detach();
    }
  }

  // ===== 内部方法 =====

  /// RPC 调用封装
  Future<Map<String, dynamic>> _rpc(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_rpcCall == null) {
      throw StateError('Remote RPC callback not configured');
    }
    return _rpcCall(method, params);
  }

  /// 订阅远程事件流
  void _subscribeRemoteEvents(Stream<Map<String, dynamic>> stream) {
    _remoteEventSubscription?.cancel();
    _remoteEventSubscription = stream.listen(
      _onRemoteEvent,
      onError: (error) {
        // 连接错误
      },
      onDone: () {
        // 连接关闭
      },
    );
  }

  /// 处理远程事件
  void _onRemoteEvent(Map<String, dynamic> eventData) {
    final type = eventData['type'] as String?;
    final data = eventData['data'] as Map<String, dynamic>? ?? {};
    final eventEmployeeUuid = eventData['employeeId'] as String?;

    // 只处理与当前 Agent 相关的事件
    if (eventEmployeeUuid != null && eventEmployeeUuid != employeeId) {
      return;
    }

    switch (type) {
      case 'agentStatusChanged':
        final snapshot = AgentStateSnapshot.fromMap(data);
        // 只在状态真正改变时才更新和广播
        if (_remoteCache.status != snapshot.status) {
          _remoteCache.snapshot = snapshot;
          _remoteCache.status = snapshot.status;
          _stateController.add(snapshot);
        }
        break;

      case 'messageStatusChanged':
        // 消息状态变化事件，需要根据消息状态更新 Agent 状态
        final messageStatusStr = data['status'] as String?;
        if (messageStatusStr != null) {
          final messageStatus = AgentMessageStatus.fromString(messageStatusStr);

          // 只有在消息完成、失败、中断或撤回时才更新状态为 idle
          // 并且当前状态不是 idle 时才触发更新
          if ((messageStatus == AgentMessageStatus.completed ||
                  messageStatus == AgentMessageStatus.failed ||
                  messageStatus == AgentMessageStatus.interrupted ||
                  messageStatus == AgentMessageStatus.revoked) &&
              _remoteCache.status != AgentStatus.idle) {
            // 消息处理完成，状态应该变为 idle
            final idleSnapshot = AgentStateSnapshot(
              status: AgentStatus.idle,
              currentProcessingMessageId: null,
              queuedMessageIds: data['queuedMessageIds'] as List<String>? ?? [],
              isStreaming: false,
              queueLength: data['queueLength'] as int? ?? 0,
            );
            _remoteCache.snapshot = idleSnapshot;
            _remoteCache.status = AgentStatus.idle;
            _stateController.add(idleSnapshot);
          } else {
            // 消息正在排队或处理中，或者已经是 idle 状态
            // 保持当前状态，但可能需要更新其他信息
            if (_remoteCache.snapshot != null) {
              _stateController.add(_remoteCache.snapshot!);
            }
          }
        }
        break;

      default:
        break;
    }
  }

  /// 释放资源
  Future<void> dispose() async {
    await _remoteEventSubscription?.cancel();
    await _stateController.close();
  }
}

/// 远程状态缓存
class _RemoteStateCache {
  AgentStatus status = AgentStatus.idle;
  AgentStateSnapshot? snapshot;
  Map<String, dynamic>? contextData;
  Map<String, dynamic>? providerConfig;
  String? projectUuid;

  void clear() {
    status = AgentStatus.idle;
    snapshot = null;
    contextData = null;
    providerConfig = null;
    projectUuid = null;
  }
}
