import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../agent/adapter/llm_chat_adapter.dart';
import '../agent/agent_state.dart';
import '../agent/entity/entity.dart';
import '../agent/i_agent.dart';
import '../agent/impl/agent_impl.dart';
import '../agent/tool/builtin/schedule_task_tool.dart';
import '../agent/tool/builtin/spawn_sub_agent_tool.dart';
import '../agent/tool/permission_rule.dart';
import '../persistence/persistence.dart';
import '../utils/logger.dart';
import 'employee_manager.dart';
import 'message_store_service.dart';
import 'skill_manager.dart';
import 'scheduled_task_manager.dart';
import 'sub_agent_executor.dart';
import 'entity/agent_runtime_config.dart';

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
  static final _log = Logger('AgentFactory');

  final Map<String, IAgent> _agents = {};
  final EmployeeManager _employeeManager;
  final MessageStoreService _messageStore;
  final ScheduledTaskManager? _scheduledTaskManager;

  final _lifecycleController =
      StreamController<AgentLifecycleEvent>.broadcast();

  AgentFactoryImpl({
    required EmployeeManager employeeManager,
    required MessageStoreService messageStore,
    required SkillManager skillManager,
    ScheduledTaskManager? scheduledTaskManager,
  })  : _employeeManager = employeeManager,
       _messageStore = messageStore,
       _scheduledTaskManager = scheduledTaskManager;

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

    final deviceId = employee.currentDeviceId;
    if (deviceId == null || deviceId.isEmpty) {
      throw StateError('员工 $employeeId 的 currentDeviceId 为空，无法创建 Agent');
    }

    // 创建LlmChatAdapter并配置持久化
    final chatAdapter = LlmChatAdapter();
    chatAdapter.configurePersistence(
      messageStore: _messageStore,
      deviceId: deviceId,
    );

    // 创建Agent
    agent = AgentImpl(employeeId: employeeId, deviceId: deviceId, chatAdapter: chatAdapter);

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
        } catch (e) {
          _log.debug('parse modelConfig failed, skipping: $e');
        }
      }
      final providerConfig = ProviderConfig.fromMap(providerConfigMap);
      await agent.setProvider(providerConfig);
    }

    // 设置System Prompt
    if (employee.systemPrompt != null && employee.systemPrompt!.isNotEmpty) {
      await agent.setContext({'systemPrompt': employee.systemPrompt});
    }

    // 注入 ScheduleTaskTool 回调
    _injectScheduleTaskCallbacks(agent, employeeId);

    // 注入 SpawnSubAgentTool 回调
    _injectSpawnSubAgentCallbacks(agent, employeeId);

    // 注入权限配置（从员工实体的 permissionConfig 字段）
    _injectPermissionConfig(agent, employee);

    _agents[employeeId] = agent;
    _notifyLifecycle(AgentLifecycleType.created, agent);

    return agent;
  }

  /// 将 ScheduledTaskManager 的回调注入到 Agent 的 ScheduleTaskTool
  void _injectScheduleTaskCallbacks(IAgent agent, String employeeId) {
    if (_scheduledTaskManager == null) return;

    // 找到 Agent 内部的 ScheduleTaskTool 并注入回调
    final impl = agent as AgentImpl;
    final scheduleTool = impl.toolRegistry.getTool('schedule_task');
    if (scheduleTool is! ScheduleTaskTool) return;

    final agentEmployeeId = employeeId; // 避免闭包中 shadow

    final now = DateTime.now();

    scheduleTool.onCreateTask = (data) async {
      final taskType = data['taskType'] as String? ?? 'reminder';
      final repeatType = data['repeatType'] as String? ?? 'recurring';

      // 解析 schedule 表达式判断调度类型
      final scheduleExpr = data['schedule'] as String;
      final scheduleType = _parseScheduleType(scheduleExpr);

      final entity = AiScheduledTaskEntity(
        uuid: const Uuid().v4(),
        employeeId: agentEmployeeId,
        name: data['name'] as String? ?? 'Scheduled task',
        scheduleType: scheduleType,
        scheduleExpression: scheduleExpr,
        repeatType: repeatType,
        taskType: taskType,
        taskConfig: jsonEncode({
          'action': 'sendMessage',
          'message': data['message'],
        }),
        createTime: now,
        updateTime: now,
      );
      final created = await _scheduledTaskManager.createTask(entity);
      return {
        'taskId': created.uuid,
        'name': created.name,
        'taskType': created.taskType,
        'schedule': created.scheduleExpression,
        'nextExecutionAt': created.nextExecutionAt?.toIso8601String(),
      };
    };

    scheduleTool.onListTasks = ({String? employeeId}) async {
      final tasks = await _scheduledTaskManager
          .getTasks(employeeId: employeeId ?? agentEmployeeId);
      return tasks.map((t) => <String, dynamic>{
        'taskId': t.uuid,
        'name': t.name,
        'schedule': t.scheduleExpression,
        'nextExecutionAt': t.nextExecutionAt?.toIso8601String(),
        'enabled': t.isEnabled,
      }).toList();
    };

    scheduleTool.onCancelTask = (taskId) async {
      try {
        await _scheduledTaskManager.deleteTask(taskId);
        return true;
      } catch (e) {
        _log.debug('cancel scheduled task failed, using fallback: $e');
        return false;
      }
    };

    _log.debug('ScheduleTaskTool callbacks injected for $agentEmployeeId');
  }

  /// 将 SubAgentExecutor 的回调注入到 Agent 的 SpawnSubAgentTool
  void _injectSpawnSubAgentCallbacks(IAgent agent, String employeeId) {
    final impl = agent as AgentImpl;
    final spawnTool = impl.toolRegistry.getTool('spawn_sub_agent');
    if (spawnTool is! SpawnSubAgentTool) return;

    final agentEmployeeId = employeeId;

    // 创建 SubAgentExecutor 并注入回调
    final executor = SubAgentExecutor();
    executor.getAgentConfig = (eid) async {
      final a = _agents[eid];
      if (a == null) return null;

      final config = AgentRuntimeConfig(
        providerConfig: a.getProviderConfig()?.toMap(),
        systemPrompt: a.getCurrentContext()?['systemPrompt'] as String?,
        projectContext: null,
      );

      return config;
    };

    // 权限请求转发：通过主 Agent 的 PermissionManager 转发
    executor.requestPermission = (request) async {
      final manager = impl.permissionManager;
      // 主 Agent 的 onPermissionRequest 回调会将请求广播到用户
      if (manager.onPermissionRequest == null) {
        return PermissionDecision.deny;
      }
      return manager.onPermissionRequest!(request);
    };

    // 文件读取回调
    executor.readFileContent = (filePath) async {
      try {
        final file = await File(filePath).readAsString();
        return file;
      } catch (e) {
        return null;
      }
    };

    spawnTool.executor = executor;
    spawnTool.employeeId = agentEmployeeId;
    spawnTool.getAvailableTools = () {
      return impl.toolRegistry.tools;
    };
    spawnTool.readFileContent = executor.readFileContent;

    _log.debug('SpawnSubAgentTool callbacks injected for $agentEmployeeId');
  }

  /// 注入权限配置到 Agent 的 PermissionManager
  void _injectPermissionConfig(IAgent agent, AiEmployeeEntity employee) {
    final impl = agent as AgentImpl;
    final manager = impl.permissionManager;

    // 从员工实体的 permissionConfig JSON 解析并注入
    if (employee.permissionConfig != null &&
        employee.permissionConfig!.isNotEmpty) {
      final config =
          PermissionConfig.fromJsonString(employee.permissionConfig!);
      manager.configure(config);
      _log.debug('Permission config injected for ${employee.uuid}'
          ' (${config.whitelist.length} whitelist, ${config.blacklist.length} blacklist rules)');
    }

    // 监听配置变更，自动持久化回员工实体
    manager.onConfigChanged = (newConfig) async {
      try {
        final updatedEmployee = await _employeeManager.getEmployee(employee.uuid);
        if (updatedEmployee != null) {
          final saved = updatedEmployee.copyWith(
            permissionConfig: newConfig.toJsonString(),
            updateTime: DateTime.now(),
          );
          await _employeeManager.updateEmployee(saved);
          _log.debug('Permission config saved for ${employee.uuid}');
        }
      } catch (e) {
        _log.error('Failed to save permission config', e);
      }
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

  /// 根据 schedule 表达式判断调度类型
  ///
  /// 包含空格或星号 → cron，否则 → interval
  static String _parseScheduleType(String expression) {
    if (expression.contains(' ') || expression.contains('*')) {
      return 'cron';
    }
    return 'interval';
  }
}
