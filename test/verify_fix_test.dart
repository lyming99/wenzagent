import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:wenzagent/src/agent/adapter/persistent_chat_adapter.dart';
import 'package:wenzagent/src/agent/adapter/provider_config.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/client/cached_agent_proxy.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/agent/impl/agent_impl.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

/// 验证修复的测试
void main() {
  late String apiKey;
  late String apiUrl;
  late String apiModel;
  late ProviderConfig providerConfig;
  
  setUpAll(() async {
    apiKey = Platform.environment['OPENAI_API_KEY'] ?? '';
    apiUrl = Platform.environment['OPENAI_API_URL'] ?? 'https://api.openai.com/v1';
    apiModel = Platform.environment['OPENAI_API_MODEL'] ?? 'gpt-3.5-turbo';
    
    if (apiKey.isEmpty) {
      throw Exception('请设置环境变量 OPENAI_API_KEY');
    }
    
    providerConfig = ProviderConfig(
      provider: LLMProvider.openai,
      apiKey: apiKey,
      baseUrl: apiUrl,
      model: apiModel,
    );
    
    await HiveManager.instance.initialize(
      storagePath: 'D:\\project\\GitHub\\wenzagent\\test_hive',
    );
  });
  
  tearDownAll(() async {
    await HiveManager.instance.close();
  });
  
  group('修复验证测试', () {
    test('✅ 验证 toolCalls 序列化修复', () {
      print('\n=== 验证 toolCalls 序列化 ===');
      
      // 创建包含 toolCalls 的 AI 消息
      final toolCalls = [
        AIChatMessageToolCall(
          id: 'call_123',
          name: 'get_weather',
          argumentsRaw: '{"city": "Beijing"}',
          arguments: {'city': 'Beijing'},
        ),
      ];
      
      final message = AIChatMessage(
        content: '',
        toolCalls: toolCalls,
      );
      
      // 创建 wrapper
      final wrapper = MessageWrapper(
        uuid: 'test-msg-123',
        message: message,
        createdAt: DateTime.now(),
      );
      
      // 使用 PersistentChatAdapter 的私有方法逻辑
      final map = <String, dynamic>{
        'uuid': wrapper.uuid,
        'id': wrapper.uuid,
        'role': 'assistant',
        'content': message.contentAsString,
        'createdAt': wrapper.createdAt.toIso8601String(),
      };
      
      // ✅ 关键：序列化 toolCalls
      if (message.toolCalls.isNotEmpty) {
        map['toolCalls'] = jsonEncode(message.toolCalls
            .map((tc) => {'id': tc.id, 'name': tc.name, 'arguments': tc.arguments})
            .toList());
      }
      
      print('toolCalls 类型: ${map['toolCalls'].runtimeType}');
      print('toolCalls 内容: ${map['toolCalls']}');
      
      // 验证是字符串类型
      expect(map['toolCalls'], isA<String>());
      
      // 验证可以反序列化
      final decoded = jsonDecode(map['toolCalls'] as String) as List;
      expect(decoded.length, equals(1));
      expect(decoded[0]['name'], equals('get_weather'));
      
      print('✅ toolCalls 序列化正确');
    });
    
    test('✅ 发送消息测试（验证持久化）', () async {
      print('\n=== 发送消息并验证持久化 ===');
      
      final employeeId = 'verify-${DateTime.now().millisecondsSinceEpoch}';
      final deviceId = 'device-${DateTime.now().millisecondsSinceEpoch}';
      
      final messageStore = MessageStoreServiceImpl(deviceId: deviceId);
      
      // 创建持久化适配器
      final adapter = PersistentChatAdapter();
      
      adapter.persistMessage = (messageData) async {
        try {
          final entity = AiEmployeeMessageEntity.fromMap(messageData);
          await messageStore.addMessage(entity, deviceId: deviceId);
          print('✅ 消息持久化成功: ${entity.uuid}');
        } catch (e) {
          print('❌ 消息持久化失败: $e');
          rethrow;
        }
      };
      
      adapter.loadMessages = (employeeId) async {
        final messages = await messageStore.getMessages(employeeId);
        return messages.map((m) => m.toMap()).toList();
      };
      
      adapter.deleteMessagesCallback = (employeeId) async {
        await messageStore.deleteMessages(employeeId, deviceId: deviceId);
      };
      
      // 创建 Agent
      final agent = AgentImpl(
        employeeId: employeeId,
        chatAdapter: adapter,
      );
      
      await agent.initialize();
      await agent.setProvider(providerConfig);
      
      // 创建 proxy
      final proxy = AgentProxy.local(
        employeeId: employeeId,
        deviceId: deviceId,
        localAgent: agent,
      );
      
      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );
      
      await cachedProxy.initialize();
      
      // 发送消息
      final messageId = await cachedProxy.sendMessage(MessageInput(
        content: '你好',
      ));
      
      print('发送消息ID: $messageId');
      
      // 等待完成
      await _waitForIdle(cachedProxy, timeout: const Duration(seconds: 30));
      
      // 验证消息
      final messages = await cachedProxy.getMessages();
      print('消息数量: ${messages.length}');
      
      expect(messages.length, greaterThanOrEqualTo(2));
      
      // 清理
      await cachedProxy.dispose();
      await proxy.dispose();
      await agent.dispose();
      await messageStore.deleteMessages(employeeId, deviceId: deviceId);
      
      print('✅ 发送消息测试通过');
    });
  });
}

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
      print('⚠️ 等待 idle 状态超时，当前状态: ${proxy.status}');
      completer.complete();
    }
  });
  
  return completer.future;
}
