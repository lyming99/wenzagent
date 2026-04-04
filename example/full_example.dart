import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wenzagent/wenzagent.dart';

/// 综合示例：展示完整的 client-host-client 架构
///
/// 演示：
/// 1. Host 启动和管理
/// 2. 多 Client 连接
/// 3. 文件传输
/// 4. RPC 同步调用
/// 5. RPC 流式调用
/// 6. Agent 远程操作
Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║          WenzAgent 综合示例 - Client-Host-Client         ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final example = FullExample();
  await example.run();
}

class FullExample {
  late LanHostServiceImpl host;
  late LanClientServiceImpl serverClient;
  late LanClientServiceImpl callerClient;
  late RemoteCallServer rpcServer;
  late RemoteCallManager rpcManager;

  Future<void> run() async {
    try {
      // 阶段 1: 启动服务
      await _startServices();

      // 阶段 2: 文件传输
      await _demonstrateFileTransfer();

      // 阶段 3: RPC 同步调用
      await _demonstrateRpcCall();

      // 阶段 4: RPC 流式调用
      await _demonstrateRpcStream();

      // 阶段 5: Agent 操作
      await _demonstrateAgent();

      // 清理
      await _cleanup();
    } catch (e, stack) {
      print('错误: $e');
      print(stack);
      await _cleanup();
    }
  }

  /// 阶段 1: 启动服务
  Future<void> _startServices() async {
    print('┌─────────────────────────────────────────────────────────┐');
    print('│ 阶段 1: 启动服务                                         │');
    print('└─────────────────────────────────────────────────────────┘\n');

    // 启动 Host (自动分配端口)
    host = LanHostServiceImpl();
    await host.start(port: 0);
    print('✓ Host 已启动: ${host.localIp}:${host.port}');

    // 监听 Host 消息
    host.messageStream.listen((msg) {
      if (msg.type == LanMessageType.system) {
        print('  [Host] ${msg.content}');
      }
    });

    // Server Client 连接
    serverClient = LanClientServiceImpl(spaceId: 'server-001');
    await serverClient.connect(host.localIp!, port: host.port);
    print('✓ Server Client 已连接: server-001');

    // 创建 RPC Server
    rpcServer = RemoteCallServer(
      clientService: serverClient,
      localSpaceId: 'server-001',
    );
    _registerRpcMethods();
    _listenServerMessages();
    print('✓ RPC Server 已注册方法');

    // Caller Client 连接
    callerClient = LanClientServiceImpl(spaceId: 'caller-001');
    await callerClient.connect(host.localIp!, port: host.port);
    print('✓ Caller Client 已连接: caller-001');

    // 创建 RPC Manager
    rpcManager = RemoteCallManager(
      clientService: callerClient,
      localSpaceId: 'caller-001',
    );
    _listenCallerMessages();
    print('✓ RPC Manager 已就绪');

    await Future.delayed(Duration(milliseconds: 500));
    print('');
  }

  void _registerRpcMethods() {
    // 同步方法
    rpcServer.register('ping', (params) async {
      return {'pong': true, 'time': DateTime.now().toIso8601String()};
    });

    rpcServer.register('add', (params) async {
      final a = params['a'] as num? ?? 0;
      final b = params['b'] as num? ?? 0;
      return {'result': a + b};
    });

    rpcServer.register('getSystemInfo', (params) async {
      return {
        'os': Platform.operatingSystem,
        'hostname': Platform.localHostname,
        'dartVersion': Platform.version,
        'processors': Platform.numberOfProcessors,
      };
    });

    // 流式方法
    rpcServer.registerStream('countDown', (params) {
      final start = params['start'] as int? ?? 5;
      return Stream.periodic(Duration(milliseconds: 500), (i) {
        if (i >= start) {
          return RpcStreamEvent.done({'message': 'Liftoff!'});
        }
        return RpcStreamEvent.chunk('${start - i}');
      }).take(start + 1);
    });

    rpcServer.registerStream('heartbeat', (params) {
      final count = params['count'] as int? ?? 5;
      return Stream.periodic(Duration(seconds: 1), (i) {
        if (i >= count) {
          return RpcStreamEvent.done({'beats': count});
        }
        return RpcStreamEvent.chunk(jsonEncode({
          'beat': i + 1,
          'time': DateTime.now().toIso8601String(),
        }));
      }).take(count + 1);
    });
  }

  void _listenServerMessages() {
    serverClient.messageStream.listen((msg) {
      if (msg.type == LanMessageType.rpcRequest) {
        try {
          final content = jsonDecode(msg.content!) as Map<String, dynamic>;
          rpcServer.handleRequest(content['payload'] as Map<String, dynamic>);
        } catch (e) {
          print('Server 处理请求错误: $e');
        }
      }
    });
  }

  void _listenCallerMessages() {
    callerClient.messageStream.listen((msg) {
      try {
        switch (msg.type) {
          case LanMessageType.rpcResponse:
            final content = jsonDecode(msg.content!) as Map<String, dynamic>;
            rpcManager.handleResponse(content['payload'] as Map<String, dynamic>);
            break;
          case LanMessageType.rpcStreamChunk:
            final content = jsonDecode(msg.content!) as Map<String, dynamic>;
            rpcManager.handleStreamChunk(content['payload'] as Map<String, dynamic>);
            break;
          case LanMessageType.rpcStreamEnd:
            final content = jsonDecode(msg.content!) as Map<String, dynamic>;
            rpcManager.handleStreamEnd(content['payload'] as Map<String, dynamic>);
            break;
          case LanMessageType.rpcError:
            final content = jsonDecode(msg.content!) as Map<String, dynamic>;
            rpcManager.handleError(content['payload'] as Map<String, dynamic>);
            break;
          default:
            break;
        }
      } catch (e) {
        print('Caller 处理消息错误: $e');
      }
    });
  }

  /// 阶段 2: 文件传输
  Future<void> _demonstrateFileTransfer() async {
    print('┌─────────────────────────────────────────────────────────┐');
    print('│ 阶段 2: 文件传输                                         │');
    print('└─────────────────────────────────────────────────────────┘\n');

    // 创建测试文件
    final testDir = Directory('${Directory.systemTemp.path}/wenzagent_demo');
    await testDir.create(recursive: true);

    final uploadFile = File('${testDir.path}/demo.txt');
    await uploadFile.writeAsString('WenzAgent 文件传输演示\n' * 50);
    print('创建测试文件: ${uploadFile.path}');

    // 上传
    print('\n上传中...');
    final fileId = await host.saveFile(
      await uploadFile.readAsBytes(),
      'demo.txt',
    );
    print('✓ 文件已上传, fileId: $fileId');

    // 下载
    print('\n下载中...');
    final downloadFile = File('${testDir.path}/downloaded.txt');
    final data = await host.getFile(fileId);
    if (data != null) {
      await downloadFile.writeAsBytes(data);
      print('✓ 文件已下载: ${downloadFile.path}');
      print('  文件大小: ${data.length} bytes');
    }

    // 清理测试文件
    await testDir.delete(recursive: true);
    print('\n✓ 测试文件已清理\n');
  }

  /// 阶段 3: RPC 同步调用
  Future<void> _demonstrateRpcCall() async {
    print('┌─────────────────────────────────────────────────────────┐');
    print('│ 阶段 3: RPC 同步调用                                     │');
    print('└─────────────────────────────────────────────────────────┘\n');

    // Ping
    print('调用 ping...');
    var result = await rpcManager.invoke<Map<String, dynamic>>(
      'ping',
      {},
      toSpaceId: 'server-001',
    );
    print('  返回: $result\n');

    // Add
    print('调用 add(100, 200)...');
    result = await rpcManager.invoke<Map<String, dynamic>>(
      'add',
      {'a': 100, 'b': 200},
      toSpaceId: 'server-001',
    );
    print('  结果: ${result['result']}\n');

    // GetSystemInfo
    print('调用 getSystemInfo...');
    result = await rpcManager.invoke<Map<String, dynamic>>(
      'getSystemInfo',
      {},
      toSpaceId: 'server-001',
    );
    print('  系统: ${result['os']}');
    print('  主机名: ${result['hostname']}');
    print('  CPU 核心数: ${result['processors']}\n');
  }

  /// 阶段 4: RPC 流式调用
  Future<void> _demonstrateRpcStream() async {
    print('┌─────────────────────────────────────────────────────────┐');
    print('│ 阶段 4: RPC 流式调用                                     │');
    print('└─────────────────────────────────────────────────────────┘\n');

    // 倒计时
    print('倒计时演示:');
    final stream1 = rpcManager.invokeStream(
      'countDown',
      {'start': 5},
      toSpaceId: 'server-001',
      timeout: 10000,
    );
    await for (final event in stream1) {
      if (event.isDone) {
        print('  🚀 ${event.result}');
      } else {
        print('  倒计时: ${event.chunk}');
      }
    }

    print('\n心跳演示:');
    final stream2 = rpcManager.invokeStream(
      'heartbeat',
      {'count': 3},
      toSpaceId: 'server-001',
      timeout: 10000,
    );
    await for (final event in stream2) {
      if (event.isDone) {
        print('  完成! 共 ${event.result?['beats']} 次心跳');
      } else {
        final data = jsonDecode(event.chunk!);
        print('  心跳 #${data['beat']}: ${data['time'].substring(11, 19)}');
      }
    }
    print('');
  }

  /// 阶段 5: Agent 操作演示
  Future<void> _demonstrateAgent() async {
    print('┌─────────────────────────────────────────────────────────┐');
    print('│ 阶段 5: Agent 操作演示                                   │');
    print('└─────────────────────────────────────────────────────────┘\n');

    // 注册 Agent 相关 RPC 方法
    rpcServer.register('agentGetOrCreate', (params) async {
      final employeeUuid = params['employeeUuid'] as String? ?? 'default-agent';
      return {
        'employeeUuid': employeeUuid,
        'sessionUuid': 'session-${DateTime.now().millisecondsSinceEpoch}',
        'status': 'idle',
      };
    });

    rpcServer.register('agentGetState', (params) async {
      return {
        'status': 'idle',
        'queueLength': 0,
        'isStreaming': false,
        'timestamp': DateTime.now().toIso8601String(),
      };
    });

    rpcServer.register('agentSendMessage', (params) async {
      // 可以从 messageData 中提取内容
      // final content = params['messageData']?['content'] ?? '';
      return {
        'messageId': 'msg-${DateTime.now().millisecondsSinceEpoch}',
        'status': 'queued',
      };
    });

    print('创建 Agent...');
    var result = await rpcManager.invoke<Map<String, dynamic>>(
      'agentGetOrCreate',
      {'employeeUuid': 'agent-demo-001'},
      toSpaceId: 'server-001',
    );
    print('  Agent ID: ${result['employeeUuid']}');
    print('  会话 ID: ${result['sessionUuid']}');
    print('  状态: ${result['status']}\n');

    print('获取 Agent 状态...');
    result = await rpcManager.invoke<Map<String, dynamic>>(
      'agentGetState',
      {'employeeUuid': 'agent-demo-001'},
      toSpaceId: 'server-001',
    );
    print('  状态: ${result['status']}');
    print('  队列长度: ${result['queueLength']}\n');

    print('发送消息到 Agent...');
    result = await rpcManager.invoke<Map<String, dynamic>>(
      'agentSendMessage',
      {
        'employeeUuid': 'agent-demo-001',
        'messageData': {'content': 'Hello from remote!'},
      },
      toSpaceId: 'server-001',
    );
    print('  消息 ID: ${result['messageId']}');
    print('  状态: ${result['status']}\n');
  }

  /// 清理资源
  Future<void> _cleanup() async {
    print('┌─────────────────────────────────────────────────────────┐');
    print('│ 清理资源                                                 │');
    print('└─────────────────────────────────────────────────────────┘\n');

    await callerClient.disconnect();
    print('✓ Caller Client 已断开');

    await serverClient.disconnect();
    print('✓ Server Client 已断开');

    await host.stop();
    print('✓ Host 已停止');

    rpcManager.dispose();
    rpcServer.dispose();
    print('✓ RPC 资源已释放');

    print('\n✅ 示例运行完成!');
  }
}
