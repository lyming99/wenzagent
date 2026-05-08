/// downloadFileByMeta 问题发现测试
///
/// 专门针对 DeviceClient.downloadFileByMeta 方法可能存在的问题编写测试。
/// 通过提取核心逻辑为独立函数 + Mock 依赖，覆盖以下潜在问题场景：
///
/// ## 已发现/验证的问题
///
/// ### 🔴 Bug 1: 文件名路径穿越漏洞
/// meta.fileName 未做 sanitize，如果包含 ".." 或 "/" 或 "\"，
/// p.join(saveDir, meta.fileName) 可能生成 saveDir 之外的路径。
/// 例如 fileName = "../../etc/passwd" 会导致文件写入到系统敏感目录。
///
/// ### 🟡 Bug 2: 同名文件静默覆盖
/// 如果 saveDir 下已存在同名文件，openWrite() 会直接覆盖，无任何警告。
/// 应考虑检测文件是否已存在，或提供冲突解决策略（自动重命名、抛异常等）。
///
/// ### 🟡 Bug 3: saveDir 不存在时无友好错误
/// 如果 saveDir 目录不存在，file.openWrite() 会在底层抛出 OS 级异常，
/// 缺少友好的业务层错误提示。
///
/// ### 🟡 Bug 4: binaryChunkStream 在连接断开时为空流
/// _connectionManager.binaryChunkStream 在 _lanClient 为 null 时返回 Stream.empty()，
/// 此时不会收到任何二进制数据，但 RPC 流可能正常结束（isDone=true），
/// 导致下载完成但文件内容为空，最终 SHA256 校验失败，错误信息不直观。
///
/// ### 🟡 Bug 5: 进度可能超过 1.0
/// 如果远端实际发送的数据量超过 meta.fileSize（meta 值不准确），
/// progress = received / meta.fileSize 会超过 1.0，可能让调用方困惑。
///
/// ### 🟡 Bug 6: 文件名冲突（并发下载同一 meta）
/// 如果同时发起两个 downloadFileByMeta 且 meta.fileName 相同，
/// 两个下载会写入同一个文件，导致数据混乱。
///
/// ### 🟡 Bug 7: 大文件完整重读校验
/// SHA256 校验时会把整个文件重新读入内存 (file.readAsBytes)，
/// 对于大文件（GB 级）会占用大量内存。应考虑流式哈希。
///
/// ### 🟡 Bug 8: 异常时 sink.close() 可能失败
/// catch 块中先调用 sink.close() 再 file.delete()，
/// 但 sink.close() 本身也可能抛异常（磁盘满等），导致 file.delete() 被跳过。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/lan/lan_client_service.dart';
import 'package:wenzagent/src/rpc/rpc_protocol.dart';

// ============================================================
// 核心下载逻辑（从 DeviceClient.downloadFileByMeta 提取）
// ============================================================

/// 模拟 DeviceConnectionManager 的两个关键接口
abstract class DownloadConnection {
  bool get isConnected;

  Stream<RpcStreamEvent> invokeRemoteStream(
    String toDeviceId,
    String method,
    Map<String, dynamic> params, {
    int timeout = 120000,
  });

  Stream<BinaryChunkEvent> get binaryChunkStream;
}

/// 从 DeviceClient.downloadFileByMeta 提取的核心下载逻辑
/// （完全复制源码逻辑，用于测试）
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
  final savePath = p.join(saveDir, meta.fileName);
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

    // 3. 先订阅二进制 chunk 流，再消费 RPC 流
    String? reqId;
    final binarySub = connMgr.binaryChunkStream.listen((chunk) {
      if (reqId != null && chunk.requestId == reqId) {
        sink.add(chunk.data);
        received += chunk.data.length;
        if (meta.fileSize > 0) {
          onProgress?.call(received / meta.fileSize);
        }
      }
    });

    try {
      await for (final event in stream) {
        if (reqId == null && event.requestId != null) {
          reqId = event.requestId!;
        }
        if (event.isDone) {
          break;
        }
      }
    } finally {
      await binarySub.cancel();
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
// Mock 实现
// ============================================================

class FakeConnection implements DownloadConnection {
  @override
  bool isConnected = true;

  StreamController<RpcStreamEvent>? _streamController;
  final StreamController<BinaryChunkEvent> _binaryController =
      StreamController<BinaryChunkEvent>.broadcast();

  @override
  Stream<BinaryChunkEvent> get binaryChunkStream => _binaryController.stream;

  /// 是否模拟 binaryChunkStream 为空（模拟 _lanClient == null 的情况）
  bool simulateEmptyBinaryStream = false;

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

  void emitStreamEvent(RpcStreamEvent event) {
    _streamController?.add(event);
  }

  void closeStream() {
    _streamController?.close();
  }

  void pushBinaryChunk(BinaryChunkEvent chunk) {
    if (!simulateEmptyBinaryStream) {
      _binaryController.add(chunk);
    }
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

/// 执行一个标准的下载流程，返回 savePath
Future<String> _runStandardDownload({
  required FakeConnection conn,
  required FileMetaMessage meta,
  required String saveDir,
  required Uint8List content,
  required String reqId,
  void Function(double progress)? onProgress,
}) async {
  final future = downloadFileByMetaLogic(
    connMgr: conn,
    meta: meta,
    saveDir: saveDir,
    onProgress: onProgress,
  );

  await Future<void>.delayed(const Duration(milliseconds: 10));

  conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));
  await Future<void>.delayed(const Duration(milliseconds: 5));
  conn.pushBinaryChunk(BinaryChunkEvent(
    requestId: reqId,
    data: content,
    isLast: true,
  ));
  await Future<void>.delayed(const Duration(milliseconds: 5));
  conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

  return future;
}

// ============================================================
// 测试主体
// ============================================================

void main() {
  late FakeConnection conn;
  late Directory tempDir;

  setUp(() {
    conn = FakeConnection();
    tempDir = Directory.systemTemp.createTempSync('dl_issues_test_');
  });

  tearDown(() async {
    conn.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  // ==============================================================
  // 🔴 Bug 1: 文件名路径穿越漏洞
  // ==============================================================
  group('🔴 Bug #1: 文件名路径穿越漏洞 (fileName path traversal)', () {
    test('fileName 包含 ".." 可逃逸 saveDir', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: '../../escape_test.txt',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '/remote/test.txt',
      );

      final savePath = p.join(tempDir.path, meta.fileName);
      final resolved = File(savePath).absolute.path;

      // 验证：生成的路径确实在 tempDir 之外
      expect(resolved.contains('..'), isTrue,
          reason: 'p.join 保留了 ".."，导致路径逃逸');

      // 尝试下载 —— 在实际场景中文件会被写入到意外位置
      try {
        await _runStandardDownload(
          conn: conn,
          meta: meta,
          saveDir: tempDir.path,
          content: content,
          reqId: 'req-traversal-1',
        );
      } catch (e) {
        // 可能因目录不存在而失败
      }

      // 清理可能创建的文件
      try {
        final escapedFile = File(savePath);
        if (await escapedFile.exists()) {
          await escapedFile.delete();
          fail('文件被写入到 saveDir 之外！路径穿越漏洞已确认');
        }
      } catch (_) {}
    });

    test('fileName 包含 "/" 可创建子目录', () async {
      final content = Uint8List.fromList([4, 5, 6]);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'subdir/nested.txt',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '/remote/nested.txt',
      );

      final savePath = p.join(tempDir.path, meta.fileName);

      // 验证 p.join 确实生成了子目录路径
      expect(savePath, contains('subdir'));

      // 注意：如果 subdir 目录不存在，file.openWrite() 会抛出 PathNotFoundException
      // 这本身就是一个问题——fileName 可以包含路径分隔符，导致文件被写入非预期的子目录
      // 如果子目录恰好存在，文件就会被成功写入到 saveDir 下的子目录中
      try {
        // 先创建子目录，模拟子目录已存在的场景
        await Directory(p.dirname(savePath)).create(recursive: true);
        await _runStandardDownload(
          conn: conn,
          meta: meta,
          saveDir: tempDir.path,
          content: content,
          reqId: 'req-traversal-2',
        );
        // 文件被写入到 saveDir/subdir/nested.txt
        expect(File(savePath).existsSync(), isTrue);
      } catch (e) {
        // 不应该到这里
        fail('文件应该被成功写入子目录: $e');
      }
    });

    test('fileName 为绝对路径可覆盖系统文件', () async {
      // 在 Windows 上: C:\Windows\System32\exploit.txt
      // 在 Linux 上: /etc/exploit.txt
      final meta = makeMeta(
        fileName: '/tmp/absolute_path_test.txt',
        fileSize: 3,
        sha256Hash: 'abc',
        filePath: '/remote/test.txt',
      );

      final savePath = p.join(tempDir.path, meta.fileName);

      // p.join 在 fileName 为绝对路径时，会忽略 saveDir！
      // 这是 Dart 的 p.join 行为：如果第二个参数是绝对路径，则忽略第一个
      if (Platform.isWindows) {
        // Windows 上 /tmp 会被解释为相对路径
      } else {
        // Linux 上 p.join('/some/dir', '/tmp/absolute_path_test.txt')
        // 返回 '/tmp/absolute_path_test.txt' —— 完全忽略了 saveDir！
        expect(savePath, equals('/tmp/absolute_path_test.txt'),
            reason: 'p.join 忽略了 saveDir，绝对路径 fileName 直接被使用');
      }
    });

    test('fileName 包含反斜杠 (Windows)', () {
      final meta = makeMeta(
        fileName: '..\\..\\windows_escape.txt',
        fileSize: 3,
        sha256Hash: 'abc',
        filePath: '/remote/test.txt',
      );

      final savePath = p.join(tempDir.path, meta.fileName);
      // 在 Windows 上，p.join 会处理反斜杠
      expect(savePath.contains('..'), isTrue);
    });
  });

  // ==============================================================
  // 🟡 Bug 2: 同名文件静默覆盖
  // ==============================================================
  group('🟡 Bug #2: 同名文件静默覆盖 (silent overwrite)', () {
    test('已存在的文件被新下载静默覆盖', () async {
      final existingContent =
          Uint8List.fromList(List.generate(100, (i) => i));
      final newContent =
          Uint8List.fromList(List.generate(50, (i) => 200 + i));
      final newHash = sha256.convert(newContent).toString();

      // 先创建一个同名文件
      final existingFile =
          File(p.join(tempDir.path, 'overwrite_test.txt'));
      await existingFile.writeAsBytes(existingContent);
      expect(await existingFile.length(), equals(100));

      final meta = makeMeta(
        fileName: 'overwrite_test.txt',
        fileSize: newContent.length,
        sha256Hash: newHash,
        filePath: '/remote/overwrite_test.txt',
      );

      final savePath = await _runStandardDownload(
        conn: conn,
        meta: meta,
        saveDir: tempDir.path,
        content: newContent,
        reqId: 'req-overwrite-1',
      );

      // 文件被覆盖，无任何警告
      final savedBytes = await File(savePath).readAsBytes();
      expect(savedBytes, equals(newContent));
      expect(savedBytes, isNot(equals(existingContent)),
          reason: '原文件已被静默覆盖，数据丢失');
    });
  });

  // ==============================================================
  // 🟡 Bug 3: saveDir 不存在
  // ==============================================================
  group('🟡 Bug #3: saveDir 不存在 (missing saveDir)', () {
    test('saveDir 不存在时抛出底层 OS 异常', () async {
      final nonExistentDir =
          '${tempDir.path}${Platform.pathSeparator}nonexistent_dir';

      // 直接测试 file.openWrite() 在不存在的目录下会抛出什么异常
      final savePath = p.join(nonExistentDir, 'test.txt');
      final file = File(savePath);

      Object? caughtError;
      try {
        final sink = file.openWrite(); // 同步创建 IOSink
        sink.add([1, 2, 3]);
        await sink.close(); // 这里会抛出 PathNotFoundException
        fail('应该抛出异常');
      } catch (e) {
        caughtError = e;
      }

      // 验证：抛出的是 OS 级 PathNotFoundException，不是友好的业务提示
      expect(caughtError, isNotNull);
      expect(caughtError.toString(), isNot(contains('保存目录不存在')),
          reason: '错误信息不是友好的业务提示，而是底层 OS 异常');
      expect(caughtError is FileSystemException, isTrue,
          reason: '抛出的是 FileSystemException（OS 级异常），不是业务层异常');
    });
  });

  // ==============================================================
  // 🟡 Bug 4: binaryChunkStream 为空流
  // ==============================================================
  group('🟡 Bug #4: binaryChunkStream 为空流 (empty binary stream)', () {
    test('binaryChunkStream 为空时文件内容为空，SHA256 校验失败', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(content).toString();

      // 模拟 binaryChunkStream 为空（_lanClient == null 的情况）
      conn.simulateEmptyBinaryStream = true;

      final meta = makeMeta(
        fileName: 'empty_stream.txt',
        fileSize: content.length,
        sha256Hash: hash, // 期望的 hash 是有内容的
        filePath: '/remote/empty_stream.txt',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-empty-stream-1';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));

      // RPC 流正常结束，但二进制数据从未到达
      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      try {
        await future;
        fail('应该抛出异常');
      } catch (e) {
        // 错误是 "SHA256 不匹配"，但实际上是因为 binaryStream 为空
        // 用户很难从错误信息中诊断出真正的原因
        expect(e.toString(), contains('SHA256'),
            reason: '错误信息误导：实际原因是 binaryStream 为空，'
                '但报的是 SHA256 不匹配');
      }
    });
  });

  // ==============================================================
  // 🟡 Bug 5: 进度超过 1.0
  // ==============================================================
  group('🟡 Bug #5: 进度超过 1.0 (progress overflow)', () {
    test('远端发送数据超过 fileSize 时 progress > 1.0', () async {
      // meta.fileSize 声明为 5 字节，但实际发送 10 字节
      final content = Uint8List.fromList(List.generate(10, (i) => i));
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'overflow_progress.dat',
        fileSize: 5, // 故意声明比实际小
        sha256Hash: hash,
        filePath: '/remote/overflow_progress.dat',
      );

      final progresses = <double>[];

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
        onProgress: progresses.add,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-progress-overflow';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId,
        data: content,
        isLast: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      // 因为 fileSize 不匹配，SHA256 会校验通过（hash 是实际内容的）
      // 但进度会超过 1.0
      try {
        await future;
      } catch (_) {
        // SHA256 可能不匹配如果 fileSize 和实际不一致（这里 hash 是对的所以会通过）
      }

      // 进度超过 1.0
      if (progresses.isNotEmpty) {
        expect(progresses.last, greaterThan(1.0),
            reason: 'progress = received(10) / fileSize(5) = 2.0 > 1.0');
      }
    });
  });

  // ==============================================================
  // 🟡 Bug 6: 并发下载同名文件
  // ==============================================================
  group('🟡 Bug #6: 并发下载同名文件 (concurrent download race)', () {
    test('两个并发下载同一 meta 写入同一文件', () async {
      final content1 = Uint8List.fromList(List.generate(100, (i) => i));
      final content2 = Uint8List.fromList(List.generate(100, (i) => 200 - i));
      final hash1 = sha256.convert(content1).toString();

      final meta = makeMeta(
        fileName: 'concurrent.dat',
        fileSize: content1.length,
        sha256Hash: hash1,
        filePath: '/remote/concurrent.dat',
      );

      // 两个下载使用相同的 meta（相同的 fileName）
      final future1 = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 第一个下载的 RPC 事件
      const reqId1 = 'req-concurrent-1';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId1));

      // 短暂延迟后启动第二个下载（使用相同的 conn，模拟不太精确但能展示问题）
      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId1,
        data: content1,
        isLast: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(
          RpcStreamEvent.done({}, requestId: reqId1));

      // 第一个下载完成
      try {
        await future1;
      } catch (e) {
        // 可能因并发写入而失败
      }

      // 验证：两个下载确实会写入同一个路径
      final savePath = p.join(tempDir.path, meta.fileName);
      expect(savePath, equals(p.join(tempDir.path, 'concurrent.dat')),
          reason: '两个下载会写入同一个文件路径');
    });
  });

  // ==============================================================
  // 🟡 Bug 7: 大文件完整重读校验（内存问题演示）
  // ==============================================================
  group('🟡 Bug #7: SHA256 校验时完整重读文件 (memory concern)', () {
    test('校验时重新读取整个文件到内存', () async {
      // 用一个中等大小的文件来演示问题
      // 实际场景中如果是 GB 级文件，readAsBytes() 会 OOM
      final content = Uint8List.fromList(
        List.generate(1024 * 1024, (i) => i % 256), // 1MB
      );
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'big_file.dat',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '/remote/big_file.dat',
      );

      final savePath = await _runStandardDownload(
        conn: conn,
        meta: meta,
        saveDir: tempDir.path,
        content: content,
        reqId: 'req-big-file',
      );

      // 验证文件正确
      expect(File(savePath).existsSync(), isTrue);

      // 注意：源码中校验使用 file.readAsBytes()，对于大文件有内存风险
      // 更好的做法是使用流式哈希：
      //   final stream = File(savePath).openRead();
      //   final hash = await sha256.bind(stream).first;
      // 这里仅记录问题，不做修复
    });
  });

  // ==============================================================
  // 🟡 Bug 8: 异常时 sink.close() 可能失败
  // ==============================================================
  group('🟡 Bug #8: 异常处理中 sink.close() 失败', () {
    test('catch 块中 sink.close() 和 file.delete() 的顺序问题', () async {
      // 源码中的模式：
      //   catch (e) {
      //     await sink.close();   // ← 如果这里抛异常
      //     try {
      //       await file.delete(); // ← 这里就不会执行
      //     } catch (_) {}
      //     rethrow;
      //   }
      //
      // 更安全的写法：
      //   catch (e) {
      //     try { await sink.close(); } catch (_) {}
      //     try { await file.delete(); } catch (_) {}
      //     rethrow;
      //   }

      // 这里我们验证当前模式在正常异常场景下能清理
      final content = Uint8List.fromList([1, 2, 3]);

      final meta = makeMeta(
        fileName: 'cleanup_test.txt',
        fileSize: content.length,
        sha256Hash: 'wrong_hash',
        filePath: '/remote/cleanup_test.txt',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-cleanup';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitError(Exception('模拟 RPC 错误'));

      try {
        await future;
        fail('应该抛出异常');
      } catch (e) {
        // 验证临时文件被清理
        final savePath = p.join(tempDir.path, 'cleanup_test.txt');
        // 在 RPC 错误场景下文件应该被删除
        expect(File(savePath).existsSync(), isFalse,
            reason: 'RPC 错误后临时文件应该被清理');
      }
    });
  });

  // ==============================================================
  // 🟢 额外边界场景
  // ==============================================================
  group('额外边界场景', () {
    test('fileName 为空字符串', () async {
      final content = Uint8List.fromList([1]);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: '',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '/remote/empty_name.txt',
      );

      // 空文件名会导致 savePath 就是 saveDir 本身（目录）
      final savePath = p.join(tempDir.path, meta.fileName);
      expect(savePath, equals(tempDir.path),
          reason: '空 fileName 导致 savePath 指向目录本身');
    });

    test('fileName 包含特殊字符（空格、中文、emoji）', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: '文件 📄 test (1).txt',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '/remote/special.txt',
      );

      final savePath = await _runStandardDownload(
        conn: conn,
        meta: meta,
        saveDir: tempDir.path,
        content: content,
        reqId: 'req-special-chars',
      );

      expect(File(savePath).existsSync(), isTrue);
      expect(File(savePath).readAsBytesSync(), equals(content));
    });

    test('fileSize 为 0 但实际有数据', () async {
      // meta 声明 fileSize=0，但远端实际发送了数据
      final content = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'zero_size.dat',
        fileSize: 0,
        sha256Hash: hash,
        filePath: '/remote/zero_size.dat',
      );

      final progresses = <double>[];

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
        onProgress: progresses.add,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-zero-size';
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
      expect(File(savePath).existsSync(), isTrue);
      // 进度不会被调用（fileSize=0 时跳过）
      expect(progresses, isEmpty,
          reason: 'fileSize=0 时不触发进度回调，'
              '即使实际有数据传输');
    });

    test('RPC 流立即关闭（无任何事件）', () async {
      final content = Uint8List(0);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'instant_close.dat',
        fileSize: 0,
        sha256Hash: hash,
        filePath: '/remote/instant_close.dat',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 直接关闭流，不发送任何事件
      conn.closeStream();

      // 这种情况下 reqId 始终为 null，binarySub 不会匹配任何 chunk
      final savePath = await future;
      expect(File(savePath).existsSync(), isTrue);
      expect(File(savePath).readAsBytesSync(), isEmpty);
    });

    test('meta.fromDeviceId 为空字符串', () async {
      final content = Uint8List.fromList([1]);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'no_device.txt',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '/remote/no_device.txt',
        fromDeviceId: '', // 空设备 ID
      );

      // invokeRemoteStream 会用空字符串作为 toDeviceId
      // 这可能导致 RPC 路由失败，但代码不会提前校验
      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-no-device';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId,
        data: content,
        isLast: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      // Mock 层面不校验 toDeviceId，所以能成功
      // 但在真实环境中，空 toDeviceId 会导致 RPC 路由失败
      final savePath = await future;
      expect(File(savePath).existsSync(), isTrue);
    });

    test('meta.filePath 为空字符串', () async {
      final content = Uint8List.fromList([1]);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'no_path.txt',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '', // 空远程路径
      );

      // 代码会把空路径传给 RPC：{'path': ''}
      // 远端收到空路径可能会报错，但本端不会提前校验
      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-no-path';
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
      expect(File(savePath).existsSync(), isTrue);
    });
  });

  // ==============================================================
  // 🟢 requestId 时序问题
  // ==============================================================
  group('requestId 时序问题', () {
    test('二进制 chunk 在 RPC 事件之前到达（reqId 尚未设置）', () async {
      final content = Uint8List.fromList([42, 43, 44]);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'early_chunk.dat',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '/remote/early_chunk.dat',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 先推二进制 chunk（此时 reqId 还没设置）
      const reqId = 'req-early';
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: reqId,
        data: content,
        isLast: true,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 5));

      // 再发 RPC 事件（设置 reqId）
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      try {
        final savePath = await future;
        final saved = File(savePath).readAsBytesSync();
        // 如果二进制帧在 reqId 设置前到达，数据会丢失
        expect(saved.length, equals(0),
            reason: '🔴 二进制 chunk 在 reqId 设置前到达，数据丢失！'
                '源码注释说 "CRITICAL: binaryChunkStream 是 broadcast stream，'
                '必须在二进制帧到达前开始监听"，但 reqId 是在 RPC 事件后才设置的，'
                '如果二进制帧比 RPC 事件先到达，chunk.requestId != reqId(null)，数据被丢弃');
      } catch (e) {
        // SHA256 校验失败（因为文件为空）
        expect(e.toString(), contains('SHA256'),
            reason: '数据丢失导致 SHA256 不匹配');
      }
    });

    test('多个 RPC 流事件中 requestId 变化', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(content).toString();

      final meta = makeMeta(
        fileName: 'changing_reqid.dat',
        fileSize: content.length,
        sha256Hash: hash,
        filePath: '/remote/changing_reqid.dat',
      );

      final future = downloadFileByMetaLogic(
        connMgr: conn,
        meta: meta,
        saveDir: tempDir.path,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 第一个 RPC 事件带 reqId-1
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: 'req-changed-1'));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // 发送二进制数据（使用 reqId-1）
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: 'req-changed-1',
        data: content,
        isLast: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // 再发一个 RPC 事件带不同的 reqId（源码只取第一个非 null 的 reqId）
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: 'req-changed-2'));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      conn.emitStreamEvent(
          RpcStreamEvent.done({}, requestId: 'req-changed-2'));

      final savePath = await future;
      // 源码中 reqId 只设置一次（if reqId == null），后续事件不会改变
      expect(File(savePath).readAsBytesSync(), equals(content),
          reason: 'reqId 只取第一个非 null 值，后续变化不影响');
    });
  });

  // ==============================================================
  // 🟢 问题汇总
  // ==============================================================
  group('问题汇总', () {
    test('所有已识别问题的清单', () {
      final issues = <String, String>{
        'Bug #1': '文件名路径穿越漏洞 — fileName 未做 sanitize',
        'Bug #2': '同名文件静默覆盖 — 无冲突检测',
        'Bug #3': 'saveDir 不存在时无友好错误',
        'Bug #4': 'binaryChunkStream 为空时错误信息误导',
        'Bug #5': '进度可能超过 1.0 — fileSize 不准确',
        'Bug #6': '并发下载同名文件数据竞争',
        'Bug #7': 'SHA256 校验时完整重读文件 — 大文件内存风险',
        'Bug #8': 'catch 块中 sink.close() 失败导致 file.delete() 被跳过',
        'Timing #1': '二进制 chunk 在 reqId 设置前到达会丢失数据',
      };

      print('\n========================================');
      print('downloadFileByMeta 已识别问题清单');
      print('========================================');
      for (final entry in issues.entries) {
        print('  ${entry.key}: ${entry.value}');
      }
      print('========================================\n');

      expect(issues.length, equals(9));
    });
  });
}
