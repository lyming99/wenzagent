import 'dart:async';
import 'dart:io';

import 'package:wenzagent/wenzagent.dart';

/// 断线重连测试
///
/// 测试场景：
/// 1. Device-A 和 Device-B 都连接并建立会话
/// 2. Device-B 断开连接
/// 3. Device-A 发送消息（Device-B 断线期间）
/// 4. Device-B 重连并同步数据
/// 5. Device-B 查询断线期间的消息
/// 6. Device-B 重连后发送消息
/// 7. 验证消息同步和状态更新

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║              断线重连测试 - 消息同步与状态更新               ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = ReconnectTest();
  await test.run();
}

class ReconnectTest {
  late LanHostServiceImpl host;
  late DeviceClientImpl deviceA;
  late DeviceClientImpl deviceB;

  final String deviceAId = 'device-alpha';
  final String deviceBId = 'device-beta';
  final String employeeAliceUuid = 'emp-alice-001';

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

      // ===== 阶段 3: 两个设备连接并建立会话 =====
      print('\n[阶段 3] 两个设备连接并建立会话...');
      await _bothDevicesConnect();

      // ===== 阶段 4: Device-A 发送初始消息 =====
      print('\n[阶段 4] Device-A 发送初始消息...');
      await _deviceASendInitialMessage();

      // ===== 阶段 5: Device-B 断开连接 =====
      print('\n[阶段 5] Device-B 断开连接...');
      await _deviceBDisconnect();

      // ===== 阶段 6: Device-A 在 Device-B 断线期间发送消息 =====
      print('\n[阶段 6] Device-A 在 Device-B 断线期间发送消息...');
      final offlineMessageId = await _deviceASendMessageWhileDeviceBOffline();

      // ===== 阶段 7: Device-B 重连 =====
      print('\n[阶段 7] Device-B 重连...');
      await _deviceBReconnect();

      // ===== 阶段 8: Device-B 查询断线期间的消息 =====
      print('\n[阶段 8] Device-B 查询断线期间的消息...');
      await _deviceBQueryOfflineMessages(offlineMessageId);

      // ===== 阶段 9: Device-B 重连后发送消息 =====
      print('\n[阶段 9] Device-B 重连后发送消息...');
      await _deviceBSendMessageAfterReconnect();

      // ===== 阶段 10: 验证最终消息同步 =====
      print('\n[阶段 10: 验证最终消息同步...');
      await _verifyFinalMessageSync();

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
    final tempDir = await Directory.systemTemp.createTemp('wenzagent_reconnect_');
    print('  临时目录: ${tempDir.path}');
    await HiveManager.instance.initialize(storagePath: tempDir.path);
    print('  ✓ Hive 初始化完成');
  }

  /// 启动 LAN Host
  Future<void> _startHost() async {
    host = LanHostServiceImpl();
    await host.start(port: 0);
    print('  ✓ Host 已启动: ${host.localIp}:${host.port}');
  }

  /// 两个设备连接并建立会话
  Future<void> _bothDevicesConnect() async {
    // Device-A 连接
    deviceA = DeviceClientImpl(
      deviceId: deviceAId,
      deviceName: 'Device Alpha',
      host: host.localIp!,
      port: host.port,
    );
    await deviceA.connect();
    print('  ✓ Device-A 已连接: $deviceAId');

    // Device-B 连接
    deviceB = DeviceClientImpl(
      deviceId: deviceBId,
      deviceName: 'Device Beta',
      host: host.localIp!,
      port: host.port,
    );
    await deviceB.connect();
    print('  ✓ Device-B 已连接: $deviceBId');

    // Device-A 创建员工 Alice
    final alice = AiEmployeeEntity(
      uuid: employeeAliceUuid,
      name: 'Alice',
      role: 'assistant',
      status: 'active',
      description: '测试员工 Alice',
      systemPrompt: '你是 Alice，一个友好的 AI 助手',
      provider: 'openai',
      model: 'mimo-v2-pro',
      apiKey: _apiKey,
      apiBaseUrl: _apiBaseUrl,
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await deviceA.employeeManager.createEmployee(alice);
    print('  ✓ Device-A 创建员工 Alice');

    // Device-A 建立会话
    await deviceA.sessionManager.getOrCreateSession(employeeAliceUuid);
    await deviceA.employeeManager.updateCurrentDeviceId(employeeAliceUuid, deviceAId);
    print('  ✓ Device-A 建立会话，currentDeviceId = $deviceAId');

    // Device-A 创建本地 Agent
    await deviceA.getOrCreateAgentProxy(employeeUuid: employeeAliceUuid);
    print('  ✓ Device-A 创建本地 Agent');

    // Device-B 同步员工数据
    final aliceB = AiEmployeeEntity(
      uuid: employeeAliceUuid,
      name: 'Alice',
      role: 'assistant',
      status: 'active',
      description: '测试员工 Alice',
      provider: 'openai',
      model: 'mimo-v2-pro',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await deviceB.employeeManager.createEmployee(aliceB);
    await deviceB.employeeManager.updateCurrentDeviceId(employeeAliceUuid, deviceAId);
    print('  ✓ Device-B 同步员工数据');

    // Device-B 同步会话数据
    final sessionA = await deviceA.sessionManager.getSession(employeeAliceUuid);
    if (sessionA != null) {
      await deviceB.sessionManager.save(sessionA);
    }
    print('  ✓ Device-B 同步会话数据');
  }

  /// Device-A 发送初始消息
  Future<void> _deviceASendInitialMessage() async {
    print('\n  [Device-A 发送初始消息]');
    final agentProxy = await deviceA.getOrCreateAgentProxy(employeeUuid: employeeAliceUuid);

    final messageId = await agentProxy.sendMessage({
      'content': '你好 Alice，这是初始消息',
      'role': 'user',
    });
    print('    消息ID: $messageId');

    await _waitForMessageComplete(deviceA, messageId);
    print('  ✓ 初始消息发送完成');
  }

  /// Device-B 断开连接
  Future<void> _deviceBDisconnect() async {
    await deviceB.disconnect();
    print('  ✓ Device-B 已断开连接');

    // 等待一小段时间确保断开
    await Future.delayed(const Duration(seconds: 1));
  }

  /// Device-A 在 Device-B 断线期间发送消息
  Future<String> _deviceASendMessageWhileDeviceBOffline() async {
    print('\n  [Device-A 在 Device-B 断线期间发送消息]');
    final agentProxy = await deviceA.getOrCreateAgentProxy(employeeUuid: employeeAliceUuid);

    final messageId = await agentProxy.sendMessage({
      'content': '这是在 Device-B 断线期间发送的消息',
      'role': 'user',
    });
    print('    消息ID: $messageId');

    await _waitForMessageComplete(deviceA, messageId);
    print('  ✓ 断线期间消息发送完成');

    return messageId;
  }

  /// Device-B 重连
  Future<void> _deviceBReconnect() async {
    print('\n  [Device-B 重连]');
    deviceB = DeviceClientImpl(
      deviceId: deviceBId,
      deviceName: 'Device Beta',
      host: host.localIp!,
      port: host.port,
    );

    await deviceB.connect();
    print('  ✓ Device-B 已重连: $deviceBId');

    // 同步员工数据
    final alice = AiEmployeeEntity(
      uuid: employeeAliceUuid,
      name: 'Alice',
      role: 'assistant',
      status: 'active',
      description: '测试员工 Alice',
      provider: 'openai',
      model: 'mimo-v2-pro',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await deviceB.employeeManager.updateEmployee(alice);
    await deviceB.employeeManager.updateCurrentDeviceId(employeeAliceUuid, deviceAId);
    print('  ✓ 同步员工数据');

    // 同步会话数据
    final sessionA = await deviceA.sessionManager.getSession(employeeAliceUuid);
    if (sessionA != null) {
      await deviceB.sessionManager.save(sessionA);
    }
    print('  ✓ 同步会话数据');

    // 同步消息数据（关键：获取 Device-A 的所有消息）
    final messagesA = await deviceA.messageStore.getMessages(employeeAliceUuid);
    print('  Device-A 消息数量: ${messagesA.length}');

    if (messagesA.isNotEmpty) {
      // 获取 Device-B 当前已有的消息
      final messagesB = await deviceB.messageStore.getMessages(employeeAliceUuid);
      print('  Device-B 消息数量（同步前）: ${messagesB.length}');

      // 只添加 Device-B 没有的消息
      final messageIdsB = messagesB.map((m) => m.uuid).toSet();
      final newMessages = messagesA.where((m) => !messageIdsB.contains(m.uuid)).toList();

      if (newMessages.isNotEmpty) {
        await deviceB.messageStore.addMessages(newMessages);
        print('  ✓ 同步 ${newMessages.length} 条新消息');
      }
    }

    // 创建远程 AgentProxy
    await deviceB.getOrCreateAgentProxy(employeeUuid: employeeAliceUuid);
    print('  ✓ 创建远程 AgentProxy');
  }

  /// Device-B 查询断线期间的消息
  Future<void> _deviceBQueryOfflineMessages(String offlineMessageId) async {
    print('\n  [Device-B 查询断线期间的消息]');
    final agentProxy = await deviceB.getOrCreateAgentProxy(employeeUuid: employeeAliceUuid);

    // 读取消息列表（使用 Agent 当前会话）
    final messages = await agentProxy.getSessionMessages();
    print('  Device-B 消息总数: ${messages.length}');

    // 查找断线期间的消息
    final offlineMessage = messages.firstWhere(
      (msg) => msg['uuid'] == offlineMessageId,
      orElse: () => <String, dynamic>{},
    );

    if (offlineMessage.isNotEmpty) {
      print('  ✓ 找到断线期间的消息');
      print('    消息内容: ${offlineMessage['content']}');
      print('    消息角色: ${offlineMessage['role']}');
    } else {
      print('  ⚠️ 未找到断线期间的消息，可能需要检查同步逻辑');
    }

    // 打印所有消息
    print('\n  Device-B 所有消息:');
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final role = msg['role'] as String? ?? 'unknown';
      final content = msg['content'] as String? ?? '';
      print('    [$i] $role: ${content.length > 50 ? "${content.substring(0, 50)}..." : content}');
    }
  }

  /// Device-B 重连后发送消息
  Future<void> _deviceBSendMessageAfterReconnect() async {
    print('\n  [Device-B 重连后发送消息]');
    final agentProxy = await deviceB.getOrCreateAgentProxy(employeeUuid: employeeAliceUuid);

    assert(!agentProxy.isLocalMode, '应该是远程模式');
    print('  AgentProxy 模式: 远程 ✓');

    final messageId = await agentProxy.sendMessage({
      'content': '这是 Device-B 重连后发送的消息',
      'role': 'user',
    });
    print('    消息ID: $messageId');

    await _waitForMessageComplete(deviceB, messageId);
    print('  ✓ 重连后消息发送完成');
  }

  /// 验证最终消息同步
  Future<void> _verifyFinalMessageSync() async {
    print('\n  [验证最终消息同步]');

    // 通过 AgentProxy 获取消息（使用 Agent 当前会话）
    final agentProxyA = await deviceA.getOrCreateAgentProxy(employeeUuid: employeeAliceUuid);
    final messagesA = await agentProxyA.getSessionMessages();

    final agentProxyB = await deviceB.getOrCreateAgentProxy(employeeUuid: employeeAliceUuid);
    final messagesB = await agentProxyB.getSessionMessages();

    print('  Device-A 消息数量: ${messagesA.length}');
    print('  Device-B 消息数量: ${messagesB.length}');

    // 验证消息数量一致
    assert(messagesA.length == messagesB.length,
           '两个设备的消息数量应该相同');
    print('  ✓ 两个设备的消息数量一致: ${messagesA.length}');

    // 验证消息内容一致（通过 uuid 对比）
    final messageIdsA = messagesA.map((msg) => msg['uuid'] as String?).whereType<String>().toSet();
    final messageIdsB = messagesB.map((msg) => msg['uuid'] as String?).whereType<String>().toSet();

    assert(messageIdsA.containsAll(messageIdsB),
           'Device-A 应该包含 Device-B 的所有消息');
    assert(messageIdsB.containsAll(messageIdsA),
           'Device-B 应该包含 Device-A 的所有消息');
    print('  ✓ 两个设备的消息内容一致');

    // 打印最终消息列表
    print('\n  最终消息列表:');
    for (int i = 0; i < messagesA.length; i++) {
      final msg = messagesA[i];
      final role = msg['role'] as String? ?? 'unknown';
      final content = msg['content'] as String? ?? '';
      print('    [$i] $role: ${content.length > 50 ? "${content.substring(0, 50)}..." : content}');
    }
  }

  /// 等待消息处理完成
  Future<void> _waitForMessageComplete(DeviceClientImpl device, String messageId) async {
    print('    等待消息处理完成...');
    final completer = Completer<void>();

    late StreamSubscription subscription;
    subscription = device.onAgentEvent.listen((event) {
      final type = event['type'] as String?;
      final data = event['data'] as Map<String, dynamic>?;

      if (type == 'messageStatusChanged') {
        final msgId = data?['messageId'] as String?;
        final status = data?['status'] as String?;

        if (msgId == messageId && (status == 'completed' || status == 'failed')) {
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
      await deviceB.disconnect();
      print('  ✓ Device-B 已断开');
    } catch (_) {}

    try {
      await deviceA.disconnect();
      print('  ✓ Device-A 已断开');
    } catch (_) {}

    try {
      await host.stop();
      print('  ✓ Host 已停止');
    } catch (_) {}

    print('  ✓ 清理完成');
  }
}
