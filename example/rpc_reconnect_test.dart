/// RPC 流式调用断线重连稳定性测试
///
/// 测试场景：
/// 1. 建立长时间运行的 RPC 流式调用
/// 2. 在流式调用过程中手动断开客户端连接
/// 3. 重新连接客户端
/// 4. 验证 RPC 流式调用的稳定性
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wenzagent/wenzagent.dart';

void main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║     RPC 流式调用断线重连稳定性测试                        ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  // ==================== 阶段 1: 启动服务 ====================
  print('┌─────────────────────────────────────────────────────────┐');
  print('│ 阶段 1: 启动服务                                         │');
  print('└─────────────────────────────────────────────────────────┘\n');

  // 启动 Host
  final host = LanHostServiceImpl();
  await host.start(port: 0);
  final hostIp = host.localIp!;
  final hostPort = host.port;
  print('✓ Host 已启动: $hostIp:$hostPort');

  // 启动 Server Client (提供流式 RPC 服务)
  final serverClient = LanClientServiceImpl(deviceId: 'stream-server');
  await serverClient.connect(hostIp, port: hostPort);
  print('✓ Server Client 已连接: stream-server');

  // 注册流式 RPC 服务
  final rpcServer = RemoteCallServer(
    clientService: serverClient,
    localDeviceId: 'stream-server',
  );

  // 注册心跳流方法
  rpcServer.registerStream('heartbeatStream', (params) {
    final count = params['count'] as int? ?? 30;
    final intervalMs = params['interval'] as int? ?? 1000;
    final controller = StreamController<RpcStreamEvent>();

    () async {
      for (var i = 1; i <= count; i++) {
        await Future.delayed(Duration(milliseconds: intervalMs));
        controller.add(RpcStreamEvent.chunk(jsonEncode({
          'seq': i,
          'total': count,
          'timestamp': DateTime.now().toIso8601String(),
          'message': '心跳 #$i',
        })));
      }
      controller.add(RpcStreamEvent.done({
        'completed': true,
        'total': count,
      }));
      await controller.close();
    }();

    return controller.stream;
  });

  // 注册数据流方法
  rpcServer.registerStream('dataStream', (params) {
    final total = params['total'] as int? ?? 20;
    final intervalMs = params['interval'] as int? ?? 500;
    final controller = StreamController<RpcStreamEvent>();

    () async {
      for (var i = 1; i <= total; i++) {
        await Future.delayed(Duration(milliseconds: intervalMs));
        controller.add(RpcStreamEvent.chunk(jsonEncode({
          'index': i,
          'total': total,
          'value': i * 100,
          'random': DateTime.now().millisecondsSinceEpoch % 1000,
        })));
      }
      controller.add(RpcStreamEvent.done({
        'finished': true,
        'total': total,
      }));
      await controller.close();
    }();

    return controller.stream;
  });

  // 监听来自 Host 的消息并转发给 RPC Server
  serverClient.messageStream.listen((msg) {
    if (msg.type == LanMessageType.rpcRequest) {
      try {
        final content = jsonDecode(msg.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcServer.handleRequest(payload);
      } catch (e) {
        print('Server 处理请求错误: $e');
      }
    }
  });

  print('✓ RPC Server 已注册流式方法\n');

  // ==================== 阶段 2: 建立流式调用 ====================
  print('┌─────────────────────────────────────────────────────────┐');
  print('│ 阶段 2: 建立流式调用                                     │');
  print('└─────────────────────────────────────────────────────────┘\n');

  // 启动 Caller Client
  var callerClient = LanClientServiceImpl(deviceId: 'stream-caller');
  await callerClient.connect(hostIp, port: hostPort);
  print('✓ Caller Client 已连接: stream-caller');

  // 创建 RPC Manager
  var rpcManager = RemoteCallManager(
    clientService: callerClient,
    localDeviceId: 'stream-caller',
  );

  // 监听来自 Host 的消息并转发给 RPC Manager
  var callerSubscription = callerClient.messageStream.listen((msg) {
    if (msg.type == LanMessageType.rpcStreamChunk) {
      try {
        final content = jsonDecode(msg.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcManager.handleStreamChunk(payload);
      } catch (e) {
        print('处理流式 chunk 错误: $e');
      }
    } else if (msg.type == LanMessageType.rpcStreamEnd) {
      try {
        final content = jsonDecode(msg.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcManager.handleStreamEnd(payload);
      } catch (e) {
        print('处理流式结束错误: $e');
      }
    } else if (msg.type == LanMessageType.rpcError) {
      try {
        final content = jsonDecode(msg.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcManager.handleError(payload);
      } catch (e) {
        print('处理 RPC 错误: $e');
      }
    }
  });

  await Future.delayed(const Duration(milliseconds: 500));
  print('✓ RPC Manager 已就绪\n');

  // 开始流式调用
  print('开始心跳流式调用 (总共 30 次，每秒 1 次)...');
  print('─────────────────────────────────────────');

  var receivedCount = 0;
  var errorCount = 0;
  var completedCount = 0;

  StreamSubscription? streamSubscription;

  try {
    final stream = rpcManager.invokeStream(
      'heartbeatStream',
      {'count': 30, 'interval': 1000},
      toDeviceId: 'stream-server',
      timeout: 60000,
    );

    streamSubscription = stream.listen(
      (event) {
        if (event.isDone) {
          completedCount++;
          print('✅ 流完成: ${event.result}');
        } else {
          receivedCount++;
          final data = jsonDecode(event.chunk!);
          print('  📨 [$receivedCount] ${data['message']}');
        }
      },
      onError: (error) {
        errorCount++;
        print('  ❌ 流错误: $error');
      },
      onDone: () {
        print('  🏁 流结束 (received: $receivedCount, errors: $errorCount)');
      },
    );
  } catch (e) {
    print('  ❌ 调用失败: $e');
  }

  // ==================== 阶段 3: 模拟断线 ====================
  print('\n┌─────────────────────────────────────────────────────────┐');
  print('│ 阶段 3: 模拟断线                                         │');
  print('└─────────────────────────────────────────────────────────┘\n');

  // 等待接收几条消息后断线
  await Future.delayed(const Duration(seconds: 5));
  print('⏰ 已收到 $receivedCount 条消息，准备断开连接...\n');

  print('🔌 断开 Caller Client 连接...');
  await streamSubscription?.cancel();
  await callerSubscription.cancel();
  await callerClient.disconnect();
  print('✓ Caller Client 已断开\n');

  // 等待一段时间模拟网络中断
  print('⏳ 模拟网络中断，等待 3 秒...');
  await Future.delayed(const Duration(seconds: 3));

  // ==================== 阶段 4: 重新连接 ====================
  print('\n┌─────────────────────────────────────────────────────────┐');
  print('│ 阶段 4: 重新连接                                         │');
  print('└─────────────────────────────────────────────────────────┘\n');

  print('🔌 重新连接 Caller Client...');

  // 清理旧实例
  await LanClientServiceImpl.dispose('stream-caller');

  callerClient = LanClientServiceImpl(deviceId: 'stream-caller');
  await callerClient.connect(hostIp, port: hostPort);
  print('✓ Caller Client 已重连: stream-caller');

  // 重新创建 RPC Manager
  rpcManager = RemoteCallManager(
    clientService: callerClient,
    localDeviceId: 'stream-caller',
  );

  callerSubscription = callerClient.messageStream.listen((msg) {
    if (msg.type == LanMessageType.rpcStreamChunk) {
      try {
        final content = jsonDecode(msg.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcManager.handleStreamChunk(payload);
      } catch (e) {
        print('处理流式 chunk 错误: $e');
      }
    } else if (msg.type == LanMessageType.rpcStreamEnd) {
      try {
        final content = jsonDecode(msg.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcManager.handleStreamEnd(payload);
      } catch (e) {
        print('处理流式结束错误: $e');
      }
    } else if (msg.type == LanMessageType.rpcError) {
      try {
        final content = jsonDecode(msg.content!) as Map<String, dynamic>;
        final payload = content['payload'] as Map<String, dynamic>;
        rpcManager.handleError(payload);
      } catch (e) {
        print('处理 RPC 错误: $e');
      }
    }
  });

  await Future.delayed(const Duration(milliseconds: 500));
  print('✓ RPC Manager 已就绪\n');

  // ==================== 阶段 5: 重新建立流式调用 ====================
  print('┌─────────────────────────────────────────────────────────┐');
  print('│ 阶段 5: 重新建立流式调用                                 │');
  print('└─────────────────────────────────────────────────────────┘\n');

  // 记录断线前的数量
  final previousCount = receivedCount;
  receivedCount = 0;
  errorCount = 0;
  completedCount = 0;

  print('重新开始心跳流式调用 (总共 15 次，每秒 1 次)...');
  print('─────────────────────────────────────────');

  try {
    final stream = rpcManager.invokeStream(
      'heartbeatStream',
      {'count': 15, 'interval': 1000},
      toDeviceId: 'stream-server',
      timeout: 30000,
    );

    final completer = Completer<void>();

    streamSubscription = stream.listen(
      (event) {
        if (event.isDone) {
          completedCount++;
          print('✅ 流完成: ${event.result}');
          if (!completer.isCompleted) completer.complete();
        } else {
          receivedCount++;
          final data = jsonDecode(event.chunk!);
          print('  📨 [$receivedCount] ${data['message']}');
        }
      },
      onError: (error) {
        errorCount++;
        print('  ❌ 流错误: $error');
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        print('  🏁 流结束 (received: $receivedCount, errors: $errorCount)');
        if (!completer.isCompleted) completer.complete();
      },
    );

    // 等待流完成
    await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        print('⏰ 流超时，但继续执行...');
      },
    );
  } catch (e) {
    print('  ❌ 调用失败: $e');
  }

  // ==================== 阶段 6: 测试数据流稳定性 ====================
  print('\n┌─────────────────────────────────────────────────────────┐');
  print('│ 阶段 6: 测试数据流稳定性                                 │');
  print('└─────────────────────────────────────────────────────────┘\n');

  print('开始数据流调用 (总共 20 次，每 500ms 1 次)...');
  print('─────────────────────────────────────────');

  var dataReceived = 0;
  var dataErrors = 0;

  try {
    final stream = rpcManager.invokeStream(
      'dataStream',
      {'total': 20, 'interval': 500},
      toDeviceId: 'stream-server',
      timeout: 30000,
    );

    final completer = Completer<void>();

    streamSubscription = stream.listen(
      (event) {
        if (event.isDone) {
          print('✅ 数据流完成: ${event.result}');
          if (!completer.isCompleted) completer.complete();
        } else {
          dataReceived++;
          final data = jsonDecode(event.chunk!);
          print('  📊 [$dataReceived] index=${data['index']}, value=${data['value']}');
        }
      },
      onError: (error) {
        dataErrors++;
        print('  ❌ 数据流错误: $error');
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        print('  🏁 数据流结束 (received: $dataReceived, errors: $dataErrors)');
        if (!completer.isCompleted) completer.complete();
      },
    );

    await completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        print('⏰ 数据流超时');
      },
    );
  } catch (e) {
    print('  ❌ 数据流调用失败: $e');
  }

  // ==================== 清理资源 ====================
  print('\n┌─────────────────────────────────────────────────────────┐');
  print('│ 清理资源                                                 │');
  print('└─────────────────────────────────────────────────────────┘\n');

  await streamSubscription?.cancel();
  await callerSubscription.cancel();
  await callerClient.disconnect();
  print('✓ Caller Client 已断开');

  await serverClient.disconnect();
  print('✓ Server Client 已断开');

  await host.stop();
  print('✓ Host 已停止');

  // ==================== 测试报告 ====================
  print('\n╔══════════════════════════════════════════════════════════╗');
  print('║                    测试报告                               ║');
  print('╠══════════════════════════════════════════════════════════╣');
  print('║ 断线前心跳流: 收到 $previousCount 条消息                        ');
  print('║ 重连后心跳流: 收到 $receivedCount 条, 完成 $completedCount 次    ');
  print('║ 数据流测试: 收到 $dataReceived 条, 错误 $dataErrors 次          ');
  print('╠══════════════════════════════════════════════════════════╣');

  if (receivedCount > 0 && dataReceived > 0) {
    print('║ 状态: ✅ 通过 - 断线重连后 RPC 流式调用正常工作              ║');
  } else {
    print('║ 状态: ❌ 失败 - RPC 流式调用存在问题                         ║');
  }

  print('╚══════════════════════════════════════════════════════════╝\n');
}
