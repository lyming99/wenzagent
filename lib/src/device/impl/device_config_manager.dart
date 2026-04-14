import '../../persistence/persistence.dart';
import '../../utils/logger.dart';
import '../app_context.dart';

/// 设备配置管理器
///
/// 负责设备配置的 CRUD 操作。
class DeviceConfigManager {
  static final _log = Logger('DeviceConfigManager');

  final DeviceConfigStore _deviceConfigStore;
  final String _deviceId;

  DeviceConfigManager._({required String deviceId, required DeviceConfigStore deviceConfigStore})
      : _deviceId = deviceId,
        _deviceConfigStore = deviceConfigStore;

  // ===== 单例管理 =====

  /// 从 [AppContext] 获取实例，不存在则回退到独立创建
  static DeviceConfigManager getInstance(String deviceId) {
    final ctx = AppContext.get(deviceId);
    if (ctx != null) return ctx.configManager;
    // 回退：独立创建（用于测试或未通过 AppContext 初始化的场景）
    return DeviceConfigManager._(
      deviceId: deviceId,
      deviceConfigStore: DeviceConfigStore(deviceId: deviceId),
    );
  }

  static void removeInstance(String deviceId) {
    // 清理由 AppContext.dispose() 统一处理
  }

  // ===== 公开方法 =====

  /// 获取设备配置
  Future<DeviceConfigEntity> getDeviceConfig() async =>
      await _deviceConfigStore.getOrCreate(_deviceId);

  /// 更新设备信息配置
  Future<void> updateDeviceInfo(DeviceInfoConfig deviceInfo) async {
    try {
      final existing = await _deviceConfigStore.find(_deviceId);
      if (existing != null) {
        await _deviceConfigStore.updateDeviceInfo(
          _deviceId,
          existing.deviceInfo.copyWith(
            name: deviceInfo.name,
            type: deviceInfo.type,
            description: deviceInfo.description,
            icon: deviceInfo.icon,
            os: deviceInfo.os,
            osVersion: deviceInfo.osVersion,
            appVersion: deviceInfo.appVersion,
            model: deviceInfo.model,
            manufacturer: deviceInfo.manufacturer,
            tags: deviceInfo.tags.isNotEmpty ? deviceInfo.tags : null,
            metadata: deviceInfo.metadata.isNotEmpty
                ? deviceInfo.metadata
                : null,
          ),
        );
      } else {
        await _deviceConfigStore.updateDeviceInfo(_deviceId, deviceInfo);
      }
    } catch (e) {
      _log.debug('updateDeviceInfo with merge failed, using direct update: $e');
      await _deviceConfigStore.updateDeviceInfo(_deviceId, deviceInfo);
    }
  }

  /// 更新环境变量
  Future<void> updateEnvironmentVariables(Map<String, String> vars) async =>
      _deviceConfigStore.updateEnvironmentVariables(_deviceId, vars);

  /// 设置单个环境变量
  Future<void> setEnvironmentVariable(String key, String value) async =>
      _deviceConfigStore.setEnvironmentVariable(_deviceId, key, value);

  /// 删除单个环境变量
  Future<void> deleteEnvironmentVariable(String key) async =>
      _deviceConfigStore.deleteEnvironmentVariable(_deviceId, key);
}
