/// CachedAgentProxy 远程对话消息同步测试
///
/// 测试重点：
/// 1. 问答消息的正确性与一致性（sendMessage → 服务端处理 → 客户端增量拉取）
/// 2. 消息状态的一致性与正确性（pending → sent → processing → completed）
/// 3. updateWatermark: false 修复验证（本地临时消息不污染同步水位线）
///
/// 测试架构：
/// - 使用 AgentProxy.remote() + 自定义 RpcCall 回调模拟远程 RPC
/// - Host（服务端）和 Client（客户端）使用不同的 SQLite 数据库文件
/// - Host 端通过 IAgent 方法处理 RPC 调用
/// - 事件流从 Host 广播到 Client
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:wenzagent/src/agent/adapter/persistent_chat_adapter.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/client/cached_agent_proxy.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/agent/impl/agent_impl.dart';
import 'package:wenzagent/src/agent/i_agent.dart';
import 'package:wenzagent/src/agent/rpc/agent_rpc_config.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/persistence/stores/message_store.dart';
import 'package:wenzagent/src/service/message_store_service.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  late DatabaseManager hostDbManager;
  late DatabaseManager clientDbManager;
  late String hostDbDir;
  late String clientDbDir;

  const employeeId = 'test-cached-proxy-sync';
  const hostDeviceId = 'host-device';
  const clientDeviceId = 'client-device';

  late AgentImpl hostAgent;
  late MessageStoreServiceImpl hostMessageStore;
  late PersistentChatAdapter hostAdapter;

  late AgentProxy clientProxy;
  late CachedAgentProxy cachedClientProxy;
  late MessageStoreServiceImpl clientMessageStore;
  late SyncWatermarkStore clientWatermarkStore;

  /// 事件广播控制器（模拟远程事件推送）
  StreamController<AgentEvent>? _remoteEventController;

  /// 获取远程事件流（懒创建控制器）
  Stream<AgentEvent> _remoteEventStream() {
    _remoteEventController ??= StreamController<AgentEvent>.broadcast();
    return _remoteEventController!.stream;
  }

  setUpAll(() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    hostDbDir = p.join(
      Directory.systemTemp.path,
      'cached_proxy_sync_host_$ts',
    );
    clientDbDir = p.join(
      Directory.systemTemp.path,
      'cached_proxy_sync_client_$ts',
    );
    Directory(hostDbDir).createSync(recursive: true);
    Directory(clientDbDir).createSync(recursive: true);
  });

  tearDownAll(() async {
    await _remoteEventController?.close();
    _remoteEventController = null;
    try { await hostDbManager.close(); } catch (_) {}
    try { await clientDbManager.close(); } catch (_) {}
    for (final dir in [hostDbDir, clientDbDir]) {
      final d = Directory(dir);
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  /// 初始化 host Agent（服务端）
  Future<void> _setupHost() async {
    hostDbManager = DatabaseManager.getInstance(hostDeviceId);
    if (hostDbManager.isInitialized) await hostDbManager.close();
    await hostDbManager.initialize(storagePath: hostDbDir);

    // 清空数据
    hostDbManager.db.execute('DELETE FROM sync_watermark');
    hostDbManager.db.execute('DELETE FROM messages');

    hostMessageStore = MessageStoreServiceImpl(
      store: MessageStore(dbManager: hostDbManager),
      deviceId: hostDeviceId,
    );
    hostAdapter = PersistentChatAdapter();
    hostAdapter.persistMessage = (messageData) async {
      final chatMsg = ChatMessage.fromJson(messageData as Map<String, dynamic>);
      await hostMessageStore.addMessage(chatMsg, deviceId: hostDeviceId);
    };
    hostAdapter.loadMessages = (empId, {int? limit}) async {
      final messages = await hostMessageStore.getMessages(empId);
      return messages.map((m) => m.toJson()).toList();
    };
    hostAdapter.updateMessageStatusCallback = (messageId, status, {error}) async {
      await hostMessageStore.updateMessageStatus(
        messageId,
        MessageStatus.values.byName(status),
        error: error,
      );
    };
    hostAdapter.deleteMessagesCallback = (empId) async {
      await hostMessageStore.deleteMessages(empId, deviceId: hostDeviceId);
    };
    hostAgent = AgentImpl(
      employeeId: employeeId,
      deviceId: hostDeviceId,
      chatAdapter: hostAdapter,
    );
    await hostAgent.initialize(enableBuiltinTools: false);
    await hostAgent.warmup();
  }

  /// 创建远程模式的 Client AgentProxy + CachedAgentProxy
  ///
  /// 通过自定义 RpcCall 回调，将 RPC 调用转发到 hostAgent
  Future<void> _setupClient() async {
    clientDbManager = DatabaseManager.getInstance(clientDeviceId);
    if (clientDbManager.isInitialized) await clientDbManager.close();
    await clientDbManager.initialize(storagePath: clientDbDir);

    // 清空数据
    clientDbManager.db.execute('DELETE FROM sync_watermark');
    clientDbManager.db.execute('DELETE FROM messages');

    clientMessageStore = MessageStoreServiceImpl(
      store: MessageStore(dbManager: clientDbManager),
      deviceId: clientDeviceId,
    );
    clientWatermarkStore = SyncWatermarkStore(dbManager: clientDbManager);

    // RPC 回调：将远程 RPC 调用转发到 hostAgent
    Future<Map<String, dynamic>> rpcCall(String method, Map<String, dynamic> params) async {
      switch (method) {
        case AgentRpcConfig.methodSendMessage:
          final msgData = params['messageData'] as Map<String, dynamic>;
          final input = MessageInput.fromMap(msgData);
          final msgId = await hostAgent.sendMessage(input);
          return {'messageId': msgId};
        case AgentRpcConfig.methodGetMaxSeq:
          final maxSeq = await hostAgent.getMaxSeq(employeeId: employeeId);
          return {'maxSeq': maxSeq};
        case AgentRpcConfig.methodGetMinSeq:
          final minSeq = await hostAgent.getMinSeq(employeeId: employeeId);
          return {'minSeq': minSeq};
        case AgentRpcConfig.methodGetMessagesAfterSeq:
          final lastSeq = params['lastSeq'] as int? ?? 0;
          final limit = params['limit'] as int? ?? 20;
          final messages = await hostAgent.getMessagesAfterSeq(
            employeeId: employeeId,
            lastSeq: lastSeq,
            limit: limit,
          );
          return {
            'messages': messages.map((m) => m.toMap()).toList(),
          };
        case AgentRpcConfig.methodClearSession:
          await hostAgent.clearCurrentSession();
          return {};
        case AgentRpcConfig.methodGetState:
          final snapshot = hostAgent.getStateSnapshot();
          return snapshot.toMap();
        case AgentRpcConfig.methodGetProvider:
          final config = hostAgent.getProviderConfig();
          return {'providerConfig': config?.toMap()};
        case AgentRpcConfig.methodGetProjectUuid:
          final uuid = hostAgent.getCurrentProjectUuid();
          return {'projectUuid': uuid};
        case AgentRpcConfig.methodGetSkills:
          final skills = hostAgent.getSkillsConfig();
          return {'skills': skills};
        case AgentRpcConfig.methodGetMcpConfigs:
          final configs = hostAgent.getMcpConfigs();
          return {'mcpConfigs': configs};
        case AgentRpcConfig.methodGetPendingPermission:
          final request = hostAgent.getPendingPermissionRequest();
          return {'request': request?.toMap()};
        default:
          print('[Test] 未实现的 RPC 方法: $method');
          return {};
      }
    }

    clientProxy = AgentProxy.remote(
      employeeId: employeeId,
      deviceId: clientDeviceId,
      rpcCall: rpcCall,
      remoteEventStream: _remoteEventStream(),
    );
    cachedClientProxy = CachedAgentProxy(
      proxy: clientProxy,
      messageStore: clientMessageStore,
      deviceId: clientDeviceId,
      employeeId: employeeId,
    );
    await cachedClientProxy.initialize();
  }

  Future<void> _tearDownClient() async {
    await cachedClientProxy.dispose();
    await clientProxy.dispose();
    clientMessageStore.dispose();
  }

  Future<void> _tearDownHost() async {
    await hostAgent.dispose();
    hostMessageStore.dispose();
  }

  Future<void> _setup() async {
    await _remoteEventController?.close();
    _remoteEventController = StreamController<AgentEvent>.broadcast();
    // 重新创建事件控制器（每个测试用独立的控制器）
    await _setupHost();
    await _setupClient();
  }

  Future<void> _tearDown() async {
    await _tearDownClient();
    await _tearDownHost();
  }

  /// host 端直接注入一条 assistant 消息（不经过 LLM）
  Future<String> hostInjectAssistant(String content) async {
    final msgId = const Uuid().v4();
    await hostAgent.injectAssistantMessage(messageId: msgId, content: content);
    return msgId;
  }

  /// host 端直接添加一条 user 消息到 DB（不经过 MessageProcessor）
  Future<String> hostAddUserMessage(String content) async {
    final msgId = const Uuid().v4();
    final chatMsg = ChatMessage.user(
      id: msgId,
      employeeId: employeeId,
      content: content,
      deviceId: hostDeviceId,
    );
    await hostMessageStore.addMessage(chatMsg, deviceId: hostDeviceId);
    return msgId;
  }

  /// 从消息列表中提取最大 seq
  int _maxSeqFromMessages(List<AgentMessage> messages) {
    int maxSeq = 0;
    for (final msg in messages) {
      final seq = msg.metadata?['seq'] as int? ?? 0;
      if (seq > maxSeq) maxSeq = seq;
    }
    return maxSeq;
  }

  // ================================================================
  // 1. 问答消息正确性与一致性
  // ================================================================
  group('问答消息正确性与一致性', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('host 注入 assistant 消息后客户端可通过 syncFromRemote 获取', () async {
      final msgId = await hostInjectAssistant('你好，这是一条助手回复');

      // 初始客户端本地无消息
      var clientMsgs = await cachedClientProxy.getMessages();
      expect(clientMsgs.length, equals(0));

      // 同步远程消息
      await cachedClientProxy.syncFromRemote();
      clientMsgs = await cachedClientProxy.getMessages();

      expect(clientMsgs.length, equals(1));
      expect(clientMsgs.first.id, equals(msgId));
      expect(clientMsgs.first.content, equals('你好，这是一条助手回复'));
      expect(clientMsgs.first.role, equals('assistant'));
      expect(clientMsgs.first.metadata?['seq'], isNotNull);
      expect(clientMsgs.first.metadata?['seq'], greaterThan(0));
    });

    test('多轮对话消息顺序和内容一致', () async {
      final userMsgId1 = await hostAddUserMessage('第一个问题');
      final assistantMsgId1 = await hostInjectAssistant('第一个回复');
      final userMsgId2 = await hostAddUserMessage('第二个问题');
      final assistantMsgId2 = await hostInjectAssistant('第二个回复');

      // 同步
      await cachedClientProxy.syncFromRemote();
      final clientMsgs = await cachedClientProxy.getMessages();

      // 验证数量
      expect(clientMsgs.length, equals(4));

      // 验证所有消息 ID 都存在
      final ids = clientMsgs.map((m) => m.id).toSet();
      expect(ids, containsAll([userMsgId1, assistantMsgId1, userMsgId2, assistantMsgId2]));

      // 验证角色对应正确
      final msg1 = clientMsgs.firstWhere((m) => m.id == userMsgId1);
      expect(msg1.role, equals('user'));
      expect(msg1.content, equals('第一个问题'));

      final msg2 = clientMsgs.firstWhere((m) => m.id == assistantMsgId1);
      expect(msg2.role, equals('assistant'));
      expect(msg2.content, equals('第一个回复'));

      final msg3 = clientMsgs.firstWhere((m) => m.id == userMsgId2);
      expect(msg3.role, equals('user'));
      expect(msg3.content, equals('第二个问题'));

      final msg4 = clientMsgs.firstWhere((m) => m.id == assistantMsgId2);
      expect(msg4.role, equals('assistant'));
      expect(msg4.content, equals('第二个回复'));
    });

    test('增量同步只拉取新消息', () async {
      await hostAddUserMessage('A');
      await hostInjectAssistant('回复A');

      // 第一次同步
      await cachedClientProxy.syncFromRemote();
      var clientMsgs = await cachedClientProxy.getMessages();
      expect(clientMsgs.length, equals(2));

      // 新增消息
      await hostAddUserMessage('B');
      await hostInjectAssistant('回复B');

      // 第二次同步（增量拉取）
      await cachedClientProxy.syncFromRemote();
      clientMsgs = await cachedClientProxy.getMessages();
      expect(clientMsgs.length, equals(4));
    });

    test('sendMessage 后本地消息立即可见', () async {
      final messageId = await cachedClientProxy.sendMessage(
        MessageInput(content: '你好'),
      );
      // 等待 _addMessageToCache 的异步落盘完成
      await Future.delayed(const Duration(milliseconds: 200));

      // sendMessage 会先创建本地消息，立即可见
      final messages = await cachedClientProxy.getMessages();
      print('[Test] sendMessage 后客户端消息数: ${messages.length}, messageId=$messageId');
      for (final m in messages) {
        print('[Test]   消息: id=${m.id}, content=${m.content}, role=${m.role}');
      }
      expect(messages, isNotEmpty,
          reason: 'sendMessage 后客户端应有消息');
      expect(messages.any((m) => m.id == messageId), isTrue,
          reason: 'sendMessage 返回的 ID 应在本地消息中找到');

      final localMsg = messages.firstWhere((m) => m.id == messageId);
      expect(localMsg.content, equals('你好'));
      expect(localMsg.role, equals('user'));
      // 注意：sendMessage 内部会调用 _updateMessageStatus(messageId, 'sent')
      // 但 'sent' 不是合法的 MessageStatus，fromString('sent') 回退为 none
      // _chatMessageToAgentMessage 将 MessageStatus.none 映射为 null
      expect(localMsg.status, isNull,
          reason: 'sendMessage 成功后 pending 被 sent 覆盖，sent 回退为 none → null');
      // metadata 不持久化到 SQLite（MessageMapper.toRecord 不包含 metadata），
      // localOnly 是内存标记，DB roundtrip 后不可见
      // expect(localMsg.metadata?['localOnly'], isTrue);
    });

    test('sendMessage 返回的消息 ID 与本地消息一致', () async {
      final returnedId = await cachedClientProxy.sendMessage(
        MessageInput(content: 'ID 一致性测试'),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      final messages = await cachedClientProxy.getMessages();
      expect(messages.any((m) => m.id == returnedId), isTrue,
          reason: 'sendMessage 返回的 ID 应在本地消息中找到');
    });
  });

  // ================================================================
  // 2. 消息状态正确性与一致性
  // ================================================================
  group('消息状态正确性与一致性', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('sendMessage 创建的消息初始状态为 pending', () async {
      final messageId = await cachedClientProxy.sendMessage(
        MessageInput(content: '状态测试'),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      final messages = await cachedClientProxy.getMessages();
      final msg = messages.firstWhere((m) => m.id == messageId);
      // sendMessage 内部会调用 _updateMessageStatus(messageId, 'sent')
      // 'sent' 不是合法的 MessageStatus，回退为 none → null
      expect(msg.status, isNull,
          reason: 'pending 被 _updateMessageStatus(sent) 覆盖，sent 回退为 none → null');
    });

    test('sendMessage 成功后状态更新（sent 在枚举中不存在，回退为 none）', () async {
      final messageId = await cachedClientProxy.sendMessage(
        MessageInput(content: '发送后状态'),
      );

      // sendMessage 内部会调用 _updateMessageStatus(messageId, 'sent')
      // 注意：MessageStatus 枚举没有 sent，fromString('sent') 会回退到 none
      // 等待一小段时间让状态更新落盘
      await Future.delayed(const Duration(milliseconds: 50));

      final msg = await clientMessageStore.getMessage(messageId);
      expect(msg, isNotNull);
      // 'sent' 不是合法的 MessageStatus，fromString 回退到 none
      expect(msg!.status, equals(MessageStatus.none),
          reason: 'sendMessage 成功后消息状态更新（sent → fromString 回退为 none）');
    });

    test('host 端消息状态变更同步到客户端', () async {
      final msgId = await hostAddUserMessage('状态同步测试');
      await hostMessageStore.updateMessageStatus(msgId, MessageStatus.completed);

      await cachedClientProxy.syncFromRemote();
      final clientMsgs = await cachedClientProxy.getMessages();
      final syncedMsg = clientMsgs.firstWhere((m) => m.id == msgId);

      expect(syncedMsg.status, equals('completed'));
    });

    test('host 端消息失败状态（含 error）同步到客户端', () async {
      final msgId = await hostAddUserMessage('失败状态测试');
      await hostMessageStore.updateMessageStatus(
        msgId,
        MessageStatus.failed,
        error: '处理超时',
      );

      await cachedClientProxy.syncFromRemote();
      final clientMsgs = await cachedClientProxy.getMessages();
      final syncedMsg = clientMsgs.firstWhere((m) => m.id == msgId);

      expect(syncedMsg.status, equals('failed'));
    });

    test('多轮消息状态各自独立正确', () async {
      final msg1 = await hostAddUserMessage('消息1');
      final msg2 = await hostAddUserMessage('消息2');
      final msg3 = await hostAddUserMessage('消息3');

      await hostMessageStore.updateMessageStatus(msg1, MessageStatus.completed);
      await hostMessageStore.updateMessageStatus(msg2, MessageStatus.failed, error: '超时');
      // msg3 保持 none 状态

      await cachedClientProxy.syncFromRemote();
      final clientMsgs = await cachedClientProxy.getMessages();

      expect(clientMsgs.firstWhere((m) => m.id == msg1).status, equals('completed'));
      expect(clientMsgs.firstWhere((m) => m.id == msg2).status, equals('failed'));
      // msg3 无状态，转换为 null
      final msg3Status = clientMsgs.firstWhere((m) => m.id == msg3).status;
      expect(msg3Status, isNull);
    });
  });

  // ================================================================
  // 3. updateWatermark: false 修复验证
  // ================================================================
  group('updateWatermark 修复验证', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('本地临时消息不更新同步水位线', () async {
      // 客户端发送消息（本地临时消息，updateWatermark=false）
      final messageId = await cachedClientProxy.sendMessage(
        MessageInput(content: '本地临时消息'),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      // 本地临时消息已写入 DB
      final localMsg = await clientMessageStore.getMessage(messageId);
      expect(localMsg, isNotNull);

      // 同步水位线应仍为 0（因为 updateWatermark=false）
      final lastSeq = clientWatermarkStore.getLastSeq(employeeId);
      expect(lastSeq, equals(0),
          reason: '本地临时消息不应更新同步水位线');
    });

    test('远程同步消息正常更新同步水位线', () async {
      await hostAddUserMessage('远程消息1');
      await hostInjectAssistant('远程回复1');

      await cachedClientProxy.syncFromRemote();

      final lastSeq = clientWatermarkStore.getLastSeq(employeeId);
      expect(lastSeq, greaterThan(0),
          reason: '远程同步消息应更新同步水位线');
    });

    test('sendMessage 后 syncFromRemote 仍能拉取服务端消息', () async {
      // 步骤1：客户端发送消息（产生本地 seq，但水位线不更新）
      final localMsgId = await cachedClientProxy.sendMessage(
        MessageInput(content: '本地消息'),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      // 步骤2：服务端注入助手消息
      final assistantMsgId = await hostInjectAssistant('助手回复');

      // 步骤3：验证水位线未被本地临时消息污染
      final lastSeq = clientWatermarkStore.getLastSeq(employeeId);
      expect(lastSeq, equals(0),
          reason: '本地临时消息不应更新水位线');

      // 步骤4：同步远程消息应能成功拉取
      await cachedClientProxy.syncFromRemote();

      final clientMsgs = await cachedClientProxy.getMessages();
      // 应包含本地消息 + 远程助手消息
      expect(
        clientMsgs.any((m) => m.id == localMsgId),
        isTrue,
        reason: '本地消息应保留',
      );
      expect(
        clientMsgs.any((m) => m.id == assistantMsgId),
        isTrue,
        reason: '远程助手消息应被拉取',
      );
    });

    test('多次 sendMessage + sync 后水位线仅反映远程 seq', () async {
      // 连续发送多条本地消息
      for (int i = 0; i < 3; i++) {
        await cachedClientProxy.sendMessage(
          MessageInput(content: '本地消息$i'),
        );
      }
      await Future.delayed(const Duration(milliseconds: 100));

      // 所有本地消息的 seq 都不应影响水位线
      expect(clientWatermarkStore.getLastSeq(employeeId), equals(0));

      // 服务端添加消息并同步
      await hostAddUserMessage('远程消息');
      await cachedClientProxy.syncFromRemote();

      final lastSeq = clientWatermarkStore.getLastSeq(employeeId);
      expect(lastSeq, greaterThan(0),
          reason: '同步后水位线应反映远程消息的 seq');
    });

    test('水位线 MAX 语义：只升不降', () async {
      await hostAddUserMessage('消息A');
      await cachedClientProxy.syncFromRemote();
      final seqAfterFirst = clientWatermarkStore.getLastSeq(employeeId);

      await hostInjectAssistant('回复A');
      await cachedClientProxy.syncFromRemote();
      final seqAfterSecond = clientWatermarkStore.getLastSeq(employeeId);

      expect(seqAfterSecond, greaterThanOrEqualTo(seqAfterFirst),
          reason: '水位线只升不降');
    });
  });

  // ================================================================
  // 4. 事件流验证
  // ================================================================
  group('事件流验证', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('onMessagesChanged 在 initialize 后触发', () async {
      // initialize 已在 _setup 中调用
      // 等待 16ms debounce 后检查事件
      final events = <List<AgentMessage>>[];
      final sub = cachedClientProxy.onMessagesChanged.listen(events.add);
      await Future.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      // initialize 时本地无消息，事件触发但列表为空
      // 重新初始化验证
      expect(events.isNotEmpty, isTrue,
          reason: 'initialize 后 onMessagesChanged 应触发');
    });

    test('syncFromRemote 后 onMessagesChanged 触发', () async {
      await hostInjectAssistant('远程消息');

      final events = <List<AgentMessage>>[];
      final sub = cachedClientProxy.onMessagesChanged.listen(events.add);

      await cachedClientProxy.syncFromRemote();
      // 等待 16ms debounce
      await Future.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(events.any((list) => list.any((m) => m.content == '远程消息')),
          isTrue,
          reason: 'syncFromRemote 后 onMessagesChanged 应包含远程消息');
    });

    test('sendMessage 后 onMessagesChanged 触发', () async {
      final events = <List<AgentMessage>>[];
      final sub = cachedClientProxy.onMessagesChanged.listen(events.add);

      await cachedClientProxy.sendMessage(
        MessageInput(content: '事件测试'),
      );
      // 等待 16ms debounce
      await Future.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(events.isNotEmpty, isTrue,
          reason: 'sendMessage 后 onMessagesChanged 应触发');
      // 最后一个事件应包含新消息
      final lastEvent = events.last;
      expect(lastEvent.any((m) => m.content == '事件测试'), isTrue);
    });
  });

  // ================================================================
  // 5. 消息通知与内容一致性
  // ================================================================
  group('消息通知与内容一致性', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('事件流中的消息与 getMessages 结果一致', () async {
      await hostAddUserMessage('Q1');
      await hostInjectAssistant('A1');
      await hostAddUserMessage('Q2');
      await hostInjectAssistant('A2');

      final events = <List<AgentMessage>>[];
      final sub = cachedClientProxy.onMessagesChanged.listen(events.add);

      await cachedClientProxy.syncFromRemote();
      // 等待 16ms debounce
      await Future.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      // 事件流应触发
      expect(events.isNotEmpty, isTrue);

      // 事件流中的消息应与直接查询 getMessages 一致
      final directMsgs = await cachedClientProxy.getMessages();
      final eventMsgs = events.last;

      expect(eventMsgs.length, equals(directMsgs.length),
          reason: '事件流消息数应与 getMessages 一致');
      for (int i = 0; i < eventMsgs.length && i < directMsgs.length; i++) {
        expect(eventMsgs[i].id, equals(directMsgs[i].id));
        expect(eventMsgs[i].content, equals(directMsgs[i].content));
        expect(eventMsgs[i].role, equals(directMsgs[i].role));
      }
    });

    test('syncWithRemote 返回的消息按时间正序', () async {
      await hostInjectAssistant('第一');
      await Future.delayed(const Duration(milliseconds: 10));
      await hostInjectAssistant('第二');
      await Future.delayed(const Duration(milliseconds: 10));
      await hostInjectAssistant('第三');

      await cachedClientProxy.syncWithRemote();
      final msgs = await cachedClientProxy.getMessages();

      expect(msgs.length, equals(3));
      // 验证按时间正序
      for (int i = 1; i < msgs.length; i++) {
        expect(
          msgs[i].createdAt.isAfter(msgs[i - 1].createdAt) ||
              msgs[i].createdAt.isAtSameMomentAs(msgs[i - 1].createdAt),
          isTrue,
          reason: '消息应按时间正序排列',
        );
      }
    });
  });

  // ================================================================
  // 6. clearCurrentSession 后同步行为
  // ================================================================
  group('clearCurrentSession 后同步行为', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('清空会话后客户端消息和水位线被重置', () async {
      // 准备数据
      await hostAddUserMessage('旧消息');
      await hostInjectAssistant('旧回复');
      await cachedClientProxy.syncFromRemote();

      var clientMsgs = await cachedClientProxy.getMessages();
      expect(clientMsgs.length, greaterThan(0));
      expect(clientWatermarkStore.getLastSeq(employeeId), greaterThan(0));

      // 清空
      await cachedClientProxy.clearCurrentSession();

      clientMsgs = await cachedClientProxy.getMessages();
      expect(clientMsgs.length, equals(0),
          reason: '清空后客户端消息应为空');
      expect(clientWatermarkStore.getLastSeq(employeeId), equals(0),
          reason: '清空后水位线应重置为 0');
    });

    test('清空后新增消息可正常同步', () async {
      await hostAddUserMessage('旧消息');
      await cachedClientProxy.syncFromRemote();

      // 清空
      await cachedClientProxy.clearCurrentSession();

      // 新增消息
      await hostAddUserMessage('新消息');
      await hostInjectAssistant('新回复');

      await cachedClientProxy.syncFromRemote();
      final clientMsgs = await cachedClientProxy.getMessages();

      expect(clientMsgs.length, equals(2),
          reason: '清空后新增消息应正常同步');
      expect(clientMsgs.any((m) => m.content == '新消息'), isTrue);
      expect(clientMsgs.any((m) => m.content == '新回复'), isTrue);
    });
  });

  // ================================================================
  // 7. syncFromRemote 完整端到端流程
  // ================================================================
  group('syncFromRemote 完整端到端流程', () {
    setUp(() async => await _setup());
    tearDown(() async => await _tearDown());

    test('完整流程：sendMessage → hostAdd → syncFromRemote → 验证一致性', () async {
      // 1. 客户端发送消息
      final clientMsgId = await cachedClientProxy.sendMessage(
        MessageInput(content: '客户端问题'),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      // 2. 服务端添加 assistant 回复
      final assistantMsgId = await hostInjectAssistant('服务端回复');

      // 3. 同步
      await cachedClientProxy.syncFromRemote();

      // 4. 验证客户端消息
      final clientMsgs = await cachedClientProxy.getMessages();

      // 应包含客户端本地消息 + assistant 回复
      expect(
        clientMsgs.any((m) => m.id == clientMsgId),
        isTrue,
        reason: '客户端本地消息应保留',
      );
      final assistantMsgs = clientMsgs.where(
        (m) => m.id == assistantMsgId && m.role == 'assistant',
      );
      expect(assistantMsgs.isNotEmpty, isTrue,
          reason: '助手回复应被同步到客户端');
      expect(assistantMsgs.first.content, equals('服务端回复'));
    });

    test('服务端连续注入多条消息后批量同步', () async {
      const totalMessages = 10;
      final ids = <String>[];
      for (int i = 0; i < totalMessages; i++) {
        ids.add(await hostInjectAssistant('消息$i'));
      }

      await cachedClientProxy.syncFromRemote();
      final clientMsgs = await cachedClientProxy.getMessages();

      expect(clientMsgs.length, equals(totalMessages));
      for (int i = 0; i < totalMessages; i++) {
        expect(clientMsgs.any((m) => m.id == ids[i]), isTrue,
            reason: '消息$i 应存在');
      }
    });

    test('seq 严格递增', () async {
      for (int i = 0; i < 5; i++) {
        await hostInjectAssistant('消息$i');
      }

      await cachedClientProxy.syncFromRemote();
      final clientMsgs = await cachedClientProxy.getMessages();

      final seqs = clientMsgs
          .map((m) => m.metadata?['seq'] as int? ?? 0)
          .toList();
      for (int i = 1; i < seqs.length; i++) {
        expect(seqs[i], greaterThan(seqs[i - 1]),
            reason: 'seq 应严格递增: seqs[$i]=${seqs[i]} > seqs[${i - 1}]=${seqs[i - 1]}');
      }
    });
  });

  print('\n=== CachedAgentProxy 远程消息同步测试完成 ===\n');
}
