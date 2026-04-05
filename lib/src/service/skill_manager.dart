import 'dart:async';

import 'package:uuid/uuid.dart';

import '../persistence/persistence.dart';

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
  final String employeeUuid;
  final AiEmployeeSkillEntity? skill;

  SkillChangeEvent({
    required this.type,
    required this.skillUuid,
    required this.employeeUuid,
    this.skill,
  });
}

/// 技能管理器接口
abstract class SkillManager {
  /// 获取员工的技能列表
  Future<List<AiEmployeeSkillEntity>> getSkills(String employeeUuid);

  /// 获取单个技能
  Future<AiEmployeeSkillEntity?> getSkill(String uuid);

  /// 创建技能
  Future<AiEmployeeSkillEntity> createSkill(AiEmployeeSkillEntity skill);

  /// 更新技能
  Future<void> updateSkill(AiEmployeeSkillEntity skill);

  /// 删除技能
  Future<void> deleteSkill(String uuid);

  /// 启用/禁用技能
  Future<void> setSkillEnabled(String uuid, bool enabled);

  /// 技能变更通知流
  Stream<SkillChangeEvent> get onSkillChanged;
}

/// 技能管理器实现
class SkillManagerImpl implements SkillManager {
  final SkillStore _store;
  final String? _spaceId;
  final _changeController = StreamController<SkillChangeEvent>.broadcast();

  SkillManagerImpl({
    SkillStore? store,
    String? spaceId,
  })  : _store = store ?? SkillStore(),
        _spaceId = spaceId;

  @override
  Future<List<AiEmployeeSkillEntity>> getSkills(String employeeUuid) async {
    return _store.findByEmployeeWithSpaceId(_spaceId, employeeUuid);
  }

  @override
  Future<AiEmployeeSkillEntity?> getSkill(String uuid) async {
    return _store.find(_spaceId, uuid);
  }

  @override
  Future<AiEmployeeSkillEntity> createSkill(AiEmployeeSkillEntity skill) async {
    final now = DateTime.now();
    final newSkill = skill.copyWith(
      createTime: now,
      updateTime: now,
    );
    await _store.saveWithSpaceId(_spaceId, newSkill);
    _notifyChange(SkillChangeType.created, newSkill);
    return newSkill;
  }

  @override
  Future<void> updateSkill(AiEmployeeSkillEntity skill) async {
    final updated = skill.copyWith(
      updateTime: DateTime.now(),
    );
    await _store.saveWithSpaceId(_spaceId, updated);
    _notifyChange(SkillChangeType.updated, updated);
  }

  @override
  Future<void> deleteSkill(String uuid) async {
    final skill = await getSkill(uuid);
    await _store.delete(_spaceId, uuid);
    if (skill != null) {
      _notifyChange(SkillChangeType.deleted, skill);
    }
  }

  @override
  Future<void> setSkillEnabled(String uuid, bool enabled) async {
    final skill = await getSkill(uuid);
    if (skill == null) return;

    final updated = skill.copyWith(
      enabled: enabled ? 1 : 0,
      updateTime: DateTime.now(),
    );
    await _store.saveWithSpaceId(_spaceId, updated);
    _notifyChange(SkillChangeType.updated, updated);
  }

  @override
  Stream<SkillChangeEvent> get onSkillChanged => _changeController.stream;

  void _notifyChange(SkillChangeType type, AiEmployeeSkillEntity skill) {
    _changeController.add(SkillChangeEvent(
      type: type,
      skillUuid: skill.uuid,
      employeeUuid: skill.employeeUuid,
      skill: skill,
    ));
  }

  /// 创建新技能实体
  AiEmployeeSkillEntity createSkillEntity({
    required String employeeUuid,
    required String name,
    String? description,
    String skillType = 'mcp',
    String? config,
  }) {
    final uuid = const Uuid().v4();
    final now = DateTime.now();
    return AiEmployeeSkillEntity(
      uuid: uuid,
      employeeUuid: employeeUuid,
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
