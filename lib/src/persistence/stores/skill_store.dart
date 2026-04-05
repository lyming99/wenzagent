import '../hive_manager.dart';
import '../entities/skill_entity.dart';

/// 技能数据存储
class SkillStore {
  final HiveManager _hiveManager;

  SkillStore({HiveManager? hiveManager})
      : _hiveManager = hiveManager ?? HiveManager.instance;

  /// 获取员工的技能列表
  Future<List<AiEmployeeSkillEntity>> findByEmployee(
    String? deviceId,
    String employeeUuid,
  ) async {
    final box = _hiveManager.skillBox;
    final prefix = deviceId != null ? ':$deviceId:' : '::';

    var skills = box.values.where((s) {
      final key = _hiveManager.buildSkillKey(s.employeeUuid.split('-').first, s.uuid);
      if (!key.contains(prefix)) return false;
      if (s.deleted == 1) return false;
      if (s.employeeUuid != employeeUuid) return false;
      return true;
    }).toList();

    // 按排序序号排序
    skills.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    return skills;
  }

  /// 使用明确deviceId获取员工技能
  Future<List<AiEmployeeSkillEntity>> findByEmployeeWithDeviceId(
    String? deviceId,
    String employeeUuid,
  ) async {
    final box = _hiveManager.skillBox;

    var skills = box.values.where((s) {
      if (s.deleted == 1) return false;
      if (s.employeeUuid != employeeUuid) return false;
      return true;
    }).toList();

    // 按排序序号排序
    skills.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    return skills;
  }

  /// 查找单个技能
  Future<AiEmployeeSkillEntity?> find(String? deviceId, String uuid) async {
    final box = _hiveManager.skillBox;
    final key = _hiveManager.buildSkillKey(deviceId, uuid);
    return box.get(key);
  }

  /// 保存技能
  Future<void> save(AiEmployeeSkillEntity entity) async {
    final box = _hiveManager.skillBox;
    final key = _hiveManager.buildSkillKey(entity.employeeUuid.split('-').first, entity.uuid);
    await box.put(key, entity);
  }

  /// 使用明确deviceId保存技能
  Future<void> saveWithDeviceId(String? deviceId, AiEmployeeSkillEntity entity) async {
    final box = _hiveManager.skillBox;
    final key = _hiveManager.buildSkillKey(deviceId, entity.uuid);
    await box.put(key, entity);
  }

  /// 删除技能（软删除）
  Future<void> delete(String? deviceId, String uuid) async {
    final box = _hiveManager.skillBox;
    final key = _hiveManager.buildSkillKey(deviceId, uuid);
    final entity = box.get(key);
    if (entity != null) {
      await box.put(key, entity.copyWith(deleted: 1));
    }
  }

  /// 硬删除技能
  Future<void> hardDelete(String? deviceId, String uuid) async {
    final box = _hiveManager.skillBox;
    final key = _hiveManager.buildSkillKey(deviceId, uuid);
    await box.delete(key);
  }

  /// 删除员工的所有技能
  Future<void> deleteByEmployee(String? deviceId, String employeeUuid) async {
    final skills = await findByEmployeeWithDeviceId(deviceId, employeeUuid);
    for (final skill in skills) {
      await delete(deviceId, skill.uuid);
    }
  }

  /// 获取技能数量
  Future<int> count(String? deviceId, String employeeUuid) async {
    final skills = await findByEmployeeWithDeviceId(deviceId, employeeUuid);
    return skills.length;
  }
}
