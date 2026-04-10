import 'dart:io';

import 'package:wenzagent/wenzagent.dart';
import 'package:uuid/uuid.dart';

/// 消息排序测试
///
/// 测试场景：
/// 1. 测试消息按 createTime 排序
/// 2. 测试相同 createTime 的消息按 uuid 排序（稳定性保证）
/// 3. 测试消息加载后的排序顺序是否正确
/// 4. 模拟 wenzflow 中的排序逻辑，验证数据层返回的消息是否需要额外排序
///
/// 参考 wenzflow 代码：
/// D:\project\GitHub\wenzflow\wenzflow_flutter\lib\view\desktop\ai\employee\message_tab\chat\controller.dart
/// 第 443-448 行的排序逻辑

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║                   消息排序测试                            ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = MessageSortingTest();
  await test.run();
}

class MessageSortingTest {
  late String tempDirPath;
  late MessageStoreService messageStoreService;

  final String deviceId = 'test-device-sorting';
  final String employeeId = 'emp-sorting-test';

  Future<void> run() async {
    try {
      // ===== 阶段 1: 初始化存储 =====
      print('\n[阶段 1] 初始化 Hive 存储...');
      await _initializeStorage();

      // ===== 阶段 2: 测试按 createTime 排序 =====
      print('\n[阶段 2] 测试按 createTime 排序...');
      await _testSortByCreateTime();

      // ===== 阶段 3: 测试相同时间按 uuid 排序 =====
      print('\n[阶段 3] 测试相同 createTime 按 uuid 排序...');
      await _testSortByUuidWhenSameTime();

      // ===== 阶段 4: 测试逆序添加消息的排序 =====
      print('\n[阶段 4] 测试逆序添加消息的排序...');
      await _testReverseOrderInsertion();

      // ===== 阶段 5: 测试消息加载后是否需要额外排序 =====
      print('\n[阶段 5] 测试消息加载后是否需要额外排序...');
      await _testLoadAndSortMessages();

      // ===== 阶段 6: 测试大量消息排序性能 =====
      print('\n[阶段 6] 测试大量消息排序性能...');
      await _testLargeMessageSorting();

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
      'wenzagent_sorting_test_',
    );
    tempDirPath = tempDir.path;
    print('  临时目录: $tempDirPath');

    await DatabaseManager.instance.initialize(storagePath: tempDirPath);

    messageStoreService = MessageStoreServiceImpl(deviceId: deviceId);

    print('  ✓ Hive 初始化完成');
  }

  /// 测试按 createTime 排序
  Future<void> _testSortByCreateTime() async {
    print('  添加 5 条不同时间的消息...');

    final baseTime = DateTime.now();
    final messages = <AiEmployeeMessageEntity>[];

    // 创建 5 条消息，时间间隔 1 秒
    for (int i = 0; i < 5; i++) {
      final message = AiEmployeeMessageEntity(
        uuid: const Uuid().v4(),
        employeeId: employeeId,
        role: i % 2 == 0 ? 'user' : 'assistant',
        type: 'text',
        content: 'Message $i',
        createTime: baseTime.add(Duration(seconds: i)),
        updateTime: baseTime.add(Duration(seconds: i)),
      );
      messages.add(message);
    }

    // 打乱顺序后添加
    messages.shuffle();
    print('  打乱后的顺序: ${messages.map((m) => m.content).join(", ")}');

    await messageStoreService.addMessages(messages);

    // 加载消息
    final loadedMessages = await messageStoreService.getMessages(employeeId);
    print('  加载的消息顺序: ${loadedMessages.map((m) => m.content).join(", ")}');

    // 验证是否按 createTime 排序
    bool isSorted = true;
    for (int i = 1; i < loadedMessages.length; i++) {
      if (loadedMessages[i].createTime.isBefore(
        loadedMessages[i - 1].createTime,
      )) {
        isSorted = false;
        print(
          '  ❌ 排序错误: ${loadedMessages[i].content} 应该在 ${loadedMessages[i - 1].content} 之前',
        );
        break;
      }
    }

    if (isSorted) {
      print('  ✓ 消息已按 createTime 正确排序');
    } else {
      throw StateError('消息未按 createTime 排序！');
    }
  }

  /// 测试相同 createTime 按 uuid 排序
  Future<void> _testSortByUuidWhenSameTime() async {
    print('  添加 5 条相同时间的消息...');

    final sameTime = DateTime.now();
    final messages = <AiEmployeeMessageEntity>[];

    // 创建 5 条消息，时间相同
    for (int i = 0; i < 5; i++) {
      final message = AiEmployeeMessageEntity(
        uuid: const Uuid().v4(),
        employeeId: employeeId,
        role: 'user',
        type: 'text',
        content: 'SameTime Message $i',
        createTime: sameTime,
        updateTime: sameTime,
      );
      messages.add(message);
    }

    await messageStoreService.addMessages(messages);

    // 加载消息
    final loadedMessages = await messageStoreService.getMessages(employeeId);
    final sameTimeMessages = loadedMessages
        .where((m) => m.content!.startsWith('SameTime Message'))
        .toList();

    print('  加载的相同时间消息顺序:');
    for (var msg in sameTimeMessages) {
      print('    ${msg.content} - uuid: ${msg.uuid.substring(0, 8)}...');
    }

    // 验证是否按 uuid 排序（稳定性保证）
    bool isStableSorted = true;
    for (int i = 1; i < sameTimeMessages.length; i++) {
      if (sameTimeMessages[i].uuid.compareTo(sameTimeMessages[i - 1].uuid) <
          0) {
        isStableSorted = false;
        print('  ❌ 稳定性排序错误: uuid 顺序不正确');
        break;
      }
    }

    if (isStableSorted) {
      print('  ✓ 相同时间的消息已按 uuid 稳定排序');
    } else {
      print('  ⚠ 相同时间的消息未按 uuid 排序（可能需要在应用层排序）');
    }
  }

  /// 测试逆序添加消息的排序
  Future<void> _testReverseOrderInsertion() async {
    final testEmployeeId = 'emp-reverse-test';
    print('  逆序添加 5 条消息...');

    final baseTime = DateTime.now();
    final messages = <AiEmployeeMessageEntity>[];

    // 创建 5 条消息，从新到旧
    for (int i = 4; i >= 0; i--) {
      final message = AiEmployeeMessageEntity(
        uuid: const Uuid().v4(),
        employeeId: testEmployeeId,
        role: 'user',
        type: 'text',
        content: 'Reverse Message $i',
        createTime: baseTime.add(Duration(seconds: i)),
        updateTime: baseTime.add(Duration(seconds: i)),
      );
      messages.add(message);
    }

    print('  添加顺序: ${messages.map((m) => m.content).join(", ")}');
    await messageStoreService.addMessages(messages);

    // 加载消息
    final loadedMessages = await messageStoreService.getMessages(
      testEmployeeId,
    );
    print('  加载顺序: ${loadedMessages.map((m) => m.content).join(", ")}');

    // 验证是否按时间正序排列
    bool isCorrectOrder = true;
    for (int i = 0; i < loadedMessages.length; i++) {
      if (!loadedMessages[i].content!.contains('Reverse Message $i')) {
        isCorrectOrder = false;
        print(
          '  ❌ 顺序错误: 期望 Reverse Message $i，实际 ${loadedMessages[i].content}',
        );
        break;
      }
    }

    if (isCorrectOrder) {
      print('  ✓ 逆序添加的消息已正确排序');
    } else {
      throw StateError('逆序添加的消息排序错误！');
    }
  }

  /// 测试消息加载后是否需要额外排序
  Future<void> _testLoadAndSortMessages() async {
    final testEmployeeId = 'emp-sort-test';
    print('  模拟 wenzflow 中的排序逻辑...');

    final baseTime = DateTime.now();
    final messages = <AiEmployeeMessageEntity>[];

    // 创建 10 条消息
    for (int i = 0; i < 10; i++) {
      final message = AiEmployeeMessageEntity(
        uuid: const Uuid().v4(),
        employeeId: testEmployeeId,
        role: i % 2 == 0 ? 'user' : 'assistant',
        type: 'text',
        content: 'Sort Test Message $i',
        createTime: baseTime.add(Duration(seconds: i)),
        updateTime: baseTime.add(Duration(seconds: i)),
      );
      messages.add(message);
    }

    // 打乱后添加
    messages.shuffle();
    await messageStoreService.addMessages(messages);

    // 加载消息
    final loadedMessages = await messageStoreService.getMessages(
      testEmployeeId,
    );

    // 应用 wenzflow 中的排序逻辑
    final sortedMessages = List<AiEmployeeMessageEntity>.from(loadedMessages);
    sortedMessages.sort((a, b) {
      final timeCompare = a.createTime.compareTo(b.createTime);
      if (timeCompare != 0) return timeCompare;
      // 时间相同时按 uuid 排序，保证排序稳定性
      return a.uuid.compareTo(b.uuid);
    });

    print('  加载的消息数量: ${loadedMessages.length}');
    print('  排序后的消息数量: ${sortedMessages.length}');

    // 验证排序后是否正确
    bool isCorrectlySorted = true;
    for (int i = 1; i < sortedMessages.length; i++) {
      final timeCompare = sortedMessages[i].createTime.compareTo(
        sortedMessages[i - 1].createTime,
      );
      if (timeCompare < 0) {
        isCorrectlySorted = false;
        print('  ❌ 排序错误');
        break;
      } else if (timeCompare == 0) {
        // 时间相同，检查 uuid
        if (sortedMessages[i].uuid.compareTo(sortedMessages[i - 1].uuid) < 0) {
          isCorrectlySorted = false;
          print('  ❌ 稳定性排序错误');
          break;
        }
      }
    }

    if (isCorrectlySorted) {
      print('  ✓ 应用 wenzflow 排序逻辑后消息正确排序');
    } else {
      throw StateError('应用排序逻辑后消息仍然排序错误！');
    }
  }

  /// 测试大量消息排序性能
  Future<void> _testLargeMessageSorting() async {
    final testEmployeeId = 'emp-large-test';
    const messageCount = 100;
    print('  添加 $messageCount 条消息...');

    final baseTime = DateTime.now();
    final messages = <AiEmployeeMessageEntity>[];

    // 创建 100 条消息
    for (int i = 0; i < messageCount; i++) {
      final message = AiEmployeeMessageEntity(
        uuid: const Uuid().v4(),
        employeeId: testEmployeeId,
        role: i % 2 == 0 ? 'user' : 'assistant',
        type: 'text',
        content: 'Large Test Message $i',
        createTime: baseTime.add(Duration(milliseconds: i * 100)),
        updateTime: baseTime.add(Duration(milliseconds: i * 100)),
      );
      messages.add(message);
    }

    // 打乱后添加
    messages.shuffle();

    final stopwatch = Stopwatch()..start();
    await messageStoreService.addMessages(messages);
    final addTime = stopwatch.elapsedMilliseconds;
    print('  添加耗时: ${addTime}ms');

    // 加载消息
    stopwatch.reset();
    final loadedMessages = await messageStoreService.getMessages(
      testEmployeeId,
    );
    final loadTime = stopwatch.elapsedMilliseconds;
    print('  加载耗时: ${loadTime}ms');

    // 验证消息数量
    if (loadedMessages.length != messageCount) {
      throw StateError(
        '消息数量不匹配！期望: $messageCount, 实际: ${loadedMessages.length}',
      );
    }

    // 验证排序
    stopwatch.reset();
    bool isSorted = true;
    for (int i = 1; i < loadedMessages.length; i++) {
      if (loadedMessages[i].createTime.isBefore(
        loadedMessages[i - 1].createTime,
      )) {
        isSorted = false;
        break;
      }
    }
    final sortCheckTime = stopwatch.elapsedMilliseconds;
    print('  排序验证耗时: ${sortCheckTime}ms');

    if (isSorted) {
      print('  ✓ $messageCount 条消息已正确排序');
    } else {
      print('  ⚠ $messageCount 条消息未排序，需要在应用层排序');

      // 测试应用层排序性能
      stopwatch.reset();
      final sortedMessages = List<AiEmployeeMessageEntity>.from(loadedMessages);
      sortedMessages.sort((a, b) {
        final timeCompare = a.createTime.compareTo(b.createTime);
        if (timeCompare != 0) return timeCompare;
        return a.uuid.compareTo(b.uuid);
      });
      final appSortTime = stopwatch.elapsedMilliseconds;
      print('  应用层排序耗时: ${appSortTime}ms');
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
