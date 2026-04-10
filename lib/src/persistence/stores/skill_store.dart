import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/skill_entity.dart';

/// 技能数据存储
///
/// 使用 SQLite 实现，保持与原 Hive 版本完全相同的公共 API。
class SkillStore {
  final DatabaseManager _dbManager;

  SkillStore({DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.instance;

  Database get _db => _dbManager.db;

  /// 从数据库行解码为实体
  AiEmployeeSkillEntity _rowToEntity(Row row) {
    return AiEmployeeSkillEntity.fromMap({
      'uuid': row['uuid'],
      'employeeId': row['employee_id'],
      'name': row['name'],
      'description': row['description'],
      'skillType': row['skill_type'],
      'config': row['config'],
      'enabled': row['enabled'],
      'sortOrder': row['sort_order'],
      'deleted': row['deleted'],
      'createTime': row['create_time'],
      'updateTime': row['update_time'],
    });
  }

  /// 获取员工的技能列表
  Future<List<AiEmployeeSkillEntity>> findByEmployee(
    String? deviceId,
    String employeeId,
  ) async {
    final resultSet = _db.select(
      'SELECT * FROM skills WHERE employee_id = ? AND deleted = 0 ORDER BY sort_order ASC',
      [employeeId],
    );
    return resultSet.map(_rowToEntity).toList();
  }

  /// 使用明确deviceId获取员工技能
  Future<List<AiEmployeeSkillEntity>> findByEmployeeWithDeviceId(
    String? deviceId,
    String employeeId,
  ) async {
    return findByEmployee(deviceId, employeeId);
  }

  /// 查找单个技能
  Future<AiEmployeeSkillEntity?> find(String? deviceId, String uuid) async {
    final resultSet = _db.select(
      'SELECT * FROM skills WHERE uuid = ? AND deleted = 0',
      [uuid],
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 保存技能
  Future<void> save(AiEmployeeSkillEntity entity) async {
    _db.execute('''
      INSERT OR REPLACE INTO skills (
        uuid, employee_id, name, description, skill_type,
        config, enabled, sort_order, deleted, create_time, update_time
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      entity.uuid,
      entity.employeeId,
      entity.name,
      entity.description,
      entity.skillType,
      entity.config,
      entity.enabled,
      entity.sortOrder,
      entity.deleted,
      entity.createTime.millisecondsSinceEpoch,
      entity.updateTime.millisecondsSinceEpoch,
    ]);
  }

  /// 使用明确deviceId保存技能
  Future<void> saveWithDeviceId(
    String? deviceId,
    AiEmployeeSkillEntity entity,
  ) async {
    await save(entity);
  }

  /// 删除技能（软删除）
  Future<void> delete(String? deviceId, String uuid) async {
    _db.execute(
      'UPDATE skills SET deleted = 1 WHERE uuid = ?',
      [uuid],
    );
  }

  /// 硬删除技能
  Future<void> hardDelete(String? deviceId, String uuid) async {
    _db.execute('DELETE FROM skills WHERE uuid = ?', [uuid]);
  }

  /// 删除员工的所有技能（软删除）
  Future<void> deleteByEmployee(
    String? deviceId,
    String employeeId,
  ) async {
    _db.execute(
      'UPDATE skills SET deleted = 1 WHERE employee_id = ?',
      [employeeId],
    );
  }

  /// 获取技能数量
  Future<int> count(String? deviceId, String employeeId) async {
    final resultSet = _db.select(
      'SELECT COUNT(*) as cnt FROM skills WHERE employee_id = ? AND deleted = 0',
      [employeeId],
    );
    return resultSet.first['cnt'] as int;
  }
}
