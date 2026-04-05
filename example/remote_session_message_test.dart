import 'dart:async';
import 'dart:io';

import 'package:wenzagent/wenzagent.dart';

/// 远程会话消息测试
///
/// 测试场景：
/// 1. Device-A 创建员工 Alice 并建立会话
/// 2. Device-A 发送几条消息
/// 3. Device-B 连接并同步数据
/// 4. Device-B 读取远程会话的消息列表
/// 5. Device-B 读取消息状态
/// 6. Device-B 通过远程会话发送消息
/// 7. 验证消息状态更新

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║              远程会话消息测试                              ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = RemoteSessionMessageTest();
  await test.run();
}

class RemoteSessionMessageTest {
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

      // ===== 阶段 3: Device-A 创建员工和会话 =====
      print('\n[阶段 3] Device-A 创建员工和会话...');
      await _deviceAConnectAndCreateSession();

      // ===== 阶段 4: Device-A 发送消息 =====
      print('\n[阶段 4] Device-A 发送消息...');
      final messageIds = await _deviceASendMessages();

      // ===== 阶段 5: Device-B 连接并同步数据 =====
      print('\n[阶段 5] Device-B 连接并同步数据...');
      await _deviceBConnectAndSync();

      // ===== 阶段 6: Device-B 读取远程会话消息列表 =====
      print('\n[阶段 6] Device-B 读取远程会话消息列表...');
      await _deviceBReadMessages();

      // ===== 阶段 7: Device-B 读取消息状态 =====
      print('\n[阶段 7] Device-B 读取消息状态...');
      await _deviceBReadMessageStatus();

      // ===== 阶段 8: Device-B 通过远程会话发送消息 =====
      print('\n[阶段 8] Device-B 通过远程会话发送消息...');
      await _deviceBSendRemoteMessage();

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
      'wenzagent_remote_message_',
    );
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

  /// Device-A 连接并创建会话
  Future<void> _deviceAConnectAndCreateSession() async {
    deviceA = DeviceClientImpl(
      deviceId: deviceAId,
      deviceName: 'Device Alpha',
      host: host.localIp!,
      port: host.port,
    );

    await deviceA.connect();
    print('  ✓ Device-A 已连接: $deviceAId');

    // 创建员工 Alice
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
    print('  ✓ 创建员工 Alice');

    // 建立会话
    await deviceA.sessionManager.getOrCreateSession(employeeAliceUuid);
    await deviceA.employeeManager.updateCurrentDeviceId(
      employeeAliceUuid,
      deviceAId,
    );
    print('  ✓ 建立会话，currentDeviceId = $deviceAId');

    // 创建本地 Agent
    await deviceA.getOrCreateAgentProxy(employeeUuid: employeeAliceUuid);
    print('  ✓ 创建本地 Agent');
  }

  /// Device-A 发送消息
  Future<List<String>> _deviceASendMessages() async {
    final agentProxy = await deviceA.getOrCreateAgentProxy(
      employeeUuid: employeeAliceUuid,
    );
    final messageIds = <String>[];

    // 发送第一条消息
    print('\n  [发送消息 1] "你好 Alice"');
    final messageId1 = await agentProxy.sendMessage({
      'content': '你好 Alice',
      'role': 'user',
    });
    messageIds.add(messageId1);
    print('    消息ID: $messageId1');

    // 等待消息处理完成
    await _waitForMessageComplete(deviceA, messageId1);

    // 发送第二条消息
    print('\n  [发送消息 2] "请介绍一下你自己"');
    final messageId2 = await agentProxy.sendMessage({
      'content': '请介绍一下你自己',
      'role': 'user',
    });
    messageIds.add(messageId2);
    print('    消息ID: $messageId2');

    // 等待消息处理完成
    await _waitForMessageComplete(deviceA, messageId2);

    return messageIds;
  }

  /// Device-B 连接并同步数据
  Future<void> _deviceBConnectAndSync() async {
    deviceB = DeviceClientImpl(
      deviceId: deviceBId,
      deviceName: 'Device Beta',
      host: host.localIp!,
      port: host.port,
    );

    await deviceB.connect();
    print('  ✓ Device-B 已连接: $deviceBId');

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
    await deviceB.employeeManager.createEmployee(alice);
    await deviceB.employeeManager.updateCurrentDeviceId(
      employeeAliceUuid,
      deviceAId,
    );
    print('  ✓ 同步员工数据');

    // 同步会话数据
    final sessionA = await deviceA.sessionManager.getSession(employeeAliceUuid);
    if (sessionA != null) {
      await deviceB.sessionManager.save(sessionA);
    }
    print('  ✓ 同步会话数据');

    // 同步消息数据（使用 employeeUuid 作为 sessionUuid）
    final messagesA = await deviceA.messageStore.getMessages(employeeAliceUuid);
    if (messagesA.isNotEmpty) {
      await deviceB.messageStore.addMessages(messagesA);
      print('  ✓ 同步 ${messagesA.length} 条消息');
    }
  }

  /// Device-B 读取远程会话消息列表
  Future<void> _deviceBReadMessages() async {
    // 获取 AgentProxy（远程模式）
    final agentProxy = await deviceB.getOrCreateAgentProxy(
      employeeUuid: employeeAliceUuid,
    );
    print('  AgentProxy 模式: ${agentProxy.isLocalMode ? "本地" : "远程"}');
    assert(!agentProxy.isLocalMode, '应该是远程模式');
    print('  ✓ AgentProxy 为远程模式');

    // 读取消息列表（使用 Agent 当前会话）
    print('\n  [读取消息列表]');
    final messages = await agentProxy.getSessionMessages();
    print('  消息数量: ${messages.length}');

    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final role = msg['role'] as String? ?? 'unknown';
      final content = msg['content'] as String? ?? '';
      final status = msg['status'] as String? ?? 'unknown';

      print(
        '    [$i] $role: ${content.length > 50 ? "${content.substring(0, 50)}..." : content}',
      );
      print('       状态: $status');
    }

    assert(messages.length >= 4, '应该至少有 4 条消息（2 用户 + 2 助手）');
    print('  ✓ 成功读取 ${messages.length} 条消息');
  }

  /// Device-B 读取消息状态
  Future<void> _deviceBReadMessageStatus() async {
    final agentProxy = await deviceB.getOrCreateAgentProxy(
      employeeUuid: employeeAliceUuid,
    );

    print('\n  [读取消息状态]');
    final messages = await agentProxy.getSessionMessages();

    // 验证消息状态
    int userMessages = 0;
    int assistantMessages = 0;
    int completedMessages = 0;

    for (final msg in messages) {
      final role = msg['role'] as String?;
      final status = msg['status'] as String?;

      if (role == 'user') {
        userMessages++;
      } else if (role == 'assistant') {
        assistantMessages++;
      }

      if (status == 'completed') {
        completedMessages++;
      }

      print('    消息: ${role} - 状态: $status');
    }

    print('  用户消息: $userMessages');
    print('  助手消息: $assistantMessages');
    print('  已完成消息: $completedMessages');

    assert(userMessages > 0, '应该有用户消息');
    assert(assistantMessages > 0, '应该有助手消息');
    assert(completedMessages > 0, '应该有已完成的消息');
    print('  ✓ 消息状态读取正常');
  }

  /// Device-B 通过远程会话发送消息
  Future<void> _deviceBSendRemoteMessage() async {
    final agentProxy = await deviceB.getOrCreateAgentProxy(
      employeeUuid: employeeAliceUuid,
    );
    assert(!agentProxy.isLocalMode, '应该是远程模式');

    print('\n  [远程发送消息] "你好，我是 Device-B"');
    final messageId = await agentProxy.sendMessage({
      'content': '你好，我是 Device-B',
      'role': 'user',
    });
    print('    消息ID: $messageId');

    // 等待消息处理完成
    await _waitForMessageComplete(deviceB, messageId);
    print('    ✓ 消息处理完成');

    // 验证消息已添加到列表
    final messages = await agentProxy.getSessionMessages();

    // 检查最后一条消息是否是刚发送的
    final lastMessage = messages.last;
    final content = lastMessage['content'] as String? ?? '';
    assert(content.contains('Device-B'), '最后一条消息应该包含 Device-B');
    print('  ✓ 远程消息已成功添加到消息列表');
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
      // 尝试取消订阅
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
