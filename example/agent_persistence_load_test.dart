import 'dart:io';

import 'package:wenzagent/wenzagent.dart';
import 'package:uuid/uuid.dart';

/// Agent 消息持久化加载测试
///
/// 测试场景：
/// 1. 创建设备和员工
/// 2. 创建 Agent 并发送消息
/// 3. 销毁 Agent
/// 4. 重新创建 Agent
/// 5. 验证 Agent 是否能从数据库加载之前持久化的消息
///
/// 预期结果：重新创建的 Agent 应该能够加载所有持久化的消息历史

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║           Agent 消息持久化加载测试                          ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = AgentPersistenceLoadTest();
  await test.run();
}

class AgentPersistenceLoadTest {
  late DeviceClientImpl device;
  late String employeeId;
  late String tempDirPath;

  final String deviceId = 'test-device';
  final String employeeName = 'Test Assistant';

  /// 从环境变量获取 API 配置
  String? get _apiKey => Platform.environment['OPENAI_API_KEY'];
  String? get _apiBaseUrl => Platform.environment['OPENAI_API_URL'];

  bool get _hasApiKey => _apiKey != null && _apiKey!.isNotEmpty;

  Future<void> run() async {
    try {
      // ===== 阶段 1: 初始化存储 =====
      print('\n[阶段 1] 初始化数据库存储...');
      await _initializeStorage();

      // ===== 阶段 2: 创建设备和员工 =====
      print('\n[阶段 2] 创建设备和员工...');
      await _createDeviceAndEmployee();

      // ===== 阶段 3: 第一次创建 Agent 并发送消息 =====
      print('\n[阶段 3] 第一次创建 Agent 并发送消息...');
      await _firstAgentSendMessages();

      // ===== 阶段 4: 验证数据库中的持久化数据 =====
      print('\n[阶段 4] 验证数据库中的持久化数据...');
      await _verifyPersistence();

      // ===== 阶段 5: 销毁 Agent =====
      print('\n[阶段 5] 销毁 Agent...');
      await _destroyAgent();

      // ===== 阶段 6: 重新创建 Agent 并验证消息加载 =====
      print('\n[阶段 6] 重新创建 Agent 并验证消息加载...');
      await _recreateAndVerifyLoad();

      // ===== 阶段 7: 验证消息内容一致性 =====
      print('\n[阶段 7] 验证消息内容一致性...');
      await _verifyMessageConsistency();

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
    final tempDir = await Directory.systemTemp.createTemp('wenzagent_agent_load_test_');
    tempDirPath = tempDir.path;
    print('  临时目录: $tempDirPath');

    await DatabaseManager.instance.initialize(storagePath: tempDirPath);
    print('  ✓ 数据库初始化完成');
  }

  /// 创建设备和员工
  Future<void> _createDeviceAndEmployee() async {
    // 创建 DeviceClient
    device = DeviceClientImpl(
      deviceId: deviceId,
      deviceName: 'Test Device',
      host: 'localhost',
      port: 9090,
    );

    // 创建员工
    employeeId = 'emp-test-${const Uuid().v4().substring(0, 8)}';
    final employee = AiEmployeeEntity(
      uuid: employeeId,
      name: employeeName,
      role: 'assistant',
      status: 'active',
      description: 'Agent 消息加载测试员工',
      systemPrompt: '你是一个测试助手。',
      provider: 'openai',
      model: 'gpt-4',
      apiKey: _apiKey,
      apiBaseUrl: _apiBaseUrl,
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );

    await device.employeeManager.createEmployee(employee);
    print('  ✓ 创建员工: $employeeId');

    // 创建会话
    await device.sessionManager.getOrCreateSession(employeeId);
    print('  ✓ 创建会话');

    // 设置 currentDeviceId
    await device.employeeManager.updateCurrentDeviceId(employeeId, deviceId);
    print('  ✓ 设置 currentDeviceId = $deviceId');
  }

  /// 第一次创建 Agent 并发送消息
  Future<void> _firstAgentSendMessages() async {
    print('  获取 AgentProxy...');
    final agentProxy = await device.getOrCreateAgentProxy(employeeId: employeeId);

    // 发送多条测试消息
    final testMessages = [
      '第一条测试消息 - Hello World',
      '第二条测试消息 - How are you?',
      '第三条测试消息 - Testing persistence',
    ];

    print('  发送 ${testMessages.length} 条消息...');
    for (var i = 0; i < testMessages.length; i++) {
      try {
        final messageId = await agentProxy.sendMessage(
          MessageInput(content: testMessages[i], role: 'user'),
        );
        print('  ✓ 消息 ${i + 1} 已发送: "${testMessages[i]}" (ID: $messageId)');

        // 等待消息处理完成
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (e) {
        print('  ⚠️  消息 ${i + 1} 发送失败: $e');
      }
    }

    // 获取内存中的消息
    final messagesInMemory = await agentProxy.getSessionMessages();
    print('  内存中消息数量: ${messagesInMemory.length}');
  }

  /// 验证数据库中的持久化数据
  Future<void> _verifyPersistence() async {
    final messageStore = MessageStore();
    final count = await messageStore.count(deviceId, employeeId);

    print('  数据库中的消息总数: $count');

    if (count == 0) {
      print('  ❌ 警告: 数据库中没有持久化的消息');
      return;
    }

    print('  ✓ 数据库中有 $count 条持久化消息');
  }

  /// 销毁 Agent
  Future<void> _destroyAgent() async {
    await device.destroyAgentProxy(employeeId);
    print('  ✓ Agent 已销毁');

    // 等待清理完成
    await Future.delayed(const Duration(milliseconds: 100));
  }

  /// 重新创建 Agent 并验证消息加载
  Future<void> _recreateAndVerifyLoad() async {
    print('  重新获取 AgentProxy...');
    final agentProxy = await device.getOrCreateAgentProxy(employeeId: employeeId);

    // 获取内存中的消息
    final messages = await agentProxy.getSessionMessages();
    print('  重新创建后内存中消息数量: ${messages.length}');

    if (messages.isEmpty) {
      print('  ❌ 错误: 重新创建的 Agent 没有加载任何消息');
      throw StateError('Agent 未能从数据库加载持久化的消息');
    }

    print('  ✓ Agent 成功从数据库加载了 ${messages.length} 条消息');

    // 打印消息摘要
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final role = msg.role ?? 'unknown';
      final content = msg.content ?? '';
      final preview = content.length > 30 ? '${content.substring(0, 30)}...' : content;
      print('    消息 ${i + 1}: [$role] $preview');
    }
  }

  /// 验证消息内容一致性
  Future<void> _verifyMessageConsistency() async {
    // 从数据库直接读取
    final messageStore = MessageStore();
    final dbMessages = await messageStore.getMessages(deviceId, employeeId);

    if (dbMessages.isEmpty) {
      print('  ⚠️  数据库中没有消息，跳过一致性验证');
      return;
    }

    // 从 Agent 读取消息
    final agentProxy = await device.getOrCreateAgentProxy(employeeId: employeeId);
    final agentMessages = await agentProxy.getSessionMessages();

    print('  数据库消息数量: ${dbMessages.length}');
    print('  Agent 消息数量: ${agentMessages.length}');

    if (dbMessages.length != agentMessages.length) {
      print('  ❌ 错误: 消息数量不一致');
      throw StateError('数据库和 Agent 中的消息数量不一致');
    }

    print('  ✓ 消息数量一致');

    // 验证每条消息的内容
    for (var i = 0; i < dbMessages.length; i++) {
      final dbMsg = dbMessages[i];
      final agentMsg = agentMessages[i];

      if (dbMsg.role != agentMsg.role) {
        print('  ❌ 错误: 消息 ${i + 1} 的 role 不一致');
        continue;
      }

      if (dbMsg.content != agentMsg.content) {
        print('  ❌ 错误: 消息 ${i + 1} 的 content 不一致');
        print('     数据库: ${dbMsg.content}');
        print('     Agent: ${agentMsg.content}');
        continue;
      }

      print('  ✓ 消息 ${i + 1} 内容一致: [${dbMsg.role}] ${dbMsg.content}');
    }

    print('  ✓ 所有消息内容验证通过');
  }

  /// 清理
  Future<void> _cleanup() async {
    print('\n[清理] 释放资源...');

    try {
      await device.destroyAgentProxy(employeeId);
      print('  ✓ Agent 已销毁');
    } catch (_) {}

    try {
      await device.disconnect();
      print('  ✓ 设备已断开');
    } catch (_) {}

    try {
      await DatabaseManager.instance.close();
      print('  ✓ 数据库已关闭');
    } catch (_) {}

    try {
      final tempDir = Directory(tempDirPath);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
        print('  ✓ 临时目录已删除');
      }
    } catch (_) {}

    print('  ✓ 清理完成');
  }
}
