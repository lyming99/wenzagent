import 'dart:async';

import '../agent_state.dart';
import '../i_agent.dart';
import '../rpc/agent_rpc_config.dart';

/// RPC 调用回调类型
typedef RpcCall = Future<Map<String, dynamic>> Function(
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
  final String employeeUuid;

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
    required this.employeeUuid,
    required IAgent localAgent,
  })  : isLocalMode = true,
        _localAgent = localAgent,
        _rpcCall = null;

  /// 创建远程模式 Proxy
  AgentProxy.remote({
    required this.employeeUuid,
    required RpcCall rpcCall,
    Stream<Map<String, dynamic>>? remoteEventStream,
  })  : isLocalMode = false,
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

  /// 当前会话UUID
  String? get currentSessionUuid {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.currentSessionUuid;
    }
    return null;
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
    if (isLocalMode && _localAgent != null) {
      return _localAgent.sendMessage(messageData);
    }
    final result = await _rpc(AgentRpcConfig.methodSendMessage, {
      'employeeUuid': employeeUuid,
      'messageData': messageData,
    });
    return result['messageId'] as String? ?? '';
  }

  /// 中断当前处理
  Future<void> interrupt() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.interrupt();
    }
    await _rpc(AgentRpcConfig.methodInterrupt, {'employeeUuid': employeeUuid});
  }

  // ===== 会话管理 =====

  /// 获取会话列表
  Future<List<Map<String, dynamic>>> getSessionList() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getSessionList();
    }
    final result = await _rpc(AgentRpcConfig.methodGetSessionList, {
      'employeeUuid': employeeUuid,
    });
    return (result['sessions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// 获取会话消息
  Future<List<Map<String, dynamic>>> getSessionMessages(
      String sessionUuid) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getSessionMessages(sessionUuid);
    }
    final result = await _rpc(AgentRpcConfig.methodGetSessionMessages, {
      'employeeUuid': employeeUuid,
      'sessionUuid': sessionUuid,
    });
    return (result['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// 创建新会话
  Future<String> createSession() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.createSession();
    }
    final result = await _rpc(AgentRpcConfig.methodCreateSession, {
      'employeeUuid': employeeUuid,
    });
    return result['sessionUuid'] as String? ?? '';
  }

  /// 切换会话
  Future<void> switchSession(String sessionUuid) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.switchSession(sessionUuid);
    }
    await _rpc(AgentRpcConfig.methodSwitchSession, {
      'employeeUuid': employeeUuid,
      'sessionUuid': sessionUuid,
    });
  }

  // ===== 上下文管理 =====

  Future<void> setContext(Map<String, dynamic> contextData) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.setContext(contextData);
    }
    await _rpc(AgentRpcConfig.methodSetContext, {
      'employeeUuid': employeeUuid,
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
      'employeeUuid': employeeUuid,
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
      'employeeUuid': employeeUuid,
      'projectData': projectData,
    });
  }

  String? getCurrentProjectUuid() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getCurrentProjectUuid();
    }
    return _remoteCache.projectUuid;
  }

  // ===== 状态查询 =====

  AgentStateSnapshot getStateSnapshot() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getStateSnapshot();
    }
    return _remoteCache.snapshot ?? AgentStateSnapshot.idle();
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

    switch (type) {
      case 'agentStatusChanged':
        final snapshot = AgentStateSnapshot.fromMap(data);
        _remoteCache.snapshot = snapshot;
        _remoteCache.status = snapshot.status;
        _stateController.add(snapshot);
        break;

      case 'messageStatusChanged':
        _stateController.add(_remoteCache.snapshot ?? AgentStateSnapshot.idle());
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
