import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wenzagent/src/agent/adapter/persistent_chat_adapter.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/client/cached_agent_proxy.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/agent/impl/agent_impl.dart';
import 'package:wenzagent/src/agent/tool/builtin/builtin_tools.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

/// Agent 客户端重启后工具调用类消息持久化恢复测试
///
/// 核心场景：
/// - 发送触发工具调用的消息，等待完成
/// - 模拟客户端重启（dispose 后重建 Agent + Adapter）
/// - 验证重启后从 Hive 加载的消息中，工具调用相关字段完好无损：
///   - functionResult 消息的 toolName 不为空（不是 "unknown"）
///   - functionResult 消息的 type == 'functionResult'
///   - assistant 消息的 toolCalls 正确保留
///   - toolCallId 匹配
void main() {
  late String apiKey;
  late String apiUrl;
  late String apiModel;
  late ProviderConfig providerConfig;

  late AgentImpl agent;
  late AgentProxy localProxy;
  late CachedAgentProxy cachedProxy;
  late MessageStoreServiceImpl messageStore;
  late String employeeId;
  late String deviceId;

  setUpAll(() async {
    apiKey = Platform.environment['OPENAI_API_KEY'] ?? '';
    apiUrl = Platform.environment['OPENAI_API_URL'] ?? 'https://api.openai.com/v1';
    apiModel = Platform.environment['OPENAI_API_MODEL'] ?? 'gpt-4o-mini';

    if (apiKey.isEmpty) {
      throw Exception('请设置环境变量 OPENAI_API_KEY');
    }

    print('\n========================================');
    print('  工具消息重启恢复测试');
    print('========================================');
    print('API URL: $apiUrl');
    print('API Model: $apiModel');

    providerConfig = ProviderConfig(
      provider: LLMProvider.openai,
      apiKey: apiKey,
      baseUrl: apiUrl,
      model: apiModel,
    );

    await HiveManager.instance.initialize(
      storagePath: 'D:\\project\\GitHub\\wenzagent\\test_hive_restart',
    );

    employeeId = 'restart-test-${DateTime.now().millisecondsSinceEpoch}';
    deviceId = 'device-${DateTime.now().millisecondsSinceEpoch}';
    print('Employee ID: $employeeId');
    print('Device ID: $deviceId\n');
  });

  /// 创建 PersistentChatAdapter 并挂载持久化回调（使用 fromMessageMap/toMessageMap）
  PersistentChatAdapter createAdapter() {
    final adapter = PersistentChatAdapter();

    adapter.persistMessage = (messageData) async {
      final entity = AiEmployeeMessageEntity.fromMessageMap(messageData);
      await messageStore.addMessage(entity, deviceId: deviceId);
    };

    adapter.loadMessages = (empId) async {
      final messages = await messageStore.getMessagesWithDeviceId(
        deviceId,
        empId,
      );
      return messages.map((m) => m.toMessageMap()).toList();
    };

    adapter.updateMessageStatusCallback = (messageId, status, {error}) async {
      await messageStore.updateMessageStatus(messageId, status.name, error: error);
    };

    adapter.deleteMessagesCallback = (empId) async {
      await messageStore.deleteMessages(empId, deviceId: deviceId);
    };

    return adapter;
  }

  /// 构建完整的 agent + proxy 栈
  Future<void> buildAgentStack(PersistentChatAdapter adapter) async {
    agent = AgentImpl(
      employeeId: employeeId,
      chatAdapter: adapter,
    );
    await agent.initialize(enableBuiltinTools: false);
    agent.registerTools(BuiltinTools.readOnly());
    await agent.setProvider(providerConfig);

    localProxy = AgentProxy.local(
      employeeId: employeeId,
      deviceId: deviceId,
      localAgent: agent,
    );

    cachedProxy = CachedAgentProxy(
      proxy: localProxy,
      messageStore: messageStore,
      deviceId: deviceId,
      employeeId: employeeId,
    );

    await cachedProxy.initialize();
  }

  /// 等待 agent 进入 idle 状态
  Future<void> waitForIdle({Duration timeout = const Duration(seconds: 90)}) {
    final completer = Completer<void>();
    int stateCount = 0;

    cachedProxy.onStateChanged.listen((state) {
      stateCount++;
      if (state.status == AgentStatus.idle && stateCount > 1) {
        // 额外等待确保持久化队列完成
        Future.delayed(const Duration(milliseconds: 800), () {
          if (!completer.isCompleted) completer.complete();
        });
      }
    });

    return completer.future.timeout(timeout, onTimeout: () {
      throw TimeoutException('等待 idle 超时');
    });
  }

  setUp(() async {
    messageStore = MessageStoreServiceImpl(deviceId: deviceId);
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

  // ===================================================================
  // 核心测试：工具消息重启后完整恢复
  // ===================================================================
  group('工具消息重启恢复', () {
    test('重启后 functionResult 消息的 toolName 正确恢复（不为 unknown）', () async {
      print('\n--- 测试：重启后工具消息 toolName 恢复 ---');

      // === 第一阶段：发送消息触发工具调用 ===
      final adapter1 = createAdapter();
      await buildAgentStack(adapter1);

      final idleFuture1 = waitForIdle();
      await cachedProxy.sendMessage(MessageInput(
        content: '请列出当前目录下的文件',
      ));
      await idleFuture1;

      // 收集第一阶段的工具消息快照
      final beforeMessages = await cachedProxy.getMessages();
      print('\n  [第一阶段] 对话完成，共 ${beforeMessages.length} 条消息');

      final beforeToolResults = beforeMessages
          .where((m) => m.type == 'functionResult' || (m.role == 'tool'))
          .toList();
      final beforeAssistantWithTools = beforeMessages
          .where((m) =>
              m.role == 'assistant' &&
              m.toolCalls != null &&
              m.toolCalls!.isNotEmpty)
          .toList();

      print('  [第一阶段] functionResult 消息数: ${beforeToolResults.length}');
      print('  [第一阶段] 含 toolCalls 的 assistant 消息数: ${beforeAssistantWithTools.length}');

      // 确认第一阶段确实产生了工具消息
      expect(beforeToolResults.isNotEmpty, isTrue,
          reason: '第一阶段应产生 functionResult 消息（需要 API 支持工具调用）');

      // 记录第一阶段的工具消息详情
      final beforeToolDetails = beforeToolResults.map((m) => {
        'id=${m.id}, toolCallId=${m.toolCallId}, toolName=${m.toolName}, '
        'type=${m.type}, content=${(m.content ?? '').substring(0, (m.content?.length ?? 0).clamp(0, 50))}'
      }).toList();
      for (final detail in beforeToolDetails) {
        print('  [第一阶段] $detail');
      }

      // === 第二阶段：模拟客户端重启 ===
      print('\n  [重启] dispose 第一阶段 agent...');
      await cachedProxy.dispose();
      await localProxy.dispose();
      await agent.dispose();
      // 不重建 messageStore，复用同一个 Hive 存储

      print('  [重启] 重建 adapter + agent + proxy...');
      final adapter2 = createAdapter();
      await buildAgentStack(adapter2);

      // 等待初始化完成（initSession 会从 Hive 加载历史消息）
      await Future.delayed(const Duration(milliseconds: 500));

      // === 第三阶段：验证重启后的消息 ===
      final afterMessages = await cachedProxy.getMessages();
      print('\n  [第三阶段] 重启后消息数: ${afterMessages.length}');

      final afterToolResults = afterMessages
          .where((m) => m.type == 'functionResult' || (m.role == 'tool'))
          .toList();
      final afterAssistantWithTools = afterMessages
          .where((m) =>
              m.role == 'assistant' &&
              m.toolCalls != null &&
              m.toolCalls!.isNotEmpty)
          .toList();

      print('  [第三阶段] functionResult 消息数: ${afterToolResults.length}');
      print('  [第三阶段] 含 toolCalls 的 assistant 消息数: ${afterAssistantWithTools.length}');

      // --- 断言 1: 消息总数一致 ---
      expect(afterMessages.length, equals(beforeMessages.length),
          reason: '重启后消息总数应与重启前一致');

      // --- 断言 2: functionResult 消息数量一致 ---
      expect(afterToolResults.length, equals(beforeToolResults.length),
          reason: '重启后 functionResult 消息数量应一致');

      // --- 断言 3: assistant 消息的 toolCalls 数量一致 ---
      expect(afterAssistantWithTools.length, equals(beforeAssistantWithTools.length),
          reason: '重启后含 toolCalls 的 assistant 消息数量应一致');

      // --- 断言 4: 每个 functionResult 消息的 toolName 不为空且不为 unknown ---
      for (final msg in afterToolResults) {
        print('  [验证] functionResult: toolName=${msg.toolName}, '
            'toolCallId=${msg.toolCallId}, type=${msg.type}');

        expect(msg.toolName, isNotEmpty,
            reason: 'functionResult 消息的 toolName 不应为空');
        expect(msg.toolName, isNot(equals('unknown')),
            reason: 'functionResult 消息的 toolName 不应为 "unknown"');
        expect(msg.toolCallId, isNotEmpty,
            reason: 'functionResult 消息的 toolCallId 不应为空');
      }

      // --- 断言 5: assistant 消息的 toolCalls 内容正确 ---
      for (final msg in afterAssistantWithTools) {
        print('  [验证] assistant(toolCalls): toolCalls count=${msg.toolCalls!.length}');
        for (final tc in msg.toolCalls!) {
          print('    - id=${tc.id}, name=${tc.name}');
          expect(tc.id, isNotEmpty, reason: 'toolCall.id 不应为空');
          expect(tc.name, isNotEmpty, reason: 'toolCall.name 不应为空');
          expect(tc.name, isNot(equals('unknown')),
              reason: 'toolCall.name 不应为 "unknown"');
        }
      }

      // --- 断言 6: toolCallId 匹配（assistant.toolCalls[].id == functionResult.toolCallId） ---
      for (final assistant in afterAssistantWithTools) {
        for (final tc in assistant.toolCalls!) {
          final matchingResult = afterToolResults.any(
              (r) => r.toolCallId == tc.id);
          expect(matchingResult, isTrue,
              reason: 'assistant toolCall(id=${tc.id}) 应有对应的 functionResult 消息');
        }
      }

      print('  [通过]\n');
    });

    test('重启后直接从 Hive 读取的消息 entity 字段正确', () async {
      print('\n--- 测试：直接从 Hive 验证 entity 字段 ---');

      // === 第一阶段：发送消息 ===
      final adapter1 = createAdapter();
      await buildAgentStack(adapter1);

      final idleFuture1 = waitForIdle();
      await cachedProxy.sendMessage(MessageInput(
        content: '请读取 pubspec.yaml 文件的前5行',
      ));
      await idleFuture1;

      // dispose 第一阶段
      await cachedProxy.dispose();
      await localProxy.dispose();
      await agent.dispose();

      // === 第二阶段：直接从 Hive 读取 entity ===
      final entities = await messageStore.getMessagesWithDeviceId(
        deviceId,
        employeeId,
      );

      print('  Hive 中存储的消息数: ${entities.length}');

      final toolResultEntities = entities
          .where((e) => e.type == 'functionResult')
          .toList();
      final assistantWithToolsEntities = entities
          .where((e) =>
              e.role == 'assistant' &&
              e.toolCalls != null &&
              e.toolCalls!.isNotEmpty)
          .toList();

      print('  functionResult entities: ${toolResultEntities.length}');
      print('  assistant(toolCalls) entities: ${assistantWithToolsEntities.length}');

      expect(toolResultEntities.isNotEmpty, isTrue,
          reason: 'Hive 中应有 functionResult 消息');

      // 验证 entity 级别的字段
      for (final entity in toolResultEntities) {
        print('  [entity] uuid=${entity.uuid}, role=${entity.role}, '
            'type=${entity.type}, toolName=${entity.toolName}, '
            'toolCallId=${entity.toolCallId}');

        expect(entity.type, equals('functionResult'),
            reason: 'entity.type 应为 functionResult');
        expect(entity.toolName, isNotEmpty,
            reason: 'entity.toolName 不应为空');
        expect(entity.toolName, isNot(equals('unknown')),
            reason: 'entity.toolName 不应为 "unknown"');
        expect(entity.toolCallId, isNotEmpty,
            reason: 'entity.toolCallId 不应为空');
        expect(entity.content, isNotEmpty,
            reason: 'entity.content 不应为空（应有工具执行结果）');

        // 验证 toMessageMap() 还原后仍包含关键字段
        final restoredMap = entity.toMessageMap();
        expect(restoredMap['type'], equals('functionResult'),
            reason: 'toMessageMap() 还原的 type 应为 functionResult');
        expect(restoredMap['toolName'], isNotEmpty,
            reason: 'toMessageMap() 还原的 toolName 不应为空');
        expect(restoredMap['toolCallId'], isNotEmpty,
            reason: 'toMessageMap() 还原的 toolCallId 不应为空');
      }

      // 验证 assistant entity 的 toolCalls
      for (final entity in assistantWithToolsEntities) {
        print('  [entity] assistant: toolCalls=${entity.toolCalls}');

        // toolCalls 应为 JSON 字符串
        expect(entity.toolCalls, isNotEmpty,
            reason: 'entity.toolCalls 不应为空');
      }

      print('  [通过]\n');
    });

    test('多轮工具调用后重启，所有工具消息均正确恢复', () async {
      print('\n--- 测试：多轮工具调用重启恢复 ---');

      // === 第一阶段：发送两轮消息 ===
      final adapter1 = createAdapter();
      await buildAgentStack(adapter1);

      // 第一轮
      var idleFuture = waitForIdle();
      await cachedProxy.sendMessage(MessageInput(
        content: '请列出 lib 目录下的文件',
      ));
      await idleFuture;
      print('  [第一轮] 完成');

      // 第二轮
      idleFuture = waitForIdle();
      await cachedProxy.sendMessage(MessageInput(
        content: '请读取 pubspec.yaml 文件',
      ));
      await idleFuture;
      print('  [第二轮] 完成');

      final beforeMessages = await cachedProxy.getMessages();
      final beforeToolResults = beforeMessages
          .where((m) => m.type == 'functionResult' || m.role == 'tool')
          .toList();

      print('  [重启前] 总消息: ${beforeMessages.length}, '
          '工具结果: ${beforeToolResults.length}');

      // === 重启 ===
      await cachedProxy.dispose();
      await localProxy.dispose();
      await agent.dispose();

      final adapter2 = createAdapter();
      await buildAgentStack(adapter2);
      await Future.delayed(const Duration(milliseconds: 500));

      // === 验证 ===
      final afterMessages = await cachedProxy.getMessages();
      final afterToolResults = afterMessages
          .where((m) => m.type == 'functionResult' || m.role == 'tool')
          .toList();

      print('  [重启后] 总消息: ${afterMessages.length}, '
          '工具结果: ${afterToolResults.length}');

      expect(afterMessages.length, equals(beforeMessages.length));
      expect(afterToolResults.length, equals(beforeToolResults.length));
      expect(afterToolResults.length, greaterThanOrEqualTo(2),
          reason: '两轮工具调用后应至少有 2 条 functionResult');

      // 每条 functionResult 都有正确的 toolName
      for (final msg in afterToolResults) {
        expect(msg.toolName, isNotEmpty,
            reason: '${msg.id}: toolName 不应为空');
        expect(msg.toolName, isNot(equals('unknown')),
            reason: '${msg.id}: toolName 不应为 "unknown"');
        expect(msg.toolCallId, isNotEmpty,
            reason: '${msg.id}: toolCallId 不应为空');
        print('  [OK] ${msg.toolName}(id=${msg.toolCallId})');
      }

      print('  [通过]\n');
    });
  });

  print('\n=== 工具消息重启恢复测试完成 ===\n');
}
