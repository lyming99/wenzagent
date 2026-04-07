import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wenzagent/src/agent/adapter/persistent_chat_adapter.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/client/cached_agent_proxy.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/agent/impl/agent_impl.dart';
import 'package:wenzagent/src/agent/tool/agent_tool.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

/// 简单的测试工具（不需要权限）
class SimpleTestTool extends AgentTool {
  @override
  String get name => 'test_simple';

  @override
  String get description => 'A simple test tool that returns a greeting message.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'name': {
        'type': 'string',
        'description': 'The name to greet',
      },
    },
    'required': ['name'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final name = arguments['name'] as String;
    await Future.delayed(const Duration(milliseconds: 100)); // 模拟耗时操作
    return ToolResult.success('Hello, $name! This is a test tool.');
  }
}

/// 需要权限的测试工具
class PermissionTestTool extends AgentTool {
  @override
  String get name => 'test_permission';

  @override
  String get description => 'A test tool that requires permission to execute.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'description': 'The action to perform',
      },
    },
    'required': ['action'],
  };

  @override
  bool get requiresPermission => true;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final action = arguments['action'] as String;
    await Future.delayed(const Duration(milliseconds: 100));
    return ToolResult.success('Executed action: $action (with permission)');
  }
}

/// Agent 高级功能测试
///
/// 测试核心高级功能：
/// 1. 技能调用状态监听
/// 2. 权限申请状态监听
/// 3. 删除处理中的消息
/// 4. 清空处理中的会话
void main() {
  // 测试配置
  late String apiKey;
  late String apiUrl;
  late String apiModel;
  late ProviderConfig providerConfig;

  // 测试组件
  late AgentImpl agent;
  late AgentProxy localProxy;
  late CachedAgentProxy cachedProxy;
  late MessageStoreService messageStore;
  late String employeeId;
  late String deviceId;

  setUpAll(() async {
    // 读取环境变量
    apiKey = Platform.environment['OPENAI_API_KEY'] ?? '';
    apiUrl = Platform.environment['OPENAI_API_URL'] ?? 'https://api.openai.com/v1';
    apiModel = Platform.environment['OPENAI_API_MODEL'] ?? 'gpt-3.5-turbo';

    if (apiKey.isEmpty) {
      throw Exception('请设置环境变量 OPENAI_API_KEY');
    }

    print('\n=== 高级功能测试配置 ===');
    print('API URL: $apiUrl');
    print('API Model: $apiModel');

    // 配置 Provider
    providerConfig = ProviderConfig(
      provider: LLMProvider.openai,
      apiKey: apiKey,
      baseUrl: apiUrl,
      model: apiModel,
    );

    // 初始化 Hive（指定存储路径）
    await HiveManager.instance.initialize(
      storagePath: 'D:\\project\\GitHub\\wenzagent\\test_hive',
    );

    // 生成测试 ID
    employeeId = 'test-adv-${DateTime.now().millisecondsSinceEpoch}';
    deviceId = 'device-adv-${DateTime.now().millisecondsSinceEpoch}';

    print('Employee ID: $employeeId');
    print('Device ID: $deviceId\n');
  });

  setUp(() async {
    // 每个测试前创建新的 Agent 实例
    messageStore = MessageStoreServiceImpl(deviceId: deviceId);

    // 创建持久化适配器
    final adapter = PersistentChatAdapter();

    // 设置持久化回调
    adapter.persistMessage = (messageData) async {
      final entity = AiEmployeeMessageEntity.fromMap(messageData);
      await messageStore.addMessage(entity, deviceId: deviceId);
    };

    adapter.loadMessages = (employeeId) async {
      final messages = await messageStore.getMessages(employeeId);
      return messages.map((m) => m.toMap()).toList();
    };

    adapter.updateMessageStatusCallback = (messageId, status, {error}) async {
      await messageStore.updateMessageStatus(messageId, status.name, error: error);
    };

    adapter.deleteMessagesCallback = (employeeId) async {
      await messageStore.deleteMessages(employeeId, deviceId: deviceId);
    };

    // 创建 Agent
    agent = AgentImpl(
      employeeId: employeeId,
      chatAdapter: adapter,
    );

    // 初始化（不启用内置工具，只注册测试工具）
    await agent.initialize(enableBuiltinTools: false);

    // 注册测试工具
    agent.registerTool(SimpleTestTool());
    agent.registerTool(PermissionTestTool());

    await agent.setProvider(providerConfig);

    // 创建 AgentProxy (本地模式)
    localProxy = AgentProxy.local(
      employeeId: employeeId,
      deviceId: deviceId,
      localAgent: agent,
    );

    // 创建 CachedAgentProxy
    cachedProxy = CachedAgentProxy(
      proxy: localProxy,
      messageStore: messageStore,
      deviceId: deviceId,
      employeeId: employeeId,
    );

    await cachedProxy.initialize();
  });

  tearDown(() async {
    await cachedProxy.dispose();
    await localProxy.dispose();
    await agent.dispose();
    await messageStore.deleteMessages(employeeId, deviceId: deviceId);
  });

  tearDownAll(() async {
    await HiveManager.instance.close();
  });

  group('高级功能测试', () {
    test('🔧 技能调用状态监听', () async {
      print('\n--- 测试：技能调用状态监听 ---');

      final toolEvents = <Map<String, dynamic>>[];
      final completer = Completer<void>();

      // 监听工具调用事件
      final subscription = localProxy.onEvent.listen((event) {
        if (event['type'] == 'toolCallStart' || event['type'] == 'toolCallResult') {
          toolEvents.add(event);
          print('工具事件: ${event['type']} - ${event['data']}');
        }
      });

      // 监听状态变化
      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle && !completer.isCompleted) {
          completer.complete();
        }
      });

      // 发送需要工具调用的消息（更明确的指令）
      final messageId = await cachedProxy.sendMessage(MessageInput(
        content: 'Call the test_simple tool with name parameter set to "World" and tell me the result.',
      ));

      print('发送消息ID: $messageId');

      // 等待处理完成
      await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('等待工具调用超时'),
      );

      await subscription.cancel();

      // 验证收到了工具调用事件
      expect(toolEvents.isNotEmpty, isTrue, reason: '应该收到工具调用事件');

      final startEvent = toolEvents.firstWhere(
        (e) => e['type'] == 'toolCallStart',
        orElse: () => <String, dynamic>{},
      );
      expect(startEvent.isNotEmpty, isTrue, reason: '应该有 toolCallStart 事件');
      expect(startEvent['data']['toolName'], equals('test_simple'));

      final resultEvent = toolEvents.firstWhere(
        (e) => e['type'] == 'toolCallResult',
        orElse: () => <String, dynamic>{},
      );
      expect(resultEvent.isNotEmpty, isTrue, reason: '应该有 toolCallResult 事件');
      expect(resultEvent['data']['isError'], isFalse);

      print('✅ 通过\n');
    });

    test('🔐 权限申请状态监听', () async {
      print('\n--- 测试：权限申请状态监听 ---');

      final permissionRequests = <AgentPermissionRequest>[];
      final completer = Completer<void>();

      // 监听权限申请事件
      final subscription = localProxy.onEvent.listen((event) {
        if (event['type'] == 'toolPermissionRequest') {
          final request = AgentPermissionRequest.fromMap(
            event['data'] as Map<String, dynamic>,
          );
          permissionRequests.add(request);
          print('权限申请: ${request.functionName} - ${request.data}');

          // 自动授予权限
          if (!completer.isCompleted) {
            cachedProxy.respondToPermission(
              request.requestId,
              PermissionDecision.allow,
            );
            print('已授予权限');
          }
        }
      });

      // 监听状态变化
      final stateSubscription = cachedProxy.onStateChanged.listen((state) {
        print('状态: ${state.status}');
        if (state.status == AgentStatus.idle && permissionRequests.isNotEmpty) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
      });

      // 发送需要权限的消息（更明确的指令）
      final messageId = await cachedProxy.sendMessage(MessageInput(
        content: 'Call the test_permission tool with action parameter set to "test_action" and tell me the result.',
      ));

      print('发送消息ID: $messageId');

      // 等待处理完成
      await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('等待权限申请超时'),
      );

      await subscription.cancel();
      await stateSubscription.cancel();

      // 验证收到了权限申请
      expect(permissionRequests.isNotEmpty, isTrue, reason: '应该收到权限申请');

      final request = permissionRequests.first;
      expect(request.functionName, equals('test_permission'));
      // 数据在 data['arguments'] 中
      final arguments = request.data?['arguments'] as Map<String, dynamic>?;
      expect(arguments?['action'], equals('test_action'));

      print('✅ 通过\n');
    });

    test('⏹️ 删除处理中的消息', () async {
      print('\n--- 测试：删除处理中的消息 ---');

      // 发送消息但不等待完成
      final messageId = await cachedProxy.sendMessage(MessageInput(
        content: '请详细描述人工智能的发展历史，从20世纪50年代开始，到2024年为止，包括所有重要的里程碑和突破',
      ));

      print('发送消息ID: $messageId');

      // 等待一小段时间确保消息开始处理
      await Future.delayed(const Duration(milliseconds: 500));

      // 立即删除消息（此时应该正在处理中）
      print('尝试删除处理中的消息...');
      await cachedProxy.revokeMessage(messageId);
      print('已发送删除请求');

      // 等待状态恢复到 idle
      await _waitForIdle(cachedProxy, timeout: const Duration(seconds: 5));

      // 验证消息被删除
      final messages = await cachedProxy.getMessages();
      final messageExists = messages.any((m) => m.id == messageId);

      expect(messageExists, isFalse, reason: '消息应该被删除');

      print('✅ 通过\n');
    });

    test('🗑️ 清空处理中的会话', () async {
      print('\n--- 测试：清空处理中的会话 ---');

      // 发送消息但不等待完成
      final messageId = await cachedProxy.sendMessage(MessageInput(
        content: '请详细解释量子计算的原理，包括量子比特、量子门、量子纠缠等概念',
      ));

      print('发送消息ID: $messageId');

      // 等待一小段时间确保消息开始处理
      await Future.delayed(const Duration(milliseconds: 500));

      // 立即清空会话（此时应该正在处理中）
      print('尝试清空处理中的会话...');
      await cachedProxy.clearCurrentSession();
      print('已发送清空请求');

      // 等待状态恢复到 idle
      await _waitForIdle(cachedProxy, timeout: const Duration(seconds: 5));

      // 验证所有消息被清空
      final messages = await cachedProxy.getMessages();
      expect(messages.isEmpty, isTrue, reason: '会话应该被清空');

      print('✅ 通过\n');
    });

    test('📨 消息已接收状态管理', () async {
      print('\n--- 测试：消息已接收状态管理 ---');

      // 发送消息
      final messageId = await cachedProxy.sendMessage(MessageInput(
        content: '你好，这是一条测试消息',
      ));

      print('发送消息ID: $messageId');

      // 等待处理完成
      await _waitForIdle(cachedProxy, timeout: const Duration(seconds: 30));

      // 验证消息已保存
      final messages = await cachedProxy.getMessages();
      final savedMessage = messages.firstWhere(
        (m) => m.id == messageId,
        orElse: () => throw Exception('消息未找到'),
      );

      expect(savedMessage.id, equals(messageId));
      expect(savedMessage.role, equals('user'));
      expect(savedMessage.content, contains('你好'));

      print('消息已保存: ${savedMessage.id}');
      print('✅ 通过\n');
    });

    test('🔄 重发机制', () async {
      print('\n--- 测试：重发机制 ---');

      // 发送消息
      final messageId = await cachedProxy.sendMessage(MessageInput(
        content: '第一条消息：你好',
      ));

      print('第一次发送消息ID: $messageId');

      // 等待处理完成
      await _waitForIdle(cachedProxy, timeout: const Duration(seconds: 30));

      // 验证消息已保存
      var messages = await cachedProxy.getMessages();
      expect(messages.length, equals(2)); // 用户消息 + 助手回复

      // 模拟重发（使用相同的 ID）
      // 注意：实际的重发机制需要客户端支持，这里测试消息 ID 的一致性
      print('验证消息ID一致性...');

      final userMessage = messages.firstWhere((m) => m.role == 'user');
      expect(userMessage.id, equals(messageId));

      // 清空会话后重新发送
      await cachedProxy.clearCurrentSession();

      // 重新发送新消息（新 ID）
      final messageId2 = await cachedProxy.sendMessage(MessageInput(
        content: '第二条消息：世界',
      ));

      print('第二次发送消息ID: $messageId2');

      // 等待处理完成
      await _waitForIdle(cachedProxy, timeout: const Duration(seconds: 30));

      // 验证新消息
      messages = await cachedProxy.getMessages();
      final newUserMessage = messages.firstWhere((m) => m.role == 'user');
      expect(newUserMessage.id, equals(messageId2));
      expect(newUserMessage.content, contains('世界'));

      print('✅ 通过\n');
    });

    test('🔍 状态查询', () async {
      print('\n--- 测试：状态查询 ---');

      // 初始状态应该是 idle
      expect(cachedProxy.status, equals(AgentStatus.idle));
      print('初始状态: ${cachedProxy.status}');

      // 发送消息
      final messageId = await cachedProxy.sendMessage(MessageInput(
        content: '请简单介绍一下 Dart 语言',
      ));

      print('发送消息ID: $messageId');

      // 立即检查状态（应该正在处理）
      await Future.delayed(const Duration(milliseconds: 100));
      print('处理中状态: ${cachedProxy.status}');

      // 等待处理完成
      await _waitForIdle(cachedProxy, timeout: const Duration(seconds: 30));

      // 最终状态应该是 idle
      expect(cachedProxy.status, equals(AgentStatus.idle));
      print('最终状态: ${cachedProxy.status}');

      // 验证消息存在
      final messages = await cachedProxy.getMessages();
      expect(messages.isNotEmpty, isTrue);

      print('✅ 通过\n');
    });
  });

  print('\n=== 所有高级测试完成 ===\n');
}

/// 等待 Agent 进入 idle 状态
Future<void> _waitForIdle(CachedAgentProxy proxy, {required Duration timeout}) async {
  final completer = Completer<void>();

  if (proxy.status == AgentStatus.idle) {
    completer.complete();
    return completer.future;
  }

  StreamSubscription? subscription;
  Timer? timer;

  subscription = proxy.onStateChanged.listen((state) {
    if (state.status == AgentStatus.idle) {
      timer?.cancel();
      subscription?.cancel();
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  });

  timer = Timer(timeout, () {
    subscription?.cancel();
    if (!completer.isCompleted) {
      completer.completeError(TimeoutException('等待 idle 状态超时'));
    }
  });

  return completer.future;
}
