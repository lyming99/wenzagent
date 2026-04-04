import 'dart:async';

import 'package:wenzagent/wenzagent.dart';

/// 远程 Agent 客户端
///
/// 通过 RPC 远程访问 Agent 服务。
/// 支持对话、会话管理、状态订阅等功能。
class AgentClient {
  final Future<Map<String, dynamic>> Function(String method, Map<String, dynamic> params) _rpcCall;
  final Stream<Map<String, dynamic>>? _eventStream;

  final _stateController = StreamController<AgentStateSnapshot>.broadcast();
  StreamSubscription? _eventSubscription;

  String? _currentEmployeeUuid;
  String? _currentSessionUuid;

  AgentClient({
    required Future<Map<String, dynamic>> Function(String method, Map<String, dynamic> params) rpcCall,
    Stream<Map<String, dynamic>>? eventStream,
  })  : _rpcCall = rpcCall,
        _eventStream = eventStream {
    _subscribeEvents();
  }

  /// 当前员工UUID
  String? get currentEmployeeUuid => _currentEmployeeUuid;

  /// 当前会话UUID
  String? get currentSessionUuid => _currentSessionUuid;

  /// 状态变更流
  Stream<AgentStateSnapshot> get onStateChanged => _stateController.stream;

  void _subscribeEvents() {
    if (_eventStream == null) return;

    _eventSubscription = _eventStream.listen((event) {
      final type = event['type'] as String?;
      final data = event['data'] as Map<String, dynamic>?;

      if (type == 'agentStateChanged' && data != null) {
        try {
          final snapshot = AgentStateSnapshot.fromMap(data);
          _stateController.add(snapshot);
        } catch (_) {}
      }
    });
  }

  /// 创建或获取 Agent
  Future<Map<String, dynamic>> getOrCreateAgent({
    required String employeeUuid,
    String? sessionUuid,
  }) async {
    final result = await _rpcCall(
      AgentRpcConfig.methodGetOrCreateAgent,
      {
        'employeeUuid': employeeUuid,
        if (sessionUuid != null) 'sessionUuid': sessionUuid,
      },
    );

    _currentEmployeeUuid = employeeUuid;
    _currentSessionUuid = result['sessionUuid'] as String?;

    return result;
  }

  /// 发送消息
  Future<String> sendMessage({
    required String content,
    String? employeeUuid,
    String? sessionUuid,
  }) async {
    final empUuid = employeeUuid ?? _currentEmployeeUuid;
    if (empUuid == null) {
      throw Exception('employeeUuid is required');
    }

    final result = await _rpcCall(
      AgentRpcConfig.methodSendMessage,
      {
        'employeeUuid': empUuid,
        if (sessionUuid != null) 'sessionUuid': sessionUuid,
        'messageData': {
          'content': content,
          if (sessionUuid != null) 'sessionUuid': sessionUuid,
        },
      },
    );

    return result['messageId'] as String;
  }

  /// 中断当前处理
  Future<void> interrupt({String? employeeUuid}) async {
    final empUuid = employeeUuid ?? _currentEmployeeUuid;
    if (empUuid == null) {
      throw Exception('employeeUuid is required');
    }

    await _rpcCall(AgentRpcConfig.methodInterrupt, {
      'employeeUuid': empUuid,
    });
  }

  /// 获取会话列表
  Future<List<Map<String, dynamic>>> getSessionList({String? employeeUuid}) async {
    final empUuid = employeeUuid ?? _currentEmployeeUuid;
    if (empUuid == null) {
      throw Exception('employeeUuid is required');
    }

    final result = await _rpcCall(AgentRpcConfig.methodGetSessionList, {
      'employeeUuid': empUuid,
    });

    return (result['sessions'] as List).cast<Map<String, dynamic>>();
  }

  /// 创建新会话
  Future<String> createSession({String? employeeUuid}) async {
    final empUuid = employeeUuid ?? _currentEmployeeUuid;
    if (empUuid == null) {
      throw Exception('employeeUuid is required');
    }

    final result = await _rpcCall(AgentRpcConfig.methodCreateSession, {
      'employeeUuid': empUuid,
    });

    _currentSessionUuid = result['sessionUuid'] as String;
    return _currentSessionUuid!;
  }

  /// 切换会话
  Future<void> switchSession({
    required String sessionUuid,
    String? employeeUuid,
  }) async {
    final empUuid = employeeUuid ?? _currentEmployeeUuid;
    if (empUuid == null) {
      throw Exception('employeeUuid is required');
    }

    await _rpcCall(AgentRpcConfig.methodSwitchSession, {
      'employeeUuid': empUuid,
      'sessionUuid': sessionUuid,
    });

    _currentSessionUuid = sessionUuid;
  }

  /// 获取会话消息
  Future<List<Map<String, dynamic>>> getSessionMessages({
    required String sessionUuid,
    String? employeeUuid,
  }) async {
    final result = await _rpcCall(AgentRpcConfig.methodGetSessionMessages, {
      'sessionUuid': sessionUuid,
      if (employeeUuid != null) 'employeeUuid': employeeUuid,
    });

    return (result['messages'] as List).cast<Map<String, dynamic>>();
  }

  /// 获取 Agent 状态
  Future<AgentStateSnapshot> getState({String? employeeUuid}) async {
    final empUuid = employeeUuid ?? _currentEmployeeUuid;
    if (empUuid == null) {
      throw Exception('employeeUuid is required');
    }

    final result = await _rpcCall(AgentRpcConfig.methodGetState, {
      'employeeUuid': empUuid,
    });

    return AgentStateSnapshot.fromMap(result);
  }

  /// 设置上下文
  Future<void> setContext({
    required Map<String, dynamic> contextData,
    String? employeeUuid,
  }) async {
    final empUuid = employeeUuid ?? _currentEmployeeUuid;
    if (empUuid == null) {
      throw Exception('employeeUuid is required');
    }

    await _rpcCall(AgentRpcConfig.methodSetContext, {
      'employeeUuid': empUuid,
      'contextData': contextData,
    });
  }

  /// 获取上下文
  Future<Map<String, dynamic>?> getContext({String? employeeUuid}) async {
    final empUuid = employeeUuid ?? _currentEmployeeUuid;
    if (empUuid == null) {
      throw Exception('employeeUuid is required');
    }

    final result = await _rpcCall(AgentRpcConfig.methodGetContext, {
      'employeeUuid': empUuid,
    });

    return result['context'] as Map<String, dynamic>?;
  }

  /// 获取活跃 Agent 列表
  Future<List<Map<String, dynamic>>> getActiveSummaries() async {
    final result = await _rpcCall(AgentRpcConfig.methodGetActiveSummaries, {});
    return (result['summaries'] as List).cast<Map<String, dynamic>>();
  }

  /// 释放资源
  Future<void> dispose() async {
    await _eventSubscription?.cancel();
    await _stateController.close();
  }
}
