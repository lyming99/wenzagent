// ============================================================================
// AgentProxy 完整场景测试
// ============================================================================
//
// 模拟真实使用场景，测试 AgentProxy + CachedAgentProxy 的端到端行为：
//
// 1. 完整对话流程（发送→处理→工具调用→回复→完成）
// 2. 消息同步高级场景（水位线、clearSeq、批量同步、跨设备去重）
// 3. 状态同步（状态机转换、多事件并发、状态恢复）
// 4. 异常和边界场景（RPC 失败、dispose 后操作、并发安全）
//
// 使用 mock RPC 回调模拟远程 Agent，无需真实 LLM 或网络连接。
// ============================================================================

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/client/cached_agent_proxy.dart';
import 'package:wenzagent/src/agent/entity/agent_event.dart';
import 'package:wenzagent/src/agent/entity/agent_message.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/agent/entity/message_input.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/service/message_store_service.dart';
import 'package:wenzagent/src/shared/chat_message.dart' show ToolCall;

void main() {
  // ===========================================================================
  // 测试基础设施
  // ===========================================================================

  late String employeeId;
  late String deviceId;
  late MessageStoreServiceImpl messageStore;
  late String tempDir;

  setUp(() async {
    employeeId = 'emp-${const Uuid().v4().substring(0, 8)}';
    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';
    // 创建临时目录用于数据库存储
    tempDir = Directory.systemTemp.path;
    // 初始化 DatabaseManager
    final dbManager = DatabaseManager.getInstance(deviceId);
    await dbManager.initialize(storagePath: tempDir);
    messageStore = MessageStoreServiceImpl(deviceId: deviceId);
  });

  tearDown(() async {
    try {
      await messageStore.deleteMessages(deviceId, employeeId);
    } catch (_) {}
    messageStore.dispose();
    DatabaseManager.removeInstance(deviceId);
  });

  // ===========================================================================
  // 1. 完整对话流程
  // ===========================================================================

  group('完整对话流程', () {
    test('用户发送消息 → Agent 处理 → 工具调用 → 回复 → 完成', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final messageEvents = <AgentEvent>[];
      final stateSnapshots = <AgentStateSnapshot>[];

      // 模拟远程 Agent 的消息序列号
      var nextSeq = 1;

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentGetMaxSeq':
              return {'maxSeq': nextSeq - 1};
            case 'agentGetMinSeq':
              return {'minSeq': 1};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              // 返回空列表（消息通过事件流同步）
              return {'messages': []};
            case 'agentGetState':
              return AgentStateSnapshot.idle().toMap();
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
        remoteEventStream: eventController.stream,
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      // 监听消息变更和状态变更
      cachedProxy.onMessagesChanged.listen((msgs) {
        // 消息变更通知
      });
      proxy.onStateChanged.listen((snapshot) {
        stateSnapshots.add(snapshot);
      });
      proxy.onEvent.listen((event) {
        messageEvents.add(event);
      });

      await cachedProxy.initialize();

      // ---- Step 1: 用户发送消息 ----
      final userMsgId = await cachedProxy.sendMessage(
        MessageInput(content: '请帮我查看 /tmp/test.txt 的内容'),
      );

      // 验证本地消息立即可见
      var messages = await cachedProxy.getMessages();
      expect(messages.length, equals(1));
      expect(messages[0].id, equals(userMsgId));
      expect(messages[0].role, equals('user'));
      // _updateMessageStatus 是 fire-and-forget，需要等待异步完成
      await Future.delayed(const Duration(milliseconds: 50));
      messages = await cachedProxy.getMessages();
      // 注意：_chatMessageToAgentMessage 不映射 'none' 状态，所以本地消息的 status 为 null
      // 当 _updateMessageStatus 异步更新后，状态变为 'sent'
      expect(messages[0].status == 'sent' || messages[0].status == null, isTrue);

      // ---- Step 2: Agent 开始处理 ----
      eventController.add(AgentEvent(
        type: AgentEventType.messageStarted,
        data: {'messageId': userMsgId},
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      expect(cachedProxy.currentProcessingMessageId, equals(userMsgId));

      // 消息状态更新为 processing
      eventController.add(AgentEvent(
        type: AgentEventType.messageStatusChanged,
        data: {'messageId': userMsgId, 'status': 'processing'},
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      messages = await cachedProxy.getMessages();
      final userMsg = messages.firstWhere((m) => m.id == userMsgId);
      expect(userMsg.status, equals('processing'));

      // ---- Step 3: Agent 状态变为 processing ----
      eventController.add(AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {
          'status': 'processing',
          'currentProcessingMessageId': userMsgId,
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      // ---- Step 4: 工具调用开始 ----
      eventController.add(AgentEvent(
        type: AgentEventType.toolCallStart,
        data: {
          'toolCallId': 'call-read-001',
          'toolName': 'read_file',
          'arguments': {'path': '/tmp/test.txt'},
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();
      await _pumpEventQueue(); // 等待去抖通知

      // 验证工具调用消息已创建
      messages = await cachedProxy.getMessages();
      final toolMsgs = messages.where(
        (m) => m.type == 'functionCall' && m.toolCallId == 'call-read-001',
      );
      expect(toolMsgs.length, equals(1));
      expect(toolMsgs.first.toolName, equals('read_file'));
      expect(toolMsgs.first.status, equals('processing'));
      expect(cachedProxy.callingToolIds, contains('call-read-001'));

      // ---- Step 5: 工具调用完成 ----
      eventController.add(AgentEvent(
        type: AgentEventType.toolCallResult,
        data: {
          'toolCallId': 'call-read-001',
          'result': 'Hello World from test.txt',
          'isError': false,
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();
      await _pumpEventQueue();

      // 验证工具调用状态更新
      messages = await cachedProxy.getMessages();
      final updatedToolMsg = messages.firstWhere(
        (m) => m.toolCallId == 'call-read-001',
      );
      expect(updatedToolMsg.status, equals('completed'));
      expect(updatedToolMsg.toolResult, equals('Hello World from test.txt'));
      expect(cachedProxy.callingToolIds, isNot(contains('call-read-001')));

      // ---- Step 6: 流式输出（streamDelta 事件不修改缓存，仅透传） ----
      eventController.add(AgentEvent(
        type: AgentEventType.streamDelta,
        data: {
          'messageId': 'assistant-reply-001',
          'delta': '根据文件内容',
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      // streamDelta 不修改消息缓存
      messages = await cachedProxy.getMessages();
      expect(messages.where((m) => m.content == '根据文件内容'), isEmpty);

      // ---- Step 7: Agent 状态变为 streaming ----
      eventController.add(AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {
          'status': 'streaming',
          'currentProcessingMessageId': userMsgId,
          'isStreaming': true,
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      // ---- Step 8: 消息处理完成 ----
      eventController.add(AgentEvent(
        type: AgentEventType.messageStatusChanged,
        data: {'messageId': userMsgId, 'status': 'completed'},
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      // ---- Step 9: Agent 回到空闲 ----
      eventController.add(AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {'status': 'idle'},
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      expect(cachedProxy.currentProcessingMessageId, isNull);
      expect(cachedProxy.queuedMessageIds, isEmpty);

      // 验证用户消息状态为 completed
      messages = await cachedProxy.getMessages();
      final completedMsg = messages.firstWhere((m) => m.id == userMsgId);
      expect(completedMsg.status, equals('completed'));

      // 验证事件流收到了所有事件
      expect(messageEvents.length, greaterThanOrEqualTo(6));

      await cachedProxy.dispose();
      await proxy.dispose();
      await eventController.close();
    });

    test('多轮对话：连续发送多条消息并依次处理', () async {
      final eventController = StreamController<AgentEvent>.broadcast();

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
        remoteEventStream: eventController.stream,
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 发送 3 条消息
      final msgIds = <String>[];
      for (int i = 0; i < 3; i++) {
        final id = await cachedProxy.sendMessage(
          MessageInput(content: 'Question $i'),
        );
        msgIds.add(id);
        await Future.delayed(const Duration(milliseconds: 10));
      }

      // 验证 3 条消息都在本地
      var messages = await cachedProxy.getMessages();
      expect(messages.length, equals(3));

      // 模拟 Agent 依次处理每条消息
      for (int i = 0; i < 3; i++) {
        // 开始处理
        eventController.add(AgentEvent(
          type: AgentEventType.messageStarted,
          data: {'messageId': msgIds[i]},
          employeeId: employeeId,
        ));
        await _pumpEventQueue();

        // 排队中：后面的消息排队
        if (i < 2) {
          eventController.add(AgentEvent(
            type: AgentEventType.agentStatusChanged,
            data: {
              'status': 'processing',
              'currentProcessingMessageId': msgIds[i],
              'queuedMessageIds': msgIds.sublist(i + 1),
            },
            employeeId: employeeId,
          ));
          await _pumpEventQueue();

          // 验证排队消息
          expect(cachedProxy.queuedMessageIds.length, equals(2 - i));
        }

        // 完成
        eventController.add(AgentEvent(
          type: AgentEventType.messageStatusChanged,
          data: {'messageId': msgIds[i], 'status': 'completed'},
          employeeId: employeeId,
        ));
        await _pumpEventQueue();
      }

      // Agent 空闲
      eventController.add(AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {'status': 'idle'},
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      // 验证所有消息都已完成
      messages = await cachedProxy.getMessages();
      for (final id in msgIds) {
        final msg = messages.firstWhere((m) => m.id == id);
        expect(msg.status, equals('completed'));
      }

      await cachedProxy.dispose();
      await proxy.dispose();
      await eventController.close();
    });

    test('权限请求 → 用户授权 → 继续执行', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      String? rpcCalledMethod;
      Map<String, dynamic>? rpcCalledParams;

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          rpcCalledMethod = method;
          rpcCalledParams = params;
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentRespondPermission':
              return <String, dynamic>{};
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
        remoteEventStream: eventController.stream,
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // Agent 发起权限请求
      eventController.add(AgentEvent(
        type: AgentEventType.toolPermissionRequest,
        data: {
          'requestId': 'perm-scenario-001',
          'type': 'tool',
          'description': '执行命令: rm -rf /tmp/old_cache',
          'functionName': 'execute_command',
          'permissionArgKey': 'command',
          'permissionArgValue': 'rm -rf /tmp/old_cache',
          'suggestedPattern': 'rm -rf /tmp/*',
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      // 验证权限请求已缓存
      final permRequest = cachedProxy.getPendingPermissionRequest();
      expect(permRequest, isNotNull);
      expect(permRequest!.requestId, equals('perm-scenario-001'));
      expect(permRequest.functionName, equals('execute_command'));
      expect(permRequest.permissionArgValue, equals('rm -rf /tmp/old_cache'));

      // 用户授权
      await cachedProxy.respondToPermission(
        'perm-scenario-001',
        PermissionDecision.allow,
        scope: PermissionApprovalScope.once,
      );

      // 验证 RPC 被调用（实际 RPC 方法名带 agent 前缀）
      expect(rpcCalledMethod, equals('agentRespondPermission'));
      expect(rpcCalledParams!['requestId'], equals('perm-scenario-001'));
      expect(rpcCalledParams!['decision'], equals('allow'));

      // 验证缓存已清除
      expect(cachedProxy.getPendingPermissionRequest(), isNull);

      await cachedProxy.dispose();
      await proxy.dispose();
      await eventController.close();
    });

    test('确认请求 → 用户选择 → 继续执行', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      String? rpcCalledMethod;
      Map<String, dynamic>? rpcCalledParams;

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          rpcCalledMethod = method;
          rpcCalledParams = params;
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentRespondConfirm':
              return <String, dynamic>{};
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
        remoteEventStream: eventController.stream,
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // Agent 发起确认请求
      eventController.add(AgentEvent(
        type: AgentEventType.confirmRequest,
        data: {
          'requestId': 'confirm-scenario-001',
          'title': '请选择部署方案',
          'message': '选择 Docker 还是 K8s 部署？',
          'options': [
            {'key': 'docker', 'label': 'Docker 部署', 'description': '简单快速'},
            {'key': 'k8s', 'label': 'K8s 部署', 'description': '高可用'},
          ],
          'defaultOption': 'docker',
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      // 验证确认请求已缓存
      final confirmRequest = cachedProxy.getPendingConfirmRequest();
      expect(confirmRequest, isNotNull);
      expect(confirmRequest!.requestId, equals('confirm-scenario-001'));
      expect(confirmRequest.title, equals('请选择部署方案'));
      expect(confirmRequest.options.length, equals(2));
      expect(confirmRequest.defaultOption, equals('docker'));

      // 用户选择
      await cachedProxy.respondToConfirm('confirm-scenario-001', 'k8s');

      // 验证 RPC 被调用（实际 RPC 方法名带 agent 前缀）
      expect(rpcCalledMethod, equals('agentRespondConfirm'));
      expect(rpcCalledParams!['requestId'], equals('confirm-scenario-001'));
      expect(rpcCalledParams!['selectedOption'], equals('k8s'));

      // 验证缓存已清除
      expect(cachedProxy.getPendingConfirmRequest(), isNull);

      await cachedProxy.dispose();
      await proxy.dispose();
      await eventController.close();
    });

    test('工具调用失败 → 权限拒绝 → interrupted', () async {
      final eventController = StreamController<AgentEvent>.broadcast();

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
        remoteEventStream: eventController.stream,
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 工具调用开始
      eventController.add(AgentEvent(
        type: AgentEventType.toolCallStart,
        data: {
          'toolCallId': 'call-denied-001',
          'toolName': 'execute_command',
          'arguments': {'command': 'rm -rf /'},
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();
      await _pumpEventQueue();

      // 工具调用被权限拒绝
      eventController.add(AgentEvent(
        type: AgentEventType.toolCallResult,
        data: {
          'toolCallId': 'call-denied-001',
          'result': '权限被拒绝: 危险命令 rm -rf /',
          'isError': true,
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();
      await _pumpEventQueue();

      // 验证工具调用状态为 interrupted
      var messages = await cachedProxy.getMessages();
      var toolMsg = messages.firstWhere(
        (m) => m.toolCallId == 'call-denied-001',
      );
      expect(toolMsg.status, equals('interrupted'));
      expect(toolMsg.toolResult, contains('权限被拒绝'));

      await cachedProxy.dispose();
      await proxy.dispose();
      await eventController.close();
    });

    test('消息处理失败 → 创建错误消息', () async {
      final eventController = StreamController<AgentEvent>.broadcast();

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
        remoteEventStream: eventController.stream,
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 发送消息
      final msgId = await cachedProxy.sendMessage(
        MessageInput(content: 'trigger error'),
      );

      // 消息处理失败
      eventController.add(AgentEvent(
        type: AgentEventType.messageStatusChanged,
        data: {
          'messageId': msgId,
          'status': 'failed',
          'error': 'LLM API 调用超时 (30s)',
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();
      await _pumpEventQueue();

      // 验证原始消息状态为 failed
      var messages = await cachedProxy.getMessages();
      final failedMsg = messages.firstWhere((m) => m.id == msgId);
      expect(failedMsg.status, equals('failed'));

      // 验证创建了错误消息
      final errorMsg = messages.where(
        (m) => m.type == 'error' && m.id == 'error_$msgId',
      );
      expect(errorMsg.length, equals(1));
      expect(errorMsg.first.content, contains('LLM API 调用超时'));
      expect(errorMsg.first.role, equals('assistant'));

      await cachedProxy.dispose();
      await proxy.dispose();
      await eventController.close();
    });
  });

  // ===========================================================================
  // 2. 消息同步高级场景
  // ===========================================================================

  group('消息同步高级场景', () {
    test('批量消息同步：一次拉取超过 batchSize 的消息', () async {
      // 创建 30 条远程消息（超过默认 batchSize=20）
      final remoteMessages = List.generate(
        30,
        (i) => _createRemoteMessage(
          id: 'batch-msg-${i.toString().padLeft(3, '0')}',
          role: i % 2 == 0 ? 'user' : 'assistant',
          content: 'Batch message $i',
          seq: i + 1,
        ),
      );

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentGetMaxSeq':
              return {'maxSeq': 30};
            case 'agentGetMinSeq':
              return {'minSeq': 1};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              final lastSeq = params['lastSeq'] as int? ?? 0;
              final limit = params['limit'] as int? ?? 20;
              // 返回 seq > lastSeq 的消息，最多 limit 条
              final filtered = remoteMessages
                  .where((m) => (m.metadata?['seq'] as int? ?? 0) > lastSeq)
                  .take(limit)
                  .toList();
              return {'messages': filtered.map((m) => m.toMap()).toList()};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();
      await cachedProxy.syncFromRemote();

      // 验证所有 30 条消息都已同步
      final messages = await cachedProxy.getMessages();
      expect(messages.length, equals(30));

      // 验证按时间正序排列
      for (int i = 0; i < messages.length - 1; i++) {
        expect(
          messages[i].createdAt.isBefore(messages[i + 1].createdAt) ||
              messages[i].createdAt.isAtSameMomentAs(messages[i + 1].createdAt),
          isTrue,
        );
      }

      await cachedProxy.dispose();
      await proxy.dispose();
    });

    test('clearSeq 清理：远程清空后本地旧消息被删除', () async {
      // 先同步 5 条消息
      final initialMessages = List.generate(
        5,
        (i) => _createRemoteMessage(
          id: 'clearseq-msg-$i',
          role: 'user',
          content: 'Message $i',
          seq: i + 1,
        ),
      );

      var clearSeqResponse = 0;

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentGetMaxSeq':
              return {'maxSeq': 5};
            case 'agentGetMinSeq':
              return {'minSeq': 1};
            case 'agentGetClearSeq':
              return {'clearSeq': clearSeqResponse};
            case 'agentGetMessagesAfterSeq':
              final lastSeq = params['lastSeq'] as int? ?? 0;
              if (lastSeq == 0) {
                return {
                  'messages': initialMessages.map((m) => m.toMap()).toList(),
                };
              }
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();
      await cachedProxy.syncFromRemote();

      var messages = await cachedProxy.getMessages();
      expect(messages.length, equals(5));

      // 模拟远程清空会话（设置 clearSeq = 6，大于所有消息的 seq）
      clearSeqResponse = 6;

      // 第二次同步：clearSeq=6 应该删除所有 seq < 6 的消息
      await cachedProxy.syncWithRemote();

      messages = await cachedProxy.getMessages();
      expect(messages.length, equals(0));

      await cachedProxy.dispose();
      await proxy.dispose();
    });

    test('跨设备消息去重：本地发送的消息与远程同步不重复', () async {
      final localMsgId = const Uuid().v4();
      var syncPhase = 0;

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentGetMaxSeq':
              return {'maxSeq': syncPhase >= 1 ? 1 : 0};
            case 'agentGetMinSeq':
              return {'minSeq': syncPhase >= 1 ? 1 : 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              if (syncPhase >= 1) {
                // 远程返回同一条消息（相同 ID）
                return {
                  'messages': [
                    _createRemoteMessage(
                      id: localMsgId,
                      role: 'user',
                      content: 'Same message',
                      seq: 1,
                      status: 'completed',
                    ).toMap(),
                  ],
                };
              }
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 本地发送消息
      await cachedProxy.sendMessage(
        MessageInput(content: 'Same message', id: localMsgId),
      );

      var messages = await cachedProxy.getMessages();
      expect(messages.length, equals(1));

      // 远程同步返回同一条消息（相同 ID）
      syncPhase = 1;
      await cachedProxy.syncWithRemote();

      // 消息不应重复
      messages = await cachedProxy.getMessages();
      expect(messages.length, equals(1));

      // 消息状态应被远程版本更新（completed）
      final msg = messages.firstWhere((m) => m.id == localMsgId);
      expect(msg.status, equals('completed'));

      await cachedProxy.dispose();
      await proxy.dispose();
    });

    test('多次增量同步逐步拉取新消息', () async {
      // 模拟远程不断有新消息
      var remoteSeq = 0;
      final allRemoteMessages = <AgentMessage>[];

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentGetMaxSeq':
              return {'maxSeq': remoteSeq};
            case 'agentGetMinSeq':
              return {'minSeq': 1};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              final lastSeq = params['lastSeq'] as int? ?? 0;
              final newMsgs = allRemoteMessages
                  .where(
                    (m) => (m.metadata?['seq'] as int? ?? 0) > lastSeq,
                  )
                  .toList();
              return {'messages': newMsgs.map((m) => m.toMap()).toList()};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 第一轮：远程有 3 条消息
      for (int i = 1; i <= 3; i++) {
        allRemoteMessages.add(_createRemoteMessage(
          id: 'round1-msg-$i',
          role: i % 2 == 0 ? 'assistant' : 'user',
          content: 'Round 1 message $i',
          seq: i,
        ));
        remoteSeq = i;
      }

      await cachedProxy.syncFromRemote();
      var messages = await cachedProxy.getMessages();
      expect(messages.length, equals(3));

      // 第二轮：远程新增 2 条消息
      for (int i = 4; i <= 5; i++) {
        allRemoteMessages.add(_createRemoteMessage(
          id: 'round2-msg-$i',
          role: i % 2 == 0 ? 'assistant' : 'user',
          content: 'Round 2 message $i',
          seq: i,
        ));
        remoteSeq = i;
      }

      await cachedProxy.syncWithRemote();
      messages = await cachedProxy.getMessages();
      expect(messages.length, equals(5));
      expect(messages.last.content, equals('Round 2 message 5'));

      // 第三轮：无新消息
      await cachedProxy.syncWithRemote();
      messages = await cachedProxy.getMessages();
      expect(messages.length, equals(5));

      await cachedProxy.dispose();
      await proxy.dispose();
    });

    test('工具调用临时消息被远程同步消息取代后清理', () async {
      final eventController = StreamController<AgentEvent>.broadcast();

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentGetMaxSeq':
              return {'maxSeq': 2};
            case 'agentGetMinSeq':
              return {'minSeq': 1};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              // 返回包含 toolCalls 的 assistant 消息
              return {
                'messages': [
                  {
                    'id': 'assistant-with-tools',
                    'role': 'assistant',
                    'type': 'text',
                    'content': 'I will read the file.',
                    'createdAt': DateTime.now().toIso8601String(),
                    'toolCalls': [
                      {
                        'id': 'call-cleanup-001',
                        'name': 'read_file',
                        'arguments': {'path': '/tmp/test.txt'},
                      },
                    ],
                    'metadata': {
                      'seq': 1,
                      'updateTime': DateTime.now().toIso8601String(),
                    },
                  },
                  {
                    'id': 'tool-result-msg',
                    'role': 'tool',
                    'type': 'functionResult',
                    'content': 'File content here',
                    'toolCallId': 'call-cleanup-001',
                    'createdAt': DateTime.now().toIso8601String(),
                    'metadata': {
                      'seq': 2,
                      'updateTime': DateTime.now().toIso8601String(),
                    },
                  },
                ],
              };
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
        remoteEventStream: eventController.stream,
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 先创建本地工具调用临时消息
      eventController.add(AgentEvent(
        type: AgentEventType.toolCallStart,
        data: {
          'toolCallId': 'call-cleanup-001',
          'toolName': 'read_file',
          'arguments': {'path': '/tmp/test.txt'},
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();
      await _pumpEventQueue();

      // 验证临时消息已创建
      var messages = await cachedProxy.getMessages();
      final localToolMsgs = messages.where(
        (m) => m.id == 'local_toolcall_call-cleanup-001',
      );
      expect(localToolMsgs.length, equals(1));

      // 远程同步：返回包含相同 toolCallId 的消息
      await cachedProxy.syncWithRemote();
      await _pumpEventQueue();

      // 本地临时消息应被清理
      messages = await cachedProxy.getMessages();
      final cleanedMsgs = messages.where(
        (m) => m.id == 'local_toolcall_call-cleanup-001',
      );
      expect(cleanedMsgs.length, equals(0));

      // 远程消息应存在
      final remoteToolMsgs = messages.where(
        (m) => m.toolCallId == 'call-cleanup-001',
      );
      expect(remoteToolMsgs.length, equals(1));

      await cachedProxy.dispose();
      await proxy.dispose();
      await eventController.close();
    });
  });

  // ===========================================================================
  // 3. 状态同步
  // ===========================================================================

  group('状态同步', () {
    test('完整状态机转换：idle → processing → streaming → waitingPermission → idle',
        () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final stateHistory = <String>[];

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            case 'agentGetPendingPermission':
              return <String, dynamic>{};
            case 'agentGetPendingConfirm':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
        remoteEventStream: eventController.stream,
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      proxy.onStateChanged.listen((snapshot) {
        stateHistory.add(snapshot.status.name);
      });

      await cachedProxy.initialize();

      // idle → processing
      eventController.add(AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {
          'status': 'processing',
          'currentProcessingMessageId': 'msg-001',
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      // processing → streaming
      eventController.add(AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {
          'status': 'streaming',
          'currentProcessingMessageId': 'msg-001',
          'isStreaming': true,
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      // streaming → waitingPermission
      eventController.add(AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {
          'status': 'waitingPermission',
          'currentProcessingMessageId': 'msg-001',
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      // waitingPermission → idle
      eventController.add(AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {'status': 'idle'},
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      // 验证状态缓存
      expect(cachedProxy.currentProcessingMessageId, isNull);
      expect(cachedProxy.queuedMessageIds, isEmpty);

      await cachedProxy.dispose();
      await proxy.dispose();
      await eventController.close();
    });

    test('多事件并发：快速连续发送多个事件', () async {
      final eventController = StreamController<AgentEvent>.broadcast();

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
        remoteEventStream: eventController.stream,
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 快速连续发送 10 个工具调用开始事件
      for (int i = 0; i < 10; i++) {
        eventController.add(AgentEvent(
          type: AgentEventType.toolCallStart,
          data: {
            'toolCallId': 'rapid-call-$i',
            'toolName': 'tool_$i',
          },
          employeeId: employeeId,
        ));
      }

      // 快速连续发送 10 个工具调用完成事件
      for (int i = 0; i < 10; i++) {
        eventController.add(AgentEvent(
          type: AgentEventType.toolCallResult,
          data: {
            'toolCallId': 'rapid-call-$i',
            'result': 'done $i',
            'isError': false,
          },
          employeeId: employeeId,
        ));
      }

      // 等待所有事件处理完成
      await Future.delayed(const Duration(milliseconds: 500));

      // 验证所有工具调用都已完成
      expect(cachedProxy.callingToolIds, isEmpty);

      // 验证所有工具调用消息都已创建
      final messages = await cachedProxy.getMessages();
      final toolMsgs = messages.where((m) => m.type == 'functionCall');
      expect(toolMsgs.length, equals(10));

      // 验证所有工具调用消息状态为 completed
      for (final msg in toolMsgs) {
        expect(msg.status, equals('completed'));
      }

      await cachedProxy.dispose();
      await proxy.dispose();
      await eventController.close();
    });

    test('状态恢复：Agent 重启后状态正确重置', () async {
      final eventController = StreamController<AgentEvent>.broadcast();

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {'messages': []};
            case 'agentGetState':
              // Agent 重启后返回 idle 状态
              return AgentStateSnapshot.idle().toMap();
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
        remoteEventStream: eventController.stream,
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 设置处理中状态
      eventController.add(AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {
          'status': 'processing',
          'currentProcessingMessageId': 'msg-restart-test',
          'queuedMessageIds': ['q-1', 'q-2'],
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      expect(cachedProxy.currentProcessingMessageId, equals('msg-restart-test'));
      expect(cachedProxy.queuedMessageIds.length, equals(2));

      // 模拟 Agent 重启：发送 idle 状态
      eventController.add(AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {'status': 'idle'},
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      // 验证状态已重置
      expect(cachedProxy.currentProcessingMessageId, isNull);
      expect(cachedProxy.queuedMessageIds, isEmpty);

      await cachedProxy.dispose();
      await proxy.dispose();
      await eventController.close();
    });

    test('配置变更事件同步：provider/project/context 变更', () async {
      final eventController = StreamController<AgentEvent>.broadcast();

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
        remoteEventStream: eventController.stream,
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // Provider 配置变更
      eventController.add(AgentEvent(
        type: AgentEventType.configChanged,
        data: {
          'configType': 'provider',
          'providerConfig': {
            'provider': 'anthropic',
            'apiKey': 'sk-ant-test',
            'model': 'claude-3.5-sonnet',
          },
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      final providerConfig = proxy.getProviderConfig();
      expect(providerConfig, isNotNull);
      expect(providerConfig!.model, equals('claude-3.5-sonnet'));

      // 项目变更
      eventController.add(AgentEvent(
        type: AgentEventType.configChanged,
        data: {
          'configType': 'project',
          'projectData': {
            'projectUuid': 'proj-config-test',
            'projectName': 'ConfigTest',
          },
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      expect(proxy.getCurrentProjectUuid(), equals('proj-config-test'));

      // Context 变更
      eventController.add(AgentEvent(
        type: AgentEventType.configChanged,
        data: {
          'configType': 'context',
          'contextData': {
            'projectRoot': '/home/user/project',
            'language': 'dart',
          },
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      final context = proxy.getCurrentContext();
      expect(context, isNotNull);
      expect(context!['language'], equals('dart'));

      // Provider 配置清除
      eventController.add(AgentEvent(
        type: AgentEventType.configChanged,
        data: {
          'configType': 'provider',
          'action': 'cleared',
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();

      expect(proxy.getProviderConfig(), isNull);

      await cachedProxy.dispose();
      await proxy.dispose();
      await eventController.close();
    });

    test('会话清空事件：远程清空后本地同步清理', () async {
      final eventController = StreamController<AgentEvent>.broadcast();

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
        remoteEventStream: eventController.stream,
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 发送多条消息
      for (int i = 0; i < 5; i++) {
        await cachedProxy.sendMessage(
          MessageInput(content: 'Before clear $i'),
        );
      }

      // 模拟权限请求
      eventController.add(AgentEvent(
        type: AgentEventType.toolPermissionRequest,
        data: {
          'requestId': 'perm-clear-test',
          'type': 'tool',
          'description': 'test',
          'functionName': 'test_tool',
        },
        employeeId: employeeId,
      ));
      await _pumpEventQueue();
      expect(cachedProxy.getPendingPermissionRequest(), isNotNull);

      var messages = await cachedProxy.getMessages();
      expect(messages.length, equals(5));

      // 远程清空会话
      eventController.add(AgentEvent(
        type: AgentEventType.sessionCleared,
        data: {},
        employeeId: employeeId,
      ));
      await _pumpEventQueue();
      await _pumpEventQueue();

      // 验证消息已清空
      messages = await cachedProxy.getMessages();
      expect(messages.length, equals(0));

      // 验证权限请求缓存已清空
      expect(cachedProxy.getPendingPermissionRequest(), isNull);

      await cachedProxy.dispose();
      await proxy.dispose();
      await eventController.close();
    });

    test('消息已读状态同步', () async {
      final eventController = StreamController<AgentEvent>.broadcast();

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentGetMaxSeq':
              return {'maxSeq': 3};
            case 'agentGetMinSeq':
              return {'minSeq': 1};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {
                'messages': [
                  _createRemoteMessage(
                    id: 'read-msg-1',
                    role: 'assistant',
                    content: 'Reply 1',
                    seq: 1,
                  ).toMap(),
                  _createRemoteMessage(
                    id: 'read-msg-2',
                    role: 'assistant',
                    content: 'Reply 2',
                    seq: 2,
                  ).toMap(),
                  _createRemoteMessage(
                    id: 'read-msg-3',
                    role: 'assistant',
                    content: 'Reply 3',
                    seq: 3,
                  ).toMap(),
                ],
              };
            case 'agentGetSessionSummary':
              return {
                'employee_id': employeeId,
                'device_id': deviceId,
                'unread_count': 3,
                'update_time': DateTime.now().millisecondsSinceEpoch,
              };
            default:
              return <String, dynamic>{};
          }
        },
        remoteEventStream: eventController.stream,
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();
      await cachedProxy.syncFromRemote();

      // 验证未读数（syncFromRemote 写入的消息 forceRead=false，所以未读）
      var unreadCount = await cachedProxy.getUnreadCount();
      expect(unreadCount, equals(3));

      // 模拟远程标记已读（基于 seq）
      // 直接调用 markAsReadBySeqInDb 而不是通过事件流
      messageStore.markAsReadBySeqInDb(deviceId, employeeId, 3);

      // 验证未读数已更新
      unreadCount = await cachedProxy.getUnreadCount();
      expect(unreadCount, equals(0));

      await cachedProxy.dispose();
      await proxy.dispose();
      await eventController.close();
    });
  });

  // ===========================================================================
  // 4. 异常和边界场景
  // ===========================================================================

  group('异常和边界场景', () {
    test('RPC 调用失败：sendMessage 抛出异常', () async {
      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          if (method == 'agentSendMessage') {
            throw Exception('Network timeout');
          }
          return <String, dynamic>{};
        },
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 发送消息应该抛出异常
      expect(
        () => cachedProxy.sendMessage(MessageInput(content: 'fail test')),
        throwsA(isA<Exception>()),
      );

      // 本地消息应该存在但状态为 failed
      await Future.delayed(const Duration(milliseconds: 50));
      final messages = await cachedProxy.getMessages();
      // 消息在发送前已写入本地，状态可能为 pending 或 failed
      // 由于 sendMessage 先写入本地再发送 RPC，RPC 失败后更新为 failed
      expect(messages.length, equals(1));
      expect(messages[0].status, equals('failed'));

      await cachedProxy.dispose();
      await proxy.dispose();
    });

    test('RPC 调用失败：同步消息时远程不可达', () async {
      var shouldFail = false;

      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          if (shouldFail) {
            throw Exception('Connection refused');
          }
          switch (method) {
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 第一次同步成功
      await cachedProxy.syncFromRemote();
      expect(cachedProxy.isDisposed, isFalse);

      // 第二次同步失败（远程不可达）
      shouldFail = true;
      // 不应抛出异常，而是内部处理错误
      await cachedProxy.syncWithRemote();
      expect(cachedProxy.isDisposed, isFalse);

      await cachedProxy.dispose();
      await proxy.dispose();
    });

    test('dispose 后操作不应崩溃', () async {
      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async => <String, dynamic>{},
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();
      await cachedProxy.dispose();

      // dispose 后调用不应崩溃
      expect(cachedProxy.isDisposed, isTrue);
      expect(cachedProxy.getPendingPermissionRequest(), isNull);
      expect(cachedProxy.getPendingConfirmRequest(), isNull);
      expect(cachedProxy.currentProcessingMessageId, isNull);
      expect(cachedProxy.queuedMessageIds, isEmpty);
      expect(cachedProxy.callingToolIds, isEmpty);

      await proxy.dispose();
    });

    test('并发初始化和同步', () async {
      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            case 'agentGetState':
              return AgentStateSnapshot.idle().toMap();
            default:
              return <String, dynamic>{};
          }
        },
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      // 并发初始化 + 同步
      await Future.wait([
        cachedProxy.initialize(),
        cachedProxy.initialize(),
        cachedProxy.initialize(),
        cachedProxy.syncFromRemote(),
        cachedProxy.syncWithRemote(),
      ]);

      expect(cachedProxy.isDisposed, isFalse);

      await cachedProxy.dispose();
      await proxy.dispose();
    });

    test('空内容和特殊字符消息', () async {
      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          return {'messageId': params['id'] ?? ''};
        },
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 空内容消息
      await cachedProxy.sendMessage(MessageInput(content: ''));
      // 特殊字符消息
      await cachedProxy.sendMessage(MessageInput(content: '你好世界 🌍\n\t\r<script>alert("xss")</script>'));
      // 超长消息
      await cachedProxy.sendMessage(MessageInput(content: 'A' * 10000));

      final messages = await cachedProxy.getMessages();
      expect(messages.length, equals(3));
      expect(messages[0].content, equals(''));
      expect(messages[1].content, contains('你好世界'));
      expect(messages[2].content!.length, equals(10000));

      await cachedProxy.dispose();
      await proxy.dispose();
    });

    test('多次 dispose 不崩溃', () async {
      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async => <String, dynamic>{},
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 多次 dispose 不崩溃
      await cachedProxy.dispose();
      await cachedProxy.dispose();
      await cachedProxy.dispose();

      expect(cachedProxy.isDisposed, isTrue);

      await proxy.dispose();
    });

    test('多个 CachedAgentProxy 共享同一 MessageStore', () async {
      final proxy1 = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          return {'messageId': params['id'] ?? ''};
        },
      );

      final proxy2 = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          return {'messageId': params['id'] ?? ''};
        },
      );

      final cachedProxy1 = CachedAgentProxy(
        proxy: proxy1,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      final cachedProxy2 = CachedAgentProxy(
        proxy: proxy2,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy1.initialize();
      await cachedProxy2.initialize();

      // 通过 proxy1 发送消息
      await cachedProxy1.sendMessage(MessageInput(content: 'From proxy1'));

      // proxy2 应该能看到（共享 MessageStore）
      final messages2 = await cachedProxy2.getMessages();
      expect(messages2.length, equals(1));
      expect(messages2[0].content, equals('From proxy1'));

      // 通过 proxy2 发送消息
      await cachedProxy2.sendMessage(MessageInput(content: 'From proxy2'));

      // proxy1 也应该能看到
      final messages1 = await cachedProxy1.getMessages();
      expect(messages1.length, equals(2));

      await cachedProxy1.dispose();
      await cachedProxy2.dispose();
      await proxy1.dispose();
      await proxy2.dispose();
    });

    test('撤回消息后本地数据库同步删除', () async {
      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentRevokeMessage':
              return <String, dynamic>{};
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 发送消息
      final msgId = await cachedProxy.sendMessage(
        MessageInput(content: 'To be revoked'),
      );

      var messages = await cachedProxy.getMessages();
      expect(messages.length, equals(1));

      // 撤回消息
      await cachedProxy.revokeMessage(msgId);

      // 验证消息已从本地删除
      messages = await cachedProxy.getMessages();
      expect(messages.length, equals(0));

      await cachedProxy.dispose();
      await proxy.dispose();
    });

    test('clearCurrentSession 完整清空', () async {
      final proxy = AgentProxy.remote(
        employeeId: employeeId,
        deviceId: deviceId,
        rpcCall: (method, params) async {
          switch (method) {
            case 'agentSendMessage':
              return {'messageId': params['id'] ?? ''};
            case 'agentClearSession':
              return <String, dynamic>{};
            case 'agentGetMaxSeq':
              return {'maxSeq': 0};
            case 'agentGetMinSeq':
              return {'minSeq': 0};
            case 'agentGetClearSeq':
              return {'clearSeq': 0};
            case 'agentGetMessagesAfterSeq':
              return {'messages': []};
            case 'agentGetSessionSummary':
              return <String, dynamic>{};
            default:
              return <String, dynamic>{};
          }
        },
      );

      final cachedProxy = CachedAgentProxy(
        proxy: proxy,
        messageStore: messageStore,
        deviceId: deviceId,
        employeeId: employeeId,
      );

      await cachedProxy.initialize();

      // 发送多条消息
      for (int i = 0; i < 5; i++) {
        await cachedProxy.sendMessage(
          MessageInput(content: 'Session msg $i'),
        );
      }

      var messages = await cachedProxy.getMessages();
      expect(messages.length, equals(5));

      // 清空会话
      await cachedProxy.clearCurrentSession();

      messages = await cachedProxy.getMessages();
      expect(messages.length, equals(0));

      await cachedProxy.dispose();
      await proxy.dispose();
    });
  });
}

// =============================================================================
// 辅助方法
// =============================================================================

/// 创建远程消息（带 seq）
AgentMessage _createRemoteMessage({
  required String id,
  required String role,
  required String content,
  required int seq,
  String type = 'text',
  String? status,
}) {
  return AgentMessage(
    id: id,
    role: role,
    type: type,
    content: content,
    createdAt: DateTime.now().add(Duration(seconds: seq)),
    status: status,
    metadata: {
      'seq': seq,
      'updateTime': DateTime.now().toIso8601String(),
    },
  );
}

/// 等待事件队列处理完成
Future<void> _pumpEventQueue() async {
  await Future.delayed(Duration.zero);
  await Future.delayed(Duration.zero);
  await Future.delayed(const Duration(milliseconds: 50));
}
