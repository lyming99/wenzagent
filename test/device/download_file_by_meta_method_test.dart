import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/lan/lan_client_service.dart';
import 'package:wenzagent/src/rpc/rpc_protocol.dart';

// ============================================================
// 核心下载逻辑（从 DeviceClient.downloadFileByMeta 提取）
//
// 因为 DeviceClient 的构造函数是私有的，无法子类化。
// 这里将核心下载逻辑提取为独立函数进行测试。
// ============================================================

/// 模拟 DeviceConnectionManager 的两个关键接口
abstract class DownloadConnection {
  bool get isConnected;

  /// 发起流式 RPC 调用
  Stream<RpcStreamEvent> invokeRemoteStream(
    String toDeviceId,
    String method,
    Map<String, dynamic> params, {
    int timeout = 120000,
  });

  /// 二进制 chunk 事件流
  Stream<BinaryChunkEvent> get binaryChunkStream;
}

/// 从 DeviceClient.downloadFileByMeta 提取的核心下载逻辑
Future<String> downloadFileByMetaLogic({
  required DownloadConnection connMgr,
  required FileMetaMessage meta,
  required String saveDir,
  void Function(double progress)? onProgress,
}) async {
  if (!connMgr.isConnected) {
    throw StateError('未连接到服务器');
  }

  // 1. 拼接保存路径
  final savePath = '$saveDir${Platform.pathSeparator}${meta.fileName}';
  final file = File(savePath);
  final sink = file.openWrite();
  int received = 0;

  try {
    // 2. 发起 RPC 流式请求
    final stream = connMgr.invokeRemoteStream(
      meta.fromDeviceId,
      'agentReadFileStream',
      {'path': meta.filePath},
      timeout: 0,
    );

    // 3. 监听二进制 chunk 流（按 requestId 过滤）
    StreamSubscription<BinaryChunkEvent>? binarySub;

    try {
      await for (final event in stream) {
        // 从首个事件中提取 requestId，开始监听二进制流
        if (binarySub == null && event.requestId != null) {
          final reqId = event.requestId!;
          binarySub = connMgr.binaryChunkStream.listen((chunk) {
            if (chunk.requestId == reqId) {
              sink.add(chunk.data);
              received += chunk.data.length;
              if (meta.fileSize > 0) {
                onProgress?.call(received / meta.fileSize);
              }
            }
          });
        }
        if (event.isDone) {
          break;
        }
      }
    } finally {
      await binarySub?.cancel();
    }

    await sink.close();
  } catch (e) {
    await sink.close();
    try {
      await file.delete();
    } catch (_) {}
    rethrow;
  }

  // 4. 校验 SHA256
  final savedBytes = await File(savePath).readAsBytes();
  final actualHash = sha256.convert(savedBytes).toString();
  if (actualHash != meta.sha256) {
    await File(savePath).delete();
    throw Exception('文件校验失败: SHA256 不匹配');
  }

  return savePath;
}

// ============================================================
// Mock
// ============================================================

class FakeConnection implements DownloadConnection {
  @override
  bool isConnected = true;

  StreamController<RpcStreamEvent>? _streamController;
  final StreamController<BinaryChunkEvent> _binaryController =
      StreamController<BinaryChunkEvent>.broadcast();

  @override
  Stream<BinaryChunkEvent> get binaryChunkStream => _binaryController.stream;

  @override
  Stream<RpcStreamEvent> invokeRemoteStream(
    String toDeviceId,
    String method,
    Map<String, dynamic> params, {
    int timeout = 120000,
  }) {
    _streamController = StreamController<RpcStreamEvent>();
    return _streamController!.stream;
  }

  // ---- 测试控制 API ----

  void emitStreamEvent(RpcStreamEvent event) {
    _streamController?.add(event);
  }

  void closeStream() {
    _streamController?.close();
  }

  void pushBinaryChunk(BinaryChunkEvent chunk) {
    _binaryController.add(chunk);
  }

  void emitError(Object error) {
    _streamController?.addError(error);
  }

  void dispose() {
    _streamController?.close();
    _binaryController.close();
  }
}

// ============================================================
// 辅助工具
// ============================================================

FileMetaMessage makeMeta({
  required String fileName,
  required int fileSize,
  required String sha256Hash,
  required String filePath,
  String fromDeviceId = 'remote-device-001',
}) {
  return FileMetaMessage(
    fileId: 'file-${DateTime.now().millisecondsSinceEpoch}',
    fileName: fileName,
    fileSize: fileSize,
    sha256: sha256Hash,
    filePath: filePath,
    fromDeviceId: fromDeviceId,
  );
}

Uint8List sequentialBytes(int len) {
  final bytes = Uint8List(len);
  for (var i = 0; i < len; i++) {
    bytes[i] = i % 256;
  }
  return bytes;
}

// ============================================================
// 测试主体
// ============================================================

void main() {
  late FakeConnection conn;
  late Directory tempDir;

  setUp(() {
    conn = FakeConnection();
    tempDir = Directory.systemTemp.createTempSync('dl_method_test_');
  });

  tearDown(() async {
    conn.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  // ==============================================================
  group('downloadFileByMeta — 连接状态', () {
    // ==============================================================

    test('未连接时抛出 StateError', () {
      conn.isConnected = false;

      final meta = makeMeta(
        fileName: 'test.txt',
        fileSize: 100,
        sha256Hash: 'abc',
        filePath: '/remote/test.txt',
      );

      expect(
        () => downloadFileByMetaLogic(
          connMgr: conn,
          meta: meta,
          saveDir: tempDir.path,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ==============================================================
  group('downloadFileByMeta — 正常下载', () {
    // ==============================================================

    test('单 chunk 小文件', () async {
      final content = Uint8List.fromList([1, 2, 3, 4, 5]);
      final hash = sha256.convert(content).toString();
      final meta = makeMeta(
        fileName: 'small.dat',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '/remote/small.dat',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      // 等待 invokeRemoteStream 被调用
      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-001';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId,
        data: content,
        isLast: true,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done(
        {'fileSize': content.length, 'fileName': 'small.dat'},
        requestId: reqId,
      ));

      final savePath = await future;
      expect(savePath, endsWith('small.dat'));
      expect(File(savePath).existsSync(), isTrue);
      expect(File(savePath).readAsBytesSync(), equals(content));
    });

    test('多 chunk 大文件 (256KB / 4 chunks)', () async {
      final totalSize = 256 * 1024;
      final content = sequentialBytes(totalSize);
      final hash = sha256.convert(content).toString();
      final chunkSize = 64 * 1024;

      final meta = makeMeta(
        fileName: 'large.bin',
        fileSize: totalSize,
        sha256Hash: hash,
        filePath: '/remote/large.bin',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-002';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      for (var i = 0; i < 4; i++) {
        final start = i * chunkSize;
        final end = (i + 1) * chunkSize;
        conn.pushBinaryChunk(BinaryChunkEvent(
          requestId: reqId,
          data: Uint8List.fromList(content.sublist(start, end)),
          isLast: i == 3,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done(
        {'fileSize': totalSize, 'fileName': 'large.bin'},
        requestId: reqId,
      ));

      final savePath = await future;
      expect(File(savePath).existsSync(), isTrue);
      expect(File(savePath).readAsBytesSync(), equals(content));
    });

    test('空文件下载', () async {
      final content = Uint8List(0);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'empty.dat',
        fileSize: 0,
        sha256Hash: hash,
        filePath: '/remote/empty.dat',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-003';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      final savePath = await future;
      expect(File(savePath).existsSync(), isTrue);
      expect(File(savePath).readAsBytesSync(), isEmpty);
    });

    test('二进制文件（所有字节值 0-255）', () async {
      final content = Uint8List.fromList(List.generate(256, (i) => i));
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'all_bytes.bin',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '/remote/all_bytes.bin',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-004';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId,
        data: content,
        isLast: true,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      final savePath = await future;
      expect(File(savePath).readAsBytesSync(), equals(content));
    });
  });

  // ==============================================================
  group('downloadFileByMeta — SHA256 校验', () {
    // ==============================================================

    test('SHA256 不匹配 → 删除文件并抛异常', () async {
      final content = Uint8List.fromList([10, 20, 30]);
      const wrongHash = '0000000000000000000000000000000000000000000000000000000000000000';

      final meta = makeMeta(
        fileName: 'bad_hash.dat',
        fileSize: content.length,
        sha256Hash: wrongHash,
        filePath: '/remote/bad_hash.dat',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-010';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId,
        data: content,
        isLast: true,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      await expectLater(future, throwsA(isA<Exception>()));

      final savePath = '${tempDir.path}${Platform.pathSeparator}bad_hash.dat';
      expect(File(savePath).existsSync(), isFalse);
    });
  });

  // ==============================================================
  group('downloadFileByMeta — 错误处理', () {
    // ==============================================================

    test('RPC 流错误 → 清理临时文件', () async {
      final meta = makeMeta(
        fileName: 'error.dat',
        fileSize: 100,
        sha256Hash: 'abc',
        filePath: '/remote/error.dat',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-020';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId,
        data: Uint8List.fromList([1, 2, 3]),
        isLast: false,
      ));

      // 模拟 RPC 错误
      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitError(Exception('模拟 RPC 错误'));

      await expectLater(future, throwsA(isA<Exception>()));

      final savePath = '${tempDir.path}${Platform.pathSeparator}error.dat';
      expect(File(savePath).existsSync(), isFalse);
    });
  });

  // ==============================================================
  group('downloadFileByMeta — 进度回调', () {
    // ==============================================================

    test('进度回调正确报告', () async {
      final content = Uint8List.fromList(List.generate(100, (i) => i));
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'progress.dat',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '/remote/progress.dat',
      );

      final progresses = <double>[];

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
        onProgress: progresses.add,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-030';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));

      // 分两半发送
      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId,
        data: Uint8List.fromList(content.sublist(0, 50)),
        isLast: false,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId,
        data: Uint8List.fromList(content.sublist(50)),
        isLast: true,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      await future;

      expect(progresses, isNotEmpty);
      expect(progresses.first, closeTo(0.5, 0.01));
      expect(progresses.last, closeTo(1.0, 0.01));
    });

    test('fileSize 为 0 时不触发进度回调', () async {
      final content = Uint8List.fromList([7]);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'zero_size.dat',
        fileSize: 0,
        sha256Hash: hash,
        filePath: '/remote/zero_size.dat',
      );

      var progressCalled = false;

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
        onProgress: (_) => progressCalled = true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-031';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId,
        data: content,
        isLast: true,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      await future;
      expect(progressCalled, isFalse);
    });

    test('无进度回调时正常下载', () async {
      final content = Uint8List.fromList([8, 9, 10]);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'no_cb.dat',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '/remote/no_cb.dat',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-032';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId,
        data: content,
        isLast: true,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      final savePath = await future;
      expect(File(savePath).readAsBytesSync(), equals(content));
    });
  });

  // ==============================================================
  group('downloadFileByMeta — requestId 过滤', () {
    // ==============================================================

    test('不同 requestId 的 chunk 被过滤', () async {
      final content = Uint8List.fromList([42, 43, 44]);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'filter.dat',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '/remote/filter.dat',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-040';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));

      await Future<void>.delayed(const Duration(milliseconds: 5));

      // 推送无关 requestId 的 chunk（应被忽略）
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: 'wrong-req-id',
        data: Uint8List.fromList([99, 98, 97]),
        isLast: false,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 5));

      // 推送正确的 chunk
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId,
        data: content,
        isLast: true,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      final savePath = await future;
      final saved = File(savePath).readAsBytesSync();
      expect(saved, equals(content));
      expect(saved, isNot(contains(99)));
    });
  });

  // ==============================================================
  group('downloadFileByMeta — 路径', () {
    // ==============================================================

    test('保存路径在 saveDir 下且文件名正确', () async {
      final content = Uint8List.fromList([1]);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'path_test.txt',
        fileSize: 1,
        sha256Hash: hash,
        filePath: '/remote/path_test.txt',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-050';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId,
        data: content,
        isLast: true,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      final savePath = await future;
      expect(savePath, startsWith(tempDir.path));
      expect(savePath, endsWith('path_test.txt'));
    });
  });
}
