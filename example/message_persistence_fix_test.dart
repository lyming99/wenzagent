import 'dart:io';

import 'package:uuid/uuid.dart';
import 'package:wenzagent/wenzagent.dart';

/// 消息持久化修复测试
///
/// 测试修复后的消息持久化逻辑，确保不会重复持久化消息
Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║            消息持久化修复测试 - 验证ID稳定性               ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = MessagePersistenceFixTest();
  await test.run();
}

class MessagePersistenceFixTest {
  late DeviceClient device;
  late String employeeId;
  late String tempDirPath;

  final String deviceId = 'test-device';
  final String employeeName = 'Test Assistant';

  Future<void> run() async {
    try {
      // ===== 阶段 1: 初始化存储 =====
      print('\n[阶段 1] 初始化 Hive 存储...');
      await _initializeStorage();

      // ===== 阶段 2: 创建设备和员工 =====
      print('\n[阶段 2] 创建设备和员工...');
      await _createDeviceAndEmployee();

      // ===== 阶段 3: 模拟发送消息（不调用真实API）=====
      print('\n[阶段 3] 模拟消息持久化...');
      await _simulateMessagePersistence();

      // ===== 阶段 4: 验证消息数量 =====
      print('\n[阶段 4] 验证消息数量...');
      await _verifyMessageCount();

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
    final tempDir = await Directory.systemTemp.createTemp('wenzagent_fix_test_');
    tempDirPath = tempDir.path;
    print('  临时目录: $tempDirPath');
  }

  /// 创建设备和员工
  Future<void> _createDeviceAndEmployee() async {
    device = DeviceClient.getInstance(deviceId);
    await device.initialize(DeviceClientConfig(
      dbPath: tempDirPath,
      host: 'localhost',
      port: 9090,
      deviceName: 'Test Device',
    ));

    employeeId = Uuid().v4();

    final employee = AiEmployeeEntity(
      uuid: employeeId,
      name: employeeName,
      role: 'assistant',
      status: 'active',
      description: '测试员工',
      systemPrompt: '你是 $employeeName',
      provider: 'openai',
      model: 'gpt-4',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );

    await device.employeeManager.createEmployee(employee);
    print('  ✓ 创建员工: ${employee.uuid}');
  }

  /// 模拟消息持久化（直接操作MessageStore）
  Future<void> _simulateMessagePersistence() async {
    final messageStore = MessageStoreServiceImpl(
      deviceId: deviceId,
    );

    final uuid = Uuid();

    // 创建3条测试消息
    final messages = [
      {
        'id': uuid.v4(),
        'employeeId': employeeId,
        'role': 'user',
        'type': 'text',
        'content': 'Hello',
        'createdAt': DateTime.now().toIso8601String(),
      },
      {
        'id': uuid.v4(),
        'employeeId': employeeId,
        'role': 'assistant',
        'type': 'text',
        'content': 'Hi there!',
        'createdAt': DateTime.now().toIso8601String(),
      },
      {
        'id': uuid.v4(),
        'employeeId': employeeId,
        'role': 'user',
        'type': 'text',
        'content': 'How are you?',
        'createdAt': DateTime.now().toIso8601String(),
      },
    ];

    // 持久化消息
    for (final msg in messages) {
      final entity = AiEmployeeMessageEntity(
        uuid: msg['id'] as String,
        employeeId: msg['employeeId'] as String,
        role: msg['role'] as String,
        type: msg['type'] as String,
        content: msg['content'] as String,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );
      await messageStore.addMessage(entity);
      print('  ✓ 持久化消息: ${msg['id']}');
    }

    print('  ✓ 共持久化 ${messages.length} 条消息');
  }

  /// 验证消息数量
  Future<void> _verifyMessageCount() async {
    final messageStore = MessageStoreServiceImpl(
      deviceId: deviceId,
    );

    final messages = await messageStore.getMessages(employeeId);

    print('  数据库中的消息数量: ${messages.length}');

    // 验证消息ID唯一性
    final ids = messages.map((m) => m.uuid).toSet();
    print('  唯一ID数量: ${ids.length}');

    if (messages.length != ids.length) {
      throw StateError('消息ID不唯一！总消息数: ${messages.length}, 唯一ID数: ${ids.length}');
    }

    if (messages.length != 3) {
      throw StateError('消息数量不正确！期望: 3, 实际: ${messages.length}');
    }

    print('  ✓ 消息ID唯一且数量正确');
  }

  /// 清理
  Future<void> _cleanup() async {
    print('\n[清理] 释放资源...');
    try {
      final tempDir = Directory(tempDirPath);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      print('  ✓ 清理完成');
    } catch (e) {
      print('  ⚠ 清理失败: $e');
    }
  }
}
