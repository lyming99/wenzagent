/// FileMessageCard._startDownload 下载流程测试
///
/// 模拟前端 FileMessageCard._startDownload() 的完整调用链路：
///
///   前端 (Flutter)                         后端 (wenzagent)
///   ─────────────                          ───────────────
///   1. 获取 DeviceClient 实例
///   2. 检查 dc.isConnected
///   3. 从 ChatMessage.metadata 提取字段
///   4. 构建 FileMetaMessage
///   5. 获取下载目录（确保存在）
///   6. 调用 dc.downloadFileByMeta()
///      ┌──────────────────────────────────────────────────┐
///      │  a. 检查连接状态                                   │
///      │  b. 拼接保存路径 p.join(saveDir, fileName)         │
///      │  c. 发起 RPC 流式请求 invokeRemoteStream           │
///      │  d. 监听 binaryChunkStream 按 requestId 过滤       │
///      │  e. 写入文件 + 报告进度                             │
///      │  f. SHA256 校验                                    │
///      │  g. 返回 savePath                                  │
///      └──────────────────────────────────────────────────┘
///   7. 更新 UI 状态 (idle → downloading → completed/failed)
///
/// 测试覆盖：
///   ✅ 正常下载：小文件、大文件（多 chunk）、空文件
///   ✅ 前端参数校验：fromDeviceId 为空、filePath 为空
///   ✅ 连接状态：未连接时拒绝下载
///   ✅ 元数据完整性：metadata 缺失字段的降级处理
///   ✅ 进度回调：进度值正确、单调递增
///   ✅ SHA256 校验：匹配/不匹配
///   ✅ 错误恢复：下载失败后可重试
///   ✅ 下载目录：自动创建
///   ✅ 特殊文件名：中文、空格、emoji
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/lan/lan_client_service.dart';
import 'package:wenzagent/src/rpc/rpc_protocol.dart';

// ============================================================
// 模拟前端 ChatMessage.metadata 结构
// ============================================================

/// 模拟前端 ChatMessage 的 metadata
///
/// 对应前端代码：
/// ```dart
/// Map<String, dynamic> get _meta => widget.message.metadata ?? <String, dynamic>{};
/// String get _fileName => _meta['fileName'] as String? ?? widget.message.content;
/// String get _filePath => _meta['filePath'] as String? ?? '';
/// int get _fileSize => _meta['fileSize'] as int? ?? 0;
/// ```
class FakeChatMessageMeta {
  final Map<String, dynamic> _meta;

  FakeChatMessageMeta(Map<String, dynamic> meta) : _meta = meta;

  /// 获取元数据（模拟 widget.message.metadata）
  Map<String, dynamic> get meta => _meta;

  String get fileName => _meta['fileName'] as String? ?? '';
  String get filePath => _meta['filePath'] as String? ?? '';
  int get fileSize => _meta['fileSize'] as int? ?? 0;
  String get fromDeviceId => _meta['fromDeviceId'] as String? ?? '';
  String get fileId => _meta['fileId'] as String? ?? '';
  String get sha256 => _meta['sha256'] as String? ?? '';
  String? get mimeType => _meta['mimeType'] as String?;
  String? get role => _meta['role'] as String?;
  String? get employeeId => _meta['employeeId'] as String?;
}

// ============================================================
// 模拟前端下载状态机
// ============================================================

/// 文件下载状态（与前端 FileDownloadState 枚举一致）
enum FileDownloadState { idle, downloading, completed, failed }

/// 模拟前端 _FileMessageCardState 的下载逻辑
///
/// 将 Flutter State 的 setState / mounted 简化为普通字段赋值。
/// 核心逻辑与 _startDownload() 完全一致。
class FakeFileMessageCard {
  final FakeChatMessageMeta messageMeta;
  final bool isLocalFile;
  final bool isDesktop;

  /// 模拟的 DeviceClient 连接
  final DownloadConnection connMgr;

  /// 模拟的下载目录
  final String downloadDir;

  // 状态字段（对应前端 State）
  FileDownloadState _state = FileDownloadState.idle;
  double _progress = 0;
  String? _errorMessage;
  String? _savePath;

  // 记录所有状态变化（用于测试断言）
  final List<FileDownloadState> stateHistory = [];
  final List<double> progressHistory = [];

  FileDownloadState get state => _state;
  double get progress => _progress;
  String? get errorMessage => _errorMessage;
  String? get savePath => _savePath;

  FakeFileMessageCard({
    required this.messageMeta,
    required this.connMgr,
    required this.downloadDir,
    this.isLocalFile = false,
    this.isDesktop = true,
  }) {
    // 模拟 initState：桌面端 + 本地文件 + 路径存在 → 直接标记完成
    if (isDesktop && isLocalFile && messageMeta.filePath.isNotEmpty) {
      _state = FileDownloadState.completed;
      _savePath = messageMeta.filePath;
    }
  }

  void _setState(FileDownloadState newState) {
    stateHistory.add(newState);
    _state = newState;
  }

  /// 模拟前端 _startDownload()
  ///
  /// 完全复制前端逻辑：
  /// 1. 检查是否正在下载
  /// 2. 检查连接状态
  /// 3. 从 metadata 提取参数并校验
  /// 4. 构建 FileMetaMessage
  /// 5. 确保下载目录存在
  /// 6. 调用 downloadFileByMeta
  Future<void> startDownload() async {
    if (_state == FileDownloadState.downloading) return;

    _setState(FileDownloadState.downloading);
    _progress = 0;
    _errorMessage = null;
    progressHistory.clear();

    try {
      // 1. 检查连接
      if (!connMgr.isConnected) {
        throw Exception('设备未连接，请检查网络');
      }

      // 2. 从 metadata 获取源设备 ID 和文件路径
      final fromDeviceId = messageMeta.fromDeviceId;
      final filePath = messageMeta.filePath;
      if (fromDeviceId.isEmpty) {
        throw Exception('文件来源设备 ID 为空，无法下载。请重新发送文件。');
      }
      if (filePath.isEmpty) {
        throw Exception('文件路径为空');
      }

      // 3. 构建 FileMetaMessage
      final meta = FileMetaMessage(
        fileId: messageMeta.fileId,
        fileName: messageMeta.fileName,
        fileSize: messageMeta.fileSize,
        sha256: messageMeta.sha256,
        filePath: filePath,
        fromDeviceId: fromDeviceId,
        mimeType: messageMeta.mimeType,
        role: messageMeta.role,
        employeeId: messageMeta.employeeId,
      );

      // 4. 确保下载目录存在（模拟 _getDownloadDir）
      final dir = Directory(downloadDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // 5. 调用 downloadFileByMeta
      final savePath = await downloadFileByMetaLogic(
        connMgr: connMgr,
        meta: meta,
        saveDir: downloadDir,
        onProgress: (double progress) {
          _progress = progress;
          progressHistory.add(progress);
        },
      );

      _savePath = savePath;
      _setState(FileDownloadState.completed);
    } catch (e) {
      _errorMessage = e.toString().replaceFirst('Exception: ', '');
      _setState(FileDownloadState.failed);
    }
  }
}

// ============================================================
// 核心下载逻辑（从 DeviceClient.downloadFileByMeta 提取）
// ============================================================

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

Future<String> downloadFileByMetaLogic({
  required DownloadConnection connMgr,
  required FileMetaMessage meta,
  required String saveDir,
  void Function(double progress)? onProgress,
}) async {
  if (!connMgr.isConnected) {
    throw StateError('未连接到服务器');
  }

  final savePath = p.join(saveDir, meta.fileName);
  final file = File(savePath);
  final sink = file.openWrite();
  int received = 0;

  try {
    final stream = connMgr.invokeRemoteStream(
      meta.fromDeviceId,
      'agentReadFileStream',
      {'path': meta.filePath},
      timeout: 0,
    );

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

/// 构建完整的 metadata（模拟前端 ChatMessage.metadata）
Map<String, dynamic> buildMetadata({
  required String fileName,
  required int fileSize,
  required String hash,
  required String filePath,
  required String fromDeviceId,
  String fileId = 'file-test-001',
  String? mimeType,
  String? role,
  String? employeeId,
}) {
  return {
    'fileName': fileName,
    'fileSize': fileSize,
    'sha256': hash,
    'filePath': filePath,
    'fromDeviceId': fromDeviceId,
    'fileId': fileId,
    if (mimeType != null) 'mimeType': mimeType,
    if (role != null) 'role': role,
    if (employeeId != null) 'employeeId': employeeId,
  };
}

/// 执行完整的前端下载流程
///
/// 模拟前端 _startDownload 的完整调用链：
/// 1. 创建 FakeFileMessageCard
/// 2. 调用 startDownload()
/// 3. 模拟 RPC 流式响应 + 二进制数据
/// 4. 等待下载完成
Future<FakeFileMessageCard> _simulateFrontendDownload({
  required FakeConnection conn,
  required Map<String, dynamic> metadata,
  required String downloadDir,
  required Uint8List content,
  required String reqId,
  bool isLocalFile = false,
}) async {
  final msgMeta = FakeChatMessageMeta(metadata);
  final card = FakeFileMessageCard(
    messageMeta: msgMeta,
    connMgr: conn,
    downloadDir: downloadDir,
    isLocalFile: isLocalFile,
  );

  // 启动下载（异步）
  final downloadFuture = card.startDownload();

  // 等待 invokeRemoteStream 被调用
  await Future<void>.delayed(const Duration(milliseconds: 10));

  // 模拟 RPC 流式响应
  conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));
  await Future<void>.delayed(const Duration(milliseconds: 5));

  // 模拟二进制数据到达
  conn.pushBinaryChunk(BinaryChunkEvent(
    requestId: reqId,
    data: content,
    isLast: true,
  ));
  await Future<void>.delayed(const Duration(milliseconds: 5));

  // 模拟 RPC 流结束
  conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

  await downloadFuture;
  return card;
}

Uint8List sequentialBytes(int len) {
  final bytes = Uint8List(len);
  for (var i = 0; i < len; i++) {
    bytes[i] = i % 256;
  }
  return bytes;
}

String formatFileSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  int unitIndex = 0;
  double size = bytes.toDouble();
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }
  return '${size.toStringAsFixed(1)} ${units[unitIndex]}';
}

// ============================================================
// 测试主体
// ============================================================

void main() {
  late FakeConnection conn;
  late Directory tempDir;

  setUp(() {
    conn = FakeConnection();
    tempDir = Directory.systemTemp.createTempSync('file_card_download_test_');
  });

  tearDown(() async {
    conn.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  // ==============================================================
  // 1. 前端参数校验（_startDownload 中的前置检查）
  // ==============================================================
  group('前端参数校验', () {
    test('fromDeviceId 为空 → 抛出友好错误', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'test.txt',
        fileSize: content.length,
        hash: hash,
        filePath: '/remote/test.txt',
        fromDeviceId: '', // 空设备 ID
      );

      final card = FakeFileMessageCard(
        messageMeta: FakeChatMessageMeta(metadata),
        connMgr: conn,
        downloadDir: tempDir.path,
      );

      await card.startDownload();

      expect(card.state, equals(FileDownloadState.failed));
      expect(card.errorMessage, contains('文件来源设备 ID 为空'));
    });

    test('filePath 为空 → 抛出友好错误', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'test.txt',
        fileSize: content.length,
        hash: hash,
        filePath: '', // 空文件路径
        fromDeviceId: 'device-A',
      );

      final card = FakeFileMessageCard(
        messageMeta: FakeChatMessageMeta(metadata),
        connMgr: conn,
        downloadDir: tempDir.path,
      );

      await card.startDownload();

      expect(card.state, equals(FileDownloadState.failed));
      expect(card.errorMessage, contains('文件路径为空'));
    });

    test('设备未连接 → 抛出友好错误', () async {
      conn.isConnected = false;

      final metadata = buildMetadata(
        fileName: 'test.txt',
        fileSize: 100,
        hash: 'abc',
        filePath: '/remote/test.txt',
        fromDeviceId: 'device-A',
      );

      final card = FakeFileMessageCard(
        messageMeta: FakeChatMessageMeta(metadata),
        connMgr: conn,
        downloadDir: tempDir.path,
      );

      await card.startDownload();

      expect(card.state, equals(FileDownloadState.failed));
      expect(card.errorMessage, contains('设备未连接'));
    });

    test('下载中重复点击 → 忽略（不重复下载）', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'test.txt',
        fileSize: content.length,
        hash: hash,
        filePath: '/remote/test.txt',
        fromDeviceId: 'device-A',
      );

      final card = FakeFileMessageCard(
        messageMeta: FakeChatMessageMeta(metadata),
        connMgr: conn,
        downloadDir: tempDir.path,
      );

      // 第一次调用：进入 downloading 状态
      final future1 = card.startDownload();
      expect(card.state, equals(FileDownloadState.downloading));

      // 第二次调用：应被忽略
      await card.startDownload();
      expect(card.state, equals(FileDownloadState.downloading));

      // 完成第一次下载
      await Future<void>.delayed(const Duration(milliseconds: 10));
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: 'req-1'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.pushBinaryChunk(BinaryChunkEvent(
        requestId: 'req-1',
        data: content,
        isLast: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(
          RpcStreamEvent.done({}, requestId: 'req-1'));

      await future1;
      expect(card.state, equals(FileDownloadState.completed));
    });
  });

  // ==============================================================
  // 2. 元数据降级处理（前端 _meta 字段的默认值逻辑）
  // ==============================================================
  group('元数据降级处理', () {
    test('metadata 缺少 fileSize → 默认 0，不触发进度回调', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(content).toString();

      // 模拟 metadata 中没有 fileSize 字段
      final metadata = <String, dynamic>{
        'fileName': 'no_size.txt',
        'sha256': hash,
        'filePath': '/remote/no_size.txt',
        'fromDeviceId': 'device-A',
        'fileId': 'file-001',
      };

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-no-size',
      );

      expect(card.state, equals(FileDownloadState.completed));
      expect(card.savePath, isNotNull);
      // fileSize=0，进度不会被调用
      expect(card.progressHistory, isEmpty);
    });

    test('metadata 缺少 sha256 → 空字符串，校验必然失败', () async {
      final content = Uint8List.fromList([1, 2, 3]);

      final metadata = <String, dynamic>{
        'fileName': 'no_hash.txt',
        'fileSize': content.length,
        'filePath': '/remote/no_hash.txt',
        'fromDeviceId': 'device-A',
        'fileId': 'file-002',
        // 没有 sha256 字段
      };

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-no-hash',
      );

      // sha256 为空字符串，与实际 hash 不匹配
      expect(card.state, equals(FileDownloadState.failed));
      expect(card.errorMessage, contains('SHA256 不匹配'));
    });

    test('metadata 完整 → 下载成功', () async {
      final content = Uint8List.fromList(utf8.encode('Hello, World!'));
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'hello.txt',
        fileSize: content.length,
        hash: hash,
        filePath: '/remote/hello.txt',
        fromDeviceId: 'device-A',
        mimeType: 'text/plain',
        role: 'user',
        employeeId: 'emp-001',
      );

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-full-meta',
      );

      expect(card.state, equals(FileDownloadState.completed));
      expect(card.savePath, endsWith('hello.txt'));
      expect(File(card.savePath!).existsSync(), isTrue);
      expect(File(card.savePath!).readAsBytesSync(), equals(content));
    });
  });

  // ==============================================================
  // 3. 正常下载流程（模拟完整的前端 → 后端调用链）
  // ==============================================================
  group('正常下载流程', () {
    test('小文件下载（单 chunk）', () async {
      final content = Uint8List.fromList(utf8.encode('Small file content'));
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'small.txt',
        fileSize: content.length,
        hash: hash,
        filePath: '/remote/small.txt',
        fromDeviceId: 'device-B',
      );

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-small',
      );

      // 验证状态流转：idle → downloading → completed
      expect(card.stateHistory,
          equals([FileDownloadState.downloading, FileDownloadState.completed]));
      expect(card.state, equals(FileDownloadState.completed));
      expect(card.savePath, isNotNull);
      expect(File(card.savePath!).readAsStringSync(), equals('Small file content'));
    });

    test('大文件下载（多 chunk，256KB）', () async {
      final totalSize = 256 * 1024;
      final content = sequentialBytes(totalSize);
      final hash = sha256.convert(content).toString();
      final chunkSize = 64 * 1024;

      final metadata = buildMetadata(
        fileName: 'large.bin',
        fileSize: totalSize,
        hash: hash,
        filePath: '/remote/large.bin',
        fromDeviceId: 'device-B',
      );

      final msgMeta = FakeChatMessageMeta(metadata);
      final card = FakeFileMessageCard(
        messageMeta: msgMeta,
        connMgr: conn,
        downloadDir: tempDir.path,
      );

      final downloadFuture = card.startDownload();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-large';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // 分 4 个 chunk 发送
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
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      await downloadFuture;

      expect(card.state, equals(FileDownloadState.completed));
      expect(card.savePath, isNotNull);
      expect(File(card.savePath!).lengthSync(), equals(totalSize));
      expect(File(card.savePath!).readAsBytesSync(), equals(content));

      // 进度应该是 4 个值，单调递增
      expect(card.progressHistory.length, equals(4));
      expect(card.progressHistory.last, closeTo(1.0, 0.01));
      for (var i = 1; i < card.progressHistory.length; i++) {
        expect(card.progressHistory[i],
            greaterThanOrEqualTo(card.progressHistory[i - 1]));
      }
    });

    test('空文件下载', () async {
      final content = Uint8List(0);
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'empty.txt',
        fileSize: 0,
        hash: hash,
        filePath: '/remote/empty.txt',
        fromDeviceId: 'device-B',
      );

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-empty',
      );

      expect(card.state, equals(FileDownloadState.completed));
      expect(File(card.savePath!).readAsBytesSync(), isEmpty);
    });

    test('二进制文件下载（全字节值 0-255）', () async {
      final content = Uint8List.fromList(List.generate(256, (i) => i));
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'binary.bin',
        fileSize: 256,
        hash: hash,
        filePath: '/remote/binary.bin',
        fromDeviceId: 'device-B',
      );

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-binary',
      );

      expect(card.state, equals(FileDownloadState.completed));
      expect(File(card.savePath!).readAsBytesSync(), equals(content));
    });
  });

  // ==============================================================
  // 4. 进度回调验证
  // ==============================================================
  group('进度回调', () {
    test('进度值单调递增且最终接近 1.0', () async {
      final content = sequentialBytes(200);
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'progress.dat',
        fileSize: 200,
        hash: hash,
        filePath: '/remote/progress.dat',
        fromDeviceId: 'device-B',
      );

      final msgMeta = FakeChatMessageMeta(metadata);
      final card = FakeFileMessageCard(
        messageMeta: msgMeta,
        connMgr: conn,
        downloadDir: tempDir.path,
      );

      final downloadFuture = card.startDownload();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-progress';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // 分 4 个 chunk 发送：50, 50, 50, 50
      for (var i = 0; i < 4; i++) {
        final start = i * 50;
        conn.pushBinaryChunk(BinaryChunkEvent(
          requestId: reqId,
          data: Uint8List.fromList(content.sublist(start, start + 50)),
          isLast: i == 3,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({}, requestId: reqId));

      await downloadFuture;

      expect(card.progressHistory, isNotEmpty);
      expect(card.progressHistory.last, closeTo(1.0, 0.01));

      // 单调递增
      for (var i = 1; i < card.progressHistory.length; i++) {
        expect(card.progressHistory[i],
            greaterThanOrEqualTo(card.progressHistory[i - 1]));
      }
    });

    test('进度值精确计算（两等分）', () async {
      final content = sequentialBytes(100);
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'exact.dat',
        fileSize: 100,
        hash: hash,
        filePath: '/remote/exact.dat',
        fromDeviceId: 'device-B',
      );

      final msgMeta = FakeChatMessageMeta(metadata);
      final card = FakeFileMessageCard(
        messageMeta: msgMeta,
        connMgr: conn,
        downloadDir: tempDir.path,
      );

      final downloadFuture = card.startDownload();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      const reqId = 'req-exact';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));
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

      await downloadFuture;

      expect(card.progressHistory.length, equals(2));
      expect(card.progressHistory[0], closeTo(0.5, 0.01));
      expect(card.progressHistory[1], closeTo(1.0, 0.01));
    });
  });

  // ==============================================================
  // 5. SHA256 校验
  // ==============================================================
  group('SHA256 校验', () {
    test('SHA256 匹配 → 下载成功', () async {
      final content = Uint8List.fromList(utf8.encode('校验成功'));
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'valid.txt',
        fileSize: content.length,
        hash: hash,
        filePath: '/remote/valid.txt',
        fromDeviceId: 'device-B',
      );

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-valid',
      );

      expect(card.state, equals(FileDownloadState.completed));
      expect(card.savePath, isNotNull);
      expect(File(card.savePath!).existsSync(), isTrue);
    });

    test('SHA256 不匹配 → 下载失败，文件被删除', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final wrongHash = sha256.convert(Uint8List.fromList([99])).toString();

      final metadata = buildMetadata(
        fileName: 'corrupt.txt',
        fileSize: content.length,
        hash: wrongHash,
        filePath: '/remote/corrupt.txt',
        fromDeviceId: 'device-B',
      );

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-corrupt',
      );

      expect(card.state, equals(FileDownloadState.failed));
      expect(card.errorMessage, contains('SHA256 不匹配'));

      // 文件应该被删除
      final savePath = p.join(tempDir.path, 'corrupt.txt');
      expect(File(savePath).existsSync(), isFalse);
    });

    test('SHA256 为空字符串 → 校验必然失败', () async {
      final content = Uint8List.fromList([1, 2, 3]);

      final metadata = buildMetadata(
        fileName: 'empty_hash.txt',
        fileSize: content.length,
        hash: '', // 空 hash
        filePath: '/remote/empty_hash.txt',
        fromDeviceId: 'device-B',
      );

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-empty-hash',
      );

      expect(card.state, equals(FileDownloadState.failed));
      expect(card.errorMessage, contains('SHA256 不匹配'));
    });
  });

  // ==============================================================
  // 6. 错误处理与重试
  // ==============================================================
  group('错误处理与重试', () {
    test('RPC 错误 → 状态变为 failed，可重试', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'retry.txt',
        fileSize: content.length,
        hash: hash,
        filePath: '/remote/retry.txt',
        fromDeviceId: 'device-B',
      );

      final msgMeta = FakeChatMessageMeta(metadata);

      // 第一次尝试：RPC 错误
      final card1 = FakeFileMessageCard(
        messageMeta: msgMeta,
        connMgr: conn,
        downloadDir: tempDir.path,
      );

      final future1 = card1.startDownload();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      conn.emitError(Exception('RPC 连接中断'));
      await future1;

      expect(card1.state, equals(FileDownloadState.failed));
      expect(card1.errorMessage, contains('RPC 连接中断'));

      // 第二次尝试：成功（使用新的 FakeConnection，因为旧的 streamController 已关闭）
      conn.dispose();
      conn = FakeConnection();

      final card2 = FakeFileMessageCard(
        messageMeta: msgMeta,
        connMgr: conn,
        downloadDir: tempDir.path,
      );

      final card2Result = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-retry-2',
      );

      expect(card2Result.state, equals(FileDownloadState.completed));
      expect(card2Result.savePath, isNotNull);
    });

    test('SHA256 校验失败后可重试', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final wrongHash = '0' * 64;

      final metadata = buildMetadata(
        fileName: 'retry_hash.txt',
        fileSize: content.length,
        hash: wrongHash,
        filePath: '/remote/retry_hash.txt',
        fromDeviceId: 'device-B',
      );

      // 第一次：hash 不匹配
      final card1 = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-hash-1',
      );
      expect(card1.state, equals(FileDownloadState.failed));

      // 第二次：用正确的 hash
      conn.dispose();
      conn = FakeConnection();

      final correctHash = sha256.convert(content).toString();
      final metadata2 = Map<String, dynamic>.from(metadata);
      metadata2['sha256'] = correctHash;

      final card2 = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata2,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-hash-2',
      );
      expect(card2.state, equals(FileDownloadState.completed));
    });
  });

  // ==============================================================
  // 7. 下载目录自动创建
  // ==============================================================
  group('下载目录', () {
    test('下载目录不存在时自动创建', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(content).toString();

      final nestedDir = p.join(tempDir.path, 'lan_downloads', 'sub', 'dir');

      final metadata = buildMetadata(
        fileName: 'nested.txt',
        fileSize: content.length,
        hash: hash,
        filePath: '/remote/nested.txt',
        fromDeviceId: 'device-B',
      );

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: nestedDir,
        content: content,
        reqId: 'req-nested',
      );

      expect(card.state, equals(FileDownloadState.completed));
      expect(Directory(nestedDir).existsSync(), isTrue);
      expect(File(card.savePath!).existsSync(), isTrue);
    });
  });

  // ==============================================================
  // 8. 桌面端本地文件（initState 直接标记完成）
  // ==============================================================
  group('桌面端本地文件', () {
    test('本地文件 initState 直接标记为 completed', () async {
      final localFile = File(p.join(tempDir.path, 'local.txt'));
      await localFile.writeAsString('Local content');

      final metadata = buildMetadata(
        fileName: 'local.txt',
        fileSize: 13,
        hash: 'any',
        filePath: localFile.path,
        fromDeviceId: 'device-A',
      );

      final card = FakeFileMessageCard(
        messageMeta: FakeChatMessageMeta(metadata),
        connMgr: conn,
        downloadDir: tempDir.path,
        isLocalFile: true,
        isDesktop: true,
      );

      // initState 中已标记为 completed
      expect(card.state, equals(FileDownloadState.completed));
      expect(card.savePath, equals(localFile.path));
      // 不需要下载
      expect(card.stateHistory, isEmpty);
    });

    test('非桌面端本地文件仍需下载', () async {
      final metadata = buildMetadata(
        fileName: 'mobile.txt',
        fileSize: 10,
        hash: sha256.convert(sequentialBytes(10)).toString(),
        filePath: '/remote/mobile.txt',
        fromDeviceId: 'device-A',
      );

      final card = FakeFileMessageCard(
        messageMeta: FakeChatMessageMeta(metadata),
        connMgr: conn,
        downloadDir: tempDir.path,
        isLocalFile: true,
        isDesktop: false, // 移动端
      );

      // 移动端即使是本地文件也不会直接标记完成
      expect(card.state, equals(FileDownloadState.idle));
    });
  });

  // ==============================================================
  // 9. 特殊文件名
  // ==============================================================
  group('特殊文件名', () {
    test('中文文件名', () async {
      final content = Uint8List.fromList(utf8.encode('中文内容'));
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: '测试文件.txt',
        fileSize: content.length,
        hash: hash,
        filePath: '/remote/测试文件.txt',
        fromDeviceId: 'device-B',
      );

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-chinese',
      );

      expect(card.state, equals(FileDownloadState.completed));
      expect(card.savePath, endsWith('测试文件.txt'));
      expect(File(card.savePath!).readAsStringSync(), equals('中文内容'));
    });

    test('文件名包含空格', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'my file (1).txt',
        fileSize: content.length,
        hash: hash,
        filePath: '/remote/my file (1).txt',
        fromDeviceId: 'device-B',
      );

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-space',
      );

      expect(card.state, equals(FileDownloadState.completed));
      expect(card.savePath, endsWith('my file (1).txt'));
    });

    test('文件名包含 emoji', () async {
      final content = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: '文档 📄.pdf',
        fileSize: content.length,
        hash: hash,
        filePath: '/remote/文档 📄.pdf',
        fromDeviceId: 'device-B',
      );

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-emoji',
      );

      expect(card.state, equals(FileDownloadState.completed));
      expect(card.savePath, endsWith('文档 📄.pdf'));
    });
  });

  // ==============================================================
  // 10. 前端 UI 辅助方法测试
  // ==============================================================
  group('前端 UI 辅助方法', () {
    test('formatFileSize 正确格式化', () {
      expect(formatFileSize(0), equals('0 B'));
      expect(formatFileSize(500), equals('500.0 B'));
      expect(formatFileSize(1024), equals('1.0 KB'));
      expect(formatFileSize(1536), equals('1.5 KB'));
      expect(formatFileSize(1024 * 1024), equals('1.0 MB'));
      expect(formatFileSize(1024 * 1024 * 1024), equals('1.0 GB'));
      expect(formatFileSize(1024 * 1024 * 1024 * 2), equals('2.0 GB'));
    });

    test('metadata 字段降级读取', () {
      // 完整 metadata
      final full = FakeChatMessageMeta(buildMetadata(
        fileName: 'test.txt',
        fileSize: 1024,
        hash: 'abc',
        filePath: '/path',
        fromDeviceId: 'dev-1',
        mimeType: 'text/plain',
        role: 'user',
        employeeId: 'emp-1',
      ));
      expect(full.fileName, 'test.txt');
      expect(full.fileSize, 1024);
      expect(full.filePath, '/path');
      expect(full.fromDeviceId, 'dev-1');
      expect(full.mimeType, 'text/plain');
      expect(full.role, 'user');
      expect(full.employeeId, 'emp-1');

      // 空 metadata
      final empty = FakeChatMessageMeta({});
      expect(empty.fileName, '');
      expect(empty.fileSize, 0);
      expect(empty.filePath, '');
      expect(empty.fromDeviceId, '');
      expect(empty.sha256, '');
      expect(empty.mimeType, isNull);
      expect(empty.role, isNull);
      expect(empty.employeeId, isNull);
    });

    test('状态历史记录完整', () async {
      final content = Uint8List.fromList([1]);
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'history.txt',
        fileSize: 1,
        hash: hash,
        filePath: '/remote/history.txt',
        fromDeviceId: 'device-B',
      );

      final card = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-history',
      );

      // 验证完整的状态流转
      expect(card.stateHistory.first, equals(FileDownloadState.downloading));
      expect(card.stateHistory.last, equals(FileDownloadState.completed));
      expect(card.stateHistory.length, equals(2));
    });
  });

  // ==============================================================
  // 11. 端到端场景模拟
  // ==============================================================
  group('端到端场景', () {
    test('完整场景：用户点击下载 → 进度更新 → 完成 → 打开文件', () async {
      // 1. 准备：模拟一个 PDF 文件
      final content = Uint8List.fromList(List.generate(5000, (i) => i % 256));
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: '报告.pdf',
        fileSize: content.length,
        hash: hash,
        filePath: '/home/user/documents/报告.pdf',
        fromDeviceId: 'device-remote-PC',
        fileId: 'file-uuid-123',
        mimeType: 'application/pdf',
        role: 'assistant',
        employeeId: 'emp-ai-001',
      );

      // 2. 用户点击下载
      final msgMeta = FakeChatMessageMeta(metadata);
      final card = FakeFileMessageCard(
        messageMeta: msgMeta,
        connMgr: conn,
        downloadDir: tempDir.path,
      );

      expect(card.state, equals(FileDownloadState.idle));

      // 3. 开始下载
      final downloadFuture = card.startDownload();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 验证进入下载状态
      expect(card.state, equals(FileDownloadState.downloading));

      // 4. 模拟数据传输（分 5 个 chunk）
      const reqId = 'req-e2e';
      conn.emitStreamEvent(RpcStreamEvent.chunk('', requestId: reqId));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final chunkSize = 1000;
      for (var i = 0; i < 5; i++) {
        final start = i * chunkSize;
        final end = start + chunkSize;
        conn.pushBinaryChunk(BinaryChunkEvent(
          requestId: reqId,
          data: Uint8List.fromList(content.sublist(start, end)),
          isLast: i == 4,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }

      await Future<void>.delayed(const Duration(milliseconds: 5));
      conn.emitStreamEvent(RpcStreamEvent.done({
        'fileSize': content.length,
        'fileName': '报告.pdf',
      }, requestId: reqId));

      // 5. 等待下载完成
      await downloadFuture;

      // 6. 验证结果
      expect(card.state, equals(FileDownloadState.completed));
      expect(card.savePath, isNotNull);
      expect(card.savePath, endsWith('报告.pdf'));
      expect(File(card.savePath!).existsSync(), isTrue);
      expect(File(card.savePath!).readAsBytesSync(), equals(content));

      // 7. 验证进度
      expect(card.progressHistory.length, equals(5));
      expect(card.progressHistory.first, closeTo(0.2, 0.01));
      expect(card.progressHistory.last, closeTo(1.0, 0.01));

      // 8. 验证状态历史
      expect(card.stateHistory,
          [FileDownloadState.downloading, FileDownloadState.completed]);

      // 9. 验证文件大小显示
      expect(formatFileSize(msgMeta.fileSize), equals('4.9 KB'));
    });

    test('完整场景：网络断开 → 失败 → 网络恢复 → 重试成功', () async {
      final content = Uint8List.fromList(utf8.encode('重要文档'));
      final hash = sha256.convert(content).toString();

      final metadata = buildMetadata(
        fileName: 'important.txt',
        fileSize: content.length,
        hash: hash,
        filePath: '/remote/important.txt',
        fromDeviceId: 'device-B',
      );

      // --- 第一次尝试：网络中断 ---
      conn.isConnected = false;

      final card1 = FakeFileMessageCard(
        messageMeta: FakeChatMessageMeta(metadata),
        connMgr: conn,
        downloadDir: tempDir.path,
      );

      await card1.startDownload();

      expect(card1.state, equals(FileDownloadState.failed));
      expect(card1.errorMessage, contains('设备未连接'));
      expect(card1.stateHistory,
          [FileDownloadState.downloading, FileDownloadState.failed]);

      // --- 模拟网络恢复 ---
      conn.isConnected = true;

      // --- 第二次尝试：成功 ---
      final card2 = await _simulateFrontendDownload(
        conn: conn,
        metadata: metadata,
        downloadDir: tempDir.path,
        content: content,
        reqId: 'req-retry-success',
      );

      expect(card2.state, equals(FileDownloadState.completed));
      expect(card2.savePath, endsWith('important.txt'));
      expect(File(card2.savePath!).readAsStringSync(), equals('重要文档'));
    });

    test('完整场景：多个文件依次下载', () async {
      final files = <Map<String, dynamic>>[
        {
          'name': 'file1.txt',
          'content': utf8.encode('First file'),
        },
        {
          'name': 'file2.bin',
          'content': sequentialBytes(1024),
        },
        {
          'name': 'file3.json',
          'content': utf8.encode('{"key": "value"}'),
        },
      ];

      for (var i = 0; i < files.length; i++) {
        final content = Uint8List.fromList(files[i]['content'] as List<int>);
        final hash = sha256.convert(content).toString();

        final metadata = buildMetadata(
          fileName: files[i]['name'] as String,
          fileSize: content.length,
          hash: hash,
          filePath: '/remote/${files[i]['name']}',
          fromDeviceId: 'device-B',
        );

        // 每次下载需要新的 connection（streamController 已关闭）
        if (i > 0) {
          conn.dispose();
          conn = FakeConnection();
        }

        final card = await _simulateFrontendDownload(
          conn: conn,
          metadata: metadata,
          downloadDir: tempDir.path,
          content: content,
          reqId: 'req-multi-$i',
        );

        expect(card.state, equals(FileDownloadState.completed),
            reason: '文件 ${files[i]['name']} 下载应该成功');
        expect(File(card.savePath!).existsSync(), isTrue);
      }

      // 验证所有文件都存在
      for (final f in files) {
        expect(
          File(p.join(tempDir.path, f['name'] as String)).existsSync(),
          isTrue,
        );
      }
    });
  });
}
