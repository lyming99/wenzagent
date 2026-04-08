import 'dart:async';
import 'dart:convert';

import '../agent/adapter/persistent_chat_adapter.dart';
import '../agent/entity/entity.dart';
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
  final String employeeId;
  final IAgent? agent;

  AgentLifecycleEvent({
    required this.type,
    required this.employeeId,
    this.agent,
  });
}

/// Agent工厂接口
abstract class AgentFactory {
  /// 创建或获取Agent实例
  ///
  /// [employeeId] 员工ID
  /// [sessionId] 会话ID，为null则使用最近会话或创建新会话
  /// [autoCreate] 如果Agent不存在是否自动创建
  Future<IAgent> getOrCreateAgent({
    required String employeeId,
    String? sessionId,
    bool autoCreate = true,
  });

  /// 获取已存在的Agent（不自动创建）
  IAgent? getAgent(String employeeId);

  /// 销毁Agent实例
  Future<void> destroyAgent(String employeeId);

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
    required String employeeId,
    String? sessionId,
    bool autoCreate = true,
  }) async {
    // 检查是否已存在
    var agent = _agents[employeeId];
    if (agent != null) {
      return agent;
    }

    if (!autoCreate) {
      throw StateError('Agent not found: $employeeId');
    }

    // 获取员工配置
    final employee = await _employeeManager.getEmployee(employeeId);
    if (employee == null) {
      throw StateError('Employee not found: $employeeId');
    }

    // 创建PersistentChatAdapter并设置持久化回调
    final chatAdapter = PersistentChatAdapter();
    _setupPersistCallbacks(chatAdapter, employeeId);

    // 创建Agent
    agent = AgentImpl(employeeId: employeeId, chatAdapter: chatAdapter);

    // 初始化Agent
    await agent.initialize(employeeId: employeeId);

    // 设置Provider配置
    if (employee.provider != null && employee.provider!.isNotEmpty) {
      final providerConfigMap = <String, dynamic>{
        'provider': employee.provider,
      };
      if (employee.model != null) {
        providerConfigMap['model'] = employee.model;
      }
      if (employee.apiKey != null) {
        providerConfigMap['apiKey'] = employee.apiKey;
      }
      if (employee.apiBaseUrl != null) {
        providerConfigMap['baseUrl'] = employee.apiBaseUrl;
      }
      if (employee.modelConfig != null) {
        try {
          providerConfigMap['modelConfig'] = jsonDecode(employee.modelConfig!);
        } catch (_) {}
      }
      final providerConfig = ProviderConfig.fromMap(providerConfigMap);
      await agent.setProvider(providerConfig);
    }

    // 设置System Prompt
    if (employee.systemPrompt != null && employee.systemPrompt!.isNotEmpty) {
      await agent.setContext({'systemPrompt': employee.systemPrompt});
    }

    _agents[employeeId] = agent;
    _notifyLifecycle(AgentLifecycleType.created, agent);

    return agent;
  }

  void _setupPersistCallbacks(
    PersistentChatAdapter adapter,
    String employeeId,
  ) {
    // 持久化会话回调
    adapter.persistSession = (session) async {
      var existingSession = await _sessionManager.getSession(employeeId);
      if (existingSession == null) {
        // Session应该已由getOrCreateSession创建
        existingSession = await _sessionManager.getOrCreateSession(
          employeeId,
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
      // 使用 fromMessageMap 将整个 Map 序列化为 JSON 字符串存入 Hive
      final entity = AiEmployeeMessageEntity.fromMessageMap(message);
      await _messageStore.addMessage(entity);
    };

    // 加载会话回调
    adapter.loadSession = (employeeId) async {
      final session = await _sessionManager.getSession(employeeId);
      if (session == null) return null;

      // 返回基本会话数据（不包含设备特定配置）
      return {
        'uuid': employeeId, // 兼容旧格式
        'employeeId': session.employeeId,
        'title': session.title,
        // 设备配置由DeviceClient负责
      };
    };

    // 加载消息回调
    adapter.loadMessages = (employeeId) async {
      final messages = await _messageStore.getMessages(employeeId);
      // 优先从 jsonData 无损还原完整消息数据
      return messages.map((m) => m.toMessageMap()).toList();
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

  @override
  IAgent? getAgent(String employeeId) {
    return _agents[employeeId];
  }

  @override
  Future<void> destroyAgent(String employeeId) async {
    final agent = _agents.remove(employeeId);
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
        employeeId: agent.employeeId,
        agent: agent,
      ),
    );
  }

  /// 销毁所有Agent
  Future<void> destroyAll() async {
    for (final employeeId in _agents.keys.toList()) {
      await destroyAgent(employeeId);
    }
  }

  /// 释放资源
  void dispose() {
    _lifecycleController.close();
  }
}
