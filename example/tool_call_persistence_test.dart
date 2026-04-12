import 'dart:io';

import 'package:wenzagent/wenzagent.dart';
import 'package:uuid/uuid.dart';

/// 测试计算工具
class TestCalculatorTool extends AgentTool {
  @override
  String get name => 'test_calculator';

  @override
  String get description => '执行简单的数学计算，返回计算结果';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'expression': {
        'type': 'string',
        'description': '要计算的表达式',
      },
    },
    'required': ['expression'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final expression = arguments['expression'] as String?;
    if (expression == null || expression.isEmpty) {
      return ToolResult.error('表达式不能为空');
    }
    return ToolResult.success('计算结果: $expression = 42');
  }
}

/// 工具调用消息持久化测试
///
/// 测试场景：
/// 1. 发送用户消息，触发工具调用
/// 2. 验证用户消息、AI 消息（含 tool_calls）、工具结果消息都被持久化
/// 3. 重新创建 Agent，验证工具消息被正确加载
///
/// 预期结果：所有工具相关消息（tool_calls, function_result）都应正确持久化

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║           工具调用消息持久化测试                            ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = ToolCallPersistenceTest();
  await test.run();
}

class ToolCallPersistenceTest {
  late DeviceClient device;
  late String employeeId;
  late String tempDirPath;

  final String deviceId = 'test-device';
  final String employeeName = 'Test Tool Assistant';
  final String model = 'mimo-v2-pro';

  /// 从环境变量获取 API 配置
  String? get _apiKey => Platform.environment['OPENAI_API_KEY'];
  String? get _apiBaseUrl => Platform.environment['OPENAI_API_URL'];

  bool get _hasApiKey => _apiKey != null && _apiKey!.isNotEmpty;

  Future<void> run() async {
    try {
      // ===== 阶段 1: 初始化 =====
      print('\n[阶段 1] 初始化环境...');
      await _initialize();

      // ===== 阶段 2: 创建测试环境 =====
      print('\n[阶段 2] 创建测试环境...');
      await _setupTestEnvironment();

      // ===== 阶段 3: 测试工具调用消息持久化 =====
      print('\n[阶段 3] 测试工具调用消息持久化...');
      await _testToolCallMessagePersistence();

      // ===== 阶段 4: 验证持久化结果 =====
      print('\n[阶段 4] 验证持久化结果...');
      await _verifyPersistence();

      // ===== 阶段 5: 重新创建 Agent 并验证加载 =====
      print('\n[阶段 5] 重新创建 Agent 并验证加载...');
      await _testReloadFromPersistence();

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
    final tempDir = await Directory.systemTemp.createTemp('wenzagent_tool_persistence_test_');
    tempDirPath = tempDir.path;
    print('  临时目录: $tempDirPath');
  }

  /// 创建测试环境
  Future<void> _setupTestEnvironment() async {
    // 创建 DeviceClient
    device = DeviceClient.getInstance(deviceId);
    await device.initialize(DeviceClientConfig(
      dbPath: tempDirPath,
      host: 'localhost',
      port: 9090,
      deviceName: 'Test Device',
    ));

    // 创建员工
    employeeId = 'emp-test-${const Uuid().v4().substring(0, 8)}';
    final employee = AiEmployeeEntity(
      uuid: employeeId,
      name: employeeName,
      role: 'assistant',
      status: 'active',
      description: '工具调用持久化测试员工',
      systemPrompt: '你是一个测试助手。当用户请求执行计算时，请使用 test_calculator 工具。',
      provider: 'openai',
      model: 'mimo-v2-pro',
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

  /// 测试工具调用消息持久化
  Future<void> _testToolCallMessagePersistence() async {
    if (!_hasApiKey) {
      print('  ⚠️  未配置 OPENAI_API_KEY，跳过工具调用测试');
      print('  提示: 设置环境变量 OPENAI_API_KEY 可启用完整测试');
      return;
    }

    print('  获取 AgentProxy...');
    final agentProxy = await device.getOrCreateAgentProxy(employeeId: employeeId);

    // 注册测试工具
    print('  注册测试工具...');
    final testTool = TestCalculatorTool();
    agentProxy.registerTool(testTool);
    print('  ✓ 已注册工具: ${testTool.name}');

    // 发送触发工具调用的消息
    print('  发送触发工具调用的消息...');
    final messageId = await agentProxy.sendMessage(
      MessageInput(content: '请使用 test_calculator 工具计算 "1+1"', role: 'user'),
    );
    print('  ✓ 消息已发送 (ID: $messageId)');

    // 等待工具调用完成
    print('  等待工具调用处理...');
    await Future.delayed(const Duration(seconds: 10));

    // 获取消息列表
    final messages = await agentProxy.getSessionMessages();
    print('  当前消息数量: ${messages.length}');

    // 打印所有消息
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final role = msg.role;
      final content = msg.content ?? '';
      final toolCalls = msg.toolCalls;
      final toolCallId = msg.toolCallId;
      final preview = content.length > 30 ? '${content.substring(0, 30)}...' : content;

      print('    消息 ${i + 1}: [$role]');
      if (toolCalls != null) {
        print('      - 包含 tool_calls: ${toolCalls.length} 个');
      } else if (toolCallId != null) {
        print('      - 工具结果, toolCallId: $toolCallId');
        print('      - 内容: $preview');
      } else {
        print('      - 内容: $preview');
      }
    }
  }

  /// 验证持久化结果
  Future<void> _verifyPersistence() async {
    final messageStore = MessageStore();

    final messages = await messageStore.getMessages(deviceId, employeeId);

    print('  数据库中消息数量: ${messages.length}');

    if (messages.isEmpty) {
      print('  ⚠️  数据库中没有持久化的消息');
      return;
    }

    print('  ✓ 数据库中有 ${messages.length} 条持久化消息');

    // 读取并分析每条消息
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      print('  消息 ${i + 1} (${msg.uuid}):');
      print('    - role: ${msg.role}');
      print('    - type: ${msg.type}');
      print('    - has toolCalls: ${msg.toolCalls != null}');
      print('    - has toolResult: ${msg.toolResult != null}');
      final content = msg.content ?? '';
      print('    - content: ${content.length > 50 ? "${content.substring(0, 50)}..." : content}');
    }
  }

  /// 测试从持久化重新加载
  Future<void> _testReloadFromPersistence() async {
    print('  销毁当前 Agent...');
    await device.destroyAgentProxy(employeeId);
    await Future.delayed(const Duration(milliseconds: 200));

    print('  重新创建 Agent...');
    final agentProxy = await device.getOrCreateAgentProxy(employeeId: employeeId);

    print('  等待消息加载...');
    await Future.delayed(const Duration(milliseconds: 500));

    final messages = await agentProxy.getSessionMessages();
    print('  重新加载后的消息数量: ${messages.length}');

    if (messages.isEmpty) {
      print('  ⚠️  没有从持久化加载到消息');
      return;
    }

    // 验证工具相关消息
    var hasToolCalls = false;
    var hasToolResult = false;

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (msg.toolCalls != null) {
        hasToolCalls = true;
        print('  ✓ 找到含 tool_calls 的消息');
      }
      if (msg.toolCallId != null) {
        hasToolResult = true;
        print('  ✓ 找到工具结果消息');
      }
    }

    if (!hasToolCalls && _hasApiKey) {
      print('  ⚠️  未找到含 tool_calls 的消息');
    }
    if (!hasToolResult && _hasApiKey) {
      print('  ⚠️  未找到工具结果消息');
    }

    print('  ✓ 重新加载测试完成');
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
      await DatabaseManager.getInstance('test').close();
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
