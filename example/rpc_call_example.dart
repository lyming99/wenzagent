import 'dart:async';
import 'dart:convert';

import 'package:wenzagent/wenzagent.dart';

/// 示例2：RPC 同步调用
///
/// 演示 client-host-client 模式：
/// - Host 作为中转站
/// - Server Client 注册 RPC 方法
/// - Client Client 调用远程方法
Future<void> rpcCallExample() async {
  print('=== RPC 同步调用示例 ===\n');

  // 1. 启动 Host (自动分配端口)
  final host = LanHostServiceImpl();
  await host.start(port: 0);
  print('Host 已启动: ${host.localIp}:${host.port}');

  // 2. Server Client 连接（提供 RPC 服务）
  final serverClient = LanClientServiceImpl(deviceId: 'server-device');
  await serverClient.connect(host.localIp!, port: host.port);
  print('Server Client 已连接: server-space');

  // 3. 创建 RPC Server 并注册方法
  final rpcServer = RemoteCallServer(
    clientService: serverClient,
    localDeviceId: 'server-device',
  );

  // 注册一些测试方法
  rpcServer.register('echo', (params) async {
    final message = params['message'] as String? ?? '';
    return {'echo': message, 'timestamp': DateTime.now().toIso8601String()};
  });

  rpcServer.register('add', (params) async {
    final a = params['a'] as num? ?? 0;
    final b = params['b'] as num? ?? 0;
    return {'result': a + b};
  });

  rpcServer.register('getServerInfo', (params) async {
    return {
      'serverName': 'WenzAgent Demo Server',
      'version': '1.0.0',
      'uptime': DateTime.now().toIso8601String(),
    };
  });

  // 处理从 Host 收到的 RPC 请求
  serverClient.messageStream.listen((message) {
    if (message.type == LanMessageType.rpcRequest) {
      try {
        final content = jsonDecode(message.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcServer.handleRequest(payload);
      } catch (e) {
        print('处理 RPC 请求错误: $e');
      }
    }
  });

  // 等待服务器就绪
  await Future.delayed(Duration(milliseconds: 500));

  // 4. Caller Client 连接（调用 RPC）
  final callerClient = LanClientServiceImpl(deviceId: 'caller-device');
  await callerClient.connect(host.localIp!, port: host.port);
  print('Caller Client 已连接: caller-space');

  // 等待客户端注册完成
  await Future.delayed(Duration(milliseconds: 500));

  // 5. 创建 RPC Manager
  final rpcManager = RemoteCallManager(
    clientService: callerClient,
    localDeviceId: 'caller-device',
  );

  // 处理 RPC 响应
  callerClient.messageStream.listen((message) {
    if (message.type == LanMessageType.rpcResponse) {
      try {
        final content = jsonDecode(message.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcManager.handleResponse(payload);
      } catch (e) {
        print('处理 RPC 响应错误: $e');
      }
    } else if (message.type == LanMessageType.rpcError) {
      try {
        final content = jsonDecode(message.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcManager.handleError(payload);
      } catch (e) {
        print('处理 RPC 错误错误: $e');
      }
    }
  });

  // 6. 调用远程方法
  print('\n--- RPC 调用测试 ---\n');

  // 测试 echo
  try {
    final result1 = await rpcManager.invoke<Map<String, dynamic>>(
      'echo',
      {'message': 'Hello from caller!'},
      toDeviceId: 'server-device',
    );
    print('echo 结果: $result1');
  } catch (e) {
    print('echo 失败: $e');
  }

  // 测试 add
  try {
    final result2 = await rpcManager.invoke<Map<String, dynamic>>(
      'add',
      {'a': 10, 'b': 25},
      toDeviceId: 'server-device',
    );
    print('add(10, 25) = ${result2['result']}');
  } catch (e) {
    print('add 失败: $e');
  }

  // 测试 getServerInfo
  try {
    final result3 = await rpcManager.invoke<Map<String, dynamic>>(
      'getServerInfo',
      {},
      toDeviceId: 'server-device',
    );
    print('服务器信息: $result3');
  } catch (e) {
    print('getServerInfo 失败: $e');
  }

  // 7. 清理
  await Future.delayed(Duration(seconds: 1));
  await callerClient.disconnect();
  await serverClient.disconnect();
  await host.stop();
  rpcManager.dispose();
  rpcServer.dispose();
  print('\n示例完成!');
}

void main() async {
  await rpcCallExample();
}
