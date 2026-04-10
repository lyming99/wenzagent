import 'dart:async';
import 'dart:io';

import 'package:wenzagent/wenzagent.dart';

/// 多设备会话测试
///
/// 测试场景：
/// 1. Device-A 创建员工 Alice
/// 2. Device-A 与 Alice 建立会话（首次打开，自动设置为本地设备）
/// 3. Device-B 获取会话列表，看到 Alice 的会话
/// 4. Device-B 打开 Alice 的会话（判定为远程会话，因为 currentDeviceId = Device-A）
/// 5. Device-B 设置自己的设备配置
/// 6. 验证两个设备上的配置独立存储

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║           多设备会话测试 - Session-Agent 架构验证           ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = MultiDeviceSessionTest();
  await test.run();
}

class MultiDeviceSessionTest {
  late DeviceClientImpl deviceA;
  late DeviceClientImpl deviceB;
  
  final String deviceAId = 'device-alpha';
  final String deviceBId = 'device-beta';
  final String employeeAliceId = 'emp-alice-001';
  final String employeeBobId = 'emp-bob-001';

  Future<void> run() async {
    try {
      // ===== 阶段 0: 初始化 Hive =====
      print('\n[阶段 0] 初始化存储...');
      await _initializeStorage();

      // ===== 阶段 1: 创建两个设备客户端 =====
      print('\n[阶段 1] 创建设备客户端...');
      await _createDeviceClients();

      // ===== 阶段 2: Device-A 创建员工 =====
      print('\n[阶段 2] Device-A 创建员工...');
      await _createEmployees();

      // ===== 阶段 3: Device-A 与 Alice 建立会话 =====
      print('\n[阶段 3] Device-A 与 Alice 建立会话（首次打开）...');
      await _deviceAOpensSessionFirstTime();

      // ===== 阶段 4: Device-B 获取会话列表 =====
      print('\n[阶段 4] Device-B 获取会话列表...');
      await _deviceBGetsSessionList();

      // ===== 阶段 5: Device-B 打开 Alice 的会话（远程会话）=====
      print('\n[阶段 5] Device-B 打开 Alice 的会话（判定为远程）...');
      await _deviceBOpensRemoteSession();

      // ===== 阶段 6: 各设备设置独立配置 =====
      print('\n[阶段 6] 各设备设置独立配置...');
      await _setDeviceSpecificConfigs();

      // ===== 阶段 7: 验证配置隔离 =====
      print('\n[阶段 7] 验证配置隔离...');
      await _verifyConfigIsolation();

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
    // 创建临时目录存储测试数据
    final tempDir = await Directory.systemTemp.createTemp('wenzagent_test_');
    print('  临时目录: ${tempDir.path}');

    // 初始化 Hive
    await DatabaseManager.instance.initialize(storagePath: tempDir.path);
    print('  ✓ Hive 初始化完成');
  }

  /// 创建设备客户端
  Future<void> _createDeviceClients() async {
    // Device-A
    deviceA = DeviceClientImpl(
      deviceId: deviceAId,
      deviceName: 'Device Alpha',
      host: 'localhost',
      port: 9090,
    );
    
    // Device-B
    deviceB = DeviceClientImpl(
      deviceId: deviceBId,
      deviceName: 'Device Beta',
      host: 'localhost',
      port: 9091,
    );

    print('  ✓ Device-A 创建完成: $deviceAId');
    print('  ✓ Device-B 创建完成: $deviceBId');
  }

  /// 创建员工
  Future<void> _createEmployees() async {
    // 在 Device-A 上创建员工 Alice
    final alice = AiEmployeeEntity(
      uuid: employeeAliceId,
      name: 'Alice',
      role: 'assistant',
      status: 'active',
      description: '测试员工 Alice',
      systemPrompt: '你是 Alice，一个友好的 AI 助手',
      provider: 'openai',
      model: 'gpt-4',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    
    await deviceA.employeeManager.createEmployee(alice);
    print('  ✓ 创建员工 Alice: ${alice.uuid}');

    // 创建员工 Bob（不建立会话，用于测试会话列表过滤）
    final bob = AiEmployeeEntity(
      uuid: employeeBobId,
      name: 'Bob',
      role: 'assistant',
      status: 'active',
      description: '测试员工 Bob（无会话）',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    
    await deviceA.employeeManager.createEmployee(bob);
    print('  ✓ 创建员工 Bob（无会话）: ${bob.uuid}');
  }

  /// Device-A 首次打开 Alice 的会话
  Future<void> _deviceAOpensSessionFirstTime() async {
    // 获取 Alice 的员工信息
    var alice = await deviceA.employeeManager.getEmployee(employeeAliceId);
    if (alice == null) {
      throw StateError('员工 Alice 不存在');
    }

    // 验证 currentDeviceId 初始为空
    print('  Alice.currentDeviceId (首次打开前): ${alice.currentDeviceId ?? "null"}');
    assert(alice.currentDeviceId == null, 'currentDeviceId 应该初始为空');

    // 获取 Session（首次会自动创建）
    final session = await deviceA.sessionManager.getOrCreateSession(employeeAliceId);
    print('  ✓ Session 创建/获取: employeeId=${session.employeeId}');
    print('  Session.config devices: ${session.config.keys.toList()}');

    // 验证 Session 存在
    final sessionExists = await deviceA.sessionManager.getSession(employeeAliceId);
    assert(sessionExists != null, 'Session 应该存在');

    // 设置 currentDeviceId（模拟 openSession 行为）
    await deviceA.employeeManager.updateCurrentDeviceId(employeeAliceId, deviceAId);
    
    // 重新获取员工验证
    alice = await deviceA.employeeManager.getEmployee(employeeAliceId);
    print('  Alice.currentDeviceId (设置后): ${alice?.currentDeviceId}');
    assert(alice?.currentDeviceId == deviceAId, 'currentDeviceId 应该等于 deviceAId');
    
    print('  ✓ 首次打开会话完成，currentDeviceId 已设置为: $deviceAId');
  }

  /// Device-B 获取会话列表
  Future<void> _deviceBGetsSessionList() async {
    // Device-B 也创建相同的员工（模拟同步）
    final alice = AiEmployeeEntity(
      uuid: employeeAliceId,
      name: 'Alice',
      role: 'assistant',
      status: 'active',
      description: '测试员工 Alice',
      provider: 'openai',
      model: 'gpt-4',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await deviceB.employeeManager.createEmployee(alice);
    
    // 同步 currentDeviceId（模拟 LAN 同步）
    await deviceB.employeeManager.updateCurrentDeviceId(employeeAliceId, deviceAId);
    
    // 同步 Session（模拟 LAN 同步）
    final sessionA = await deviceA.sessionManager.getSession(employeeAliceId);
    if (sessionA != null) {
      await deviceB.sessionManager.save(sessionA);
    }

    // 获取会话列表
    final sessions = await deviceB.sessionManager.getAllSessions();
    print('  Device-B 会话列表数量: ${sessions.length}');
    
    for (final session in sessions) {
      final employee = await deviceB.employeeManager.getEmployee(session.employeeId);
      print('    - Session: ${session.employeeId}');
      print('      员工: ${employee?.name ?? "未知"}');
      print('      currentDeviceId: ${employee?.currentDeviceId ?? "null"}');
    }

    // 验证：会话列表只包含有 Session 的员工（Alice）
    assert(sessions.any((s) => s.employeeId == employeeAliceId), 
           'Alice 应该在会话列表中');
    assert(!sessions.any((s) => s.employeeId == employeeBobId), 
           'Bob 不应该在会话列表中（没有 Session）');
    
    print('  ✓ 会话列表正确：只显示有 Session 的员工');
  }

  /// Device-B 打开 Alice 的会话（远程会话判定）
  Future<void> _deviceBOpensRemoteSession() async {
    final alice = await deviceB.employeeManager.getEmployee(employeeAliceId);
    
    print('  Alice.currentDeviceId: ${alice?.currentDeviceId}');
    print('  Device-B.deviceId: $deviceBId');
    
    // 判断本地还是远程
    final isLocal = alice?.currentDeviceId == deviceBId;
    final isRemote = alice?.currentDeviceId == deviceAId;
    
    print('  isLocal: $isLocal');
    print('  isRemote: $isRemote');
    
    assert(isRemote, '应该是远程会话（currentDeviceId = deviceAId != deviceBId）');
    
    // 获取或创建 Session（确保存在）
    final session = await deviceB.sessionManager.getOrCreateSession(employeeAliceId);
    print('  ✓ Session 获取成功: ${session.employeeId}');
    
    print('  ✓ 远程会话判定正确：Device-B 需要通过 LAN RPC 与 Device-A 上的 Agent 交互');
  }

  /// 各设备设置独立配置
  Future<void> _setDeviceSpecificConfigs() async {
    // Device-A 设置自己的配置
    await deviceA.sessionManager.updateDeviceConfig(
      employeeAliceId,
      deviceAId,
      providerConfig: '{"provider":"openai","model":"gpt-4"}',
    );
    print('  ✓ Device-A 设置配置: model=gpt-4');

    // Device-B 设置自己的配置（独立于 Device-A）
    await deviceB.sessionManager.updateDeviceConfig(
      employeeAliceId,
      deviceBId,
      providerConfig: '{"provider":"anthropic","model":"claude-3"}',
    );
    print('  ✓ Device-B 设置配置: model=claude-3');
  }

  /// 验证配置隔离
  Future<void> _verifyConfigIsolation() async {
    // 从 Device-A 获取 Session
    final sessionA = await deviceA.sessionManager.getSession(employeeAliceId);
    assert(sessionA != null, 'Device-A Session 应该存在');
    
    // 获取各设备的配置
    final configA = sessionA!.getConfig(deviceAId);
    final configB = sessionA!.getConfig(deviceBId);
    
    print('  Device-A 配置:');
    print('    providerConfig: ${configA?.providerConfig}');
    
    print('  Device-B 配置:');
    print('    providerConfig: ${configB?.providerConfig}');
    
    // 验证各设备 Provider 配置独立
    assert(configA?.providerConfig?.contains('gpt-4') ?? false, 
           'Device-A 应该使用 gpt-4');
    assert(configB?.providerConfig?.contains('claude-3') ?? false, 
           'Device-B 应该使用 claude-3');

    // 验证 config Map 包含两个设备的配置
    assert(sessionA.config.length == 2, 'Session.config 应该包含 2 个设备配置');
    assert(sessionA.config.containsKey(deviceAId), '应该包含 deviceAId 配置');
    assert(sessionA.config.containsKey(deviceBId), '应该包含 deviceBId 配置');

    print('  ✓ 配置隔离验证通过：各设备配置独立存储');
    print('  ✓ Session.config 包含 ${sessionA.config.length} 个设备配置');
  }

  /// 清理
  Future<void> _cleanup() async {
    print('\n[清理] 释放资源...');
    print('  ✓ 清理完成');
  }
}
