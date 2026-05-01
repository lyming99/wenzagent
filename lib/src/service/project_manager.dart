import 'dart:async';

import '../persistence/persistence.dart';

/// 项目变更类型
enum ProjectChangeType { created, updated, deleted }

/// 项目变更事件
class ProjectChangeEvent {
  final ProjectChangeType type;
  final String projectUuid;
  final ProjectEntity? project;

  ProjectChangeEvent({
    required this.type,
    required this.projectUuid,
    this.project,
  });
}

/// 项目管理器接口
///
/// 管理项目及其子资源（模块、技能、工单），提供增删改查和变更通知。
/// 使用单例模式，按 deviceId 隔离。
abstract class ProjectManager {
  static final Map<String, ProjectManager> _instances = {};

  /// 按 deviceId 获取单例，不存在则自动创建
  static ProjectManager getInstance(String deviceId) {
    return _instances.putIfAbsent(
      deviceId,
      () => ProjectManagerImpl(deviceId: deviceId),
    );
  }

  /// 移除指定 deviceId 的实例
  static void removeInstance(String deviceId) =>
      _instances.remove(deviceId);

  // ==================== 项目 ====================

  /// 获取所有项目
  Future<List<ProjectEntity>> getAllProjects();

  /// 搜索项目
  Future<List<ProjectEntity>> searchProjects(String keyword);

  /// 获取单个项目
  Future<ProjectEntity?> getProject(String uuid);

  /// 创建项目
  Future<ProjectEntity> createProject(ProjectEntity project);

  /// 保存项目（同步场景，不修改时间戳）
  Future<void> saveProject(ProjectEntity project);

  /// 更新项目
  Future<void> updateProject(ProjectEntity project);

  /// 删除项目（软删除）
  Future<void> deleteProject(String uuid);

  // ==================== 模块 ====================

  /// 获取项目的模块列表
  Future<List<ProjectModuleEntity>> getModules(String projectUuid);

  /// 创建模块
  Future<ProjectModuleEntity> createModule(ProjectModuleEntity module);

  /// 保存模块（同步场景）
  Future<void> saveModule(ProjectModuleEntity module);

  /// 更新模块
  Future<void> updateModule(ProjectModuleEntity module);

  /// 删除模块
  Future<void> deleteModule(String uuid);

  // ==================== 技能 ====================

  /// 获取项目的技能列表
  Future<List<ProjectSkillEntity>> getSkills(String projectUuid);

  /// 创建技能
  Future<ProjectSkillEntity> createSkill(ProjectSkillEntity skill);

  /// 保存技能（同步场景）
  Future<void> saveSkill(ProjectSkillEntity skill);

  /// 更新技能
  Future<void> updateSkill(ProjectSkillEntity skill);

  /// 删除技能
  Future<void> deleteSkill(String uuid);

  // ==================== 工单 ====================

  /// 获取项目的工单列表
  Future<List<ProjectIssueEntity>> getIssues(String projectUuid, {String? status});

  /// 创建工单
  Future<ProjectIssueEntity> createIssue(ProjectIssueEntity issue);

  /// 保存工单（同步场景）
  Future<void> saveIssue(ProjectIssueEntity issue);

  /// 更新工单
  Future<void> updateIssue(ProjectIssueEntity issue);

  /// 关闭工单
  Future<void> closeIssue(String uuid);

  /// 删除工单
  Future<void> deleteIssue(String uuid);

  // ==================== 变更通知 ====================

  /// 项目变更通知流
  Stream<ProjectChangeEvent> get onProjectChanged;
}

/// 项目管理器实现
class ProjectManagerImpl implements ProjectManager {
  final ProjectStore _store;
  final _changeController = StreamController<ProjectChangeEvent>.broadcast();

  ProjectManagerImpl({
    ProjectStore? store,
    String deviceId = 'default',
  })  : _store = store ?? ProjectStore(deviceId: deviceId);

  // ==================== 项目 ====================

  @override
  Future<List<ProjectEntity>> getAllProjects() async {
    return _store.findAllProjects();
  }

  @override
  Future<List<ProjectEntity>> searchProjects(String keyword) async {
    if (keyword.isEmpty) return getAllProjects();
    return _store.searchProjects(keyword);
  }

  @override
  Future<ProjectEntity?> getProject(String uuid) async {
    return _store.findProject(uuid);
  }

  @override
  Future<ProjectEntity> createProject(ProjectEntity project) async {
    final now = DateTime.now();
    final newProject = project.copyWith(
      createTime: now,
      updateTime: now,
    );
    await _store.saveProject(newProject);
    _notifyChange(ProjectChangeType.created, newProject);
    return newProject;
  }

  @override
  Future<void> saveProject(ProjectEntity project) async {
    final existing = await _store.findProjectIncludingDeleted(project.uuid);
    await _store.saveProject(project);
    if (existing != null) {
      _notifyChange(ProjectChangeType.updated, project);
    } else {
      _notifyChange(ProjectChangeType.created, project);
    }
  }

  @override
  Future<void> updateProject(ProjectEntity project) async {
    final updated = project.copyWith(updateTime: DateTime.now());
    await _store.saveProject(updated);
    _notifyChange(ProjectChangeType.updated, updated);
  }

  @override
  Future<void> deleteProject(String uuid) async {
    await _store.deleteProject(uuid);
    _notifyChange(ProjectChangeType.deleted, uuid);
  }

  // ==================== 模块 ====================

  @override
  Future<List<ProjectModuleEntity>> getModules(String projectUuid) async {
    return _store.findModules(projectUuid);
  }

  @override
  Future<ProjectModuleEntity> createModule(ProjectModuleEntity module) async {
    final now = DateTime.now();
    final newModule = module.copyWith(
      createTime: now,
      updateTime: now,
    );
    await _store.saveModule(newModule);
    return newModule;
  }

  @override
  Future<void> saveModule(ProjectModuleEntity module) async {
    await _store.saveModule(module);
  }

  @override
  Future<void> updateModule(ProjectModuleEntity module) async {
    final updated = module.copyWith(updateTime: DateTime.now());
    await _store.saveModule(updated);
  }

  @override
  Future<void> deleteModule(String uuid) async {
    await _store.deleteModule(uuid);
  }

  // ==================== 技能 ====================

  @override
  Future<List<ProjectSkillEntity>> getSkills(String projectUuid) async {
    return _store.findSkills(projectUuid);
  }

  @override
  Future<ProjectSkillEntity> createSkill(ProjectSkillEntity skill) async {
    final now = DateTime.now();
    final newSkill = skill.copyWith(
      createTime: now,
      updateTime: now,
    );
    await _store.saveSkill(newSkill);
    return newSkill;
  }

  @override
  Future<void> saveSkill(ProjectSkillEntity skill) async {
    await _store.saveSkill(skill);
  }

  @override
  Future<void> updateSkill(ProjectSkillEntity skill) async {
    final updated = skill.copyWith(updateTime: DateTime.now());
    await _store.saveSkill(updated);
  }

  @override
  Future<void> deleteSkill(String uuid) async {
    await _store.deleteSkill(uuid);
  }

  // ==================== 工单 ====================

  @override
  Future<List<ProjectIssueEntity>> getIssues(String projectUuid, {String? status}) async {
    return _store.findIssues(projectUuid, status: status);
  }

  @override
  Future<ProjectIssueEntity> createIssue(ProjectIssueEntity issue) async {
    final now = DateTime.now();
    final newIssue = issue.copyWith(
      createTime: now,
      updateTime: now,
    );
    await _store.saveIssue(newIssue);
    return newIssue;
  }

  @override
  Future<void> saveIssue(ProjectIssueEntity issue) async {
    await _store.saveIssue(issue);
  }

  @override
  Future<void> updateIssue(ProjectIssueEntity issue) async {
    final updated = issue.copyWith(updateTime: DateTime.now());
    await _store.saveIssue(updated);
  }

  @override
  Future<void> closeIssue(String uuid) async {
    final issue = await _store.findIssue(uuid);
    if (issue == null) return;
    final updated = issue.copyWith(
      status: 'closed',
      closeTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await _store.saveIssue(updated);
  }

  @override
  Future<void> deleteIssue(String uuid) async {
    await _store.deleteIssue(uuid);
  }

  // ==================== 变更通知 ====================

  @override
  Stream<ProjectChangeEvent> get onProjectChanged =>
      _changeController.stream;

  void _notifyChange(ProjectChangeType type, dynamic projectOrUuid) {
    if (projectOrUuid is ProjectEntity) {
      _changeController.add(
        ProjectChangeEvent(
          type: type,
          projectUuid: projectOrUuid.uuid,
          project: projectOrUuid,
        ),
      );
    } else if (projectOrUuid is String) {
      _changeController.add(
        ProjectChangeEvent(type: type, projectUuid: projectOrUuid),
      );
    }
  }

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}
