import 'dart:async';
import 'dart:convert';

import '../agent/adapter/persistent_chat_adapter.dart';
import '../agent/i_agent.dart';
import '../agent/impl/agent_impl.dart';
import '../agent/agent_state.dart';
import '../persistence/persistence.dart';
import 'employee_manager.dart';
import 'session_manager.dart';
import 'message_store_service.dart';
import 'skill_manager.dart';

/// Agent生命周期类型
enum AgentLifecycleType { created, destroyed }

/// Agent生命周期事件
class AgentLifecycleEvent {
  final AgentLifecycleType type;
  final String employeeUuid;
  final IAgent? agent;

  AgentLifecycleEvent({
    required this.type,
    required this.employeeUuid,
    this.agent,
  });
}

/// Agent工厂接口
abstract class AgentFactory {
  /// 创建或获取Agent实例
  ///
  /// [employeeUuid] 员工UUID
  /// [employeeId] 会话UUID，为null则使用最近会话或创建新会话
  /// [autoCreate] 如果Agent不存在是否自动创建
  Future<IAgent> getOrCreateAgent({
    required String employeeUuid,
    String? employeeId,
    bool autoCreate = true,
  });

  /// 获取已存在的Agent（不自动创建）
  IAgent? getAgent(String employeeUuid);

  /// 销毁Agent实例
  Future<void> destroyAgent(String employeeUuid);

  /// 获取所有活跃Agent
  List<MapEntry<String, IAgent>> getActiveAgents();

  /// Agent生命周期事件流
  Stream<AgentLifecycleEvent> get onAgentLifecycle;
}

/// Agent工厂实现
class AgentFactoryImpl implements AgentFactory {
  final Map<String, IAgent> _agents = {};
  final EmployeeManager _employeeManager;
  final SessionManager _sessionManager;
  final MessageStoreService _messageStore;
  final SkillManager _skillManager;

  final _lifecycleController =
      StreamController<AgentLifecycleEvent>.broadcast();

  AgentFactoryImpl({
    required EmployeeManager employeeManager,
    required SessionManager sessionManager,
    required MessageStoreService messageStore,
    required SkillManager skillManager,
  })  : _employeeManager = employeeManager,
       _sessionManager = sessionManager,
       _messageStore = messageStore,
       _skillManager = skillManager;

  @override
  Future<IAgent> getOrCreateAgent({
    required String employeeUuid,
    String? employeeId,
    bool autoCreate = true,
  }) async {
    // 检查是否已存在
    var agent = _agents[employeeUuid];
    if (agent != null) {
      return agent;
    }

    if (!autoCreate) {
      throw StateError('Agent not found: $employeeUuid');
    }

    // 获取员工配置
    final employee = await _employeeManager.getEmployee(employeeUuid);
    if (employee == null) {
      throw StateError('Employee not found: $employeeUuid');
    }

    // 创建PersistentChatAdapter并设置持久化回调
    final chatAdapter = PersistentChatAdapter();
    _setupPersistCallbacks(chatAdapter, employeeUuid);

    // 创建Agent
    agent = AgentImpl(employeeUuid: employeeUuid, chatAdapter: chatAdapter);

    // 初始化Agent
    await agent.initialize(employeeId: employeeId);

    // 设置Provider配置
    if (employee.provider != null && employee.provider!.isNotEmpty) {
      final providerConfig = <String, dynamic>{'type': employee.provider};
      if (employee.model != null) {
        providerConfig['model'] = employee.model;
      }
      if (employee.apiKey != null) {
        providerConfig['apiKey'] = employee.apiKey;
      }
      if (employee.apiBaseUrl != null) {
        providerConfig['baseUrl'] = employee.apiBaseUrl;
      }
      if (employee.modelConfig != null) {
        try {
          providerConfig['modelConfig'] = jsonDecode(employee.modelConfig!);
        } catch (_) {}
      }
      await agent.setProvider(providerConfig);
    }

    // 设置System Prompt
    if (employee.systemPrompt != null && employee.systemPrompt!.isNotEmpty) {
      await agent.setContext({'systemPrompt': employee.systemPrompt});
    }

    _agents[employeeUuid] = agent;
    _notifyLifecycle(AgentLifecycleType.created, agent);

    return agent;
  }

  void _setupPersistCallbacks(
    PersistentChatAdapter adapter,
    String employeeUuid,
  ) {
    // 持久化会话回调
    adapter.persistSession = (session) async {
      var existingSession = await _sessionManager.getSession(employeeUuid);
      if (existingSession == null) {
        // Session应该已由getOrCreateSession创建
        existingSession = await _sessionManager.getOrCreateSession(
          employeeUuid,
        );
      }

      // 更新标题
      final title = session['title'] as String?;
      if (title != null && title != existingSession.title) {
        existingSession = existingSession.copyWith(
          title: title,
          updateTime: DateTime.now(),
        );
        await _sessionManager.save(existingSession);
      }
      // 注意：设备配置更新由DeviceClient负责，这里只更新标题
    };

    // 持久化消息回调
    adapter.persistMessage = (message) async {
      final entity = _mapToMessageEntity(message);
      await _messageStore.addMessage(entity);
    };

    // 加载会话回调
    adapter.loadSession = (employeeId) async {
      final session = await _sessionManager.getSession(employeeUuid);
      if (session == null) return null;

      // 返回基本会话数据（不包含设备特定配置）
      return {
        'uuid': employeeUuid, // 兼容旧格式
        'employeeUuid': session.employeeUuid,
        'title': session.title,
        // 设备配置由DeviceClient负责
      };
    };

    // 加载消息回调
    adapter.loadMessages = (employeeId) async {
      final messages = await _messageStore.getMessages(employeeId);
      return messages.map((m) => m.toMap()).toList();
    };

    // 更新消息状态回调
    adapter.updateMessageStatusCallback = (messageId, status, {error}) async {
      await _messageStore.updateMessageStatus(
        messageId,
        status.name,
        error: error,
      );
    };
  }

  AiEmployeeMessageEntity _mapToMessageEntity(Map<String, dynamic> message) {
    return AiEmployeeMessageEntity(
      uuid: message['id'] as String? ?? '',
      employeeId: message['employeeId'] as String? ?? '',
      role: message['role'] as String? ?? 'user',
      type: message['type'] as String? ?? 'text',
      content: message['content'] as String?,
      toolCallId: message['toolCallId'] as String?,
      toolName: message['toolName'] as String?,
      toolArguments: message['toolArguments'] as String?,
      toolResult: message['toolResult'] as String?,
      toolCalls: message['toolCalls'] != null
          ? jsonEncode(message['toolCalls'])
          : null,
      processingStatus: message['processingStatus'] as String? ?? 'none',
      processingError: message['processingError'] as String?,
      createTime: message['createTime'] is DateTime
          ? message['createTime'] as DateTime
          : DateTime.now(),
      updateTime: DateTime.now(),
    );
  }

  @override
  IAgent? getAgent(String employeeUuid) {
    return _agents[employeeUuid];
  }

  @override
  Future<void> destroyAgent(String employeeUuid) async {
    final agent = _agents.remove(employeeUuid);
    if (agent != null) {
      await agent.dispose();
      _notifyLifecycle(AgentLifecycleType.destroyed, agent);
    }
  }

  @override
  List<MapEntry<String, IAgent>> getActiveAgents() {
    return _agents.entries.toList();
  }

  @override
  Stream<AgentLifecycleEvent> get onAgentLifecycle =>
      _lifecycleController.stream;

  void _notifyLifecycle(AgentLifecycleType type, IAgent agent) {
    _lifecycleController.add(
      AgentLifecycleEvent(
        type: type,
        employeeUuid: agent.employeeUuid,
        agent: agent,
      ),
    );
  }

  /// 销毁所有Agent
  Future<void> destroyAll() async {
    for (final employeeUuid in _agents.keys.toList()) {
      await destroyAgent(employeeUuid);
    }
  }

  /// 释放资源
  void dispose() {
    _lifecycleController.close();
  }
}
