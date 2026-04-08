import 'dart:convert';

import '../hive_manager.dart';
import '../entities/skill_entity.dart';

/// 技能数据存储
class SkillStore {
  final HiveManager _hiveManager;

  SkillStore({HiveManager? hiveManager})
      : _hiveManager = hiveManager ?? HiveManager.instance;

  /// 解码JSON字符串为实体
  AiEmployeeSkillEntity? _decodeEntity(dynamic jsonString) {
    if (jsonString == null) return null;
    if (jsonString is String && jsonString.isNotEmpty) {
      return AiEmployeeSkillEntity.fromMap(
        jsonDecode(jsonString) as Map<String, dynamic>,
      );
    }
    return null;
  }

  /// 获取员工的技能列表
  Future<List<AiEmployeeSkillEntity>> findByEmployee(
    String? deviceId,
    String employeeId,
  ) async {
    final box = _hiveManager.skillBox;
    final prefix = deviceId != null ? ':$deviceId:' : '::';

    var skills = <AiEmployeeSkillEntity>[];
    for (final key in box.keys) {
      final entity = _decodeEntity(box.get(key));
      if (entity == null) continue;
      final buildKey = _hiveManager.buildSkillKey(
        entity.employeeId.split('-').first,
        entity.uuid,
      );
      if (!buildKey.contains(prefix)) continue;
      if (entity.deleted == 1) continue;
      if (entity.employeeId != employeeId) continue;
      skills.add(entity);
    }

    // 按排序序号排序
    skills.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    return skills;
  }

  /// 使用明确deviceId获取员工技能
  Future<List<AiEmployeeSkillEntity>> findByEmployeeWithDeviceId(
    String? deviceId,
    String employeeId,
  ) async {
    final box = _hiveManager.skillBox;

    var skills = <AiEmployeeSkillEntity>[];
    for (final key in box.keys) {
      final entity = _decodeEntity(box.get(key));
      if (entity == null) continue;
      if (entity.deleted == 1) continue;
      if (entity.employeeId != employeeId) continue;
      skills.add(entity);
    }

    // 按排序序号排序
    skills.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    return skills;
  }

  /// 查找单个技能
  Future<AiEmployeeSkillEntity?> find(String? deviceId, String uuid) async {
    final box = _hiveManager.skillBox;
    final key = _hiveManager.buildSkillKey(deviceId, uuid);
    return _decodeEntity(box.get(key));
  }

  /// 保存技能
  Future<void> save(AiEmployeeSkillEntity entity) async {
    final box = _hiveManager.skillBox;
    final key = _hiveManager.buildSkillKey(
      entity.employeeId.split('-').first,
      entity.uuid,
    );
    await box.put(key, jsonEncode(entity.toMap()));
  }

  /// 使用明确deviceId保存技能
  Future<void> saveWithDeviceId(
    String? deviceId,
    AiEmployeeSkillEntity entity,
  ) async {
    final box = _hiveManager.skillBox;
    final key = _hiveManager.buildSkillKey(deviceId, entity.uuid);
    await box.put(key, jsonEncode(entity.toMap()));
  }

  /// 删除技能（软删除）
  Future<void> delete(String? deviceId, String uuid) async {
    final box = _hiveManager.skillBox;
    final key = _hiveManager.buildSkillKey(deviceId, uuid);
    final entity = _decodeEntity(box.get(key));
    if (entity != null) {
      await box.put(key, jsonEncode(entity.copyWith(deleted: 1).toMap()));
    }
  }

  /// 硬删除技能
  Future<void> hardDelete(String? deviceId, String uuid) async {
    final box = _hiveManager.skillBox;
    final key = _hiveManager.buildSkillKey(deviceId, uuid);
    await box.delete(key);
  }

  /// 删除员工的所有技能
  Future<void> deleteByEmployee(
    String? deviceId,
    String employeeId,
  ) async {
    final skills = await findByEmployeeWithDeviceId(deviceId, employeeId);
    for (final skill in skills) {
      await delete(deviceId, skill.uuid);
    }
  }

  /// 获取技能数量
  Future<int> count(String? deviceId, String employeeId) async {
    final skills = await findByEmployeeWithDeviceId(deviceId, employeeId);
    return skills.length;
  }
}
