import 'dart:async';
import 'dart:io';

import 'package:wenzagent/wenzagent.dart';

/// Topic 过滤测试
///
/// 测试场景：
/// 1. 启动 LAN Host
/// 2. Device-A 使用 topic "group1" 连接
/// 3. Device-B 使用 topic "group1" 连接
/// 4. Device-C 使用 topic "group2" 连接
/// 5. 验证 Device-A/B 只能看到同 topic 的设备（group1）
/// 6. 验证 Device-C 只能看到同 topic 的设备（group2）

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║                  Topic 分组过滤测试                        ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = TopicFilterTest();
  await test.run();
}

class TopicFilterTest {
  late LanHostServiceImpl host;
  late DeviceClientImpl deviceA;
  late DeviceClientImpl deviceB;
  late DeviceClientImpl deviceC;

  Future<void> run() async {
    try {
      // ===== 阶段 1: 初始化存储 =====
      print('\n[阶段 1] 初始化存储...');
      await _initializeStorage();

      // ===== 阶段 2: 启动 LAN Host =====
      print('\n[阶段 2] 启动 LAN Host...');
      await _startHost();

      // ===== 阶段 3: Device-A 连接 (topic: group1) =====
      print('\n[阶段 3] Device-A 连接 (topic: group1)...');
      await _connectDeviceA();

      // ===== 阶段 4: Device-B 连接 (topic: group1) =====
      print('\n[阶段 4] Device-B 连接 (topic: group1)...');
      await _connectDeviceB();

      // ===== 阶段 5: Device-C 连接 (topic: group2) =====
      print('\n[阶段 5] Device-C 连接 (topic: group2)...');
      await _connectDeviceC();

      // ===== 阶段 6: 验证 topic 过滤 =====
      print('\n[阶段 6] 验证 topic 过滤...');
      await _verifyTopicFilter();

      print('\n╔══════════════════════════════════════════════════════════╗');
      print('║                    ✓ 所有测试通过！                        ║');
      print('╚══════════════════════════════════════════════════════════╝\n');
    } catch (e, stackTrace) {
      print('❌ 测试失败: $e');
      print(stackTrace);
    } finally {
      await _cleanup();
    }
  }

  /// 初始化存储
  Future<void> _initializeStorage() async {
    final tempDir = await Directory.systemTemp.createTemp(
      'wenzagent_topic_filter_',
    );
    print('  临时目录: ${tempDir.path}');
    await DatabaseManager.instance.initialize(storagePath: tempDir.path);
    print('  ✓ Hive 初始化完成');
  }

  /// 启动 LAN Host
  Future<void> _startHost() async {
    host = LanHostServiceImpl();
    await host.start(port: 0);
    print('  ✓ Host 已启动: ${host.localIp}:${host.port}');
  }

  /// Device-A 连接 (topic: group1)
  Future<void> _connectDeviceA() async {
    deviceA = DeviceClientImpl(
      deviceId: 'device-alpha',
      deviceName: 'Device Alpha',
      host: host.localIp!,
      port: host.port,
      topic: 'group1',
    );
    await deviceA.connect();
    print('  ✓ Device-A 已连接 (topic: group1)');

    // 等待一小段时间确保连接注册
    await Future.delayed(const Duration(milliseconds: 100));
  }

  /// Device-B 连接 (topic: group1)
  Future<void> _connectDeviceB() async {
    deviceB = DeviceClientImpl(
      deviceId: 'device-beta',
      deviceName: 'Device Beta',
      host: host.localIp!,
      port: host.port,
      topic: 'group1',
    );
    await deviceB.connect();
    print('  ✓ Device-B 已连接 (topic: group1)');

    // 等待一小段时间确保连接注册
    await Future.delayed(const Duration(milliseconds: 100));
  }

  /// Device-C 连接 (topic: group2)
  Future<void> _connectDeviceC() async {
    deviceC = DeviceClientImpl(
      deviceId: 'device-gamma',
      deviceName: 'Device Gamma',
      host: host.localIp!,
      port: host.port,
      topic: 'group2',
    );
    await deviceC.connect();
    print('  ✓ Device-C 已连接 (topic: group2)');

    // 等待一小段时间确保连接注册
    await Future.delayed(const Duration(milliseconds: 100));
  }

  /// 验证 topic 过滤
  Future<void> _verifyTopicFilter() async {
    // Device-A (group1) 应该看到 device-alpha 和 device-beta
    print('\n  [验证] Device-A (topic: group1) 获取在线设备...');
    final devicesA = await deviceA.getOnlineDevices();
    print('    设备数量: ${devicesA.length}');
    for (final device in devicesA) {
      print('    - ${device.id} (${device.name})');
    }

    assert(devicesA.length == 2, 'Device-A 应该看到 2 个设备');
    assert(devicesA.any((d) => d.id == 'device-alpha'), '应该包含 device-alpha');
    assert(devicesA.any((d) => d.id == 'device-beta'), '应该包含 device-beta');
    assert(!devicesA.any((d) => d.id == 'device-gamma'), '不应该包含 device-gamma');
    print('    ✓ Device-A 只看到 group1 的设备');

    // Device-B (group1) 应该看到 device-alpha 和 device-beta
    print('\n  [验证] Device-B (topic: group1) 获取在线设备...');
    final devicesB = await deviceB.getOnlineDevices();
    print('    设备数量: ${devicesB.length}');
    for (final device in devicesB) {
      print('    - ${device.id} (${device.name})');
    }

    assert(devicesB.length == 2, 'Device-B 应该看到 2 个设备');
    assert(devicesB.any((d) => d.id == 'device-alpha'), '应该包含 device-alpha');
    assert(devicesB.any((d) => d.id == 'device-beta'), '应该包含 device-beta');
    assert(!devicesB.any((d) => d.id == 'device-gamma'), '不应该包含 device-gamma');
    print('    ✓ Device-B 只看到 group1 的设备');

    // Device-C (group2) 应该只看到 device-gamma
    print('\n  [验证] Device-C (topic: group2) 获取在线设备...');
    final devicesC = await deviceC.getOnlineDevices();
    print('    设备数量: ${devicesC.length}');
    for (final device in devicesC) {
      print('    - ${device.id} (${device.name})');
    }

    assert(devicesC.length == 1, 'Device-C 应该看到 1 个设备');
    assert(devicesC.any((d) => d.id == 'device-gamma'), '应该包含 device-gamma');
    assert(!devicesC.any((d) => d.id == 'device-alpha'), '不应该包含 device-alpha');
    assert(!devicesC.any((d) => d.id == 'device-beta'), '不应该包含 device-beta');
    print('    ✓ Device-C 只看到 group2 的设备');

    print('\n  ✓ Topic 过滤功能正常');
  }

  /// 清理
  Future<void> _cleanup() async {
    print('\n[清理] 释放资源...');

    try {
      await deviceA.disconnect();
      print('  ✓ Device-A 已断开');
    } catch (_) {}

    try {
      await deviceB.disconnect();
      print('  ✓ Device-B 已断开');
    } catch (_) {}

    try {
      await deviceC.disconnect();
      print('  ✓ Device-C 已断开');
    } catch (_) {}

    try {
      await host.stop();
      print('  ✓ Host 已停止');
    } catch (_) {}

    print('  ✓ 清理完成');
  }
}
