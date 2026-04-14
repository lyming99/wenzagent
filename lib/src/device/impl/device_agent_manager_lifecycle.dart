part of 'device_agent_manager.dart';

// ===== 生命周期 / 配置注入 =====

extension DeviceAgentManagerLifecycle on DeviceAgentManager {
  /// 热更新已运行 Agent 的权限配置
  void reloadPermissionConfig(String employeeId, AiEmployeeEntity employee) {
    final agent = _localAgents[employeeId];
    if (agent == null) return;

    final impl = agent as AgentImpl;
    final manager = impl.permissionManager;

    if (employee.permissionConfig != null &&
        employee.permissionConfig!.isNotEmpty) {
      final config = PermissionConfig.fromJsonString(
        employee.permissionConfig!,
      );
      manager.configure(config);
      DeviceAgentManager._log.info(
        'Permission config reloaded for $employeeId'
        ' (${config.whitelist.length} whitelist, ${config.blacklist.length} blacklist rules)',
      );
    }
  }

  void _injectPermissionConfig(IAgent agent, AiEmployeeEntity employee) {
    final impl = agent as AgentImpl;
    final manager = impl.permissionManager;

    if (employee.permissionConfig != null &&
        employee.permissionConfig!.isNotEmpty) {
      final config = PermissionConfig.fromJsonString(
        employee.permissionConfig!,
      );
      manager.configure(config);
      DeviceAgentManager._log.info(
        'Permission config injected for ${employee.uuid}'
        ' (${config.whitelist.length} whitelist, ${config.blacklist.length} blacklist rules)',
      );
    }

    manager.onConfigChanged = (newConfig) async {
      try {
        final updatedEmployee = await _employeeManager.getEmployee(
          employee.uuid,
        );
        if (updatedEmployee != null) {
          final saved = updatedEmployee.copyWith(
            permissionConfig: newConfig.toJsonString(),
            updateTime: DateTime.now(),
          );
          await _employeeManager.updateEmployee(saved);
          DeviceAgentManager._log.info(
            'Permission config saved for ${employee.uuid}',
          );
        }
      } catch (e) {
        DeviceAgentManager._log.debug('Failed to save permission config: $e');
      }
    };
  }

  void _injectScheduleTaskCallbacks(IAgent agent, String agentEmployeeId) {
    final impl = agent as AgentImpl;
    final scheduleTool = impl.toolRegistry.getTool('schedule_task');
    if (scheduleTool is! ScheduleTaskTool) return;

    final now = DateTime.now();

    scheduleTool.onCreateTask = (data) async {
      final taskType = data['taskType'] as String? ?? 'reminder';
      final repeatType = data['repeatType'] as String? ?? 'recurring';
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
      final tasks = await _scheduledTaskManager.getTasks(
        employeeId: employeeId ?? agentEmployeeId,
      );
      return tasks
          .map(
            (t) => <String, dynamic>{
              'taskId': t.uuid,
              'name': t.name,
              'schedule': t.scheduleExpression,
              'nextExecutionAt': t.nextExecutionAt?.toIso8601String(),
              'enabled': t.isEnabled,
            },
          )
          .toList();
    };

    scheduleTool.onCancelTask = (taskId) async {
      try {
        await _scheduledTaskManager.deleteTask(taskId);
        return true;
      } catch (e) {
        DeviceAgentManager._log.debug('cancelTask failed: $e');
        return false;
      }
    };

    DeviceAgentManager._log.info(
      'ScheduleTaskTool callbacks injected for $agentEmployeeId',
    );
  }

  static String _parseScheduleType(String expression) {
    if (expression.contains(' ') || expression.contains('*')) {
      return 'cron';
    }
    return 'interval';
  }

  void _setupAdapter(LlmChatAdapter adapter, String employeeId) {
    adapter.configurePersistence(
      messageStore: _messageStoreService,
      deviceId: _deviceId,
    );
    adapter.deviceId = _deviceId;

    adapter.shouldMarkAsRead = (empId) =>
        _notificationManager.currentOpenSession?.employeeId == empId;

    // 会话清空回调：设置 clearSeq = lastSeq + 清理通知
    adapter.onSessionCleared = (empId, maxSeq) async {
      if (maxSeq > 0) {
        final watermarkStore = SyncWatermarkStore(deviceId: _deviceId);
        watermarkStore.setClearSeq(empId, maxSeq, deviceId: _deviceId);
        watermarkStore.resetLastSeq(empId, maxSeq, deviceId: _deviceId);
      }
      _stateHolder.notificationHub.markAllAsRead(employeeId: empId);
      _notificationManager.clearLatestMessageCache(empId);
    };

    // Provider 配置变更回调
    adapter.onProviderConfigChanged = (providerConfig) async {
      await _sessionManager.updateDeviceConfig(
        employeeId,
        _deviceId,
        providerConfig: jsonEncode(providerConfig),
      );
    };
  }
}
