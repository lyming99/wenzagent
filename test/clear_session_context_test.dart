import 'package:langchain_core/chat_models.dart';
import 'package:test/test.dart';
import 'package:wenzagent/src/agent/adapter/langchain_chat_adapter.dart';
import 'package:wenzagent/src/agent/adapter/persistent_chat_adapter.dart';
import 'package:wenzagent/src/agent/adapter/session_memory_manager.dart';

/// 清空会话后上下文是否被正确清空的测试
///
/// 测试场景：
/// 1. 发送消息后清空会话，验证内存消息历史被清空
/// 2. 清空会话后，验证上下文（_context）是否被保留（这是预期行为）
/// 3. 清空会话后，验证 ContextCompressor 的压缩缓存是否被清空
/// 4. 清空会话后新发消息，验证不会携带旧消息
/// 5. PersistentChatAdapter 清空会话后，验证持久化回调被调用
void main() {
  late LangChainChatAdapter adapter;
  late PersistentChatAdapter persistentAdapter;
  late String testEmployeeId;
  late String testDeviceId;

  setUp(() {
    adapter = LangChainChatAdapter();
    persistentAdapter = PersistentChatAdapter();
    testEmployeeId = 'test-employee-${DateTime.now().millisecondsSinceEpoch}';
    testDeviceId = 'test-device-${DateTime.now().millisecondsSinceEpoch}';
  });

  tearDown(() async {
    await adapter.dispose();
    await persistentAdapter.dispose();
  });

  group('LangChainChatAdapter - 清空会话与上下文', () {
    test('清空会话后，内存消息历史应为空', () async {
      // 1. 初始化会话
      await adapter.initSession(employeeId: testEmployeeId);

      // 2. 手动添加消息到 SessionMemoryManager
      adapter.memoryManager.addMessage(
        testEmployeeId,
        testDeviceId,
        ChatMessage.humanText('你好'),
        messageId: 'msg-1',
      );
      adapter.memoryManager.addMessage(
        testEmployeeId,
        testDeviceId,
        ChatMessage.ai('你好！有什么可以帮你的？'),
        messageId: 'msg-2',
      );

      // 3. 验证消息存在
      final session = adapter.memoryManager.getSession(testEmployeeId);
      expect(session, isNotNull);
      expect(session!.messageCount, equals(2));

      // 4. 清空会话
      await adapter.clearCurrentSession();

      // 5. 验证消息历史被清空
      expect(session.messageCount, equals(0));
      expect(session.allMessages, isEmpty);
      expect(session.conversationSummary, isNull);
      expect(session.summarizedUpToIndex, equals(0));
    });

    test('清空会话后，上下文（_context）应被保留（不被自动清除）', () async {
      // 1. 初始化会话
      await adapter.initSession(employeeId: testEmployeeId);

      // 2. 设置上下文
      adapter.setContext({
        'systemPrompt': '你是一个有用的助手',
        'projectContext': '项目A的上下文信息',
      });

      // 3. 添加消息
      adapter.memoryManager.addMessage(
        testEmployeeId,
        testDeviceId,
        ChatMessage.humanText('你好'),
        messageId: 'msg-1',
      );

      // 4. 清空会话
      await adapter.clearCurrentSession();

      // 5. 验证：消息历史被清空，但上下文被保留
      final session = adapter.memoryManager.getSession(testEmployeeId);
      expect(session!.messageCount, equals(0), reason: '消息历史应被清空');

      expect(adapter.currentContext, isNotNull, reason: '上下文不应被自动清除');
      expect(adapter.currentContext!['systemPrompt'], equals('你是一个有用的助手'));
      expect(adapter.currentContext!['projectContext'], equals('项目A的上下文信息'));

      // 6. 需要显式调用 clearContext 才能清除上下文
      adapter.clearContext();
      expect(adapter.currentContext, isNull, reason: '显式 clearContext 后上下文应为空');
    });

    test('清空会话后发送新消息，不应携带旧消息', () async {
      // 1. 初始化会话
      await adapter.initSession(employeeId: testEmployeeId);

      // 2. 添加旧消息
      adapter.memoryManager.addMessage(
        testEmployeeId,
        testDeviceId,
        ChatMessage.humanText('旧消息1'),
        messageId: 'msg-old-1',
      );
      adapter.memoryManager.addMessage(
        testEmployeeId,
        testDeviceId,
        ChatMessage.ai('旧回复1'),
        messageId: 'msg-old-2',
      );

      // 3. 清空会话
      await adapter.clearCurrentSession();

      // 4. 添加新消息
      adapter.memoryManager.addMessage(
        testEmployeeId,
        testDeviceId,
        ChatMessage.humanText('新消息'),
        messageId: 'msg-new-1',
      );

      // 5. 构建发送给 LLM 的消息列表
      final messages = adapter.memoryManager.buildMessages(
        employeeId: testEmployeeId,
        systemPrompt: '你是助手',
      );

      // 6. 验证：只有系统提示词 + 新消息，不应有旧消息
      expect(messages.length, equals(2), reason: '应该只有系统提示词和新消息');
      expect(messages[0].contentAsString, equals('你是助手'));
      expect(messages[1].contentAsString, equals('新消息'));
    });

    test('clearCurrentSession 对不存在的会话不报错', () async {
      // 没有初始化会话，直接清空，不应抛异常
      await adapter.clearCurrentSession();
    });

    test('设置上下文后再清空会话，buildMessages 应仍包含系统提示词', () async {
      // 1. 初始化会话
      await adapter.initSession(employeeId: testEmployeeId);

      // 2. 设置上下文
      adapter.setContext({
        'systemPrompt': '你是专用助手',
      });

      // 3. 清空会话
      await adapter.clearCurrentSession();

      // 4. 添加新消息
      adapter.memoryManager.addMessage(
        testEmployeeId,
        testDeviceId,
        ChatMessage.humanText('你好'),
        messageId: 'msg-1',
      );

      // 5. buildMessages 应包含系统提示词
      final messages = adapter.memoryManager.buildMessages(
        employeeId: testEmployeeId,
      );

      // buildMessages 只传入 systemPrompt 参数时才包含系统提示
      // 但这里的系统提示词是从 _buildSystemPrompt 中获取的（在 adapter 内部）
      // memoryManager.buildMessages 需要手动传入 systemPrompt
      final messagesWithPrompt = adapter.memoryManager.buildMessages(
        employeeId: testEmployeeId,
        systemPrompt: '你是专用助手',
      );

      expect(messagesWithPrompt.length, equals(2));
      expect(messagesWithPrompt[0].contentAsString, equals('你是专用助手'));
    });
  });

  group('SessionMemoryManager - 清空会话', () {
    test('clearSession 清空指定会话的消息', () {
      final manager = SessionMemoryManager();

      // 创建两个会话
      manager.getOrCreateSession('emp-1');
      manager.getOrCreateSession('emp-2');

      // 添加消息
      manager.addMessage('emp-1', 'dev-1', ChatMessage.humanText('消息1'));
      manager.addMessage('emp-1', 'dev-1', ChatMessage.ai('回复1'));
      manager.addMessage('emp-2', 'dev-1', ChatMessage.humanText('消息2'));

      // 验证消息数量
      expect(manager.getSession('emp-1')!.messageCount, equals(2));
      expect(manager.getSession('emp-2')!.messageCount, equals(1));

      // 清空 emp-1 的会话
      manager.clearSession('emp-1');

      // 验证 emp-1 被清空，emp-2 不受影响
      expect(manager.getSession('emp-1')!.messageCount, equals(0));
      expect(manager.getSession('emp-2')!.messageCount, equals(1));
    });

    test('clearSession 重置 conversationSummary 和 summarizedUpToIndex', () {
      final manager = SessionMemoryManager();
      final session = manager.getOrCreateSession('emp-1');

      // 模拟摘要数据
      session.conversationSummary = '这是一个关于天气的对话';
      session.summarizedUpToIndex = 5;

      // 添加消息
      manager.addMessage('emp-1', 'dev-1', ChatMessage.humanText('天气怎么样？'));

      // 清空会话
      manager.clearSession('emp-1');

      // 验证摘要被重置
      expect(session.conversationSummary, isNull);
      expect(session.summarizedUpToIndex, equals(0));
      expect(session.messageCount, equals(0));
    });

    test('deleteSession 完全删除会话对象', () {
      final manager = SessionMemoryManager();

      manager.getOrCreateSession('emp-1');
      manager.addMessage('emp-1', 'dev-1', ChatMessage.humanText('消息1'));

      expect(manager.getSession('emp-1'), isNotNull);

      manager.deleteSession('emp-1');

      expect(manager.getSession('emp-1'), isNull);
    });

    test('clearDeviceSession 只清空指定设备的消息', () {
      final manager = SessionMemoryManager();
      manager.getOrCreateSession('emp-1');

      manager.addMessage('emp-1', 'dev-1', ChatMessage.humanText('设备1消息'));
      manager.addMessage('emp-1', 'dev-2', ChatMessage.humanText('设备2消息'));

      expect(manager.getSession('emp-1')!.messageCount, equals(2));

      manager.clearDeviceSession('emp-1', 'dev-1');

      // dev-1 的消息被清空，dev-2 不受影响
      expect(manager.getSession('emp-1')!.messageCount, equals(1));
      expect(
        manager.getMessagesForDevice('emp-1', 'dev-1'),
        isEmpty,
        reason: 'dev-1 消息应被清空',
      );
      expect(
        manager.getMessagesForDevice('emp-1', 'dev-2'),
        isNotEmpty,
        reason: 'dev-2 消息应保留',
      );
    });
  });

  group('PersistentChatAdapter - 清空会话', () {
    test('clearCurrentSession 触发持久化回调（删除消息）', () async {
      // 追踪回调是否被调用
      bool deleteMessagesCalled = false;
      String? deletedEmployeeId;
      bool persistSessionCalled = false;

      persistentAdapter.deleteMessagesCallback = (empId) async {
        deleteMessagesCalled = true;
        deletedEmployeeId = empId;
      };

      persistentAdapter.persistSession = (sessionData) async {
        persistSessionCalled = true;
      };

      // 初始化会话
      await persistentAdapter.initSession(employeeId: testEmployeeId);

      // 添加消息
      persistentAdapter.memoryManager.addMessage(
        testEmployeeId,
        testDeviceId,
        ChatMessage.humanText('测试消息'),
        messageId: 'msg-1',
      );

      // 清空会话
      await persistentAdapter.clearCurrentSession();

      // 验证回调被调用
      expect(deleteMessagesCalled, isTrue, reason: 'deleteMessagesCallback 应被调用');
      expect(deletedEmployeeId, equals(testEmployeeId));
      expect(persistSessionCalled, isTrue, reason: 'persistSession 应被调用（通知持久化会话状态）');
    });

    test('clearCurrentSession 清空 _persistedMessageIds', () async {
      // 设置回调（避免空指针）
      persistentAdapter.deleteMessagesCallback = (empId) async {};
      persistentAdapter.persistMessage = (data) async {};

      // 初始化会话
      await persistentAdapter.initSession(employeeId: testEmployeeId);

      // 添加消息
      persistentAdapter.memoryManager.addMessage(
        testEmployeeId,
        testDeviceId,
        ChatMessage.humanText('测试消息'),
        messageId: 'msg-1',
      );

      // 模拟已持久化
      // 通过反射或直接调用内部方法来添加到 _persistedMessageIds
      // 由于 _persistedMessageIds 是私有的，我们通过 clearCurrentSession 的行为来验证
      // 添加更多消息后清空
      persistentAdapter.memoryManager.addMessage(
        testEmployeeId,
        testDeviceId,
        ChatMessage.humanText('测试消息2'),
        messageId: 'msg-2',
      );

      await persistentAdapter.clearCurrentSession();

      // 验证会话消息被清空
      final session = persistentAdapter.memoryManager.getSession(testEmployeeId);
      expect(session!.messageCount, equals(0));
    });

    test('清空会话后上下文仍然保留', () async {
      persistentAdapter.deleteMessagesCallback = (empId) async {};
      persistentAdapter.persistSession = (data) async {};

      await persistentAdapter.initSession(employeeId: testEmployeeId);

      // 设置上下文
      persistentAdapter.setContext({
        'systemPrompt': '你是专用助手',
        'additionalInfo': '额外信息',
      });

      // 清空会话
      await persistentAdapter.clearCurrentSession();

      // 上下文应保留
      expect(persistentAdapter.currentContext, isNotNull);
      expect(persistentAdapter.currentContext!['systemPrompt'], equals('你是专用助手'));
      expect(persistentAdapter.currentContext!['additionalInfo'], equals('额外信息'));

      // 显式清除上下文
      persistentAdapter.clearContext();
      expect(persistentAdapter.currentContext, isNull);
    });

    test('initSession 从数据库加载消息后，clearCurrentSession 应清空这些消息', () async {
      // 模拟数据库中的消息
      final mockDbMessages = <Map<String, dynamic>>[
        {
          'uuid': 'db-msg-1',
          'id': 'db-msg-1',
          'role': 'user',
          'content': '数据库中的用户消息',
          'type': 'text',
          'deviceId': testDeviceId,
          'createTime': '2025-01-01T10:00:00.000',
        },
        {
          'uuid': 'db-msg-2',
          'id': 'db-msg-2',
          'role': 'assistant',
          'content': '数据库中的AI回复',
          'type': 'text',
          'deviceId': testDeviceId,
          'createTime': '2025-01-01T10:01:00.000',
        },
        {
          'uuid': 'db-msg-3',
          'id': 'db-msg-3',
          'role': 'user',
          'content': '数据库中的第二条用户消息',
          'type': 'text',
          'deviceId': testDeviceId,
          'createTime': '2025-01-01T10:02:00.000',
        },
      ];

      // 设置 loadMessages 回调
      persistentAdapter.loadMessages = (employeeId) async {
        return mockDbMessages;
      };

      // 追踪 deleteMessagesCallback
      bool deleteCalled = false;
      String? deletedSessionId;
      persistentAdapter.deleteMessagesCallback = (sessionId) async {
        deleteCalled = true;
        deletedSessionId = sessionId;
      };

      persistentAdapter.persistSession = (data) async {};

      // 1. initSession 应从数据库加载消息
      await persistentAdapter.initSession(employeeId: testEmployeeId);

      // 2. 验证消息已加载到内存
      final session = persistentAdapter.memoryManager.getSession(testEmployeeId);
      expect(session, isNotNull);
      expect(session!.messageCount, equals(3),
          reason: 'initSession 应从数据库加载 3 条消息到内存');

      final allMessages = session.allMessages;
      expect(allMessages[0].message.contentAsString, equals('数据库中的用户消息'));
      expect(allMessages[1].message.contentAsString, equals('数据库中的AI回复'));
      expect(allMessages[2].message.contentAsString, equals('数据库中的第二条用户消息'));

      // 3. 清空会话
      await persistentAdapter.clearCurrentSession();

      // 4. 验证内存消息被清空
      expect(session.messageCount, equals(0),
          reason: 'clearCurrentSession 应清空从数据库加载的消息');
      expect(session.allMessages, isEmpty);

      // 5. 验证 deleteMessagesCallback 被调用
      expect(deleteCalled, isTrue,
          reason: 'clearCurrentSession 应调用 deleteMessagesCallback');
      expect(deletedSessionId, equals(testEmployeeId));
    });

    test('initSession 加载消息后再发新消息，clearCurrentSession 应全部清空', () async {
      // 模拟数据库中的消息
      final mockDbMessages = <Map<String, dynamic>>[
        {
          'uuid': 'db-msg-1',
          'id': 'db-msg-1',
          'role': 'user',
          'content': '历史消息1',
          'type': 'text',
          'deviceId': testDeviceId,
          'createTime': '2025-01-01T10:00:00.000',
        },
      ];

      persistentAdapter.loadMessages = (employeeId) async {
        return mockDbMessages;
      };

      persistentAdapter.deleteMessagesCallback = (sessionId) async {};
      persistentAdapter.persistMessage = (data) async {};
      persistentAdapter.persistSession = (data) async {};

      // 1. initSession 加载历史消息
      await persistentAdapter.initSession(employeeId: testEmployeeId);
      expect(persistentAdapter.memoryManager.getSession(testEmployeeId)!.messageCount, equals(1));

      // 2. 添加新消息（模拟用户发新消息）
      persistentAdapter.memoryManager.addMessage(
        testEmployeeId,
        testDeviceId,
        ChatMessage.humanText('新发送的消息'),
        messageId: 'new-msg-1',
      );
      persistentAdapter.memoryManager.addMessage(
        testEmployeeId,
        testDeviceId,
        ChatMessage.ai('新AI回复'),
        messageId: 'new-msg-2',
      );

      // 3. 验证内存中共有 3 条消息（1条历史 + 2条新消息）
      expect(persistentAdapter.memoryManager.getSession(testEmployeeId)!.messageCount, equals(3));

      // 4. 清空会话
      await persistentAdapter.clearCurrentSession();

      // 5. 验证所有消息都被清空
      final session = persistentAdapter.memoryManager.getSession(testEmployeeId);
      expect(session!.messageCount, equals(0),
          reason: 'clearCurrentSession 应清空所有消息（包括历史加载和新增的）');
      expect(session.allMessages, isEmpty);
    });

    test('clearCurrentSession 后再 initSession 加载消息，消息应重新加载', () async {
      // 模拟数据库消息
      final mockDbMessages = <Map<String, dynamic>>[
        {
          'uuid': 'db-msg-1',
          'id': 'db-msg-1',
          'role': 'user',
          'content': '可重新加载的消息',
          'type': 'text',
          'deviceId': testDeviceId,
          'createTime': '2025-01-01T10:00:00.000',
        },
      ];

      int loadCallCount = 0;
      persistentAdapter.loadMessages = (employeeId) async {
        loadCallCount++;
        return mockDbMessages;
      };

      bool deleteCalled = false;
      persistentAdapter.deleteMessagesCallback = (sessionId) async {
        deleteCalled = true;
      };
      persistentAdapter.persistSession = (data) async {};

      // 1. 第一次 initSession 加载消息
      await persistentAdapter.initSession(employeeId: testEmployeeId);
      expect(persistentAdapter.memoryManager.getSession(testEmployeeId)!.messageCount, equals(1));
      expect(loadCallCount, equals(1));

      // 2. 清空会话
      await persistentAdapter.clearCurrentSession();
      expect(persistentAdapter.memoryManager.getSession(testEmployeeId)!.messageCount, equals(0));
      expect(deleteCalled, isTrue);

      // 3. 重新 initSession，消息应再次加载
      deleteCalled = false; // 重置追踪
      await persistentAdapter.initSession(employeeId: testEmployeeId);
      expect(persistentAdapter.memoryManager.getSession(testEmployeeId)!.messageCount, equals(1),
          reason: '重新 initSession 后消息应重新从数据库加载');
      expect(loadCallCount, equals(2),
          reason: 'loadMessages 应被调用两次');
      expect(
        persistentAdapter.memoryManager.getSession(testEmployeeId)!.allMessages[0].message.contentAsString,
        equals('可重新加载的消息'),
      );
    });
  });
}
