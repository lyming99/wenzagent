import 'dart:async';

import 'package:uuid/uuid.dart';

import '../persistence/persistence.dart';

/// 全局技能变更类型
enum GlobalSkillChangeType {
  created,
  updated,
  deleted,
}

/// 全局技能变更事件
class GlobalSkillChangeEvent {
  final GlobalSkillChangeType type;
  final String skillUuid;
  final GlobalSkillEntity? skill;

  GlobalSkillChangeEvent({
    required this.type,
    required this.skillUuid,
    this.skill,
  });
}

/// 全局技能管理器
///
/// 管理独立于员工的全局技能库，提供增删改查和变更通知。
/// 使用单例模式，按 deviceId 隔离。
abstract class GlobalSkillManager {
  static final Map<String, GlobalSkillManager> _instances = {};

  /// 按 deviceId 获取单例，不存在则自动创建
  static GlobalSkillManager getInstance(String deviceId) {
    return _instances.putIfAbsent(
      deviceId,
      () => GlobalSkillManagerImpl(deviceId: deviceId),
    );
  }

  /// 移除指定 deviceId 的实例
  static void removeInstance(String deviceId) =>
      _instances.remove(deviceId);

  /// 获取所有技能
  Future<List<GlobalSkillEntity>> getAllSkills();

  /// 获取单个技能
  Future<GlobalSkillEntity?> getSkill(String uuid);

  /// 创建技能
  Future<GlobalSkillEntity> createSkill(GlobalSkillEntity skill);

  /// 更新技能
  Future<void> updateSkill(GlobalSkillEntity skill);

  /// 删除技能
  Future<void> deleteSkill(String uuid);

  /// 获取单个技能（包含已删除的，用于同步合并场景）
  Future<GlobalSkillEntity?> getSkillIncludingDeleted(String uuid);

  /// 获取所有技能（包含已删除的，用于同步拉取）
  Future<List<GlobalSkillEntity>> getAllSkillsIncludingDeleted();

  /// 启用/禁用技能
  Future<void> setSkillEnabled(String uuid, bool enabled);

  /// 搜索技能
  Future<List<GlobalSkillEntity>> searchSkills(String keyword);

  /// 技能变更通知流
  Stream<GlobalSkillChangeEvent> get onSkillChanged;
}

/// 全局技能管理器实现
class GlobalSkillManagerImpl implements GlobalSkillManager {
  final GlobalSkillStore _store;
  final _changeController =
      StreamController<GlobalSkillChangeEvent>.broadcast();

  GlobalSkillManagerImpl({
    GlobalSkillStore? store,
    String? deviceId,
  })  : _store = store ?? GlobalSkillStore(deviceId: deviceId);

  @override
  Future<List<GlobalSkillEntity>> getAllSkills() async {
    return _store.findAll();
  }

  @override
  Future<GlobalSkillEntity?> getSkill(String uuid) async {
    return _store.find(uuid);
  }

  @override
  Future<GlobalSkillEntity> createSkill(GlobalSkillEntity skill) async {
    final now = DateTime.now();
    final newSkill = skill.copyWith(
      createTime: now,
      updateTime: now,
    );
    await _store.save(newSkill);
    _notifyChange(GlobalSkillChangeType.created, newSkill);
    return newSkill;
  }

  @override
  Future<void> updateSkill(GlobalSkillEntity skill) async {
    final updated = skill.copyWith(
      updateTime: DateTime.now(),
    );
    await _store.save(updated);
    _notifyChange(GlobalSkillChangeType.updated, updated);
  }

  @override
  Future<void> deleteSkill(String uuid) async {
    final skill = await getSkill(uuid);
    if (skill == null) return;
    final updated = skill.copyWith(
      deleted: 1,
      deleteTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await _store.save(updated);
    _notifyChange(GlobalSkillChangeType.deleted, updated);
  }

  @override
  Future<GlobalSkillEntity?> getSkillIncludingDeleted(String uuid) async {
    return _store.findIncludingDeleted(uuid);
  }

  @override
  Future<List<GlobalSkillEntity>> getAllSkillsIncludingDeleted() async {
    return _store.findAllIncludingDeleted();
  }

  @override
  Future<void> setSkillEnabled(String uuid, bool enabled) async {
    final skill = await getSkill(uuid);
    if (skill == null) return;

    final updated = skill.copyWith(
      enabled: enabled ? 1 : 0,
      updateTime: DateTime.now(),
    );
    await _store.save(updated);
    _notifyChange(GlobalSkillChangeType.updated, updated);
  }

  @override
  Future<List<GlobalSkillEntity>> searchSkills(String keyword) async {
    if (keyword.isEmpty) return getAllSkills();
    return _store.search(keyword);
  }

  @override
  Stream<GlobalSkillChangeEvent> get onSkillChanged =>
      _changeController.stream;

  void _notifyChange(GlobalSkillChangeType type, GlobalSkillEntity skill) {
    _changeController.add(GlobalSkillChangeEvent(
      type: type,
      skillUuid: skill.uuid,
      skill: skill,
    ));
  }

  /// 创建新技能实体（便捷方法）
  GlobalSkillEntity createSkillEntity({
    required String name,
    String? description,
    String skillType = 'config',
    String? config,
  }) {
    final uuid = const Uuid().v4();
    final now = DateTime.now();
    return GlobalSkillEntity(
      uuid: uuid,
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
