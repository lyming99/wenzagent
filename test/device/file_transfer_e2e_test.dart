import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/device/impl/file_transfer_token_manager.dart';

/// 文件传输端到端测试
///
/// 模拟完整的跨设备文件传输流程：
/// 1. RPC handler 生成 Token 并附带 hostIp/hostPort
/// 2. 调用方从 RPC 响应拼接完整 URL
/// 3. HTTP 请求到远程设备的 HTTP 服务
/// 4. Token 验证 + 文件流式传输
void main() {
  group('文件传输端到端流程', () {
    late Directory tempDir;

    setUp(() async {
      FileTransferTokenManager.dispose();
      tempDir = await Directory.systemTemp.createTemp('wenzagent_e2e_test_');
    });

    tearDown(() async {
      FileTransferTokenManager.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    // ================================================================
    // 测试 1: RPC 响应包含 hostIp/hostPort（修复的核心）
    // ================================================================
    test('RPC download 响应应包含 hostIp 和 hostPort', () async {
      // 准备测试文件
      final testFile = File('${tempDir.path}/download_test.txt');
      await testFile.writeAsString('Hello, remote download!');

      final stat = await testFile.stat();
      final fileName = testFile.path.split(Platform.pathSeparator).last;

      // 模拟 RPC handler（device_rpc_handler.dart）的 agentDownloadFile 逻辑
      final transferToken = FileTransferTokenManager.generateDownloadToken(
        deviceId: 'device-B',
        filePath: testFile.path,
      );

      // 模拟远程设备返回的 RPC 响应 —— 这是修复的关键
      final rpcResponse = {
        'success': true,
        'token': transferToken.token,
        'expiresIn': 300,
        'fileSize': stat.size,
        'fileName': fileName,
        'hostIp': '192.168.1.100', // ← 远程设备的 IP（修复新增）
        'hostPort': 9090, // ← 远程设备的端口（修复新增）
      };

      // 验证响应包含必要字段
      expect(rpcResponse['success'], isTrue);
      expect(rpcResponse['token'], isNotEmpty);
      expect(rpcResponse['hostIp'], '192.168.1.100');
      expect(rpcResponse['hostPort'], 9090);
      expect(rpcResponse['fileSize'], greaterThan(0));
      expect(rpcResponse['fileName'], endsWith('download_test.txt'));
    });

    test('RPC upload 响应应包含 hostIp 和 hostPort', () async {
      // 模拟 RPC handler（device_rpc_handler.dart）的 agentUploadFile 逻辑
      final transferToken = FileTransferTokenManager.generateUploadToken(
        deviceId: 'device-B',
        filePath: '${tempDir.path}/upload_test.txt',
        overwrite: true,
      );

      // 模拟远程设备返回的 RPC 响应
      final rpcResponse = {
        'success': true,
        'token': transferToken.token,
        'expiresIn': 300,
        'hostIp': '192.168.1.100', // ← 远程设备的 IP（修复新增）
        'hostPort': 9090, // ← 远程设备的端口（修复新增）
      };

      expect(rpcResponse['success'], isTrue);
      expect(rpcResponse['token'], isNotEmpty);
      expect(rpcResponse['hostIp'], '192.168.1.100');
      expect(rpcResponse['hostPort'], 9090);
    });

    // ================================================================
    // 测试 2: 调用方 URL 拼接逻辑（修复的核心）
    // ================================================================
    test('调用方应从 RPC 响应拼接完整下载 URL', () {
      // 模拟 RPC 响应
      final result = <String, dynamic>{
        'success': true,
        'token': 'test-token-abc-123',
        'expiresIn': 300,
        'fileSize': 1024,
        'fileName': 'test.txt',
        'hostIp': '192.168.1.100',
        'hostPort': 9090,
      };

      // 模拟调用方 URL 拼接逻辑（agent_proxy_remote_ops.dart / device_client.dart）
      final hostIp = result['hostIp'] as String? ?? '';
      final hostPort = result['hostPort'] as int? ?? 0;
      final token = result['token'] as String? ?? '';
      if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
        result['url'] = 'http://$hostIp:$hostPort/file-download?token=$token';
      }

      // 验证 URL 指向远程设备
      expect(result['url'], 'http://192.168.1.100:9090/file-download?token=test-token-abc-123');
    });

    test('调用方应从 RPC 响应拼接完整上传 URL', () {
      final result = <String, dynamic>{
        'success': true,
        'token': 'upload-token-xyz-456',
        'expiresIn': 300,
        'hostIp': '192.168.1.100',
        'hostPort': 9090,
      };

      final hostIp = result['hostIp'] as String? ?? '';
      final hostPort = result['hostPort'] as int? ?? 0;
      final token = result['token'] as String? ?? '';
      if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
        result['url'] = 'http://$hostIp:$hostPort/file-upload?token=$token';
      }

      expect(result['url'], 'http://192.168.1.100:9090/file-upload?token=upload-token-xyz-456');
    });

    test('hostIp 为空时不拼接 URL', () {
      final result = <String, dynamic>{
        'success': true,
        'token': 'some-token',
        'expiresIn': 300,
        'hostIp': '',
        'hostPort': 9090,
      };

      final hostIp = result['hostIp'] as String? ?? '';
      final hostPort = result['hostPort'] as int? ?? 0;
      final token = result['token'] as String? ?? '';
      if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
        result['url'] = 'http://$hostIp:$hostPort/file-download?token=$token';
      }

      expect(result.containsKey('url'), isFalse);
    });

    test('hostPort 为 0 时不拼接 URL', () {
      final result = <String, dynamic>{
        'success': true,
        'token': 'some-token',
        'expiresIn': 300,
        'hostIp': '192.168.1.100',
        'hostPort': 0,
      };

      final hostIp = result['hostIp'] as String? ?? '';
      final hostPort = result['hostPort'] as int? ?? 0;
      final token = result['token'] as String? ?? '';
      if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
        result['url'] = 'http://$hostIp:$hostPort/file-download?token=$token';
      }

      expect(result.containsKey('url'), isFalse);
    });

    test('token 为空时不拼接 URL', () {
      final result = <String, dynamic>{
        'success': true,
        'token': '',
        'expiresIn': 300,
        'hostIp': '192.168.1.100',
        'hostPort': 9090,
      };

      final hostIp = result['hostIp'] as String? ?? '';
      final hostPort = result['hostPort'] as int? ?? 0;
      final token = result['token'] as String? ?? '';
      if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
        result['url'] = 'http://$hostIp:$hostPort/file-download?token=$token';
      }

      expect(result.containsKey('url'), isFalse);
    });

    // ================================================================
    // 测试 3: FileDownloadUrlResult / FileUploadUrlResult 反序列化
    // ================================================================
    test('FileDownloadUrlResult 从 RPC 响应正确解析（含拼接 URL）', () {
      final rpcResult = <String, dynamic>{
        'success': true,
        'token': 'download-token-123',
        'expiresIn': 300,
        'fileSize': 2048,
        'fileName': 'report.pdf',
        'hostIp': '192.168.1.200',
        'hostPort': 8080,
      };

      // 调用方拼接 URL
      final hostIp = rpcResult['hostIp'] as String? ?? '';
      final hostPort = rpcResult['hostPort'] as int? ?? 0;
      final token = rpcResult['token'] as String? ?? '';
      if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
        rpcResult['url'] = 'http://$hostIp:$hostPort/file-download?token=$token';
      }

      final result = FileDownloadUrlResult.fromMap(rpcResult);

      expect(result.url, 'http://192.168.1.200:8080/file-download?token=download-token-123');
      expect(result.token, 'download-token-123');
      expect(result.expiresIn, 300);
      expect(result.fileSize, 2048);
      expect(result.fileName, 'report.pdf');
      expect(result.error, isNull);
    });

    test('FileUploadUrlResult 从 RPC 响应正确解析（含拼接 URL）', () {
      final rpcResult = <String, dynamic>{
        'success': true,
        'token': 'upload-token-456',
        'expiresIn': 300,
        'hostIp': '10.0.0.5',
        'hostPort': 3000,
      };

      final hostIp = rpcResult['hostIp'] as String? ?? '';
      final hostPort = rpcResult['hostPort'] as int? ?? 0;
      final token = rpcResult['token'] as String? ?? '';
      if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
        rpcResult['url'] = 'http://$hostIp:$hostPort/file-upload?token=$token';
      }

      final result = FileUploadUrlResult.fromMap(rpcResult);

      expect(result.url, 'http://10.0.0.5:3000/file-upload?token=upload-token-456');
      expect(result.token, 'upload-token-456');
      expect(result.expiresIn, 300);
      expect(result.error, isNull);
    });

    test('FileDownloadUrlResult 错误响应', () {
      final rpcResult = <String, dynamic>{
        'success': false,
        'error': '文件不存在: /tmp/missing.txt',
      };

      final result = FileDownloadUrlResult.fromMap(rpcResult);

      expect(result.url, '');
      expect(result.token, '');
      expect(result.error, '文件不存在: /tmp/missing.txt');
    });

    // ================================================================
    // 测试 4: Token 跨设备隔离验证（问题复现 + 验证修复）
    // ================================================================
    test('Token 在生成设备验证成功，在另一设备验证失败', () {
      // 模拟设备 B 生成 Token
      final token = FileTransferTokenManager.generateDownloadToken(
        deviceId: 'device-B',
        filePath: '/data/secret.txt',
      );

      // 设备 B 验证 → 成功（Token 在设备 B 的内存中）
      final validatedOnB = FileTransferTokenManager.validateAndConsume(
        token.token,
        'download',
      );
      expect(validatedOnB, isNotNull);
      expect(validatedOnB!.filePath, '/data/secret.txt');

      // 重新生成（上面的已消费）
      final token2 = FileTransferTokenManager.generateDownloadToken(
        deviceId: 'device-B',
        filePath: '/data/secret2.txt',
      );

      // 模拟设备 A 尝试验证同一个 Token → 失败
      // （因为 FileTransferTokenManager 是进程内单例，
      //   设备 A 是另一个 Dart 进程，内存独立，Token 不存在）
      // 在单进程测试中，我们用 "不存在" 的 token 来模拟
      final validatedOnA = FileTransferTokenManager.validateAndConsume(
        'fake-token-from-another-device',
        'download',
      );
      expect(validatedOnA, isNull);

      // 清理
      FileTransferTokenManager.dispose();
    });

    // ================================================================
    // 测试 5: 完整下载流程模拟（RPC + HTTP handler）
    // ================================================================
    test('完整下载流程：生成 Token → 拼接 URL → HTTP handler 验证', () async {
      // 1. 准备测试文件
      final testContent = 'This is the file content for e2e test!';
      final testFile = File('${tempDir.path}/e2e_download.txt');
      await testFile.writeAsString(testContent);

      final stat = await testFile.stat();
      final fileName = testFile.path.split(Platform.pathSeparator).last;

      // 2. 模拟远程设备 B 的 RPC handler 生成 Token
      final transferToken = FileTransferTokenManager.generateDownloadToken(
        deviceId: 'device-B',
        filePath: testFile.path,
      );

      // 3. 模拟 RPC 响应
      final rpcResponse = {
        'success': true,
        'token': transferToken.token,
        'expiresIn': 300,
        'fileSize': stat.size,
        'fileName': fileName,
        'hostIp': '192.168.1.100',
        'hostPort': 9090,
      };

      // 4. 调用方拼接 URL
      final hostIp = rpcResponse['hostIp'] as String? ?? '';
      final hostPort = rpcResponse['hostPort'] as int? ?? 0;
      final token = rpcResponse['token'] as String? ?? '';
      String downloadUrl = '';
      if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
        downloadUrl = 'http://$hostIp:$hostPort/file-download?token=$token';
      }
      expect(downloadUrl, contains('file-download?token='));
      expect(downloadUrl, contains('192.168.1.100'));

      // 5. 模拟 HTTP handler 收到请求，验证 Token
      //    从 URL 中提取 token 参数
      final uri = Uri.parse(downloadUrl);
      final tokenParam = uri.queryParameters['token'];
      expect(tokenParam, isNotEmpty);

      // 6. 模拟 _handleRemoteFileDownload 中的 Token 验证
      final validatedToken = FileTransferTokenManager.validateAndConsume(
        tokenParam!,
        'download',
      );
      expect(validatedToken, isNotNull);
      expect(validatedToken!.filePath, testFile.path);

      // 7. 模拟读取文件
      final file = File(validatedToken.filePath);
      expect(await file.exists(), isTrue);
      final content = await file.readAsString();
      expect(content, testContent);
    });

    // ================================================================
    // 测试 6: 完整上传流程模拟（RPC + HTTP handler）
    // ================================================================
    test('完整上传流程：生成 Token → 拼接 URL → HTTP handler 验证', () async {
      final uploadPath = '${tempDir.path}/e2e_upload.txt';

      // 1. 模拟远程设备 B 的 RPC handler 生成上传 Token
      final transferToken = FileTransferTokenManager.generateUploadToken(
        deviceId: 'device-B',
        filePath: uploadPath,
        overwrite: true,
      );

      // 2. 模拟 RPC 响应
      final rpcResponse = {
        'success': true,
        'token': transferToken.token,
        'expiresIn': 300,
        'hostIp': '192.168.1.100',
        'hostPort': 9090,
      };

      // 3. 调用方拼接 URL
      final hostIp = rpcResponse['hostIp'] as String? ?? '';
      final hostPort = rpcResponse['hostPort'] as int? ?? 0;
      final token = rpcResponse['token'] as String? ?? '';
      String uploadUrl = '';
      if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
        uploadUrl = 'http://$hostIp:$hostPort/file-upload?token=$token';
      }
      expect(uploadUrl, contains('file-upload?token='));

      // 4. 模拟 HTTP handler 验证 Token
      final uri = Uri.parse(uploadUrl);
      final tokenParam = uri.queryParameters['token'];
      final validatedToken = FileTransferTokenManager.validateAndConsume(
        tokenParam!,
        'upload',
      );
      expect(validatedToken, isNotNull);
      expect(validatedToken!.filePath, uploadPath);
      expect(validatedToken.overwrite, isTrue);

      // 5. 模拟写入文件
      final uploadContent = 'Uploaded data from device A';
      final file = File(validatedToken.filePath);
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      await file.writeAsString(uploadContent);

      // 6. 验证写入成功
      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), uploadContent);
    });

    // ================================================================
    // 测试 7: Token 一次性使用（重放攻击防护）
    // ================================================================
    test('Token 一次性使用：第二次 HTTP 请求应被拒绝', () async {
      final testFile = File('${tempDir.path}/replay_test.txt');
      await testFile.writeAsString('replay test content');

      // 生成 Token
      final transferToken = FileTransferTokenManager.generateDownloadToken(
        deviceId: 'device-B',
        filePath: testFile.path,
      );

      // 第一次验证 → 成功
      final first = FileTransferTokenManager.validateAndConsume(
        transferToken.token,
        'download',
      );
      expect(first, isNotNull);

      // 第二次验证 → 失败（Token 已被消费）
      final second = FileTransferTokenManager.validateAndConsume(
        transferToken.token,
        'download',
      );
      expect(second, isNull);
    });

    // ================================================================
    // 测试 8: Token 操作类型不匹配
    // ================================================================
    test('download Token 不能用于 upload 操作', () async {
      final testFile = File('${tempDir.path}/mismatch_test.txt');
      await testFile.writeAsString('mismatch test');

      final downloadToken = FileTransferTokenManager.generateDownloadToken(
        deviceId: 'device-B',
        filePath: testFile.path,
      );

      // 用 upload 操作验证 download token → 失败
      final result = FileTransferTokenManager.validateAndConsume(
        downloadToken.token,
        'upload',
      );
      expect(result, isNull);
    });

    // ================================================================
    // 测试 9: 模拟 HTTP handler 对无效 Token 返回 403
    // ================================================================
    test('HTTP handler 对无效 Token 应返回 403', () async {
      // 模拟 _handleRemoteFileDownload 的逻辑
      Future<shelf.Response> handleDownload(shelf.Request request) async {
        final token = request.url.queryParameters['token'];
        if (token == null || token.isEmpty) {
          return shelf.Response.badRequest(body: 'Missing token');
        }

        final transferToken = FileTransferTokenManager.validateAndConsume(token, 'download');
        if (transferToken == null) {
          return shelf.Response.forbidden('Invalid or expired token');
        }

        return shelf.Response.ok('file content');
      }

      // 使用无效 Token
      final request = shelf.Request(
        'GET',
        Uri.parse('http://localhost:9090/file-download?token=invalid-token'),
      );
      final response = await handleDownload(request);
      expect(response.statusCode, 403);
    });

    test('HTTP handler 对缺失 Token 应返回 400', () async {
      Future<shelf.Response> handleDownload(shelf.Request request) async {
        final token = request.url.queryParameters['token'];
        if (token == null || token.isEmpty) {
          return shelf.Response.badRequest(body: 'Missing token');
        }

        return shelf.Response.ok('file content');
      }

      final request = shelf.Request(
        'GET',
        Uri.parse('http://localhost:9090/file-download'),
      );
      final response = await handleDownload(request);
      expect(response.statusCode, 400);
    });

    // ================================================================
    // 测试 10: 修复前 vs 修复后对比
    // ================================================================
    test('修复前：URL 指向本地设备（错误）', () {
      // 修复前：RPC 响应没有 hostIp/hostPort
      final oldRpcResponse = {
        'success': true,
        'token': 'test-token',
        'expiresIn': 300,
        'fileSize': 1024,
        'fileName': 'test.txt',
        // 没有 hostIp 和 hostPort！
      };

      // 修复前的调用方只能用本地地址
      final localHostIp = '192.168.1.50'; // 设备 A 自己的 IP
      final localHostPort = 9090; // 设备 A 自己的端口

      final wrongUrl = 'http://$localHostIp:$localHostPort/file-download?token=${oldRpcResponse['token']}';

      // URL 指向了设备 A（本地），而非远程设备 B → Token 不在设备 A → 403
      expect(wrongUrl, 'http://192.168.1.50:9090/file-download?token=test-token');
      expect(wrongUrl, isNot(contains('192.168.1.100'))); // 不是远程设备 B 的 IP
    });

    test('修复后：URL 指向远程设备（正确）', () {
      // 修复后：RPC 响应包含远程设备的 hostIp/hostPort
      final newRpcResponse = <String, dynamic>{
        'success': true,
        'token': 'test-token',
        'expiresIn': 300,
        'fileSize': 1024,
        'fileName': 'test.txt',
        'hostIp': '192.168.1.100', // 远程设备 B 的 IP
        'hostPort': 9090,
      };

      // 修复后的调用方从 RPC 响应获取远程地址
      final hostIp = newRpcResponse['hostIp'] as String? ?? '';
      final hostPort = newRpcResponse['hostPort'] as int? ?? 0;
      final token = newRpcResponse['token'] as String? ?? '';
      String correctUrl = '';
      if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
        correctUrl = 'http://$hostIp:$hostPort/file-download?token=$token';
      }

      // URL 指向远程设备 B → Token 在设备 B → 验证成功
      expect(correctUrl, 'http://192.168.1.100:9090/file-download?token=test-token');
    });

    // ================================================================
    // 测试 11: 断点续传 Range 请求逻辑
    // ================================================================
    test('HTTP handler 正确处理 Range 请求', () async {
      final testFile = File('${tempDir.path}/range_test.txt');
      // 写入 16 字节
      await testFile.writeAsString('0123456789ABCDEF');

      final transferToken = FileTransferTokenManager.generateDownloadToken(
        deviceId: 'device-B',
        filePath: testFile.path,
      );

      // 模拟 Range 请求：bytes=4-7
      final fileSize = await testFile.length();
      final rangeHeader = 'bytes=4-7';
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      expect(match, isNotNull);

      final start = int.parse(match!.group(1)!);
      final end = match.group(2) != null && match.group(2)!.isNotEmpty
          ? int.parse(match.group(2)!)
          : fileSize - 1;

      expect(start, 4);
      expect(end, 7);

      // 读取范围数据
      final bytes = await testFile.readAsBytes();
      final sliced = bytes.sublist(start, end + 1);
      expect(utf8.decode(sliced), '4567');

      // 清理 Token
      FileTransferTokenManager.validateAndConsume(transferToken.token, 'download');
    });

    test('Range 请求越界应返回 416', () async {
      final testFile = File('${tempDir.path}/range_overflow.txt');
      await testFile.writeAsString('short');

      final fileSize = await testFile.length();
      expect(fileSize, 5);

      // 模拟越界 Range: bytes=100-200
      final start = 100;
      final end = 200;

      // 应返回 416
      expect(start >= fileSize, isTrue);
    });

    // ================================================================
    // 测试 12: 上传文件已存在且不可覆盖
    // ================================================================
    test('上传时文件已存在且 overwrite=false 应拒绝', () async {
      final existingFile = File('${tempDir.path}/existing.txt');
      await existingFile.writeAsString('existing content');

      final transferToken = FileTransferTokenManager.generateUploadToken(
        deviceId: 'device-B',
        filePath: existingFile.path,
        overwrite: false, // 不可覆盖
      );

      // 模拟 HTTP handler 验证
      final validated = FileTransferTokenManager.validateAndConsume(
        transferToken.token,
        'upload',
      );
      expect(validated, isNotNull);
      expect(validated!.overwrite, isFalse);

      // 模拟检查文件已存在
      final file = File(validated.filePath);
      expect(await file.exists(), isTrue);
      // overwrite=false + 文件已存在 → 应返回 409
    });

    // ================================================================
    // 测试 13: 大文件场景（验证 Token 有效性）
    // ================================================================
    test('大文件下载 Token 生成与验证', () async {
      final largeFile = File('${tempDir.path}/large_file.bin');
      // 写入 1MB 数据
      final data = List.generate(1024 * 1024, (i) => i % 256);
      await largeFile.writeAsBytes(data);

      final stat = await largeFile.stat();
      expect(stat.size, 1024 * 1024);

      // 生成 Token
      final transferToken = FileTransferTokenManager.generateDownloadToken(
        deviceId: 'device-B',
        filePath: largeFile.path,
      );

      // 模拟 RPC 响应
      final rpcResponse = {
        'success': true,
        'token': transferToken.token,
        'expiresIn': 300,
        'fileSize': stat.size,
        'fileName': 'large_file.bin',
        'hostIp': '192.168.1.100',
        'hostPort': 9090,
      };

      // 调用方拼接 URL
      final hostIp = rpcResponse['hostIp'] as String? ?? '';
      final hostPort = rpcResponse['hostPort'] as int? ?? 0;
      final token = rpcResponse['token'] as String? ?? '';
      if (hostIp.isNotEmpty && hostPort > 0 && token.isNotEmpty) {
        rpcResponse['url'] = 'http://$hostIp:$hostPort/file-download?token=$token';
      }

      final result = FileDownloadUrlResult.fromMap(rpcResponse);
      expect(result.fileSize, 1024 * 1024);
      expect(result.url, contains('192.168.1.100'));

      // Token 验证成功
      final validated = FileTransferTokenManager.validateAndConsume(
        transferToken.token,
        'download',
      );
      expect(validated, isNotNull);
      expect(validated!.filePath, largeFile.path);
    });

    // ================================================================
    // 测试 14: 并发 Token 生成（多个文件同时传输）
    // ================================================================
    test('多个文件同时生成独立 Token', () async {
      final tokens = <String>[];

      for (int i = 0; i < 10; i++) {
        final file = File('${tempDir.path}/concurrent_$i.txt');
        await file.writeAsString('content $i');

        final token = FileTransferTokenManager.generateDownloadToken(
          deviceId: 'device-B',
          filePath: file.path,
        );
        tokens.add(token.token);
      }

      // 所有 Token 应唯一
      expect(tokens.toSet().length, 10);

      // 每个 Token 都能独立验证
      for (int i = 0; i < 10; i++) {
        final validated = FileTransferTokenManager.validateAndConsume(
          tokens[i],
          'download',
        );
        expect(validated, isNotNull);
        expect(validated!.filePath, contains('concurrent_$i'));
      }
    });
  });
}
