import 'dart:async';

import 'package:wenzagent/src/agent/adapter/langchain_chat_adapter.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/client/agent_proxy.dart';
import 'package:wenzagent/src/agent/i_agent.dart';
import 'package:wenzagent/src/agent/impl/agent_impl.dart';
import 'package:wenzagent/src/agent/rpc/agent_rpc_config.dart';

/// 测试远程权限请求获取
///
/// 测试场景：
/// 1. 远程模式下无权限请求
/// 2. 远程模式下有权限请求
/// 3. 权限请求响应后的状态
/// 4. 多个权限请求的情况
Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║           远程权限请求获取测试                              ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  try {
    // ===== 测试 1: 远程模式下无权限请求 =====
    print('[测试 1] 远程模式下无权限请求');
    await testRemoteNoPermissionRequest();

    // ===== 测试 2: 远程模式下有权限请求 =====
    print('\n[测试 2] 远程模式下有权限请求');
    await testRemoteWithPermissionRequest();

    // ===== 测试 3: 权限请求响应后状态 =====
    print('\n[测试 3] 权限请求响应后状态');
    await testPermissionRequestAfterResponse();

    // ===== 测试 4: 同步方法在远程模式下返回 null =====
    print('\n[测试 4] 同步方法在远程模式下返回 null');
    await testSyncMethodReturnsNull();

    // ===== 测试 5: 本地模式权限请求 =====
    print('\n[测试 5] 本地模式权限请求');
    await testLocalModePermissionRequest();

    print('\n╔══════════════════════════════════════════════════════════╗');
    print('║                    ✓ 所有测试通过！                        ║');
    print('╚══════════════════════════════════════════════════════════╝\n');
  } catch (e, stackTrace) {
    print('❌ 测试失败: $e');
    print(stackTrace);
  }
}

/// 测试远程模式下无权限请求
Future<void> testRemoteNoPermissionRequest() async {
  // 创建一个模拟的远程 Agent（实际上是本地实例，但用于模拟 RPC）
  final chatAdapter = LangChainChatAdapter();
  final remoteAgent = AgentImpl(
    employeeId: 'remote-employee-001',
    chatAdapter: chatAdapter,
  );

  // 创建事件流
  final eventController = StreamController<Map<String, dynamic>>.broadcast();
  
  // 创建远程 AgentProxy
  final remoteProxy = AgentProxy.remote(
    employeeId: 'remote-employee-001',
    deviceId: 'device-001',
    rpcCall: (method, params) async {
      // 模拟 RPC 调用
      if (method == AgentRpcConfig.methodGetPendingPermission) {
        // 直接调用远程 Agent 的方法
        final request = remoteAgent.getPendingPermissionRequest();
        return {
          'request': request?.toMap(),
        };
      }
      return {};
    },
    remoteEventStream: eventController.stream,
  );

  // 测试异步方法
  final request = await remoteProxy.getPendingPermissionRequestAsync();
  
  if (request != null) {
    throw Exception('期望返回 null，但返回了权限请求');
  }
  
  print('  ✓ 异步方法返回 null（无权限请求）');

  // 清理
  await remoteProxy.dispose();
  await remoteAgent.dispose();
  await eventController.close();
  
  print('  ✓ 测试通过');
}

/// 测试远程模式下有权限请求
Future<void> testRemoteWithPermissionRequest() async {
  // 创建模拟远程 Agent
  final chatAdapter = LangChainChatAdapter();
  final remoteAgent = AgentImpl(
    employeeId: 'remote-employee-002',
    chatAdapter: chatAdapter,
  );

  // 创建事件流
  final eventController = StreamController<Map<String, dynamic>>.broadcast();

  // 创建一个测试权限请求
  final testRequest = AgentPermissionRequest(
    requestId: 'test-request-001',
    type: 'file_access',
    description: '读取文件权限',
    functionName: 'readFile',
    permissionPattern: '/home/user/*.txt',
    permissionType: 'file_read',
    data: {'path': '/home/user/test.txt'},
  );

  // 模拟远程 Agent 有权限请求
  // 注意：实际场景中，权限请求是由工具执行时产生的
  // 这里我们通过反射或直接访问内部状态来模拟
  // 由于无法直接访问私有成员，我们需要通过其他方式模拟
  
  bool hasMockRequest = false;
  
  // 创建远程 AgentProxy
  final remoteProxy = AgentProxy.remote(
    employeeId: 'remote-employee-002',
    deviceId: 'device-002',
    rpcCall: (method, params) async {
      // 模拟 RPC 调用
      if (method == AgentRpcConfig.methodGetPendingPermission) {
        // 如果模拟有权限请求，返回测试请求
        if (hasMockRequest) {
          return {
            'request': testRequest.toMap(),
          };
        }
        // 否则返回实际远程 Agent 的状态
        final request = remoteAgent.getPendingPermissionRequest();
        return {
          'request': request?.toMap(),
        };
      }
      return {};
    },
    remoteEventStream: eventController.stream,
  );

  // 测试初始状态（无权限请求）
  var request = await remoteProxy.getPendingPermissionRequestAsync();
  if (request != null) {
    throw Exception('初始状态应该无权限请求');
  }
  print('  ✓ 初始状态无权限请求');

  // 模拟有权限请求
  hasMockRequest = true;
  
  // 再次查询
  request = await remoteProxy.getPendingPermissionRequestAsync();
  if (request == null) {
    throw Exception('期望返回权限请求，但返回了 null');
  }
  
  print('  ✓ 成功获取权限请求:');
  print('    - 请求ID: ${request.requestId}');
  print('    - 类型: ${request.type}');
  print('    - 函数: ${request.functionName}');
  print('    - 描述: ${request.description}');
  print('    - 权限模式: ${request.permissionPattern}');
  print('    - 权限类型: ${request.permissionType}');
  print('    - 附加数据: ${request.data}');

  // 验证返回的请求内容
  if (request.requestId != testRequest.requestId) {
    throw Exception('请求ID不匹配');
  }
  if (request.type != testRequest.type) {
    throw Exception('类型不匹配');
  }
  if (request.functionName != testRequest.functionName) {
    throw Exception('函数名不匹配');
  }
  
  print('  ✓ 权限请求内容验证通过');

  // 清理
  await remoteProxy.dispose();
  await remoteAgent.dispose();
  await eventController.close();
  
  print('  ✓ 测试通过');
}

/// 测试权限请求响应后状态
Future<void> testPermissionRequestAfterResponse() async {
  final chatAdapter = LangChainChatAdapter();
  final remoteAgent = AgentImpl(
    employeeId: 'remote-employee-003',
    chatAdapter: chatAdapter,
  );

  final eventController = StreamController<Map<String, dynamic>>.broadcast();
  
  bool hasMockRequest = false;
  bool permissionResponded = false;
  
  final testRequest = AgentPermissionRequest(
    requestId: 'test-request-002',
    type: 'network_access',
    description: '访问网络权限',
    functionName: 'httpRequest',
  );

  final remoteProxy = AgentProxy.remote(
    employeeId: 'remote-employee-003',
    deviceId: 'device-003',
    rpcCall: (method, params) async {
      if (method == AgentRpcConfig.methodGetPendingPermission) {
        if (hasMockRequest && !permissionResponded) {
          return {'request': testRequest.toMap()};
        }
        final request = remoteAgent.getPendingPermissionRequest();
        return {'request': request?.toMap()};
      }
      if (method == AgentRpcConfig.methodRespondPermission) {
        // 模拟响应权限请求
        final requestId = params['requestId'] as String?;
        final decisionStr = params['decision'] as String?;
        if (requestId == testRequest.requestId) {
          permissionResponded = true;
          print('  ✓ 权限请求已响应: $decisionStr');
        }
        return {};
      }
      return {};
    },
    remoteEventStream: eventController.stream,
  );

  // 模拟有权限请求
  hasMockRequest = true;
  
  // 获取权限请求
  var request = await remoteProxy.getPendingPermissionRequestAsync();
  if (request == null) {
    throw Exception('应该有权限请求');
  }
  print('  ✓ 获取到权限请求: ${request.requestId}');

  // 响应权限请求
  await remoteProxy.respondToPermission(
    request.requestId,
    PermissionDecision.allow,
  );

  // 再次查询，应该返回 null
  await Future.delayed(Duration(milliseconds: 100));
  request = await remoteProxy.getPendingPermissionRequestAsync();
  if (request != null) {
    throw Exception('权限请求响应后应该返回 null');
  }
  print('  ✓ 权限请求响应后查询返回 null');

  // 清理
  await remoteProxy.dispose();
  await remoteAgent.dispose();
  await eventController.close();
  
  print('  ✓ 测试通过');
}

/// 测试同步方法在远程模式下返回 null
Future<void> testSyncMethodReturnsNull() async {
  final eventController = StreamController<Map<String, dynamic>>.broadcast();

  final remoteProxy = AgentProxy.remote(
    employeeId: 'remote-employee-004',
    deviceId: 'device-004',
    rpcCall: (method, params) async {
      // 这个方法在同步调用中不会被调用
      return {};
    },
    remoteEventStream: eventController.stream,
  );

  // 调用同步方法
  final request = remoteProxy.getPendingPermissionRequest();
  
  if (request != null) {
    throw Exception('同步方法在远程模式下应该返回 null');
  }
  
  print('  ✓ 同步方法在远程模式下返回 null（符合预期）');

  // 清理
  await remoteProxy.dispose();
  await eventController.close();
  
  print('  ✓ 测试通过');
}

/// 测试本地模式权限请求
Future<void> testLocalModePermissionRequest() async {
  final chatAdapter = LangChainChatAdapter();
  final localAgent = AgentImpl(
    employeeId: 'local-employee-001',
    chatAdapter: chatAdapter,
  );

  final localProxy = AgentProxy.local(
    employeeId: 'local-employee-001',
    deviceId: 'device-001',
    localAgent: localAgent,
  );

  // 测试初始状态
  var request = localProxy.getPendingPermissionRequest();
  if (request != null) {
    throw Exception('本地模式初始状态应该无权限请求');
  }
  print('  ✓ 本地模式初始状态无权限请求');

  // 测试异步方法
  request = await localProxy.getPendingPermissionRequestAsync();
  if (request != null) {
    throw Exception('异步方法也应该返回 null');
  }
  print('  ✓ 本地模式异步方法也返回 null');

  // 清理
  await localProxy.dispose();
  await localAgent.dispose();
  
  print('  ✓ 测试通过');
}

/// 扩展：创建一个完整的端到端测试场景
Future<void> testEndToEndPermissionFlow() async {
  print('\n[扩展测试] 端到端权限请求流程');
  
  // 这个测试展示了一个完整的权限请求流程：
  // 1. 工具执行需要权限
  // 2. Agent 产生权限请求
  // 3. 客户端通过远程调用获取权限请求
  // 4. 用户响应权限请求
  // 5. Agent 继续执行
  
  print('  ✓ 端到端测试需要在实际运行环境中进行');
  print('  ✓ 此测试仅作为参考示例');
}
