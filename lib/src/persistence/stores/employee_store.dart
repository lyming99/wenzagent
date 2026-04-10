import 'dart:convert';

import '../hive_manager.dart';
import '../entities/employee_entity.dart';

/// 员工数据存储
///
/// 使用 LazyBox 实现异步读取，避免主线程阻塞。
class EmployeeStore {
  final HiveManager _hiveManager;

  EmployeeStore({HiveManager? hiveManager})
      : _hiveManager = hiveManager ?? HiveManager.instance;

  /// 解码JSON字符串为实体
  AiEmployeeEntity? _decodeEntity(dynamic jsonString) {
    if (jsonString == null) return null;
    if (jsonString is String && jsonString.isNotEmpty) {
      return AiEmployeeEntity.fromMap(
        jsonDecode(jsonString) as Map<String, dynamic>,
      );
    }
    return null;
  }

  /// 查找所有员工
  Future<List<AiEmployeeEntity>> findAll(
    String? spaceId, {
    String? keyword,
    String? status,
  }) async {
    final box = _hiveManager.employeeBox;
    final prefix = spaceId != null ? ':$spaceId:' : '::';

    var employees = <AiEmployeeEntity>[];
    for (final key in box.keys) {
      final entity = _decodeEntity(await box.get(key));
      if (entity == null) continue;
      final buildKey = _hiveManager.buildEmployeeKey(entity.spaceId, entity.uuid);
      if (!buildKey.contains(prefix)) continue;
      if (entity.deleted == 1) continue;
      if (status != null && entity.status != status) continue;
      if (keyword != null &&
          keyword.isNotEmpty &&
          !entity.name.toLowerCase().contains(keyword.toLowerCase()) &&
          !(entity.description?.toLowerCase().contains(keyword.toLowerCase()) ??
              false)) {
        continue;
      }
      employees.add(entity);
    }

    // 按置顶和排序序号排序
    employees.sort((a, b) {
      if (a.isPinned != b.isPinned) {
        return b.isPinned.compareTo(a.isPinned);
      }
      return a.sortOrder.compareTo(b.sortOrder);
    });

    return employees;
  }

  /// 查找单个员工
  Future<AiEmployeeEntity?> find(String? spaceId, String uuid) async {
    final box = _hiveManager.employeeBox;
    final key = _hiveManager.buildEmployeeKey(spaceId, uuid);
    return _decodeEntity(await box.get(key));
  }

  /// 保存员工
  Future<void> save(AiEmployeeEntity entity) async {
    final box = _hiveManager.employeeBox;
    final key = _hiveManager.buildEmployeeKey(entity.spaceId, entity.uuid);
    await box.put(key, jsonEncode(entity.toMap()));
  }

  /// 删除员工（软删除）
  Future<void> delete(String? spaceId, String uuid) async {
    final box = _hiveManager.employeeBox;
    final key = _hiveManager.buildEmployeeKey(spaceId, uuid);
    final entity = _decodeEntity(await box.get(key));
    if (entity != null) {
      await box.put(
        key,
        jsonEncode(
          entity
              .copyWith(
                deleted: 1,
                deletedTime: DateTime.now(),
              )
              .toMap(),
        ),
      );
    }
  }

  /// 获取员工数量
  Future<int> count(String? spaceId, {String? status}) async {
    final employees = await findAll(spaceId, status: status);
    return employees.length;
  }

  /// 检查员工是否存在
  Future<bool> exists(String? spaceId, String uuid) async {
    final box = _hiveManager.employeeBox;
    final key = _hiveManager.buildEmployeeKey(spaceId, uuid);
    return box.containsKey(key);
  }
}
