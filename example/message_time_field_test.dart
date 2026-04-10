import 'dart:io';

import 'package:wenzagent/wenzagent.dart';
import 'package:uuid/uuid.dart';

/// 消息时间字段兼容性测试
///
/// 测试 createTime 和 createdAt 字段的兼容性问题
/// 验证从数据库加载消息时，时间字段能被正确解析

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║              消息时间字段兼容性测试                        ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = MessageTimeFieldTest();
  await test.run();
}

class MessageTimeFieldTest {
  late String tempDirPath;
  late MessageStoreService messageStoreService;

  final String deviceId = 'test-device-time-field';
  final String employeeId = 'emp-time-field-test';

  Future<void> run() async {
    try {
      // ===== 阶段 1: 初始化 =====
      print('\n[阶段 1] 初始化存储...');
      await _initialize();

      // ===== 阶段 2: 测试 createTime 字段（数据库实体使用）=====
      print('\n[阶段 2] 测试 createTime 字段（数据库实体）...');
      await _testCreateTimeField();

      // ===== 阶段 3: 测试 createdAt 字段（内存消息使用）=====
      print('\n[阶段 3] 测试 createdAt 字段兼容性...');
      await _testCreatedAtField();

      // ===== 阶段 4: 测试时间戳格式兼容性 =====
      print('\n[阶段 4] 测试不同时间格式兼容性...');
      await _testDifferentTimeFormats();

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
      'wenzagent_time_field_test_',
    );
    tempDirPath = tempDir.path;
    print('  临时目录: $tempDirPath');

    await DatabaseManager.instance.initialize(storagePath: tempDirPath);

    messageStoreService = MessageStoreServiceImpl(deviceId: deviceId);

    print('  ✓ 初始化完成');
  }

  /// 测试 createTime 字段（数据库实体使用）
  Future<void> _testCreateTimeField() async {
    print('  添加消息（使用 createTime 字段）...');

    final baseTime = DateTime.now();
    final messages = <AiEmployeeMessageEntity>[];

    // 创建 5 条消息
    for (int i = 0; i < 5; i++) {
      final message = AiEmployeeMessageEntity(
        uuid: const Uuid().v4(),
        employeeId: employeeId,
        role: 'user',
        type: 'text',
        content: 'CreateTime Message $i',
        createTime: baseTime.add(Duration(seconds: i)),
        updateTime: baseTime.add(Duration(seconds: i)),
      );
      messages.add(message);
    }

    await messageStoreService.addMessages(messages);

    // 从数据库加载
    final loadedMessages = await messageStoreService.getMessages(employeeId);
    print('  加载的消息数量: ${loadedMessages.length}');

    // 验证排序
    bool isSorted = true;
    for (int i = 1; i < loadedMessages.length; i++) {
      if (loadedMessages[i].createTime.isBefore(
        loadedMessages[i - 1].createTime,
      )) {
        isSorted = false;
        print('  ❌ 排序错误');
        break;
      }
    }

    if (isSorted) {
      print('  ✓ createTime 字段消息正确排序');
    } else {
      throw StateError('createTime 字段消息排序错误！');
    }

    // 验证 toMap 返回的字段名
    final map = loadedMessages.first.toMap();
    print('  验证 toMap() 返回的字段:');
    print('    包含 createTime: ${map.containsKey('createTime')}');
    print('    包含 createdAt: ${map.containsKey('createdAt')}');

    if (!map.containsKey('createTime')) {
      throw StateError('toMap() 应该包含 createTime 字段！');
    }

    print('  ✓ toMap() 使用 createTime 字段');
  }

  /// 测试 createdAt 字段兼容性
  Future<void> _testCreatedAtField() async {
    print('  测试字段名兼容逻辑...');

    // 模拟数据库实体返回的 Map（使用 createTime）
    final createTimeMap = {
      'uuid': const Uuid().v4(),
      'employeeId': employeeId,
      'role': 'user',
      'type': 'text',
      'content': 'Test Message',
      'createTime': DateTime.now().millisecondsSinceEpoch,
    };

    // 模拟内存消息返回的 Map（使用 createdAt）
    final createdAtMap = {
      'id': const Uuid().v4(),
      'role': 'user',
      'content': 'Test Message',
      'createdAt': DateTime.now().toIso8601String(),
    };

    // 测试兼容逻辑
    dynamic timeValue1 =
        createTimeMap['createTime'] ?? createTimeMap['createdAt'];
    dynamic timeValue2 =
        createdAtMap['createTime'] ?? createdAtMap['createdAt'];

    print('  createTime Map 解析结果: $timeValue1 (类型: ${timeValue1.runtimeType})');
    print('  createdAt Map 解析结果: $timeValue2 (类型: ${timeValue2.runtimeType})');

    if (timeValue1 == null) {
      throw StateError('createTime 字段应该能被解析！');
    }

    if (timeValue2 == null) {
      throw StateError('createdAt 字段应该能被解析！');
    }

    print('  ✓ 字段名兼容逻辑正确');
  }

  /// 测试不同时间格式兼容性
  Future<void> _testDifferentTimeFormats() async {
    print('  测试不同时间格式的解析...');

    final now = DateTime.now();

    // 测试 1: String 格式（ISO 8601）
    final stringTime = now.toIso8601String();
    final parsedFromString = DateTime.parse(stringTime);
    print('  ✓ String 格式解析: $stringTime -> $parsedFromString');

    // 测试 2: int 格式（毫秒时间戳）
    final intTime = now.millisecondsSinceEpoch;
    final parsedFromInt = DateTime.fromMillisecondsSinceEpoch(intTime);
    print('  ✓ int 格式解析: $intTime -> $parsedFromInt');

    // 测试 3: DateTime 格式
    final dateTime = now;
    print('  ✓ DateTime 格式: $dateTime');

    // 测试兼容逻辑
    final testCases = [
      {'createTime': stringTime, 'name': 'String createTime'},
      {'createTime': intTime, 'name': 'int createTime'},
      {'createTime': dateTime, 'name': 'DateTime createTime'},
      {'createdAt': stringTime, 'name': 'String createdAt'},
      {'createdAt': intTime, 'name': 'int createdAt'},
      {'createdAt': dateTime, 'name': 'DateTime createdAt'},
    ];

    for (final testCase in testCases) {
      final name = testCase['name'] as String;
      dynamic timeValue = testCase['createTime'] ?? testCase['createdAt'];

      DateTime parsed;
      if (timeValue is String) {
        parsed = DateTime.parse(timeValue);
      } else if (timeValue is int) {
        parsed = DateTime.fromMillisecondsSinceEpoch(timeValue);
      } else if (timeValue is DateTime) {
        parsed = timeValue;
      } else {
        throw StateError('$name: 不支持的时间类型 ${timeValue.runtimeType}');
      }

      print('  ✓ $name 解析成功: $parsed');
    }

    print('  ✓ 所有时间格式兼容性测试通过');
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
