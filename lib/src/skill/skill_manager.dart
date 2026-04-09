import 'dart:async';

import 'skill.dart';
import 'skill_context.dart';

/// 技能变更事件
class SkillEvent {
  /// 技能ID
  final String skillId;

  /// 事件类型：added | removed | reloaded | error
  final String type;

  /// 附加数据
  final dynamic data;

  SkillEvent({required this.skillId, required this.type, this.data});
}

/// 技能生命周期管理器（运行时）
///
/// 统一管理三种 Skill 的加载、激活、卸载。
/// 核心职责：将 Skill 产出的 AgentTool 注册/注销到 ToolRegistry。
///
/// 与 service/skill_manager.dart 中的 SkillManager（持久化 CRUD）职责分离：
/// - SkillManager / SkillManagerImpl：数据库 CRUD、持久化
/// - SkillLifecycleManager（此类）：运行时生命周期管理、工具注册/注销
class SkillLifecycleManager {
  final SkillContext _context;
  final Map<String, Skill> _skills = {};
  final _eventController = StreamController<SkillEvent>.broadcast(sync: true);

  SkillLifecycleManager(this._context);

  /// 加载并激活技能
  Future<void> loadSkill(Skill skill) async {
    try {
      print('[SkillLifecycle] 开始加载技能: id=${skill.id}, name=${skill.name}, type=${skill.runtimeType}');

      await skill.initialize();
      print('[SkillLifecycle] 技能初始化完成: ${skill.name}, tools=[${skill.tools.map((t) => t.name).join(', ')}]');

      await skill.activate();
      print('[SkillLifecycle] 技能激活完成: ${skill.name}');

      for (final tool in skill.tools) {
        final existed = _context.toolRegistry.contains(tool.name);
        if (existed) {
          _context.toolRegistry.registerOrReplaceTool(tool);
          print('[SkillLifecycle] 工具已替换: ${tool.name}');
        } else {
          _context.toolRegistry.registerTool(tool);
          print('[SkillLifecycle] 工具已注册: ${tool.name}');
        }
      }

      _skills[skill.id] = skill;
      _eventController.add(SkillEvent(
        skillId: skill.id,
        type: 'added',
        data: {'name': skill.name, 'toolCount': skill.tools.length},
      ));
      print('[SkillLifecycle] 技能加载成功: ${skill.name}, 共注册 ${skill.tools.length} 个工具');
    } catch (e, st) {
      _context.logger('error', '技能加载失败: ${skill.name}, $e\n$st');
      _eventController.add(SkillEvent(
        skillId: skill.id, type: 'error', data: {'error': e.toString()},
      ));
      rethrow;
    }
  }

  /// 卸载技能
  Future<void> unloadSkill(String skillId) async {
    final skill = _skills.remove(skillId);
    if (skill == null) return;

    for (final tool in skill.tools) {
      _context.toolRegistry.unregisterTool(tool.name);
    }
    await skill.deactivate();
    await skill.dispose();

    _eventController.add(SkillEvent(
      skillId: skillId, type: 'removed',
    ));
  }

  /// 重新加载技能
  Future<void> reloadSkill(String skillId) async {
    final skill = _skills[skillId];
    if (skill == null) return;

    // 注销旧工具
    for (final tool in skill.tools) {
      _context.toolRegistry.unregisterTool(tool.name);
    }
    await skill.deactivate();
    await skill.dispose();

    // 重新初始化
    await skill.initialize();
    await skill.activate();

    for (final tool in skill.tools) {
      _context.toolRegistry.registerOrReplaceTool(tool);
    }

    _eventController.add(SkillEvent(skillId: skillId, type: 'reloaded'));
  }

  /// 获取所有已加载技能
  List<Skill> get skills => _skills.values.toList();

  /// 根据ID获取技能
  Skill? getSkill(String id) => _skills[id];

  /// 技能变更事件流
  Stream<SkillEvent> get onEvent => _eventController.stream;

  /// 释放所有技能资源
  Future<void> dispose() async {
    for (final skill in _skills.values) {
      try {
        await skill.dispose();
      } catch (_) {}
    }
    _skills.clear();
    await _eventController.close();
  }
}
