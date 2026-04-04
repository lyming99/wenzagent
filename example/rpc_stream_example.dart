import 'dart:async';
import 'dart:convert';

import 'package:wenzagent/wenzagent.dart';

/// 示例3：RPC 流式调用
///
/// 演示流式 RPC 调用，适用于大文件传输、实时数据推送等场景。
Future<void> rpcStreamExample() async {
  print('=== RPC 流式调用示例 ===\n');

  // 1. 启动 Host (自动分配端口)
  final host = LanHostServiceImpl();
  await host.start(port: 0);
  print('Host 已启动: ${host.localIp}:${host.port}');

  // 2. Server Client 连接（提供流式 RPC 服务）
  final serverClient = LanClientServiceImpl(spaceId: 'stream-server');
  await serverClient.connect(host.localIp!, port: host.port);
  print('Server Client 已连接: stream-server');

  // 3. 创建 RPC Server 并注册流式方法
  final rpcServer = RemoteCallServer(
    clientService: serverClient,
    localSpaceId: 'stream-server',
  );

  // 注册流式方法：计数器
  rpcServer.registerStream('counter', (params) {
    final count = params['count'] as int? ?? 5;
    final interval = params['interval'] as int? ?? 500;

    return Stream.periodic(
      Duration(milliseconds: interval),
      (i) {
        if (i >= count) {
          return RpcStreamEvent.done({'total': count, 'completed': true});
        }
        return RpcStreamEvent.chunk(jsonEncode({
          'index': i + 1,
          'total': count,
          'timestamp': DateTime.now().toIso8601String(),
        }));
      },
    ).take(count + 1);
  });

  // 注册流式方法：模拟日志推送
  rpcServer.registerStream('logStream', (params) {
    final logs = [
      '[INFO] Server starting...',
      '[INFO] Loading configuration...',
      '[DEBUG] Database connection established',
      '[INFO] Initializing modules...',
      '[DEBUG] Cache warmed up',
      '[INFO] Server ready to accept connections',
      '[INFO] Starting background tasks...',
      '[DEBUG] Health check scheduled',
      '[INFO] All systems operational',
    ];

    return Stream.periodic(Duration(milliseconds: 300), (i) {
      if (i >= logs.length) {
        return RpcStreamEvent.done({'logCount': logs.length});
      }
      return RpcStreamEvent.chunk(logs[i]);
    }).take(logs.length + 1);
  });

  // 注册流式方法：模拟数据生成器
  rpcServer.registerStream('dataGenerator', (params) {
    final count = params['count'] as int? ?? 10;
    final controller = StreamController<RpcStreamEvent>();

    // 模拟异步数据生成
    () async {
      for (var i = 0; i < count; i++) {
        await Future.delayed(Duration(milliseconds: 200));
        controller.add(RpcStreamEvent.chunk(jsonEncode({
          'id': i + 1,
          'value': (i + 1) * 100,
          'random': DateTime.now().microsecond,
        })));
      }
      controller.add(RpcStreamEvent.done({
        'totalGenerated': count,
        'finishedAt': DateTime.now().toIso8601String(),
      }));
      await controller.close();
    }();

    return controller.stream;
  });

  // 处理流式 RPC 请求
  serverClient.messageStream.listen((message) {
    if (message.type == LanMessageType.rpcRequest) {
      try {
        final content = jsonDecode(message.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcServer.handleRequest(payload);
      } catch (e) {
        print('处理流式 RPC 请求错误: $e');
      }
    }
  });

  // 等待服务器就绪
  await Future.delayed(Duration(milliseconds: 500));

  // 4. Caller Client 连接
  final callerClient = LanClientServiceImpl(spaceId: 'stream-caller');
  await callerClient.connect(host.localIp!, port: host.port);
  print('Caller Client 已连接: stream-caller');

  // 等待客户端注册完成
  await Future.delayed(Duration(milliseconds: 500));

  // 5. 创建 RPC Manager
  final rpcManager = RemoteCallManager(
    clientService: callerClient,
    localSpaceId: 'stream-caller',
  );

  // 处理流式响应
  callerClient.messageStream.listen((message) {
    if (message.type == LanMessageType.rpcStreamChunk) {
      try {
        final content = jsonDecode(message.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcManager.handleStreamChunk(payload);
      } catch (e) {
        print('处理流式 chunk 错误: $e');
      }
    } else if (message.type == LanMessageType.rpcStreamEnd) {
      try {
        final content = jsonDecode(message.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcManager.handleStreamEnd(payload);
      } catch (e) {
        print('处理流式结束错误: $e');
      }
    } else if (message.type == LanMessageType.rpcError) {
      try {
        final content = jsonDecode(message.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcManager.handleError(payload);
      } catch (e) {
        print('处理 RPC 错误: $e');
      }
    }
  });

  // 6. 测试流式调用
  print('\n--- 测试 1: 计数器流 ---\n');
  try {
    final stream1 = rpcManager.invokeStream(
      'counter',
      {'count': 5, 'interval': 400},
      toSpaceId: 'stream-server',
      timeout: 10000,
    );

    await for (final event in stream1) {
      if (event.isDone) {
        print('计数完成: ${event.result}');
      } else {
        print('收到: ${event.chunk}');
      }
    }
  } catch (e) {
    print('计数器流失败: $e');
  }

  print('\n--- 测试 2: 日志流 ---\n');
  try {
    final stream2 = rpcManager.invokeStream(
      'logStream',
      {},
      toSpaceId: 'stream-server',
      timeout: 10000,
    );

    await for (final event in stream2) {
      if (event.isDone) {
        print('日志流结束: ${event.result}');
      } else {
        print('日志: ${event.chunk}');
      }
    }
  } catch (e) {
    print('日志流失败: $e');
  }

  print('\n--- 测试 3: 数据生成器 ---\n');
  try {
    final stream3 = rpcManager.invokeStream(
      'dataGenerator',
      {'count': 6},
      toSpaceId: 'stream-server',
      timeout: 10000,
    );

    final dataItems = <String>[];
    await for (final event in stream3) {
      if (event.isDone) {
        print('数据生成完成: ${event.result}');
        print('共收集 ${dataItems.length} 条数据');
      } else {
        dataItems.add(event.chunk!);
        print('数据: ${event.chunk}');
      }
    }
  } catch (e) {
    print('数据生成器失败: $e');
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
  await rpcStreamExample();
}
