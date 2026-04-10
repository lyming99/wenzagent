import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/employee_entity.dart';

/// 员工数据存储
///
/// 使用 SQLite 实现，保持与原 Hive 版本完全相同的公共 API。
class EmployeeStore {
  final DatabaseManager _dbManager;

  EmployeeStore({DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.instance;

  Database get _db => _dbManager.db;

  /// 从数据库行解码为实体
  AiEmployeeEntity _rowToEntity(Row row) {
    return AiEmployeeEntity.fromMap({
      'uuid': row['uuid'],
      'spaceId': row['space_id'],
      'name': row['name'],
      'avatar': row['avatar'],
      'role': row['role'],
      'status': row['status'],
      'description': row['description'],
      'systemPrompt': row['system_prompt'],
      'provider': row['provider'],
      'model': row['model'],
      'apiKey': row['api_key'],
      'apiBaseUrl': row['api_base_url'],
      'modelConfig': row['model_config'],
      'enableTools': row['enable_tools'],
      'enableMcp': row['enable_mcp'],
      'projectUuid': row['project_uuid'],
      'projectName': row['project_name'],
      'projectContext': row['project_context'],
      'workPath': row['work_path'],
      'mcpConfig': row['mcp_config'],
      'permissionConfig': row['permission_config'],
      'deviceId': row['device_id'],
      'currentDeviceId': row['current_device_id'],
      'autoApprove': row['auto_approve'],
      'sortOrder': row['sort_order'],
      'isPinned': row['is_pinned'],
      'deleted': row['deleted'],
      'deletedTime': row['deleted_time'],
      'createTime': row['create_time'],
      'updateTime': row['update_time'],
    });
  }

  /// 将实体转换为数据库插入参数
  List<Object?> _entityToParams(AiEmployeeEntity e) {
    return [
      e.uuid,
      e.spaceId,
      e.name,
      e.avatar,
      e.role,
      e.status,
      e.description,
      e.systemPrompt,
      e.provider,
      e.model,
      e.apiKey,
      e.apiBaseUrl,
      e.modelConfig,
      e.projectUuid,
      e.projectName,
      e.projectContext,
      e.workPath,
      e.enableTools,
      e.enableMcp,
      e.mcpConfig,
      e.permissionConfig,
      e.deviceId,
      e.currentDeviceId,
      e.autoApprove,
      e.sortOrder,
      e.isPinned,
      e.deleted,
      e.deletedTime?.millisecondsSinceEpoch,
      e.createTime.millisecondsSinceEpoch,
      e.updateTime.millisecondsSinceEpoch,
    ];
  }

  /// 查找所有员工
  Future<List<AiEmployeeEntity>> findAll(
    String? spaceId, {
    String? keyword,
    String? status,
  }) async {
    final conditions = <String>['deleted = 0'];
    final params = <Object?>[];

    if (spaceId != null) {
      conditions.add('space_id = ?');
      params.add(spaceId);
    }
    if (status != null) {
      conditions.add('status = ?');
      params.add(status);
    }
    if (keyword != null && keyword.isNotEmpty) {
      conditions.add('(name LIKE ? OR description LIKE ?)');
      final like = '%$keyword%';
      params.add(like);
      params.add(like);
    }

    final where = conditions.join(' AND ');
    final sql =
        'SELECT * FROM employees WHERE $where ORDER BY is_pinned DESC, sort_order ASC';

    final resultSet = _db.select(sql, params);
    return resultSet.map(_rowToEntity).toList();
  }

  /// 查找单个员工
  Future<AiEmployeeEntity?> find(String? spaceId, String uuid) async {
    final resultSet = _db.select(
      'SELECT * FROM employees WHERE uuid = ? AND deleted = 0',
      [uuid],
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 保存员工（INSERT OR REPLACE）
  Future<void> save(AiEmployeeEntity entity) async {
    _db.execute('''
      INSERT OR REPLACE INTO employees (
        uuid, space_id, name, avatar, role, status, description,
        system_prompt, provider, model, api_key, api_base_url, model_config,
        project_uuid, project_name, project_context, work_path,
        enable_tools, enable_mcp, mcp_config, permission_config,
        device_id, current_device_id, auto_approve, sort_order, is_pinned,
        deleted, deleted_time, create_time, update_time
      ) VALUES (
        ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?
      )
    ''', _entityToParams(entity));
  }

  /// 删除员工（软删除）
  Future<void> delete(String? spaceId, String uuid) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'UPDATE employees SET deleted = 1, deleted_time = ?, update_time = ? WHERE uuid = ?',
      [now, now, uuid],
    );
  }

  /// 获取员工数量
  Future<int> count(String? spaceId, {String? status}) async {
    final conditions = <String>['deleted = 0'];
    final params = <Object?>[];

    if (spaceId != null) {
      conditions.add('space_id = ?');
      params.add(spaceId);
    }
    if (status != null) {
      conditions.add('status = ?');
      params.add(status);
    }

    final where = conditions.join(' AND ');
    final resultSet = _db.select(
      'SELECT COUNT(*) as cnt FROM employees WHERE $where',
      params,
    );
    return resultSet.first['cnt'] as int;
  }

  /// 检查员工是否存在
  Future<bool> exists(String? spaceId, String uuid) async {
    final resultSet = _db.select(
      'SELECT 1 FROM employees WHERE uuid = ? AND deleted = 0 LIMIT 1',
      [uuid],
    );
    return resultSet.isNotEmpty;
  }
}
