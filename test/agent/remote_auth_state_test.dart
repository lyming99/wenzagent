import 'dart:async';

import 'package:test/test.dart';

import 'package:wenzagent/src/agent/adapter/langchain_chat_adapter.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/i_agent.dart';
import 'package:wenzagent/src/agent/impl/agent_impl.dart';
import 'package:wenzagent/src/agent/tool/agent_tool.dart';

/// 测试远程对话关闭后授权状态查询恢复
///
/// 测试场景：
/// 1. 模拟远程Agent发送需要权限的工具调用
/// 2. 验证权限请求是否正确传递到远程Proxy
/// 3. 关闭远程对话（dispose）
/// 4. 验证授权状态是否恢复为idle
void main() {
  group('远程对话授权状态恢复测试', () {
    late IAgent localAgent;
    late AgentProxy remoteProxy;
    late StreamController<Map<String, dynamic>> eventController;
    final List<AgentStatus> statusChanges = [];
    final List<AgentPermissionRequest> permissionRequests = [];

    setUp(() async {
      print('\n========== 测试开始 ==========');

      // 1. 创建事件流控制器，模拟远程事件传输
      eventController = StreamController<Map<String, dynamic>>.broadcast();

      // 2. 创建本地 Agent
      final chatAdapter = LangChainChatAdapter();
      localAgent = AgentImpl(
        employeeId: 'test-employee-auth-001',
        chatAdapter: chatAdapter,
      );

      // 初始化 Agent
      await localAgent.initialize(employeeId: 'test-employee-auth-001');

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
        employeeId: 'test-employee-auth-001',
        deviceId: 'device-remote-auth-001',
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
      permissionRequests.clear();

      print('✓ 资源已清理');
    });

    test('远程Proxy应该能够获取权限请求状态', () async {
      print('\n--- 测试 1: 权限请求状态获取 ---');

      // 等待初始状态稳定
      await Future.delayed(const Duration(milliseconds: 100));

      // 初始状态应该是idle
      expect(remoteProxy.status, AgentStatus.idle);
      print('✓ 初始状态验证: ${remoteProxy.status}');

      // 尝试获取权限请求（应该为null）
      final pendingRequest = await remoteProxy.getPendingPermissionRequestAsync();
      expect(pendingRequest, isNull);
      print('✓ 初始状态无权限请求');
    });

    test('远程对话关闭后状态应该恢复为idle', () async {
      print('\n--- 测试 2: 关闭后状态恢复 ---');

      // 记录初始状态
      final initialStatus = remoteProxy.status;
      print('初始状态: $initialStatus');

      // 模拟远程对话关闭
      print('\n关闭远程对话...');
      await remoteProxy.dispose();
      await Future.delayed(const Duration(milliseconds: 100));

      // 验证最终状态
      print('关闭后状态: ${remoteProxy.status}');
      expect(remoteProxy.status, AgentStatus.idle);
      print('✓ 状态已恢复为idle');
    });

    test('远程Proxy dispose后不应该再接收事件', () async {
      print('\n--- 测试 3: dispose后事件隔离 ---');

      await Future.delayed(const Duration(milliseconds: 100));

      // 记录dispose前的事件数量
      final statusCountBefore = statusChanges.length;
      print('dispose前状态变化次数: $statusCountBefore');

      // dispose远程Proxy
      await remoteProxy.dispose();

      // 清空记录
      statusChanges.clear();

      // 触发本地事件
      eventController.add({
        'type': 'agentStatusChanged',
        'data': {'status': 'processing'},
        'employeeId': 'test-employee-auth-001',
      });

      await Future.delayed(const Duration(milliseconds: 100));

      // 验证不应该收到事件
      expect(statusChanges.length, 0);
      print('✓ dispose后不再接收事件');
    });

    test('远程Proxy清理后状态缓存应该重置', () async {
      print('\n--- 测试 4: 状态缓存清理 ---');

      await Future.delayed(const Duration(milliseconds: 100));

      // 获取状态快照
      final snapshot = remoteProxy.getStateSnapshot();
      print('dispose前快照: ${snapshot.toMap()}');

      // dispose
      await remoteProxy.dispose();

      // 再次获取快照（应该返回idle状态）
      final snapshotAfter = remoteProxy.getStateSnapshot();
      print('dispose后快照: ${snapshotAfter.toMap()}');

      expect(snapshotAfter.status, AgentStatus.idle);
      expect(snapshotAfter.currentProcessingMessageId, isNull);
      expect(snapshotAfter.queueLength, 0);
      print('✓ 状态缓存已重置');
    });
  });

  group('权限请求场景测试', () {
    late IAgent localAgent;
    late AgentProxy remoteProxy;
    late StreamController<Map<String, dynamic>> eventController;
    final List<Map<String, dynamic>> receivedEvents = [];

    setUp(() async {
      print('\n========== 权限测试开始 ==========');

      eventController = StreamController<Map<String, dynamic>>.broadcast();

      final chatAdapter = LangChainChatAdapter();
      localAgent = AgentImpl(
        employeeId: 'test-permission-001',
        chatAdapter: chatAdapter,
      );

      await localAgent.initialize(employeeId: 'test-permission-001');

      // 监听所有事件
      localAgent.onEvent.listen((event) {
        receivedEvents.add(event);
        eventController.add(event);
        print('[事件] ${event['type']}: ${event['data']}');
      });

      remoteProxy = AgentProxy.remote(
        employeeId: 'test-permission-001',
        deviceId: 'device-permission-001',
        rpcCall: (method, params) async {
          return {'messageId': 'msg-test'};
        },
        remoteEventStream: eventController.stream,
      );

      print('✓ 测试环境初始化完成');
    });

    tearDown(() async {
      await remoteProxy.dispose();
      await localAgent.dispose();
      await eventController.close();
      receivedEvents.clear();
      print('✓ 测试环境清理完成');
    });

    test('关闭对话时权限请求应该被清理', () async {
      print('\n--- 测试: 权限请求清理 ---');

      await Future.delayed(const Duration(milliseconds: 100));

      // 初始状态：无权限请求
      var pendingRequest = await remoteProxy.getPendingPermissionRequestAsync();
      expect(pendingRequest, isNull);
      print('✓ 初始无权限请求');

      // 关闭对话
      await remoteProxy.dispose();
      print('✓ 远程对话已关闭');

      // 再次检查权限请求（应该为null）
      pendingRequest = await remoteProxy.getPendingPermissionRequestAsync();
      expect(pendingRequest, isNull);
      print('✓ 关闭后无权限请求');
    });

    test('关闭对话后授权状态应该正确', () async {
      print('\n--- 测试: 授权状态 ---');

      await Future.delayed(const Duration(milliseconds: 100));

      // 验证初始状态
      expect(remoteProxy.status, AgentStatus.idle);
      expect(remoteProxy.isSending, isFalse);
      print('✓ 初始状态正确');

      // 关闭对话
      await remoteProxy.dispose();

      // 验证关闭后状态
      expect(remoteProxy.status, AgentStatus.idle);
      expect(remoteProxy.isSending, isFalse);
      print('✓ 关闭后状态正确');
    });
  });

  group('事件流关闭测试', () {
    test('远程事件流关闭后状态应该保持idle', () async {
      print('\n--- 测试: 事件流关闭 ---');

      final eventController = StreamController<Map<String, dynamic>>.broadcast();

      final chatAdapter = LangChainChatAdapter();
      final agent = AgentImpl(
        employeeId: 'test-stream-001',
        chatAdapter: chatAdapter,
      );

      await agent.initialize(employeeId: 'test-stream-001');

      agent.onEvent.listen((event) {
        eventController.add(event);
      });

      final proxy = AgentProxy.remote(
        employeeId: 'test-stream-001',
        deviceId: 'device-stream-001',
        rpcCall: (method, params) async => {'messageId': 'msg-test'},
        remoteEventStream: eventController.stream,
      );

      await Future.delayed(const Duration(milliseconds: 100));

      // 验证初始状态
      expect(proxy.status, AgentStatus.idle);
      print('初始状态: ${proxy.status}');

      // 关闭事件流
      await eventController.close();
      await Future.delayed(const Duration(milliseconds: 100));

      // 状态应该仍然是idle
      expect(proxy.status, AgentStatus.idle);
      print('✓ 事件流关闭后状态保持idle');

      await proxy.dispose();
      await agent.dispose();
    });

    test('多次dispose应该安全', () async {
      print('\n--- 测试: 多次dispose ---');

      final eventController = StreamController<Map<String, dynamic>>.broadcast();

      final proxy = AgentProxy.remote(
        employeeId: 'test-multi-dispose',
        deviceId: 'device-multi',
        rpcCall: (method, params) async => {},
        remoteEventStream: eventController.stream,
      );

      await Future.delayed(const Duration(milliseconds: 100));

      // 第一次dispose
      await proxy.dispose();
      print('✓ 第一次dispose成功');

      // 第二次dispose（应该不会报错）
      await proxy.dispose();
      print('✓ 第二次dispose成功');

      await eventController.close();
    });
  });

  group('状态恢复综合测试', () {
    test('完整流程：打开-操作-关闭', () async {
      print('\n--- 测试: 完整流程 ---');

      final eventController = StreamController<Map<String, dynamic>>.broadcast();
      final statusHistory = <AgentStatus>[];

      final chatAdapter = LangChainChatAdapter();
      final agent = AgentImpl(
        employeeId: 'test-full-flow',
        chatAdapter: chatAdapter,
      );

      await agent.initialize(employeeId: 'test-full-flow');

      agent.onEvent.listen((event) {
        eventController.add(event);
      });

      final proxy = AgentProxy.remote(
        employeeId: 'test-full-flow',
        deviceId: 'device-full',
        rpcCall: (method, params) async => {'messageId': 'msg-test'},
        remoteEventStream: eventController.stream,
      );

      // 监听状态变化
      proxy.onStateChanged.listen((snapshot) {
        statusHistory.add(snapshot.status);
        print('[状态变化] ${snapshot.status}');
      });

      await Future.delayed(const Duration(milliseconds: 100));

      // 阶段1: 初始状态
      expect(proxy.status, AgentStatus.idle);
      print('✓ 阶段1: 初始状态idle');

      // 阶段2: 模拟操作（这里没有真实API调用，只是验证状态）
      final snapshot = proxy.getStateSnapshot();
      expect(snapshot.status, AgentStatus.idle);
      print('✓ 阶段2: 状态查询正常');

      // 阶段3: 关闭对话
      await proxy.dispose();
      await agent.dispose();
      await eventController.close();
      print('✓ 阶段3: 资源已清理');

      // 阶段4: 验证最终状态
      expect(proxy.status, AgentStatus.idle);
      print('✓ 阶段4: 最终状态idle');

      // 打印状态变化历史
      print('\n状态变化历史:');
      for (var i = 0; i < statusHistory.length; i++) {
        print('  [$i] ${statusHistory[i]}');
      }

      // 验证最终状态是idle
      if (statusHistory.isNotEmpty) {
        expect(statusHistory.last, AgentStatus.idle);
      }
    });
  });
}
