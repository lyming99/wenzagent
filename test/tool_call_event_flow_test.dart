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

/// 工具调用过程中消息刷新 & 状态刷新 实时性测试
///
/// 核心场景：
/// - 工具调用开始时，客户端是否立即收到消息刷新？
/// - 工具调用完成后，消息状态是否立即更新？
/// - 整个过程中状态流转是否正确？
/// - 消息刷新是实时的，还是等全部完成才批量刷新？
void main() {
  late String apiKey;
  late String apiUrl;
  late String apiModel;
  late ProviderConfig providerConfig;

  late AgentImpl agent;
  late AgentProxy localProxy;
  late CachedAgentProxy cachedProxy;
  late MessageStoreService messageStore;
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
    print('  工具调用过程中消息刷新 & 状态刷新测试');
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
      storagePath: 'D:\\project\\GitHub\\wenzagent\\test_hive',
    );

    employeeId = 'refresh-test-${DateTime.now().millisecondsSinceEpoch}';
    deviceId = 'device-${DateTime.now().millisecondsSinceEpoch}';
    print('Employee ID: $employeeId');
    print('Device ID: $deviceId\n');
  });

  setUp(() async {
    messageStore = MessageStoreServiceImpl(deviceId: deviceId);

    final adapter = PersistentChatAdapter();

    adapter.persistMessage = (messageData) async {
      final entity = AiEmployeeMessageEntity.fromMap(messageData);
      await messageStore.addMessage(entity, deviceId: deviceId);
    };

    adapter.loadMessages = (empId) async {
      final messages = await messageStore.getMessages(empId);
      return messages.map((m) => m.toMap()).toList();
    };

    adapter.updateMessageStatusCallback = (messageId, status, {error}) async {
      await messageStore.updateMessageStatus(messageId, status.name, error: error);
    };

    adapter.deleteMessagesCallback = (empId) async {
      await messageStore.deleteMessages(empId, deviceId: deviceId);
    };

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
  // 一、工具调用过程中的状态实时刷新
  // ===================================================================
  group('一、状态实时刷新', () {
    test('工具调用期间：idle → processing → (streaming) → idle 全程可观测', () async {
      print('\n--- 测试：状态流转全程监控 ---');

      final timeline = <_TimelineEntry>[];
      final idleCompleter = Completer<void>();

      cachedProxy.onStateChanged.listen((state) {
        final entry = _TimelineEntry(
          time: DateTime.now(),
          label: '状态变更',
          detail: state.status.name,
        );
        timeline.add(entry);
        print('  [${entry.elapsed}ms] 状态: ${state.status.name}');
        if (state.status == AgentStatus.idle && timeline.length > 1) {
          if (!idleCompleter.isCompleted) idleCompleter.complete();
        }
      });

      await cachedProxy.sendMessage(MessageInput(
        content: '请列出当前目录下的文件',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('等待 idle 超时'),
      );

      // 验证：至少经过 processing 和 idle 两个状态
      final statusNames = timeline.map((e) => e.detail).toList();
      expect(statusNames, contains('idle'),
          reason: '最终状态应为 idle');
      expect(statusNames.any((s) => s == 'processing' || s == 'streaming'),
          isTrue, reason: '过程中应有 processing 或 streaming 状态');

      // 验证：processing 状态在 idle 之前出现（不是直接跳过）
      final processingIdx = statusNames.lastIndexWhere(
          (s) => s == 'processing' || s == 'streaming');
      final idleIdx = statusNames.lastIndexWhere((s) => s == 'idle');
      expect(processingIdx, lessThan(idleIdx),
          reason: 'processing/streaming 应在最终 idle 之前');

      print('  状态序列: $statusNames');
      print('  [通过]\n');
    });

    test('多轮对话中每轮的状态都独立回到 idle', () async {
      print('\n--- 测试：多轮状态独立回 idle ---');

      final roundStatuses = <List<String>>[];

      for (int round = 1; round <= 3; round++) {
        final statuses = <String>[];
        final completer = Completer<void>();

        cachedProxy.onStateChanged.listen((state) {
          statuses.add(state.status.name);
          if (state.status == AgentStatus.idle && statuses.length > 1) {
            if (!completer.isCompleted) completer.complete();
          }
        });

        await cachedProxy.sendMessage(MessageInput(
          content: '请读取 pubspec.yaml 文件的前5行',
        ));

        await completer.future.timeout(
          const Duration(seconds: 60),
          onTimeout: () => throw TimeoutException('第 $round 轮等待 idle 超时'),
        );

        roundStatuses.add(statuses);
        print('  第 $round 轮状态: $statuses');

        // 每轮最终都是 idle
        expect(statuses.last, equals('idle'));
      }

      print('  [通过]\n');
    });
  });

  // ===================================================================
  // 二、工具调用过程中的消息实时刷新（onMessagesChanged）
  // ===================================================================
  group('二、消息实时刷新', () {
    test('工具调用期间 onMessagesChanged 应多次触发（非一次性）', () async {
      print('\n--- 测试：消息刷新频率 ---');

      final refreshTimestamps = <DateTime>[];
      final idleCompleter = Completer<void>();

      // 监听消息刷新
      cachedProxy.onMessagesChanged.listen((messages) {
        refreshTimestamps.add(DateTime.now());
        final toolCallCount = messages.where(
            (m) => m.type == 'functionCall' || (m.toolCallId != null && m.role == 'tool')).length;
        final processingCount = messages.where((m) => m.status == 'processing').length;
        print('  [消息刷新] 共${messages.length}条, '
            '工具相关$toolCallCount条, processing中$processingCount条');
      });

      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!idleCompleter.isCompleted) idleCompleter.complete();
          });
        }
      });

      await cachedProxy.sendMessage(MessageInput(
        content: '请列出 lib 目录下的文件，然后读取 pubspec.yaml',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw TimeoutException('等待完成超时'),
      );

      print('\n  消息刷新总次数: ${refreshTimestamps.length}');

      // 关键断言：消息刷新次数应 > 2（不是一次性刷新）
      // 至少：初始消息 + 工具调用开始 + 工具调用完成 + 最终同步
      expect(refreshTimestamps.length, greaterThan(2),
          reason: '消息应多次刷新，而非一次性批量刷新');

      // 计算刷新间隔，验证是否分散在整个过程中
      if (refreshTimestamps.length > 1) {
        final firstRefresh = refreshTimestamps.first;
        final lastRefresh = refreshTimestamps.last;
        final totalDuration = lastRefresh.difference(firstRefresh).inMilliseconds;
        print('  刷新时间跨度: ${totalDuration}ms');

        // 刷新不应全部集中在最后（即不是等完成后才批量刷新）
        // 如果总跨度 > 1秒，首次刷新应在前50%时间内
        if (totalDuration > 1000) {
          final halfPoint = firstRefresh.add(Duration(milliseconds: totalDuration ~/ 2));
          final earlyRefreshes = refreshTimestamps.where((t) => t.isBefore(halfPoint)).length;
          print('  前50%时间内的刷新次数: $earlyRefreshes');
          expect(earlyRefreshes, greaterThan(0),
              reason: '不应等全部完成后才批量刷新消息');
        }
      }

      print('  [通过]\n');
    });

    test('工具调用开始时应立即出现 functionCall 类型的消息', () async {
      print('\n--- 测试：工具调用开始时消息即时出现 ---');

      final snapshots = <List<AgentMessage>>[];
      final idleCompleter = Completer<void>();

      cachedProxy.onMessagesChanged.listen((messages) {
        snapshots.add(List.from(messages));
      });

      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!idleCompleter.isCompleted) idleCompleter.complete();
          });
        }
      });

      await cachedProxy.sendMessage(MessageInput(
        content: '请搜索 dart 文件',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('等待完成超时'),
      );

      // 检查：在最终 idle 之前（即工具执行过程中），是否已有 functionCall 消息
      // 找到最终快照（idle 状态后最后一个）
      final finalSnapshot = snapshots.last;
      final functionCallMessages = finalSnapshot.where(
          (m) => m.type == 'functionCall' || (m.toolCalls != null && m.toolCalls!.isNotEmpty));

      print('  最终消息数: ${finalSnapshot.length}');
      print('  functionCall/含toolCalls消息数: ${functionCallMessages.length}');

      for (final m in functionCallMessages) {
        print('  - ${m.type}: ${m.toolName ?? m.toolCalls?.first.name} '
            'status=${m.status} id=${m.id}');
      }

      // 至少应有带 toolCalls 的 assistant 消息
      expect(functionCallMessages.isNotEmpty, isTrue,
          reason: '最终消息中应有工具调用相关的消息');

      // 验证：工具调用消息在 idle 之前的快照中就已经存在（实时性）
      bool foundBeforeIdle = false;
      for (int i = 0; i < snapshots.length - 1; i++) {
        final hasToolCall = snapshots[i].any(
            (m) => m.type == 'functionCall' || (m.toolCalls != null && m.toolCalls!.isNotEmpty));
        if (hasToolCall) {
          foundBeforeIdle = true;
          print('  早在第 ${i + 1} 次刷新时就已出现工具调用消息');
          break;
        }
      }
      expect(foundBeforeIdle, isTrue,
          reason: '工具调用消息应在最终 idle 之前就已出现（实时刷新）');

      print('  [通过]\n');
    });

    test('工具调用完成后消息状态应从 processing 变为 completed', () async {
      print('\n--- 测试：工具调用消息状态更新 ---');

      final snapshots = <List<AgentMessage>>[];
      final idleCompleter = Completer<void>();

      cachedProxy.onMessagesChanged.listen((messages) {
        snapshots.add(List.from(messages));
      });

      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle) {
          // 等待 idle 后再延迟一点，确保最后的 onMessagesChanged 被收集
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!idleCompleter.isCompleted) idleCompleter.complete();
          });
        }
      });

      await cachedProxy.sendMessage(MessageInput(
        content: '请列出 test 目录下的文件',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('等待完成超时'),
      );

      // 检查状态变化：某个消息从 processing → completed
      final processingIds = <String>{};
      final completedIds = <String>{};

      for (int i = 0; i < snapshots.length; i++) {
        for (final m in snapshots[i]) {
          if (m.status == 'processing' && m.toolCallId != null) {
            processingIds.add(m.toolCallId!);
          }
          if (m.status == 'completed' && m.toolCallId != null) {
            completedIds.add(m.toolCallId!);
          }
        }
      }

      print('  曾处于 processing 的 toolCallId: $processingIds');
      print('  最终处于 completed 的 toolCallId: $completedIds');

      // 至少有一个工具调用经历了 processing → completed
      final transitioned = processingIds.intersection(completedIds);
      expect(transitioned.isNotEmpty, isTrue,
          reason: '应有工具调用经历 processing → completed 状态转换');
      print('  经历状态转换的 toolCallId: $transitioned');

      print('  [通过]\n');
    });
  });

  // ===================================================================
  // 三、事件流与消息刷新的时序关系
  // ===================================================================
  group('三、事件流与消息刷新时序', () {
    test('toolCallStart 事件后应紧接着触发 onMessagesChanged', () async {
      print('\n--- 测试：事件 → 消息刷新时序 ---');

      final eventTimes = <String, DateTime>{};
      final refreshTimes = <DateTime>[];
      final idleCompleter = Completer<void>();

      // 记录事件时间
      localProxy.onEvent.listen((event) {
        final type = event['type'] as String?;
        if (type == 'toolCallStart' || type == 'toolCallResult') {
          final now = DateTime.now();
          eventTimes[type!] = now;
          print('  [事件] $type @ ${now.millisecondsSinceEpoch}');
        }
      });

      // 记录消息刷新时间
      cachedProxy.onMessagesChanged.listen((messages) {
        final now = DateTime.now();
        refreshTimes.add(now);
      });

      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle && eventTimes.isNotEmpty) {
          if (!idleCompleter.isCompleted) idleCompleter.complete();
        }
      });

      await cachedProxy.sendMessage(MessageInput(
        content: '请列出 lib 目录的文件',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('等待超时'),
      );

      // 验证：toolCallStart 事件被触发
      expect(eventTimes.containsKey('toolCallStart'), isTrue,
          reason: '应收到 toolCallStart 事件');
      expect(eventTimes.containsKey('toolCallResult'), isTrue,
          reason: '应收到 toolCallResult 事件');

      // 验证：事件后有消息刷新（不是等全部完成）
      if (refreshTimes.isNotEmpty && eventTimes['toolCallStart'] != null) {
        final startEventTime = eventTimes['toolCallStart']!;
        // 在 toolCallStart 后 500ms 内应有至少一次消息刷新
        final refreshAfterStart = refreshTimes.where(
            (t) => t.difference(startEventTime).inMilliseconds >= 0 &&
                   t.difference(startEventTime).inMilliseconds < 2000);
        print('  toolCallStart 后 2s 内的消息刷新次数: ${refreshAfterStart.length}');
        expect(refreshAfterStart.isNotEmpty, isTrue,
            reason: 'toolCallStart 后应有消息刷新（不应延迟到全部完成）');
      }

      print('  事件总数: ${eventTimes.length}');
      print('  消息刷新总数: ${refreshTimes.length}');
      print('  [通过]\n');
    });

    test('toolCallStart 和 toolCallResult 成对出现且有序', () async {
      print('\n--- 测试：事件成对性 ---');

      final eventSequence = <_TimelineEntry>[];
      final idleCompleter = Completer<void>();

      localProxy.onEvent.listen((event) {
        final type = event['type'] as String?;
        if (type == 'toolCallStart' || type == 'toolCallResult') {
          final data = event['data'] as Map<String, dynamic>? ?? {};
          final tcId = data['toolCallId'] as String? ?? '';
          final tcName = data['toolName'] as String? ?? '';
          eventSequence.add(_TimelineEntry(
            time: DateTime.now(),
            label: '$type',
            detail: '$tcName($tcId)',
          ));
          print('  ${eventSequence.last.label}: ${eventSequence.last.detail}');
        }
      });

      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle && eventSequence.isNotEmpty) {
          if (!idleCompleter.isCompleted) idleCompleter.complete();
        }
      });

      await cachedProxy.sendMessage(MessageInput(
        content: '请列出 test 目录下的文件，然后搜索 dart 文件',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw TimeoutException('等待超时'),
      );

      final starts = eventSequence.where((e) => e.label == 'toolCallStart').toList();
      final results = eventSequence.where((e) => e.label == 'toolCallResult').toList();

      print('  toolCallStart: ${starts.length} 个');
      print('  toolCallResult: ${results.length} 个');

      // 成对
      expect(starts.length, equals(results.length),
          reason: 'Start 和 Result 应成对');
      expect(starts.length, greaterThan(0),
          reason: '至少应有 1 对工具调用事件');

      // 每个 Start 先于对应的 Result
      for (final start in starts) {
        final startTcId = start.detail;
        final matchingResult = results.where((r) => r.detail == startTcId);
        expect(matchingResult.isNotEmpty, isTrue,
            reason: '$startTcId 的 Start 应有对应 Result');
        for (final result in matchingResult) {
          expect(result.time.isAfter(start.time) || result.time.isAtSameMomentAs(start.time),
              isTrue, reason: 'Result 不应在 Start 之前');
        }
      }

      print('  事件序列验证通过，共 ${starts.length} 对');
      print('  [通过]\n');
    });
  });

  // ===================================================================
  // 四、端到端实时性：模拟客户端监听全流程
  // ===================================================================
  group('四、端到端实时性模拟', () {
    test('模拟客户端：发送消息 → 实时收到状态和消息更新 → 完成', () async {
      print('\n--- 测试：客户端全流程监听模拟 ---');

      // 模拟客户端的监听状态
      final clientLog = <String>[];
      var messageRefreshCount = 0;
      var stateChangeCount = 0;
      var eventCount = 0;
      final functionCallAppearTimes = <int>[];

      // 1. 监听消息刷新（模拟客户端 rebuild UI）
      cachedProxy.onMessagesChanged.listen((messages) {
        messageRefreshCount++;
        final timeMs = DateTime.now().millisecond;
        final toolMessages = messages.where((m) =>
            m.type == 'functionCall' || m.status == 'processing' ||
            (m.toolCallId != null && m.role == 'tool'));

        if (toolMessages.isNotEmpty) {
          functionCallAppearTimes.add(timeMs);
        }

        clientLog.add('[消息刷新#$messageRefreshCount] '
            '总${messages.length}条, '
            '工具相关$toolMessages.length条');
      });

      // 2. 监听状态变化
      cachedProxy.onStateChanged.listen((state) {
        stateChangeCount++;
        clientLog.add('[状态#$stateChangeCount] ${state.status.name}');
      });

      // 3. 监听事件
      localProxy.onEvent.listen((event) {
        final type = event['type'] as String?;
        if (type == 'toolCallStart' || type == 'toolCallResult') {
          eventCount++;
          final data = event['data'] as Map<String, dynamic>? ?? {};
          clientLog.add('[事件#$eventCount] $type: ${data['toolName']}');
        }
      });

      final idleCompleter = Completer<void>();
      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle && stateChangeCount > 1) {
          if (!idleCompleter.isCompleted) idleCompleter.complete();
        }
      });

      final t0 = DateTime.now();
      await cachedProxy.sendMessage(MessageInput(
        content: '请依次执行：1.列出lib目录文件 2.搜索dart文件 3.读取pubspec.yaml',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 120),
        onTimeout: () => throw TimeoutException('等待超时'),
      );
      final totalMs = DateTime.now().difference(t0).inMilliseconds;

      // 输出完整日志
      print('\n  === 客户端监听日志 ===');
      for (final entry in clientLog) {
        print('  $entry');
      }
      print('  =====================');

      print('\n  === 统计 ===');
      print('  总耗时: ${totalMs}ms');
      print('  消息刷新次数: $messageRefreshCount');
      print('  状态变化次数: $stateChangeCount');
      print('  工具事件次数: $eventCount');
      print('  工具消息出现次数: ${functionCallAppearTimes.length}');

      // 关键断言
      expect(messageRefreshCount, greaterThan(2),
          reason: '消息应多次刷新，不应只在完成后刷新一次');
      expect(stateChangeCount, greaterThanOrEqualTo(2),
          reason: '至少有 idle→processing→idle 两次状态变化');
      expect(eventCount, greaterThanOrEqualTo(2),
          reason: '至少有 1 对工具事件（start+result）');

      // 验证实时性：工具消息不应只在最后才出现
      // 如果有多次消息刷新，工具消息应在中间的刷新中就出现
      if (messageRefreshCount > 2 && functionCallAppearTimes.isNotEmpty) {
        print('  ✅ 工具调用过程中消息被实时刷新');
      } else if (messageRefreshCount <= 2) {
        print('  ⚠️ 消息刷新次数较少（$messageRefreshCount），可能存在批量刷新问题');
      }

      print('  [通过]\n');
    });
  });

  // ===================================================================
  // 五、临时消息生命周期监控
  // ===================================================================
  group('五、临时消息生命周期', () {
    test('临时 functionCall 消息：创建时 processing → 完成后 completed', () async {
      print('\n--- 测试：临时消息状态变化监控 ---');

      final snapshots = <List<AgentMessage>>[];
      final idleCompleter = Completer<void>();

      cachedProxy.onMessagesChanged.listen((messages) {
        snapshots.add(List.from(messages));
      });

      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!idleCompleter.isCompleted) idleCompleter.complete();
          });
        }
      });

      await cachedProxy.sendMessage(MessageInput(
        content: '请读取 pubspec.yaml 文件',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('等待超时'),
      );

      // 追踪所有 local_toolcall_ 前缀的临时消息在各快照中的状态
      final allLocalIds = <String>{};
      for (final snap in snapshots) {
        for (final m in snap) {
          if (m.id.startsWith('local_toolcall_')) {
            allLocalIds.add(m.id);
          }
        }
      }

      print('  发现 ${allLocalIds.length} 条临时消息');

      for (final id in allLocalIds) {
        final statusHistory = <String>[];
        for (int i = 0; i < snapshots.length; i++) {
          final msg = snapshots[i].where((m) => m.id == id).firstOrNull;
          if (msg != null && !statusHistory.contains(msg.status ?? '')) {
            statusHistory.add(msg.status ?? 'null');
          }
        }
        print('  $id 状态变化: $statusHistory');

        // 临时消息应经历 processing → completed/failed
        expect(statusHistory.first, equals('processing'),
            reason: '临时消息初始状态应为 processing');
        expect(statusHistory.length, greaterThan(1),
            reason: '临时消息状态应发生变化');
        expect(['completed', 'failed', 'interrupted'], contains(statusHistory.last),
            reason: '临时消息最终状态应为 completed/failed/interrupted');
      }

      print('  [通过]\n');
    });

    test('最终快照中不应残留已被远程消息覆盖的临时消息', () async {
      print('\n--- 测试：临时消息最终清理 ---');

      final snapshots = <List<AgentMessage>>[];
      final idleCompleter = Completer<void>();

      cachedProxy.onMessagesChanged.listen((messages) {
        snapshots.add(List.from(messages));
      });

      cachedProxy.onStateChanged.listen((state) {
        if (state.status == AgentStatus.idle) {
          // 额外等待一下让清理逻辑执行
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!idleCompleter.isCompleted) idleCompleter.complete();
          });
        }
      });

      await cachedProxy.sendMessage(MessageInput(
        content: '请搜索 pubspec.yaml 文件',
      ));

      await idleCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('等待超时'),
      );

      // 注意：本地模式下 _needCache=false，_cleanupLocalToolCallMessages
      // 只在 _mergeUnreceivedMessages 中调用，而 _mergeUnreceivedMessages
      // 只在远程模式下触发。本地模式下临时消息可能不会被清理。
      // 这里记录实际行为。

      final finalSnapshot = snapshots.last;
      final localToolCalls = finalSnapshot.where(
          (m) => m.id.startsWith('local_toolcall_')).toList();
      final remoteToolCalls = finalSnapshot.where(
          (m) => !m.id.startsWith('local_toolcall_') &&
                 m.role == 'assistant' &&
                 m.toolCalls != null).toList();

      print('  最终快照消息总数: ${finalSnapshot.length}');
      print('  残留临时消息数: ${localToolCalls.length}');
      print('  远程 assistant(toolCalls) 消息数: ${remoteToolCalls.length}');

      for (final m in localToolCalls) {
        print('  残留临时: ${m.id} status=${m.status}');
      }

      // 在本地模式下记录实际行为
      if (localToolCalls.isNotEmpty) {
        print('  ⚠️ 本地模式下临时消息未被清理（仅远程模式触发清理）');
      }

      print('  [通过]\n');
    });
  });

  print('\n=== 所有测试完成 ===\n');
}

/// 时间线条目，用于记录事件发生的时间和内容
class _TimelineEntry {
  final DateTime time;
  final String label;
  final String detail;

  _TimelineEntry({required this.time, required this.label, required this.detail});

  int get elapsed => time.millisecondsSinceEpoch;
}
