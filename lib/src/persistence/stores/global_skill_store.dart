import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/global_skill_entity.dart';

/// 全局技能数据存储
///
/// 使用 SQLite 实现，管理独立于员工的全局技能库。
class GlobalSkillStore {
  final DatabaseManager _dbManager;

  GlobalSkillStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  Database get _db {
    if (!_dbManager.isInitialized) {
      throw StateError(
        '$runtimeType: DatabaseManager 未初始化，请先调用 initialize()。',
      );
    }
    return _dbManager.db;
  }

  /// 从数据库行解码为实体
  GlobalSkillEntity _rowToEntity(Row row) {
    return GlobalSkillEntity.fromMap({
      'uuid': row['uuid'],
      'name': row['name'],
      'description': row['description'],
      'skillType': row['skill_type'],
      'config': row['config'],
      'enabled': row['enabled'],
      'sortOrder': row['sort_order'],
      'deleted': row['deleted'],
      'deleteTime': row['delete_time'],
      'createTime': row['create_time'],
      'updateTime': row['update_time'],
    });
  }

  /// 获取所有技能（未删除）
  Future<List<GlobalSkillEntity>> findAll() async {
    final resultSet = _db.select(
      'SELECT * FROM global_skills WHERE deleted = 0 ORDER BY sort_order ASC, create_time DESC',
    );
    return resultSet.map(_rowToEntity).toList();
  }

  /// 按类型获取技能
  Future<List<GlobalSkillEntity>> findByType(String skillType) async {
    final resultSet = _db.select(
      'SELECT * FROM global_skills WHERE skill_type = ? AND deleted = 0 ORDER BY sort_order ASC, create_time DESC',
      [skillType],
    );
    return resultSet.map(_rowToEntity).toList();
  }

  /// 查找单个技能
  Future<GlobalSkillEntity?> find(String uuid) async {
    final resultSet = _db.select(
      'SELECT * FROM global_skills WHERE uuid = ? AND deleted = 0',
      [uuid],
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 保存技能（INSERT OR REPLACE）
  Future<void> save(GlobalSkillEntity entity) async {
    _db.execute('''
      INSERT OR REPLACE INTO global_skills (
        uuid, name, description, skill_type,
        config, enabled, sort_order, deleted, delete_time, create_time, update_time
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      entity.uuid,
      entity.name,
      entity.description,
      entity.skillType,
      entity.config,
      entity.enabled,
      entity.sortOrder,
      entity.deleted,
      entity.deleteTime?.millisecondsSinceEpoch,
      entity.createTime.millisecondsSinceEpoch,
      entity.updateTime.millisecondsSinceEpoch,
    ]);
  }

  /// 删除技能（软删除）
  Future<void> delete(String uuid) async {
    _db.execute(
      'UPDATE global_skills SET deleted = 1, delete_time = ? WHERE uuid = ?',
      [DateTime.now().millisecondsSinceEpoch, uuid],
    );
  }

  /// 硬删除技能
  Future<void> hardDelete(String uuid) async {
    _db.execute('DELETE FROM global_skills WHERE uuid = ?', [uuid]);
  }

  /// 获取技能总数（未删除）
  Future<int> count() async {
    final resultSet = _db.select(
      'SELECT COUNT(*) as cnt FROM global_skills WHERE deleted = 0',
    );
    return resultSet.first['cnt'] as int;
  }

  /// 搜索技能（按名称或描述模糊匹配）
  Future<List<GlobalSkillEntity>> search(String keyword) async {
    final pattern = '%$keyword%';
    final resultSet = _db.select(
      'SELECT * FROM global_skills WHERE deleted = 0 AND (name LIKE ? OR description LIKE ?) ORDER BY sort_order ASC, create_time DESC',
      [pattern, pattern],
    );
    return resultSet.map(_rowToEntity).toList();
  }

  /// 查找单个技能（包含已删除的，用于同步合并场景）
  Future<GlobalSkillEntity?> findIncludingDeleted(String uuid) async {
    final resultSet = _db.select(
      'SELECT * FROM global_skills WHERE uuid = ?',
      [uuid],
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 获取所有技能（包含已删除的，用于同步拉取）
  Future<List<GlobalSkillEntity>> findAllIncludingDeleted() async {
    final resultSet = _db.select(
      'SELECT * FROM global_skills ORDER BY sort_order ASC, create_time DESC',
    );
    return resultSet.map(_rowToEntity).toList();
  }
}
