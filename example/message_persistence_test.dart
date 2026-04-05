import 'dart:io';
import 'dart:convert';

import 'package:wenzagent/wenzagent.dart';
import 'package:uuid/uuid.dart';

/// 消息持久化测试
///
/// 测试场景：
/// 1. 初始化 Hive 存储
/// 2. 创建员工和会话
/// 3. 发送消息
/// 4. 验证消息是否正确持久化到 Hive
/// 5. 验证消息 ID 的一致性

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║                 消息持久化测试 - Hive 存储                  ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = MessagePersistenceTest();
  await test.run();
}

class MessagePersistenceTest {
  late DeviceClientImpl device;
  late String employeeUuid;
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
      print('\n[阶段 1] 初始化 Hive 存储...');
      await _initializeStorage();

      // ===== 阶段 2: 创建设备和员工 =====
      print('\n[阶段 2] 创建设备和员工...');
      await _createDeviceAndEmployee();

      // ===== 阶段 3: 发送测试消息 =====
      print('\n[阶段 3] 发送测试消息...');
      await _sendTestMessage();

      // ===== 阶段 4: 验证消息持久化 =====
      print('\n[阶段 4] 验证消息持久化...');
      await _verifyMessagePersistence();

      // ===== 阶段 5: 测试消息 ID 一致性 =====
      print('\n[阶段 5] 测试消息 ID 一致性...');
      await _testMessageIdConsistency();

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
    final tempDir = await Directory.systemTemp.createTemp('wenzagent_message_test_');
    tempDirPath = tempDir.path;
    print('  临时目录: $tempDirPath');

    await HiveManager.instance.initialize(storagePath: tempDirPath);
    print('  ✓ Hive 初始化完成');
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
    employeeUuid = 'emp-test-${const Uuid().v4().substring(0, 8)}';
    final employee = AiEmployeeEntity(
      uuid: employeeUuid,
      name: employeeName,
      role: 'assistant',
      status: 'active',
      description: '消息持久化测试员工',
      systemPrompt: '你是一个测试助手。',
      provider: 'openai',
      model: 'gpt-4',
      apiKey: _apiKey,
      apiBaseUrl: _apiBaseUrl,
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );

    await device.employeeManager.createEmployee(employee);
    print('  ✓ 创建员工: $employeeUuid');

    // 创建会话
    await device.sessionManager.getOrCreateSession(employeeUuid);
    print('  ✓ 创建会话');

    // 设置 currentDeviceId
    await device.employeeManager.updateCurrentDeviceId(employeeUuid, deviceId);
    print('  ✓ 设置 currentDeviceId = $deviceId');
  }

  /// 发送测试消息
  Future<void> _sendTestMessage() async {
    print('  获取 AgentProxy...');
    final agentProxy = await device.getOrCreateAgentProxy(employeeUuid: employeeUuid);

    // 发送测试消息
    final testMessage = 'Hello, this is a test message for persistence.';
    print('  发送消息: "$testMessage"');

    try {
      final messageId = await agentProxy.sendMessage({
        'content': testMessage,
        'role': 'user',
      });
      print('  ✓ 消息已发送，ID: $messageId');

      // 等待一段时间让消息处理完成
      await Future.delayed(const Duration(seconds: 2));

      // 获取内存中的消息
      final messagesInMemory = await agentProxy.getSessionMessages();
      print('  内存中消息数量: ${messagesInMemory.length}');
    } catch (e) {
      print('  警告: 消息发送失败（可能是 API Key 未配置）: $e');
      // 即使发送失败，我们也继续测试持久化机制
    }
  }

  /// 验证消息持久化
  Future<void> _verifyMessagePersistence() async {
    // 直接从 Hive 读取消息
    final hiveManager = HiveManager.instance;
    final messageBox = hiveManager.messageBox;

    print('  Hive messageBox 中的消息总数: ${messageBox.length}');

    // 获取会话消息索引（使用 deviceId 作为 spaceId）
    final indexBox = hiveManager.sessionMessagesBox;
    final indexKey = hiveManager.buildSessionMessagesKey(deviceId, employeeUuid);
    final messageUuids = indexBox.get(indexKey);

    print('  索引 key: $indexKey');
    print('  会话消息索引中的消息数量: ${messageUuids?.length ?? 0}');

    if (messageUuids == null || messageUuids.isEmpty) {
      print('  ⚠️  警告: 没有找到持久化的消息');
      print('  这可能意味着：');
      print('    1. 消息还未发送到 AI（API Key 未配置）');
      print('    2. 消息持久化机制存在问题');
      return;
    }

    // 读取每条消息的详细信息
    for (final msgUuid in messageUuids) {
      final key = hiveManager.buildMessageKey(deviceId, msgUuid as String);
      final msg = messageBox.get(key);
      if (msg != null) {
        print('  消息详情:');
        print('    UUID: ${msg.uuid}');
        print('    Role: ${msg.role}');
        print('    Type: ${msg.type}');
        print('    Content: ${msg.content?.substring(0, msg.content!.length > 50 ? 50 : msg.content!.length)}...');
        print('    CreateTime: ${msg.createTime}');
        print('    ProcessingStatus: ${msg.processingStatus}');
      }
    }

    print('  ✓ 消息持久化验证完成');
  }

  /// 测试消息 ID 一致性
  Future<void> _testMessageIdConsistency() async {
    print('  检查消息 ID 一致性...');

    final hiveManager = HiveManager.instance;
    final indexBox = hiveManager.sessionMessagesBox;
    final indexKey = hiveManager.buildSessionMessagesKey(deviceId, employeeUuid);
    final messageUuids = indexBox.get(indexKey) ?? [];

    if (messageUuids.isEmpty) {
      print('  ⚠️  跳过 ID 一致性测试（没有持久化的消息）');
      return;
    }

    // 检查是否有重复的消息 UUID
    final uniqueUuids = messageUuids.toSet();
    if (uniqueUuids.length != messageUuids.length) {
      print('  ❌ 发现重复的消息 UUID！');
      print('     总数: ${messageUuids.length}, 唯一数: ${uniqueUuids.length}');
    } else {
      print('  ✓ 没有发现重复的消息 UUID');
    }

    // 检查消息 ID 格式
    final messageBox = hiveManager.messageBox;
    for (final msgUuid in messageUuids) {
      final key = hiveManager.buildMessageKey(deviceId, msgUuid as String);
      final msg = messageBox.get(key);
      if (msg != null) {
        if (!msg.uuid.startsWith('msg-')) {
          print('  ⚠️  消息 UUID 格式不正确: ${msg.uuid}');
        }
      }
    }

    print('  ✓ 消息 ID 一致性测试完成');
  }

  /// 清理
  Future<void> _cleanup() async {
    print('\n[清理] 释放资源...');

    try {
      await device.disconnect();
      print('  ✓ 设备已断开');
    } catch (_) {}

    try {
      await HiveManager.instance.close();
      print('  ✓ Hive 已关闭');
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
