/// Folder Skill 文件同步 E2E 测试
///
/// 启动真实的 WebSocket Server + 两个 Client，验证 Folder Skill 文件夹的
/// ZIP 打包 → 二进制流式传输 → 解压完整流程。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/agent/rpc/agent_rpc_config.dart';
import 'package:wenzagent/src/entity/lan_message.dart';
import 'package:wenzagent/src/lan/entity/client_info.dart';
import 'package:wenzagent/src/lan/impl/lan_client_service_impl.dart';
import 'package:wenzagent/src/lan/impl/lan_host_service_impl.dart';
import 'package:wenzagent/src/lan/lan_client_service.dart';
import 'package:wenzagent/src/rpc/remote_call_manager.dart';
import 'package:wenzagent/src/rpc/remote_call_server.dart';
import 'package:wenzagent/src/rpc/rpc_protocol.dart';

// ═══════════════════════════════════════════════════════════════
// 桥接 LanClientService（覆盖 deviceId）
// ═══════════════════════════════════════════════════════════════

class _BridgeClient implements LanClientService {
  final LanClientServiceImpl _real;
  final String _overrideId;
  _BridgeClient(this._real, this._overrideId);

  @override bool get isConnected => _real.isConnected;
  @override bool get isConnecting => _real.isConnecting;
  @override String get deviceId => _overrideId;
  @override String? get topic => _real.topic;
  @override String? get hostIp => _real.hostIp;
  @override int get hostPort => _real.hostPort;
  @override double get uploadProgress => _real.uploadProgress;
  @override double get downloadProgress => _real.downloadProgress;
  @override Stream<LanMessage> get messageStream => _real.messageStream;
  @override Future<void> connect(String hostIp, {int port = 9090}) =>
      _real.connect(hostIp, port: port);
  @override Future<void> disconnect() => _real.disconnect();
  @override Future<void> reconnect() => _real.reconnect();
  @override void sendMessage(String content) => _real.sendMessage(content);
  @override Future<bool> sendLanMessage(LanMessage message) =>
      _real.sendLanMessage(message);
  @override Future<String> uploadFile(String filePath) => _real.uploadFile(filePath);
  @override Future<void> downloadFile(String fileId, String savePath) =>
      _real.downloadFile(fileId, savePath);
  @override Future<ClientInfo> getClientInfo() => _real.getClientInfo();
  @override void sendBinaryMessage(dynamic data) => _real.sendBinaryMessage(data);
  @override Stream<BinaryChunkEvent> get binaryChunkStream =>
      _real.binaryChunkStream;
}

// ═══════════════════════════════════════════════════════════════
// 消息分发
// ═══════════════════════════════════════════════════════════════

Map<String, dynamic>? _parsePayload(String? content) {
  if (content == null) return null;
  try {
    return (jsonDecode(content) as Map<String, dynamic>)['payload']
        as Map<String, dynamic>?;
  } catch (_) {
    return null;
  }
}

StreamSubscription<LanMessage> _dispatch(
  LanClientService client,
  RemoteCallManager mgr,
  RemoteCallServer srv,
) {
  return client.messageStream.listen((msg) {
    if (msg.type == LanMessageType.rpcRequest) {
      final p = _parsePayload(msg.content);
      if (p != null) srv.handleRequest(p);
    } else {
      final p = _parsePayload(msg.content);
      if (p == null) return;
      switch (msg.type) {
        case LanMessageType.rpcResponse:
          mgr.handleResponse(p);
        case LanMessageType.rpcStreamChunk:
          mgr.handleStreamChunk(p);
        case LanMessageType.rpcStreamEnd:
          mgr.handleStreamEnd(p);
        case LanMessageType.rpcError:
          mgr.handleError(p);
        default:
          break;
      }
    }
  });
}

// ═══════════════════════════════════════════════════════════════
// 创建测试 Skill 文件夹
// ═══════════════════════════════════════════════════════════════

Future<String> _createSkillDir(String name, {List<String>? extras}) async {
  final base = await Directory.systemTemp.createTemp('st_$name');
  final dir = '${base.path}${Platform.pathSeparator}$name';
  await Directory(dir).create(recursive: true);
  await File('$dir${Platform.pathSeparator}SKILL.md')
      .writeAsString('# $name\nTest skill.');
  final prompt = '$dir${Platform.pathSeparator}prompt';
  await Directory(prompt).create(recursive: true);
  await File('$prompt${Platform.pathSeparator}translate.md')
      .writeAsString('Translate: {{input}}');
  final res = '$dir${Platform.pathSeparator}resources';
  await Directory(res).create(recursive: true);
  await File('$res${Platform.pathSeparator}dict.csv')
      .writeAsString('hello,你好\nworld,世界');
  if (extras != null) {
    for (final e in extras) {
      final parts = e.split('|');
      final fp = '$dir${Platform.pathSeparator}${parts[0]}';
      await File(fp).parent.create(recursive: true);
      await File(fp).writeAsString(parts.length > 1 ? parts[1] : 'extra');
    }
  }
  return dir;
}

// ═══════════════════════════════════════════════════════════════
// 测试用例（使用 group + setUp/tearDown，与 skill_sync_e2e_test.dart 一致）
// ═══════════════════════════════════════════════════════════════

void main() {
  group('Folder Skill 文件同步 E2E', () {
    late LanHostServiceImpl server;
    late String tempDir;
    int groupCounter = 0;

    // Per-test resources
    late String idA;
    late String idB;
    late _BridgeClient clientA;
    late _BridgeClient clientB;
    late RemoteCallManager mgrA;
    late RemoteCallServer srvA;
    late RemoteCallManager mgrB;
    late RemoteCallServer srvB;
    late StreamSubscription<LanMessage> subA;
    late StreamSubscription<LanMessage> subB;

    setUp(() async {
      groupCounter++;
      server = LanHostServiceImpl();
      tempDir =
          '${Directory.systemTemp.path}${p.separator}wenzagent_folder_e2e_$groupCounter';
      await Directory(tempDir).create(recursive: true);
      await server.start(port: 0, storageDir: tempDir);

      final port = server.port!;
      final topic = 'folder-e2e-$groupCounter';
      idA = 'fdev-a-$groupCounter';
      idB = 'fdev-b-$groupCounter';

      // Connect clients
      final rawA = LanClientServiceImpl(deviceId: idA, topic: topic);
      clientA = _BridgeClient(rawA, idA);
      await clientA.connect('127.0.0.1', port: port);
      for (var i = 0; i < 50; i++) {
        if (server.clients.any((c) => c.deviceId == idA)) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      final rawB = LanClientServiceImpl(deviceId: idB, topic: topic);
      clientB = _BridgeClient(rawB, idB);
      await clientB.connect('127.0.0.1', port: port);
      for (var i = 0; i < 50; i++) {
        if (server.clients.any((c) => c.deviceId == idB)) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      // RPC endpoints
      mgrA = RemoteCallManager(localDeviceId: idA, clientService: clientA);
      srvA = RemoteCallServer(clientService: clientA, localDeviceId: idA);
      mgrB = RemoteCallManager(localDeviceId: idB, clientService: clientB);
      srvB = RemoteCallServer(clientService: clientB, localDeviceId: idB);

      // Register methodPackSkillFolder on both servers
      for (final srv in [srvA, srvB]) {
        srv.register(AgentRpcConfig.methodPackSkillFolder, (params) async {
          final folderPath = params['folderPath'] as String;
          final skillId = params['skillId'] as String? ?? '';
          final dir = Directory(folderPath);
          if (!await dir.exists()) {
            return {'success': false, 'error': '文件夹不存在: $folderPath'};
          }
          final td = await Directory.systemTemp.createTemp('sp_');
          final folderName = dir.path.split(Platform.pathSeparator).last;
          final zipPath =
              '${td.path}${Platform.pathSeparator}${skillId.isNotEmpty ? skillId : folderName}.zip';

          final archive = Archive();
          await for (final entity in dir.list(recursive: true)) {
            if (entity is File) {
              final rel = entity.path
                  .substring(dir.path.length + 1)
                  .replaceAll('\\', '/');
              final bytes = await entity.readAsBytes();
              archive.addFile(ArchiveFile(rel, bytes.length, bytes));
            }
          }
          final zipData = ZipEncoder().encode(archive);
          await File(zipPath).writeAsBytes(zipData!);

          final zf = File(zipPath);
          final zs = await zf.length();
          final zh = sha256.convert(await zf.readAsBytes()).toString();
          return {
            'success': true,
            'zipFilePath': zipPath,
            'zipSize': zs,
            'sha256': zh,
            'skillId': skillId,
            'folderName': folderName,
          };
        });

        // Register methodReadFileStream for binary transfer
        final client = srv == srvA ? clientA : clientB;
        srv.registerStream(AgentRpcConfig.methodReadFileStream,
            (params) async* {
          final filePath = params['path'] as String;
          final chunkSize = params['chunkSize'] as int? ?? 64 * 1024;
          final requestId = params['_requestId'] as String? ?? '';
          final toDeviceId = params['_fromDeviceId'] as String? ?? '';

          final file = File(filePath);
          if (!await file.exists()) throw Exception('文件不存在: $filePath');
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

              final toIdBytes = utf8.encode(toDeviceId);
              final reqIdBytes = utf8.encode(requestId);
              final b = BytesBuilder();
              b.addByte(0x01);
              b.addByte(0x02);
              final toIdLen = ByteData(4)..setUint32(0, toIdBytes.length);
              b.add(toIdLen.buffer.asUint8List());
              b.add(toIdBytes);
              final reqIdLen = ByteData(4)..setUint32(0, reqIdBytes.length);
              b.add(reqIdLen.buffer.asUint8List());
              b.add(reqIdBytes);
              b.addByte(isLast ? 0x01 : 0x00);
              b.add(bytes);

              client.sendBinaryMessage(b.takeBytes());
              offset += bytes.length;
              yield RpcStreamEvent.chunk('');
            }
          } finally {
            await raf.close();
          }
          yield RpcStreamEvent.done({
            'fileSize': fileSize,
            'fileName': filePath.split(Platform.pathSeparator).last,
          });
        });
      }

      // Dispatch
      subA = _dispatch(clientA, mgrA, srvA);
      subB = _dispatch(clientB, mgrB, srvB);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    tearDown(() async {
      await subA.cancel();
      await subB.cancel();
      // Don't dispose managers - they may still have pending operations
      mgrA.dispose();
      mgrB.dispose();
      await clientA.disconnect();
      await clientB.disconnect();
      await server.stop();
      try {
        await Directory(tempDir).delete(recursive: true);
      } catch (_) {}
      // Give time for cleanup
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    // ── 辅助方法 ──

    Future<String> downloadAndUnpack({
      required String fromDeviceId,
      required String folderPath,
      required String skillId,
      required String localDir,
    }) async {
      // 1. Pack on remote
      final rpcMgr = fromDeviceId == idB ? mgrA : mgrB;
      final packResult = await rpcMgr.invoke(
        AgentRpcConfig.methodPackSkillFolder,
        {'folderPath': folderPath, 'skillId': skillId},
        toDeviceId: fromDeviceId,
      );
      final pack = Map<String, dynamic>.from(packResult['result'] as Map);
      if (pack['success'] != true) throw Exception('打包失败: ${pack['error']}');

      final zipFilePath = pack['zipFilePath'] as String;
      final zipHash = pack['sha256'] as String;
      final folderName = pack['folderName'] as String;

      // 2. Download via binary stream
      final td = await Directory.systemTemp.createTemp('ss_');
      final tempZip = '${td.path}${Platform.pathSeparator}$skillId.zip';

      final result = rpcMgr.invokeStreamWithId(
        AgentRpcConfig.methodReadFileStream,
        {'path': zipFilePath},
        toDeviceId: fromDeviceId,
        timeout: 0,
      );
      final reqId = result.requestId;
      final sink = File(tempZip).openWrite();
      // Binary frames arrive at the requesting client
      final binaryClient = rpcMgr == mgrA ? clientA : clientB;
      final binarySub = binaryClient.binaryChunkStream.listen((chunk) {
        if (chunk.requestId == reqId) sink.add(chunk.data);
      });

      try {
        await for (final event in result.stream) {
          if (event.isDone) break;
        }
      } finally {
        await binarySub.cancel();
        await sink.close();
      }

      // 3. Verify hash
      final savedBytes = await File(tempZip).readAsBytes();
      final actualHash = sha256.convert(savedBytes).toString();
      if (actualHash != zipHash) throw Exception('ZIP 校验失败');

      // 4. Unpack
      final targetDir = '$localDir${Platform.pathSeparator}$folderName';
      final target = Directory(targetDir);
      if (await target.exists()) await target.delete(recursive: true);
      await target.create(recursive: true);

      final archive = ZipDecoder().decodeBytes(savedBytes);
      for (final file in archive) {
        final name = file.name;
        // Skip empty or directory-only entries
        if (name.isEmpty) continue;

        final fp = '$targetDir${Platform.pathSeparator}'
            '${name.replaceAll('/', Platform.pathSeparator)}';
        if (file.isFile) {
          final f = File(fp);
          await f.parent.create(recursive: true);
          await f.writeAsBytes(file.content as List<int>);
        } else {
          await Directory(fp).create(recursive: true);
        }
      }

      // 5. Cleanup temp
      try { await td.delete(recursive: true); } catch (_) {}

      return targetDir;
    }

    // ── 测试用例 ──

    test('打包 Skill 文件夹为 ZIP', timeout: const Timeout(Duration(seconds: 60)),
        () async {
      final skillDir = await _createSkillDir('translator');

      // A 调用 B（跨设备 RPC）
      final result = await mgrA.invoke(
        AgentRpcConfig.methodPackSkillFolder,
        {'folderPath': skillDir, 'skillId': 'skill-001'},
        toDeviceId: idB,
      );

      final data = Map<String, dynamic>.from(result['result'] as Map);
      expect(data['success'], isTrue);
      expect(data['zipFilePath'], isNotEmpty);
      expect(data['zipSize'], greaterThan(0));
      expect(data['sha256'], isNotEmpty);
      expect(data['folderName'], equals('translator'));

      final zipFile = File(data['zipFilePath'] as String);
      expect(await zipFile.exists(), isTrue);
    });

    test('跨设备传输 ZIP 并解压', timeout: const Timeout(Duration(seconds: 60)),
        () async {
      final skillDir = await _createSkillDir('translator');
      final localDir =
          '${Directory.systemTemp.path}${Platform.pathSeparator}sk_${const Uuid().v4().substring(0, 8)}';

      final targetDir = await downloadAndUnpack(
        fromDeviceId: idA,
        folderPath: skillDir,
        skillId: 'skill-002',
        localDir: localDir,
      );

      // Verify structure
      expect(await Directory(targetDir).exists(), isTrue);

      final skillMd = File('$targetDir${Platform.pathSeparator}SKILL.md');
      expect(await skillMd.exists(), isTrue, reason: 'SKILL.md should exist in $targetDir');
      expect(await skillMd.readAsString(), contains('translator'));

      final promptFile =
          File('$targetDir${Platform.pathSeparator}prompt${Platform.pathSeparator}translate.md');
      expect(await promptFile.exists(), isTrue);
      expect(await promptFile.readAsString(), contains('{{input}}'));

      final dictFile =
          File('$targetDir${Platform.pathSeparator}resources${Platform.pathSeparator}dict.csv');
      expect(await dictFile.exists(), isTrue);
      expect(await dictFile.readAsString(), contains('hello,你好'));

      // Cleanup
      try { await Directory(localDir).delete(recursive: true); } catch (_) {}
    });

    test('大文件传输', timeout: const Timeout(Duration(seconds: 60)), () async {
      final skillDir = await _createSkillDir('bigskill', extras: [
        'resources/large.bin|${'A' * 200000}',
      ]);
      final localDir =
          '${Directory.systemTemp.path}${Platform.pathSeparator}sk_${const Uuid().v4().substring(0, 8)}';

      final targetDir = await downloadAndUnpack(
        fromDeviceId: idA,
        folderPath: skillDir,
        skillId: 'skill-big',
        localDir: localDir,
      );

      final bigFile = File(
          '$targetDir${Platform.pathSeparator}resources${Platform.pathSeparator}large.bin');
      expect(await bigFile.exists(), isTrue);
      expect((await bigFile.readAsString()).length, equals(200000));

      try { await Directory(localDir).delete(recursive: true); } catch (_) {}
    });

    test('解压覆盖已有目录', timeout: const Timeout(Duration(seconds: 60)),
        () async {
      final skillDir = await _createSkillDir('overwrite-test');
      final localDir =
          '${Directory.systemTemp.path}${Platform.pathSeparator}sk_${const Uuid().v4().substring(0, 8)}';

      // Create old content
      final oldDir = '$localDir${Platform.pathSeparator}overwrite-test';
      await Directory(oldDir).create(recursive: true);
      await File('$oldDir${Platform.pathSeparator}old.txt')
          .writeAsString('old content');

      final targetDir = await downloadAndUnpack(
        fromDeviceId: idA,
        folderPath: skillDir,
        skillId: 'skill-ow',
        localDir: localDir,
      );

      expect(await Directory(targetDir).exists(), isTrue);
      final skillMd = File('$targetDir${Platform.pathSeparator}SKILL.md');
      expect(await skillMd.exists(), isTrue);

      final oldFile = File('$targetDir${Platform.pathSeparator}old.txt');
      expect(await oldFile.exists(), isFalse);

      try { await Directory(localDir).delete(recursive: true); } catch (_) {}
    });

    test('不存在的文件夹打包返回失败',
        timeout: const Timeout(Duration(seconds: 30)), () async {
      // A 调用 B（跨设备 RPC）
      final result = await mgrA.invoke(
        AgentRpcConfig.methodPackSkillFolder,
        {'folderPath': '/nonexistent/path/skill', 'skillId': 'skill-err'},
        toDeviceId: idB,
      );

      final data = Map<String, dynamic>.from(result['result'] as Map);
      expect(data['success'], isFalse);
      expect(data['error'], contains('文件夹不存在'));
    });
  });
}
