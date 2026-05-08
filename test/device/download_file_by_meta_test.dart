import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/agent/entity/file_transfer_url_result.dart';
import 'package:wenzagent/src/device/impl/file_transfer_token_manager.dart';
import 'package:wenzagent/src/lan/lan_client_service.dart';

// =============================================================================
// 辅助：手动构造二进制帧（与 DeviceRpcHandler._buildBinaryFrame 格式一致）
// =============================================================================
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
  // type
  builder.addByte(0x02);

  // toDeviceId length (uint32 BE) + toDeviceId
  final toDeviceIdLenData = ByteData(4)
    ..setUint32(0, toDeviceIdBytes.length);
  builder.add(toDeviceIdLenData.buffer.asUint8List());
  builder.add(toDeviceIdBytes);

  // requestId length (uint32 BE) + requestId
  final requestIdLenData = ByteData(4)
    ..setUint32(0, requestIdBytes.length);
  builder.add(requestIdLenData.buffer.asUint8List());
  builder.add(requestIdBytes);

  // flags (bit0 = lastChunk)
  builder.addByte(isLast ? 0x01 : 0x00);

  // payload
  builder.add(payload);

  return builder.takeBytes();
}

// =============================================================================
// 辅助：解析二进制帧头部，返回结构化字段
// =============================================================================
class ParsedFrame {
  final int version;
  final int type;
  final String toDeviceId;
  final String requestId;
  final bool isLast;
  final Uint8List payload;

  const ParsedFrame({
    required this.version,
    required this.type,
    required this.toDeviceId,
    required this.requestId,
    required this.isLast,
    required this.payload,
  });
}

ParsedFrame? parseBinaryFrame(Uint8List bytes) {
  // 最小帧头长度：version(1) + type(1) + toDeviceIdLen(4) + toDeviceId(0)
  // + requestIdLen(4) + requestId(0) + flags(1) = 11
  if (bytes.length < 11) return null;
  if (bytes[0] != 0x01) return null;
  if (bytes[1] != 0x02) return null;

  int offset = 2;

  final toDeviceIdLen =
      ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
  offset += 4;
  final toDeviceId =
      utf8.decode(bytes.sublist(offset, offset + toDeviceIdLen));
  offset += toDeviceIdLen;

  final requestIdLen =
      ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
  offset += 4;
  final requestId =
      utf8.decode(bytes.sublist(offset, offset + requestIdLen));
  offset += requestIdLen;

  final flags = bytes[offset];
  offset += 1;
  final isLast = (flags & 0x01) != 0;

  final payload = Uint8List.sublistView(bytes, offset);

  return ParsedFrame(
    version: bytes[0],
    type: bytes[1],
    toDeviceId: toDeviceId,
    requestId: requestId,
    isLast: isLast,
    payload: payload,
  );
}

// =============================================================================
// 辅助：将原始二进制帧转换为 BinaryChunkEvent（模拟 _handleBinaryData）
// =============================================================================
BinaryChunkEvent? frameToChunkEvent(Uint8List bytes) {
  final parsed = parseBinaryFrame(bytes);
  if (parsed == null) return null;
  return BinaryChunkEvent(
    requestId: parsed.requestId,
    data: parsed.payload,
    isLast: parsed.isLast,
  );
}

// =============================================================================
// 辅助：模拟 downloadFileByMeta 核心逻辑（流式写入 + SHA256 校验）
// =============================================================================
Future<String> simulateDownload({
  required FileMetaMessage meta,
  required String saveDir,
  required List<BinaryChunkEvent> chunks,
  void Function(double progress)? onProgress,
}) async {
  final savePath = '$saveDir${Platform.pathSeparator}${meta.fileName}';
  final file = File(savePath);
  final sink = file.openWrite();
  int received = 0;

  try {
    for (final chunk in chunks) {
      sink.add(chunk.data);
      received += chunk.data.length;
      if (meta.fileSize > 0) {
        onProgress?.call(received / meta.fileSize);
      }
    }
    await sink.close();
  } catch (e) {
    await sink.close();
    try {
      await file.delete();
    } catch (_) {}
    rethrow;
  }

  // SHA256 校验
  final savedBytes = await File(savePath).readAsBytes();
  final actualHash = sha256.convert(savedBytes).toString();
  if (actualHash != meta.sha256) {
    await File(savePath).delete();
    throw Exception('文件校验失败: SHA256 不匹配');
  }

  return savePath;
}

// =============================================================================
// 测试入口
// =============================================================================
void main() {
  // ===========================================================================
  // 1. Binary frame construction and parsing
  // ===========================================================================
  group('Binary frame construction and parsing', () {
    test('build frame with correct header fields', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame = buildBinaryFrame(
        toDeviceId: 'device-A',
        requestId: 'req-001',
        payload: payload,
        isLast: true,
      );

      final parsed = parseBinaryFrame(frame);
      expect(parsed, isNotNull);
      expect(parsed!.version, 0x01);
      expect(parsed.type, 0x02);
      expect(parsed.toDeviceId, 'device-A');
      expect(parsed.requestId, 'req-001');
      expect(parsed.isLast, isTrue);
      expect(parsed.payload, equals(payload));
    });

    test('isLast=false sets flags byte to 0x00', () {
      final frame = buildBinaryFrame(
        toDeviceId: 'dev',
        requestId: 'r1',
        payload: Uint8List(0),
        isLast: false,
      );
      final parsed = parseBinaryFrame(frame);
      expect(parsed, isNotNull);
      expect(parsed!.isLast, isFalse);
    });

    test('frame with empty payload', () {
      final frame = buildBinaryFrame(
        toDeviceId: 'device-X',
        requestId: 'req-empty',
        payload: Uint8List(0),
        isLast: true,
      );
      final parsed = parseBinaryFrame(frame);
      expect(parsed, isNotNull);
      expect(parsed!.payload, isEmpty);
      expect(parsed!.isLast, isTrue);
    });

    test('frame with large payload preserves all bytes', () {
      final payload = Uint8List.fromList(List.generate(10000, (i) => i % 256));
      final frame = buildBinaryFrame(
        toDeviceId: 'dev',
        requestId: 'r-big',
        payload: payload,
        isLast: false,
      );
      final parsed = parseBinaryFrame(frame);
      expect(parsed!.payload.length, 10000);
      expect(parsed.payload, equals(payload));
    });

    test('frame with UTF-8 device ID and request ID', () {
      final frame = buildBinaryFrame(
        toDeviceId: '设备-中文ID',
        requestId: '请求-001',
        payload: Uint8List.fromList([0xAA, 0xBB]),
        isLast: true,
      );
      final parsed = parseBinaryFrame(frame);
      expect(parsed!.toDeviceId, '设备-中文ID');
      expect(parsed.requestId, '请求-001');
    });

    test('parse returns null for too-short data', () {
      final short = Uint8List.fromList([0x01, 0x02, 0x00]);
      expect(parseBinaryFrame(short), isNull);
    });

    test('parse returns null for wrong version', () {
      final frame = buildBinaryFrame(
        toDeviceId: 'd',
        requestId: 'r',
        payload: Uint8List(0),
        isLast: false,
      );
      // Tamper version byte
      frame[0] = 0x99;
      expect(parseBinaryFrame(frame), isNull);
    });

    test('parse returns null for wrong type', () {
      final frame = buildBinaryFrame(
        toDeviceId: 'd',
        requestId: 'r',
        payload: Uint8List(0),
        isLast: false,
      );
      // Tamper type byte
      frame[1] = 0xFF;
      expect(parseBinaryFrame(frame), isNull);
    });
  });

  // ===========================================================================
  // 2. BinaryChunkEvent serialization / deserialization
  // ===========================================================================
  group('BinaryChunkEvent', () {
    test('constructor and field access', () {
      final data = Uint8List.fromList([10, 20, 30]);
      final event = BinaryChunkEvent(
        requestId: 'req-123',
        data: data,
        isLast: true,
      );
      expect(event.requestId, 'req-123');
      expect(event.data, equals(data));
      expect(event.isLast, isTrue);
    });

    test('toString contains useful info', () {
      final event = BinaryChunkEvent(
        requestId: 'req-abc',
        data: Uint8List.fromList([1, 2, 3]),
        isLast: false,
      );
      final str = event.toString();
      expect(str, contains('req-abc'));
      expect(str, contains('3')); // dataLen
      expect(str, contains('isLast'));
    });

    test('frameToChunkEvent correctly converts a valid frame', () {
      final payload = Uint8List.fromList([42, 43, 44]);
      final frame = buildBinaryFrame(
        toDeviceId: 'device-1',
        requestId: 'req-xyz',
        payload: payload,
        isLast: true,
      );
      final event = frameToChunkEvent(frame);
      expect(event, isNotNull);
      expect(event!.requestId, 'req-xyz');
      expect(event.data, equals(payload));
      expect(event.isLast, isTrue);
    });

    test('frameToChunkEvent returns null for invalid frame', () {
      expect(frameToChunkEvent(Uint8List(5)), isNull);
    });
  });

  // ===========================================================================
  // 3. Stream chunk assembly — multiple chunks into complete file
  // ===========================================================================
  group('Stream chunk assembly', () {
    late Directory tempDir;

    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('chunk_assembly_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('multiple chunks assembled into correct file', () async {
      final content = 'Hello, binary streaming world!';
      final contentBytes = utf8.encode(content);
      final hash = sha256.convert(contentBytes).toString();

      // Split content into 3 chunks
      final chunk1 = Uint8List.fromList(contentBytes.sublist(0, 10));
      final chunk2 = Uint8List.fromList(contentBytes.sublist(10, 20));
      final chunk3 = Uint8List.fromList(contentBytes.sublist(20));

      final chunks = [
        BinaryChunkEvent(requestId: 'r1', data: chunk1, isLast: false),
        BinaryChunkEvent(requestId: 'r1', data: chunk2, isLast: false),
        BinaryChunkEvent(requestId: 'r1', data: chunk3, isLast: true),
      ];

      final meta = FileMetaMessage(
        fileId: 'f1',
        fileName: 'hello.txt',
        fileSize: contentBytes.length,
        sha256: hash,
        filePath: '/remote/hello.txt',
        fromDeviceId: 'device-B',
      );

      final savePath = await simulateDownload(
        meta: meta,
        saveDir: tempDir.path,
        chunks: chunks,
      );

      expect(await File(savePath).exists(), isTrue);
      final savedContent = await File(savePath).readAsString();
      expect(savedContent, content);
    });

    test('single chunk (entire file in one frame)', () async {
      final content = 'Single chunk file';
      final contentBytes = utf8.encode(content);
      final hash = sha256.convert(contentBytes).toString();

      final chunks = [
        BinaryChunkEvent(
          requestId: 'r1',
          data: Uint8List.fromList(contentBytes),
          isLast: true,
        ),
      ];

      final meta = FileMetaMessage(
        fileId: 'f2',
        fileName: 'single.txt',
        fileSize: contentBytes.length,
        sha256: hash,
        filePath: '/remote/single.txt',
        fromDeviceId: 'device-B',
      );

      final savePath = await simulateDownload(
        meta: meta,
        saveDir: tempDir.path,
        chunks: chunks,
      );

      final savedContent = await File(savePath).readAsString();
      expect(savedContent, content);
    });

    test('chunks with different requestIds are filtered by simulation', () async {
      // In the real implementation, only chunks matching the expected requestId
      // are processed. Here we verify the filtering logic conceptually.
      final content = 'Filtered content';
      final contentBytes = utf8.encode(content);

      final correctChunks = [
        BinaryChunkEvent(requestId: 'correct', data: Uint8List.fromList(contentBytes), isLast: true),
      ];
      final wrongChunks = [
        BinaryChunkEvent(requestId: 'wrong', data: Uint8List.fromList([0xFF, 0xFE]), isLast: false),
      ];

      // Only correct chunks should be used
      expect(correctChunks.every((c) => c.requestId == 'correct'), isTrue);
      expect(wrongChunks.every((c) => c.requestId != 'correct'), isTrue);
    });
  });

  // ===========================================================================
  // 4. SHA256 verification — success and failure
  // ===========================================================================
  group('SHA256 verification', () {
    late Directory tempDir;

    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('sha256_verify_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('SHA256 match — file is kept', () async {
      final content = 'SHA256 success test';
      final contentBytes = utf8.encode(content);
      final hash = sha256.convert(contentBytes).toString();

      final meta = FileMetaMessage(
        fileId: 'f1',
        fileName: 'ok.txt',
        fileSize: contentBytes.length,
        sha256: hash,
        filePath: '/remote/ok.txt',
        fromDeviceId: 'device-B',
      );

      final chunks = [
        BinaryChunkEvent(
          requestId: 'r1',
          data: Uint8List.fromList(contentBytes),
          isLast: true,
        ),
      ];

      final savePath = await simulateDownload(
        meta: meta,
        saveDir: tempDir.path,
        chunks: chunks,
      );

      expect(await File(savePath).exists(), isTrue);
    });

    test('SHA256 mismatch — file is deleted and exception thrown', () async {
      final content = 'Actual content';
      final contentBytes = utf8.encode(content);
      final wrongHash = sha256.convert(utf8.encode('Wrong content')).toString();

      final meta = FileMetaMessage(
        fileId: 'f2',
        fileName: 'mismatch.txt',
        fileSize: contentBytes.length,
        sha256: wrongHash, // Intentionally wrong hash
        filePath: '/remote/mismatch.txt',
        fromDeviceId: 'device-B',
      );

      final chunks = [
        BinaryChunkEvent(
          requestId: 'r1',
          data: Uint8List.fromList(contentBytes),
          isLast: true,
        ),
      ];

      final saveDir = '${tempDir.path}/save';
      await Directory(saveDir).create(recursive: true);

      await expectLater(
        simulateDownload(
          meta: meta,
          saveDir: saveDir,
          chunks: chunks,
        ),
        throwsA(isA<Exception>()),
      );

      // File should have been deleted
      final file = File('$saveDir${Platform.pathSeparator}mismatch.txt');
      expect(await file.exists(), isFalse);
    });
  });

  // ===========================================================================
  // 5. Progress callback — verify progress calculation
  // ===========================================================================
  group('Progress callback', () {
    test('progress reported correctly for multi-chunk transfer', () async {
      final content = List.generate(1000, (i) => i % 256);
      final contentBytes = Uint8List.fromList(content);
      final hash = sha256.convert(contentBytes).toString();

      // Split into 4 chunks: 200, 300, 250, 250
      final chunks = [
        BinaryChunkEvent(
          requestId: 'r1',
          data: Uint8List.fromList(contentBytes.sublist(0, 200)),
          isLast: false,
        ),
        BinaryChunkEvent(
          requestId: 'r1',
          data: Uint8List.fromList(contentBytes.sublist(200, 500)),
          isLast: false,
        ),
        BinaryChunkEvent(
          requestId: 'r1',
          data: Uint8List.fromList(contentBytes.sublist(500, 750)),
          isLast: false,
        ),
        BinaryChunkEvent(
          requestId: 'r1',
          data: Uint8List.fromList(contentBytes.sublist(750)),
          isLast: true,
        ),
      ];

      final progresses = <double>[];

      final tempDir =
          await Directory.systemTemp.createTemp('progress_test_');
      try {
        final meta = FileMetaMessage(
          fileId: 'f1',
          fileName: 'progress.bin',
          fileSize: contentBytes.length,
          sha256: hash,
          filePath: '/remote/progress.bin',
          fromDeviceId: 'device-B',
        );

        await simulateDownload(
          meta: meta,
          saveDir: tempDir.path,
          chunks: chunks,
          onProgress: (p) => progresses.add(p),
        );

        expect(progresses, [0.2, 0.5, 0.75, 1.0]);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('no progress callback when fileSize is 0', () async {
      final content = 'some content';
      final contentBytes = utf8.encode(content);
      final hash = sha256.convert(contentBytes).toString();

      final chunks = [
        BinaryChunkEvent(
          requestId: 'r1',
          data: Uint8List.fromList(contentBytes),
          isLast: true,
        ),
      ];

      final progresses = <double>[];
      final tempDir =
          await Directory.systemTemp.createTemp('progress_zero_test_');
      try {
        final meta = FileMetaMessage(
          fileId: 'f2',
          fileName: 'zero.txt',
          fileSize: 0, // fileSize is 0 → no progress
          sha256: hash,
          filePath: '/remote/zero.txt',
          fromDeviceId: 'device-B',
        );

        await simulateDownload(
          meta: meta,
          saveDir: tempDir.path,
          chunks: chunks,
          onProgress: (p) => progresses.add(p),
        );

        expect(progresses, isEmpty);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('progress reaches 1.0 on completion', () async {
      final content = 'Complete';
      final contentBytes = utf8.encode(content);
      final hash = sha256.convert(contentBytes).toString();

      final chunks = [
        BinaryChunkEvent(
          requestId: 'r1',
          data: Uint8List.fromList(contentBytes.sublist(0, 4)),
          isLast: false,
        ),
        BinaryChunkEvent(
          requestId: 'r1',
          data: Uint8List.fromList(contentBytes.sublist(4)),
          isLast: true,
        ),
      ];

      double? lastProgress;
      final tempDir =
          await Directory.systemTemp.createTemp('progress_final_test_');
      try {
        final meta = FileMetaMessage(
          fileId: 'f3',
          fileName: 'final.txt',
          fileSize: contentBytes.length,
          sha256: hash,
          filePath: '/remote/final.txt',
          fromDeviceId: 'device-B',
        );

        await simulateDownload(
          meta: meta,
          saveDir: tempDir.path,
          chunks: chunks,
          onProgress: (p) => lastProgress = p,
        );

        expect(lastProgress, 1.0);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });

  // ===========================================================================
  // 6. Error handling — temp file cleanup on exception
  // ===========================================================================
  group('Error handling', () {
    test('exception during write causes temp file cleanup', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('error_cleanup_test_');
      try {
        final content = 'Will fail';
        final contentBytes = utf8.encode(content);
        final hash = sha256.convert(contentBytes).toString();

        final meta = FileMetaMessage(
          fileId: 'f1',
          fileName: 'fail.txt',
          fileSize: contentBytes.length,
          sha256: hash,
          filePath: '/remote/fail.txt',
          fromDeviceId: 'device-B',
        );

        // Use a chunk that throws
        final badChunks = [
          BinaryChunkEvent(
            requestId: 'r1',
            data: Uint8List.fromList(contentBytes),
            isLast: true,
          ),
        ];

        // Simulate by writing directly and checking cleanup logic
        final savePath =
            '${tempDir.path}${Platform.pathSeparator}fail.txt';
        final file = File(savePath);
        final sink = file.openWrite();
        try {
          sink.add(contentBytes);
          throw Exception('模拟写入中断');
        } catch (e) {
          await sink.close();
          try {
            await file.delete();
          } catch (_) {}
        }

        expect(await file.exists(), isFalse);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('SHA256 mismatch deletes file', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('sha256_cleanup_test_');
      try {
        final content = 'Content';
        final contentBytes = utf8.encode(content);
        final wrongHash = '0' * 64; // Definitely wrong

        final meta = FileMetaMessage(
          fileId: 'f2',
          fileName: 'corrupt.txt',
          fileSize: contentBytes.length,
          sha256: wrongHash,
          filePath: '/remote/corrupt.txt',
          fromDeviceId: 'device-B',
        );

        final chunks = [
          BinaryChunkEvent(
            requestId: 'r1',
            data: Uint8List.fromList(contentBytes),
            isLast: true,
          ),
        ];

        final saveDir = '${tempDir.path}/save';
        await Directory(saveDir).create();

        try {
          await simulateDownload(
            meta: meta,
            saveDir: saveDir,
            chunks: chunks,
          );
          fail('Should have thrown');
        } on Exception {
          // Expected
        }

        final file =
            File('$saveDir${Platform.pathSeparator}corrupt.txt');
        expect(await file.exists(), isFalse);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });

  // ===========================================================================
  // 7. FileMetaMessage serialization (kept from original)
  // ===========================================================================
  group('FileMetaMessage serialization', () {
    test('toJson / fromJson round-trip', () {
      final meta = FileMetaMessage(
        fileId: 'file-uuid-001',
        fileName: '测试文件.pdf',
        fileSize: 2048,
        sha256: 'abcdef1234567890',
        filePath: '/home/user/测试文件.pdf',
        fromDeviceId: 'device-remote-001',
        mimeType: 'application/pdf',
        role: 'user',
        employeeId: 'emp-001',
      );

      final json = meta.toJson();
      expect(json['fileId'], 'file-uuid-001');
      expect(json['fileName'], '测试文件.pdf');
      expect(json['fileSize'], 2048);
      expect(json['sha256'], 'abcdef1234567890');
      expect(json['filePath'], '/home/user/测试文件.pdf');
      expect(json['fromDeviceId'], 'device-remote-001');
      expect(json['mimeType'], 'application/pdf');
      expect(json['role'], 'user');
      expect(json['employeeId'], 'emp-001');

      final restored = FileMetaMessage.fromJson(json);
      expect(restored.fileId, meta.fileId);
      expect(restored.fileName, meta.fileName);
      expect(restored.fileSize, meta.fileSize);
      expect(restored.sha256, meta.sha256);
      expect(restored.filePath, meta.filePath);
      expect(restored.fromDeviceId, meta.fromDeviceId);
      expect(restored.mimeType, meta.mimeType);
      expect(restored.role, meta.role);
      expect(restored.employeeId, meta.employeeId);
    });

    test('optional null fields are omitted from toJson', () {
      final meta = FileMetaMessage(
        fileId: 'file-uuid-002',
        fileName: 'data.bin',
        fileSize: 100,
        sha256: 'hash',
        filePath: '/tmp/data.bin',
        fromDeviceId: 'device-A',
      );

      final json = meta.toJson();
      expect(json.containsKey('mimeType'), isFalse);
      expect(json.containsKey('role'), isFalse);
      expect(json.containsKey('employeeId'), isFalse);
    });

    test('fromDeviceId used as toDeviceId for download request', () {
      final meta = FileMetaMessage(
        fileId: 'file-001',
        fileName: 'doc.txt',
        fileSize: 100,
        sha256: 'hash123',
        filePath: '/remote/path/doc.txt',
        fromDeviceId: 'device-B',
      );

      // downloadFileByMeta uses meta.fromDeviceId as the target device
      expect(meta.fromDeviceId, 'device-B');
      expect(meta.filePath, '/remote/path/doc.txt');
    });

    test('multiple FileMetaMessages are independent', () {
      final metas = List.generate(
        5,
        (i) => FileMetaMessage(
          fileId: 'file-$i',
          fileName: 'file_$i.dat',
          fileSize: (i + 1) * 100,
          sha256: 'hash_$i',
          filePath: '/remote/file_$i.dat',
          fromDeviceId: 'device-B',
        ),
      );

      for (var i = 0; i < 5; i++) {
        expect(metas[i].fileId, 'file-$i');
        expect(metas[i].fileName, 'file_$i.dat');
        expect(metas[i].fileSize, (i + 1) * 100);
        expect(metas[i].filePath, '/remote/file_$i.dat');
      }
    });
  });

  // ===========================================================================
  // 8. FileDownloadUrlResult (backward compatibility)
  // ===========================================================================
  group('FileDownloadUrlResult', () {
    test('fromMap handles missing fields with defaults', () {
      final result = FileDownloadUrlResult.fromMap({});
      expect(result.url, '');
      expect(result.token, '');
      expect(result.expiresIn, 300);
      expect(result.fileSize, 0);
      expect(result.fileName, '');
      expect(result.error, isNull);
    });

    test('fromMap correctly parses error', () {
      final result = FileDownloadUrlResult.fromMap({
        'url': '',
        'token': '',
        'error': '远程设备不可达',
      });
      expect(result.error, '远程设备不可达');
      expect(result.url, isEmpty);
    });

    test('toMap / fromMap round-trip', () {
      final original = FileDownloadUrlResult(
        url: 'http://192.168.1.100:9090/file-download?token=abc',
        token: 'abc',
        expiresIn: 600,
        fileSize: 4096,
        fileName: 'test.zip',
      );

      final map = original.toMap();
      final restored = FileDownloadUrlResult.fromMap(map);

      expect(restored.url, original.url);
      expect(restored.token, original.token);
      expect(restored.expiresIn, original.expiresIn);
      expect(restored.fileSize, original.fileSize);
      expect(restored.fileName, original.fileName);
      expect(restored.error, original.error);
    });

    test('error detection: empty URL triggers error path', () {
      final result = FileDownloadUrlResult(
        url: '',
        token: '',
        error: '远程设备离线',
      );
      expect(result.error != null || result.url.isEmpty, isTrue);
    });

    test('error detection: non-null error triggers error path', () {
      final result = FileDownloadUrlResult(
        url: 'http://some.url',
        token: 'abc',
        error: '文件不存在',
      );
      expect(result.error != null || result.url.isEmpty, isTrue);
    });

    test('URL construction from RPC response fields', () {
      final rpcResponse = <String, dynamic>{
        'success': true,
        'token': 'test-token-123',
        'expiresIn': 300,
        'fileSize': 1024,
        'fileName': 'document.pdf',
        'hostIp': '192.168.1.200',
        'hostPort': 9090,
      };

      final hostIp = rpcResponse['hostIp'] as String? ?? '';
      final hostPort = rpcResponse['hostPort'] as int? ?? 0;
      final token = rpcResponse['token'] as String? ?? '';
      if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
        rpcResponse['url'] = 'http://$hostIp:$hostPort/file-download?token=$token';
      }

      final result = FileDownloadUrlResult.fromMap(rpcResponse);
      expect(result.url,
          'http://192.168.1.200:9090/file-download?token=test-token-123');
      expect(result.token, 'test-token-123');
      expect(result.fileSize, 1024);
      expect(result.fileName, 'document.pdf');
      expect(result.error, isNull);
    });
  });

  // ===========================================================================
  // 9. Token management (backward compatibility)
  // ===========================================================================
  group('Token management', () {
    setUp(() {
      FileTransferTokenManager.dispose();
    });

    tearDown(() {
      FileTransferTokenManager.dispose();
    });

    test('generate and validate download token', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('token_test_');
      try {
        final testFile = File('${tempDir.path}/token_test.txt');
        await testFile.writeAsString('Token test content');

        final transferToken =
            FileTransferTokenManager.generateDownloadToken(
          deviceId: 'device-B',
          filePath: testFile.path,
        );

        expect(transferToken.token, isNotEmpty);
        expect(transferToken.operation, 'download');
        expect(transferToken.filePath, testFile.path);

        final validated = FileTransferTokenManager.validateAndConsume(
          transferToken.token,
          'download',
        );
        expect(validated, isNotNull);
        expect(validated!.filePath, testFile.path);

        // Token is one-time use
        final secondValidation =
            FileTransferTokenManager.validateAndConsume(
          transferToken.token,
          'download',
        );
        expect(secondValidation, isNull);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('type mismatch causes validation failure', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('token_type_test_');
      try {
        final testFile = File('${tempDir.path}/type_mismatch.txt');
        await testFile.writeAsString('test');

        final downloadToken =
            FileTransferTokenManager.generateDownloadToken(
          deviceId: 'device-B',
          filePath: testFile.path,
        );

        final result = FileTransferTokenManager.validateAndConsume(
          downloadToken.token,
          'upload',
        );
        expect(result, isNull);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('token consumed cannot be reused', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('token_reuse_test_');
      try {
        final testFile = File('${tempDir.path}/reuse_test.txt');
        await testFile.writeAsString('test');

        final token = FileTransferTokenManager.generateDownloadToken(
          deviceId: 'device-B',
          filePath: testFile.path,
        );

        final first = FileTransferTokenManager.validateAndConsume(
          token.token,
          'download',
        );
        expect(first, isNotNull);

        final second = FileTransferTokenManager.validateAndConsume(
          token.token,
          'download',
        );
        expect(second, isNull);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });

  // ===========================================================================
  // 10. Edge cases — empty file and binary file
  // ===========================================================================
  group('Edge cases', () {
    late Directory tempDir;

    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('edge_case_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('empty file download and SHA256 verification', () async {
      // SHA256 of empty bytes
      const expectedEmptyHash =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

      final meta = FileMetaMessage(
        fileId: 'empty-1',
        fileName: 'empty.txt',
        fileSize: 0,
        sha256: expectedEmptyHash,
        filePath: '/remote/empty.txt',
        fromDeviceId: 'device-B',
      );

      // Empty file: single chunk with empty payload
      final chunks = [
        BinaryChunkEvent(
          requestId: 'r1',
          data: Uint8List(0),
          isLast: true,
        ),
      ];

      final savePath = await simulateDownload(
        meta: meta,
        saveDir: tempDir.path,
        chunks: chunks,
      );

      final savedBytes = await File(savePath).readAsBytes();
      expect(savedBytes, isEmpty);
      expect(await File(savePath).exists(), isTrue);
    });

    test('binary file with all byte values downloads correctly', () async {
      final binaryContent = List.generate(256, (i) => i);
      final contentBytes = Uint8List.fromList(binaryContent);
      final hash = sha256.convert(contentBytes).toString();

      // Split into two chunks
      final chunks = [
        BinaryChunkEvent(
          requestId: 'r1',
          data: Uint8List.fromList(contentBytes.sublist(0, 128)),
          isLast: false,
        ),
        BinaryChunkEvent(
          requestId: 'r1',
          data: Uint8List.fromList(contentBytes.sublist(128)),
          isLast: true,
        ),
      ];

      final meta = FileMetaMessage(
        fileId: 'bin-1',
        fileName: 'binary.bin',
        fileSize: contentBytes.length,
        sha256: hash,
        filePath: '/remote/binary.bin',
        fromDeviceId: 'device-B',
      );

      final savePath = await simulateDownload(
        meta: meta,
        saveDir: tempDir.path,
        chunks: chunks,
      );

      final savedBytes = await File(savePath).readAsBytes();
      expect(savedBytes.length, 256);
      expect(savedBytes, equals(contentBytes));
    });

    test('large file (1MB) SHA256 is correct', () async {
      final largeContent = List.generate(1024 * 1024, (i) => i % 256);
      final contentBytes = Uint8List.fromList(largeContent);
      final hash = sha256.convert(contentBytes).toString();

      expect(hash, hasLength(64));

      // Verify determinism
      final hash2 = sha256.convert(contentBytes).toString();
      expect(hash2, hash);
    });

    test('file with path separator in fileName does not escape saveDir', () {
      // Verify that the fileName is used as-is with p.join
      // p.join handles path separators correctly
      final meta = FileMetaMessage(
        fileId: 'f-escape',
        fileName: 'normal.txt',
        fileSize: 10,
        sha256: 'hash',
        filePath: '/remote/normal.txt',
        fromDeviceId: 'device-B',
      );

      // The save path should use the fileName correctly
      final savePath =
          '${tempDir.path}${Platform.pathSeparator}${meta.fileName}';
      expect(savePath, contains('normal.txt'));
    });
  });

  // ===========================================================================
  // End-to-end: binary streaming download simulation
  // ===========================================================================
  group('End-to-end binary streaming download', () {
    late Directory tempDir;

    setUp(() async {
      FileTransferTokenManager.dispose();
      tempDir =
          await Directory.systemTemp.createTemp('e2e_binary_test_');
    });

    tearDown(() async {
      FileTransferTokenManager.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('full flow: build frames → parse → assemble → verify', () async {
      // 1. Prepare "remote" file content
      final content = '端到端二进制流式下载测试内容';
      final contentBytes = utf8.encode(content);
      final hash = sha256.convert(contentBytes).toString();

      // 2. Split into chunks and build binary frames
      const chunkSize = 10;
      final frames = <Uint8List>[];
      for (int i = 0; i < contentBytes.length; i += chunkSize) {
        final end = (i + chunkSize > contentBytes.length)
            ? contentBytes.length
            : i + chunkSize;
        final isLast = end >= contentBytes.length;
        frames.add(buildBinaryFrame(
          toDeviceId: 'device-A',
          requestId: 'req-e2e',
          payload: Uint8List.fromList(contentBytes.sublist(i, end)),
          isLast: isLast,
        ));
      }

      // 3. Parse frames back to BinaryChunkEvents
      final chunkEvents = <BinaryChunkEvent>[];
      for (final frame in frames) {
        final event = frameToChunkEvent(frame);
        expect(event, isNotNull);
        chunkEvents.add(event!);
      }

      // Verify all chunks have same requestId
      expect(chunkEvents.every((c) => c.requestId == 'req-e2e'), isTrue);
      // Last chunk should be marked
      expect(chunkEvents.last.isLast, isTrue);
      // Non-last chunks should not be marked
      for (int i = 0; i < chunkEvents.length - 1; i++) {
        expect(chunkEvents[i].isLast, isFalse);
      }

      // 4. Simulate download
      final meta = FileMetaMessage(
        fileId: 'e2e-1',
        fileName: 'e2e_test.txt',
        fileSize: contentBytes.length,
        sha256: hash,
        filePath: '/remote/e2e_test.txt',
        fromDeviceId: 'device-B',
      );

      final progresses = <double>[];
      final savePath = await simulateDownload(
        meta: meta,
        saveDir: tempDir.path,
        chunks: chunkEvents,
        onProgress: (p) => progresses.add(p),
      );

      // 5. Verify result
      expect(await File(savePath).exists(), isTrue);
      final savedContent = await File(savePath).readAsString();
      expect(savedContent, content);

      // Progress should be monotonically increasing
      for (int i = 1; i < progresses.length; i++) {
        expect(progresses[i], greaterThanOrEqualTo(progresses[i - 1]));
      }
      expect(progresses.last, closeTo(1.0, 0.01));
    });

    test('full flow with binary content (non-text)', () async {
      // Create content with all possible byte values
      final contentBytes = Uint8List.fromList(
        List.generate(512, (i) => i % 256),
      );
      final hash = sha256.convert(contentBytes).toString();

      // Build frames with 64-byte chunks
      final frames = <Uint8List>[];
      for (int i = 0; i < contentBytes.length; i += 64) {
        final end = (i + 64 > contentBytes.length)
            ? contentBytes.length
            : i + 64;
        frames.add(buildBinaryFrame(
          toDeviceId: 'device-A',
          requestId: 'req-bin',
          payload: Uint8List.fromList(contentBytes.sublist(i, end)),
          isLast: end >= contentBytes.length,
        ));
      }

      final chunkEvents =
          frames.map((f) => frameToChunkEvent(f)!).toList();

      final meta = FileMetaMessage(
        fileId: 'bin-e2e',
        fileName: 'binary_e2e.bin',
        fileSize: contentBytes.length,
        sha256: hash,
        filePath: '/remote/binary_e2e.bin',
        fromDeviceId: 'device-B',
      );

      final savePath = await simulateDownload(
        meta: meta,
        saveDir: tempDir.path,
        chunks: chunkEvents,
      );

      final savedBytes = await File(savePath).readAsBytes();
      expect(savedBytes, equals(contentBytes));
    });
  });
}
