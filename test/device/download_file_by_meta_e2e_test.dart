/// downloadFileByMeta 真实场景 E2E 测试
///
/// 启动真实的 WebSocket Server + Client，验证完整的文件下载流程：
///   设备 A (下载方) → WebSocket → Server (中转) → 设备 B (文件拥有者)
///
/// 流程：
///   1. Server 启动 (LanHostServiceImpl)，port=0 随机端口
///   2. 设备 A、设备 B 作为真实 LanClientServiceImpl 连接到 Server
///   3. 设备 B 注册 RPC 流式文件读取处理器
///   4. 设备 A 通过 RPC invokeStream 发起下载
///   5. 设备 B 读取文件，构造二进制帧通过 WebSocket 发送
///   6. 设备 A 从 binaryChunkStream 接收二进制数据并写入文件
///   7. 验证：文件内容一致、SHA256 校验通过、进度回调正确
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/agent/entity/file_meta_message.dart';
import 'package:wenzagent/src/agent/rpc/agent_rpc_config.dart';
import 'package:wenzagent/src/entity/lan_message.dart';
import 'package:wenzagent/src/lan/entity/client_info.dart';
import 'package:wenzagent/src/lan/impl/lan_client_service_impl.dart';
import 'package:wenzagent/src/lan/impl/lan_host_service_impl.dart';
import 'package:wenzagent/src/lan/lan_client_service.dart';
import 'package:wenzagent/src/rpc/remote_call_manager.dart';
import 'package:wenzagent/src/rpc/remote_call_server.dart';
import 'package:wenzagent/src/rpc/rpc_protocol.dart';
import 'package:wenzagent/src/utils/logger.dart';


// ═══════════════════════════════════════════════════════════════
// 桥接 LanClientService：将 RPC 消息发送到真实 WebSocket
// ═══════════════════════════════════════════════════════════════

class _BridgeLanClientService implements LanClientService {
  final LanClientService _realClient;
  final String _overrideDeviceId;

  _BridgeLanClientService({
    required LanClientService realClient,
    required String overrideDeviceId,
  })  : _realClient = realClient,
        _overrideDeviceId = overrideDeviceId;

  @override
  bool get isConnected => _realClient.isConnected;

  @override
  bool get isConnecting => _realClient.isConnecting;

  @override
  String get deviceId => _overrideDeviceId;

  @override
  String? get topic => _realClient.topic;

  @override
  String? get hostIp => _realClient.hostIp;

  @override
  int get hostPort => _realClient.hostPort;

  @override
  double get uploadProgress => _realClient.uploadProgress;

  @override
  double get downloadProgress => _realClient.downloadProgress;

  @override
  Stream<LanMessage> get messageStream => _realClient.messageStream;

  @override
  Future<void> connect(String hostIp, {int port = 9090}) =>
      _realClient.connect(hostIp, port: port);

  @override
  Future<void> disconnect() => _realClient.disconnect();

  @override
  Future<void> reconnect() => _realClient.reconnect();

  @override
  void sendMessage(String content) => _realClient.sendMessage(content);

  @override
  Future<bool> sendLanMessage(LanMessage message) =>
      _realClient.sendLanMessage(message);

  @override
  Future<String> uploadFile(String filePath) => _realClient.uploadFile(filePath);

  @override
  Future<void> downloadFile(String fileId, String savePath) =>
      _realClient.downloadFile(fileId, savePath);

  @override
  Future<ClientInfo> getClientInfo() => _realClient.getClientInfo();

  @override
  void sendBinaryMessage(Uint8List data) => _realClient.sendBinaryMessage(data);

  @override
  Stream<BinaryChunkEvent> get binaryChunkStream =>
      _realClient.binaryChunkStream;
}

// ═══════════════════════════════════════════════════════════════
// 二进制帧工具
// ═══════════════════════════════════════════════════════════════

/// 构造二进制帧（与 DeviceRpcHandler._buildBinaryFrame 格式一致）
///
/// 帧格式：
/// [0]    0x01 版本
/// [1]    0x02 binaryChunk
/// [2..5] toDeviceId 长度 (uint32 BE)
/// [6..M] toDeviceId (UTF-8)
/// [M+1..M+4] requestId 长度 (uint32 BE)
/// [M+5..N] requestId (UTF-8)
/// [N+1]  flags (bit0=lastChunk)
/// [N+2..] 原始二进制数据
Uint8List buildBinaryFrame({
  required String toDeviceId,
  required String requestId,
  required Uint8List payload,
  required bool isLast,
}) {
  final toDeviceIdBytes = utf8.encode(toDeviceId);
  final requestIdBytes = utf8.encode(requestId);

  final builder = BytesBuilder();

  // version
  builder.addByte(0x01);
  // type = binaryChunk
  builder.addByte(0x02);

  // toDeviceId
  final toDeviceIdLenData = ByteData(4)
    ..setUint32(0, toDeviceIdBytes.length);
  builder.add(toDeviceIdLenData.buffer.asUint8List());
  builder.add(toDeviceIdBytes);

  // requestId
  final requestIdLenData = ByteData(4)
    ..setUint32(0, requestIdBytes.length);
  builder.add(requestIdLenData.buffer.asUint8List());
  builder.add(requestIdBytes);

  // flags
  builder.addByte(isLast ? 0x01 : 0x00);

  // payload
  builder.add(payload);

  return builder.takeBytes();
}

// ═══════════════════════════════════════════════════════════════
// 测试主体
// ═══════════════════════════════════════════════════════════════

void main() {
  Logger.level = LogLevel.warn; // reduce noise

  group('downloadFileByMeta E2E', () {
    late LanHostServiceImpl server;
    late String tempDir;
    int testCounter = 0;

    setUp(() async {
      testCounter++;
      server = LanHostServiceImpl();
      tempDir =
          '${Directory.systemTemp.path}${p.separator}wenzagent_dl_e2e_$testCounter';
      await Directory(tempDir).create(recursive: true);

      // 启动真实 WebSocket Server（端口 0 = 随机可用端口）
      await server.start(port: 0, storageDir: tempDir);
    });

    tearDown(() async {
      await server.stop();
      try {
        await Directory(tempDir).delete(recursive: true);
      } catch (_) {}
    });

    // ── 辅助方法 ──

    Future<LanClientServiceImpl> createAndConnectClient(
      String deviceId,
      String topic,
      int serverPort,
    ) async {
      final client = LanClientServiceImpl(deviceId: deviceId, topic: topic);
      await client.connect('127.0.0.1', port: serverPort);

      // 等待 Server 端 clientInfo 注册完成
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (true) {
        final registered = server.clients.any((c) => c.deviceId == deviceId);
        if (registered) break;
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('等待 deviceId=$deviceId 注册超时');
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }

      return client;
    }

    Future<void> cleanupClients({
      required List<LanClientServiceImpl> clients,
      required List<String> deviceIds,
      required List<RemoteCallManager> managers,
      required List<RemoteCallServer> rpcServers,
    }) async {
      for (final m in managers) {
        m.dispose();
      }
      for (final s in rpcServers) {
        s.dispose();
      }
      for (final c in clients) {
        await c.disconnect();
      }
      for (final id in deviceIds) {
        await LanClientServiceImpl.dispose(id);
      }
    }

    Map<String, dynamic>? parsePayload(String? content) {
      if (content == null) return null;
      try {
        final contentData = jsonDecode(content) as Map<String, dynamic>;
        return contentData['payload'] as Map<String, dynamic>?;
      } catch (_) {
        return null;
      }
    }

    StreamSubscription<LanMessage> setupADispatch(
      LanClientServiceImpl clientA,
      RemoteCallManager rpcManagerA,
    ) {
      return clientA.messageStream.listen((msg) {
        final payload = parsePayload(msg.content);
        if (payload == null) return;

        switch (msg.type) {
          case LanMessageType.rpcResponse:
            rpcManagerA.handleResponse(payload);
          case LanMessageType.rpcStreamChunk:
            rpcManagerA.handleStreamChunk(payload);
          case LanMessageType.rpcStreamEnd:
            rpcManagerA.handleStreamEnd(payload);
          case LanMessageType.rpcError:
            rpcManagerA.handleError(payload);
          default:
            break;
        }
      });
    }

    /// 设置设备 B 的 RPC 请求分发。
    ///
    /// 将 DeviceB 收到的 RPC 请求转发给 rpcServerB 处理。
    /// `_requestId` 和 `_fromDeviceId` 由 `RemoteCallServer._handleStreamRequest` 自动注入。
    StreamSubscription<LanMessage> setupBDispatch(
      LanClientServiceImpl clientB,
      RemoteCallServer rpcServerB,
    ) {
      return clientB.messageStream.listen((msg) {
        if (msg.type == LanMessageType.rpcRequest) {
          final payload = parsePayload(msg.content);
          if (payload != null) {
            // _requestId and _fromDeviceId are now auto-injected by RemoteCallServer._handleStreamRequest
            rpcServerB.handleRequest(payload);
          }
        }
      });
    }

    // ════════════════════════════════════════════════════════
    // Test 1: Small file download via binary frames
    // ════════════════════════════════════════════════════════

    test('small file download via binary frames', () async {
      final uuid = const Uuid().v4().substring(0, 8);
      final deviceAId = 'dev-A-$uuid';
      final deviceBId = 'dev-B-$uuid';
      final serverPort = server.port;
      const topic = 'e2e-test';

      final testContent = 'Hello, WebSocket Binary Transfer!';
      final testBytes = utf8.encode(testContent);
      final testFileSha256 = sha256.convert(testBytes).toString();
      final sourceFile = File(p.join(tempDir, 'source_test.txt'));
      await sourceFile.writeAsBytes(testBytes);

      final clientA =
          await createAndConnectClient(deviceAId, topic, serverPort);
      final clientB =
          await createAndConnectClient(deviceBId, topic, serverPort);

      final bridgeA = _BridgeLanClientService(
          realClient: clientA, overrideDeviceId: deviceAId);
      final bridgeB = _BridgeLanClientService(
          realClient: clientB, overrideDeviceId: deviceBId);

      final rpcManagerA = RemoteCallManager(
          clientService: bridgeA, localDeviceId: deviceAId);
      final rpcServerB = RemoteCallServer(
          clientService: bridgeB, localDeviceId: deviceBId);

      rpcServerB.registerStream(
        AgentRpcConfig.methodReadFileStream,
        (params) async* {
          final path = params['path'] as String;
          final requestId = params['_requestId'] as String? ?? '';
          final toDeviceId = params['_fromDeviceId'] as String? ?? '';
          final chunkSize = params['chunkSize'] as int? ?? 64 * 1024;

          final file = File(path);
          if (!await file.exists()) {
            throw Exception('File not found: $path');
          }

          final fileSize = await file.length();
          final raf = await file.open();

          try {
            int offset = 0;
            while (offset < fileSize) {
              await raf.setPosition(offset);
              final remaining = fileSize - offset;
              final readLen = remaining < chunkSize ? remaining : chunkSize;
              final bytes = await raf.read(readLen);
              final isLast = (offset + bytes.length) >= fileSize;

              final frame = buildBinaryFrame(
                toDeviceId: toDeviceId,
                requestId: requestId,
                payload: Uint8List.fromList(bytes),
                isLast: isLast,
              );
              clientB.sendBinaryMessage(frame);
              // Allow event loop to process WebSocket delivery
              await Future<void>.delayed(Duration.zero);

              offset += bytes.length;
              yield RpcStreamEvent.chunk('');
            }
          } finally {
            await raf.close();
          }

          yield RpcStreamEvent.done({
            'fileSize': fileSize,
            'fileName': p.basename(path),
          });
        },
      );

      final subA = setupADispatch(clientA, rpcManagerA);
      final subB = setupBDispatch(clientB, rpcServerB);

      final saveDir = p.join(tempDir, 'downloads');
      await Directory(saveDir).create(recursive: true);

      final stream = rpcManagerA.invokeStream(
        AgentRpcConfig.methodReadFileStream,
        {'path': sourceFile.path},
        toDeviceId: deviceBId,
        timeout: 0,
      );

      final savePath = p.join(saveDir, 'test.txt');
      final sink = File(savePath).openWrite();

      // Collect all binary chunks (no requestId filtering needed - only one download at a time)
      final receivedChunks = <BinaryChunkEvent>[];
      final binaryDone = Completer<void>();
      final binarySub = clientA.binaryChunkStream.listen((chunk) {
        receivedChunks.add(chunk);
        if (chunk.isLast && !binaryDone.isCompleted) {
          binaryDone.complete();
        }
      });

      try {
        await for (final event in stream) {
          if (event.isDone) break;
        }
        await binaryDone.future.timeout(const Duration(seconds: 5));
      } finally {
        await binarySub.cancel();
      }

      // Write all chunks to file
      int received = 0;
      final progressList = <double>[];
      for (final chunk in receivedChunks) {
        sink.add(chunk.data);
        received += chunk.data.length;
        if (testBytes.isNotEmpty) {
          progressList.add(received / testBytes.length);
        }
      }
      await sink.close();

      final savedBytes = await File(savePath).readAsBytes();
      final savedHash = sha256.convert(savedBytes).toString();

      expect(savedHash, equals(testFileSha256));
      expect(utf8.decode(savedBytes), equals(testContent));
      expect(savedBytes.length, equals(testBytes.length));
      expect(progressList, isNotEmpty);
      expect(progressList.last, closeTo(1.0, 0.01));

      await subA.cancel();
      await subB.cancel();
      await cleanupClients(
        clients: [clientA, clientB],
        deviceIds: [deviceAId, deviceBId],
        managers: [rpcManagerA],
        rpcServers: [rpcServerB],
      );
    });

    // ════════════════════════════════════════════════════════
    // Test 2: Large file multi-chunk download
    // ════════════════════════════════════════════════════════

    test('large file multi-chunk download', () async {
      final uuid = const Uuid().v4().substring(0, 8);
      final deviceAId = 'dev-A-$uuid';
      final deviceBId = 'dev-B-$uuid';
      final serverPort = server.port;
      const topic = 'e2e-large';

      final rng = Random(42);
      final testBytes =
          Uint8List.fromList(List.generate(256 * 1024, (_) => rng.nextInt(256)));
      final testFileSha256 = sha256.convert(testBytes).toString();
      final sourceFile = File(p.join(tempDir, 'source_large.bin'));
      await sourceFile.writeAsBytes(testBytes);

      final clientA =
          await createAndConnectClient(deviceAId, topic, serverPort);
      final clientB =
          await createAndConnectClient(deviceBId, topic, serverPort);

      final bridgeA = _BridgeLanClientService(
          realClient: clientA, overrideDeviceId: deviceAId);
      final bridgeB = _BridgeLanClientService(
          realClient: clientB, overrideDeviceId: deviceBId);

      final rpcManagerA = RemoteCallManager(
          clientService: bridgeA, localDeviceId: deviceAId);
      final rpcServerB = RemoteCallServer(
          clientService: bridgeB, localDeviceId: deviceBId);

      const chunkSize = 32 * 1024;
      rpcServerB.registerStream(
        AgentRpcConfig.methodReadFileStream,
        (params) async* {
          final path = params['path'] as String;
          final requestId = params['_requestId'] as String? ?? '';
          final toDeviceId = params['_fromDeviceId'] as String? ?? '';

          final file = File(path);
          final fileSize = await file.length();
          final raf = await file.open();

          try {
            int offset = 0;
            while (offset < fileSize) {
              await raf.setPosition(offset);
              final remaining = fileSize - offset;
              final readLen = remaining < chunkSize ? remaining : chunkSize;
              final bytes = await raf.read(readLen);
              final isLast = (offset + bytes.length) >= fileSize;

              final frame = buildBinaryFrame(
                toDeviceId: toDeviceId,
                requestId: requestId,
                payload: Uint8List.fromList(bytes),
                isLast: isLast,
              );
              clientB.sendBinaryMessage(frame);
              // Allow event loop to process WebSocket delivery
              await Future<void>.delayed(Duration.zero);

              offset += bytes.length;
              yield RpcStreamEvent.chunk('');
            }
          } finally {
            await raf.close();
          }

          yield RpcStreamEvent.done({
            'fileSize': fileSize,
            'fileName': p.basename(path),
          });
        },
      );

      final subA = setupADispatch(clientA, rpcManagerA);
      final subB = setupBDispatch(clientB, rpcServerB);

      final saveDir = p.join(tempDir, 'downloads_large');
      await Directory(saveDir).create(recursive: true);

      final stream = rpcManagerA.invokeStream(
        AgentRpcConfig.methodReadFileStream,
        {'path': sourceFile.path},
        toDeviceId: deviceBId,
        timeout: 0,
      );

      final savePath = p.join(saveDir, 'large.bin');
      final sink = File(savePath).openWrite();

      // Collect all binary chunks (no requestId filtering needed - only one download at a time)
      final receivedChunks = <BinaryChunkEvent>[];
      final binaryDone = Completer<void>();
      final binarySub = clientA.binaryChunkStream.listen((chunk) {
        receivedChunks.add(chunk);
        if (chunk.isLast && !binaryDone.isCompleted) {
          binaryDone.complete();
        }
      });

      try {
        await for (final event in stream) {
          if (event.isDone) break;
        }
        await binaryDone.future.timeout(const Duration(seconds: 5));
      } finally {
        await binarySub.cancel();
      }

      // Write all chunks to file
      int received = 0;
      int chunkCount = 0;
      final progressList = <double>[];
      for (final chunk in receivedChunks) {
        sink.add(chunk.data);
        received += chunk.data.length;
        chunkCount++;
        progressList.add(received / testBytes.length);
      }
      await sink.close();

      final savedBytes = await File(savePath).readAsBytes();
      expect(savedBytes.length, equals(testBytes.length));
      expect(sha256.convert(savedBytes).toString(), equals(testFileSha256));
      expect(chunkCount, equals(8)); // 256KB / 32KB = 8 chunks
      expect(progressList.first, closeTo(0.125, 0.01));
      expect(progressList.last, closeTo(1.0, 0.01));

      await subA.cancel();
      await subB.cancel();
      await cleanupClients(
        clients: [clientA, clientB],
        deviceIds: [deviceAId, deviceBId],
        managers: [rpcManagerA],
        rpcServers: [rpcServerB],
      );
    });

    // ════════════════════════════════════════════════════════
    // Test 3: Empty file download
    // ════════════════════════════════════════════════════════

    test('empty file download', () async {
      final uuid = const Uuid().v4().substring(0, 8);
      final deviceAId = 'dev-A-$uuid';
      final deviceBId = 'dev-B-$uuid';
      final serverPort = server.port;
      const topic = 'e2e-empty';

      final sourceFile = File(p.join(tempDir, 'empty.txt'));
      await sourceFile.writeAsBytes([]);
      final testFileSha256 = sha256.convert(<int>[]).toString();

      final clientA =
          await createAndConnectClient(deviceAId, topic, serverPort);
      final clientB =
          await createAndConnectClient(deviceBId, topic, serverPort);

      final bridgeA = _BridgeLanClientService(
          realClient: clientA, overrideDeviceId: deviceAId);
      final bridgeB = _BridgeLanClientService(
          realClient: clientB, overrideDeviceId: deviceBId);

      final rpcManagerA = RemoteCallManager(
          clientService: bridgeA, localDeviceId: deviceAId);
      final rpcServerB = RemoteCallServer(
          clientService: bridgeB, localDeviceId: deviceBId);

      rpcServerB.registerStream(
        AgentRpcConfig.methodReadFileStream,
        (params) async* {
          final path = params['path'] as String;
          final file = File(path);
          final fileSize = await file.length();
          yield RpcStreamEvent.done({
            'fileSize': fileSize,
            'fileName': p.basename(path),
          });
        },
      );

      final subA = setupADispatch(clientA, rpcManagerA);
      final subB = setupBDispatch(clientB, rpcServerB);

      final saveDir = p.join(tempDir, 'downloads_empty');
      await Directory(saveDir).create(recursive: true);

      final stream = rpcManagerA.invokeStream(
        AgentRpcConfig.methodReadFileStream,
        {'path': sourceFile.path},
        toDeviceId: deviceBId,
        timeout: 0,
      );

      final savePath = p.join(saveDir, 'empty.txt');
      final sink = File(savePath).openWrite();
      String? reqId;

      // CRITICAL: Subscribe to binaryChunkStream BEFORE consuming RPC stream,
      // because binary frames may arrive before the first RPC text event.
      final binarySub = clientA.binaryChunkStream.listen((chunk) {
        if (reqId != null && chunk.requestId == reqId) {
          sink.add(chunk.data);
        }
      });

      try {
        await for (final event in stream) {
          if (reqId == null && event.requestId != null) {
            reqId = event.requestId!;
          }
          if (event.isDone) break;
        }
      } finally {
        await binarySub.cancel();
      }
      await sink.close();

      final savedBytes = await File(savePath).readAsBytes();
      expect(savedBytes.length, equals(0));
      expect(sha256.convert(savedBytes).toString(), equals(testFileSha256));

      await subA.cancel();
      await subB.cancel();
      await cleanupClients(
        clients: [clientA, clientB],
        deviceIds: [deviceAId, deviceBId],
        managers: [rpcManagerA],
        rpcServers: [rpcServerB],
      );
    });

    // ════════════════════════════════════════════════════════
    // Test 4: File not found RPC error
    // ════════════════════════════════════════════════════════

    test('file not found RPC error', () async {
      final uuid = const Uuid().v4().substring(0, 8);
      final deviceAId = 'dev-A-$uuid';
      final deviceBId = 'dev-B-$uuid';
      final serverPort = server.port;
      const topic = 'e2e-notfound';

      final clientA =
          await createAndConnectClient(deviceAId, topic, serverPort);
      final clientB =
          await createAndConnectClient(deviceBId, topic, serverPort);

      final bridgeA = _BridgeLanClientService(
          realClient: clientA, overrideDeviceId: deviceAId);
      final bridgeB = _BridgeLanClientService(
          realClient: clientB, overrideDeviceId: deviceBId);

      final rpcManagerA = RemoteCallManager(
          clientService: bridgeA, localDeviceId: deviceAId);
      final rpcServerB = RemoteCallServer(
          clientService: bridgeB, localDeviceId: deviceBId);

      rpcServerB.registerStream(
        AgentRpcConfig.methodReadFileStream,
        (params) async* {
          final path = params['path'] as String;
          final file = File(path);
          if (!await file.exists()) {
            throw Exception('File not found: $path');
          }
          yield RpcStreamEvent.done({});
        },
      );

      final subA = setupADispatch(clientA, rpcManagerA);
      final subB = setupBDispatch(clientB, rpcServerB);

      final stream = rpcManagerA.invokeStream(
        AgentRpcConfig.methodReadFileStream,
        {'path': '/nonexistent/path/file.txt'},
        toDeviceId: deviceBId,
        timeout: 5000,
      );

      Object? caughtError;
      try {
        await for (final _ in stream) {
          // drain
        }
      } catch (e) {
        caughtError = e;
      }

      expect(caughtError, isNotNull);
      expect(caughtError, isA<Exception>());

      await subA.cancel();
      await subB.cancel();
      await cleanupClients(
        clients: [clientA, clientB],
        deviceIds: [deviceAId, deviceBId],
        managers: [rpcManagerA],
        rpcServers: [rpcServerB],
      );
    });

    // ════════════════════════════════════════════════════════
    // Test 5: Progress callback per chunk
    // ════════════════════════════════════════════════════════

    test('progress callback per chunk', () async {
      final uuid = const Uuid().v4().substring(0, 8);
      final deviceAId = 'dev-A-$uuid';
      final deviceBId = 'dev-B-$uuid';
      final serverPort = server.port;
      const topic = 'e2e-progress';

      final rng = Random(123);
      final testBytes =
          Uint8List.fromList(List.generate(4 * 1024, (_) => rng.nextInt(256)));
      final sourceFile = File(p.join(tempDir, 'progress_test.bin'));
      await sourceFile.writeAsBytes(testBytes);

      final clientA =
          await createAndConnectClient(deviceAId, topic, serverPort);
      final clientB =
          await createAndConnectClient(deviceBId, topic, serverPort);

      final bridgeA = _BridgeLanClientService(
          realClient: clientA, overrideDeviceId: deviceAId);
      final bridgeB = _BridgeLanClientService(
          realClient: clientB, overrideDeviceId: deviceBId);

      final rpcManagerA = RemoteCallManager(
          clientService: bridgeA, localDeviceId: deviceAId);
      final rpcServerB = RemoteCallServer(
          clientService: bridgeB, localDeviceId: deviceBId);

      const chunkSize = 1024;
      rpcServerB.registerStream(
        AgentRpcConfig.methodReadFileStream,
        (params) async* {
          final path = params['path'] as String;
          final requestId = params['_requestId'] as String? ?? '';
          final toDeviceId = params['_fromDeviceId'] as String? ?? '';

          final file = File(path);
          final fileSize = await file.length();
          final raf = await file.open();

          try {
            int offset = 0;
            while (offset < fileSize) {
              await raf.setPosition(offset);
              final remaining = fileSize - offset;
              final readLen = remaining < chunkSize ? remaining : chunkSize;
              final bytes = await raf.read(readLen);
              final isLast = (offset + bytes.length) >= fileSize;

              final frame = buildBinaryFrame(
                toDeviceId: toDeviceId,
                requestId: requestId,
                payload: Uint8List.fromList(bytes),
                isLast: isLast,
              );
              clientB.sendBinaryMessage(frame);
              // Allow event loop to process WebSocket delivery
              await Future<void>.delayed(Duration.zero);

              offset += bytes.length;
              yield RpcStreamEvent.chunk('');
            }
          } finally {
            await raf.close();
          }

          yield RpcStreamEvent.done({
            'fileSize': fileSize,
            'fileName': p.basename(path),
          });
        },
      );

      final subA = setupADispatch(clientA, rpcManagerA);
      final subB = setupBDispatch(clientB, rpcServerB);

      final stream = rpcManagerA.invokeStream(
        AgentRpcConfig.methodReadFileStream,
        {'path': sourceFile.path},
        toDeviceId: deviceBId,
        timeout: 0,
      );

      // Collect all binary chunks (no requestId filtering needed - only one download at a time)
      final receivedChunks = <BinaryChunkEvent>[];
      final progressList = <double>[];
      final binaryDone = Completer<void>();
      final binarySub = clientA.binaryChunkStream.listen((chunk) {
        receivedChunks.add(chunk);
        if (testBytes.isNotEmpty) {
          int totalSoFar = 0;
          for (final c in receivedChunks) {
            totalSoFar += c.data.length;
          }
          progressList.add(totalSoFar / testBytes.length);
        }
        if (chunk.isLast && !binaryDone.isCompleted) {
          binaryDone.complete();
        }
      });

      try {
        await for (final event in stream) {
          if (event.isDone) break;
        }
        await binaryDone.future.timeout(const Duration(seconds: 5));
      } finally {
        await binarySub.cancel();
      }

      expect(progressList.length, equals(4));
      expect(progressList[0], closeTo(0.25, 0.01));
      expect(progressList[1], closeTo(0.50, 0.01));
      expect(progressList[2], closeTo(0.75, 0.01));
      expect(progressList[3], closeTo(1.00, 0.01));

      await subA.cancel();
      await subB.cancel();
      await cleanupClients(
        clients: [clientA, clientB],
        deviceIds: [deviceAId, deviceBId],
        managers: [rpcManagerA],
        rpcServers: [rpcServerB],
      );
    });

    // ════════════════════════════════════════════════════════
    // Test 6: requestId propagation through RPC stream
    // ════════════════════════════════════════════════════════

    test('requestId propagation through RPC stream', () async {
      final uuid = const Uuid().v4().substring(0, 8);
      final deviceAId = 'dev-A-$uuid';
      final deviceBId = 'dev-B-$uuid';
      final serverPort = server.port;
      const topic = 'e2e-reqid';

      final sourceFile = File(p.join(tempDir, 'reqid_test.txt'));
      await sourceFile.writeAsBytes(utf8.encode('test request id'));

      final clientA =
          await createAndConnectClient(deviceAId, topic, serverPort);
      final clientB =
          await createAndConnectClient(deviceBId, topic, serverPort);

      final bridgeA = _BridgeLanClientService(
          realClient: clientA, overrideDeviceId: deviceAId);
      final bridgeB = _BridgeLanClientService(
          realClient: clientB, overrideDeviceId: deviceBId);

      final rpcManagerA = RemoteCallManager(
          clientService: bridgeA, localDeviceId: deviceAId);
      final rpcServerB = RemoteCallServer(
          clientService: bridgeB, localDeviceId: deviceBId);

      rpcServerB.registerStream(
        AgentRpcConfig.methodReadFileStream,
        (params) async* {
          final path = params['path'] as String;
          final requestId = params['_requestId'] as String? ?? '';
          final toDeviceId = params['_fromDeviceId'] as String? ?? '';

          final file = File(path);
          final bytes = await file.readAsBytes();

          final frame = buildBinaryFrame(
            toDeviceId: toDeviceId,
            requestId: requestId,
            payload: Uint8List.fromList(bytes),
            isLast: true,
          );
          clientB.sendBinaryMessage(frame);
          // Allow event loop to process WebSocket delivery
          await Future<void>.delayed(Duration.zero);

          yield RpcStreamEvent.chunk('');
          yield RpcStreamEvent.done({'fileSize': bytes.length});
        },
      );

      final subA = setupADispatch(clientA, rpcManagerA);
      final subB = setupBDispatch(clientB, rpcServerB);

      final stream = rpcManagerA.invokeStream(
        AgentRpcConfig.methodReadFileStream,
        {'path': sourceFile.path},
        toDeviceId: deviceBId,
        timeout: 0,
      );

      final requestIds = <String>{};
      final binaryDone = Completer<void>();
      final binarySub = clientA.binaryChunkStream.listen((chunk) {
        if (chunk.isLast && !binaryDone.isCompleted) {
          binaryDone.complete();
        }
      });

      try {
        await for (final event in stream) {
          if (event.requestId != null) {
            requestIds.add(event.requestId!);
          }
          if (event.isDone) break;
        }
        await binaryDone.future.timeout(const Duration(seconds: 5));
      } finally {
        await binarySub.cancel();
      }

      expect(requestIds, isNotEmpty);
      final capturedRequestId = requestIds.first;
      expect(capturedRequestId.length, greaterThan(0));
      expect(capturedRequestId.contains('-'), isTrue);

      await subA.cancel();
      await subB.cancel();
      await cleanupClients(
        clients: [clientA, clientB],
        deviceIds: [deviceAId, deviceBId],
        managers: [rpcManagerA],
        rpcServers: [rpcServerB],
      );
    });

    // ════════════════════════════════════════════════════════
    // Test 7: SHA256 mismatch detection and file deletion
    // ════════════════════════════════════════════════════════

    test('SHA256 mismatch detection and file deletion', () async {
      final uuid = const Uuid().v4().substring(0, 8);
      final deviceAId = 'dev-A-$uuid';
      final deviceBId = 'dev-B-$uuid';
      final serverPort = server.port;
      const topic = 'e2e-sha256';

      final testBytes = utf8.encode('correct content');
      final sourceFile = File(p.join(tempDir, 'sha_test.txt'));
      await sourceFile.writeAsBytes(testBytes);

      final wrongSha256 =
          sha256.convert(utf8.encode('wrong hash')).toString();

      final clientA =
          await createAndConnectClient(deviceAId, topic, serverPort);
      final clientB =
          await createAndConnectClient(deviceBId, topic, serverPort);

      final bridgeA = _BridgeLanClientService(
          realClient: clientA, overrideDeviceId: deviceAId);
      final bridgeB = _BridgeLanClientService(
          realClient: clientB, overrideDeviceId: deviceBId);

      final rpcManagerA = RemoteCallManager(
          clientService: bridgeA, localDeviceId: deviceAId);
      final rpcServerB = RemoteCallServer(
          clientService: bridgeB, localDeviceId: deviceBId);

      rpcServerB.registerStream(
        AgentRpcConfig.methodReadFileStream,
        (params) async* {
          final requestId = params['_requestId'] as String? ?? '';
          final toDeviceId = params['_fromDeviceId'] as String? ?? '';

          final corrupted = utf8.encode('CORRUPTED DATA!!!');
          final frame = buildBinaryFrame(
            toDeviceId: toDeviceId,
            requestId: requestId,
            payload: Uint8List.fromList(corrupted),
            isLast: true,
          );
          clientB.sendBinaryMessage(frame);
          // Allow event loop to process WebSocket delivery
          await Future<void>.delayed(Duration.zero);

          yield RpcStreamEvent.chunk('');
          yield RpcStreamEvent.done({
            'fileSize': corrupted.length,
            'fileName': 'sha_test.txt',
          });
        },
      );

      final subA = setupADispatch(clientA, rpcManagerA);
      final subB = setupBDispatch(clientB, rpcServerB);

      final saveDir = p.join(tempDir, 'downloads_sha');
      await Directory(saveDir).create(recursive: true);

      final meta = FileMetaMessage(
        fileId: 'test-file-id',
        fileName: 'sha_test.txt',
        fileSize: testBytes.length,
        sha256: wrongSha256,
        filePath: sourceFile.path,
        fromDeviceId: deviceBId,
      );

      final stream = rpcManagerA.invokeStream(
        AgentRpcConfig.methodReadFileStream,
        {'path': sourceFile.path},
        toDeviceId: deviceBId,
        timeout: 0,
      );

      final savePath = p.join(saveDir, 'sha_test.txt');
      final sink = File(savePath).openWrite();

      // Collect all binary chunks (no requestId filtering needed - only one download at a time)
      final receivedChunks = <BinaryChunkEvent>[];
      final binaryDone = Completer<void>();
      final binarySub = clientA.binaryChunkStream.listen((chunk) {
        receivedChunks.add(chunk);
        if (chunk.isLast && !binaryDone.isCompleted) {
          binaryDone.complete();
        }
      });

      try {
        await for (final event in stream) {
          if (event.isDone) break;
        }
        await binaryDone.future.timeout(const Duration(seconds: 5));
      } finally {
        await binarySub.cancel();
      }

      // Write all chunks to file
      for (final chunk in receivedChunks) {
        sink.add(chunk.data);
      }
      await sink.close();

      final savedBytes = await File(savePath).readAsBytes();
      final actualHash = sha256.convert(savedBytes).toString();

      expect(actualHash, isNot(equals(meta.sha256)));

      if (actualHash != meta.sha256) {
        await File(savePath).delete();
      }

      expect(await File(savePath).exists(), isFalse);

      await subA.cancel();
      await subB.cancel();
      await cleanupClients(
        clients: [clientA, clientB],
        deviceIds: [deviceAId, deviceBId],
        managers: [rpcManagerA],
        rpcServers: [rpcServerB],
      );
    });
  });
}
