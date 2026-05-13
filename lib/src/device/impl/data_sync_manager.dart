import 'dart:io';

import 'package:path/path.dart' as p;

import '../../host/host_rpc_methods.dart';
import '../../persistence/persistence.dart';
import '../../service/service.dart';
import '../../utils/logger.dart';
import '../app_context.dart';
import '../device_client.dart';
import 'device_agent_manager.dart';
import 'device_connection_manager.dart';
import 'device_registry.dart';
import 'device_state_holder.dart';

/// 数据同步管理器
///
/// 负责跨设备的员工、会话数据同步。
/// 所有同步操作内置防抖机制，避免短时间内大量重复同步。
class DataSyncManager {
  static final _log = Logger('DataSyncManager');

  final String _deviceId;
  late final EmployeeManager _employeeManager = EmployeeManager.getInstance(
    _deviceId,
  );
  late final SessionManager _sessionManager = SessionManager.getInstance(_deviceId);
  late final DeviceConnectionManager _connectionManager =
      DeviceConnectionManager.getInstance(_deviceId);
  late final DeviceRegistry _deviceRegistry = DeviceRegistry.getInstance(
    _deviceId,
  );
  late final DeviceStateHolder _stateHolder = DeviceStateHolder.getInstance(
    _deviceId,
  );
  late final DeviceAgentManager _agentManager = DeviceAgentManager.getInstance(
    _deviceId,
  );
  late final SkillManager _skillManager = SkillManager.getInstance(
    _deviceId,
  );
  late final GlobalSkillManager _globalSkillManager = GlobalSkillManager.getInstance(
    _deviceId,
  );
  late final ProjectManager _projectManager = ProjectManager.getInstance(
    _deviceId,
  );

  DataSyncManager._({required String deviceId}) : _deviceId = deviceId;

  // ===== 单例管理 =====

  static final Map<String, DataSyncManager> _instances = {};

  /// 从 [AppContext] 获取实例，不存在则回退到独立创建
  static DataSyncManager getInstance(String deviceId) {
    final ctx = AppContext.get(deviceId);
    if (ctx != null) return ctx.dataSyncManager;
    return _instances.putIfAbsent(
      deviceId,
      () => DataSyncManager._(deviceId: deviceId),
    );
  }

  static void removeInstance(String deviceId) {
    _instances.remove(deviceId);
  }

  // ===== 公开方法 =====

  /// 从其他设备同步员工数据
  Future<void> syncEmployeesFromDevices() async {
    final changedIds = await _doSyncEmployeesFromDevices();
    if (changedIds.isNotEmpty) {
      _stateHolder.notifyDataSynced(DataSyncEvent(
        changedEmployeeIds: changedIds,
      ));
    }
  }

  /// 从其他设备同步会话数据
  Future<void> syncSessionsFromDevices() async {
    final changedIds = await _doSyncSessionsFromDevices();
    if (changedIds.isNotEmpty) {
      _stateHolder.notifyDataSynced(DataSyncEvent(
        changedSessionIds: changedIds,
      ));
    }
  }

  /// 从其他设备同步会话摘要数据
  Future<void> syncSessionSummariesFromDevices() async {
    await _doSyncSessionSummariesFromDevices();
  }

  /// 从其他设备同步 spec 数据
  Future<void> syncSpecsFromDevices() async {
    await _doSyncSpecsFromDevices();
  }

  /// 从其他设备同步 todo 数据
  Future<void> syncTodosFromDevices() async {
    await _doSyncTodosFromDevices();
  }

  /// 从其他设备同步项目数据
  Future<void> syncProjectsFromDevices() async {
    final changedIds = await _doSyncProjectsFromDevices();
    if (changedIds.isNotEmpty) {
      _stateHolder.notifyDataSynced(DataSyncEvent(
        changedProjectIds: changedIds,
      ));
    }
  }

  /// 同步全部数据（员工+会话+会话摘要+spec+技能，并行执行）
  Future<void> syncAllFromDevices() async {
    final (changedEmployeeIds, changedSessionIds, _) = await (
      _doSyncEmployeesFromDevices(),
      _doSyncSessionsFromDevices(),
      _doSyncSessionSummariesFromDevices(),
    ).wait;
    // spec 同步不需要等待其他同步完成
    _doSyncSpecsFromDevices();
    // todo 同步不需要等待其他同步完成
    _doSyncTodosFromDevices();
    // 技能同步不需要等待其他同步完成
    _doSyncSkillsFromDevices();
    _doSyncGlobalSkillsFromDevices();
    // 项目同步不需要等待其他同步完成
    _doSyncProjectsFromDevices().then((changedProjectIds) {
      if (changedProjectIds.isNotEmpty) {
        _stateHolder.notifyDataSynced(DataSyncEvent(
          changedProjectIds: changedProjectIds,
        ));
      }
    });
    // Folder Skill 文件同步（元数据同步后）
    syncFolderSkillFiles();
    if (changedEmployeeIds.isNotEmpty || changedSessionIds.isNotEmpty) {
      _stateHolder.notifyDataSynced(DataSyncEvent(
        changedEmployeeIds: changedEmployeeIds,
        changedSessionIds: changedSessionIds,
      ));
    }
  }

  /// 从指定设备同步单个员工数据
  Future<AiEmployeeEntity?> syncEmployeeFromDevice({
    required String employeeId,
    String? targetDeviceId,
  }) async {
    if (!_connectionManager.isConnected) return null;
    try {
      final devices = targetDeviceId != null
          ? (await _deviceRegistry.getOnlineDevices())
              .where((d) => d.id == targetDeviceId)
              .toList()
          : await _deviceRegistry.getOnlineDevices();

      for (final device in devices) {
        if (device.id == _deviceId) continue;
        try {
          final result = await _connectionManager.invokeRemote(
            device.id,
            HostRpcConfig.methodGetEmployee,
            {'uuid': employeeId},
          );
          final data = result['result']['employee'] as Map<String, dynamic>?;
          if (data == null) continue;
          final remote = AiEmployeeEntity.fromMap(data);
          final existing = await _employeeManager.getEmployeeIncludingDeleted(remote.uuid);
          if (existing == null) {
            await _employeeManager.saveEmployee(remote);
            return remote;
          } else {
            await _mergeAndSaveEmployee(existing, remote);
            // 返回合并后的本地最新数据，而不是远程原始数据
            // 避免远程缺少本地已有的字段（如 permissionConfig）导致数据丢失
            final merged = await _employeeManager.getEmployeeIncludingDeleted(remote.uuid);
            return merged ?? remote;
          }
        } catch (e) {
          _log.debug('syncEmployeeFromDevice failed for device ${device.id}: $e');
        }
      }
    } catch (e) {
      _log.debug('syncEmployeeFromDevice failed: $e');
    }
    return null;
  }

  /// 广播员工数据到所有在线设备（创建/更新后调用）
  Future<void> broadcastEmployeeToAllDevices(String employeeId) async {
    if (!_connectionManager.isConnected) return;
    try {
      final employee = await _employeeManager.getEmployee(employeeId);
      if (employee == null) return;
      final devices = await _deviceRegistry.getOnlineDevices();
      for (final device in devices) {
        if (device.id == _deviceId) continue;
        try {
          await _connectionManager.invokeRemote(
            device.id,
            HostRpcConfig.methodSyncEmployees,
            {
              'employees': [employee.toMap()],
            },
          );
        } catch (e) {
          _log.debug('broadcastEmployee to device ${device.id} failed: $e');
        }
      }
    } catch (e) {
      _log.debug('broadcastEmployeeToAllDevices failed: $e');
    }
  }

  /// 广播会话数据到所有在线设备（创建/更新后调用）
  Future<void> broadcastSessionToAllDevices(String employeeId) async {
    if (!_connectionManager.isConnected) return;
    try {
      final session = await _sessionManager.getSession(employeeId);
      if (session == null) return;
      final devices = await _deviceRegistry.getOnlineDevices();
      for (final device in devices) {
        if (device.id == _deviceId) continue;
        try {
          await _connectionManager.invokeRemote(
            device.id,
            HostRpcConfig.methodSyncSessions,
            {
              'sessions': [session.toMap()],
            },
          );
        } catch (e) {
          _log.debug('broadcastSession to device ${device.id} failed: $e');
        }
      }
    } catch (e) {
      _log.debug('broadcastSessionToAllDevices failed: $e');
    }
  }

  /// 广播 spec 数据到所有在线设备（创建/更新后调用）
  Future<void> broadcastSpecToAllDevices(String employeeId) async {
    if (!_connectionManager.isConnected) return;
    try {
      final specStore = SpecStore(deviceId: _deviceId);
      final specs = specStore.findAllByEmployee(employeeId);
      if (specs.isEmpty) return;
      final devices = await _deviceRegistry.getOnlineDevices();
      for (final device in devices) {
        if (device.id == _deviceId) continue;
        try {
          await _connectionManager.invokeRemote(
            device.id,
            HostRpcConfig.methodSyncSpecs,
            {
              'specs': specs.map((s) => s.toMap()).toList(),
            },
          );
        } catch (e) {
          _log.debug('broadcastSpec to device ${device.id} failed: $e');
        }
      }
    } catch (e) {
      _log.debug('broadcastSpecToAllDevices failed: $e');
    }
  }

  /// 广播 todo 数据到所有在线设备（创建/更新后调用）
  Future<void> broadcastTodoToAllDevices(String employeeId) async {
    if (!_connectionManager.isConnected) return;
    try {
      final todoStore = TodoStore(deviceId: _deviceId);
      final topics = todoStore.findAllTopics(employeeId);
      if (topics.isEmpty) return;
      final taskItems = <Map<String, dynamic>>[];
      for (final topic in topics) {
        final items = todoStore.findTaskItemsByTopic(topic.id);
        taskItems.addAll(items.map((i) => i.toMap()).toList());
      }
      final devices = await _deviceRegistry.getOnlineDevices();
      for (final device in devices) {
        if (device.id == _deviceId) continue;
        try {
          await _connectionManager.invokeRemote(
            device.id,
            HostRpcConfig.methodSyncTodos,
            {
              'topics': topics.map((t) => t.toMap()).toList(),
              'taskItems': taskItems,
            },
          );
        } catch (e) {
          _log.debug('broadcastTodo to device ${device.id} failed: $e');
        }
      }
    } catch (e) {
      _log.debug('broadcastTodoToAllDevices failed: $e');
    }
  }

  /// 同步员工到指定远程设备
  Future<bool> syncEmployeeToDevice({
    required String employeeId,
    required String targetDeviceId,
  }) async {
    if (!_connectionManager.isConnected) return false;
    if (targetDeviceId == _deviceId) return false;
    try {
      final employee = await _employeeManager.getEmployee(employeeId);
      if (employee == null) return false;
      final result = await _connectionManager.invokeRemote(
        targetDeviceId,
        HostRpcConfig.methodSyncEmployees,
        {
          'employees': [employee.toMap()],
        },
      );
      return (result['result']['count'] as int? ?? 0) > 0;
    } catch (e) {
      _log.error('同步员工到设备 $targetDeviceId 失败', e);
      return false;
    }
  }

  /// 从其他设备同步技能数据
  Future<void> syncSkillsFromDevices() async {
    await _doSyncSkillsFromDevices();
    await _doSyncGlobalSkillsFromDevices();
  }

  /// 广播员工技能到所有在线设备（创建/更新后调用）
  Future<void> broadcastSkillToAllDevices(String employeeId) async {
    if (!_connectionManager.isConnected) return;
    try {
      // 获取所有 skill（含已删除的），确保删除状态也能同步到其他设备
      final allSkills = await _skillManager.getAllSkills();
      final skills =
          allSkills.where((s) => s.employeeId == employeeId).toList();
      if (skills.isEmpty) return;
      final devices = await _deviceRegistry.getOnlineDevices();
      for (final device in devices) {
        if (device.id == _deviceId) continue;
        try {
          await _connectionManager.invokeRemote(
            device.id,
            HostRpcConfig.methodSyncSkills,
            {'skills': skills.map((s) => s.toMap()).toList()},
          );
        } catch (e) {
          _log.debug('broadcastSkill to device ${device.id} failed: $e');
        }
      }
    } catch (e) {
      _log.debug('broadcastSkillToAllDevices failed: $e');
    }
  }

  /// 广播全局技能到所有在线设备
  Future<void> broadcastGlobalSkillsToAllDevices() async {
    if (!_connectionManager.isConnected) return;
    try {
      final skills = await _globalSkillManager.getAllSkills();
      if (skills.isEmpty) return;
      final devices = await _deviceRegistry.getOnlineDevices();
      for (final device in devices) {
        if (device.id == _deviceId) continue;
        try {
          await _connectionManager.invokeRemote(
            device.id,
            HostRpcConfig.methodSyncGlobalSkills,
            {'skills': skills.map((s) => s.toMap()).toList()},
          );
        } catch (e) {
          _log.debug('broadcastGlobalSkill to device ${device.id} failed: $e');
        }
      }
    } catch (e) {
      _log.debug('broadcastGlobalSkillsToAllDevices failed: $e');
    }
  }

  /// 删除技能并同步到其他设备
  Future<void> deleteSkillWithSync(String skillId) async {
    _log.info('deleteSkillWithSync: skillId=$skillId');
    final skill = await _skillManager.getSkillIncludingDeleted(skillId);
    _log.debug('deleteSkillWithSync: skill=${skill?.name}, skillType=${skill?.skillType}');
    try {
      await _skillManager.deleteSkill(skillId);
      _log.info('deleteSkillWithSync: 本地删除成功, skillId=$skillId');
    } catch (e, st) {
      _log.error('deleteSkillWithSync: 本地删除失败, skillId=$skillId', e, st);
      rethrow;
    }
    if (skill != null) {
      _log.debug('deleteSkillWithSync: 同步删除到其他设备, skill=${skill.name}');
      await _syncSkillDeleteToDevices(skill.copyWith(
        deleted: 1,
        deleteTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));
    }
  }

  /// 广播项目数据到所有在线设备（创建/更新后调用）
  Future<void> broadcastProjectToAllDevices(String projectUuid) async {
    if (!_connectionManager.isConnected) return;
    try {
      final project = await _projectManager.getProject(projectUuid);
      if (project == null) return;
      final projectStore = ProjectStore(deviceId: _deviceId);
      final modules = await projectStore.findModules(projectUuid);
      final skills = await projectStore.findSkills(projectUuid);
      final issues = await projectStore.findIssues(projectUuid);
      final devices = await _deviceRegistry.getOnlineDevices();
      for (final device in devices) {
        if (device.id == _deviceId) continue;
        try {
          await _connectionManager.invokeRemote(
            device.id,
            HostRpcConfig.methodSyncProjects,
            {
              'projects': [
                {
                  'project': project.toMap(),
                  'modules': modules.map((m) => m.toMap()).toList(),
                  'skills': skills.map((s) => s.toMap()).toList(),
                  'issues': issues.map((i) => i.toMap()).toList(),
                },
              ],
            },
          );
        } catch (e) {
          _log.debug('broadcastProject to device ${device.id} failed: $e');
        }
      }
    } catch (e) {
      _log.debug('broadcastProjectToAllDevices failed: $e');
    }
  }

  /// 删除项目并同步到其他设备
  Future<void> deleteProjectWithSync(String projectUuid) async {
    final project = await _projectManager.getProject(projectUuid);
    await _projectManager.deleteProject(projectUuid);
    if (project != null) {
      _syncProjectDeleteToDevices(project.copyWith(
        deleted: 1,
        deleteTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));
    }
  }

  /// 删除员工并同步到其他设备
  Future<void> deleteEmployeeWithSync(String employeeId) async {
    // 先获取员工数据（删除前 getEmployee 可查到），用于广播
    final employee = await _employeeManager.getEmployee(employeeId);
    await _employeeManager.deleteEmployee(employeeId);
    // 删除后 getEmployee 返回 null（filtered by deleted=0），所以传入删除前的快照
    if (employee != null) {
      _syncEmployeeDeleteToDevices(employee.copyWith(
        deleted: 1,
        deletedTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));
    }
  }

  /// 删除会话并同步到其他设备
  Future<void> deleteSessionWithSync(String employeeId) async {
    // 先获取会话数据（删除前 getSession 可查到），用于广播
    final session = await _sessionManager.getSession(employeeId);
    // 软删除：设置 deleted=1、deleteTime=now
    await _sessionManager.deleteSession(employeeId);
    _agentManager.destroyAgentProxy(employeeId);
    // 广播软删除的会话数据到其他设备（含 deleted=1 和 deleteTime）
    // 使用 methodSyncSessions 让远端执行 deleteTime 合并，保证一致性
    if (session != null) {
      _syncSessionDeleteToDevices(session.copyWith(
        deleted: 1,
        deleteTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));
    }
  }

  // ===== 内部实现 =====

  Future<Set<String>> _doSyncEmployeesFromDevices() async {
    final changedIds = <String>{};
    if (!_connectionManager.isConnected) return changedIds;
    final devices = await _deviceRegistry.getOnlineDevices();
    for (final device in devices) {
      if (device.id == _deviceId) continue;
      try {
        // 请求包含已删除的员工，以便正确同步删除状态（与 _doSyncSessionsFromDevices 一致）
        final result = await _connectionManager.invokeRemote(
          device.id,
          HostRpcConfig.methodGetEmployees,
          {'includeDeleted': true},
        );
        for (final data in (result['result']['employees'] as List? ?? [])) {
          final employee = AiEmployeeEntity.fromMap(
            data as Map<String, dynamic>,
          );
          final existing = await _employeeManager.getEmployeeIncludingDeleted(employee.uuid);
          if (existing == null) {
            // 本地不存在 → 远程未删除的直接保存，已删除的不保存（避免数据污染）
            if (employee.deleted != 1) {
              await _employeeManager.saveEmployee(employee);
              changedIds.add(employee.uuid);
            }
          } else {
            final changed = await _mergeAndSaveEmployee(existing, employee);
            if (changed) changedIds.add(employee.uuid);
          }
        }
      } catch (e) {
        _log.debug('syncEmployees from device ${device.id} failed: $e');
      }
    }
    return changedIds;
  }

  Future<Set<String>> _doSyncSessionsFromDevices() async {
    final changedIds = <String>{};
    if (!_connectionManager.isConnected) return changedIds;
    final devices = await _deviceRegistry.getOnlineDevices();

    // 第一阶段：收集所有设备的会话数据，同一 employeeId 取 updateTime 最大的版本
    final allRemoteSessions = <String, AiEmployeeSessionEntity>{};
    for (final device in devices) {
      if (device.id == _deviceId) continue;
      try {
        // 请求包含已删除的会话，以便正确同步删除状态
        final result = await _connectionManager.invokeRemote(
          device.id,
          HostRpcConfig.methodGetSessions,
          {'includeDeleted': true},
        );
        for (final data in (result['result']['sessions'] as List? ?? [])) {
          final session = AiEmployeeSessionEntity.fromMap(
            data as Map<String, dynamic>,
          );
          final existing = allRemoteSessions[session.employeeId];
          // 取 updateTime 最大的版本
          if (existing == null ||
              session.updateTime.isAfter(existing.updateTime)) {
            allRemoteSessions[session.employeeId] = session;
          }
        }
      } catch (e) {
        _log.debug('syncSessions from device ${device.id} failed: $e');
      }
    }

    // 第二阶段：对每个会话只取最新版本进行合并
    for (final session in allRemoteSessions.values) {
      final existing = await _sessionManager.getSession(session.employeeId);
      if (existing == null) {
        if (session.deleted != 1) {
          await _sessionManager.save(session);
          changedIds.add(session.employeeId);
        }
      } else {
        final changed = await _mergeAndSaveSession(existing, session);
        if (changed) changedIds.add(session.employeeId);
      }
    }
    return changedIds;
  }

  Future<void> _doSyncSessionSummariesFromDevices() async {
    if (!_connectionManager.isConnected) return;
    final devices = await _deviceRegistry.getOnlineDevices();
    final summaryStore = SessionSummaryStore(deviceId: _deviceId);
    for (final device in devices) {
      if (device.id == _deviceId) continue;
      try {
        final result = await _connectionManager.invokeRemote(
          device.id,
          HostRpcConfig.methodGetSessionSummaries,
          {},
        );
        final summaries = (result['result']['summaries'] as List? ?? [])
            .map((s) => SessionSummaryEntity.fromMap(s as Map<String, dynamic>))
            .toList();
        for (final summary in summaries) {
          // 保留远程摘要的原始 deviceId（employeeId + deviceId 隔离）
          summaryStore.upsertFromRemote(summary);
        }
      } catch (e) {
        _log.debug('syncSessionSummaries from device ${device.id} failed: $e');
      }
    }
  }

  Future<void> _doSyncSpecsFromDevices() async {
    if (!_connectionManager.isConnected) return;
    final devices = await _deviceRegistry.getOnlineDevices();
    final specStore = SpecStore(deviceId: _deviceId);
    for (final device in devices) {
      if (device.id == _deviceId) continue;
      try {
        // 遍历所有员工，拉取各员工的 spec 数据
        final employees = await _employeeManager.getEmployees();
        for (final employee in employees) {
          try {
            final result = await _connectionManager.invokeRemote(
              device.id,
              HostRpcConfig.methodGetSpecs,
              {'employeeId': employee.uuid},
            );
            final specs = (result['result']['specs'] as List? ?? [])
                .map((s) => SpecItemEntity.fromMap(s as Map<String, dynamic>))
                .toList();
            if (specs.isNotEmpty) {
              specStore.upsertAllFromRemote(specs);
            }
          } catch (e) {
            _log.debug('syncSpecs for employee ${employee.uuid} from device ${device.id} failed: $e');
          }
        }
      } catch (e) {
        _log.debug('syncSpecs from device ${device.id} failed: $e');
      }
    }
  }

  Future<void> _doSyncTodosFromDevices() async {
    if (!_connectionManager.isConnected) return;
    final devices = await _deviceRegistry.getOnlineDevices();
    final todoStore = TodoStore(deviceId: _deviceId);
    for (final device in devices) {
      if (device.id == _deviceId) continue;
      try {
        // 遍历所有员工，拉取各员工的 todo 数据
        final employees = await _employeeManager.getEmployees();
        for (final employee in employees) {
          try {
            final result = await _connectionManager.invokeRemote(
              device.id,
              HostRpcConfig.methodGetTodos,
              {'employeeId': employee.uuid},
            );
            final topics = (result['result']['topics'] as List? ?? [])
                .map((t) => TodoTopicEntity.fromMap(t as Map<String, dynamic>))
                .toList();
            final taskItems = (result['result']['taskItems'] as List? ?? [])
                .map((i) => TodoTaskItemEntity.fromMap(i as Map<String, dynamic>))
                .toList();
            if (topics.isNotEmpty || taskItems.isNotEmpty) {
              todoStore.upsertAllTopicsFromRemote(topics);
              todoStore.upsertAllTaskItemsFromRemote(taskItems);
            }
          } catch (e) {
            _log.debug('syncTodos for employee ${employee.uuid} from device ${device.id} failed: $e');
          }
        }
      } catch (e) {
        _log.debug('syncTodos from device ${device.id} failed: $e');
      }
    }
  }

  /// 将员工删除同步到所有在线设备
  void _syncEmployeeDeleteToDevices(AiEmployeeEntity employee) {
    Future(() async {
      if (!_connectionManager.isConnected) return;
      try {
        // 广播员工数据（含 deleted=1 和 deletedTime），让其他设备执行 deleteTime 合并
        final devices = await _deviceRegistry.getOnlineDevices();
        for (final device in devices) {
          if (device.id == _deviceId) continue;
          try {
            await _connectionManager.invokeRemote(
              device.id,
              HostRpcConfig.methodSyncEmployees,
              {
                'employees': [employee.toMap()],
              },
            );
          } catch (e) {
            _log.debug('syncEmployeeDelete to device ${device.id} failed: $e');
          }
        }
      } catch (e) {
        _log.debug('syncEmployeeDeleteToDevices failed: $e');
      }
    });
  }

  void _syncSessionDeleteToDevices(AiEmployeeSessionEntity session) {
    Future(() async {
      if (!_connectionManager.isConnected) return;
      try {
        final devices = await _deviceRegistry.getOnlineDevices();
        for (final device in devices) {
          if (device.id == _deviceId) continue;
          try {
            await _connectionManager.invokeRemote(
              device.id,
              HostRpcConfig.methodSyncSessions,
              {
                'sessions': [session.toMap()],
              },
            );
          } catch (e) {
            _log.debug('syncSessionDelete to device ${device.id} failed: $e');
          }
        }
      } catch (e) {
        _log.debug('syncSessionDeleteToDevices failed: $e');
      }
    });
  }

  /// 将技能删除同步到所有在线设备
  Future<void> _syncSkillDeleteToDevices(AiEmployeeSkillEntity skill) async {
    if (!_connectionManager.isConnected) return;
    try {
      final devices = await _deviceRegistry.getOnlineDevices();
      for (final device in devices) {
        if (device.id == _deviceId) continue;
        try {
          await _connectionManager.invokeRemote(
            device.id,
            HostRpcConfig.methodSyncSkills,
            {
              'skills': [skill.toMap()],
            },
          );
        } catch (e) {
          _log.debug('syncSkillDelete to device ${device.id} failed: $e');
        }
      }
    } catch (e) {
      _log.debug('syncSkillDeleteToDevices failed: $e');
    }
  }

  /// 将项目删除同步到所有在线设备
  void _syncProjectDeleteToDevices(ProjectEntity project) {
    Future(() async {
      if (!_connectionManager.isConnected) return;
      try {
        final projectStore = ProjectStore(deviceId: _deviceId);
        // 获取子资源（含已删除）一起广播
        final modules = await projectStore.findAllModulesIncludingDeleted(project.uuid);
        final skills = await projectStore.findAllSkillsIncludingDeleted(project.uuid);
        final issues = await projectStore.findAllIssuesIncludingDeleted(project.uuid);
        final devices = await _deviceRegistry.getOnlineDevices();
        for (final device in devices) {
          if (device.id == _deviceId) continue;
          try {
            await _connectionManager.invokeRemote(
              device.id,
              HostRpcConfig.methodSyncProjects,
              {
                'projects': [
                  {
                    'project': project.toMap(),
                    'modules': modules.map((m) => m.toMap()).toList(),
                    'skills': skills.map((s) => s.toMap()).toList(),
                    'issues': issues.map((i) => i.toMap()).toList(),
                  },
                ],
              },
            );
          } catch (e) {
            _log.debug('syncProjectDelete to device ${device.id} failed: $e');
          }
        }
      } catch (e) {
        _log.debug('syncProjectDeleteToDevices failed: $e');
      }
    });
  }

  // ===== 技能同步内部实现 =====

  Future<void> _doSyncSkillsFromDevices() async {
    if (!_connectionManager.isConnected) return;
    final devices = await _deviceRegistry.getOnlineDevices();
    for (final device in devices) {
      if (device.id == _deviceId) continue;
      try {
        final result = await _connectionManager.invokeRemote(
          device.id,
          HostRpcConfig.methodGetAllSkills,
          {'includeDeleted': true},
        );
        for (final data in (result['result']['skills'] as List? ?? [])) {
          final remote = AiEmployeeSkillEntity.fromMap(data as Map<String, dynamic>);
          final existing = await _skillManager.getSkillIncludingDeleted(remote.uuid);
          if (existing == null) {
            if (remote.deleted != 1) {
              await _skillManager.createSkill(remote);
            }
          } else {
            await _mergeAndSaveSkill(existing, remote);
          }
        }
      } catch (e) {
        _log.debug('syncSkills from device ${device.id} failed: $e');
      }
    }
  }

  Future<void> _doSyncGlobalSkillsFromDevices() async {
    if (!_connectionManager.isConnected) return;
    final devices = await _deviceRegistry.getOnlineDevices();
    for (final device in devices) {
      if (device.id == _deviceId) continue;
      try {
        final result = await _connectionManager.invokeRemote(
          device.id,
          HostRpcConfig.methodGetGlobalSkills,
          {'includeDeleted': true},
        );
        for (final data in (result['result']['skills'] as List? ?? [])) {
          final remote = GlobalSkillEntity.fromMap(data as Map<String, dynamic>);
          final existing = await _globalSkillManager.getSkillIncludingDeleted(remote.uuid);
          if (existing == null) {
            if (remote.deleted != 1) {
              await _globalSkillManager.createSkill(remote);
            }
          } else {
            await _mergeAndSaveGlobalSkill(existing, remote);
          }
        }
        _log.debug('syncGlobalSkills from device ${device.id} success.');
      } catch (e) {
        _log.debug('syncGlobalSkills from device ${device.id} failed: $e');
      }
    }
  }

  Future<bool> _mergeAndSaveSkill(
    AiEmployeeSkillEntity existing,
    AiEmployeeSkillEntity remote,
  ) async {
    final mergeResult = StoreMergeUtil.mergeDeleteState(
      localDeleteTime: existing.deleteTime,
      localDeleted: existing.deleted,
      remoteDeleteTime: remote.deleteTime,
      remoteDeleted: remote.deleted,
      localUpdateTime: existing.updateTime,
      remoteUpdateTime: remote.updateTime,
    );
    final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
        existing.updateTime, remote.updateTime);
    final shouldUpdateDelete =
        mergeResult.mergedDeleteTime != existing.deleteTime ||
            mergeResult.mergedDeleted != existing.deleted;
    if (shouldUpdateData || shouldUpdateDelete) {
      await _skillManager.updateSkill(
        (shouldUpdateData ? remote : existing).copyWith(
          deleted: mergeResult.mergedDeleted,
          deleteTime: mergeResult.mergedDeleteTime,
        ),
      );
      return true;
    }
    return false;
  }

  Future<bool> _mergeAndSaveGlobalSkill(
    GlobalSkillEntity existing,
    GlobalSkillEntity remote,
  ) async {
    final mergeResult = StoreMergeUtil.mergeDeleteState(
      localDeleteTime: existing.deleteTime,
      localDeleted: existing.deleted,
      remoteDeleteTime: remote.deleteTime,
      remoteDeleted: remote.deleted,
      localUpdateTime: existing.updateTime,
      remoteUpdateTime: remote.updateTime,
    );
    final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
        existing.updateTime, remote.updateTime);
    final shouldUpdateDelete =
        mergeResult.mergedDeleteTime != existing.deleteTime ||
            mergeResult.mergedDeleted != existing.deleted;
    if (shouldUpdateData || shouldUpdateDelete) {
      await _globalSkillManager.updateSkill(
        (shouldUpdateData ? remote : existing).copyWith(
          deleted: mergeResult.mergedDeleted,
          deleteTime: mergeResult.mergedDeleteTime,
        ),
      );
      return true;
    }
    return false;
  }

  // ===== 项目同步内部实现 =====

  Future<Set<String>> _doSyncProjectsFromDevices() async {
    if (!_connectionManager.isConnected) return {};
    final devices = await _deviceRegistry.getOnlineDevices();
    final projectStore = ProjectStore(deviceId: _deviceId);
    final changedIds = <String>{};
    for (final device in devices) {
      if (device.id == _deviceId) continue;
      try {
        final result = await _connectionManager.invokeRemote(
          device.id,
          HostRpcConfig.methodGetAllProjects,
          {'includeDeleted': true},
        );
        for (final item in (result['result']['projects'] as List? ?? [])) {
          final itemMap = item as Map<String, dynamic>;

          // 合并项目主表
          if (itemMap.containsKey('project')) {
            final remote = ProjectEntity.fromMap(
              itemMap['project'] as Map<String, dynamic>,
            );
            final changed = projectStore.upsertFromRemote(remote);
            if (changed) {
              changedIds.add(remote.uuid);
            }
          }

          // 合并模块
          for (final m in (itemMap['modules'] as List? ?? [])) {
            final remote = ProjectModuleEntity.fromMap(m as Map<String, dynamic>);
            projectStore.upsertModuleFromRemote(remote);
          }

          // 合并技能
          for (final s in (itemMap['skills'] as List? ?? [])) {
            final remote = ProjectSkillEntity.fromMap(s as Map<String, dynamic>);
            projectStore.upsertSkillFromRemote(remote);
          }

          // 合并工单
          for (final i in (itemMap['issues'] as List? ?? [])) {
            final remote = ProjectIssueEntity.fromMap(i as Map<String, dynamic>);
            projectStore.upsertIssueFromRemote(remote);
          }
        }
        _log.debug('syncProjects from device ${device.id} success.');
      } catch (e) {
        _log.debug('syncProjects from device ${device.id} failed: $e');
      }
    }
    return changedIds;
  }

  // ===== 合并逻辑 =====

  Future<bool> _mergeAndSaveEmployee(
    AiEmployeeEntity existing,
    AiEmployeeEntity remote,
  ) async {
    final mergeResult = StoreMergeUtil.mergeDeleteState(
      localDeleteTime: existing.deletedTime,
      localDeleted: existing.deleted,
      remoteDeleteTime: remote.deletedTime,
      remoteDeleted: remote.deleted,
      localUpdateTime: existing.updateTime,
      remoteUpdateTime: remote.updateTime,
    );
    final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
        existing.updateTime, remote.updateTime);
    final shouldUpdateDelete =
        mergeResult.mergedDeleteTime != existing.deletedTime ||
            mergeResult.mergedDeleted != existing.deleted;
    if (shouldUpdateData || shouldUpdateDelete) {
      await _employeeManager.updateEmployee(
        (shouldUpdateData ? remote : existing).copyWith(
          deleted: mergeResult.mergedDeleted,
          deletedTime: mergeResult.mergedDeleteTime,
        ),
      );
      return true;
    }
    return false;
  }

  Future<bool> _mergeAndSaveSession(
    AiEmployeeSessionEntity existing,
    AiEmployeeSessionEntity remote,
  ) async {
    final mergeResult = StoreMergeUtil.mergeDeleteState(
      localDeleteTime: existing.deleteTime,
      localDeleted: existing.deleted,
      remoteDeleteTime: remote.deleteTime,
      remoteDeleted: remote.deleted,
      localUpdateTime: existing.updateTime,
      remoteUpdateTime: remote.updateTime,
    );
    final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
        existing.updateTime, remote.updateTime);
    final shouldUpdateDelete =
        mergeResult.mergedDeleteTime != existing.deleteTime ||
            mergeResult.mergedDeleted != existing.deleted;
    if (shouldUpdateData || shouldUpdateDelete) {
      await _sessionManager.save(
        (shouldUpdateData ? remote : existing).copyWith(
          deleted: mergeResult.mergedDeleted,
          deleteTime: mergeResult.mergedDeleteTime,
        ),
      );
      return true;
    }
    return false;
  }

  // ===== Folder Skill 文件同步 =====

  /// 同步 Folder Skill 文件内容
  ///
  /// 检测本地缺失的 folder skill 文件夹，从远端设备下载并解压。
  /// 在元数据同步完成后调用。
  ///
  /// 使用动态路径: skillsDir + skill.name（而非 config 中的 folder_path）。
  Future<void> syncFolderSkillFiles() async {
    if (!_connectionManager.isConnected) return;

    final deviceClient = DeviceClient.getInstance(_deviceId);

    final devices = await _deviceRegistry.getOnlineDevices();
    final otherDevices = devices.where((d) => d.id != _deviceId).toList();
    if (otherDevices.isEmpty) {
      _log.debug('syncFolderSkillFiles: 无其他在线设备，跳过');
      return;
    }

    // 收集需要文件同步的 folder skill
    final folderSkills = <Map<String, dynamic>>[];

    // 动态路径: skillsDir + skill.name
    final skillsDir = deviceClient.skillsDir;

    // 员工级
    final skills = await _skillManager.getAllSkills();
    for (final s in skills) {
      if (s.skillType == 'folder' && s.deleted != 1) {
        final folderPath = _resolveDynamicFolderPath(skillsDir, s.name);
        if (!await Directory(folderPath).exists()) {
          folderSkills.add({
            'skillId': s.uuid,
            'folderPath': folderPath,
            'skillName': s.name,
            'type': 'employee',
            'employeeId': s.employeeId,
          });
        }
      }
    }

    // 全局级
    final globalSkills = await _globalSkillManager.getAllSkills();
    for (final s in globalSkills) {
      if (s.skillType == 'folder' && s.deleted != 1) {
        final folderPath = _resolveDynamicFolderPath(skillsDir, s.name);
        if (!await Directory(folderPath).exists()) {
          folderSkills.add({
            'skillId': s.uuid,
            'folderPath': folderPath,
            'skillName': s.name,
            'type': 'global',
          });
        }
      }
    }

    if (folderSkills.isEmpty) {
      _log.debug('syncFolderSkillFiles: 所有 Folder Skill 文件夹已存在，无需同步');
      return;
    }

    _log.info('syncFolderSkillFiles: 发现 ${folderSkills.length} 个 Folder Skill 需要文件同步, 在线设备: ${otherDevices.map((d) => d.id).toList()}');

    // 逐个同步（串行，避免带宽争抢）
    for (final item in folderSkills) {
      final skillId = item['skillId'] as String;
      final skillName = item['skillName'] as String;
      final skillFolderPath = item['folderPath'] as String;

      for (final device in otherDevices) {
        try {
          _log.info('syncFolderSkillFiles: 开始同步 skill=$skillId, name=$skillName, fromDevice=${device.id}');

          final localPath = await deviceClient.syncFolderSkillFiles(
            fromDeviceId: device.id,
            folderPath: skillFolderPath,
            skillId: skillId,
            localSkillsDir: skillsDir,
            targetFolderName: skillName,
          );

          _log.info('syncFolderSkillFiles: 同步成功 skill=$skillId, localPath=$localPath');
          break; // 同步成功，跳出设备循环
        } catch (e) {
          _log.warn('syncFolderSkillFiles: 同步失败 skill=$skillId from ${device.id}: $e');
        }
      }
    }
  }

  /// 根据动态路径规则计算 folder skill 本地路径: skillsDir + skillName
  static String _resolveDynamicFolderPath(String skillsDir, String skillName) {
    return p.normalize(p.absolute(p.join(skillsDir, skillName)));
  }

  /// 定向同步单个 Folder Skill 文件
  ///
  /// 与 [syncFolderSkillFiles] 扫描全部缺失 skill 不同，此方法仅同步指定的单个 skill。
  /// 返回本地解压后的文件夹路径，失败返回 null。
  Future<String?> syncSingleFolderSkill(String skillId, String skillName, {String? originName}) async {
    if (!_connectionManager.isConnected) return null;

    final deviceClient = DeviceClient.getInstance(_deviceId);
    final skillsDir = deviceClient.skillsDir;
    final localPath = _resolveDynamicFolderPath(skillsDir, skillName);

    // 本地已存在则直接返回
    if (await Directory(localPath).exists()) {
      _log.debug('syncSingleFolderSkill: 本地已存在, path=$localPath');
      return localPath;
    }

    final devices = await _deviceRegistry.getOnlineDevices();
    final otherDevices = devices.where((d) => d.id != _deviceId).toList();
    if (otherDevices.isEmpty) {
      _log.debug('syncSingleFolderSkill: 无其他在线设备, skillName=$skillName');
      return null;
    }

    // 远端查找文件夹时优先使用 originName（原始文件夹名）
    final remoteFolderName = originName ?? skillName;

    for (final device in otherDevices) {
      try {
        _log.info('syncSingleFolderSkill: 开始同步 skillId=$skillId, name=$skillName, originName=$originName, fromDevice=${device.id}');

        final result = await deviceClient.syncFolderSkillFiles(
          fromDeviceId: device.id,
          folderPath: remoteFolderName,
          skillId: skillId,
          localSkillsDir: skillsDir,
          targetFolderName: skillName,
        );

        _log.info('syncSingleFolderSkill: 同步成功 skillId=$skillId, localPath=$result');
        return result;
      } catch (e) {
        _log.warn('syncSingleFolderSkill: 同步失败 skillId=$skillId from ${device.id}: $e');
      }
    }

    _log.warn('syncSingleFolderSkill: 所有设备均同步失败, skillId=$skillId');
    return null;
  }

}
