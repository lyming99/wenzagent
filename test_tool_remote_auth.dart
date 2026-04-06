import 'dart:async';

import 'package:wenzagent/src/agent/adapter/langchain_chat_adapter.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/i_agent.dart';
import 'package:wenzagent/src/agent/impl/agent_impl.dart';

/// 测试远程对话关闭后授权状态恢复
///
/// 简化版测试脚本
Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║     远程对话关闭后授权状态恢复测试                          ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  try {
    // ===== 测试 1: 远程Proxy创建和状态验证 =====
    print('[测试 1] 远程Proxy创建和状态验证');
    await testProxyCreation();

    // ===== 测试 2: 关闭后状态恢复 =====
    print('\n[测试 2] 关闭后状态恢复');
    await testDisposeAndRecovery();

    // ===== 测试 3: 事件流隔离 =====
    print('\n[测试 3] 事件流隔离');
    await testEventStreamIsolation();

    // ===== 测试 4: 权限请求状态 =====
    print('\n[测试 4] 权限请求状态');
    await testPermissionRequestState();

    print('\n╔══════════════════════════════════════════════════════════╗');
    print('║                    ✓ 所有测试通过！                        ║');
    print('╚══════════════════════════════════════════════════════════╝\n');
  } catch (e, stackTrace) {
    print('❌ 测试失败: $e');
    print(stackTrace);
  }
}

/// 测试远程Proxy创建和状态验证
Future<void> testProxyCreation() async {
  final eventController = StreamController<Map<String, dynamic>>.broadcast();
  final chatAdapter = LangChainChatAdapter();
  final agent = AgentImpl(
    employeeId: 'test-employee-001',
    chatAdapter: chatAdapter,
  );

  await agent.initialize(employeeId: 'test-employee-001');

  agent.onEvent.listen((event) {
    eventController.add(event);
  });

  final proxy = AgentProxy.remote(
    employeeId: 'test-employee-001',
    deviceId: 'device-remote-001',
    rpcCall: (method, params) async => {'messageId': 'msg-test'},
    remoteEventStream: eventController.stream,
  );

  await Future.delayed(const Duration(milliseconds: 100));

  // 验证初始状态
  assert(proxy.status == AgentStatus.idle, '初始状态应该是idle');
  print('  ✓ 初始状态: ${proxy.status}');

  assert(!proxy.isSending, '初始不应该在发送中');
  print('  ✓ isSending: ${proxy.isSending}');

  final snapshot = proxy.getStateSnapshot();
  assert(snapshot.status == AgentStatus.idle, '快照状态应该是idle');
  assert(snapshot.currentProcessingMessageId == null, '不应该有处理中的消息');
  print('  ✓ 状态快照正常');

  await proxy.dispose();
  await agent.dispose();
  await eventController.close();

  print('  ✓ 测试通过');
}

/// 测试关闭后状态恢复
Future<void> testDisposeAndRecovery() async {
  final eventController = StreamController<Map<String, dynamic>>.broadcast();
  final chatAdapter = LangChainChatAdapter();
  final agent = AgentImpl(
    employeeId: 'test-employee-002',
    chatAdapter: chatAdapter,
  );

  await agent.initialize(employeeId: 'test-employee-002');

  agent.onEvent.listen((event) {
    eventController.add(event);
  });

  final proxy = AgentProxy.remote(
    employeeId: 'test-employee-002',
    deviceId: 'device-remote-002',
    rpcCall: (method, params) async => {'messageId': 'msg-test'},
    remoteEventStream: eventController.stream,
  );

  await Future.delayed(const Duration(milliseconds: 100));

  print('  关闭前状态: ${proxy.status}');

  // 关闭远程对话
  await proxy.dispose();
  await Future.delayed(const Duration(milliseconds: 100));

  // 验证关闭后状态
  assert(proxy.status == AgentStatus.idle, '关闭后状态应该是idle');
  print('  ✓ 关闭后状态: ${proxy.status}');

  assert(!proxy.isSending, '关闭后不应该在发送中');
  print('  ✓ isSending: ${proxy.isSending}');

  await agent.dispose();
  await eventController.close();

  print('  ✓ 测试通过');
}

/// 测试事件流隔离
Future<void> testEventStreamIsolation() async {
  final eventController = StreamController<Map<String, dynamic>>.broadcast();
  final chatAdapter = LangChainChatAdapter();
  final agent = AgentImpl(
    employeeId: 'test-employee-003',
    chatAdapter: chatAdapter,
  );

  await agent.initialize(employeeId: 'test-employee-003');

  var eventCount = 0;

  agent.onEvent.listen((event) {
    eventController.add(event);
  });

  final proxy = AgentProxy.remote(
    employeeId: 'test-employee-003',
    deviceId: 'device-remote-003',
    rpcCall: (method, params) async => {'messageId': 'msg-test'},
    remoteEventStream: eventController.stream,
  );

  proxy.onStateChanged.listen((snapshot) {
    eventCount++;
  });

  await Future.delayed(const Duration(milliseconds: 100));

  // 记录dispose前的事件数
  final countBefore = eventCount;
  print('  dispose前事件数: $countBefore');

  // dispose
  await proxy.dispose();

  // 触发本地事件
  eventController.add({
    'type': 'agentStatusChanged',
    'data': {'status': 'processing'},
    'employeeId': 'test-employee-003',
  });

  await Future.delayed(const Duration(milliseconds: 100));

  // 验证不应该收到新事件
  assert(eventCount == countBefore, 'dispose后不应该收到事件');
  print('  ✓ dispose后事件数: $eventCount (无变化)');

  await agent.dispose();
  await eventController.close();

  print('  ✓ 测试通过');
}

/// 测试权限请求状态
Future<void> testPermissionRequestState() async {
  final eventController = StreamController<Map<String, dynamic>>.broadcast();
  final chatAdapter = LangChainChatAdapter();
  final agent = AgentImpl(
    employeeId: 'test-employee-004',
    chatAdapter: chatAdapter,
  );

  await agent.initialize(employeeId: 'test-employee-004');

  agent.onEvent.listen((event) {
    eventController.add(event);
  });

  final proxy = AgentProxy.remote(
    employeeId: 'test-employee-004',
    deviceId: 'device-remote-004',
    rpcCall: (method, params) async => {'messageId': 'msg-test'},
    remoteEventStream: eventController.stream,
  );

  await Future.delayed(const Duration(milliseconds: 100));

  // 获取权限请求（应该为null）
  var pendingRequest = await proxy.getPendingPermissionRequestAsync();
  assert(pendingRequest == null, '初始不应该有权限请求');
  print('  ✓ 初始无权限请求');

  // 关闭对话
  await proxy.dispose();

  // 再次检查权限请求（应该为null）
  pendingRequest = await proxy.getPendingPermissionRequestAsync();
  assert(pendingRequest == null, '关闭后不应该有权限请求');
  print('  ✓ 关闭后无权限请求');

  await agent.dispose();
  await eventController.close();

  print('  ✓ 测试通过');
}
