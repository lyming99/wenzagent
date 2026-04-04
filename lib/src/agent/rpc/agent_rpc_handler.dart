import '../i_agent.dart';
import '../i_agent_manager.dart';
import 'agent_rpc_config.dart';

/// Agent RPC 请求处理结果
class AgentRpcResult {
  final bool success;
  final Map<String, dynamic>? data;
  final int? errorCode;
  final String? errorMessage;

  const AgentRpcResult.success([this.data])
      : success = true,
        errorCode = null,
        errorMessage = null;

  const AgentRpcResult.error(this.errorCode, this.errorMessage)
      : success = false,
        data = null;

  Map<String, dynamic> toMap() {
    if (success) {
      return {
        'success': true,
        'result': data ?? {},
      };
    }
    return {
      'success': false,
      'error': {
        'code': errorCode,
        'message': errorMessage,
      },
    };
  }
}

/// Agent RPC 处理器（纯 Dart）
///
/// 接收 RPC 请求，路由到对应的 [IAgentManager] / [IAgent] 方法。
class AgentRpcHandler {
  final IAgentManager _agentManager;

  AgentRpcHandler({required IAgentManager agentManager})
      : _agentManager = agentManager;

  /// 处理 RPC 请求
  Future<AgentRpcResult> handleRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      switch (method) {
        // ===== 对话操作 =====
        case AgentRpcConfig.methodSendMessage:
          return await _handleSendMessage(params);
        case AgentRpcConfig.methodInterrupt:
          return await _handleInterrupt(params);

        // ===== 会话管理 =====
        case AgentRpcConfig.methodGetSessionList:
          return await _handleGetSessionList(params);
        case AgentRpcConfig.methodGetSessionMessages:
          return await _handleGetSessionMessages(params);
        case AgentRpcConfig.methodCreateSession:
          return await _handleCreateSession(params);
        case AgentRpcConfig.methodSwitchSession:
          return await _handleSwitchSession(params);

        // ===== 上下文管理 =====
        case AgentRpcConfig.methodSetContext:
          return await _handleSetContext(params);
        case AgentRpcConfig.methodGetContext:
          return await _handleGetContext(params);

        // ===== 模型管理 =====
        case AgentRpcConfig.methodSetProvider:
          return await _handleSetProvider(params);
        case AgentRpcConfig.methodGetProvider:
          return await _handleGetProvider(params);

        // ===== 项目管理 =====
        case AgentRpcConfig.methodSetProject:
          return await _handleSetProject(params);
        case AgentRpcConfig.methodGetProjectUuid:
          return await _handleGetProjectUuid(params);

        // ===== 状态查询 =====
        case AgentRpcConfig.methodGetState:
          return await _handleGetState(params);

        // ===== 生命周期 =====
        case AgentRpcConfig.methodGetOrCreateAgent:
          return await _handleGetOrCreate(params);
        case AgentRpcConfig.methodGetEmployeeList:
          return await _handleGetEmployeeList();
        case AgentRpcConfig.methodGetActiveSummaries:
          return _handleGetActiveSummaries();
        case AgentRpcConfig.methodGetMemoryStats:
          return _handleGetMemoryStats();

        // ===== Ping =====
        case AgentRpcConfig.methodPing:
          return const AgentRpcResult.success({'alive': true});

        default:
          return const AgentRpcResult.error(
            AgentRpcConfig.errorInvalidParams,
            'Unknown method',
          );
      }
    } catch (e) {
      return AgentRpcResult.error(
        AgentRpcConfig.errorInternal,
        e.toString(),
      );
    }
  }

  // ===== 对话操作处理 =====

  Future<AgentRpcResult> _handleSendMessage(Map<String, dynamic> params) async {
    final agent = await _getAgent(params);
    if (agent == null) return _agentNotFound();

    final messageData =
        params['messageData'] as Map<String, dynamic>? ?? {};
    final messageId = await agent.sendMessage(messageData);
    return AgentRpcResult.success({'messageId': messageId});
  }

  Future<AgentRpcResult> _handleInterrupt(Map<String, dynamic> params) async {
    final agent = await _getAgent(params);
    if (agent == null) return _agentNotFound();

    await agent.interrupt();
    return const AgentRpcResult.success();
  }

  // ===== 会话管理处理 =====

  Future<AgentRpcResult> _handleGetSessionList(
      Map<String, dynamic> params) async {
    final agent = await _getAgent(params);
    if (agent == null) return _agentNotFound();

    final sessions = await agent.getSessionList();
    return AgentRpcResult.success({'sessions': sessions});
  }

  Future<AgentRpcResult> _handleGetSessionMessages(
      Map<String, dynamic> params) async {
    final sessionUuid = params['sessionUuid'] as String?;
    if (sessionUuid == null) {
      return _invalidParams('sessionUuid is required');
    }

    final agent = await _getAgent(params);
    if (agent != null) {
      final messages = await agent.getSessionMessages(sessionUuid);
      return AgentRpcResult.success({'messages': messages});
    }

    final messages = await _agentManager.getSessionMessages(sessionUuid);
    return AgentRpcResult.success({'messages': messages});
  }

  Future<AgentRpcResult> _handleCreateSession(
      Map<String, dynamic> params) async {
    final agent = await _getAgent(params);
    if (agent == null) return _agentNotFound();

    final sessionUuid = await agent.createSession();
    return AgentRpcResult.success({'sessionUuid': sessionUuid});
  }

  Future<AgentRpcResult> _handleSwitchSession(
      Map<String, dynamic> params) async {
    final agent = await _getAgent(params);
    if (agent == null) return _agentNotFound();

    final sessionUuid = params['sessionUuid'] as String?;
    if (sessionUuid == null) {
      return _invalidParams('sessionUuid is required');
    }

    await agent.switchSession(sessionUuid);
    return const AgentRpcResult.success();
  }

  // ===== 上下文管理处理 =====

  Future<AgentRpcResult> _handleSetContext(Map<String, dynamic> params) async {
    final agent = await _getAgent(params);
    if (agent == null) return _agentNotFound();

    final contextData =
        params['contextData'] as Map<String, dynamic>? ?? {};
    await agent.setContext(contextData);
    return const AgentRpcResult.success();
  }

  Future<AgentRpcResult> _handleGetContext(Map<String, dynamic> params) async {
    final agent = await _getAgent(params);
    if (agent == null) return _agentNotFound();

    final context = agent.getCurrentContext();
    return AgentRpcResult.success({'context': context});
  }

  // ===== 模型管理处理 =====

  Future<AgentRpcResult> _handleSetProvider(
      Map<String, dynamic> params) async {
    final agent = await _getAgent(params);
    if (agent == null) return _agentNotFound();

    final providerConfig =
        params['providerConfig'] as Map<String, dynamic>? ?? {};
    await agent.setProvider(providerConfig);
    return const AgentRpcResult.success();
  }

  Future<AgentRpcResult> _handleGetProvider(
      Map<String, dynamic> params) async {
    final agent = await _getAgent(params);
    if (agent == null) return _agentNotFound();

    final config = agent.getProviderConfig();
    return AgentRpcResult.success({'providerConfig': config});
  }

  // ===== 项目管理处理 =====

  Future<AgentRpcResult> _handleSetProject(Map<String, dynamic> params) async {
    final agent = await _getAgent(params);
    if (agent == null) return _agentNotFound();

    final projectData =
        params['projectData'] as Map<String, dynamic>?;
    await agent.setProject(projectData);
    return const AgentRpcResult.success();
  }

  Future<AgentRpcResult> _handleGetProjectUuid(
      Map<String, dynamic> params) async {
    final agent = await _getAgent(params);
    if (agent == null) return _agentNotFound();

    final uuid = agent.getCurrentProjectUuid();
    return AgentRpcResult.success({'projectUuid': uuid});
  }

  // ===== 状态查询处理 =====

  Future<AgentRpcResult> _handleGetState(Map<String, dynamic> params) async {
    final agent = await _getAgent(params);
    if (agent == null) return _agentNotFound();

    final snapshot = agent.getStateSnapshot();
    return AgentRpcResult.success(snapshot.toMap());
  }

  // ===== 生命周期处理 =====

  Future<AgentRpcResult> _handleGetOrCreate(Map<String, dynamic> params) async {
    final employeeUuid = params['employeeUuid'] as String?;
    if (employeeUuid == null) {
      return _invalidParams('employeeUuid is required');
    }

    final sessionUuid = params['sessionUuid'] as String?;
    final agent = await _agentManager.getOrCreate(
      employeeUuid: employeeUuid,
      sessionUuid: sessionUuid,
    );

    return AgentRpcResult.success({
      'employeeUuid': agent.employeeUuid,
      'sessionUuid': agent.currentSessionUuid,
      'status': agent.status.name,
    });
  }

  Future<AgentRpcResult> _handleGetEmployeeList() async {
    final list = await _agentManager.getEmployeeList();
    return AgentRpcResult.success({'employees': list});
  }

  AgentRpcResult _handleGetActiveSummaries() {
    final summaries = _agentManager.getActiveSummaries();
    return AgentRpcResult.success({
      'summaries': summaries.map((s) => s.toMap()).toList(),
    });
  }

  AgentRpcResult _handleGetMemoryStats() {
    final stats = _agentManager.getMemoryStats();
    return AgentRpcResult.success(stats);
  }

  // ===== 工具方法 =====

  Future<IAgent?> _getAgent(Map<String, dynamic> params) async {
    final employeeUuid = params['employeeUuid'] as String?;
    if (employeeUuid == null) return null;

    final existing = _agentManager.get(employeeUuid);
    if (existing != null) return existing;

    final sessionUuid = params['sessionUuid'] as String?;
    try {
      return await _agentManager.getOrCreate(
        employeeUuid: employeeUuid,
        sessionUuid: sessionUuid,
      );
    } catch (_) {
      return null;
    }
  }

  AgentRpcResult _agentNotFound() {
    return const AgentRpcResult.error(
      AgentRpcConfig.errorAgentNotFound,
      'Agent not found',
    );
  }

  AgentRpcResult _invalidParams(String message) {
    return AgentRpcResult.error(
      AgentRpcConfig.errorInvalidParams,
      message,
    );
  }
}
