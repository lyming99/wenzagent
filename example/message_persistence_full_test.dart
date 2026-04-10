import 'dart:io';

import 'package:wenzagent/wenzagent.dart';
import 'package:uuid/uuid.dart';

/// Agent 消息持久化完整测试
///
/// 测试场景：
/// 1. 用户消息持久化
/// 2. AI 回复消息持久化
/// 3. 消息清空功能
/// 4. 清空后重新发送消息的持久化
/// 5. 跨 Agent 实例的消息一致性
///
/// 预期结果：
/// - 用户消息正确持久化
/// - AI 回复消息正确持久化
/// - 清空消息后数据库和内存都清空
/// - 清空后重新发送消息可以正确持久化
/// - 跨实例消息内容一致

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║           Agent 消息持久化完整测试                         ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = MessagePersistenceFullTest();
  await test.run();
}

class MessagePersistenceFullTest {
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
      // ===== 阶段 1: 初始化 =====
      print('\n[阶段 1] 初始化环境...');
      await _initialize();

      // ===== 阶段 2: 创建设备和员工 =====
      print('\n[阶段 2] 创建测试环境...');
      await _setupTestEnvironment();

      // ===== 阶段 3: 测试用户消息持久化 =====
      print('\n[阶段 3] 测试用户消息持久化...');
      await _testUserMessagePersistence();

      // ===== 阶段 4: 测试 AI 回复持久化（如果有 API Key）=====
      if (_hasApiKey) {
        print('\n[阶段 4] 测试 AI 回复持久化...');
        await _testAIResponsePersistence();
      } else {
        print('\n[阶段 4] 跳过 AI 回复测试（未配置 OPENAI_API_KEY）');
        print('  提示: 设置环境变量 OPENAI_API_KEY 可启用完整测试');
      }

      // ===== 阶段 5: 测试消息清空功能 =====
      print('\n[阶段 5] 测试消息清空功能...');
      await _testClearMessages();

      // ===== 阶段 6: 测试清空后重新发送 =====
      print('\n[阶段 6] 测试清空后重新发送消息...');
      await _testAfterClearResend();

      // ===== 阶段 7: 测试跨实例消息一致性 =====
      print('\n[阶段 7] 测试跨实例消息一致性...');
      await _testCrossInstanceConsistency();

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

  /// 初始化
  Future<void> _initialize() async {
    final tempDir = await Directory.systemTemp.createTemp('wenzagent_msg_persistence_test_');
    tempDirPath = tempDir.path;
    print('  临时目录: $tempDirPath');

    await DatabaseManager.instance.initialize(storagePath: tempDirPath);
    print('  ✓ 数据库初始化完成');
  }

  /// 创建测试环境
  Future<void> _setupTestEnvironment() async {
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
      description: '消息持久化完整测试员工',
      systemPrompt: '你是一个测试助手，请简短回复。',
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

  /// 测试用户消息持久化
  Future<void> _testUserMessagePersistence() async {
    print('  获取 AgentProxy...');
    final agentProxy = await device.getOrCreateAgentProxy(employeeId: employeeId);

    // 发送 3 条用户消息
    final userMessages = [
      '用户消息 1: 你好',
      '用户消息 2: 今天天气如何？',
      '用户消息 3: 测试持久化功能',
    ];

    print('  发送 ${userMessages.length} 条用户消息...');
    for (var i = 0; i < userMessages.length; i++) {
      final messageId = await agentProxy.sendMessage(
        MessageInput(content: userMessages[i], role: 'user'),
      );
      print('  ✓ 消息 ${i + 1} 已发送 (ID: $messageId)');

      // 等待消息处理完成，即使 AI 回复失败，用户消息也应该被持久化
      await Future.delayed(const Duration(seconds: 2));
    }

    // 验证内存中的消息
    final messagesInMemory = await agentProxy.getSessionMessages();
    print('  内存中消息数量: ${messagesInMemory.length}');

    // 验证数据库中的消息
    await _verifyDbMessages(expectedCount: userMessages.length);

    // 验证消息内容
    print('  验证消息内容...');
    for (var i = 0; i < userMessages.length; i++) {
      if (i < messagesInMemory.length) {
        final msg = messagesInMemory[i];
        final content = msg.content ?? '';
        if (content.contains(userMessages[i])) {
          print('    ✓ 消息 ${i + 1} 内容正确: ${content}');
        } else {
          print('    ❌ 消息 ${i + 1} 内容不匹配');
          print('       期望: ${userMessages[i]}');
          print('       实际: $content');
        }
      }
    }

    print('  ✓ 用户消息持久化测试通过');
  }

  /// 测试 AI 回复持久化
  Future<void> _testAIResponsePersistence() async {
    print('  获取 AgentProxy...');
    final agentProxy = await device.getOrCreateAgentProxy(employeeId: employeeId);

    // 发送一条消息等待 AI 回复
    print('  发送消息并等待 AI 回复...');
    final messageId = await agentProxy.sendMessage(
      MessageInput(content: '请回复 "AI 回复测试成功"', role: 'user'),
    );
    print('  消息已发送 (ID: $messageId)');

    // 等待 AI 处理完成
    await Future.delayed(const Duration(seconds: 5));

    // 获取消息列表
    final messages = await agentProxy.getSessionMessages();
    print('  当前消息数量: ${messages.length}');

    // 查找 AI 回复
    final aiResponses = messages.where((msg) => msg.role == 'assistant').toList();
    print('  AI 回复数量: ${aiResponses.length}');

    if (aiResponses.isEmpty) {
      print('  ⚠️  未找到 AI 回复，可能 API 调用失败');
      return;
    }

    // 验证数据库中的消息
    await _verifyDbMessages(expectedCount: messages.length);

    // 打印 AI 回复
    for (var i = 0; i < aiResponses.length; i++) {
      final response = aiResponses[i];
      final content = response.content ?? '';
      final preview = content.length > 50 ? '${content.substring(0, 50)}...' : content;
      print('    AI 回复 ${i + 1}: $preview');
    }

    print('  ✓ AI 回复持久化测试通过');
  }

  /// 测试消息清空功能
  Future<void> _testClearMessages() async {
    print('  获取当前消息数量...');
    final agentProxy = await device.getOrCreateAgentProxy(employeeId: employeeId);
    final messagesBefore = await agentProxy.getSessionMessages();
    print('  清空前消息数量: ${messagesBefore.length}');

    if (messagesBefore.isEmpty) {
      print('  ⚠️  没有消息可清空，跳过清空测试');
      return;
    }

    // 调用清空消息
    print('  调用 clearCurrentSession...');
    await agentProxy.clearCurrentSession();
    await Future.delayed(const Duration(milliseconds: 200));

    // 验证内存中的消息
    final messagesAfterMemory = await agentProxy.getSessionMessages();
    print('  清空后内存消息数量: ${messagesAfterMemory.length}');

    if (messagesAfterMemory.isNotEmpty) {
      print('  ❌ 错误: 内存中的消息未清空');
      throw StateError('内存消息清空失败');
    }

    // 验证数据库中的消息
    final messageStore = MessageStore();
    final dbMessageCount = await messageStore.count(deviceId, employeeId);

    print('  清空后数据库消息数量: $dbMessageCount');

    if (dbMessageCount > 0) {
      print('  ❌ 错误: 数据库中的消息未清空');
      throw StateError('数据库消息清空失败');
    }

    print('  ✓ 消息清空功能测试通过');
  }

  /// 测试清空后重新发送
  Future<void> _testAfterClearResend() async {
    print('  发送新消息...');
    final agentProxy = await device.getOrCreateAgentProxy(employeeId: employeeId);

    final newMessage = '清空后的第一条消息';
    final messageId = await agentProxy.sendMessage(
      MessageInput(content: newMessage, role: 'user'),
    );
    print('  消息已发送 (ID: $messageId)');
    await Future.delayed(const Duration(milliseconds: 200));

    // 验证内存
    final messagesInMemory = await agentProxy.getSessionMessages();
    print('  内存消息数量: ${messagesInMemory.length}');

    if (messagesInMemory.length != 1) {
      print('  ❌ 错误: 内存消息数量不正确，期望 1，实际 ${messagesInMemory.length}');
      throw StateError('内存消息数量不正确');
    }

    // 验证消息内容
    final content = messagesInMemory[0].content ?? '';
    if (content != newMessage) {
      print('  ❌ 错误: 消息内容不匹配');
      print('     期望: $newMessage');
      print('     实际: $content');
      throw StateError('消息内容不匹配');
    }

    // 验证数据库
    await _verifyDbMessages(expectedCount: 1);

    print('  ✓ 消息内容: $content');
    print('  ✓ 清空后重新发送测试通过');
  }

  /// 测试跨实例消息一致性
  Future<void> _testCrossInstanceConsistency() async {
    print('  销毁当前 Agent 实例...');
    await device.destroyAgentProxy(employeeId);
    await Future.delayed(const Duration(milliseconds: 100));

    print('  重新创建 Agent 实例...');
    final agentProxy = await device.getOrCreateAgentProxy(employeeId: employeeId);

    print('  获取消息...');
    final messages = await agentProxy.getSessionMessages();
    print('  新实例中消息数量: ${messages.length}');

    if (messages.isEmpty) {
      print('  ❌ 错误: 新实例未能加载消息');
      throw StateError('新实例未能加载消息');
    }

    // 验证消息内容
    final expectedMessage = '清空后的第一条消息';
    final content = messages[0].content ?? '';

    if (content != expectedMessage) {
      print('  ❌ 错误: 消息内容不一致');
      print('     期望: $expectedMessage');
      print('     实际: $content');
      throw StateError('消息内容不一致');
    }

    print('  ✓ 消息内容: $content');
    print('  ✓ 跨实例消息一致性测试通过');
  }

  /// 验证数据库中的消息数量
  Future<void> _verifyDbMessages({required int expectedCount}) async {
    final messageStore = MessageStore();
    final actualCount = await messageStore.count(deviceId, employeeId);

    print('  数据库消息数量: $actualCount (期望: $expectedCount)');

    if (actualCount != expectedCount) {
      print('  ❌ 错误: 数据库消息数量不正确');
      throw StateError('数据库消息数量不正确，期望 $expectedCount，实际 $actualCount');
    }

    // 打印所有消息
    final messages = await messageStore.getMessages(deviceId, employeeId);
    if (messages.isNotEmpty) {
      print('  数据库消息 UUIDs: ${messages.map((m) => m.uuid).join(", ")}');
    }
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
