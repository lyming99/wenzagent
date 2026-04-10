import 'dart:convert';

import '../hive_manager.dart';
import '../entities/device_config_entity.dart';

/// 设备配置存储
///
/// 使用deviceId作为主键：一个设备只有一个配置。
/// 使用 LazyBox 实现异步读取，避免主线程阻塞。
class DeviceConfigStore {
  final HiveManager _hiveManager;

  DeviceConfigStore({HiveManager? hiveManager})
      : _hiveManager = hiveManager ?? HiveManager.instance;

  /// 构建设备配置key（使用 wenz_ 前缀）
  String _buildKey(String deviceId) {
    return 'wenz_devconf:$deviceId';
  }

  /// 解码JSON字符串为实体
  DeviceConfigEntity? _decodeEntity(dynamic jsonString) {
    if (jsonString == null) return null;
    if (jsonString is String && jsonString.isNotEmpty) {
      return DeviceConfigEntity.fromMap(
        jsonDecode(jsonString) as Map<String, dynamic>,
      );
    }
    return null;
  }

  /// 获取设备配置（主键查找）
  Future<DeviceConfigEntity?> find(String deviceId) async {
    final box = _hiveManager.deviceConfigBox;
    final key = _buildKey(deviceId);
    return _decodeEntity(await box.get(key));
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

  /// 保存设备配置
  Future<void> save(DeviceConfigEntity config) async {
    final box = _hiveManager.deviceConfigBox;
    final key = _buildKey(config.deviceId);
    await box.put(key, jsonEncode(config.toMap()));
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
    final box = _hiveManager.deviceConfigBox;
    final key = _buildKey(deviceId);
    await box.delete(key);
  }

  /// 获取所有设备配置
  Future<List<DeviceConfigEntity>> findAll() async {
    final box = _hiveManager.deviceConfigBox;

    var configs = <DeviceConfigEntity>[];
    for (final key in box.keys) {
      final entity = _decodeEntity(await box.get(key));
      if (entity != null) configs.add(entity);
    }
    return configs;
  }

  /// 获取设备配置数量
  Future<int> count() async {
    final configs = await findAll();
    return configs.length;
  }
}
