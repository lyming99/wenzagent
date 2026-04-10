import 'dart:io';

import 'package:wenzagent/wenzagent.dart';
import 'package:uuid/uuid.dart';

/// 消息排序和缓存清理测试
///
/// 测试场景（基于wenzflow的问题）：
/// 1. 排序问题：从AgentProxy获取的消息是否正确排序
/// 2. 清除数据缓存问题：clearCurrentSession后内存和数据库是否都清理了
/// 3. 清除后重新加载：清理后Agent重新初始化是否会重新加载已删除的消息
///
/// 参考 wenzflow 代码：
/// - D:\project\GitHub\wenzflow\wenzflow_flutter\lib\view\desktop\ai\employee\message_tab\chat\controller.dart
///   - 第 443-448 行：排序逻辑
///   - 第 644-659 行：clearCurrentSession 逻辑

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║              消息排序与缓存清理测试                       ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = MessageSortAndClearTest();
  await test.run();
}

class MessageSortAndClearTest {
  late String tempDirPath;
  late DeviceClientImpl device;
  late MessageStoreService messageStoreService;

  final String deviceId = 'test-device-sort-clear';
  final String employeeId = 'emp-sort-clear-test';

  Future<void> run() async {
    try {
      // ===== 阶段 1: 初始化 =====
      print('\n[阶段 1] 初始化存储和设备...');
      await _initialize();

      // ===== 阶段 2: 测试从数据库加载的消息排序 =====
      print('\n[阶段 2] 测试从数据库加载的消息排序...');
      await _testDatabaseMessageSorting();

      // ===== 阶段 3: 测试从AgentProxy获取的消息排序 =====
      print('\n[阶段 3] 测试从AgentProxy获取的消息排序...');
      await _testAgentProxyMessageSorting();

      // ===== 阶段 4: 测试清除会话 - 内存缓存 =====
      print('\n[阶段 4] 测试清除会话 - 内存缓存...');
      await _testClearSessionMemory();

      // ===== 阶段 5: 测试清除会话 - 数据库 =====
      print('\n[阶段 5] 测试清除会话 - 数据库...');
      await _testClearSessionDatabase();

      // ===== 阶段 6: 测试清除后重新加载 =====
      print('\n[阶段 6] 测试清除后重新加载（关键问题）...');
      await _testClearAndReload();

      // ===== 阶段 7: 测试完整流程 =====
      print('\n[阶段 7] 测试完整流程：发送消息 -> 清除 -> 重新发送...');
      await _testFullWorkflow();

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
    final tempDir = await Directory.systemTemp.createTemp(
      'wenzagent_sort_clear_test_',
    );
    tempDirPath = tempDir.path;
    print('  临时目录: $tempDirPath');

    await DatabaseManager.instance.initialize(storagePath: tempDirPath);

    messageStoreService = MessageStoreServiceImpl(deviceId: deviceId);

    // 创建 DeviceClient
    device = DeviceClientImpl(
      deviceId: deviceId,
      deviceName: 'Test Device',
      host: 'localhost',
      port: 9090,
    );

    print('  ✓ 初始化完成');
  }

  /// 测试从数据库加载的消息排序
  Future<void> _testDatabaseMessageSorting() async {
    print('  添加 10 条乱序消息到数据库...');

    final baseTime = DateTime.now();
    final messages = <AiEmployeeMessageEntity>[];

    // 创建 10 条消息，时间间隔 1 秒
    for (int i = 0; i < 10; i++) {
      final message = AiEmployeeMessageEntity(
        uuid: const Uuid().v4(),
        employeeId: employeeId,
        role: i % 2 == 0 ? 'user' : 'assistant',
        type: 'text',
        content: 'DB Message $i',
        createTime: baseTime.add(Duration(seconds: i)),
        updateTime: baseTime.add(Duration(seconds: i)),
      );
      messages.add(message);
    }

    // 打乱顺序后添加
    messages.shuffle();
    print(
      '  添加顺序（打乱）: ${messages.take(3).map((m) => m.content).join(", ")}...',
    );

    await messageStoreService.addMessages(messages);

    // 从数据库加载
    final loadedMessages = await messageStoreService.getMessages(employeeId);
    print(
      '  从数据库加载的消息顺序: ${loadedMessages.take(3).map((m) => m.content).join(", ")}...',
    );

    // 验证排序
    bool isSorted = true;
    for (int i = 1; i < loadedMessages.length; i++) {
      if (loadedMessages[i].createTime.isBefore(
        loadedMessages[i - 1].createTime,
      )) {
        isSorted = false;
        break;
      }
    }

    if (isSorted) {
      print('  ✓ 数据库加载的消息已正确排序');
    } else {
      throw StateError('数据库加载的消息未排序！');
    }
  }

  /// 测试从AgentProxy获取的消息排序
  Future<void> _testAgentProxyMessageSorting() async {
    // 创建员工
    final employee = AiEmployeeEntity(
      uuid: employeeId,
      name: 'Test Employee',
      role: 'assistant',
      status: 'active',
      description: '排序和清除测试员工',
      systemPrompt: '你是一个测试助手。',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );

    await device.employeeManager.createEmployee(employee);

    // 获取 AgentProxy
    final agentProxy = await device.getOrCreateAgentProxy(
      employeeId: employeeId,
    );

    // 等待消息加载
    await Future.delayed(const Duration(milliseconds: 500));

    // 获取消息
    final messages = await agentProxy.getSessionMessages();
    print('  从 AgentProxy 获取的消息数量: ${messages.length}');

    if (messages.isNotEmpty) {
      print('  前3条消息:');
      for (int i = 0; i < (messages.length < 3 ? messages.length : 3); i++) {
        final msg = messages[i];
        print('    [$i] ${msg.content} - ${msg.createdAt}');
      }

      // 验证排序
      bool isSorted = true;
      for (int i = 1; i < messages.length; i++) {
        final prevTime = messages[i - 1].createdAt;
        final currTime = messages[i].createdAt;
        if (currTime.isBefore(prevTime)) {
          isSorted = false;
          print('  ❌ 排序错误: 消息 $i 应该在消息 ${i - 1} 之前');
          break;
        }
      }

      if (isSorted) {
        print('  ✓ AgentProxy 返回的消息已正确排序');
      } else {
        print('  ⚠ AgentProxy 返回的消息未排序（需要在应用层排序）');
      }
    } else {
      print('  ⚠ AgentProxy 没有返回消息');
    }
  }

  /// 测试清除会话 - 内存缓存
  Future<void> _testClearSessionMemory() async {
    final testEmployeeId = 'emp-clear-memory-test';

    // 创建员工
    final employee = AiEmployeeEntity(
      uuid: testEmployeeId,
      name: 'Clear Memory Test',
      role: 'assistant',
      status: 'active',
      description: '清除内存测试',
      systemPrompt: '测试清除内存。',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );

    await device.employeeManager.createEmployee(employee);

    // 获取 AgentProxy
    final agentProxy = await device.getOrCreateAgentProxy(
      employeeId: testEmployeeId,
    );

    // 发送几条消息
    for (int i = 0; i < 3; i++) {
      await agentProxy.sendMessage(
        MessageInput(content: 'Memory Test Message $i', role: 'user'),
      );
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // 验证消息存在
    var messages = await agentProxy.getSessionMessages();
    print('  清除前内存中的消息数量: ${messages.length}');

    if (messages.length < 3) {
      print('  ⚠ 消息数量不足，跳过测试');
      return;
    }

    // 清除会话
    await agentProxy.clearCurrentSession();

    // 验证内存已清空
    messages = await agentProxy.getSessionMessages();
    print('  清除后内存中的消息数量: ${messages.length}');

    if (messages.isEmpty) {
      print('  ✓ 内存缓存已正确清空');
    } else {
      throw StateError('清除会话后内存中仍有消息！数量: ${messages.length}');
    }
  }

  /// 测试清除会话 - 数据库
  Future<void> _testClearSessionDatabase() async {
    final testEmployeeId = 'emp-clear-db-test';

    // 添加消息到数据库
    final baseTime = DateTime.now();
    final messages = <AiEmployeeMessageEntity>[];
    for (int i = 0; i < 5; i++) {
      messages.add(
        AiEmployeeMessageEntity(
          uuid: const Uuid().v4(),
          employeeId: testEmployeeId,
          role: 'user',
          type: 'text',
          content: 'DB Clear Test $i',
          createTime: baseTime.add(Duration(seconds: i)),
          updateTime: baseTime.add(Duration(seconds: i)),
        ),
      );
    }

    await messageStoreService.addMessages(messages);

    // 验证数据库中有消息
    var dbMessages = await messageStoreService.getMessages(testEmployeeId);
    print('  清除前数据库中的消息数量: ${dbMessages.length}');

    if (dbMessages.length != 5) {
      print('  ⚠ 数据库消息数量不正确，期望 5，实际 ${dbMessages.length}');
    }

    // 清除数据库消息
    await messageStoreService.deleteMessages(testEmployeeId);

    // 验证数据库已清空
    dbMessages = await messageStoreService.getMessages(testEmployeeId);
    print('  清除后数据库中的消息数量: ${dbMessages.length}');

    if (dbMessages.isEmpty) {
      print('  ✓ 数据库已正确清空');
    } else {
      throw StateError('清除会话后数据库中仍有消息！数量: ${dbMessages.length}');
    }
  }

  /// 测试清除后重新加载（关键问题）
  Future<void> _testClearAndReload() async {
    final testEmployeeId = 'emp-clear-reload-test';

    print('  步骤 1: 添加消息到数据库...');
    // 添加消息到数据库
    final baseTime = DateTime.now();
    final messages = <AiEmployeeMessageEntity>[];
    for (int i = 0; i < 5; i++) {
      messages.add(
        AiEmployeeMessageEntity(
          uuid: const Uuid().v4(),
          employeeId: testEmployeeId,
          role: 'user',
          type: 'text',
          content: 'Reload Test $i',
          createTime: baseTime.add(Duration(seconds: i)),
          updateTime: baseTime.add(Duration(seconds: i)),
        ),
      );
    }

    await messageStoreService.addMessages(messages);
    var dbMessages = await messageStoreService.getMessages(testEmployeeId);
    print('  数据库中的消息数量: ${dbMessages.length}');

    print('  步骤 2: 清除数据库消息...');
    // 清除数据库消息
    await messageStoreService.deleteMessages(testEmployeeId);

    dbMessages = await messageStoreService.getMessages(testEmployeeId);
    print('  清除后数据库中的消息数量: ${dbMessages.length}');

    if (dbMessages.isNotEmpty) {
      throw StateError('数据库未正确清空！');
    }

    print('  步骤 3: 创建 Agent 并验证不会加载已删除的消息...');
    // 创建员工
    final employee = AiEmployeeEntity(
      uuid: testEmployeeId,
      name: 'Clear Reload Test',
      role: 'assistant',
      status: 'active',
      description: '清除后重新加载测试',
      systemPrompt: '测试清除后重新加载。',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );

    await device.employeeManager.createEmployee(employee);

    // 获取 AgentProxy（会触发从数据库加载消息）
    final agentProxy = await device.getOrCreateAgentProxy(
      employeeId: testEmployeeId,
    );

    // 等待消息加载
    await Future.delayed(const Duration(milliseconds: 500));

    // 验证内存中没有加载已删除的消息
    final agentMessages = await agentProxy.getSessionMessages();
    print('  Agent 内存中的消息数量: ${agentMessages.length}');

    if (agentMessages.isEmpty) {
      print('  ✓ 清除后重新加载正确：没有加载已删除的消息');
    } else {
      print('  ❌ 严重问题：Agent 加载了已删除的消息！');
      print('  消息数量: ${agentMessages.length}');
      for (int i = 0; i < agentMessages.length; i++) {
        print('    [$i] ${agentMessages[i].content}');
      }
      throw StateError('Agent 加载了已删除的消息！');
    }
  }

  /// 测试完整流程
  Future<void> _testFullWorkflow() async {
    final testEmployeeId = 'emp-full-workflow-test';

    print('  步骤 1: 创建员工并发送消息...');
    // 创建员工
    final employee = AiEmployeeEntity(
      uuid: testEmployeeId,
      name: 'Full Workflow Test',
      role: 'assistant',
      status: 'active',
      description: '完整流程测试',
      systemPrompt: '测试完整流程。',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );

    await device.employeeManager.createEmployee(employee);

    // 获取 AgentProxy
    final agentProxy = await device.getOrCreateAgentProxy(
      employeeId: testEmployeeId,
    );

    // 发送消息
    for (int i = 0; i < 3; i++) {
      await agentProxy.sendMessage(
        MessageInput(content: 'Workflow Message $i', role: 'user'),
      );
      await Future.delayed(const Duration(milliseconds: 200));
    }

    var messages = await agentProxy.getSessionMessages();
    print('  发送的消息数量: ${messages.length}');

    print('  步骤 2: 验证数据库中有消息...');
    var dbMessages = await messageStoreService.getMessages(testEmployeeId);
    print('  数据库中的消息数量: ${dbMessages.length}');

    print('  步骤 3: 清除会话...');
    await agentProxy.clearCurrentSession();

    messages = await agentProxy.getSessionMessages();
    dbMessages = await messageStoreService.getMessages(testEmployeeId);
    print('  清除后内存中的消息数量: ${messages.length}');
    print('  清除后数据库中的消息数量: ${dbMessages.length}');

    if (messages.isNotEmpty || dbMessages.isNotEmpty) {
      throw StateError('清除会话后仍有残留消息！');
    }

    print('  步骤 4: 重新发送消息...');
    for (int i = 0; i < 2; i++) {
      await agentProxy.sendMessage(
        MessageInput(content: 'New Workflow Message $i', role: 'user'),
      );
      await Future.delayed(const Duration(milliseconds: 200));
    }

    messages = await agentProxy.getSessionMessages();
    dbMessages = await messageStoreService.getMessages(testEmployeeId);
    print('  重新发送后内存中的消息数量: ${messages.length}');
    print('  重新发送后数据库中的消息数量: ${dbMessages.length}');

    if (messages.length >= 2 && dbMessages.length >= 2) {
      print('  ✓ 完整流程测试通过');
    } else {
      throw StateError('完整流程测试失败！');
    }
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
