import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/agent/adapter/llm_chat_adapter.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/client/cached_agent_proxy.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/agent/impl/agent_impl.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

/// Agent 基础功能测试
/// 
/// 测试核心功能：
/// 1. 发送消息并收到回复
/// 2. 状态监听
/// 3. 消息ID一致性
/// 4. 消息不重复
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
    
    print('\n=== 测试配置 ===');
    print('API URL: $apiUrl');
    print('API Model: $apiModel');
    
    // 配置 Provider
    providerConfig = ProviderConfig(
      provider: LLMProvider.openai,
      apiKey: apiKey,
      baseUrl: apiUrl,
      model: apiModel,
    );
    
    // 初始化数据库（指定存储路径）
    await DatabaseManager.getInstance('test').initialize(
      storagePath: 'D:\\project\\GitHub\\wenzagent\\test_db',
    );
    
    // 生成测试 ID
    employeeId = 'test-${DateTime.now().millisecondsSinceEpoch}';
    deviceId = 'device-${DateTime.now().millisecondsSinceEpoch}';
    
    print('Employee ID: $employeeId');
    print('Device ID: $deviceId\n');
  });
  
  setUp(() async {
    // 每个测试前创建新的 Agent 实例
    messageStore = MessageStoreServiceImpl(deviceId: deviceId);
    
    // 创建适配器并配置持久化
    final adapter = LlmChatAdapter();
    adapter.configurePersistence(
      messageStore: messageStore,
      deviceId: deviceId,
    );
    
    // 创建 Agent
    agent = AgentImpl(
      employeeId: employeeId,
      deviceId: deviceId,
      chatAdapter: adapter,
    );
    
    await agent.initialize(enableBuiltinTools: false); // 禁用内置工具
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
      markReadQueueStore: MarkReadQueueStore(deviceId: deviceId),
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
    await DatabaseManager.getInstance('test').close();
  });
  
  group('基础功能测试', () {
    test('✅ 发送消息并收到回复', () async {
      print('\n--- 测试：发送消息并收到回复 ---');
      
      // 发送消息
      final messageId = await cachedProxy.sendMessage(MessageInput(
        content: '你好，请简单回复"测试成功"',
      ));
      
      print('发送消息ID: $messageId');
      expect(messageId, isNotEmpty);
      
      // 等待处理完成
      await _waitForIdle(cachedProxy, timeout: const Duration(seconds: 30));
      
      // 获取消息列表
      final messages = await cachedProxy.getMessages();
      print('消息数量: ${messages.length}');
      
      // 验证有用户消息和助手消息
      expect(messages.length, greaterThanOrEqualTo(2));
      
      final userMsg = messages.firstWhere((m) => m.role == 'user');
      final assistantMsg = messages.firstWhere((m) => m.role == 'assistant');
      
      expect(userMsg.id, equals(messageId));
      expect(assistantMsg.content, isNotEmpty);
      
      print('用户消息: ${userMsg.content}');
      print('助手回复: ${assistantMsg.content}');
      print('✅ 通过\n');
    });
    
    test('✅ 消息ID一致性', () async {
      print('\n--- 测试：消息ID一致性 ---');
      
      // 客户端生成UUID
      final clientMessageId = const Uuid().v4();
      print('客户端生成的消息ID: $clientMessageId');
      
      // 发送消息
      final returnedId = await cachedProxy.sendMessage(MessageInput(
        id: clientMessageId,
        content: '测试ID一致性',
      ));
      
      print('返回的消息ID: $returnedId');
      
      // 验证返回的ID与客户端生成的ID一致
      expect(returnedId, equals(clientMessageId));
      
      await _waitForIdle(cachedProxy, timeout: const Duration(seconds: 30));
      
      // 验证消息列表中的ID也是一致的
      final messages = await cachedProxy.getMessages();
      final userMsg = messages.firstWhere((m) => m.role == 'user');
      expect(userMsg.id, equals(clientMessageId));
      
      print('✅ 通过\n');
    });
    
    test('✅ 消息不重复', () async {
      print('\n--- 测试：消息不重复 ---');
      
      // 发送一条消息
      await cachedProxy.sendMessage(MessageInput(
        content: '测试消息不重复',
      ));
      
      await _waitForIdle(cachedProxy, timeout: const Duration(seconds: 30));
      
      // 多次获取消息列表，验证没有重复
      for (int i = 0; i < 3; i++) {
        final messages = await cachedProxy.getMessages();
        final ids = messages.map((m) => m.id).toList();
        final uniqueIds = ids.toSet();
        
        expect(ids.length, equals(uniqueIds.length), 
          reason: '第${i+1}次查询发现重复消息ID');
        
        print('第${i+1}次查询：${messages.length}条消息，无重复');
      }
      
      print('✅ 通过\n');
    });
    
    test('✅ 状态监听', () async {
      print('\n--- 测试：状态监听 ---');
      
      final states = <AgentStateSnapshot>[];
      final completer = Completer<void>();
      
      // 监听状态变化
      cachedProxy.onStateChanged.listen((state) {
        states.add(state);
        print('状态: ${state.status}');
        
        if (state.status == AgentStatus.idle && states.length > 1) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
      });
      
      // 发送消息
      await cachedProxy.sendMessage(MessageInput(
        content: '测试状态监听',
      ));
      
      // 等待完成
      await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('等待状态变化超时'),
      );
      
      // 验证状态变化序列
      expect(states.isNotEmpty, isTrue);
      
      // 应该包含 processing 或 streaming 状态
      final hasProcessing = states.any((s) => 
        s.status == AgentStatus.processing || 
        s.status == AgentStatus.streaming
      );
      expect(hasProcessing, isTrue, reason: '应该包含处理中状态');
      
      // 最终应该是 idle
      expect(states.last.status, equals(AgentStatus.idle));
      
      print('✅ 通过\n');
    });
    
    test('✅ 删除消息', () async {
      print('\n--- 测试：删除消息 ---');
      
      // 发送并等待完成
      final messageId = await cachedProxy.sendMessage(MessageInput(
        content: '测试删除消息',
      ));
      
      await _waitForIdle(cachedProxy, timeout: const Duration(seconds: 30));
      
      // 验证消息存在
      var messages = await cachedProxy.getMessages();
      expect(messages.any((m) => m.id == messageId), isTrue);
      print('消息已创建: $messageId');
      
      // 删除消息
      await cachedProxy.revokeMessage(messageId);
      print('已删除消息: $messageId');
      
      // 验证消息被删除
      messages = await cachedProxy.getMessages();
      expect(messages.any((m) => m.id == messageId), isFalse);
      
      print('✅ 通过\n');
    });
    
    test('✅ 清空消息', () async {
      print('\n--- 测试：清空所有消息 ---');
      
      // 发送多条消息
      for (int i = 0; i < 2; i++) {
        await cachedProxy.sendMessage(MessageInput(
          content: '测试消息 $i',
        ));
        await _waitForIdle(cachedProxy, timeout: const Duration(seconds: 30));
      }
      
      // 验证有消息
      var messages = await cachedProxy.getMessages();
      print('清空前消息数量: ${messages.length}');
      expect(messages.length, greaterThan(0));
      
      // 清空会话
      await cachedProxy.clearCurrentSession();
      print('已清空会话');
      
      // 验证消息被清空
      messages = await cachedProxy.getMessages();
      print('清空后消息数量: ${messages.length}');
      expect(messages.length, equals(0));
      
      print('✅ 通过\n');
    });
  });
  
  print('\n=== 所有测试完成 ===\n');
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
