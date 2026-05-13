import 'dart:async';

import 'package:uuid/uuid.dart';

import '../persistence/persistence.dart';
import '../utils/logger.dart';

/// 技能变更类型
enum SkillChangeType {
  created,
  updated,
  deleted,
}

/// 技能变更事件
class SkillChangeEvent {
  final SkillChangeType type;
  final String skillUuid;
  final String employeeId;
  final AiEmployeeSkillEntity? skill;

  SkillChangeEvent({
    required this.type,
    required this.skillUuid,
    required this.employeeId,
    this.skill,
  });
}

/// 技能管理器接口
///
/// Skill 绑定员工（employeeId），不绑定设备（deviceId）。
/// deviceId 仅用于确定数据库文件路径，不参与 skill 数据查询隔离。
abstract class SkillManager {
  static final Map<String, SkillManager> _instances = {};

  /// 按 deviceId 获取单例，不存在则自动创建
  /// deviceId 用于确定数据库文件路径，不参与 skill 数据查询隔离
  static SkillManager getInstance(String deviceId) {
    return _instances.putIfAbsent(
      deviceId,
      () => SkillManagerImpl(deviceId: deviceId),
    );
  }

  /// 移除指定 deviceId 的实例
  static void removeInstance(String deviceId) => _instances.remove(deviceId);

  /// 获取员工的技能列表（只按 employeeId）
  Future<List<AiEmployeeSkillEntity>> getSkills(String employeeId);

  /// 获取单个技能（只按 uuid）
  Future<AiEmployeeSkillEntity?> getSkill(String uuid);

  /// 创建技能
  Future<AiEmployeeSkillEntity> createSkill(AiEmployeeSkillEntity skill);

  /// 更新技能
  Future<void> updateSkill(AiEmployeeSkillEntity skill);

  /// 删除技能（软删除，保留原 deviceId）
  Future<void> deleteSkill(String uuid);

  /// 获取单个技能（包含已删除的，用于同步合并场景）
  Future<AiEmployeeSkillEntity?> getSkillIncludingDeleted(String uuid);

  /// 获取所有技能（包含已删除的，用于同步拉取）
  Future<List<AiEmployeeSkillEntity>> getAllSkills();

  /// 启用/禁用技能
  Future<void> setSkillEnabled(String uuid, bool enabled);

  /// 技能变更通知流
  Stream<SkillChangeEvent> get onSkillChanged;
}

/// 技能管理器实现
class SkillManagerImpl implements SkillManager {
  final SkillStore _store;
  final String? _deviceId;
  final _changeController = StreamController<SkillChangeEvent>.broadcast();
  final _log = Logger('SkillManager');

  SkillManagerImpl({
    SkillStore? store,
    String? deviceId,
  })  : _store = store ?? SkillStore(deviceId: deviceId),
        _deviceId = deviceId;

  @override
  Future<List<AiEmployeeSkillEntity>> getSkills(String employeeId) async {
    return _store.findByEmployee(employeeId);
  }

  @override
  Future<AiEmployeeSkillEntity?> getSkill(String uuid) async {
    return _store.find(uuid);
  }

  @override
  Future<AiEmployeeSkillEntity> createSkill(AiEmployeeSkillEntity skill) async {
    final now = DateTime.now();
    final newSkill = skill.copyWith(
      createTime: now,
      updateTime: now,
    );
    await _store.save(newSkill);
    _notifyChange(SkillChangeType.created, newSkill);
    return newSkill;
  }

  @override
  Future<void> updateSkill(AiEmployeeSkillEntity skill) async {
    final updated = skill.copyWith(
      updateTime: DateTime.now(),
    );
    await _store.save(updated);
    _notifyChange(SkillChangeType.updated, updated);
  }

  @override
  Future<void> deleteSkill(String uuid) async {
    _log.debug('deleteSkill: uuid=$uuid');
    final skill = await getSkillIncludingDeleted(uuid);
    if (skill == null) {
      _log.warn('deleteSkill: 技能不存在, uuid=$uuid');
      return;
    }
    _log.debug('deleteSkill: 找到技能, name=${skill.name}, skillType=${skill.skillType}, employeeId=${skill.employeeId}');
    final updated = skill.copyWith(
      deleted: 1,
      deleteTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    try {
      await _store.save(updated);
      _log.info('deleteSkill: 删除成功, uuid=$uuid, name=${skill.name}');
    } catch (e, st) {
      _log.error('deleteSkill: 保存失败, uuid=$uuid, name=${skill.name}', e, st);
      rethrow;
    }
    _notifyChange(SkillChangeType.deleted, updated);
  }

  @override
  Future<AiEmployeeSkillEntity?> getSkillIncludingDeleted(String uuid) async {
    return _store.findIncludingDeleted(uuid);
  }

  @override
  Future<List<AiEmployeeSkillEntity>> getAllSkills() async {
    return _store.findAll();
  }

  @override
  Future<void> setSkillEnabled(String uuid, bool enabled) async {
    final skill = await getSkillIncludingDeleted(uuid);
    if (skill == null || skill.deleted == 1) return;

    final updated = skill.copyWith(
      enabled: enabled ? 1 : 0,
      updateTime: DateTime.now(),
    );
    await _store.save(updated);
    _notifyChange(SkillChangeType.updated, updated);
  }

  @override
  Stream<SkillChangeEvent> get onSkillChanged => _changeController.stream;

  void _notifyChange(SkillChangeType type, AiEmployeeSkillEntity skill) {
    _changeController.add(SkillChangeEvent(
      type: type,
      skillUuid: skill.uuid,
      employeeId: skill.employeeId,
      skill: skill,
    ));
  }

  /// 创建新技能实体
  AiEmployeeSkillEntity createSkillEntity({
    required String employeeId,
    required String name,
    String? description,
    String skillType = 'mcp',
    String? config,
  }) {
    final uuid = const Uuid().v4();
    final now = DateTime.now();
    return AiEmployeeSkillEntity(
      uuid: uuid,
      employeeId: employeeId,
      name: name,
      description: description,
      skillType: skillType,
      config: config,
      createTime: now,
      updateTime: now,
    );
  }

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}