import 'dart:convert';

import '../hive_manager.dart';
import '../entities/scheduled_task_entity.dart';

/// 定时任务数据存储
///
/// 使用 LazyBox 实现异步读取，避免主线程阻塞。
class ScheduledTaskStore {
  final HiveManager _hiveManager;
  static const String _boxKey = 'scheduled_task_box';

  ScheduledTaskStore({HiveManager? hiveManager})
      : _hiveManager = hiveManager ?? HiveManager.instance;

  AiScheduledTaskEntity? _decodeEntity(dynamic jsonString) {
    if (jsonString == null) return null;
    if (jsonString is String && jsonString.isNotEmpty) {
      return AiScheduledTaskEntity.fromMap(
        jsonDecode(jsonString) as Map<String, dynamic>,
      );
    }
    return null;
  }

  /// 获取所有未删除的任务
  Future<List<AiScheduledTaskEntity>> findAll() async {
    final box = _hiveManager.getBox(_boxKey);

    final tasks = <AiScheduledTaskEntity>[];
    for (final key in box.keys) {
      final entity = _decodeEntity(await box.get(key));
      if (entity != null && entity.deleted == 0) {
        tasks.add(entity);
      }
    }
    tasks.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return tasks;
  }

  /// 获取指定员工的任务
  Future<List<AiScheduledTaskEntity>> findByEmployee(
      String employeeId) async {
    final all = await findAll();
    return all.where((t) => t.employeeId == employeeId).toList();
  }

  /// 查找单个任务
  Future<AiScheduledTaskEntity?> find(String uuid) async {
    final box = _hiveManager.getBox(_boxKey);
    final key = _buildKey(uuid);
    return _decodeEntity(await box.get(key));
  }

  /// 保存任务
  Future<void> save(AiScheduledTaskEntity entity) async {
    final box = _hiveManager.getBox(_boxKey);
    final key = _buildKey(entity.uuid);
    await box.put(key, jsonEncode(entity.toMap()));
  }

  /// 删除任务（软删除）
  Future<void> delete(String uuid) async {
    final entity = await find(uuid);
    if (entity != null) {
      await save(entity.copyWith(
        deleted: 1,
        enabled: 0,
        updateTime: DateTime.now(),
      ));
    }
  }

  /// 硬删除
  Future<void> hardDelete(String uuid) async {
    final box = _hiveManager.getBox(_boxKey);
    await box.delete(_buildKey(uuid));
  }

  /// 删除员工的所有任务
  Future<void> deleteByEmployee(String employeeId) async {
    final tasks = await findByEmployee(employeeId);
    for (final task in tasks) {
      await delete(task.uuid);
    }
  }

  /// 获取需要执行的任务
  Future<List<AiScheduledTaskEntity>> findDueTasks() async {
    final now = DateTime.now();
    final all = await findAll();
    return all.where((t) {
      if (!t.isEnabled) return false;
      if (!t.isStarted) return false;
      if (t.isExpired) return false;
      if (t.nextExecutionAt == null) return false;
      return !now.isBefore(t.nextExecutionAt!);
    }).toList();
  }

  String _buildKey(String uuid) => 'wenz_stask:$uuid';
}
