import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../database_manager.dart';
import '../entities/device_config_entity.dart';

/// 设备配置存储
///
/// 使用 SQLite 实现，保持与原 Hive 版本完全相同的公共 API。
/// 主键：deviceId（一个设备只有一个配置）。
class DeviceConfigStore {
  final DatabaseManager _dbManager;

  DeviceConfigStore({DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.instance;

  Database get _db => _dbManager.db;

  /// 从数据库行解码为实体
  DeviceConfigEntity _rowToEntity(Row row) {
    DeviceInfoConfig deviceInfo = DeviceInfoConfig();
    final deviceInfoStr = row['device_info'] as String?;
    if (deviceInfoStr != null && deviceInfoStr.isNotEmpty) {
      deviceInfo = DeviceInfoConfig.fromMap(
        jsonDecode(deviceInfoStr) as Map<String, dynamic>,
      );
    }

    Map<String, String> envVars = {};
    final envVarsStr = row['env_vars'] as String?;
    if (envVarsStr != null && envVarsStr.isNotEmpty) {
      final raw = jsonDecode(envVarsStr) as Map;
      envVars = raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }

    return DeviceConfigEntity(
      deviceId: row['device_id'] as String,
      deviceInfo: deviceInfo,
      environmentVariables: envVars,
      createTime: DateTime.fromMillisecondsSinceEpoch(
          row['create_time'] as int),
      updateTime: DateTime.fromMillisecondsSinceEpoch(
          row['update_time'] as int),
    );
  }

  /// 获取设备配置（主键查找）
  Future<DeviceConfigEntity?> find(String deviceId) async {
    final resultSet = _db.select(
      'SELECT * FROM device_configs WHERE device_id = ?',
      [deviceId],
    );
    for (final row in resultSet) {
      return _rowToEntity(row);
    }
    return null;
  }

  /// 获取或创建设备配置
  Future<DeviceConfigEntity> getOrCreate(String deviceId) async {
    var config = await find(deviceId);
    if (config != null) return config;

    final now = DateTime.now();
    config = DeviceConfigEntity(
      deviceId: deviceId,
      createTime: now,
      updateTime: now,
    );

    await save(config);
    return config;
  }

  /// 保存设备配置（INSERT OR REPLACE）
  Future<void> save(DeviceConfigEntity config) async {
    _db.execute('''
      INSERT OR REPLACE INTO device_configs (
        device_id, device_info, env_vars, create_time, update_time
      ) VALUES (?, ?, ?, ?, ?)
    ''', [
      config.deviceId,
      jsonEncode(config.deviceInfo.toMap()),
      jsonEncode(config.environmentVariables),
      config.createTime.millisecondsSinceEpoch,
      config.updateTime.millisecondsSinceEpoch,
    ]);
  }

  /// 更新设备信息配置
  Future<void> updateDeviceInfo(
    String deviceId,
    DeviceInfoConfig deviceInfo,
  ) async {
    var config = await find(deviceId);
    if (config == null) {
      config = await getOrCreate(deviceId);
    }

    await save(config.copyWith(
      deviceInfo: deviceInfo,
      updateTime: DateTime.now(),
    ));
  }

  /// 更新设备环境变量
  Future<void> updateEnvironmentVariables(
    String deviceId,
    Map<String, String> environmentVariables,
  ) async {
    var config = await find(deviceId);
    if (config == null) {
      config = await getOrCreate(deviceId);
    }

    await save(config.copyWith(
      environmentVariables: environmentVariables,
      updateTime: DateTime.now(),
    ));
  }

  /// 设置单个环境变量
  Future<void> setEnvironmentVariable(
    String deviceId,
    String key,
    String value,
  ) async {
    var config = await find(deviceId);
    if (config == null) {
      config = await getOrCreate(deviceId);
    }

    final newEnvVars = Map<String, String>.from(config.environmentVariables);
    newEnvVars[key] = value;

    await save(config.copyWith(
      environmentVariables: newEnvVars,
      updateTime: DateTime.now(),
    ));
  }

  /// 删除单个环境变量
  Future<void> deleteEnvironmentVariable(
    String deviceId,
    String key,
  ) async {
    var config = await find(deviceId);
    if (config == null) return;

    final newEnvVars = Map<String, String>.from(config.environmentVariables);
    newEnvVars.remove(key);

    await save(config.copyWith(
      environmentVariables: newEnvVars,
      updateTime: DateTime.now(),
    ));
  }

  /// 删除设备配置
  Future<void> delete(String deviceId) async {
    _db.execute(
      'DELETE FROM device_configs WHERE device_id = ?',
      [deviceId],
    );
  }

  /// 获取所有设备配置
  Future<List<DeviceConfigEntity>> findAll() async {
    return _db
        .select('SELECT * FROM device_configs')
        .map(_rowToEntity)
        .toList();
  }

  /// 获取设备配置数量
  Future<int> count() async {
    final resultSet = _db.select(
      'SELECT COUNT(*) as cnt FROM device_configs',
    );
    return resultSet.first['cnt'] as int;
  }
}
