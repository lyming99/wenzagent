import 'package:sqlite_async/sqlite_async.dart';

import '../database_manager.dart';
import '../entities/entities.dart';
import '../store_merge_util.dart';

/// 项目数据存储（wenzagent SQLite）
///
/// 管理 wenz_projects / wenz_project_modules / wenz_project_skills / wenz_project_issues 四张表。
class ProjectStore {
  final DatabaseManager _dbManager;

  ProjectStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  SqliteDatabase get _db {
    if (!_dbManager.isInitialized) {
      throw StateError(
        '$runtimeType: DatabaseManager 未初始化，请先调用 initialize()。',
      );
    }
    return _dbManager.db;
  }

  // ==================== 项目 ====================

  ProjectEntity _rowToProject(Map<String, Object?> row) {
    return ProjectEntity.fromMap({
      'uuid': row['uuid'],
      'userId': row['user_id'],
      'spaceId': row['space_id'],
      'title': row['title'],
      'description': row['description'],
      'workPath': row['work_path'],
      'gitUrl': row['git_url'],
      'deleted': row['deleted'],
      'deleteBy': row['delete_by'],
      'deleteTime': row['delete_time'],
      'createBy': row['create_by'],
      'createTime': row['create_time'],
      'updateBy': row['update_by'],
      'updateTime': row['update_time'],
    });
  }

  /// 获取所有项目（未删除）
  Future<List<ProjectEntity>> findAllProjects() async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_projects WHERE deleted = 0 ORDER BY update_time DESC',
    );
    return rs.map(_rowToProject).toList();
  }

  /// 按关键词搜索项目
  Future<List<ProjectEntity>> searchProjects(String keyword) async {
    final pattern = '%$keyword%';
    final rs = await _db.getAll(
      'SELECT * FROM wenz_projects WHERE deleted = 0 AND (title LIKE ? OR description LIKE ?) ORDER BY update_time DESC',
      [pattern, pattern],
    );
    return rs.map(_rowToProject).toList();
  }

  /// 获取单个项目
  Future<ProjectEntity?> findProject(String uuid) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_projects WHERE uuid = ? AND deleted = 0',
      [uuid],
    );
    for (final row in rs) {
      return _rowToProject(row);
    }
    return null;
  }

  /// 获取单个项目（含已删除）
  Future<ProjectEntity?> findProjectIncludingDeleted(String uuid) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_projects WHERE uuid = ?',
      [uuid],
    );
    for (final row in rs) {
      return _rowToProject(row);
    }
    return null;
  }

  /// 保存项目（INSERT OR REPLACE）
  Future<void> saveProject(ProjectEntity entity) async {
    await _db.execute('''
      INSERT OR REPLACE INTO wenz_projects (
        uuid, user_id, space_id, title, description, work_path, git_url,
        deleted, delete_by, delete_time, create_by, create_time, update_by, update_time
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      entity.uuid,
      entity.userId,
      entity.spaceId,
      entity.title,
      entity.description,
      entity.workPath,
      entity.gitUrl,
      entity.deleted,
      entity.deleteBy,
      entity.deleteTime?.millisecondsSinceEpoch,
      entity.createBy,
      entity.createTime.millisecondsSinceEpoch,
      entity.updateBy,
      entity.updateTime.millisecondsSinceEpoch,
    ]);
  }

  /// 软删除项目
  Future<void> deleteProject(String uuid) async {
    await _db.execute(
      'UPDATE wenz_projects SET deleted = 1, delete_time = ? WHERE uuid = ?',
      [DateTime.now().millisecondsSinceEpoch, uuid],
    );
  }

  // ==================== 模块 ====================

  ProjectModuleEntity _rowToModule(Map<String, Object?> row) {
    return ProjectModuleEntity.fromMap({
      'uuid': row['uuid'],
      'projectUuid': row['project_uuid'],
      'title': row['title'],
      'description': row['description'],
      'noteUuid': row['note_uuid'],
      'sortOrder': row['sort_order'],
      'deleted': row['deleted'],
      'deleteBy': row['delete_by'],
      'deleteTime': row['delete_time'],
      'createBy': row['create_by'],
      'createTime': row['create_time'],
      'updateBy': row['update_by'],
      'updateTime': row['update_time'],
    });
  }

  /// 获取项目的模块列表
  Future<List<ProjectModuleEntity>> findModules(String projectUuid) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_project_modules WHERE project_uuid = ? AND deleted = 0 ORDER BY sort_order ASC',
      [projectUuid],
    );
    return rs.map(_rowToModule).toList();
  }

  /// 保存模块
  Future<void> saveModule(ProjectModuleEntity entity) async {
    await _db.execute('''
      INSERT OR REPLACE INTO wenz_project_modules (
        uuid, project_uuid, title, description, note_uuid, sort_order,
        deleted, delete_by, delete_time, create_by, create_time, update_by, update_time
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      entity.uuid,
      entity.projectUuid,
      entity.title,
      entity.description,
      entity.noteUuid,
      entity.sortOrder,
      entity.deleted,
      entity.deleteBy,
      entity.deleteTime?.millisecondsSinceEpoch,
      entity.createBy,
      entity.createTime.millisecondsSinceEpoch,
      entity.updateBy,
      entity.updateTime.millisecondsSinceEpoch,
    ]);
  }

  /// 软删除模块
  Future<void> deleteModule(String uuid) async {
    await _db.execute(
      'UPDATE wenz_project_modules SET deleted = 1, delete_time = ? WHERE uuid = ?',
      [DateTime.now().millisecondsSinceEpoch, uuid],
    );
  }

  // ==================== 技能 ====================

  ProjectSkillEntity _rowToSkill(Map<String, Object?> row) {
    return ProjectSkillEntity.fromMap({
      'uuid': row['uuid'],
      'projectUuid': row['project_uuid'],
      'title': row['title'],
      'description': row['description'],
      'skillType': row['skill_type'],
      'noteUuid': row['note_uuid'],
      'documentUuid': row['document_uuid'],
      'mcpConfig': row['mcp_config'],
      'fileConfig': row['file_config'],
      'sortOrder': row['sort_order'],
      'deleted': row['deleted'],
      'deleteBy': row['delete_by'],
      'deleteTime': row['delete_time'],
      'createBy': row['create_by'],
      'createTime': row['create_time'],
      'updateBy': row['update_by'],
      'updateTime': row['update_time'],
    });
  }

  /// 获取项目的技能列表
  Future<List<ProjectSkillEntity>> findSkills(String projectUuid) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_project_skills WHERE project_uuid = ? AND deleted = 0 ORDER BY sort_order ASC',
      [projectUuid],
    );
    return rs.map(_rowToSkill).toList();
  }

  /// 保存技能
  Future<void> saveSkill(ProjectSkillEntity entity) async {
    await _db.execute('''
      INSERT OR REPLACE INTO wenz_project_skills (
        uuid, project_uuid, title, description, skill_type, note_uuid, document_uuid,
        mcp_config, file_config, sort_order,
        deleted, delete_by, delete_time, create_by, create_time, update_by, update_time
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      entity.uuid,
      entity.projectUuid,
      entity.title,
      entity.description,
      entity.skillType,
      entity.noteUuid,
      entity.documentUuid,
      entity.mcpConfig,
      entity.fileConfig,
      entity.sortOrder,
      entity.deleted,
      entity.deleteBy,
      entity.deleteTime?.millisecondsSinceEpoch,
      entity.createBy,
      entity.createTime.millisecondsSinceEpoch,
      entity.updateBy,
      entity.updateTime.millisecondsSinceEpoch,
    ]);
  }

  /// 软删除技能
  Future<void> deleteSkill(String uuid) async {
    await _db.execute(
      'UPDATE wenz_project_skills SET deleted = 1, delete_time = ? WHERE uuid = ?',
      [DateTime.now().millisecondsSinceEpoch, uuid],
    );
  }

  // ==================== 工单 ====================

  ProjectIssueEntity _rowToIssue(Map<String, Object?> row) {
    return ProjectIssueEntity.fromMap({
      'uuid': row['uuid'],
      'projectUuid': row['project_uuid'],
      'title': row['title'],
      'description': row['description'],
      'status': row['status'],
      'priority': row['priority'],
      'assignee': row['assignee'],
      'closeTime': row['close_time'],
      'deleted': row['deleted'],
      'deleteBy': row['delete_by'],
      'deleteTime': row['delete_time'],
      'createBy': row['create_by'],
      'createTime': row['create_time'],
      'updateBy': row['update_by'],
      'updateTime': row['update_time'],
    });
  }

  /// 获取项目的工单列表
  Future<List<ProjectIssueEntity>> findIssues(
    String projectUuid, {
    String? status,
  }) async {
    if (status != null) {
      final rs = await _db.getAll(
        'SELECT * FROM wenz_project_issues WHERE project_uuid = ? AND deleted = 0 AND status = ? ORDER BY create_time DESC',
        [projectUuid, status],
      );
      return rs.map(_rowToIssue).toList();
    }
    final rs = await _db.getAll(
      'SELECT * FROM wenz_project_issues WHERE project_uuid = ? AND deleted = 0 ORDER BY create_time DESC',
      [projectUuid],
    );
    return rs.map(_rowToIssue).toList();
  }

  /// 保存工单
  Future<void> saveIssue(ProjectIssueEntity entity) async {
    await _db.execute('''
      INSERT OR REPLACE INTO wenz_project_issues (
        uuid, project_uuid, title, description, status, priority, assignee, close_time,
        deleted, delete_by, delete_time, create_by, create_time, update_by, update_time
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      entity.uuid,
      entity.projectUuid,
      entity.title,
      entity.description,
      entity.status,
      entity.priority,
      entity.assignee,
      entity.closeTime?.millisecondsSinceEpoch,
      entity.deleted,
      entity.deleteBy,
      entity.deleteTime?.millisecondsSinceEpoch,
      entity.createBy,
      entity.createTime.millisecondsSinceEpoch,
      entity.updateBy,
      entity.updateTime.millisecondsSinceEpoch,
    ]);
  }

  /// 获取单个工单（通过 uuid，跨项目查询）
  Future<ProjectIssueEntity?> findIssue(String uuid) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_project_issues WHERE uuid = ? AND deleted = 0',
      [uuid],
    );
    for (final row in rs) {
      return _rowToIssue(row);
    }
    return null;
  }

  /// 软删除工单
  Future<void> deleteIssue(String uuid) async {
    await _db.execute(
      'UPDATE wenz_project_issues SET deleted = 1, delete_time = ? WHERE uuid = ?',
      [DateTime.now().millisecondsSinceEpoch, uuid],
    );
  }

  // ==================== 批量查询（含已删除） ====================

  /// 获取所有项目（含已删除）
  Future<List<ProjectEntity>> findAllProjectsIncludingDeleted() async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_projects ORDER BY update_time DESC',
    );
    return rs.map(_rowToProject).toList();
  }

  /// 获取项目的所有模块（含已删除）
  Future<List<ProjectModuleEntity>> findAllModulesIncludingDeleted(String projectUuid) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_project_modules WHERE project_uuid = ? ORDER BY sort_order ASC',
      [projectUuid],
    );
    return rs.map(_rowToModule).toList();
  }

  /// 获取项目的所有技能（含已删除）
  Future<List<ProjectSkillEntity>> findAllSkillsIncludingDeleted(String projectUuid) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_project_skills WHERE project_uuid = ? ORDER BY sort_order ASC',
      [projectUuid],
    );
    return rs.map(_rowToSkill).toList();
  }

  /// 获取项目的所有工单（含已删除）
  Future<List<ProjectIssueEntity>> findAllIssuesIncludingDeleted(String projectUuid) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_project_issues WHERE project_uuid = ? ORDER BY create_time DESC',
      [projectUuid],
    );
    return rs.map(_rowToIssue).toList();
  }

  // ==================== 单个查询（含已删除） ====================

  /// 获取单个模块（含已删除）
  Future<ProjectModuleEntity?> findModuleIncludingDeleted(String uuid) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_project_modules WHERE uuid = ?',
      [uuid],
    );
    for (final row in rs) {
      return _rowToModule(row);
    }
    return null;
  }

  /// 获取单个技能（含已删除）
  Future<ProjectSkillEntity?> findSkillIncludingDeleted(String uuid) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_project_skills WHERE uuid = ?',
      [uuid],
    );
    for (final row in rs) {
      return _rowToSkill(row);
    }
    return null;
  }

  /// 获取单个工单（含已删除）
  Future<ProjectIssueEntity?> findIssueIncludingDeleted(String uuid) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_project_issues WHERE uuid = ?',
      [uuid],
    );
    for (final row in rs) {
      return _rowToIssue(row);
    }
    return null;
  }

  // ==================== 远程合并写入 ====================

  /// 远程项目数据合并写入
  ///
  /// 返回 true 表示有更新，false 表示无需更新。
  /// 使用 StoreMergeUtil.mergeDeleteState + shouldUpdateData 进行合并判断。
  Future<bool> upsertFromRemote(ProjectEntity remote) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_projects WHERE uuid = ?',
      [remote.uuid],
    );
    if (rs.isEmpty) {
      // 本地不存在 → 直接保存（未删除的才保存）
      if (remote.deleted != 1) {
        await saveProject(remote);
      }
      return remote.deleted != 1;
    }
    final existing = _rowToProject(rs.first);
    final mergeResult = StoreMergeUtil.mergeDeleteState(
      localDeleteTime: existing.deleteTime,
      localDeleted: existing.deleted,
      remoteDeleteTime: remote.deleteTime,
      remoteDeleted: remote.deleted,
      localUpdateTime: existing.updateTime,
      remoteUpdateTime: remote.updateTime,
    );
    final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
        existing.updateTime, remote.updateTime);
    final shouldUpdateDelete =
        mergeResult.mergedDeleteTime != existing.deleteTime ||
            mergeResult.mergedDeleted != existing.deleted;
    if (shouldUpdateData || shouldUpdateDelete) {
      final base = shouldUpdateData ? remote : existing;
      await saveProject(base.copyWith(
        deleted: mergeResult.mergedDeleted,
        deleteTime: mergeResult.mergedDeleteTime,
      ));
      return true;
    }
    return false;
  }

  /// 远程模块数据合并写入
  Future<bool> upsertModuleFromRemote(ProjectModuleEntity remote) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_project_modules WHERE uuid = ?',
      [remote.uuid],
    );
    if (rs.isEmpty) {
      if (remote.deleted != 1) {
        await saveModule(remote);
      }
      return remote.deleted != 1;
    }
    final existing = _rowToModule(rs.first);
    final mergeResult = StoreMergeUtil.mergeDeleteState(
      localDeleteTime: existing.deleteTime,
      localDeleted: existing.deleted,
      remoteDeleteTime: remote.deleteTime,
      remoteDeleted: remote.deleted,
      localUpdateTime: existing.updateTime,
      remoteUpdateTime: remote.updateTime,
    );
    final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
        existing.updateTime, remote.updateTime);
    final shouldUpdateDelete =
        mergeResult.mergedDeleteTime != existing.deleteTime ||
            mergeResult.mergedDeleted != existing.deleted;
    if (shouldUpdateData || shouldUpdateDelete) {
      final base = shouldUpdateData ? remote : existing;
      await saveModule(base.copyWith(
        deleted: mergeResult.mergedDeleted,
        deleteTime: mergeResult.mergedDeleteTime,
      ));
      return true;
    }
    return false;
  }

  /// 远程技能数据合并写入
  Future<bool> upsertSkillFromRemote(ProjectSkillEntity remote) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_project_skills WHERE uuid = ?',
      [remote.uuid],
    );
    if (rs.isEmpty) {
      if (remote.deleted != 1) {
        await saveSkill(remote);
      }
      return remote.deleted != 1;
    }
    final existing = _rowToSkill(rs.first);
    final mergeResult = StoreMergeUtil.mergeDeleteState(
      localDeleteTime: existing.deleteTime,
      localDeleted: existing.deleted,
      remoteDeleteTime: remote.deleteTime,
      remoteDeleted: remote.deleted,
      localUpdateTime: existing.updateTime,
      remoteUpdateTime: remote.updateTime,
    );
    final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
        existing.updateTime, remote.updateTime);
    final shouldUpdateDelete =
        mergeResult.mergedDeleteTime != existing.deleteTime ||
            mergeResult.mergedDeleted != existing.deleted;
    if (shouldUpdateData || shouldUpdateDelete) {
      final base = shouldUpdateData ? remote : existing;
      await saveSkill(base.copyWith(
        deleted: mergeResult.mergedDeleted,
        deleteTime: mergeResult.mergedDeleteTime,
      ));
      return true;
    }
    return false;
  }

  /// 远程工单数据合并写入
  Future<bool> upsertIssueFromRemote(ProjectIssueEntity remote) async {
    final rs = await _db.getAll(
      'SELECT * FROM wenz_project_issues WHERE uuid = ?',
      [remote.uuid],
    );
    if (rs.isEmpty) {
      if (remote.deleted != 1) {
        await saveIssue(remote);
      }
      return remote.deleted != 1;
    }
    final existing = _rowToIssue(rs.first);
    final mergeResult = StoreMergeUtil.mergeDeleteState(
      localDeleteTime: existing.deleteTime,
      localDeleted: existing.deleted,
      remoteDeleteTime: remote.deleteTime,
      remoteDeleted: remote.deleted,
      localUpdateTime: existing.updateTime,
      remoteUpdateTime: remote.updateTime,
    );
    final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
        existing.updateTime, remote.updateTime);
    final shouldUpdateDelete =
        mergeResult.mergedDeleteTime != existing.deleteTime ||
            mergeResult.mergedDeleted != existing.deleted;
    if (shouldUpdateData || shouldUpdateDelete) {
      final base = shouldUpdateData ? remote : existing;
      await saveIssue(base.copyWith(
        deleted: mergeResult.mergedDeleted,
        deleteTime: mergeResult.mergedDeleteTime,
      ));
      return true;
    }
    return false;
  }
}
