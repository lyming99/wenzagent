import '../persistence/persistence.dart';
import '../rpc/remote_call_server.dart';
import '../service/service.dart';
import 'client_session_manager.dart';

/// Host端RPC方法名常量
class HostRpcConfig {
  // ===== 员工管理 =====
  static const String methodGetEmployees = 'hostGetEmployees';
  static const String methodGetEmployee = 'hostGetEmployee';
  static const String methodCreateEmployee = 'hostCreateEmployee';
  static const String methodUpdateEmployee = 'hostUpdateEmployee';
  static const String methodDeleteEmployee = 'hostDeleteEmployee';

  // ===== 会话管理 =====
  static const String methodGetSessions = 'hostGetSessions';
  static const String methodGetSession = 'hostGetSession';
  static const String methodGetOrCreateSession = 'hostGetOrCreateSession';
  static const String methodUpdateDeviceConfig = 'hostUpdateDeviceConfig';
  static const String methodDeleteSession = 'hostDeleteSession';

  // ===== 技能管理 =====
  static const String methodGetSkills = 'hostGetSkills';
  static const String methodCreateSkill = 'hostCreateSkill';
  static const String methodUpdateSkill = 'hostUpdateSkill';
  static const String methodDeleteSkill = 'hostDeleteSkill';

  // ===== 数据同步 =====
  static const String methodSyncEmployees = 'hostSyncEmployees';
  static const String methodSyncSessions = 'hostSyncSessions';
  static const String methodSyncMessages = 'hostSyncMessages';

  // ===== 会话摘要同步 =====
  static const String methodGetSessionSummaries = 'hostGetSessionSummaries';
  static const String methodSyncSessionSummaries = 'hostSyncSessionSummaries';

  // ===== Spec 同步 =====
  static const String methodGetSpecs = 'hostGetSpecs';
  static const String methodSyncSpecs = 'hostSyncSpecs';

  // ===== Todo 同步 =====
  static const String methodGetTodos = 'hostGetTodos';
  static const String methodSyncTodos = 'hostSyncTodos';

  // ===== 技能同步 =====
  static const String methodGetAllSkills = 'hostGetAllSkills';
  static const String methodSyncSkills = 'hostSyncSkills';
  static const String methodGetGlobalSkills = 'hostGetGlobalSkills';
  static const String methodSyncGlobalSkills = 'hostSyncGlobalSkills';

  // ===== 设备管理 =====
  static const String methodGetOnlineDevices = 'getOnlineDevices';
  static const String methodGetDeviceInfo = 'getDeviceInfo';
  static const String methodUpdateDeviceInfo = 'updateDeviceInfo';

  // ===== 定时任务管理 =====
  static const String methodGetScheduledTasks = 'hostGetScheduledTasks';
  static const String methodGetScheduledTask = 'hostGetScheduledTask';
  static const String methodCreateScheduledTask = 'hostCreateScheduledTask';
  static const String methodUpdateScheduledTask = 'hostUpdateScheduledTask';
  static const String methodDeleteScheduledTask = 'hostDeleteScheduledTask';
  static const String methodEnableScheduledTask = 'hostEnableScheduledTask';
  static const String methodDisableScheduledTask = 'hostDisableScheduledTask';
  static const String methodTriggerScheduledTask = 'hostTriggerScheduledTask';

  // ===== 设备配置查询 =====
  static const String methodGetDeviceConfig = 'hostGetDeviceConfig';
}

/// 注册Host端RPC方法
void registerHostRpcMethods({
  required RemoteCallServer rpcServer,
  required EmployeeManager employeeManager,
  required SessionManager sessionManager,
  required SkillManager skillManager,
  required MessageStoreService messageStore,
  required ClientSessionManager clientSessionManager,
  ScheduledTaskManager? scheduledTaskManager,
}) {
  // ===== 员工管理方法 =====

  // 获取员工列表
  rpcServer.register(HostRpcConfig.methodGetEmployees, (params) async {
    final includeDeleted = params['includeDeleted'] as bool? ?? false;
    final employees = await employeeManager.getEmployees(
      keyword: params['keyword'] as String?,
      status: params['status'] as String?,
      includeDeleted: includeDeleted,
    );
    return {'employees': employees.map((e) => e.toMap()).toList()};
  });

  // 获取单个员工
  rpcServer.register(HostRpcConfig.methodGetEmployee, (params) async {
    final uuid = params['uuid'] as String;
    final employee = await employeeManager.getEmployee(uuid);
    if (employee == null) {
      throw Exception('Employee not found: $uuid');
    }
    return {'employee': employee.toMap()};
  });

  // 创建员工
  rpcServer.register(HostRpcConfig.methodCreateEmployee, (params) async {
    final employeeData = params['employee'] as Map<String, dynamic>;
    final employee = AiEmployeeEntity.fromMap(employeeData);
    final created = await employeeManager.createEmployee(employee);
    return {'employee': created.toMap()};
  });

  // 更新员工
  rpcServer.register(HostRpcConfig.methodUpdateEmployee, (params) async {
    final employeeData = params['employee'] as Map<String, dynamic>;
    final employee = AiEmployeeEntity.fromMap(employeeData);
    await employeeManager.updateEmployee(employee);
    return {'success': true};
  });

  // 删除员工
  rpcServer.register(HostRpcConfig.methodDeleteEmployee, (params) async {
    final uuid = params['uuid'] as String;
    await employeeManager.deleteEmployee(uuid);
    return {'success': true};
  });

  // ===== 会话管理方法 =====

  // 获取会话列表
  rpcServer.register(HostRpcConfig.methodGetSessions, (params) async {
    final includeDeleted = params['includeDeleted'] as bool? ?? false;
    final sessions = await sessionManager.getAllSessions(
      includeArchived: params['includeArchived'] as bool? ?? false,
      includeDeleted: includeDeleted,
    );
    return {'sessions': sessions.map((s) => s.toMap()).toList()};
  });

  // 获取单个会话
  rpcServer.register(HostRpcConfig.methodGetSession, (params) async {
    final employeeId = params['employeeId'] as String;
    final session = await sessionManager.getSession(employeeId);
    if (session == null) {
      throw Exception('Session not found: $employeeId');
    }
    return {'session': session.toMap()};
  });

  // 获取或创建会话
  rpcServer.register(HostRpcConfig.methodGetOrCreateSession, (params) async {
    final employeeId = params['employeeId'] as String;
    final session = await sessionManager.getOrCreateSession(employeeId);
    return {'session': session.toMap()};
  });

  // 更新设备配置（仅设备级别：providerConfig、systemPromptOverride）
  rpcServer.register(HostRpcConfig.methodUpdateDeviceConfig, (params) async {
    final employeeId = params['employeeId'] as String;
    final deviceId = params['deviceId'] as String;

    await sessionManager.updateDeviceConfig(
      employeeId,
      deviceId,
      providerConfig: params['providerConfig'] as String?,
      systemPromptOverride: params['systemPromptOverride'] as String?,
    );
    return {'success': true};
  });

  // 删除会话
  rpcServer.register(HostRpcConfig.methodDeleteSession, (params) async {
    final employeeId = params['employeeId'] as String;
    await sessionManager.deleteSession(employeeId);
    return {'success': true};
  });

  // ===== 技能管理方法 =====

  // 获取员工技能列表
  rpcServer.register(HostRpcConfig.methodGetSkills, (params) async {
    final employeeId = params['employeeId'] as String;
    final skills = await skillManager.getSkills(employeeId);
    return {'skills': skills.map((s) => s.toMap()).toList()};
  });

  // 创建技能
  rpcServer.register(HostRpcConfig.methodCreateSkill, (params) async {
    final skillData = params['skill'] as Map<String, dynamic>;
    final skill = AiEmployeeSkillEntity.fromMap(skillData);
    final created = await skillManager.createSkill(skill);
    return {'skill': created.toMap()};
  });

  // 更新技能
  rpcServer.register(HostRpcConfig.methodUpdateSkill, (params) async {
    final skillData = params['skill'] as Map<String, dynamic>;
    final skill = AiEmployeeSkillEntity.fromMap(skillData);
    await skillManager.updateSkill(skill);
    return {'success': true};
  });

  // 删除技能
  rpcServer.register(HostRpcConfig.methodDeleteSkill, (params) async {
    final uuid = params['uuid'] as String;
    await skillManager.deleteSkill(uuid);
    return {'success': true};
  });

  // ===== 数据同步方法 =====

  // 同步员工数据
  rpcServer.register(HostRpcConfig.methodSyncEmployees, (params) async {
    final employeesData = params['employees'] as List;
    final employees = employeesData
        .map((e) => AiEmployeeEntity.fromMap(e as Map<String, dynamic>))
        .toList();

    for (final employee in employees) {
      final existing = await employeeManager.getEmployeeIncludingDeleted(employee.uuid);
      if (existing == null) {
        // 本地不存在（含已删除） → 直接保存，保留原始 deviceId 和时间戳
        await employeeManager.saveEmployee(employee);
      } else {
        // 合并：deleteTime 独立比较，数据按 updateTime 合并
        final mergeResult = StoreMergeUtil.mergeDeleteState(
          localDeleteTime: existing.deletedTime,
          localDeleted: existing.deleted,
          remoteDeleteTime: employee.deletedTime,
          remoteDeleted: employee.deleted,
          localUpdateTime: existing.updateTime,
          remoteUpdateTime: employee.updateTime,
        );
        final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
            existing.updateTime, employee.updateTime);
        final shouldUpdateDelete =
            mergeResult.mergedDeleteTime != existing.deletedTime ||
                mergeResult.mergedDeleted != existing.deleted;

        if (shouldUpdateData || shouldUpdateDelete) {
          final base = shouldUpdateData ? employee : existing;
          await employeeManager.updateEmployee(base.copyWith(
            deleted: mergeResult.mergedDeleted,
            deletedTime: mergeResult.mergedDeleteTime,
          ));
        }
      }
    }
    return {'count': employees.length};
  });

  // 同步会话数据
  rpcServer.register(HostRpcConfig.methodSyncSessions, (params) async {
    final sessionsData = params['sessions'] as List;
    final sessions = sessionsData
        .map((s) => AiEmployeeSessionEntity.fromMap(s as Map<String, dynamic>))
        .toList();

    for (final session in sessions) {
      final existing = await sessionManager.getSession(session.employeeId);
      if (existing == null) {
        // 本地不存在 → 远程未删除的直接创建
        if (session.deleted != 1) {
          await sessionManager.save(session);
        }
      } else {
        // 合并：deleteTime + deleted 独立比较，数据按 updateTime 合并
        final mergeResult = StoreMergeUtil.mergeDeleteState(
          localDeleteTime: existing.deleteTime,
          localDeleted: existing.deleted,
          remoteDeleteTime: session.deleteTime,
          remoteDeleted: session.deleted,
          localUpdateTime: existing.updateTime,
          remoteUpdateTime: session.updateTime,
        );
        final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
            existing.updateTime, session.updateTime);
        final shouldUpdateDelete =
            mergeResult.mergedDeleteTime != existing.deleteTime ||
                mergeResult.mergedDeleted != existing.deleted;

        if (shouldUpdateData || shouldUpdateDelete) {
          final base = shouldUpdateData ? session : existing;
          await sessionManager.save(base.copyWith(
            deleted: mergeResult.mergedDeleted,
            deleteTime: mergeResult.mergedDeleteTime,
          ));
        }
      }
    }
    return {'count': sessions.length};
  });

  // 同步消息数据
  rpcServer.register(HostRpcConfig.methodSyncMessages, (params) async {
    final messagesData = params['messages'] as List;
    final messages = messagesData
        .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
        .toList();

    // 消息携带各自的 deviceId，按设备分组写入
    final byDevice = <String, List<ChatMessage>>{};
    for (final msg in messages) {
      final did = msg.deviceId ?? '';
      (byDevice[did] ??= []).add(msg);
    }
    for (final entry in byDevice.entries) {
      await messageStore.addMessages(entry.key, entry.value);
    }
    return {'count': messages.length};
  });

  // ===== 设备管理方法 =====

  // ===== 会话摘要同步方法 =====

  // 获取所有会话摘要
  rpcServer.register(HostRpcConfig.methodGetSessionSummaries, (params) async {
    final summaryStore = SessionSummaryStore(deviceId: '');
    final summaries = summaryStore.getAllSummaries();
    return {'summaries': summaries.map((s) => s.toMap()).toList()};
  });

  // 同步远端会话摘要（接收远端摘要列表，逐条写入本地）
  rpcServer.register(HostRpcConfig.methodSyncSessionSummaries, (params) async {
    final summaryStore = SessionSummaryStore(deviceId: '');
    final summaries = (params['summaries'] as List? ?? [])
        .map((s) => SessionSummaryEntity.fromMap(s as Map<String, dynamic>))
        .toList();
    int count = 0;
    for (final summary in summaries) {
      summaryStore.upsertFromRemote(summary);
      count++;
    }
    return {'count': count};
  });

  // ===== Spec 同步方法 =====

  // 获取指定员工的所有 spec 项（含已删除）
  rpcServer.register(HostRpcConfig.methodGetSpecs, (params) async {
    final employeeId = params['employeeId'] as String;
    final specStore = SpecStore(deviceId: '');
    final specs = specStore.findAllByEmployee(employeeId);
    return {'specs': specs.map((s) => s.toMap()).toList()};
  });

  // 同步远程 spec 数据（接收远程 spec 列表，逐条 merge 写入本地）
  rpcServer.register(HostRpcConfig.methodSyncSpecs, (params) async {
    final specStore = SpecStore(deviceId: '');
    final specs = (params['specs'] as List? ?? [])
        .map((s) => SpecItemEntity.fromMap(s as Map<String, dynamic>))
        .toList();
    int count = 0;
    for (final spec in specs) {
      if (specStore.upsertFromRemote(spec)) {
        count++;
      }
    }
    return {'count': count};
  });

  // ===== Todo 同步方法 =====

  // 获取指定员工的所有 todo 数据（含已删除）
  rpcServer.register(HostRpcConfig.methodGetTodos, (params) async {
    final employeeId = params['employeeId'] as String;
    final todoStore = TodoStore(deviceId: '');
    final topics = todoStore.findAllTopicsIncludingDeleted(employeeId);
    final taskItems = <Map<String, dynamic>>[];
    for (final topic in topics) {
      final items = todoStore.findTaskItemsByTopic(topic.id);
      taskItems.addAll(items.map((i) => i.toMap()).toList());
    }
    return {
      'topics': topics.map((t) => t.toMap()).toList(),
      'taskItems': taskItems,
    };
  });

  // 同步远程 todo 数据（接收远程 todo 列表，逐条 merge 写入本地）
  rpcServer.register(HostRpcConfig.methodSyncTodos, (params) async {
    final todoStore = TodoStore(deviceId: '');
    final topics = (params['topics'] as List? ?? [])
        .map((t) => TodoTopicEntity.fromMap(t as Map<String, dynamic>))
        .toList();
    final taskItems = (params['taskItems'] as List? ?? [])
        .map((i) => TodoTaskItemEntity.fromMap(i as Map<String, dynamic>))
        .toList();
    int count = 0;
    for (final topic in topics) {
      if (todoStore.upsertTopicFromRemote(topic)) {
        count++;
      }
    }
    for (final item in taskItems) {
      if (todoStore.upsertTaskItemFromRemote(item)) {
        count++;
      }
    }
    return {'count': count};
  });

  // ===== 技能同步方法 =====

  // 获取所有技能（含已删除）
  rpcServer.register(HostRpcConfig.methodGetAllSkills, (params) async {
    final includeDeleted = params['includeDeleted'] as bool? ?? false;
    final skills = includeDeleted
        ? await skillManager.getAllSkills()
        : await skillManager.getAllSkills().then(
            (list) => list.where((s) => s.deleted != 1).toList());
    return {'skills': skills.map((s) => s.toMap()).toList()};
  });

  // 同步技能数据（逐条合并）
  rpcServer.register(HostRpcConfig.methodSyncSkills, (params) async {
    final skillsData = params['skills'] as List;
    final skills = skillsData
        .map((s) => AiEmployeeSkillEntity.fromMap(s as Map<String, dynamic>))
        .toList();

    for (final skill in skills) {
      final existing = await skillManager.getSkillIncludingDeleted(skill.uuid);
      if (existing == null) {
        // 本地不存在 → 直接保存
        await skillManager.createSkill(skill);
      } else {
        // 合并：deleteTime 独立比较，数据按 updateTime 合并
        final mergeResult = StoreMergeUtil.mergeDeleteState(
          localDeleteTime: existing.deleteTime,
          localDeleted: existing.deleted,
          remoteDeleteTime: skill.deleteTime,
          remoteDeleted: skill.deleted,
          localUpdateTime: existing.updateTime,
          remoteUpdateTime: skill.updateTime,
        );
        final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
            existing.updateTime, skill.updateTime);
        final shouldUpdateDelete =
            mergeResult.mergedDeleteTime != existing.deleteTime ||
                mergeResult.mergedDeleted != existing.deleted;

        if (shouldUpdateData || shouldUpdateDelete) {
          final base = shouldUpdateData ? skill : existing;
          await skillManager.updateSkill(base.copyWith(
            deleted: mergeResult.mergedDeleted,
            deleteTime: mergeResult.mergedDeleteTime,
          ));
        }
      }
    }
    return {'count': skills.length};
  });

  // 获取全局技能（含已删除）
  rpcServer.register(HostRpcConfig.methodGetGlobalSkills, (params) async {
    final includeDeleted = params['includeDeleted'] as bool? ?? false;
    final globalSkillManager = GlobalSkillManager.getInstance('');
    final skills = includeDeleted
        ? await globalSkillManager.getAllSkillsIncludingDeleted()
        : await globalSkillManager.getAllSkills();
    return {'skills': skills.map((s) => s.toMap()).toList()};
  });

  // 同步全局技能数据（逐条合并）
  rpcServer.register(HostRpcConfig.methodSyncGlobalSkills, (params) async {
    final skillsData = params['skills'] as List;
    final skills = skillsData
        .map((s) => GlobalSkillEntity.fromMap(s as Map<String, dynamic>))
        .toList();
    final globalSkillManager = GlobalSkillManager.getInstance('');

    for (final skill in skills) {
      final existing = await globalSkillManager.getSkillIncludingDeleted(skill.uuid);
      if (existing == null) {
        await globalSkillManager.createSkill(skill);
      } else {
        final mergeResult = StoreMergeUtil.mergeDeleteState(
          localDeleteTime: existing.deleteTime,
          localDeleted: existing.deleted,
          remoteDeleteTime: skill.deleteTime,
          remoteDeleted: skill.deleted,
          localUpdateTime: existing.updateTime,
          remoteUpdateTime: skill.updateTime,
        );
        final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
            existing.updateTime, skill.updateTime);
        final shouldUpdateDelete =
            mergeResult.mergedDeleteTime != existing.deleteTime ||
                mergeResult.mergedDeleted != existing.deleted;

        if (shouldUpdateData || shouldUpdateDelete) {
          final base = shouldUpdateData ? skill : existing;
          await globalSkillManager.updateSkill(base.copyWith(
            deleted: mergeResult.mergedDeleted,
            deleteTime: mergeResult.mergedDeleteTime,
          ));
        }
      }
    }
    return {'count': skills.length};
  });

  // 获取在线设备列表
  rpcServer.register(HostRpcConfig.methodGetOnlineDevices, (params) async {
    final devices = clientSessionManager.getOnlineDevicesInfo();
    return {'devices': devices};
  });

  // 获取设备配置（按 employeeId + deviceId 查询）
  rpcServer.register(HostRpcConfig.methodGetDeviceConfig, (params) async {
    final employeeId = params['employeeId'] as String;
    final deviceId = params['deviceId'] as String?;

    final session = await sessionManager.getSession(employeeId);
    if (session == null) {
      throw Exception('Session not found: $employeeId');
    }

    if (deviceId != null && deviceId.isNotEmpty) {
      final config = session.config[deviceId];
      if (config != null) {
        return {'deviceConfig': config.toMap()};
      }
    }

    // 返回所有设备配置
    final allConfigs = session.config.map(
      (key, value) => MapEntry(key, value.toMap()),
    );
    return {'configs': allConfigs};
  });

  // 获取设备信息
  rpcServer.register(HostRpcConfig.methodGetDeviceInfo, (params) async {
    final deviceId = params['deviceId'] as String;
    final clients = clientSessionManager.getClientsByDeviceId(deviceId);

    if (clients.isEmpty) {
      throw Exception('Device not found: $deviceId');
    }

    final firstClient = clients.first;
    return {
      'device': {
        'deviceId': deviceId,
        'deviceName': firstClient.deviceName,
        'topic': firstClient.topic,
        'connectedAt': firstClient.connectedAt.millisecondsSinceEpoch,
        'clientCount': clients.length,
      },
    };
  });

  // ===== 定时任务管理方法 =====
  if (scheduledTaskManager != null) {
    _registerScheduledTaskRpcMethods(
      rpcServer: rpcServer,
      manager: scheduledTaskManager,
    );
  }
}

/// 注册定时任务相关的 RPC 方法
void _registerScheduledTaskRpcMethods({
  required RemoteCallServer rpcServer,
  required ScheduledTaskManager manager,
}) {
  // 获取任务列表
  rpcServer.register(HostRpcConfig.methodGetScheduledTasks, (params) async {
    final tasks = await manager.getTasks(
      employeeId: params['employeeId'] as String?,
    );
    return {'tasks': tasks.map((t) => t.toMap()).toList()};
  });

  // 获取单个任务
  rpcServer.register(HostRpcConfig.methodGetScheduledTask, (params) async {
    final uuid = params['uuid'] as String;
    final task = await manager.getTask(uuid);
    if (task == null) {
      throw Exception('Scheduled task not found: $uuid');
    }
    return {'task': task.toMap()};
  });

  // 创建任务
  rpcServer.register(HostRpcConfig.methodCreateScheduledTask, (params) async {
    final taskData = params['task'] as Map<String, dynamic>;
    final task = AiScheduledTaskEntity.fromMap(taskData);
    final created = await manager.createTask(task);
    return {'task': created.toMap()};
  });

  // 更新任务
  rpcServer.register(HostRpcConfig.methodUpdateScheduledTask, (params) async {
    final taskData = params['task'] as Map<String, dynamic>;
    final task = AiScheduledTaskEntity.fromMap(taskData);
    final updated = await manager.updateTask(task);
    return {'task': updated.toMap()};
  });

  // 删除任务
  rpcServer.register(HostRpcConfig.methodDeleteScheduledTask, (params) async {
    final uuid = params['uuid'] as String;
    await manager.deleteTask(uuid);
    return {'success': true};
  });

  // 启用任务
  rpcServer.register(HostRpcConfig.methodEnableScheduledTask, (params) async {
    final uuid = params['uuid'] as String;
    await manager.enableTask(uuid);
    return {'success': true};
  });

  // 禁用任务
  rpcServer.register(HostRpcConfig.methodDisableScheduledTask, (params) async {
    final uuid = params['uuid'] as String;
    await manager.disableTask(uuid);
    return {'success': true};
  });

  // 立即触发
  rpcServer.register(HostRpcConfig.methodTriggerScheduledTask, (params) async {
    final uuid = params['uuid'] as String;
    await manager.triggerTaskNow(uuid);
    return {'success': true};
  });
}
