import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/agent/rpc/agent_rpc_config.dart';
import 'package:wenzagent/src/entity/lan_message.dart';
import 'package:wenzagent/src/lan/impl/lan_client_service_impl.dart';
import 'package:wenzagent/src/lan/impl/lan_host_service_impl.dart';
import 'package:wenzagent/src/lan/lan_client_service.dart';
import 'package:wenzagent/src/rpc/remote_call_manager.dart';
import 'package:wenzagent/src/rpc/remote_call_server.dart';
import 'package:wenzagent/src/rpc/rpc_protocol.dart';
import 'package:wenzagent/src/utils/logger.dart';
import 'package:path/path.dart' as p;

class _BridgeLanClientService implements LanClientService {
  final LanClientService _realClient;
  final String _overrideDeviceId;
  _BridgeLanClientService({required LanClientService realClient, required String overrideDeviceId})
      : _realClient = realClient, _overrideDeviceId = overrideDeviceId;

  @override bool get isConnected => _realClient.isConnected;
  @override bool get isConnecting => _realClient.isConnecting;
  @override String get deviceId => _overrideDeviceId;
  @override String? get topic => _realClient.topic;
  @override String? get hostIp => _realClient.hostIp;
  @override int get hostPort => _realClient.hostPort;
  @override double get uploadProgress => _realClient.uploadProgress;
  @override double get downloadProgress => _realClient.downloadProgress;
  @override Stream<LanMessage> get messageStream => _realClient.messageStream;
  @override Future<void> connect(String hostIp, {int port = 9090}) => _realClient.connect(hostIp, port: port);
  @override Future<void> disconnect() => _realClient.disconnect();
  @override Future<void> reconnect() => _realClient.reconnect();
  @override void sendMessage(String content) => _realClient.sendMessage(content);
  @override Future<bool> sendLanMessage(LanMessage message) => _realClient.sendLanMessage(message);
  @override Future<String> uploadFile(String filePath) => _realClient.uploadFile(filePath);
  @override Future<void> downloadFile(String fileId, String savePath) => _realClient.downloadFile(fileId, savePath);
  @override Future<ClientInfo> getClientInfo() => _realClient.getClientInfo();
  @override void sendBinaryMessage(Uint8List data) => _realClient.sendBinaryMessage(data);
  @override Stream<BinaryChunkEvent> get binaryChunkStream => _realClient.binaryChunkStream;
}

Uint8List buildBinaryFrame({required String toDeviceId, required String requestId, required Uint8List payload, required bool isLast}) {
  final toDeviceIdBytes = utf8.encode(toDeviceId);
  final requestIdBytes = utf8.encode(requestId);
  final builder = BytesBuilder();
  builder.addByte(0x01);
  builder.addByte(0x02);
  final toDeviceIdLenData = ByteData(4)..setUint32(0, toDeviceIdBytes.length);
  builder.add(toDeviceIdLenData.buffer.asUint8List());
  builder.add(toDeviceIdBytes);
  final requestIdLenData = ByteData(4)..setUint32(0, requestIdBytes.length);
  builder.add(requestIdLenData.buffer.asUint8List());
  builder.add(requestIdBytes);
  builder.addByte(isLast ? 0x01 : 0x00);
  builder.add(payload);
  return builder.takeBytes();
}

void main() {
  Logger.level = LogLevel.warn;

  test('binary frame forwarding debug', () async {
    final server = LanHostServiceImpl();
    final tempDir = '${Directory.systemTemp.path}${p.separator}wenzagent_debug_test';
    await Directory(tempDir).create(recursive: true);
    await server.start(port: 0, storageDir: tempDir);

    final uuid = const Uuid().v4().substring(0, 8);
    final deviceAId = 'dev-A-$uuid';
    final deviceBId = 'dev-B-$uuid';
    final serverPort = server.port;
    const topic = 'debug-test';
    // ignore: avoid_print
    print('[DEBUG] serverPort=$serverPort, A=$deviceAId, B=$deviceBId');

    // Create clients
    final clientA = LanClientServiceImpl(deviceId: deviceAId, topic: topic);
    await clientA.connect('127.0.0.1', port: serverPort);
    final clientB = LanClientServiceImpl(deviceId: deviceBId, topic: topic);
    await clientB.connect('127.0.0.1', port: serverPort);

    // Wait for registration
    for (int i = 0; i < 30; i++) {
      final aOk = server.clients.any((c) => c.deviceId == deviceAId);
      final bOk = server.clients.any((c) => c.deviceId == deviceBId);
      if (aOk && bOk) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    // ignore: avoid_print
    print('[DEBUG] clients registered: ${server.clients.map((c) => c.deviceId).toList()}');

    final bridgeA = _BridgeLanClientService(realClient: clientA, overrideDeviceId: deviceAId);
    final bridgeB = _BridgeLanClientService(realClient: clientB, overrideDeviceId: deviceBId);

    final rpcManagerA = RemoteCallManager(clientService: bridgeA, localDeviceId: deviceAId);
    final rpcServerB = RemoteCallServer(clientService: bridgeB, localDeviceId: deviceBId);

    // Track request IDs
    String? capturedRequestId;
    String? capturedToDeviceId;

    rpcServerB.registerStream(
      AgentRpcConfig.methodReadFileStream,
      (params) async* {
        final requestId = params['_requestId'] as String? ?? '';
        final toDeviceId = params['_fromDeviceId'] as String? ?? '';
        capturedRequestId = requestId;
        capturedToDeviceId = toDeviceId;
        // ignore: avoid_print
        print('[DEBUG-HANDLER] requestId=$requestId, toDeviceId=$toDeviceId');

        final testPayload = Uint8List.fromList(utf8.encode('Hello Binary!'));
        final frame = buildBinaryFrame(
          toDeviceId: toDeviceId,
          requestId: requestId,
          payload: testPayload,
          isLast: true,
        );
        // ignore: avoid_print
        print('[DEBUG-HANDLER] sending binary frame: to=$toDeviceId, req=$requestId, frameSize=${frame.length}');
        clientB.sendBinaryMessage(frame);

        yield RpcStreamEvent.chunk('');
        yield RpcStreamEvent.done({'fileSize': testPayload.length});
      },
    );

    // Setup dispatch
    Map<String, dynamic>? parsePayload(String? content) {
      if (content == null) return null;
      try {
        final contentData = jsonDecode(content) as Map<String, dynamic>;
        return contentData['payload'] as Map<String, dynamic>?;
      } catch (_) { return null; }
    }

    final subA = clientA.messageStream.listen((msg) {
      final payload = parsePayload(msg.content);
      if (payload == null) return;
      switch (msg.type) {
        case LanMessageType.rpcResponse: rpcManagerA.handleResponse(payload);
        case LanMessageType.rpcStreamChunk: rpcManagerA.handleStreamChunk(payload);
        case LanMessageType.rpcStreamEnd: rpcManagerA.handleStreamEnd(payload);
        case LanMessageType.rpcError: rpcManagerA.handleError(payload);
        default: break;
      }
    });

    final subB = clientB.messageStream.listen((msg) {
      if (msg.type == LanMessageType.rpcRequest) {
        final payload = parsePayload(msg.content);
        if (payload != null) {
          final params = payload['params'] as Map<String, dynamic>?;
          if (params != null) {
            params['_requestId'] ??= payload['requestId'] ?? '';
            params['_fromDeviceId'] ??= payload['fromDeviceId'] ?? '';
          }
          // ignore: avoid_print
          print('[DEBUG-DISPATCH-B] payload keys: ${payload.keys.toList()}, params: $params');
          rpcServerB.handleRequest(payload);
        }
      }
    });

    // Invoke RPC stream
    final stream = rpcManagerA.invokeStream(
      AgentRpcConfig.methodReadFileStream,
      {'path': '/fake/path.txt'},
      toDeviceId: deviceBId,
      timeout: 0,
    );

    final binaryDone = Completer<void>();
    StreamSubscription<BinaryChunkEvent>? binarySub;
    int binaryChunkCount = 0;

    try {
      await for (final event in stream) {
        // ignore: avoid_print
        print('[DEBUG-EVENT] isDone=${event.isDone}, requestId=${event.requestId?.substring(0, 8)}, chunk=${event.chunk}');
        if (binarySub == null && event.requestId != null) {
          final reqId = event.requestId!;
          // ignore: avoid_print
          print('[DEBUG] subscribing to binaryChunkStream for reqId=$reqId');
          binarySub = clientA.binaryChunkStream.listen((chunk) {
            // ignore: avoid_print
            print('[DEBUG-BINARY] chunk: reqId=${chunk.requestId.substring(0, 8)}, len=${chunk.data.length}, isLast=${chunk.isLast}');
            binaryChunkCount++;
            if (chunk.isLast && !binaryDone.isCompleted) {
              binaryDone.complete();
            }
          });
        }
        if (event.isDone) break;
      }
      // ignore: avoid_print
      print('[DEBUG] stream loop done, waiting for binary...');
      await binaryDone.future.timeout(const Duration(seconds: 5));
      // ignore: avoid_print
      print('[DEBUG] binary received! count=$binaryChunkCount');
    } on TimeoutException {
      // ignore: avoid_print
      print('[DEBUG] TIMEOUT waiting for binary! count=$binaryChunkCount, capturedRequestId=$capturedRequestId, capturedToDeviceId=$capturedToDeviceId');
      // ignore: avoid_print
      print('[DEBUG] server clients: ${server.clients.map((c) => '${c.deviceId}(id=${c.id.substring(0, 8)})').toList()}');
    } finally {
      await binarySub?.cancel();
    }

    await subA.cancel();
    await subB.cancel();
    rpcManagerA.dispose();
    rpcServerB.dispose();
    await clientA.disconnect();
    await clientB.disconnect();
    await LanClientServiceImpl.dispose(deviceAId);
    await LanClientServiceImpl.dispose(deviceBId);
    await server.stop();
    try { await Directory(tempDir).delete(recursive: true); } catch (_) {}

    expect(binaryChunkCount, equals(1));
  });
}
