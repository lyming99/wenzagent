/// 设备配置使用示例
///
/// 展示如何使用 DeviceClient 的设备信息配置和环境变量配置功能
library;

import 'dart:io';

import 'package:wenzagent/src/persistence/entities/device_config_entity.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/device/device_client.dart';
import 'package:wenzagent/src/device/impl/device_client_impl.dart';

Future<void> main() async {
  print('========== 设备配置使用示例 ==========\n');

  // 1. 初始化持久化层
  final testPath = '${Directory.systemTemp.path}/device_config_example';
  await Directory(testPath).create(recursive: true);
  await DatabaseManager.instance.initialize(storagePath: testPath);

  // 2. 创建设备客户端
  final deviceClient = DeviceClientImpl(
    deviceId: 'device-example-001',
    deviceName: '示例设备',
    host: 'localhost',
    port: 9090,
  );

  try {
    // ===== 示例 1: 获取设备配置 =====
    print('【示例 1】获取设备配置');
    var config = await deviceClient.getDeviceConfig();
    print('设备ID: ${config.deviceId}');
    print('设备名称: ${config.deviceInfo.name ?? "未设置"}');
    print('');

    // ===== 示例 2: 更新设备信息 =====
    print('【示例 2】更新设备信息');
    await deviceClient.updateDeviceInfo(DeviceInfoConfig(
      name: '我的开发工作站',
      type: 'desktop',
      description: '主要用于 Flutter 开发的工作站',
      os: 'Windows',
      osVersion: '11',
      appVersion: '1.0.0',
      model: 'Dell XPS 15',
      manufacturer: 'Dell',
      tags: ['development', 'flutter', 'primary'],
      metadata: {
        'location': 'office',
        'user': 'developer',
        'department': 'R&D',
      },
    ));

    config = await deviceClient.getDeviceConfig();
    print('设备名称: ${config.deviceInfo.name}');
    print('设备类型: ${config.deviceInfo.type}');
    print('操作系统: ${config.deviceInfo.os} ${config.deviceInfo.osVersion}');
    print('设备型号: ${config.deviceInfo.model}');
    print('标签: ${config.deviceInfo.tags.join(", ")}');
    print('');

    // ===== 示例 3: 批量设置环境变量 =====
    print('【示例 3】批量设置环境变量');
    await deviceClient.updateEnvironmentVariables({
      'API_URL': 'https://api.example.com',
      'API_VERSION': 'v2',
      'DEBUG_MODE': 'true',
      'MAX_CONNECTIONS': '100',
      'TIMEOUT': '30',
    });

    config = await deviceClient.getDeviceConfig();
    print('已设置 ${config.environmentVariables.length} 个环境变量:');
    config.environmentVariables.forEach((key, value) {
      print('  $key = $value');
    });
    print('');

    // ===== 示例 4: 设置单个环境变量 =====
    print('【示例 4】设置单个环境变量');
    await deviceClient.setEnvironmentVariable('DATABASE_URL', 'postgresql://localhost:5432/myapp');
    await deviceClient.setEnvironmentVariable('REDIS_URL', 'redis://localhost:6379');

    config = await deviceClient.getDeviceConfig();
    print('DATABASE_URL: ${config.environmentVariables["DATABASE_URL"]}');
    print('REDIS_URL: ${config.environmentVariables["REDIS_URL"]}');
    print('');

    // ===== 示例 5: 使用环境变量 =====
    print('【示例 5】使用环境变量');
    final apiUrl = config.environmentVariables['API_URL'];
    final debugMode = config.environmentVariables['DEBUG_MODE'] == 'true';
    final timeout = int.tryParse(config.environmentVariables['TIMEOUT'] ?? '10') ?? 10;

    print('API 地址: $apiUrl');
    print('调试模式: ${debugMode ? "开启" : "关闭"}');
    print('超时时间: ${timeout}秒');
    print('');

    // ===== 示例 6: 删除环境变量 =====
    print('【示例 6】删除环境变量');
    await deviceClient.deleteEnvironmentVariable('DEBUG_MODE');

    config = await deviceClient.getDeviceConfig();
    print('删除 DEBUG_MODE 后的环境变量数量: ${config.environmentVariables.length}');
    print('DEBUG_MODE 是否存在: ${config.environmentVariables.containsKey("DEBUG_MODE")}');
    print('');

    // ===== 示例 7: 完整配置摘要 =====
    print('【示例 7】完整配置摘要');
    print('─' * 50);
    print('设备信息:');
    print('  ID: ${config.deviceId}');
    print('  名称: ${config.deviceInfo.name}');
    print('  类型: ${config.deviceInfo.type}');
    print('  描述: ${config.deviceInfo.description}');
    print('  操作系统: ${config.deviceInfo.os} ${config.deviceInfo.osVersion}');
    print('  应用版本: ${config.deviceInfo.appVersion}');
    print('  设备型号: ${config.deviceInfo.model}');
    print('  制造商: ${config.deviceInfo.manufacturer}');
    print('  标签: ${config.deviceInfo.tags.join(", ")}');
    print('  元数据:');
    config.deviceInfo.metadata.forEach((key, value) {
      print('    $key: $value');
    });
    print('');
    print('环境变量 (${config.environmentVariables.length} 个):');
    config.environmentVariables.forEach((key, value) {
      print('  $key: $value');
    });
    print('─' * 50);
    print('');

    print('✅ 所有示例执行完成！');
  } finally {
    // 清理资源
    await deviceClient.dispose();
    await DatabaseManager.instance.close();

    // 删除测试目录
    try {
      await Directory(testPath).delete(recursive: true);
    } catch (_) {}
  }
}
