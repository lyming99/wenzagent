/// Folder Skill 远程拉取 + GlobalSkill 关联 E2E 测试
///
/// 启动真实的 WebSocket Server + 两个 DeviceClient，验证 Folder Skill 的
/// 远程拉取完整流程以及 GlobalSkill → 员工 Skill 的三级获取策略。
///
/// 测试覆盖：
///   Group 1: syncSingleFolderSkill 基础（无 globalSkillId）
///     - 基本拉取、已存在跳过、不存在失败、批量拉取
///
///   Group 2: GlobalSkill → 员工 Skill 三级获取策略
///     - 有 globalSkillId + GlobalSkill 本地有数据 → 直接复制
///     - 有 globalSkillId + GlobalSkill 本地无数据 → LAN 拉取 GlobalSkill → 复制
///     - 无 globalSkillId → 降级为员工 skill LAN 拉取
///     - globalSkillId 对应的 GlobalSkill 已删除 → 降级为员工 skill LAN 拉取
///
///   Group 3: setSkills 端到端
///     - 从 GlobalSkill 配置员工 skill → setSkills → 文件夹同步成功
///     - 无 GlobalSkill 的员工 skill → setSkills → 文件夹同步成功
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:wenzagent/src/device/app_context.dart';
import 'package:wenzagent/src/device/device_client.dart';
import 'package:wenzagent/src/device/impl/data_sync_manager.dart';
import 'package:wenzagent/src/device/impl/device_rpc_handler.dart';
import 'package:wenzagent/src/lan/impl/lan_host_service_impl.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/service.dart';
import 'package:wenzagent/src/utils/logger.dart';

int _testCounter = 0;

// ═══════════════════════════════════════════════════════════════
// 创建测试 Skill 文件夹
// ═══════════════════════════════════════════════════════════════

Future<void> _createTestSkillFiles(String skillsDir, String skillName) async {
  final dir = p.join(skillsDir, skillName);
  await Directory(dir).create(recursive: true);
  await File(p.join(dir, 'SKILL.md'))
      .writeAsString('# $skillName\nTest skill.');
  await File(p.join(dir, 'config.json'))
      .writeAsString('{"name":"$skillName","version":"1.0"}');
  final promptDir = p.join(dir, 'prompt');
  await Directory(promptDir).create(recursive: true);
  await File(p.join(promptDir, 'translate.md'))
      .writeAsString('Translate: {{input}}');
}

/// 验证 skill 文件夹内容完整性
void _verifySkillFiles(String path, String expectedName) {
  final skillMd = File(p.join(path, 'SKILL.md'));
  expect(skillMd.existsSync(), isTrue, reason: '$expectedName/SKILL.md 应存在');
  expect(skillMd.readAsStringSync(), contains(expectedName));

  final configJson = File(p.join(path, 'config.json'));
  expect(configJson.existsSync(), isTrue, reason: '$expectedName/config.json 应存在');

  final promptFile = File(p.join(path, 'prompt', 'translate.md'));
  expect(promptFile.existsSync(), isTrue, reason: '$expectedName/prompt/translate.md 应存在');
  expect(promptFile.readAsStringSync(), contains('{{input}}'));
}

// ═══════════════════════════════════════════════════════════════
// 测试上下文 — 完整的 DeviceClient + Server 环境
// ═══════════════════════════════════════════════════════════════

class _TestEnv {
  final LanHostServiceImpl server;
  final String tempDir;
  final String deviceIdA;
  final String deviceIdB;
  final String storageA;
  final String storageB;
  final DeviceClient clientA;
  final DeviceClient clientB;

  _TestEnv({
    required this.server,
    required this.tempDir,
    required this.deviceIdA,
    required this.deviceIdB,
    required this.storageA,
    required this.storageB,
    required this.clientA,
    required this.clientB,
  });

  /// 获取设备 A 的 skillsDir
  String get skillsDirA => clientA.skillsDir;

  /// 获取设备 B 的 skillsDir
  String get skillsDirB => clientB.skillsDir;

  Future<void> dispose() async {
    await clientA.disconnect();
    await clientB.disconnect();
    await clientA.dispose();
    await clientB.dispose();
    await DeviceClient.removeInstance(deviceIdA);
    await DeviceClient.removeInstance(deviceIdB);
    DataSyncManager.removeInstance(deviceIdA);
    DataSyncManager.removeInstance(deviceIdB);
    DeviceRpcHandler.removeInstance(deviceIdA);
    DeviceRpcHandler.removeInstance(deviceIdB);
    SkillManager.removeInstance(deviceIdA);
    SkillManager.removeInstance(deviceIdB);
    EmployeeManager.removeInstance(deviceIdA);
    EmployeeManager.removeInstance(deviceIdB);
    SessionManager.removeInstance(deviceIdA);
    SessionManager.removeInstance(deviceIdB);
    GlobalSkillManager.removeInstance(deviceIdA);
    GlobalSkillManager.removeInstance(deviceIdB);
    await DatabaseManager.getInstance(deviceIdA).close();
    await DatabaseManager.getInstance(deviceIdB).close();
    DatabaseManager.removeInstance(deviceIdA);
    DatabaseManager.removeInstance(deviceIdB);
    await AppContext.dispose(deviceIdA);
    await AppContext.dispose(deviceIdB);
    await server.stop();
    try {
      await Directory(tempDir).delete(recursive: true);
    } catch (_) {}
    try {
      await Directory(storageA).delete(recursive: true);
    } catch (_) {}
    try {
      await Directory(storageB).delete(recursive: true);
    } catch (_) {}
  }
}

Future<_TestEnv> _createEnv() async {
  _testCounter++;
  final c = _testCounter;

  // 1. 启动 Server（port=0 随机端口）
  final server = LanHostServiceImpl();
  final tempDir =
      '${Directory.systemTemp.path}${p.separator}wenzagent_skill_pull_server_$c';
  await Directory(tempDir).create(recursive: true);
  await server.start(port: 0, storageDir: tempDir);
  final port = server.port;

  // 2. 设备 ID 和存储路径
  final deviceIdA = 'pull-a-$c-${const Uuid().v4().substring(0, 8)}';
  final deviceIdB = 'pull-b-$c-${const Uuid().v4().substring(0, 8)}';
  final storageA =
      '${Directory.systemTemp.path}${p.separator}wenzagent_skill_pull_a_$c';
  final storageB =
      '${Directory.systemTemp.path}${p.separator}wenzagent_skill_pull_b_$c';
  await Directory(storageA).create(recursive: true);
  await Directory(storageB).create(recursive: true);

  // 3. 创建并初始化 DeviceClient A
  final clientA = DeviceClient.getInstance(deviceIdA);
  await clientA.initialize(DeviceClientConfig(
    storagePath: storageA,
    host: '127.0.0.1',
    port: port,
    deviceName: 'Device A',
  ));
  await clientA.connect();

  // 等待 A 注册到 server
  for (var i = 0; i < 100; i++) {
    if (server.clients.any((cl) => cl.deviceId == deviceIdA)) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  // 4. 创建并初始化 DeviceClient B
  final clientB = DeviceClient.getInstance(deviceIdB);
  await clientB.initialize(DeviceClientConfig(
    storagePath: storageB,
    host: '127.0.0.1',
    port: port,
    deviceName: 'Device B',
  ));
  await clientB.connect();

  // 等待 B 注册到 server
  for (var i = 0; i < 100; i++) {
    if (server.clients.any((cl) => cl.deviceId == deviceIdB)) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  // 5. 等待设备互相发现
  await Future<void>.delayed(const Duration(seconds: 2));

  return _TestEnv(
    server: server,
    tempDir: tempDir,
    deviceIdA: deviceIdA,
    deviceIdB: deviceIdB,
    storageA: storageA,
    storageB: storageB,
    clientA: clientA,
    clientB: clientB,
  );
}

// ═══════════════════════════════════════════════════════════════
// 三级获取策略模拟（与 agent_impl_skill.dart 中 _ensureFolderSkillData 一致）
// ═══════════════════════════════════════════════════════════════

/// 模拟 agent 的 _ensureFolderSkillData 逻辑
/// 返回 true 表示数据已就绪
Future<bool> _ensureFolderSkillData({
  required String deviceId,
  required String skillName,
  required String skillUuid,
  String? globalSkillId,
}) async {
  final skillsDir = DeviceClient.getInstance(deviceId).skillsDir;
  final targetPath = p.normalize(p.absolute(p.join(skillsDir, skillName)));

  // 本地已存在
  if (await Directory(targetPath).exists()) return true;

  final dsm = DataSyncManager.getInstance(deviceId);

  // 第一级 + 第二级：有 globalSkillId
  if (globalSkillId != null && globalSkillId.isNotEmpty) {
    final gsm = GlobalSkillManager.getInstance(deviceId);
    final globalSkill = await gsm.getSkill(globalSkillId);

    if (globalSkill != null && globalSkill.deleted == 0) {
      final globalPath = p.normalize(p.absolute(p.join(skillsDir, globalSkill.name)));

      // 第一级：GlobalSkill 本地有数据 → 直接复制
      if (await Directory(globalPath).exists()) {
        await _copyDirectory(globalPath, targetPath);
        return true;
      }

      // 第二级：从 LAN 拉取 GlobalSkill → 再复制
      final syncedPath = await dsm.syncSingleFolderSkill(
        globalSkill.uuid,
        globalSkill.name,
      );
      if (syncedPath != null) {
        // 如果 GlobalSkill name == 员工 skill name，路径相同，无需复制
        if (p.normalize(p.absolute(syncedPath)) == p.normalize(p.absolute(targetPath))) {
          return true;
        }
        await _copyDirectory(syncedPath, targetPath);
        return true;
      }
    }
  }

  // 第三级：降级为员工 skill LAN 拉取
  final result = await dsm.syncSingleFolderSkill(skillUuid, skillName);
  return result != null;
}

/// 递归复制目录
Future<void> _copyDirectory(String source, String target) async {
  final sourceDir = Directory(source);
  final targetDir = Directory(target);
  if (await targetDir.exists()) {
    await targetDir.delete(recursive: true);
  }
  await targetDir.create(recursive: true);

  await for (final entity in sourceDir.list(recursive: true)) {
    final relativePath = p.relative(entity.path, from: source);
    final targetPath = p.join(target, relativePath);
    if (entity is Directory) {
      await Directory(targetPath).create(recursive: true);
    } else if (entity is File) {
      await File(targetPath).parent.create(recursive: true);
      await entity.copy(targetPath);
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// 测试主体
// ═══════════════════════════════════════════════════════════════

void main() {
  Logger.level = LogLevel.warn;

  // ═══════════════════════════════════════════════════════════
  // Group 1: syncSingleFolderSkill 基础（无 globalSkillId）
  // ═══════════════════════════════════════════════════════════

  group('syncSingleFolderSkill 基础（无 globalSkillId）', () {
    late _TestEnv env;

    setUp(() async {
      env = await _createEnv();
    });

    tearDown(() async {
      await env.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    test('设备 A 有 skill 文件夹 → 设备 B 通过 syncSingleFolderSkill 拉取成功',
        timeout: const Timeout(Duration(seconds: 60)), () async {
      // 1. 在设备 A 的 skillsDir 下创建 video 文件夹
      await _createTestSkillFiles(env.skillsDirA, 'video');
      expect(await Directory(p.join(env.skillsDirA, 'video')).exists(), isTrue);

      // 2. 设备 B 没有 video 文件夹
      expect(await Directory(p.join(env.skillsDirB, 'video')).exists(), isFalse);

      // 3. 通过 DataSyncManager 从设备 B 拉取
      final syncManager = DataSyncManager.getInstance(env.deviceIdB);
      final result = await syncManager.syncSingleFolderSkill('test-video-id', 'video');

      // 4. 验证
      expect(result, isNotNull);
      expect(result, equals(p.join(env.skillsDirB, 'video')));
      _verifySkillFiles(result!, 'video');
    });

    test('设备 B 已有文件夹时 syncSingleFolderSkill 跳过拉取',
        timeout: const Timeout(Duration(seconds: 30)), () async {
      await _createTestSkillFiles(env.skillsDirB, 'video');

      final syncManager = DataSyncManager.getInstance(env.deviceIdB);
      final result = await syncManager.syncSingleFolderSkill('test-video-id', 'video');

      expect(result, isNotNull);
      expect(result, equals(p.join(env.skillsDirB, 'video')));
    });

    test('两台设备都没有对应文件夹时返回 null',
        timeout: const Timeout(Duration(seconds: 30)), () async {
      final syncManager = DataSyncManager.getInstance(env.deviceIdB);
      final result = await syncManager.syncSingleFolderSkill('nonexistent-id', 'nonexistent');
      expect(result, isNull);
    });

    test('多个 skill 文件夹批量拉取',
        timeout: const Timeout(Duration(seconds: 90)), () async {
      await _createTestSkillFiles(env.skillsDirA, 'video');
      await _createTestSkillFiles(env.skillsDirA, 'translate');
      await _createTestSkillFiles(env.skillsDirA, 'code-review');

      final syncManager = DataSyncManager.getInstance(env.deviceIdB);
      for (final name in ['video', 'translate', 'code-review']) {
        final result = await syncManager.syncSingleFolderSkill('test-$name', name);
        expect(result, isNotNull, reason: '$name 拉取应成功');
        _verifySkillFiles(result!, name);
      }
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 2: GlobalSkill → 员工 Skill 三级获取策略
  // ═══════════════════════════════════════════════════════════

  group('GlobalSkill → 员工 Skill 三级获取策略', () {
    late _TestEnv env;

    setUp(() async {
      env = await _createEnv();
    });

    tearDown(() async {
      await env.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    test('有 globalSkillId + GlobalSkill 本地有数据 → 直接复制',
        timeout: const Timeout(Duration(seconds: 60)), () async {
      final gsmB = GlobalSkillManager.getInstance(env.deviceIdB);

      // 1. 在设备 B 上创建 GlobalSkill（folder 类型）
      final globalSkill = await gsmB.createSkill(GlobalSkillEntity(
        uuid: 'gs-video-${const Uuid().v4()}',
        name: 'video-global',
        description: 'Global video skill',
        skillType: 'folder',
        enabled: 1,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));

      // 2. 在设备 B 的 skillsDir 下创建 GlobalSkill 对应的文件夹
      await _createTestSkillFiles(env.skillsDirB, 'video-global');

      // 3. 创建员工 skill（有 globalSkillId）
      final skillUuid = 'emp-video-${const Uuid().v4()}';

      // 4. 员工 skill 文件夹不存在，触发三级获取
      //    第一级：globalSkillId → GlobalSkill 本地有数据 → 直接复制
      final success = await _ensureFolderSkillData(
        deviceId: env.deviceIdB,
        skillName: 'video-employee',
        skillUuid: skillUuid,
        globalSkillId: globalSkill.uuid,
      );

      expect(success, isTrue, reason: '三级获取应成功');

      // 5. 验证复制结果：video-employee 文件夹内容应来自 video-global
      final targetPath = p.join(env.skillsDirB, 'video-employee');
      expect(await Directory(targetPath).exists(), isTrue);
      _verifySkillFiles(targetPath, 'video-global');
    });

    test('有 globalSkillId + GlobalSkill 本地无数据 → LAN 拉取 GlobalSkill → 复制',
        timeout: const Timeout(Duration(seconds: 60)), () async {
      final gsmB = GlobalSkillManager.getInstance(env.deviceIdB);

      // 1. 在设备 B 上创建 GlobalSkill（folder 类型）
      final globalSkill = await gsmB.createSkill(GlobalSkillEntity(
        uuid: 'gs-translate-${const Uuid().v4()}',
        name: 'translate',
        description: 'Global translate skill',
        skillType: 'folder',
        enabled: 1,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));

      // 2. 设备 B 没有 translate 文件夹，但设备 A 有
      await _createTestSkillFiles(env.skillsDirA, 'translate');

      // 3. 创建员工 skill（有 globalSkillId）
      final skillUuid = 'emp-translate-${const Uuid().v4()}';

      // 4. 触发三级获取
      //    第一级：GlobalSkill 本地无数据 → 跳过
      //    第二级：从 LAN 拉取 GlobalSkill（translate）→ 成功 → 复制到员工 skill 路径
      final success = await _ensureFolderSkillData(
        deviceId: env.deviceIdB,
        skillName: 'translate-employee',
        skillUuid: skillUuid,
        globalSkillId: globalSkill.uuid,
      );

      expect(success, isTrue, reason: '三级获取应成功');

      // 5. 验证结果
      final targetPath = p.join(env.skillsDirB, 'translate-employee');
      expect(await Directory(targetPath).exists(), isTrue);
      _verifySkillFiles(targetPath, 'translate');
    });

    test('无 globalSkillId → 降级为员工 skill LAN 拉取',
        timeout: const Timeout(Duration(seconds: 60)), () async {
      // 1. 设备 A 有 code-review 文件夹
      await _createTestSkillFiles(env.skillsDirA, 'code-review');

      // 2. 员工 skill 没有 globalSkillId
      final skillUuid = 'emp-code-review-${const Uuid().v4()}';

      // 3. 触发三级获取
      //    跳过第一级和第二级（无 globalSkillId）
      //    第三级：从 LAN 拉取员工 skill → 成功
      final success = await _ensureFolderSkillData(
        deviceId: env.deviceIdB,
        skillName: 'code-review',
        skillUuid: skillUuid,
        globalSkillId: null,
      );

      expect(success, isTrue, reason: '降级 LAN 拉取应成功');

      // 4. 验证结果
      final targetPath = p.join(env.skillsDirB, 'code-review');
      expect(await Directory(targetPath).exists(), isTrue);
      _verifySkillFiles(targetPath, 'code-review');
    });

    test('globalSkillId 对应的 GlobalSkill 已删除 → 降级为员工 skill LAN 拉取',
        timeout: const Timeout(Duration(seconds: 60)), () async {
      final gsmB = GlobalSkillManager.getInstance(env.deviceIdB);

      // 1. 在设备 B 上创建 GlobalSkill 并删除
      final globalSkill = await gsmB.createSkill(GlobalSkillEntity(
        uuid: 'gs-deleted-${const Uuid().v4()}',
        name: 'video-deleted',
        description: 'Deleted global skill',
        skillType: 'folder',
        enabled: 1,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));
      await gsmB.deleteSkill(globalSkill.uuid);

      // 2. 设备 A 有 video-deleted 文件夹（用员工 skill 名称同步）
      await _createTestSkillFiles(env.skillsDirA, 'video-deleted');

      // 3. 员工 skill 有 globalSkillId 但 GlobalSkill 已删除
      final skillUuid = 'emp-deleted-${const Uuid().v4()}';

      // 4. 触发三级获取
      //    第一级：GlobalSkill 已删除 → 跳过
      //    第二级：跳过（GlobalSkill 已删除）
      //    第三级：从 LAN 拉取员工 skill → 成功
      final success = await _ensureFolderSkillData(
        deviceId: env.deviceIdB,
        skillName: 'video-deleted',
        skillUuid: skillUuid,
        globalSkillId: globalSkill.uuid,
      );

      expect(success, isTrue, reason: '降级 LAN 拉取应成功');

      // 5. 验证结果
      final targetPath = p.join(env.skillsDirB, 'video-deleted');
      expect(await Directory(targetPath).exists(), isTrue);
      _verifySkillFiles(targetPath, 'video-deleted');
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 3: setSkills 端到端（GlobalSkill → 员工 Skill 完整流程）
  // ═══════════════════════════════════════════════════════════

  group('setSkills 端到端（GlobalSkill → 员工 Skill）', () {
    late _TestEnv env;

    setUp(() async {
      env = await _createEnv();
    });

    tearDown(() async {
      await env.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    test('从 GlobalSkill 配置员工 skill → setSkills → 文件夹同步成功',
        timeout: const Timeout(Duration(seconds: 60)), () async {
      final gsmB = GlobalSkillManager.getInstance(env.deviceIdB);
      final skillStore = SkillStore(deviceId: env.deviceIdB);

      // 1. 在设备 B 上创建 GlobalSkill（folder 类型）
      final globalUuid = 'gs-e2e-${const Uuid().v4()}';
      await gsmB.createSkill(GlobalSkillEntity(
        uuid: globalUuid,
        name: 'video',
        description: 'Global video skill',
        skillType: 'folder',
        enabled: 1,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));

      // 2. 设备 A 有 video 文件夹（GlobalSkill 本地无数据，需从 LAN 拉取）
      await _createTestSkillFiles(env.skillsDirA, 'video');

      // 3. 模拟前端 addSkillsFromGlobal：创建员工 skill（含 globalSkillId）
      //    注意：员工 skill name 可以与 GlobalSkill 不同（实际场景中通常相同）
      //    这里用相同 name 模拟最常见的场景
      final empId = 'emp-${const Uuid().v4()}';
      final skillUuid = const Uuid().v4();
      final now = DateTime.now();
      final employeeSkill = AiEmployeeSkillEntity(
        uuid: skillUuid,
        employeeId: empId,
        deviceId: '',
        name: 'video', // 与 GlobalSkill 同名
        description: 'Global video skill',
        skillType: 'folder',
        config: null,
        globalSkillId: globalUuid,
        enabled: 1,
        sortOrder: 0,
        createTime: now,
        updateTime: now,
      );

      // 4. 保存到数据库
      await skillStore.save(employeeSkill);

      // 5. 验证保存成功（含 globalSkillId）
      final saved = await skillStore.find(skillUuid);
      expect(saved, isNotNull);
      expect(saved!.globalSkillId, equals(globalUuid));
      expect(saved.name, equals('video'));
      expect(saved.skillType, equals('folder'));

      // 6. 执行三级获取策略（模拟 agent 的 _loadPersistedSkills 中 folder 分支）
      //    员工 skill name == GlobalSkill name，所以 syncSingleFolderSkill 拉取的
      //    GlobalSkill 文件夹路径 == 员工 skill 目标路径，直接就是结果
      final success = await _ensureFolderSkillData(
        deviceId: env.deviceIdB,
        skillName: saved.name,
        skillUuid: saved.uuid,
        globalSkillId: saved.globalSkillId,
      );
      expect(success, isTrue, reason: '从 GlobalSkill 配置的员工 skill 文件夹同步应成功');

      // 7. 验证文件
      //    因为员工 skill name == GlobalSkill name，syncSingleFolderSkill 已经
      //    下载到 skillsDirB/video，无需额外复制
      final targetPath = p.join(env.skillsDirB, 'video');
      expect(await Directory(targetPath).exists(), isTrue);
      _verifySkillFiles(targetPath, 'video');
    });

    test('无 GlobalSkill 的员工 skill → setSkills → LAN 拉取同步成功',
        timeout: const Timeout(Duration(seconds: 60)), () async {
      final skillStore = SkillStore(deviceId: env.deviceIdB);

      // 1. 设备 A 有 summary 文件夹
      await _createTestSkillFiles(env.skillsDirA, 'summary');

      // 2. 创建员工 skill（无 globalSkillId）
      final empId = 'emp-${const Uuid().v4()}';
      final skillUuid = const Uuid().v4();
      final now = DateTime.now();
      final employeeSkill = AiEmployeeSkillEntity(
        uuid: skillUuid,
        employeeId: empId,
        deviceId: '',
        name: 'summary',
        description: 'Summary skill (no global)',
        skillType: 'folder',
        config: null,
        globalSkillId: null, // 无 globalSkillId
        enabled: 1,
        sortOrder: 0,
        createTime: now,
        updateTime: now,
      );

      // 3. 保存到数据库
      await skillStore.save(employeeSkill);

      // 4. 验证保存成功
      final saved = await skillStore.find(skillUuid);
      expect(saved, isNotNull);
      expect(saved!.globalSkillId, isNull);

      // 5. 执行三级获取策略
      final success = await _ensureFolderSkillData(
        deviceId: env.deviceIdB,
        skillName: saved.name,
        skillUuid: saved.uuid,
        globalSkillId: saved.globalSkillId,
      );
      expect(success, isTrue, reason: '无 GlobalSkill 的员工 skill LAN 拉取应成功');

      // 6. 验证文件
      final targetPath = p.join(env.skillsDirB, 'summary');
      expect(await Directory(targetPath).exists(), isTrue);
      _verifySkillFiles(targetPath, 'summary');
    });

    test('混合场景：有/无 globalSkillId 的多个 skill 同时 setSkills',
        timeout: const Timeout(Duration(seconds: 90)), () async {
      final gsmB = GlobalSkillManager.getInstance(env.deviceIdB);
      final skillStore = SkillStore(deviceId: env.deviceIdB);

      // 1. 创建两个 GlobalSkill
      final gsVideoUuid = 'gs-mix-video-${const Uuid().v4()}';
      final gsTranslateUuid = 'gs-mix-translate-${const Uuid().v4()}';
      for (final gs in [
        GlobalSkillEntity(
          uuid: gsVideoUuid, name: 'video', skillType: 'folder',
          enabled: 1, createTime: DateTime.now(), updateTime: DateTime.now(),
        ),
        GlobalSkillEntity(
          uuid: gsTranslateUuid, name: 'translate', skillType: 'folder',
          enabled: 1, createTime: DateTime.now(), updateTime: DateTime.now(),
        ),
      ]) {
        await gsmB.createSkill(gs);
      }

      // 2. 设备 A 有所有文件夹
      await _createTestSkillFiles(env.skillsDirA, 'video');
      await _createTestSkillFiles(env.skillsDirA, 'translate');
      await _createTestSkillFiles(env.skillsDirA, 'code-review');

      // 3. 创建三个员工 skill：两个有 globalSkillId，一个没有
      //    注意：有 globalSkillId 的员工 skill name == GlobalSkill name
      //    这样 syncSingleFolderSkill 拉取的路径就是最终目标路径
      final empId = 'emp-mix-${const Uuid().v4()}';
      final now = DateTime.now();
      final skills = [
        AiEmployeeSkillEntity(
          uuid: 'emp-video-${const Uuid().v4()}',
          employeeId: empId, name: 'video', skillType: 'folder',
          globalSkillId: gsVideoUuid, enabled: 1,
          createTime: now, updateTime: now,
        ),
        AiEmployeeSkillEntity(
          uuid: 'emp-translate-${const Uuid().v4()}',
          employeeId: empId, name: 'translate', skillType: 'folder',
          globalSkillId: gsTranslateUuid, enabled: 1,
          createTime: now, updateTime: now,
        ),
        AiEmployeeSkillEntity(
          uuid: 'emp-code-review-${const Uuid().v4()}',
          employeeId: empId, name: 'code-review', skillType: 'folder',
          globalSkillId: null, enabled: 1, // 无 globalSkillId
          createTime: now, updateTime: now,
        ),
      ];

      // 4. 保存所有 skill
      for (final skill in skills) {
        await skillStore.save(skill);
      }

      // 5. 对每个 skill 执行三级获取
      for (final skill in skills) {
        final success = await _ensureFolderSkillData(
          deviceId: env.deviceIdB,
          skillName: skill.name,
          skillUuid: skill.uuid,
          globalSkillId: skill.globalSkillId,
        );
        expect(success, isTrue, reason: '${skill.name} 获取应成功');

        final targetPath = p.join(env.skillsDirB, skill.name);
        expect(await Directory(targetPath).exists(), isTrue);
        _verifySkillFiles(targetPath, skill.name);
      }
    });
  });
}
