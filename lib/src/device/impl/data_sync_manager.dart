import '../../host/host_rpc_methods.dart';
import '../../persistence/persistence.dart';
import '../../persistence/store_merge_util.dart';
import '../../persistence/stores/spec_store.dart';
import '../../persistence/entities/spec_item_entity.dart';
import '../../persistence/stores/todo_store.dart';
import '../../persistence/entities/todo_topic_entity.dart';
import '../../persistence/entities/todo_task_item_entity.dart';
import '../../service/service.dart';
import '../../utils/logger.dart';
import '../app_context.dart';
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

  /// 同步全部数据（员工+会话+会话摘要+spec，并行执行）
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
          final data = result['employee'] as Map<String, dynamic>?;
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
      return (result['count'] as int? ?? 0) > 0;
    } catch (e) {
      _log.error('同步员工到设备 $targetDeviceId 失败', e);
      return false;
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
        for (final data in (result['employees'] as List? ?? [])) {
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
        for (final data in (result['sessions'] as List? ?? [])) {
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
        final summaries = (result['summaries'] as List? ?? [])
            .map((s) => SessionSummaryEntity.fromMap(s as Map<String, dynamic>))
            .toList();
        for (final summary in summaries) {
          print("${summary.deviceId}==>${summary.unreadCount}");
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
            final specs = (result['specs'] as List? ?? [])
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
            final topics = (result['topics'] as List? ?? [])
                .map((t) => TodoTopicEntity.fromMap(t as Map<String, dynamic>))
                .toList();
            final taskItems = (result['taskItems'] as List? ?? [])
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

}
