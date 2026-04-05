import 'dart:async';

import '../persistence/persistence.dart';

/// 员工变更类型
enum EmployeeChangeType { created, updated, deleted }

/// 员工变更事件
class EmployeeChangeEvent {
  final EmployeeChangeType type;
  final String employeeUuid;
  final AiEmployeeEntity? employee;

  EmployeeChangeEvent({
    required this.type,
    required this.employeeUuid,
    this.employee,
  });
}

/// 员工统计信息
class EmployeeStats {
  final int totalCount;
  final int activeCount;
  final int pinnedCount;

  EmployeeStats({
    required this.totalCount,
    required this.activeCount,
    required this.pinnedCount,
  });
}

/// 员工管理器接口
abstract class EmployeeManager {
  /// 获取员工列表
  Future<List<AiEmployeeEntity>> getEmployees({
    String? keyword,
    String? status,
  });

  /// 获取单个员工
  Future<AiEmployeeEntity?> getEmployee(String uuid);

  /// 创建员工
  Future<AiEmployeeEntity> createEmployee(AiEmployeeEntity employee);

  /// 更新员工
  Future<void> updateEmployee(AiEmployeeEntity employee);

  /// 更新员工当前设备ID（会话漫游）
  Future<void> updateCurrentDeviceId(String uuid, String deviceId);

  /// 删除员工（软删除）
  Future<void> deleteEmployee(String uuid);

  /// 获取员工统计信息
  Future<EmployeeStats> getEmployeeStats();

  /// 员工变更通知流
  Stream<EmployeeChangeEvent> get onEmployeeChanged;
}

/// 员工管理器实现
class EmployeeManagerImpl implements EmployeeManager {
  final EmployeeStore _store;
  final String _deviceId;
  final _changeController = StreamController<EmployeeChangeEvent>.broadcast();

  EmployeeManagerImpl({
    EmployeeStore? store,
    String deviceId = 'default',
  })  : _store = store ?? EmployeeStore(),
        _deviceId = deviceId;

  @override
  Future<List<AiEmployeeEntity>> getEmployees({
    String? keyword,
    String? status,
  }) async {
    return _store.findAll(_deviceId, keyword: keyword, status: status);
  }

  @override
  Future<AiEmployeeEntity?> getEmployee(String uuid) async {
    return _store.find(_deviceId, uuid);
  }

  @override
  Future<AiEmployeeEntity> createEmployee(AiEmployeeEntity employee) async {
    final now = DateTime.now();
    final newEmployee = employee.copyWith(
      spaceId: _deviceId,
      createTime: now,
      updateTime: now,
    );
    await _store.save(newEmployee);
    _notifyChange(EmployeeChangeType.created, newEmployee);
    return newEmployee;
  }

  @override
  Future<void> updateEmployee(AiEmployeeEntity employee) async {
    final updated = employee.copyWith(updateTime: DateTime.now());
    await _store.save(updated);
    _notifyChange(EmployeeChangeType.updated, updated);
  }

  @override
  Future<void> updateCurrentDeviceId(String uuid, String deviceId) async {
    final employee = await getEmployee(uuid);
    if (employee == null) return;

    final updated = employee.copyWith(
      currentDeviceId: deviceId,
      updateTime: DateTime.now(),
    );
    await _store.save(updated);
    _notifyChange(EmployeeChangeType.updated, updated);
  }

  @override
  Future<void> deleteEmployee(String uuid) async {
    await _store.delete(_deviceId, uuid);
    _notifyChange(EmployeeChangeType.deleted, uuid);
  }

  @override
  Future<EmployeeStats> getEmployeeStats() async {
    final all = await _store.findAll(_deviceId);
    final active = all.where((e) => e.status == 'active').toList();
    final pinned = all.where((e) => e.isPinned == 1).toList();
    return EmployeeStats(
      totalCount: all.length,
      activeCount: active.length,
      pinnedCount: pinned.length,
    );
  }

  @override
  Stream<EmployeeChangeEvent> get onEmployeeChanged => _changeController.stream;

  void _notifyChange(EmployeeChangeType type, dynamic employeeOrUuid) {
    if (employeeOrUuid is AiEmployeeEntity) {
      _changeController.add(
        EmployeeChangeEvent(
          type: type,
          employeeUuid: employeeOrUuid.uuid,
          employee: employeeOrUuid,
        ),
      );
    } else if (employeeOrUuid is String) {
      _changeController.add(
        EmployeeChangeEvent(type: type, employeeUuid: employeeOrUuid),
      );
    }
  }

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}
