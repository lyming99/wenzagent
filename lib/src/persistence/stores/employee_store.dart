import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/employee_entity.dart';

/// 员工数据存储
///
/// 使用 SQLite 实现，保持与原 Hive 版本完全相同的公共 API。
class EmployeeStore {
  final DatabaseManager _dbManager;

  EmployeeStore({String? deviceId, DatabaseManager? dbManager})
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
  AiEmployeeEntity _rowToEntity(Row row) {
    return AiEmployeeEntity.fromMap({
      'uuid': row['uuid'],
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
  ///
  /// [includeDeleted] 为 true 时包含已删除的员工（用于跨设备同步场景）
  Future<List<AiEmployeeEntity>> findAll(
    String? deviceId, {
    String? keyword,
    String? status,
    bool includeDeleted = false,
  }) async {
    final conditions = <String>[];
    if (!includeDeleted) {
      conditions.add('deleted = 0');
    }
    final params = <Object?>[];

    if (deviceId != null) {
      conditions.add('device_id = ?');
      params.add(deviceId);
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

    final where = conditions.isNotEmpty ? conditions.join(' AND ') : '1=1';
    final sql =
        'SELECT * FROM employees WHERE $where ORDER BY is_pinned DESC, sort_order ASC';

    final resultSet = _db.select(sql, params);
    return resultSet.map(_rowToEntity).toList();
  }

  /// 查找单个员工（包含已删除的，用于同步合并场景）
  Future<AiEmployeeEntity?> findIncludingDeleted(String uuid) async {
    final resultSet = _db.select(
      'SELECT * FROM employees WHERE uuid = ? LIMIT 1',
      [uuid],
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 查找单个员工
  Future<AiEmployeeEntity?> find(String? deviceId, String uuid) async {
    final conditions = <String>['uuid = ?', 'deleted = 0'];
    final params = <Object?>[uuid];

    if (deviceId != null) {
      conditions.add('device_id = ?');
      params.add(deviceId);
    }

    final where = conditions.join(' AND ');
    final resultSet = _db.select(
      'SELECT * FROM employees WHERE $where',
      params,
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 保存员工（INSERT OR REPLACE）
  Future<void> save(AiEmployeeEntity entity) async {
    const columns = [
      'uuid', 'name', 'avatar', 'role', 'status', 'description',
      'system_prompt', 'provider', 'model', 'api_key', 'api_base_url', 'model_config',
      'project_uuid', 'project_name', 'project_context', 'work_path',
      'enable_tools', 'enable_mcp', 'mcp_config', 'permission_config',
      'device_id', 'current_device_id', 'auto_approve', 'sort_order', 'is_pinned',
      'deleted', 'deleted_time', 'create_time', 'update_time',
    ];
    final placeholders = List.filled(columns.length, '?').join(', ');
    final columnList = columns.join(', ');
    _db.execute(
      'INSERT OR REPLACE INTO employees ($columnList) VALUES ($placeholders)',
      _entityToParams(entity),
    );
  }

  /// 删除员工（软删除）
  Future<void> delete(String? deviceId, String uuid) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'UPDATE employees SET deleted = 1, deleted_time = ?, update_time = ? WHERE uuid = ?',
      [now, now, uuid],
    );
  }

  /// 获取员工数量
  Future<int> count(String? deviceId, {String? status}) async {
    final conditions = <String>['deleted = 0'];
    final params = <Object?>[];

    if (deviceId != null) {
      conditions.add('device_id = ?');
      params.add(deviceId);
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
  Future<bool> exists(String? deviceId, String uuid) async {
    final resultSet = _db.select(
      'SELECT 1 FROM employees WHERE uuid = ? AND deleted = 0 LIMIT 1',
      [uuid],
    );
    return resultSet.isNotEmpty;
  }
}
