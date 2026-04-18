import 'dart:convert';

import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

/// Event 系统完整性测试
///
/// 覆盖：
/// - AgentEventType 枚举序列化/反序列化
/// - AgentEvent 实体序列化/反序列化
/// - ToolEvent sealed class 及 ToolEventMapper
/// - AgentNotificationEvent sealed class
/// - 事件处理逻辑（路由、权限响应、会话摘要）
/// - 广播链路完整性
/// - 死代码清理验证
void main() {
  // ============================================================
  // 1. AgentEventType 枚举测试
  // ============================================================
  group('AgentEventType', () {
    test('所有枚举值的 value 属性返回正确的字符串', () {
      for (final type in AgentEventType.values) {
        if (type == AgentEventType.unknown) continue;
        expect(type.value, equals(type.name),
            reason: '$type.value 应等于 ${type.name}');
      }
    });

    test('fromString 正确解析所有已知类型', () {
      for (final type in AgentEventType.values) {
        if (type == AgentEventType.unknown) continue;
        final parsed = AgentEventType.fromString(type.name);
        expect(parsed, equals(type),
            reason: 'fromString("${type.name}") 应返回 $type');
      }
    });

    test('fromString 对未知字符串返回 unknown', () {
      expect(AgentEventType.fromString('nonExistentEvent'),
          equals(AgentEventType.unknown));
      expect(AgentEventType.fromString(''), equals(AgentEventType.unknown));
      expect(AgentEventType.fromString('messageQueued'),
          equals(AgentEventType.unknown),
          reason: '已删除的 messageQueued 应返回 unknown');
      expect(AgentEventType.fromString('messageProcessing'),
          equals(AgentEventType.unknown),
          reason: '已删除的 messageProcessing 应返回 unknown');
      expect(AgentEventType.fromString('messageReplied'),
          equals(AgentEventType.unknown),
          reason: '已删除的 messageReplied 应返回 unknown');
      expect(AgentEventType.fromString('specGroupChanged'),
          equals(AgentEventType.unknown),
          reason: '已删除的 specGroupChanged 应返回 unknown');
    });

    test('新增事件类型枚举值存在', () {
      expect(AgentEventType.values.contains(AgentEventType.thinkingDelta),
          isTrue, reason: 'thinkingDelta 应存在');
      expect(AgentEventType.values.contains(AgentEventType.streamDelta),
          isTrue, reason: 'streamDelta 应存在');
      expect(AgentEventType.values.contains(AgentEventType.configChanged),
          isTrue, reason: 'configChanged 应存在');
      expect(AgentEventType.values.contains(AgentEventType.messageStarted),
          isTrue, reason: 'messageStarted 应存在');
    });

    test('已删除的事件类型枚举值不存在', () {
      final names = AgentEventType.values.map((e) => e.name).toSet();
      expect(names.contains('messageQueued'), isFalse,
          reason: 'messageQueued 应已删除');
      expect(names.contains('messageProcessing'), isFalse,
          reason: 'messageProcessing 应已删除');
      expect(names.contains('messageReplied'), isFalse,
          reason: 'messageReplied 应已删除');
      expect(names.contains('specGroupChanged'), isFalse,
          reason: 'specGroupChanged 应已删除');
    });
  });

  // ============================================================
  // 2. AgentEvent 实体测试
  // ============================================================
  group('AgentEvent', () {
    test('构造函数正确设置所有字段', () {
      final event = AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: {'status': 'idle', 'queueLength': 0},
        employeeId: 'emp-001',
        fromDeviceId: 'dev-001',
      );

      expect(event.type, equals(AgentEventType.agentStatusChanged));
      expect(event.data, equals({'status': 'idle', 'queueLength': 0}));
      expect(event.employeeId, equals('emp-001'));
      expect(event.fromDeviceId, equals('dev-001'));
    });

    test('employeeId 和 fromDeviceId 可选', () {
      final event = AgentEvent(
        type: AgentEventType.messageStatusChanged,
        data: {'messageId': 'msg-001', 'status': 'completed'},
      );

      expect(event.employeeId, isNull);
      expect(event.fromDeviceId, isNull);
    });

    test('toMap 序列化输出正确格式', () {
      final event = AgentEvent(
        type: AgentEventType.toolCallStart,
        data: {
          'toolCallId': 'tc-001',
          'toolName': 'file_read',
          'arguments': {'path': '/tmp/test.txt'},
        },
        employeeId: 'emp-001',
        fromDeviceId: 'dev-001',
      );

      final map = event.toMap();
      expect(map['type'], equals('toolCallStart'));
      expect(map['data'], isA<Map>());
      expect(map['employeeId'], equals('emp-001'));
      expect(map['fromDeviceId'], equals('dev-001'));
    });

    test('toMap 省略 null 字段', () {
      final event = AgentEvent(
        type: AgentEventType.sessionCleared,
        data: {'employeeId': 'emp-001'},
      );

      final map = event.toMap();
      expect(map.containsKey('employeeId'), isFalse);
      expect(map.containsKey('fromDeviceId'), isFalse);
    });

    test('fromMap 反序列化正确还原所有字段', () {
      final map = {
        'type': 'agentStatusChanged',
        'data': {'status': 'processing'},
        'employeeId': 'emp-002',
        'fromDeviceId': 'dev-002',
      };

      final event = AgentEvent.fromMap(map);
      expect(event.type, equals(AgentEventType.agentStatusChanged));
      expect(event.data, equals({'status': 'processing'}));
      expect(event.employeeId, equals('emp-002'));
      expect(event.fromDeviceId, equals('dev-002'));
    });

    test('fromMap 兼容旧字段 fromId → fromDeviceId', () {
      final map = {
        'type': 'messageStatusChanged',
        'data': {'status': 'completed'},
        'fromId': 'old-dev-001',
      };

      final event = AgentEvent.fromMap(map);
      expect(event.fromDeviceId, equals('old-dev-001'));
    });

    test('fromMap 优先使用 fromDeviceId 而非 fromId', () {
      final map = {
        'type': 'messageStatusChanged',
        'data': {},
        'fromDeviceId': 'new-dev-001',
        'fromId': 'old-dev-001',
      };

      final event = AgentEvent.fromMap(map);
      expect(event.fromDeviceId, equals('new-dev-001'));
    });

    test('fromMap 处理缺失字段（null safety）', () {
      final event = AgentEvent.fromMap({});
      expect(event.type, equals(AgentEventType.unknown));
      expect(event.data, equals({}));
      expect(event.employeeId, isNull);
      expect(event.fromDeviceId, isNull);
    });

    test('toMap/fromMap 往返一致性', () {
      final original = AgentEvent(
        type: AgentEventType.configChanged,
        data: {
          'configType': 'provider',
          'configData': {'model': 'gpt-4'},
        },
        employeeId: 'emp-003',
        fromDeviceId: 'dev-003',
      );

      final map = original.toMap();
      final restored = AgentEvent.fromMap(map);

      expect(restored.type, equals(original.type));
      expect(restored.data, equals(original.data));
      expect(restored.employeeId, equals(original.employeeId));
      expect(restored.fromDeviceId, equals(original.fromDeviceId));
    });

    test('toString 输出格式正确', () {
      final event = AgentEvent(
        type: AgentEventType.streamDelta,
        data: {'content': 'hello'},
        employeeId: 'emp-001',
      );

      final str = event.toString();
      expect(str, contains('streamDelta'));
      expect(str, contains('emp-001'));
    });

    test('新增事件类型可正确序列化/反序列化', () {
      for (final type in [
        AgentEventType.thinkingDelta,
        AgentEventType.streamDelta,
        AgentEventType.configChanged,
        AgentEventType.messageStarted,
      ]) {
        final event = AgentEvent(type: type, data: {'test': true});
        final map = event.toMap();
        final restored = AgentEvent.fromMap(map);
        expect(restored.type, equals(type),
            reason: '$type 序列化/反序列化往返应一致');
      }
    });
  });

  // ============================================================
  // 3. ToolEvent sealed class 测试
  // ============================================================
  group('ToolEvent', () {
    test('ToolCallStartEvent 构造和字段验证', () {
      final event = ToolCallStartEvent(
        toolCallId: 'tc-001',
        toolName: 'file_read',
        arguments: {'path': '/tmp/test.txt', 'offset': 0},
      );

      expect(event.toolCallId, equals('tc-001'));
      expect(event.toolName, equals('file_read'));
      expect(event.arguments, equals({'path': '/tmp/test.txt', 'offset': 0}));
      expect(event, isA<ToolCallStartEvent>());
      expect(event, isA<ToolEvent>());
    });

    test('ToolCallResultEvent 构造和字段验证', () {
      final event = ToolCallResultEvent(
        toolCallId: 'tc-001',
        toolName: 'file_read',
        result: 'file content here...',
        isError: false,
        durationMs: 150,
        denyReason: null,
      );

      expect(event.toolCallId, equals('tc-001'));
      expect(event.toolName, equals('file_read'));
      expect(event.result, equals('file content here...'));
      expect(event.isError, isFalse);
      expect(event.durationMs, equals(150));
      expect(event.denyReason, isNull);
      expect(event, isA<ToolCallResultEvent>());
    });

    test('ToolCallResultEvent 错误场景', () {
      final event = ToolCallResultEvent(
        toolCallId: 'tc-002',
        toolName: 'file_delete',
        result: '权限被拒绝',
        isError: true,
        denyReason: 'path matches deny pattern',
      );

      expect(event.isError, isTrue);
      expect(event.denyReason, equals('path matches deny pattern'));
    });

    test('ToolEventMapper.fromMap 正确解析 toolCallStart', () {
      final map = {
        'type': 'toolCallStart',
        'data': {
          'toolCallId': 'tc-003',
          'toolName': 'content_search',
          'arguments': {'pattern': 'test', 'path': '/src'},
        },
      };

      final event = ToolEventMapper.fromMap(map);
      expect(event, isA<ToolCallStartEvent>());

      final startEvent = event as ToolCallStartEvent;
      expect(startEvent.toolCallId, equals('tc-003'));
      expect(startEvent.toolName, equals('content_search'));
      expect(startEvent.arguments['pattern'], equals('test'));
    });

    test('ToolEventMapper.fromMap 正确解析 toolCallResult（含可选字段）', () {
      final map = {
        'type': 'toolCallResult',
        'data': {
          'toolCallId': 'tc-004',
          'toolName': 'command_execute',
          'result': 'output...',
          'isError': false,
          'durationMs': 2000,
          'denyReason': null,
        },
      };

      final event = ToolEventMapper.fromMap(map);
      expect(event, isA<ToolCallResultEvent>());

      final resultEvent = event as ToolCallResultEvent;
      expect(resultEvent.toolCallId, equals('tc-004'));
      expect(resultEvent.result, equals('output...'));
      expect(resultEvent.isError, isFalse);
      expect(resultEvent.durationMs, equals(2000));
    });

    test('ToolEventMapper.fromMap 处理缺失可选字段', () {
      final map = {
        'type': 'toolCallResult',
        'data': {
          'toolCallId': 'tc-005',
          'toolName': 'web_fetch',
          'result': '',
          'isError': true,
        },
      };

      final event = ToolEventMapper.fromMap(map) as ToolCallResultEvent;
      expect(event.durationMs, isNull);
      expect(event.denyReason, isNull);
    });

    test('ToolEventMapper.toMap 正确序列化 ToolCallStartEvent', () {
      final event = ToolCallStartEvent(
        toolCallId: 'tc-006',
        toolName: 'git_operations',
        arguments: {'action': 'status'},
      );

      final map = ToolEventMapper.toMap(event);
      expect(map['type'], equals('toolCallStart'));
      expect(map['data']['toolCallId'], equals('tc-006'));
      expect(map['data']['toolName'], equals('git_operations'));
      expect(map['data']['arguments'], equals({'action': 'status'}));
    });

    test('ToolEventMapper.toMap 正确序列化 ToolCallResultEvent', () {
      final event = ToolCallResultEvent(
        toolCallId: 'tc-007',
        toolName: 'file_write',
        result: 'OK',
        isError: false,
        durationMs: 50,
      );

      final map = ToolEventMapper.toMap(event);
      expect(map['type'], equals('toolCallResult'));
      expect(map['data']['toolCallId'], equals('tc-007'));
      expect(map['data']['result'], equals('OK'));
      expect(map['data']['isError'], isFalse);
      expect(map['data']['durationMs'], equals(50));
    });

    test('ToolEventMapper toMap→fromMap 往返一致性', () {
      final events = <ToolEvent>[
        ToolCallStartEvent(
          toolCallId: 'tc-round-1',
          toolName: 'test_tool',
          arguments: {'key': 'value'},
        ),
        ToolCallResultEvent(
          toolCallId: 'tc-round-2',
          toolName: 'test_tool',
          result: 'success',
          isError: false,
          durationMs: 100,
          denyReason: null,
        ),
      ];

      for (final original in events) {
        final map = ToolEventMapper.toMap(original);
        final restored = ToolEventMapper.fromMap(map);

        expect(restored.toolCallId, equals(original.toolCallId));
        expect(restored.toolName, equals(original.toolName));

        if (original is ToolCallStartEvent) {
          final r = restored as ToolCallStartEvent;
          final o = original;
          expect(r.arguments, equals(o.arguments));
        } else if (original is ToolCallResultEvent) {
          final r = restored as ToolCallResultEvent;
          final o = original;
          expect(r.result, equals(o.result));
          expect(r.isError, equals(o.isError));
          expect(r.durationMs, equals(o.durationMs));
        }
      }
    });
  });

  // ============================================================
  // 4. AgentNotificationEvent sealed class 测试
  // ============================================================
  group('AgentNotificationEvent', () {
    test('AgentMessageArrivedEvent 字段正确', () {
      final msg = AgentMessage(
        id: 'msg-001',
        role: 'assistant',
        type: 'text',
        content: 'Hello',
        createdAt: DateTime.now(),
      );

      final event = AgentMessageArrivedEvent(
        message: msg,
        fromDeviceId: 'dev-001',
        toDeviceId: 'dev-002',
        employeeId: 'emp-001',
        isRemote: true,
      );

      expect(event.message.id, equals('msg-001'));
      expect(event.fromDeviceId, equals('dev-001'));
      expect(event.toDeviceId, equals('dev-002'));
      expect(event.employeeId, equals('emp-001'));
      expect(event.isRemote, isTrue);
    });

    test('AgentMessageReadStatusChangedEvent 字段正确', () {
      final event = AgentMessageReadStatusChangedEvent(
        messageId: 'msg-002',
        employeeId: 'emp-001',
        isRead: true,
        fromDeviceId: 'dev-001',
      );

      expect(event.messageId, equals('msg-002'));
      expect(event.isRead, isTrue);
      expect(event.fromDeviceId, equals('dev-001'));
    });

    test('AgentUnreadCountChangedEvent 字段正确', () {
      final event = AgentUnreadCountChangedEvent(
        employeeId: 'emp-001',
        fromDeviceId: 'dev-001',
        unreadCount: 5,
      );

      expect(event.employeeId, equals('emp-001'));
      expect(event.unreadCount, equals(5));
    });

    test('AgentLatestMessageUpdatedEvent 字段正确', () {
      final msg = AgentMessage(
        id: 'msg-003',
        role: 'assistant',
        type: 'text',
        content: 'Latest',
        createdAt: DateTime.now(),
      );

      final event = AgentLatestMessageUpdatedEvent(
        latestMessage: msg,
        employeeId: 'emp-001',
        fromDeviceId: 'dev-001',
        unreadCount: 3,
      );

      expect(event.latestMessage.id, equals('msg-003'));
      expect(event.unreadCount, equals(3));
    });

    test('AgentLatestMessageClearedEvent 字段正确', () {
      final event = AgentLatestMessageClearedEvent(
        employeeId: 'emp-001',
        fromDeviceId: 'dev-001',
      );

      expect(event.employeeId, equals('emp-001'));
      expect(event.fromDeviceId, equals('dev-001'));
    });

    test('AgentStatusNotifyEvent 字段正确', () {
      final event = AgentStatusNotifyEvent(
        employeeId: 'emp-001',
        fromDeviceId: 'dev-001',
        status: 'waitingPermission',
        extra: {'requestId': 'req-001'},
      );

      expect(event.status, equals('waitingPermission'));
      expect(event.extra?['requestId'], equals('req-001'));
    });
  });

  // ============================================================
  // 5. 事件数据结构测试
  // ============================================================
  group('事件数据结构', () {
    test('thinkingDelta 事件 data 结构', () {
      final data = {
        'messageId': 'msg-think-001',
        'content': '让我分析一下这个问题...',
        'index': 0,
      };

      final event = AgentEvent(
        type: AgentEventType.thinkingDelta,
        data: data,
        employeeId: 'emp-001',
      );

      expect(event.data['messageId'], equals('msg-think-001'));
      expect(event.data['content'], isA<String>());
      expect(event.data['index'], isA<int>());
    });

    test('streamDelta 事件 data 结构', () {
      final data = {
        'messageId': 'msg-stream-001',
        'content': 'Hello',
        'type': 'text',
        'isDone': false,
      };

      final event = AgentEvent(
        type: AgentEventType.streamDelta,
        data: data,
        employeeId: 'emp-001',
      );

      expect(event.data['messageId'], equals('msg-stream-001'));
      expect(event.data['type'], equals('text'));
      expect(event.data['isDone'], isFalse);
    });

    test('configChanged 事件 data 结构', () {
      final data = {
        'configType': 'provider',
        'configData': {
          'model': 'gpt-4',
          'temperature': 0.7,
        },
      };

      final event = AgentEvent(
        type: AgentEventType.configChanged,
        data: data,
        employeeId: 'emp-001',
      );

      expect(event.data['configType'], equals('provider'));
      expect(event.data['configData'], isA<Map>());
    });

    test('messageStarted 事件 data 结构', () {
      final data = {
        'messageId': 'msg-start-001',
        'role': 'user',
        'type': 'text',
        'content': '请帮我分析代码',
        'queuePosition': 1,
      };

      final event = AgentEvent(
        type: AgentEventType.messageStarted,
        data: data,
        employeeId: 'emp-001',
      );

      expect(event.data['messageId'], equals('msg-start-001'));
      expect(event.data['role'], equals('user'));
      expect(event.data['queuePosition'], equals(1));
    });

    test('permissionResponse 事件 data 包含 decision 和 scope', () {
      final data = {
        'requestId': 'perm-001',
        'decision': 'allow',
        'scope': 'pattern',
        'pattern': 'file_read.*',
      };

      final event = AgentEvent(
        type: AgentEventType.toolPermissionResponse,
        data: data,
        employeeId: 'emp-001',
      );

      expect(event.data['decision'], equals('allow'));
      expect(event.data['scope'], equals('pattern'));
      expect(event.data['pattern'], equals('file_read.*'));
    });
  });

  // ============================================================
  // 6. 广播链路完整性测试
  // ============================================================
  group('广播链路映射', () {
    test('所有 AgentEventType 都有明确的处理策略', () {
      // 验证每个事件类型在系统中都有处理逻辑
      // 不应该有事件落入"完全无处理"的状态

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
  });

  // ============================================================
  // 7. JSON 序列化往返测试
  // ============================================================
  group('JSON 序列化', () {
    test('AgentEvent JSON 往返一致性', () {
      final events = [
        AgentEvent(
          type: AgentEventType.agentStatusChanged,
          data: {'status': 'idle', 'queueLength': 0},
          employeeId: 'emp-001',
          fromDeviceId: 'dev-001',
        ),
        AgentEvent(
          type: AgentEventType.thinkingDelta,
          data: {'messageId': 'm1', 'content': '思考中...'},
        ),
        AgentEvent(
          type: AgentEventType.streamDelta,
          data: {'messageId': 'm1', 'content': 'Hello', 'isDone': false},
        ),
        AgentEvent(
          type: AgentEventType.configChanged,
          data: {'configType': 'provider', 'configData': {}},
          employeeId: 'emp-001',
        ),
        AgentEvent(
          type: AgentEventType.messageStarted,
          data: {'messageId': 'm2', 'role': 'user'},
          employeeId: 'emp-001',
        ),
        AgentEvent(
          type: AgentEventType.sessionSummaryChanged,
          data: {'summary': {'unreadCount': 3}},
          employeeId: 'emp-001',
        ),
      ];

      for (final original in events) {
        final jsonStr = jsonEncode(original.toMap());
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        final restored = AgentEvent.fromMap(map);

        expect(restored.type, equals(original.type),
            reason: '${original.type} JSON 往返失败');
        expect(restored.employeeId, equals(original.employeeId));
        expect(restored.fromDeviceId, equals(original.fromDeviceId));
      }
    });

    test('ToolEvent JSON 往返一致性', () {
      final events = <ToolEvent>[
        ToolCallStartEvent(
          toolCallId: 'tc-json-1',
          toolName: 'file_read',
          arguments: {'path': '/test.txt'},
        ),
        ToolCallResultEvent(
          toolCallId: 'tc-json-2',
          toolName: 'command_execute',
          result: 'done',
          isError: false,
          durationMs: 500,
        ),
      ];

      for (final original in events) {
        final map = ToolEventMapper.toMap(original);
        final jsonStr = jsonEncode(map);
        final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
        final restored = ToolEventMapper.fromMap(decoded);

        expect(restored.toolCallId, equals(original.toolCallId));
        expect(restored.toolName, equals(original.toolName));

        if (original is ToolCallStartEvent) {
          expect((restored as ToolCallStartEvent).arguments,
              equals(original.arguments));
        }
      }
    });
  });

  // ============================================================
  // 8. 边界条件和兼容性测试
  // ============================================================
  group('边界条件和兼容性', () {
    test('空 data 的 AgentEvent 正常工作', () {
      final event = AgentEvent(
        type: AgentEventType.unknown,
        data: {},
      );

      expect(event.data, isEmpty);
      expect(event.toMap()['data'], isEmpty);
    });

    test('超长 content 的 AgentEvent 正常序列化', () {
      final longContent = 'A' * 100000;
      final event = AgentEvent(
        type: AgentEventType.streamDelta,
        data: {'content': longContent},
      );

      final map = event.toMap();
      expect((map['data'] as Map)['content'] as String, hasLength(100000));
    });

    test('特殊字符的 AgentEvent 正常序列化', () {
      final specialContent = 'Hello\n\t\r"世界" 🌍 \\n';
      final event = AgentEvent(
        type: AgentEventType.streamDelta,
        data: {'content': specialContent},
      );

      final jsonStr = jsonEncode(event.toMap());
      final restored = AgentEvent.fromMap(jsonDecode(jsonStr));

      expect(restored.data['content'], equals(specialContent));
    });

    test('嵌套 Map 的 data 正常序列化', () {
      final data = {
        'level1': {
          'level2': {
            'level3': 'deep value',
          },
        },
        'list': [1, 2, 3],
        'bool': true,
        'null': null,
      };

      final event = AgentEvent(
        type: AgentEventType.configChanged,
        data: data,
      );

      final jsonStr = jsonEncode(event.toMap());
      final restored = AgentEvent.fromMap(jsonDecode(jsonStr));

      expect(restored.data['level1']['level2']['level3'], equals('deep value'));
      expect(restored.data['list'], equals([1, 2, 3]));
      expect(restored.data['bool'], isTrue);
      expect(restored.data['null'], isNull);
    });

    test('旧版事件数据兼容性', () {
      // 模拟旧版客户端发送的已删除事件类型
      final oldEvents = [
        {'type': 'messageQueued', 'data': {'messageId': 'old-1'}},
        {'type': 'messageProcessing', 'data': {'messageId': 'old-2'}},
        {'type': 'messageReplied', 'data': {'originalMessageId': 'o1'}},
        {'type': 'specGroupChanged', 'data': {'groupId': 'g1'}},
      ];

      for (final oldMap in oldEvents) {
        final event = AgentEvent.fromMap(oldMap);
        expect(event.type, equals(AgentEventType.unknown),
            reason: '旧事件类型 ${oldMap['type']} 应被解析为 unknown');
        // 不应抛出异常
      }
    });
  });
}
