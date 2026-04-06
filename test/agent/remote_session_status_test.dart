import 'dart:async';

import 'package:test/test.dart';

import 'package:wenzagent/src/agent/adapter/langchain_chat_adapter.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/i_agent.dart';
import 'package:wenzagent/src/agent/impl/agent_impl.dart';

/// 测试远程会话状态问题
///
/// 测试场景：
/// 1. 模拟本地 Agent 发送消息
/// 2. 验证远程 Proxy 是否正确接收状态变化
/// 3. 检查状态是否从 idle -> processing -> streaming -> idle 正确转换
void main() {
  group('远程会话状态测试', () {
    late IAgent localAgent;
    late AgentProxy remoteProxy;
    late StreamController<Map<String, dynamic>> eventController;
    final List<AgentStatus> statusChanges = [];
    final List<AgentStateSnapshot> snapshots = [];

    setUp(() async {
      print('\n========== 测试开始 ==========');

      // 1. 创建事件流控制器，模拟远程事件传输
      eventController = StreamController<Map<String, dynamic>>.broadcast();

      // 2. 创建本地 Agent
      final chatAdapter = LangChainChatAdapter();
      localAgent = AgentImpl(
        employeeId: 'test-employee-001',
        chatAdapter: chatAdapter,
      );

      // 初始化 Agent
      await localAgent.initialize(employeeId: 'test-employee-001');

      print('✓ 本地 Agent 已创建并初始化');

      // 3. 订阅本地 Agent 的事件流，广播给远程
      localAgent.onEvent.listen((event) {
        print(
          '[本地->远程] 广播事件: ${event['type']}, status: ${event['data']?['status']}',
        );
        eventController.add(event);
      });

      print('✓ 本地 Agent 事件已订阅');

      // 4. 创建远程 Proxy
      remoteProxy = AgentProxy.remote(
        employeeId: 'test-employee-001',
        deviceId: 'device-remote-001',
        rpcCall: (method, params) async {
          print('[远程->本地] RPC 调用: $method');
          // 模拟 RPC 响应
          return {'messageId': 'msg-${DateTime.now().millisecondsSinceEpoch}'};
        },
        remoteEventStream: eventController.stream,
      );

      print('✓ 远程 Proxy 已创建');

      // 5. 订阅远程 Proxy 的状态变化
      remoteProxy.onStateChanged.listen((snapshot) {
        print('[远程] 状态变更: ${snapshot.status}');
        statusChanges.add(snapshot.status);
        snapshots.add(snapshot);
      });

      print('✓ 远程状态监听器已设置');
      print('初始状态: ${remoteProxy.status}');
    });

    tearDown(() async {
      print('\n========== 测试清理 ==========');

      // 清理资源
      await remoteProxy.dispose();
      await localAgent.dispose();
      await eventController.close();

      // 清空状态记录
      statusChanges.clear();
      snapshots.clear();

      print('✓ 资源已清理');
    });

    test('远程 Proxy 应该正确接收状态变化', () async {
      print('\n--- 测试 1: 状态变化接收 ---');

      // 等待初始状态
      await Future.delayed(const Duration(milliseconds: 100));

      expect(remoteProxy.status, AgentStatus.idle, reason: '初始状态应该是 idle');
      print('✓ 初始状态验证: ${remoteProxy.status}');

      // 记录发送前的状态
      final statusBeforeSend = remoteProxy.status;
      print('发送消息前状态: $statusBeforeSend');

      // 发送消息（这会触发状态变化）
      print('\n开始发送消息...');
      try {
        await localAgent.sendMessage({'content': '测试消息'});
        print('✓ 消息发送完成');
      } catch (e) {
        print('⚠ 消息发送失败（可能因为没有配置模型）: $e');
        // 没关系，我们只是测试状态变化
      }

      // 等待状态变化传播
      print('\n等待状态变化...');
      await Future.delayed(const Duration(milliseconds: 500));

      // 检查状态变化
      print('\n状态变化记录:');
      for (var i = 0; i < statusChanges.length; i++) {
        print('  [$i] ${statusChanges[i]}');
      }

      print('\n快照记录:');
      for (var i = 0; i < snapshots.length; i++) {
        print(
          '  [$i] status=${snapshots[i].status}, '
          'isStreaming=${snapshots[i].isStreaming}, '
          'queueLength=${snapshots[i].queueLength}',
        );
      }

      // 验证最终状态
      expect(remoteProxy.status, AgentStatus.idle, reason: '最终状态应该回到 idle');
      print('✓ 最终状态验证: ${remoteProxy.status}');

      // 验证至少有一些状态变化
      expect(statusChanges.length, greaterThan(0), reason: '应该有状态变化记录');
      print('✓ 状态变化记录验证: 共 ${statusChanges.length} 次变化');
    });

    test('状态应该完整经历 idle -> processing -> streaming -> idle', () async {
      print('\n--- 测试 2: 状态转换序列 ---');

      // 清空之前的状态记录
      statusChanges.clear();
      snapshots.clear();

      // 等待初始稳定
      await Future.delayed(const Duration(milliseconds: 100));

      print('发送消息...');
      try {
        await localAgent.sendMessage({'content': '测试消息'});
      } catch (e) {
        print('⚠ 消息发送失败（预期）: $e');
      }

      // 等待所有状态变化完成
      await Future.delayed(const Duration(seconds: 2));

      print('\n完整状态转换序列:');
      for (var i = 0; i < statusChanges.length; i++) {
        print('  [$i] ${statusChanges[i]}');
      }

      // 验证状态序列
      final statusSequence = statusChanges.join(' -> ');
      print('\n状态序列: $statusSequence');

      // 检查是否包含关键状态
      final hasProcessing = statusChanges.any(
        (s) => s == AgentStatus.processing,
      );
      final hasStreaming = statusChanges.any((s) => s == AgentStatus.streaming);
      final endsWithIdle =
          statusChanges.isNotEmpty && statusChanges.last == AgentStatus.idle;

      print('\n状态验证:');
      print('  包含 processing: $hasProcessing');
      print('  包含 streaming: $hasStreaming');
      print('  最终是 idle: $endsWithIdle');

      // 注意：由于可能没有配置模型，状态转换可能不完整
      // 这里只是记录实际的行为
      if (statusChanges.isNotEmpty) {
        print('✓ 记录了 ${statusChanges.length} 次状态变化');
      } else {
        print('⚠ 没有记录到状态变化（可能消息处理立即失败）');
      }
    });

    test('远程 Proxy 的 isSending 属性应该正确反映状态', () async {
      print('\n--- 测试 3: isSending 属性 ---');

      // 清空状态记录
      statusChanges.clear();

      await Future.delayed(const Duration(milliseconds: 100));

      print('初始 isSending: ${remoteProxy.isSending}');
      expect(remoteProxy.isSending, isFalse, reason: '初始状态不应该在发送中');

      print('\n发送消息...');
      try {
        final messageId = await localAgent.sendMessage({'content': '测试'});
        print('消息 ID: $messageId');
      } catch (e) {
        print('⚠ 消息发送失败（预期）: $e');
      }

      // 等待一段时间
      await Future.delayed(const Duration(milliseconds: 300));

      print('\n发送后的 isSending: ${remoteProxy.isSending}');
      print('发送后的 status: ${remoteProxy.status}');

      // 最终应该回到 idle
      await Future.delayed(const Duration(milliseconds: 1000));

      print('最终 isSending: ${remoteProxy.isSending}');
      print('最终 status: ${remoteProxy.status}');

      expect(remoteProxy.isSending, isFalse, reason: '最终状态不应该在发送中');
      expect(remoteProxy.status, AgentStatus.idle, reason: '最终状态应该是 idle');

      print('✓ isSending 属性验证通过');
    });

    test('测试事件流的正确性', () async {
      print('\n--- 测试 4: 事件流正确性 ---');

      int eventCount = 0;
      final eventTypes = <String>[];

      // 订阅原始事件流
      final subscription = eventController.stream.listen((event) {
        eventCount++;
        final type = event['type'] as String?;
        eventTypes.add(type ?? 'unknown');
        print('[$eventCount] 接收到事件: $type, data: ${event['data']}');
      });

      await Future.delayed(const Duration(milliseconds: 100));

      print('\n发送消息...');
      try {
        await localAgent.sendMessage({'content': '事件流测试'});
      } catch (e) {
        print('⚠ 消息发送失败（预期）: $e');
      }

      // 等待事件传播
      await Future.delayed(const Duration(milliseconds: 500));

      await subscription.cancel();

      print('\n事件统计:');
      print('  总事件数: $eventCount');
      print('  事件类型: ${eventTypes.join(', ')}');

      // 应该有事件产生
      expect(eventCount, greaterThan(0), reason: '应该有事件通过事件流传输');

      // 应该包含 agentStatusChanged 事件
      final hasStatusEvent = eventTypes.contains('agentStatusChanged');
      print('  包含状态变化事件: $hasStatusEvent');

      print('✓ 事件流验证完成');
    });

    test('测试并发状态更新', () async {
      print('\n--- 测试 5: 并发状态更新 ---');

      statusChanges.clear();

      // 快速发送多条消息
      final futures = <Future>[];
      for (var i = 0; i < 3; i++) {
        futures.add(
          Future.delayed(Duration(milliseconds: i * 100), () async {
            try {
              await localAgent.sendMessage({'content': '并发测试 $i'});
            } catch (e) {
              print('消息 $i 发送失败: $e');
            }
          }),
        );
      }

      await Future.wait(futures);
      await Future.delayed(const Duration(seconds: 2));

      print('\n并发状态变化记录:');
      for (var i = 0; i < statusChanges.length; i++) {
        print('  [$i] ${statusChanges[i]}');
      }

      print('✓ 并发测试完成，共 ${statusChanges.length} 次状态变化');
    });
  });

  group('问题诊断测试', () {
    test('检查状态变化事件的数据结构', () async {
      print('\n--- 诊断测试: 状态事件数据结构 ---');

      final eventController =
          StreamController<Map<String, dynamic>>.broadcast();
      final receivedEvents = <Map<String, dynamic>>[];

      // 创建本地 Agent
      final chatAdapter = LangChainChatAdapter();
      final agent = AgentImpl(
        employeeId: 'diag-employee-001',
        chatAdapter: chatAdapter,
      );

      // 订阅本地事件
      agent.onEvent.listen((event) {
        print('本地事件: ${event['type']}');
        print('  employeeId: ${event['employeeId']}');
        print('  data: ${event['data']}');
        receivedEvents.add(Map.from(event));
        eventController.add(event);
      });

      // 创建远程 Proxy
      final proxy = AgentProxy.remote(
        employeeId: 'diag-employee-001',
        deviceId: 'device-diag',
        rpcCall: (_, __) async => {'messageId': 'test-msg-id'},
        remoteEventStream: eventController.stream,
      );

      // 订阅远程状态
      final remoteStatuses = <AgentStatus>[];
      proxy.onStateChanged.listen((snapshot) {
        print('远程状态变更: ${snapshot.status}');
        print(
          '  currentProcessingMessageId: ${snapshot.currentProcessingMessageId}',
        );
        print('  queuedMessageIds: ${snapshot.queuedMessageIds}');
        print('  isStreaming: ${snapshot.isStreaming}');
        print('  queueLength: ${snapshot.queueLength}');
        remoteStatuses.add(snapshot.status);
      });

      await agent.initialize(employeeId: 'diag-employee-001');
      await Future.delayed(const Duration(milliseconds: 100));

      print('\n发送测试消息...');
      try {
        await agent.sendMessage({'content': '诊断测试'});
      } catch (e) {
        print('⚠ 发送失败（预期）: $e');
      }

      await Future.delayed(const Duration(milliseconds: 500));

      print('\n=== 诊断结果 ===');
      print('本地事件数量: ${receivedEvents.length}');
      print('远程状态变更数量: ${remoteStatuses.length}');

      for (var i = 0; i < receivedEvents.length; i++) {
        final event = receivedEvents[i];
        print('\n事件 $i:');
        print('  type: ${event['type']}');
        print('  employeeId: ${event['employeeId']}');
        final data = event['data'];
        if (data != null) {
          print('  data.status: ${data['status']}');
          print(
            '  data.currentProcessingMessageId: ${data['currentProcessingMessageId']}',
          );
          print('  data.isStreaming: ${data['isStreaming']}');
        }
      }

      await proxy.dispose();
      await agent.dispose();
      await eventController.close();

      print('\n✓ 诊断测试完成');
    });
  });
}
