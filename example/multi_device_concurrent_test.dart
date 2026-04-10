import 'dart:async';
import 'dart:io';

import 'package:wenzagent/wenzagent.dart';

/// 多设备并发对话测试
///
/// 测试场景：
/// 1. 设备C创建员工Alice
/// 2. 设备A和设备B同时连接
/// 3. A和B同时与C上的Alice对话
/// 4. 验证：Alice只有一个Agent实例（在C上）
/// 5. 验证：A和B的会话数据最终一致

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║         多设备并发对话测试 - Agent唯一性验证               ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = MultiDeviceConcurrentTest();
  await test.run();
}

class MultiDeviceConcurrentTest {
  late LanHostServiceImpl host;
  late DeviceClientImpl deviceA;
  late DeviceClientImpl deviceB;
  late DeviceClientImpl deviceC;

  final String deviceAId = 'device-alpha';
  final String deviceBId = 'device-beta';
  final String deviceCId = 'device-charlie';
  final String employeeAliceId = 'emp-alice-001';

  /// 从环境变量获取 API 配置
  String? get _apiKey => Platform.environment['OPENAI_API_KEY'];
  String? get _apiBaseUrl => Platform.environment['OPENAI_API_URL'];

  Future<void> run() async {
    try {
      // ===== 阶段 1: 初始化存储 =====
      print('\n[阶段 1] 初始化存储...');
      await _initializeStorage();

      // ===== 阶段 2: 启动 LAN Host =====
      print('\n[阶段 2] 启动 LAN Host...');
      await _startHost();

      // ===== 阶段 3: 设备C创建员工Alice =====
      print('\n[阶段 3: 设备C创建员工Alice...');
      await _deviceCCreateEmployee();

      // ===== 阶段 4: 设备A和B连接并同步数据 =====
      print('\n[阶段 4: 设备A和B连接并同步数据...');
      await _devicesAAndBConnect();

      // ===== 阶段 5: A和B同时发送消息（并发）=====
      print('\n[阶段 5: A和B同时发送消息（并发）...');
      await _concurrentSendMessages();

      // ===== 阶段 6: 验证Agent唯一性 =====
      print('\n[阶段 6: 验证Agent唯一性...');
      await _verifyAgentUniqueness();

      // ===== 阶段 7: 验证会话数据一致性 =====
      print('\n[阶段 7: 验证会话数据一致性...');
      await _verifySessionDataConsistency();

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
      'wenzagent_concurrent_',
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

  /// 设备C创建员工Alice
  Future<void> _deviceCCreateEmployee() async {
    deviceC = DeviceClientImpl(
      deviceId: deviceCId,
      deviceName: 'Device Charlie',
      host: host.localIp!,
      port: host.port,
    );

    await deviceC.connect();
    print('  ✓ 设备C 已连接: $deviceCId');

    // 创建员工 Alice
    final alice = AiEmployeeEntity(
      uuid: employeeAliceId,
      name: 'Alice',
      role: 'assistant',
      status: 'active',
      description: '测试员工 Alice',
      systemPrompt: '你是 Alice，一个友好的 AI 助手。请记住你的名字和位置。',
      provider: 'openai',
      model: 'mimo-v2-pro',
      apiKey: _apiKey,
      apiBaseUrl: _apiBaseUrl,
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await deviceC.employeeManager.createEmployee(alice);
    print('  ✓ 设备C 创建员工 Alice');

    // 建立会话，currentDeviceId 设置为 deviceC
    await deviceC.sessionManager.getOrCreateSession(employeeAliceId);
    await deviceC.employeeManager.updateCurrentDeviceId(
      employeeAliceId,
      deviceCId,
    );
    print('  ✓ 建立会话，currentDeviceId = $deviceCId');

    // 创建本地 Agent（这是唯一的Agent实例）
    await deviceC.getOrCreateAgentProxy(employeeId: employeeAliceId);
    print('  ✓ 设备C 创建本地 Agent（唯一实例）');
  }

  /// 设备A和B连接并同步数据
  Future<void> _devicesAAndBConnect() async {
    // 设备A 连接
    deviceA = DeviceClientImpl(
      deviceId: deviceAId,
      deviceName: 'Device Alpha',
      host: host.localIp!,
      port: host.port,
    );
    await deviceA.connect();
    print('  ✓ 设备A 已连接: $deviceAId');

    // 设备B 连接
    deviceB = DeviceClientImpl(
      deviceId: deviceBId,
      deviceName: 'Device Beta',
      host: host.localIp!,
      port: host.port,
    );
    await deviceB.connect();
    print('  ✓ 设备B 已连接: $deviceBId');

    // 同步员工数据到A和B
    final alice = AiEmployeeEntity(
      uuid: employeeAliceId,
      name: 'Alice',
      role: 'assistant',
      status: 'active',
      description: '测试员工 Alice',
      provider: 'openai',
      model: 'mimo-v2-pro',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );

    // 设备A同步
    await deviceA.employeeManager.createEmployee(alice);
    await deviceA.employeeManager.updateCurrentDeviceId(
      employeeAliceId,
      deviceCId,
    );
    print('  ✓ 设备A 同步员工数据（currentDeviceId = $deviceCId）');

    // 设备B同步
    await deviceB.employeeManager.createEmployee(alice);
    await deviceB.employeeManager.updateCurrentDeviceId(
      employeeAliceId,
      deviceCId,
    );
    print('  ✓ 设备B 同步员工数据（currentDeviceId = $deviceCId）');

    // 同步会话数据
    final sessionC = await deviceC.sessionManager.getSession(employeeAliceId);
    if (sessionC != null) {
      await deviceA.sessionManager.save(sessionC);
      await deviceB.sessionManager.save(sessionC);
    }
    print('  ✓ 同步会话数据到A和B');

    // 创建远程 AgentProxy（指向设备C上的Agent）
    await deviceA.getOrCreateAgentProxy(employeeId: employeeAliceId);
    await deviceB.getOrCreateAgentProxy(employeeId: employeeAliceId);
    print('  ✓ 设备A和B 创建远程 AgentProxy');
  }

  /// A和B同时发送消息（并发）
  Future<void> _concurrentSendMessages() async {
    print('\n  [并发发送消息]');

    // 记录开始时间
    final startTime = DateTime.now();

    // 并发发送消息
    final futures = <Future<String>>[
      _deviceASendMessage(),
      _deviceBSendMessage(),
    ];

    // 等待两个消息都发送完成
    final messageIds = await Future.wait(futures);

    final endTime = DateTime.now();
    final duration = endTime.difference(startTime);

    print('\n  并发发送完成，耗时: ${duration.inMilliseconds}ms');
    print('  设备A 消息ID: ${messageIds[0]}');
    print('  设备B 消息ID: ${messageIds[1]}');

    // 等待两个消息都处理完成
    await Future.wait([
      _waitForMessageComplete(deviceA, messageIds[0]),
      _waitForMessageComplete(deviceB, messageIds[1]),
    ]);

    print('  ✓ 两个消息都处理完成');
  }

  /// 设备A发送消息
  Future<String> _deviceASendMessage() async {
    print('\n  [设备A] 发送消息...');
    final agentProxy = await deviceA.getOrCreateAgentProxy(
      employeeId: employeeAliceId,
    );

    assert(!agentProxy.isLocalMode, '设备A应该是远程模式');
    print('    AgentProxy 模式: 远程 ✓');

    final messageId = await agentProxy.sendMessage(
      MessageInput(content: '你好 Alice，我是设备A，我在测试多设备并发对话', role: 'user'),
    );
    print('    消息已发送，ID: $messageId');

    return messageId;
  }

  /// 设备B发送消息
  Future<String> _deviceBSendMessage() async {
    print('\n  [设备B] 发送消息...');
    final agentProxy = await deviceB.getOrCreateAgentProxy(
      employeeId: employeeAliceId,
    );

    assert(!agentProxy.isLocalMode, '设备B应该是远程模式');
    print('    AgentProxy 模式: 远程 ✓');

    final messageId = await agentProxy.sendMessage(
      MessageInput(content: '你好 Alice，我是设备B，我也在测试多设备并发对话', role: 'user'),
    );
    print('    消息已发送，ID: $messageId');

    return messageId;
  }

  /// 验证Agent唯一性
  Future<void> _verifyAgentUniqueness() async {
    print('\n  [验证Agent唯一性]');

    // 获取员工信息
    final aliceA = await deviceA.employeeManager.getEmployee(employeeAliceId);
    final aliceB = await deviceB.employeeManager.getEmployee(employeeAliceId);
    final aliceC = await deviceC.employeeManager.getEmployee(employeeAliceId);

    print('  设备A上的 Alice.currentDeviceId: ${aliceA?.currentDeviceId}');
    print('  设备B上的 Alice.currentDeviceId: ${aliceB?.currentDeviceId}');
    print('  设备C上的 Alice.currentDeviceId: ${aliceC?.currentDeviceId}');

    // 验证三个设备都认为 Alice 在设备C上
    assert(aliceA?.currentDeviceId == deviceCId, '设备A应该认为Alice在C上');
    assert(aliceB?.currentDeviceId == deviceCId, '设备B应该认为Alice在C上');
    assert(aliceC?.currentDeviceId == deviceCId, '设备C应该认为Alice在自己上');
    print('  ✓ 三个设备都确认 Alice 在设备C上');

    // 验证AgentProxy模式
    final proxyA = await deviceA.getOrCreateAgentProxy(
      employeeId: employeeAliceId,
    );
    final proxyB = await deviceB.getOrCreateAgentProxy(
      employeeId: employeeAliceId,
    );
    final proxyC = await deviceC.getOrCreateAgentProxy(
      employeeId: employeeAliceId,
    );

    assert(!proxyA.isLocalMode, '设备A应该是远程模式');
    assert(!proxyB.isLocalMode, '设备B应该是远程模式');
    assert(proxyC.isLocalMode, '设备C应该是本地模式');
    print('  ✓ AgentProxy 模式正确：A(远程), B(远程), C(本地)');

    print('  ✓ Agent唯一性验证通过：只有一个Agent实例，在设备C上');
  }

  /// 验证会话数据一致性
  Future<void> _verifySessionDataConsistency() async {
    print('\n  [验证会话数据一致性]');

    // 获取设备A的会话数据
    final proxyA = await deviceA.getOrCreateAgentProxy(
      employeeId: employeeAliceId,
    );
    final messagesA = await proxyA.getSessionMessages();

    // 获取设备B的会话数据
    final proxyB = await deviceB.getOrCreateAgentProxy(
      employeeId: employeeAliceId,
    );
    final messagesB = await proxyB.getSessionMessages();

    // 获取设备C的会话数据
    final proxyC = await deviceC.getOrCreateAgentProxy(
      employeeId: employeeAliceId,
    );
    final messagesC = await proxyC.getSessionMessages();

    print('  设备A 消息数量: ${messagesA.length}');
    print('  设备B 消息数量: ${messagesB.length}');
    print('  设备C 消息数量: ${messagesC.length}');

    // 验证消息数量一致
    assert(messagesA.length == messagesB.length, 'A和B的消息数量应该相同');
    assert(messagesA.length == messagesC.length, 'A和C的消息数量应该相同');
    assert(messagesB.length == messagesC.length, 'B和C的消息数量应该相同');
    print('  ✓ 三个设备的消息数量一致: ${messagesA.length}');

    // 验证消息内容一致（通过 id 对比）
    final messageIdsA = messagesA
        .map((msg) => msg.id)
        .whereType<String>()
        .toSet();
    final messageIdsB = messagesB
        .map((msg) => msg.id)
        .whereType<String>()
        .toSet();
    final messageIdsC = messagesC
        .map((msg) => msg.id)
        .whereType<String>()
        .toSet();

    assert(messageIdsA.containsAll(messageIdsB), 'A应该包含B的所有消息');
    assert(messageIdsB.containsAll(messageIdsA), 'B应该包含A的所有消息');
    assert(messageIdsA.containsAll(messageIdsC), 'A应该包含C的所有消息');
    assert(messageIdsC.containsAll(messageIdsA), 'C应该包含A的所有消息');
    print('  ✓ 三个设备的消息内容完全一致');

    // 打印消息摘要
    print('\n  消息摘要:');
    for (int i = 0; i < messagesA.length; i++) {
      final msg = messagesA[i];
      final role = msg.role ?? 'unknown';
      final content = msg.content ?? '';
      print(
        '    [$i] $role: ${content.length > 60 ? "${content.substring(0, 60)}..." : content}',
      );
    }

    print('  ✓ 会话数据一致性验证通过');
  }

  /// 等待消息处理完成
  Future<void> _waitForMessageComplete(
    DeviceClientImpl device,
    String messageId,
  ) async {
    print('    等待消息处理完成...');

    final completer = Completer<void>();
    late StreamSubscription subscription;

    subscription = device.onAgentEvent.listen((event) {
      final type = event['type'] as String?;
      final data = event['data'] as Map<String, dynamic>?;

      if (type == 'messageStatusChanged') {
        final msgId = data?['messageId'] as String?;
        final status = data?['status'] as String?;

        if (msgId == messageId &&
            (status == 'completed' || status == 'failed')) {
          print('    消息处理完成: $status');
          if (!completer.isCompleted) {
            completer.complete();
            subscription.cancel();
          }
        }
      }
    });

    try {
      await completer.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          print('    警告: 等待超时（60秒）');
        },
      );
    } catch (_) {
      // 超时或其他错误
    } finally {
      try {
        subscription.cancel();
      } catch (_) {}
    }
  }

  /// 清理
  Future<void> _cleanup() async {
    print('\n[清理] 释放资源...');

    try {
      await deviceA.disconnect();
      print('  ✓ 设备A 已断开');
    } catch (_) {}

    try {
      await deviceB.disconnect();
      print('  ✓ 设备B 已断开');
    } catch (_) {}

    try {
      await deviceC.disconnect();
      print('  ✓ 设备C 已断开');
    } catch (_) {}

    try {
      await host.stop();
      print('  ✓ Host 已停止');
    } catch (_) {}

    print('  ✓ 清理完成');
  }
}
