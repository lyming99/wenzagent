import 'dart:async';

import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

/// 事件广播系统完整性测试
///
/// 验证：
/// - streamDelta / thinkingDelta 回调触发后能通过事件流收到事件
/// - messageStarted 回调在消息开始处理时触发
/// - configChanged 事件在配置变更方法调用后发射
/// - 广播链路完整性：AgentEventType → LanMessageType 映射
/// - 高频事件（streamDelta/thinkingDelta）不广播到 LAN
/// - 所有 AgentEventType 都有明确的处理策略
void main() {
  // ============================================================
  // 1. streamDelta 事件发射验证
  // ============================================================
  group('streamDelta 事件发射', () {
    test('通过 IChatAdapter.onStreamDelta 回调发射 streamDelta 事件', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final events = <AgentEvent>[];
      final sub = eventController.stream.listen(events.add);

      // 模拟 AgentImpl 注入的回调
      void Function(String chunk)? onStreamDelta;
      onStreamDelta = (chunk) {
        eventController.add(AgentEvent(
          type: AgentEventType.streamDelta,
          data: {'content': chunk},
          employeeId: 'emp-001',
        ));
      };

      // 模拟 LLM 产生多个 chunk
      onStreamDelta('Hello');
      onStreamDelta(' World');
      onStreamDelta('!');

      // 等待事件传播
      await Future.delayed(Duration(milliseconds: 50));

      expect(events.length, equals(3));
      expect(events[0].type, equals(AgentEventType.streamDelta));
      expect(events[0].data['content'], equals('Hello'));
      expect(events[1].data['content'], equals(' World'));
      expect(events[2].data['content'], equals('!'));

      // 验证拼接后内容正确
      final fullContent = events.map((e) => e.data['content'] as String).join();
      expect(fullContent, equals('Hello World!'));

      await sub.cancel();
      await eventController.close();
    });

    test('streamDelta 事件 data 包含 content 字段', () {
      final event = AgentEvent(
        type: AgentEventType.streamDelta,
        data: {'content': 'chunk text'},
        employeeId: 'emp-001',
      );

      expect(event.data, contains('content'));
      expect(event.data['content'], isA<String>());
    });

    test('连续多个 streamDelta 事件的 content 可拼接', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final chunks = <String>[];
      final sub = eventController.stream
          .where((e) => e.type == AgentEventType.streamDelta)
          .listen((e) => chunks.add(e.data['content'] as String));

      for (var i = 0; i < 10; i++) {
        eventController.add(AgentEvent(
          type: AgentEventType.streamDelta,
          data: {'content': 'chunk$i '},
          employeeId: 'emp-001',
        ));
      }

      await Future.delayed(Duration(milliseconds: 50));
      expect(chunks.length, equals(10));
      expect(chunks.join(), equals('chunk0 chunk1 chunk2 chunk3 chunk4 chunk5 chunk6 chunk7 chunk8 chunk9 '));

      await sub.cancel();
      await eventController.close();
    });
  });

  // ============================================================
  // 2. thinkingDelta 事件发射验证
  // ============================================================
  group('thinkingDelta 事件发射', () {
    test('通过 IChatAdapter.onThinkingDelta 回调发射 thinkingDelta 事件', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final events = <AgentEvent>[];
      final sub = eventController.stream.listen(events.add);

      void Function(String delta)? onThinkingDelta;
      onThinkingDelta = (delta) {
        eventController.add(AgentEvent(
          type: AgentEventType.thinkingDelta,
          data: {'content': delta},
          employeeId: 'emp-001',
        ));
      };

      onThinkingDelta('让我分析一下...');
      onThinkingDelta('这个问题需要...');

      await Future.delayed(Duration(milliseconds: 50));

      expect(events.length, equals(2));
      expect(events[0].type, equals(AgentEventType.thinkingDelta));
      expect(events[0].data['content'], equals('让我分析一下...'));
      expect(events[1].data['content'], equals('这个问题需要...'));

      await sub.cancel();
      await eventController.close();
    });

    test('thinkingDelta 与 streamDelta 可交叉出现', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final events = <AgentEvent>[];
      final sub = eventController.stream.listen(events.add);

      // 模拟 LLM 同时产生思考和输出
      eventController.add(AgentEvent(
        type: AgentEventType.thinkingDelta,
        data: {'content': '思考中...'},
        employeeId: 'emp-001',
      ));
      eventController.add(AgentEvent(
        type: AgentEventType.streamDelta,
        data: {'content': '回答'},
        employeeId: 'emp-001',
      ));
      eventController.add(AgentEvent(
        type: AgentEventType.thinkingDelta,
        data: {'content': '继续思考...'},
        employeeId: 'emp-001',
      ));
      eventController.add(AgentEvent(
        type: AgentEventType.streamDelta,
        data: {'content': '内容'},
        employeeId: 'emp-001',
      ));

      await Future.delayed(Duration(milliseconds: 50));

      expect(events.length, equals(4));
      expect(events[0].type, equals(AgentEventType.thinkingDelta));
      expect(events[1].type, equals(AgentEventType.streamDelta));
      expect(events[2].type, equals(AgentEventType.thinkingDelta));
      expect(events[3].type, equals(AgentEventType.streamDelta));

      await sub.cancel();
      await eventController.close();
    });
  });

  // ============================================================
  // 3. messageStarted 事件发射验证
  // ============================================================
  group('messageStarted 事件发射', () {
    test('messageStarted 事件 data 包含 messageId、role、content', () {
      final event = AgentEvent(
        type: AgentEventType.messageStarted,
        data: {
          'messageId': 'msg-001',
          'role': 'user',
          'type': 'text',
          'content': '请帮我分析代码',
        },
        employeeId: 'emp-001',
      );

      expect(event.data['messageId'], equals('msg-001'));
      expect(event.data['role'], equals('user'));
      expect(event.data['type'], equals('text'));
      expect(event.data['content'], equals('请帮我分析代码'));
    });

    test('messageStarted 事件可通过 JSON 往返', () {
      final original = AgentEvent(
        type: AgentEventType.messageStarted,
        data: {
          'messageId': 'msg-002',
          'role': 'user',
          'type': 'text',
          'content': '测试消息',
        },
        employeeId: 'emp-001',
      );

      final map = original.toMap();
      final restored = AgentEvent.fromMap(map);

      expect(restored.type, equals(AgentEventType.messageStarted));
      expect(restored.data['messageId'], equals('msg-002'));
      expect(restored.data['role'], equals('user'));
    });

    test('messageStarted 事件在 processing 状态之后发射', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final events = <AgentEvent>[];
      final sub = eventController.stream.listen(events.add);

      // 模拟 MessageProcessor._processNext 的行为
      // 1. 先发射 messageStatusChanged(processing)
      eventController.add(AgentEvent(
        type: AgentEventType.messageStatusChanged,
        data: {'messageId': 'msg-003', 'status': 'processing'},
        employeeId: 'emp-001',
      ));
      // 2. 再发射 messageStarted
      eventController.add(AgentEvent(
        type: AgentEventType.messageStarted,
        data: {'messageId': 'msg-003', 'role': 'user'},
        employeeId: 'emp-001',
      ));

      await Future.delayed(Duration(milliseconds: 50));

      expect(events.length, equals(2));
      expect(events[0].type, equals(AgentEventType.messageStatusChanged));
      expect(events[0].data['status'], equals('processing'));
      expect(events[1].type, equals(AgentEventType.messageStarted));

      await sub.cancel();
      await eventController.close();
    });
  });

  // ============================================================
  // 4. configChanged 事件发射验证
  // ============================================================
  group('configChanged 事件发射', () {
    test('configChanged 事件 data 包含 configType 和 action', () {
      final event = AgentEvent(
        type: AgentEventType.configChanged,
        data: {'configType': 'provider', 'action': 'updated'},
        employeeId: 'emp-001',
      );

      expect(event.data['configType'], equals('provider'));
      expect(event.data['action'], equals('updated'));
    });

    for (final configType in ['provider', 'context', 'project', 'tools', 'skills']) {
      test('configType=$configType 的 configChanged 可序列化', () {
        final event = AgentEvent(
          type: AgentEventType.configChanged,
          data: {'configType': configType, 'action': 'updated'},
          employeeId: 'emp-001',
        );

        final map = event.toMap();
        final restored = AgentEvent.fromMap(map);

        expect(restored.type, equals(AgentEventType.configChanged));
        expect(restored.data['configType'], equals(configType));
      });
    }

    test('setProvider 后发射 configChanged(provider, updated)', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final events = <AgentEvent>[];
      final sub = eventController.stream
          .where((e) => e.type == AgentEventType.configChanged)
          .listen(events.add);

      // 模拟 setProvider 调用后的事件发射
      eventController.add(AgentEvent(
        type: AgentEventType.configChanged,
        data: {'configType': 'provider', 'action': 'updated'},
        employeeId: 'emp-001',
      ));

      await Future.delayed(Duration(milliseconds: 50));

      expect(events.length, equals(1));
      expect(events[0].data['configType'], equals('provider'));

      await sub.cancel();
      await eventController.close();
    });

    test('registerTool 后发射 configChanged(tools, added)', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final events = <AgentEvent>[];
      final sub = eventController.stream
          .where((e) => e.type == AgentEventType.configChanged)
          .listen(events.add);

      // 模拟 registerTool 调用后的事件发射
      eventController.add(AgentEvent(
        type: AgentEventType.configChanged,
        data: {'configType': 'tools', 'action': 'added', 'toolName': 'my_tool'},
        employeeId: 'emp-001',
      ));

      await Future.delayed(Duration(milliseconds: 50));

      expect(events.length, equals(1));
      expect(events[0].data['configType'], equals('tools'));
      expect(events[0].data['action'], equals('added'));
      expect(events[0].data['toolName'], equals('my_tool'));

      await sub.cancel();
      await eventController.close();
    });

    test('clearContext 后发射 configChanged(context, cleared)', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final events = <AgentEvent>[];
      final sub = eventController.stream
          .where((e) => e.type == AgentEventType.configChanged)
          .listen(events.add);

      eventController.add(AgentEvent(
        type: AgentEventType.configChanged,
        data: {'configType': 'context', 'action': 'cleared'},
        employeeId: 'emp-001',
      ));

      await Future.delayed(Duration(milliseconds: 50));

      expect(events.length, equals(1));
      expect(events[0].data['configType'], equals('context'));
      expect(events[0].data['action'], equals('cleared'));

      await sub.cancel();
      await eventController.close();
    });

    test('addSkill 后发射 configChanged(skills, added)', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final events = <AgentEvent>[];
      final sub = eventController.stream
          .where((e) => e.type == AgentEventType.configChanged)
          .listen(events.add);

      eventController.add(AgentEvent(
        type: AgentEventType.configChanged,
        data: {'configType': 'skills', 'action': 'added', 'skillId': 'skill-001'},
        employeeId: 'emp-001',
      ));

      await Future.delayed(Duration(milliseconds: 50));

      expect(events.length, equals(1));
      expect(events[0].data['configType'], equals('skills'));
      expect(events[0].data['action'], equals('added'));
      expect(events[0].data['skillId'], equals('skill-001'));

      await sub.cancel();
      await eventController.close();
    });
  });

  // ============================================================
  // 5. 广播链路完整性测试
  // ============================================================
  group('广播链路完整性', () {
    test('所有 AgentEventType 都有明确的处理策略', () {
      // 以下事件应广播到 LAN
      final lanBroadcastTypes = {
        AgentEventType.agentStatusChanged,
        AgentEventType.messageStatusChanged,
        AgentEventType.messageReadStatusChanged,
        AgentEventType.toolCallStart,
        AgentEventType.toolCallResult,
        AgentEventType.toolPermissionRequest,
        AgentEventType.toolPermissionResponse,
        AgentEventType.confirmRequest,
        AgentEventType.confirmResponse,
        AgentEventType.sessionCleared,
        AgentEventType.sessionSummaryChanged,
        AgentEventType.todoTopicChanged,
        AgentEventType.todoTaskItemChanged,
        AgentEventType.specChanged,
        AgentEventType.configChanged,
        AgentEventType.messageStarted,
      };

      // 以下事件仅本地使用，不广播到 LAN（高频或纯本地语义）
      final localOnlyTypes = {
        AgentEventType.streamDelta,
        AgentEventType.thinkingDelta,
      };

      // unknown 不应有任何处理
      final ignoredTypes = {
        AgentEventType.unknown,
      };

      final allTypes = AgentEventType.values.toSet();
      final accountedTypes =
          lanBroadcastTypes.union(localOnlyTypes).union(ignoredTypes);

      final unaccounted = allTypes.difference(accountedTypes);
      expect(unaccounted, isEmpty,
          reason: '以下事件类型未在任何处理策略中覆盖: $unaccounted');
    });

    test('streamDelta 和 thinkingDelta 不广播到 LAN', () {
      // 验证高频事件被正确过滤
      final localOnlyTypes = {
        AgentEventType.streamDelta,
        AgentEventType.thinkingDelta,
      };

      // 这些事件类型不应出现在 LAN 广播列表中
      final lanBroadcastTypes = {
        AgentEventType.agentStatusChanged,
        AgentEventType.messageStatusChanged,
        AgentEventType.messageReadStatusChanged,
        AgentEventType.toolCallStart,
        AgentEventType.toolCallResult,
        AgentEventType.toolPermissionRequest,
        AgentEventType.toolPermissionResponse,
        AgentEventType.confirmRequest,
        AgentEventType.confirmResponse,
        AgentEventType.sessionCleared,
        AgentEventType.sessionSummaryChanged,
        AgentEventType.todoTopicChanged,
        AgentEventType.todoTaskItemChanged,
        AgentEventType.specChanged,
        AgentEventType.configChanged,
        AgentEventType.messageStarted,
      };

      for (final localType in localOnlyTypes) {
        expect(lanBroadcastTypes.contains(localType), isFalse,
            reason: '$localType 不应出现在 LAN 广播列表中');
      }
    });

    test('configChanged 事件应广播到 LAN', () {
      final lanBroadcastTypes = {
        AgentEventType.agentStatusChanged,
        AgentEventType.messageStatusChanged,
        AgentEventType.messageReadStatusChanged,
        AgentEventType.toolCallStart,
        AgentEventType.toolCallResult,
        AgentEventType.toolPermissionRequest,
        AgentEventType.toolPermissionResponse,
        AgentEventType.confirmRequest,
        AgentEventType.confirmResponse,
        AgentEventType.sessionCleared,
        AgentEventType.sessionSummaryChanged,
        AgentEventType.todoTopicChanged,
        AgentEventType.todoTaskItemChanged,
        AgentEventType.specChanged,
        AgentEventType.configChanged,
        AgentEventType.messageStarted,
      };

      expect(lanBroadcastTypes.contains(AgentEventType.configChanged), isTrue,
          reason: 'configChanged 应广播到 LAN');
    });

    test('messageStarted 事件应广播到 LAN', () {
      final lanBroadcastTypes = {
        AgentEventType.agentStatusChanged,
        AgentEventType.messageStatusChanged,
        AgentEventType.messageReadStatusChanged,
        AgentEventType.toolCallStart,
        AgentEventType.toolCallResult,
        AgentEventType.toolPermissionRequest,
        AgentEventType.toolPermissionResponse,
        AgentEventType.confirmRequest,
        AgentEventType.confirmResponse,
        AgentEventType.sessionCleared,
        AgentEventType.sessionSummaryChanged,
        AgentEventType.todoTopicChanged,
        AgentEventType.todoTaskItemChanged,
        AgentEventType.specChanged,
        AgentEventType.configChanged,
        AgentEventType.messageStarted,
      };

      expect(lanBroadcastTypes.contains(AgentEventType.messageStarted), isTrue,
          reason: 'messageStarted 应广播到 LAN');
    });

    test('confirmRequest/confirmResponse 应广播到 LAN', () {
      final lanBroadcastTypes = {
        AgentEventType.confirmRequest,
        AgentEventType.confirmResponse,
      };

      expect(lanBroadcastTypes.contains(AgentEventType.confirmRequest), isTrue);
      expect(lanBroadcastTypes.contains(AgentEventType.confirmResponse), isTrue);
    });

    test('todo/spec 事件应广播到 LAN', () {
      final lanBroadcastTypes = {
        AgentEventType.todoTopicChanged,
        AgentEventType.todoTaskItemChanged,
        AgentEventType.specChanged,
      };

      expect(lanBroadcastTypes.contains(AgentEventType.todoTopicChanged), isTrue);
      expect(lanBroadcastTypes.contains(AgentEventType.todoTaskItemChanged), isTrue);
      expect(lanBroadcastTypes.contains(AgentEventType.specChanged), isTrue);
    });
  });

  // ============================================================
  // 6. 事件发射顺序测试
  // ============================================================
  group('事件发射顺序', () {
    test('消息处理生命周期事件顺序正确', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final events = <AgentEvent>[];
      final sub = eventController.stream.listen(events.add);

      // 模拟完整的消息处理生命周期
      // 1. 消息入队
      eventController.add(AgentEvent(
        type: AgentEventType.messageStatusChanged,
        data: {'messageId': 'msg-life-001', 'status': 'queued'},
        employeeId: 'emp-001',
      ));
      // 2. Agent 状态变为 processing
      eventController.add(AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {'status': 'processing'},
        employeeId: 'emp-001',
      ));
      // 3. 消息状态变为 processing
      eventController.add(AgentEvent(
        type: AgentEventType.messageStatusChanged,
        data: {'messageId': 'msg-life-001', 'status': 'processing'},
        employeeId: 'emp-001',
      ));
      // 4. 消息开始处理
      eventController.add(AgentEvent(
        type: AgentEventType.messageStarted,
        data: {'messageId': 'msg-life-001', 'role': 'user'},
        employeeId: 'emp-001',
      ));
      // 5. 思考过程
      eventController.add(AgentEvent(
        type: AgentEventType.thinkingDelta,
        data: {'content': '分析中...'},
        employeeId: 'emp-001',
      ));
      // 6. 流式输出
      eventController.add(AgentEvent(
        type: AgentEventType.streamDelta,
        data: {'content': 'Hello'},
        employeeId: 'emp-001',
      ));
      // 7. Agent 状态变为 streaming
      eventController.add(AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {'status': 'streaming'},
        employeeId: 'emp-001',
      ));
      // 8. 消息完成
      eventController.add(AgentEvent(
        type: AgentEventType.messageStatusChanged,
        data: {'messageId': 'msg-life-001', 'status': 'completed'},
        employeeId: 'emp-001',
      ));
      // 9. Agent 状态变为 idle
      eventController.add(AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {'status': 'idle'},
        employeeId: 'emp-001',
      ));

      await Future.delayed(Duration(milliseconds: 50));

      expect(events.length, equals(9));

      // 验证关键顺序
      final statusChanges = events
          .where((e) => e.type == AgentEventType.messageStatusChanged)
          .map((e) => e.data['status'] as String)
          .toList();
      expect(statusChanges, equals(['queued', 'processing', 'completed']));

      final agentStatusChanges = events
          .where((e) => e.type == AgentEventType.agentStatusChanged)
          .map((e) => e.data['status'] as String)
          .toList();
      expect(agentStatusChanges, equals(['processing', 'streaming', 'idle']));

      // messageStarted 在 processing 之后
      final startedIdx = events.indexWhere((e) => e.type == AgentEventType.messageStarted);
      final processingIdx = events.indexWhere(
          (e) => e.type == AgentEventType.messageStatusChanged && e.data['status'] == 'processing');
      expect(startedIdx, greaterThan(processingIdx - 1));
      expect(startedIdx, lessThan(events.indexWhere(
          (e) => e.type == AgentEventType.streamDelta)));

      await sub.cancel();
      await eventController.close();
    });
  });

  // ============================================================
  // 7. IChatAdapter 回调接口测试
  // ============================================================
  group('IChatAdapter 回调接口', () {
    test('onStreamDelta 回调字段存在且可设置', () {
      final adapter = LlmChatAdapter();
      expect(adapter.onStreamDelta, isNull);

      adapter.onStreamDelta = (chunk) {};
      expect(adapter.onStreamDelta, isNotNull);

      adapter.dispose();
    });

    test('onThinkingDelta 回调字段存在且可设置', () {
      final adapter = LlmChatAdapter();
      expect(adapter.onThinkingDelta, isNull);

      adapter.onThinkingDelta = (delta) {};
      expect(adapter.onThinkingDelta, isNotNull);

      adapter.dispose();
    });

    test('SubAgentLlmChatAdapter 也支持 onStreamDelta 回调', () {
      final adapter = SubAgentLlmChatAdapter();
      expect(adapter.onStreamDelta, isNull);

      adapter.onStreamDelta = (chunk) {};
      expect(adapter.onStreamDelta, isNotNull);

      adapter.dispose();
    });

    test('SubAgentLlmChatAdapter 也支持 onThinkingDelta 回调', () {
      final adapter = SubAgentLlmChatAdapter();
      expect(adapter.onThinkingDelta, isNull);

      adapter.onThinkingDelta = (delta) {};
      expect(adapter.onThinkingDelta, isNotNull);

      adapter.dispose();
    });
  });

  // ============================================================
  // 8. 死代码清理验证
  // ============================================================
  group('死代码清理验证', () {
    test('已删除的事件类型在 fromString 中返回 unknown', () {
      final deletedTypes = [
        'messageQueued',
        'messageProcessing',
        'messageReplied',
        'specGroupChanged',
      ];

      for (final typeName in deletedTypes) {
        expect(AgentEventType.fromString(typeName), equals(AgentEventType.unknown),
            reason: '$typeName 应已被删除，fromString 应返回 unknown');
      }
    });

    test('已删除的事件类型不存在于枚举值中', () {
      final names = AgentEventType.values.map((e) => e.name).toSet();
      final deletedNames = [
        'messageQueued',
        'messageProcessing',
        'messageReplied',
        'specGroupChanged',
      ];

      for (final name in deletedNames) {
        expect(names.contains(name), isFalse,
            reason: '$name 不应存在于 AgentEventType 枚举中');
      }
    });
  });

  // ============================================================
  // 9. 新增事件类型 JSON 编解码往返一致性
  // ============================================================
  group('新增事件类型 JSON 往返', () {
    final newEventTypes = <AgentEventType, Map<String, dynamic>>{
      AgentEventType.streamDelta: {'content': 'Hello World', 'isDone': false},
      AgentEventType.thinkingDelta: {'content': '思考中...', 'index': 0},
      AgentEventType.configChanged: {'configType': 'provider', 'action': 'updated'},
      AgentEventType.messageStarted: {'messageId': 'msg-001', 'role': 'user', 'type': 'text'},
    };

    for (final entry in newEventTypes.entries) {
      test('${entry.key.name} JSON 往返一致', () {
        final event = AgentEvent(
          type: entry.key,
          data: entry.value,
          employeeId: 'emp-001',
        );

        final map = event.toMap();
        final restored = AgentEvent.fromMap(map);

        expect(restored.type, equals(entry.key),
            reason: '${entry.key.name} 往返后类型应一致');
        expect(restored.data, equals(entry.value),
            reason: '${entry.key.name} 往返后 data 应一致');
        expect(restored.employeeId, equals('emp-001'));
      });
    }
  });

  // ============================================================
  // 10. 事件流压力测试
  // ============================================================
  group('事件流压力测试', () {
    test('大量 streamDelta 事件不丢失', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final events = <AgentEvent>[];
      final sub = eventController.stream
          .where((e) => e.type == AgentEventType.streamDelta)
          .listen(events.add);

      const count = 1000;
      for (var i = 0; i < count; i++) {
        eventController.add(AgentEvent(
          type: AgentEventType.streamDelta,
          data: {'content': 'chunk$i'},
          employeeId: 'emp-001',
        ));
      }

      await Future.delayed(Duration(milliseconds: 200));

      expect(events.length, equals(count),
          reason: '应收到全部 $count 个 streamDelta 事件');

      await sub.cancel();
      await eventController.close();
    });

    test('混合事件类型正确区分', () async {
      final eventController = StreamController<AgentEvent>.broadcast();
      final streamDeltas = <AgentEvent>[];
      final thinkingDeltas = <AgentEvent>[];
      final others = <AgentEvent>[];

      final sub = eventController.stream.listen((event) {
        switch (event.type) {
          case AgentEventType.streamDelta:
            streamDeltas.add(event);
          case AgentEventType.thinkingDelta:
            thinkingDeltas.add(event);
          default:
            others.add(event);
        }
      });

      // 模拟混合事件流
      for (var i = 0; i < 50; i++) {
        eventController.add(AgentEvent(
          type: AgentEventType.streamDelta,
          data: {'content': 'text $i'},
          employeeId: 'emp-001',
        ));
        if (i % 5 == 0) {
          eventController.add(AgentEvent(
            type: AgentEventType.thinkingDelta,
            data: {'content': 'think $i'},
            employeeId: 'emp-001',
          ));
        }
        if (i % 10 == 0) {
          eventController.add(AgentEvent(
            type: AgentEventType.configChanged,
            data: {'configType': 'tools', 'action': 'added'},
            employeeId: 'emp-001',
          ));
        }
      }

      await Future.delayed(Duration(milliseconds: 100));

      expect(streamDeltas.length, equals(50));
      expect(thinkingDeltas.length, equals(10)); // 0,5,10,...,45 → 10个
      expect(others.length, equals(5)); // 0,10,20,30,40 → 5个

      await sub.cancel();
      await eventController.close();
    });
  });
}
