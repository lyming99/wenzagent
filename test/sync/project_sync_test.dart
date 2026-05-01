import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/persistence/store_merge_util.dart';
import 'package:wenzagent/src/service/project_manager.dart';

int _testCounter = 0;

/// Project / ProjectSkill 局域网同步合并测试
///
/// 模拟两台设备（A=本地, B=远程）各自持有独立数据库，
/// 验证项目和技能在跨设备同步时的合并逻辑：
/// 1. 远程数据更新 → 本地采纳远程数据
/// 2. 本地数据更新 → 保留本地数据
/// 3. 删除状态独立合并（deleteTime 取较大值）
/// 4. 本地不存在 + 远程已删除 → 不保存
/// 5. 已删除数据不复活（除非远程明确复活且 updateTime 更新）
/// 6. 技能按项目隔离
void main() {
  // ===== 设备 A（本地）的数据库 =====
  late String testDbPathA;
  late String deviceIdA;
  late ProjectStore projectStoreA;
  late ProjectManager projectManagerA;

  // ===== 设备 B（远程）的数据库 =====
  late String testDbPathB;
  late String deviceIdB;
  late ProjectStore projectStoreB;
  late ProjectManager projectManagerB;

  setUp(() async {
    _testCounter++;

    // 设备 A
    testDbPathA =
        '${Directory.systemTemp.path}/wenzagent_project_sync_test_A_$_testCounter';
    await Directory(testDbPathA).create(recursive: true);
    deviceIdA = 'devA-${const Uuid().v4().substring(0, 8)}';
    await DatabaseManager.getInstance(deviceIdA).initialize(
      storagePath: testDbPathA,
    );
    projectStoreA = ProjectStore(deviceId: deviceIdA);
    projectManagerA = ProjectManager.getInstance(deviceIdA);

    // 设备 B
    testDbPathB =
        '${Directory.systemTemp.path}/wenzagent_project_sync_test_B_$_testCounter';
    await Directory(testDbPathB).create(recursive: true);
    deviceIdB = 'devB-${const Uuid().v4().substring(0, 8)}';
    await DatabaseManager.getInstance(deviceIdB).initialize(
      storagePath: testDbPathB,
    );
    projectStoreB = ProjectStore(deviceId: deviceIdB);
    projectManagerB = ProjectManager.getInstance(deviceIdB);
  });

  tearDown(() async {
    // 清理设备 A
    (projectManagerA as ProjectManagerImpl).dispose();
    await DatabaseManager.getInstance(deviceIdA).close();
    DatabaseManager.removeInstance(deviceIdA);
    ProjectManager.removeInstance(deviceIdA);
    try {
      await Directory(testDbPathA).delete(recursive: true);
    } catch (_) {}

    // 清理设备 B
    (projectManagerB as ProjectManagerImpl).dispose();
    await DatabaseManager.getInstance(deviceIdB).close();
    DatabaseManager.removeInstance(deviceIdB);
    ProjectManager.removeInstance(deviceIdB);
    try {
      await Directory(testDbPathB).delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════
  // 辅助方法
  // ═══════════════════════════════════════════════════

  ProjectEntity createProject({
    String? uuid,
    String title = '测试项目',
    String? description,
    String? workPath,
    String? gitUrl,
    int deleted = 0,
    DateTime? deleteTime,
    String? createBy,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return ProjectEntity(
      uuid: uuid ?? const Uuid().v4(),
      title: title,
      description: description,
      workPath: workPath,
      gitUrl: gitUrl,
      deleted: deleted,
      deleteTime: deleteTime,
      createBy: createBy,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  ProjectSkillEntity createSkill({
    String? uuid,
    required String projectUuid,
    String title = '测试技能',
    String? description,
    String skillType = 'mcp',
    String? mcpConfig,
    String? fileConfig,
    int sortOrder = 0,
    int deleted = 0,
    DateTime? deleteTime,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return ProjectSkillEntity(
      uuid: uuid ?? const Uuid().v4(),
      projectUuid: projectUuid,
      title: title,
      description: description,
      skillType: skillType,
      mcpConfig: mcpConfig,
      fileConfig: fileConfig,
      sortOrder: sortOrder,
      deleted: deleted,
      deleteTime: deleteTime,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  /// 模拟项目同步合并逻辑（与 DataSyncManager / HostRpcMethods 一致）
  /// 返回 (shouldSave, mergedEntity)
  (bool, ProjectEntity?) simulateProjectMerge(
    ProjectEntity existing,
    ProjectEntity remote,
  ) {
    final mergeResult = StoreMergeUtil.mergeDeleteState(
      localDeleteTime: existing.deleteTime,
      localDeleted: existing.deleted,
      remoteDeleteTime: remote.deleteTime,
      remoteDeleted: remote.deleted,
      localUpdateTime: existing.updateTime,
      remoteUpdateTime: remote.updateTime,
    );
    final shouldUpdateData =
        StoreMergeUtil.shouldUpdateData(existing.updateTime, remote.updateTime);
    final shouldUpdateDelete =
        mergeResult.mergedDeleteTime?.millisecondsSinceEpoch !=
            existing.deleteTime?.millisecondsSinceEpoch ||
        mergeResult.mergedDeleted != existing.deleted;

    if (shouldUpdateData || shouldUpdateDelete) {
      final base = shouldUpdateData ? remote : existing;
      return (
        true,
        base.copyWith(
          deleted: mergeResult.mergedDeleted,
          deleteTime: mergeResult.mergedDeleteTime,
        ),
      );
    }
    return (false, null);
  }

  /// 模拟技能同步合并逻辑
  /// 返回 (shouldSave, mergedEntity)
  (bool, ProjectSkillEntity?) simulateSkillMerge(
    ProjectSkillEntity existing,
    ProjectSkillEntity remote,
  ) {
    final mergeResult = StoreMergeUtil.mergeDeleteState(
      localDeleteTime: existing.deleteTime,
      localDeleted: existing.deleted,
      remoteDeleteTime: remote.deleteTime,
      remoteDeleted: remote.deleted,
      localUpdateTime: existing.updateTime,
      remoteUpdateTime: remote.updateTime,
    );
    final shouldUpdateData =
        StoreMergeUtil.shouldUpdateData(existing.updateTime, remote.updateTime);
    final shouldUpdateDelete =
        mergeResult.mergedDeleteTime?.millisecondsSinceEpoch !=
            existing.deleteTime?.millisecondsSinceEpoch ||
        mergeResult.mergedDeleted != existing.deleted;

    if (shouldUpdateData || shouldUpdateDelete) {
      final base = shouldUpdateData ? remote : existing;
      return (
        true,
        base.copyWith(
          deleted: mergeResult.mergedDeleted,
          deleteTime: mergeResult.mergedDeleteTime,
        ),
      );
    }
    return (false, null);
  }

  /// 模拟从远程同步单个项目到本地
  /// 逻辑：
  ///   existing == null && remote.deleted != 1 → saveProject (changed)
  ///   existing == null && remote.deleted == 1 → skip (not changed)
  ///   existing != null → merge
  Future<(bool, ProjectEntity?)> simulateSyncProject(
    ProjectStore localStore,
    ProjectEntity remote,
  ) async {
    final existing =
        await localStore.findProjectIncludingDeleted(remote.uuid);
    if (existing == null) {
      if (remote.deleted != 1) {
        await localStore.saveProject(remote);
        return (true, remote);
      }
      return (false, null);
    }
    final (shouldSave, merged) = simulateProjectMerge(existing, remote);
    if (shouldSave && merged != null) {
      await localStore.saveProject(merged);
    }
    return (shouldSave, merged);
  }

  /// 模拟从远程同步单个技能到本地
  Future<(bool, ProjectSkillEntity?)> simulateSyncSkill(
    ProjectStore localStore,
    ProjectSkillEntity remote,
  ) async {
    // 技能没有 findIncludingDeleted，通过 findSkills + deleted 过滤来查找
    // 这里直接用全表扫描模拟
    final allSkills = await localStore.findSkills(remote.projectUuid);
    ProjectSkillEntity? existing;
    try {
      // 尝试查找包括已删除的：通过 save + find 的方式
      // 因为 ProjectStore 没有 findSkillIncludingDeleted，
      // 我们模拟同步时需要先检查是否存在
      existing = allSkills.where((s) => s.uuid == remote.uuid).firstOrNull;
    } catch (_) {}

    if (existing == null) {
      if (remote.deleted != 1) {
        await localStore.saveSkill(remote);
        return (true, remote);
      }
      return (false, null);
    }
    final (shouldSave, merged) = simulateSkillMerge(existing, remote);
    if (shouldSave && merged != null) {
      await localStore.saveSkill(merged);
    }
    return (shouldSave, merged);
  }

  // ═══════════════════════════════════════════════════
  // 一、项目同步合并
  // ═══════════════════════════════════════════════════

  group('项目同步合并', () {
    // ---------- 1. 远程数据更新 → 本地采纳 ----------

    test('远程项目数据更新 → 本地采纳远程数据', () async {
      final project = createProject(
        title: '本地项目',
        description: '本地描述',
        workPath: '/local/path',
        updateTime: DateTime(2024, 1, 2),
      );
      await projectStoreA.saveProject(project);

      final remote = project.copyWith(
        title: '远程项目',
        description: '远程描述',
        workPath: '/remote/path',
        updateTime: DateTime(2024, 1, 5),
      );

      final (changed, merged) =
          await simulateSyncProject(projectStoreA, remote);

      expect(changed, isTrue);
      expect(merged!.title, equals('远程项目'));
      expect(merged.description, equals('远程描述'));
      expect(merged.workPath, equals('/remote/path'));

      // 验证数据库
      final found = await projectStoreA.findProject(project.uuid);
      expect(found, isNotNull);
      expect(found!.title, equals('远程项目'));
    });

    test('远程项目更新且updateTime更新 → 远程复活覆盖本地删除', () async {
      final localDT = DateTime(2024, 1, 6);
      final project = createProject(
        title: '本地项目',
        deleted: 1,
        deleteTime: localDT,
        updateTime: DateTime(2024, 1, 2),
      );
      await projectStoreA.saveProject(project);

      // 远程：明确复活（deleted=0, deleteTime=null）且 updateTime 更新
      final remote = project.copyWith(
        title: '远程更新',
        deleted: 0,
        deleteTime: null,
        updateTime: DateTime(2024, 1, 5),
      );

      final (changed, merged) =
          await simulateSyncProject(projectStoreA, remote);

      expect(changed, isTrue);
      expect(merged!.title, equals('远程更新')); // 数据取远程
      // StoreMergeUtil 远程明确复活规则：远程 updateTime 更新 → 允许复活
      expect(merged.deleted, equals(0));
      expect(merged.deleteTime, isNull);
    });

    // ---------- 2. 本地数据更新 → 保留本地 ----------

    test('本地项目数据更新 → 保留本地数据', () async {
      final project = createProject(
        title: '本地项目',
        updateTime: DateTime(2024, 1, 5),
      );
      await projectStoreA.saveProject(project);

      final remote = project.copyWith(
        title: '远程旧数据',
        updateTime: DateTime(2024, 1, 2),
      );

      final (changed, _) =
          await simulateSyncProject(projectStoreA, remote);

      expect(changed, isFalse);

      final found = await projectStoreA.findProject(project.uuid);
      expect(found, isNotNull);
      expect(found!.title, equals('本地项目'));
    });

    test('updateTime 相同 → 不更新', () async {
      final ts = DateTime(2024, 1, 5, 12, 0);
      final project = createProject(
        title: '本地项目',
        updateTime: ts,
      );
      await projectStoreA.saveProject(project);

      final remote = project.copyWith(
        title: '远程项目',
        updateTime: ts,
      );

      final (changed, _) =
          await simulateSyncProject(projectStoreA, remote);

      expect(changed, isFalse);
    });

    // ---------- 3. 删除状态独立合并 ----------

    test('远程删除时间更新 → 本地采纳删除', () async {
      final remoteDT = DateTime(2024, 1, 6);
      final project = createProject(
        title: '项目',
        deleted: 0,
        updateTime: DateTime(2024, 1, 2),
      );
      await projectStoreA.saveProject(project);

      final remote = project.copyWith(
        deleted: 1,
        deleteTime: remoteDT,
        // 不设 updateTime → copyWith 保留原值，确保 remote.updateTime > existing.updateTime
      );

      final (changed, merged) =
          await simulateSyncProject(projectStoreA, remote);

      expect(changed, isTrue);
      expect(merged!.deleted, equals(1));
      // 远程 updateTime 与本地相同但删除状态变化
      expect(merged.title, equals('项目')); // 数据保留本地
    });

    test('双方都已删除 → 取较大 deleteTime', () async {
      final localDT = DateTime(2024, 1, 3);
      final remoteDT = DateTime(2024, 1, 6);
      final project = createProject(
        title: '项目',
        deleted: 1,
        deleteTime: localDT,
        updateTime: DateTime(2024, 1, 2),
      );
      await projectStoreA.saveProject(project);

      final remote = project.copyWith(
        deleted: 1,
        deleteTime: remoteDT,
        updateTime: DateTime(2024, 1, 1),
      );

      final (changed, merged) =
          await simulateSyncProject(projectStoreA, remote);

      expect(changed, isTrue);
      expect(merged!.deleted, equals(1));
      expect(
        merged.deleteTime?.millisecondsSinceEpoch,
        equals(remoteDT.millisecondsSinceEpoch),
      );
    });

    test('仅删除状态变化 → 仍触发保存', () async {
      final ts = DateTime(2024, 1, 5);
      final project = createProject(
        title: '相同数据',
        deleted: 0,
        updateTime: ts,
      );
      await projectStoreA.saveProject(project);

      final remote = project.copyWith(
        deleted: 1,
        deleteTime: DateTime(2024, 1, 6),
        updateTime: ts,
      );

      final (changed, merged) =
          await simulateSyncProject(projectStoreA, remote);

      expect(changed, isTrue);
      expect(merged!.deleted, equals(1));
      expect(merged.title, equals('相同数据'));
    });

    // ---------- 4. 本地不存在场景 ----------

    test('本地不存在 + 远程未删除 → 直接保存', () async {
      final remote = createProject(
        title: '新项目',
        description: '远程创建',
      );

      final (changed, merged) =
          await simulateSyncProject(projectStoreA, remote);

      expect(changed, isTrue);
      expect(merged!.title, equals('新项目'));

      final found = await projectStoreA.findProject(remote.uuid);
      expect(found, isNotNull);
      expect(found!.title, equals('新项目'));
    });

    test('本地不存在 + 远程已删除 → 不保存', () async {
      final remote = createProject(
        title: '已删除项目',
        deleted: 1,
        deleteTime: DateTime(2024, 1, 5),
      );

      final (changed, _) =
          await simulateSyncProject(projectStoreA, remote);

      expect(changed, isFalse);

      // findProjectIncludingDeleted 也查不到（未保存）
      final found =
          await projectStoreA.findProjectIncludingDeleted(remote.uuid);
      expect(found, isNull);
    });

    // ---------- 5. 已删除数据不复活 ----------

    test('本地已删除 + 远程未删除且updateTime较旧 → 不复活', () async {
      final localDT = DateTime(2024, 1, 5);
      final project = createProject(
        title: '已删除项目',
        deleted: 1,
        deleteTime: localDT,
        updateTime: DateTime(2024, 1, 5),
      );
      await projectStoreA.saveProject(project);

      // 远程：未删除但 updateTime 更旧
      final remote = project.copyWith(
        deleted: 0,
        deleteTime: null,
        updateTime: DateTime(2024, 1, 3),
      );

      final (changed, merged) =
          await simulateSyncProject(projectStoreA, remote);

      // StoreMergeUtil 的复活规则要求 remoteUpdateTime > localUpdateTime
      // 这里远程更旧，不应复活
      expect(changed, isFalse);
    });

    // ---------- 6. 远程明确复活（updateTime 更新）----------

    test('远程明确复活且updateTime更新 → 允许复活', () async {
      final localDT = DateTime(2024, 1, 3);
      final project = createProject(
        title: '已删除项目',
        deleted: 1,
        deleteTime: localDT,
        updateTime: DateTime(2024, 1, 2),
      );
      await projectStoreA.saveProject(project);

      // 远程：明确复活（deleted=0, deleteTime=null）且 updateTime 更新
      final remote = project.copyWith(
        title: '复活项目',
        deleted: 0,
        deleteTime: null,
        updateTime: DateTime(2024, 1, 6),
      );

      final (changed, merged) =
          await simulateSyncProject(projectStoreA, remote);

      expect(changed, isTrue);
      expect(merged!.deleted, equals(0)); // 复活
      expect(merged.deleteTime, isNull);
      expect(merged.title, equals('复活项目'));
    });

    // ---------- 7. 双设备完整同步流程 ----------

    test('双设备完整同步流程', () async {
      // 设备 B 创建项目
      final project = createProject(title: '同步测试');
      await projectStoreB.saveProject(project);

      // 设备 A 从 B 同步
      final remoteData = project;
      final (changed, _) =
          await simulateSyncProject(projectStoreA, remoteData);
      expect(changed, isTrue);

      // 验证 A 上有该项目
      var foundA = await projectStoreA.findProject(project.uuid);
      expect(foundA, isNotNull);
      expect(foundA!.title, equals('同步测试'));

      // 设备 B 更新项目
      final updated = project.copyWith(
        title: 'B更新标题',
        description: 'B新增描述',
        updateTime: DateTime.now().add(const Duration(seconds: 1)),
      );
      await projectStoreB.saveProject(updated);

      // 设备 A 再次同步
      final (changed2, _) =
          await simulateSyncProject(projectStoreA, updated);
      expect(changed2, isTrue);

      foundA = await projectStoreA.findProject(project.uuid);
      expect(foundA!.title, equals('B更新标题'));
      expect(foundA.description, equals('B新增描述'));

      // 设备 B 删除项目
      await projectStoreB.deleteProject(project.uuid);

      // 设备 A 同步删除
      final deletedRemote = updated.copyWith(
        deleted: 1,
        deleteTime: DateTime.now().add(const Duration(seconds: 2)),
      );
      final (changed3, _) =
          await simulateSyncProject(projectStoreA, deletedRemote);
      expect(changed3, isTrue);

      foundA = await projectStoreA.findProject(project.uuid);
      expect(foundA, isNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // 二、项目技能同步合并
  // ═══════════════════════════════════════════════════

  group('项目技能同步合并', () {
    late String projectUuidA;
    late String projectUuidB;

    setUp(() async {
      // 在两个设备上分别创建项目
      final pA = createProject(title: '设备A项目');
      await projectStoreA.saveProject(pA);
      projectUuidA = pA.uuid;

      final pB = createProject(title: '设备B项目');
      await projectStoreB.saveProject(pB);
      projectUuidB = pB.uuid;
    });

    // ---------- 1. 远程数据更新 ----------

    test('远程技能数据更新 → 本地采纳', () async {
      // 两端先有相同技能
      final uuid = const Uuid().v4();
      final skill = createSkill(
        uuid: uuid,
        projectUuid: projectUuidA,
        title: '本地技能',
        description: '本地描述',
        mcpConfig: '{"server":"local"}',
        updateTime: DateTime(2024, 1, 2),
      );
      await projectStoreA.saveSkill(skill);

      final remote = skill.copyWith(
        title: '远程技能',
        description: '远程描述',
        mcpConfig: '{"server":"remote"}',
        updateTime: DateTime(2024, 1, 5),
      );

      final (changed, merged) =
          await simulateSyncSkill(projectStoreA, remote);

      expect(changed, isTrue);
      expect(merged!.title, equals('远程技能'));
      expect(merged.description, equals('远程描述'));
      expect(merged.mcpConfig, equals('{"server":"remote"}'));
    });

    test('远程技能更新且updateTime更新 → 远程复活覆盖本地删除', () async {
      final uuid = const Uuid().v4();
      final skill = createSkill(
        uuid: uuid,
        projectUuid: projectUuidA,
        title: '技能',
        deleted: 1,
        deleteTime: DateTime(2024, 1, 6),
        updateTime: DateTime(2024, 1, 2),
      );
      await projectStoreA.saveSkill(skill);

      final remote = skill.copyWith(
        title: '远程更新',
        deleted: 0,
        deleteTime: null,
        updateTime: DateTime(2024, 1, 5),
      );

      final (changed, merged) =
          await simulateSyncSkill(projectStoreA, remote);

      expect(changed, isTrue);
      expect(merged!.title, equals('远程更新'));
      // StoreMergeUtil 远程明确复活规则
      expect(merged.deleted, equals(0));
      expect(merged.deleteTime, isNull);
    });

    // ---------- 2. 本地数据更新 ----------

    test('本地技能数据更新 → 保留本地', () async {
      final uuid = const Uuid().v4();
      final skill = createSkill(
        uuid: uuid,
        projectUuid: projectUuidA,
        title: '本地技能',
        updateTime: DateTime(2024, 1, 5),
      );
      await projectStoreA.saveSkill(skill);

      final remote = skill.copyWith(
        title: '远程旧数据',
        updateTime: DateTime(2024, 1, 2),
      );

      final (changed, _) =
          await simulateSyncSkill(projectStoreA, remote);

      expect(changed, isFalse);
    });

    // ---------- 3. 删除状态独立合并 ----------

    test('远程删除技能 → 本地采纳删除', () async {
      final uuid = const Uuid().v4();
      final skill = createSkill(
        uuid: uuid,
        projectUuid: projectUuidA,
        title: '技能',
        updateTime: DateTime(2024, 1, 2),
      );
      await projectStoreA.saveSkill(skill);

      final remote = skill.copyWith(
        deleted: 1,
        deleteTime: DateTime(2024, 1, 6),
        // 不设 updateTime → copyWith 保留原值，确保 shouldUpdateData=false 但 shouldUpdateDelete=true
      );

      final (changed, merged) =
          await simulateSyncSkill(projectStoreA, remote);

      expect(changed, isTrue);
      expect(merged!.deleted, equals(1));
    });

    test('仅删除状态变化 → 触发保存', () async {
      final ts = DateTime(2024, 1, 5);
      final uuid = const Uuid().v4();
      final skill = createSkill(
        uuid: uuid,
        projectUuid: projectUuidA,
        title: '技能',
        updateTime: ts,
      );
      await projectStoreA.saveSkill(skill);

      final remote = skill.copyWith(
        deleted: 1,
        deleteTime: DateTime(2024, 1, 6),
        updateTime: ts,
      );

      final (changed, merged) =
          await simulateSyncSkill(projectStoreA, remote);

      expect(changed, isTrue);
      expect(merged!.deleted, equals(1));
    });

    // ---------- 4. 本地不存在场景 ----------

    test('本地不存在 + 远程未删除技能 → 直接保存', () async {
      final remote = createSkill(
        projectUuid: projectUuidA,
        title: '新技能',
        skillType: 'mcp',
        mcpConfig: '{"server":"new"}',
      );

      final (changed, merged) =
          await simulateSyncSkill(projectStoreA, remote);

      expect(changed, isTrue);
      expect(merged!.title, equals('新技能'));

      final skills = await projectStoreA.findSkills(projectUuidA);
      expect(skills.length, equals(1));
      expect(skills.first.title, equals('新技能'));
    });

    test('本地不存在 + 远程已删除技能 → 不保存', () async {
      final remote = createSkill(
        projectUuid: projectUuidA,
        title: '已删除技能',
        deleted: 1,
        deleteTime: DateTime(2024, 1, 5),
      );

      final (changed, _) =
          await simulateSyncSkill(projectStoreA, remote);

      expect(changed, isFalse);

      final skills = await projectStoreA.findSkills(projectUuidA);
      expect(skills, isEmpty);
    });

    // ---------- 5. 技能按项目隔离 ----------

    test('技能同步按项目隔离', () async {
      // 在设备 A 上创建两个项目
      final p2 = createProject(title: '项目2');
      await projectStoreA.saveProject(p2);

      // 同步技能到项目1
      final skill1 = createSkill(
        projectUuid: projectUuidA,
        title: '项目1技能',
      );
      await simulateSyncSkill(projectStoreA, skill1);

      // 同步技能到项目2
      final skill2 = createSkill(
        projectUuid: p2.uuid,
        title: '项目2技能',
      );
      await simulateSyncSkill(projectStoreA, skill2);

      final skills1 = await projectStoreA.findSkills(projectUuidA);
      expect(skills1.length, equals(1));
      expect(skills1.first.title, equals('项目1技能'));

      final skills2 = await projectStoreA.findSkills(p2.uuid);
      expect(skills2.length, equals(1));
      expect(skills2.first.title, equals('项目2技能'));
    });

    // ---------- 6. 远程明确复活 ----------

    test('远程明确复活技能且updateTime更新 → 允许复活', () async {
      final uuid = const Uuid().v4();
      final skill = createSkill(
        uuid: uuid,
        projectUuid: projectUuidA,
        title: '已删除技能',
        deleted: 1,
        deleteTime: DateTime(2024, 1, 3),
        updateTime: DateTime(2024, 1, 2),
      );
      await projectStoreA.saveSkill(skill);

      final remote = skill.copyWith(
        title: '复活技能',
        deleted: 0,
        deleteTime: null,
        updateTime: DateTime(2024, 1, 6),
      );

      final (changed, merged) =
          await simulateSyncSkill(projectStoreA, remote);

      expect(changed, isTrue);
      expect(merged!.deleted, equals(0));
      expect(merged.deleteTime, isNull);
      expect(merged.title, equals('复活技能'));
    });

    // ---------- 7. 双设备完整同步流程 ----------

    test('双设备技能完整同步流程', () async {
      // 在两个设备上创建相同项目
      final project = createProject(title: '共享项目');
      await projectStoreA.saveProject(project);
      await projectStoreB.saveProject(project);

      // 设备 B 创建技能
      final skill = createSkill(
        projectUuid: project.uuid,
        title: 'B创建技能',
        skillType: 'mcp',
        mcpConfig: '{"server":"b"}',
      );
      await projectStoreB.saveSkill(skill);

      // 设备 A 从 B 同步技能
      final (changed1, _) =
          await simulateSyncSkill(projectStoreA, skill);
      expect(changed1, isTrue);

      var skillsA = await projectStoreA.findSkills(project.uuid);
      expect(skillsA.length, equals(1));
      expect(skillsA.first.title, equals('B创建技能'));

      // 设备 B 更新技能
      final updated = skill.copyWith(
        title: 'B更新技能',
        mcpConfig: '{"server":"b-v2"}',
        updateTime: DateTime.now().add(const Duration(seconds: 1)),
      );
      await projectStoreB.saveSkill(updated);

      // 设备 A 再次同步
      final (changed2, _) =
          await simulateSyncSkill(projectStoreA, updated);
      expect(changed2, isTrue);

      skillsA = await projectStoreA.findSkills(project.uuid);
      expect(skillsA.first.title, equals('B更新技能'));
      expect(skillsA.first.mcpConfig, equals('{"server":"b-v2"}'));

      // 设备 B 删除技能
      await projectStoreB.deleteSkill(skill.uuid);

      // 设备 A 同步删除
      final deletedRemote = updated.copyWith(
        deleted: 1,
        deleteTime: DateTime.now().add(const Duration(seconds: 2)),
      );
      final (changed3, _) =
          await simulateSyncSkill(projectStoreA, deletedRemote);
      expect(changed3, isTrue);

      skillsA = await projectStoreA.findSkills(project.uuid);
      expect(skillsA, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════
  // 三、批量同步场景
  // ═══════════════════════════════════════════════════

  group('批量同步场景', () {
    test('批量同步多个项目', () async {
      // 设备 B 有 3 个项目
      final p1 = createProject(title: '项目1');
      final p2 = createProject(title: '项目2');
      final p3 = createProject(
        title: '已删除项目',
        deleted: 1,
        deleteTime: DateTime(2024, 1, 5),
      );
      await projectStoreB.saveProject(p1);
      await projectStoreB.saveProject(p2);
      await projectStoreB.saveProject(p3);

      // 设备 A 批量同步
      final remoteProjects = [p1, p2, p3];
      var changedCount = 0;
      for (final remote in remoteProjects) {
        final (changed, _) =
            await simulateSyncProject(projectStoreA, remote);
        if (changed) changedCount++;
      }

      expect(changedCount, equals(2)); // p1, p2 保存，p3 已删除不保存

      final allA = await projectStoreA.findAllProjects();
      expect(allA.length, equals(2));
    });

    test('批量同步多个技能', () async {
      // 共享项目
      final project = createProject(title: '批量测试');
      await projectStoreA.saveProject(project);
      await projectStoreB.saveProject(project);

      // 设备 B 有多个技能
      final skills = [
        createSkill(projectUuid: project.uuid, title: '技能A', sortOrder: 1),
        createSkill(projectUuid: project.uuid, title: '技能B', sortOrder: 2),
        createSkill(
          projectUuid: project.uuid,
          title: '已删除技能',
          deleted: 1,
          deleteTime: DateTime(2024, 1, 5),
        ),
      ];
      for (final s in skills) {
        await projectStoreB.saveSkill(s);
      }

      // 设备 A 批量同步
      var changedCount = 0;
      for (final remote in skills) {
        final (changed, _) =
            await simulateSyncSkill(projectStoreA, remote);
        if (changed) changedCount++;
      }

      expect(changedCount, equals(2));

      final skillsA = await projectStoreA.findSkills(project.uuid);
      expect(skillsA.length, equals(2));
    });

    test('项目 + 技能联合同步', () async {
      // 设备 B 创建项目及技能
      final project = createProject(title: '联合同步项目');
      await projectStoreB.saveProject(project);

      final skill1 = createSkill(
        projectUuid: project.uuid,
        title: '技能1',
        skillType: 'mcp',
      );
      final skill2 = createSkill(
        projectUuid: project.uuid,
        title: '技能2',
        skillType: 'note',
      );
      await projectStoreB.saveSkill(skill1);
      await projectStoreB.saveSkill(skill2);

      // 设备 A 同步项目
      final (projChanged, _) =
          await simulateSyncProject(projectStoreA, project);
      expect(projChanged, isTrue);

      // 设备 A 同步技能
      for (final remote in [skill1, skill2]) {
        final (changed, _) =
            await simulateSyncSkill(projectStoreA, remote);
        expect(changed, isTrue);
      }

      // 验证
      final found = await projectStoreA.findProject(project.uuid);
      expect(found, isNotNull);
      expect(found!.title, equals('联合同步项目'));

      final skills = await projectStoreA.findSkills(project.uuid);
      expect(skills.length, equals(2));
    });

    test('增量同步 - 本地已有部分数据', () async {
      // 设备 A 已有项目1
      final p1 = createProject(title: '已有项目');
      await projectStoreA.saveProject(p1);

      // 设备 B 有项目1（更新）和项目2（新）
      final p1Updated = p1.copyWith(
        title: 'B更新项目1',
        updateTime: DateTime.now().add(const Duration(seconds: 1)),
      );
      final p2 = createProject(title: '新项目2');
      await projectStoreB.saveProject(p1Updated);
      await projectStoreB.saveProject(p2);

      // 增量同步
      final (changed1, _) =
          await simulateSyncProject(projectStoreA, p1Updated);
      expect(changed1, isTrue);

      final (changed2, _) =
          await simulateSyncProject(projectStoreA, p2);
      expect(changed2, isTrue);

      // 验证
      final found1 = await projectStoreA.findProject(p1.uuid);
      expect(found1!.title, equals('B更新项目1'));

      final found2 = await projectStoreA.findProject(p2.uuid);
      expect(found2, isNotNull);
      expect(found2!.title, equals('新项目2'));

      final allA = await projectStoreA.findAllProjects();
      expect(allA.length, equals(2));
    });
  });

  // ═══════════════════════════════════════════════════
  // 四、序列化兼容性（同步传输验证）
  // ═══════════════════════════════════════════════════

  group('同步序列化兼容性', () {
    test('ProjectEntity toMap/fromMap 跨设备一致', () async {
      final now = DateTime(2024, 6, 15, 12, 0, 0);
      final project = ProjectEntity(
        uuid: 'proj-sync-serial',
        userId: 42,
        spaceId: 'space-sync',
        title: '同步序列化',
        description: '描述',
        workPath: '/sync/path',
        gitUrl: 'https://github.com/sync.git',
        deleted: 0,
        createBy: 'device-A',
        createTime: now,
        updateBy: 'device-B',
        updateTime: now,
      );

      // 设备 A 保存
      await projectStoreA.saveProject(project);

      // 通过 toMap/fromMap 模拟网络传输
      final map = project.toMap();
      final restored = ProjectEntity.fromMap(map);

      // 设备 B 接收并保存
      await projectStoreB.saveProject(restored);

      // 验证两端数据一致
      final foundA = await projectStoreA.findProject('proj-sync-serial');
      final foundB = await projectStoreB.findProject('proj-sync-serial');

      expect(foundA, isNotNull);
      expect(foundB, isNotNull);
      expect(foundA!.title, equals(foundB!.title));
      expect(foundA.description, equals(foundB.description));
      expect(foundA.workPath, equals(foundB.workPath));
      expect(foundA.gitUrl, equals(foundB.gitUrl));
      expect(foundA.userId, equals(foundB.userId));
      expect(foundA.spaceId, equals(foundB.spaceId));
    });

    test('ProjectSkillEntity toMap/fromMap 跨设备一致', () async {
      final now = DateTime(2024, 6, 15, 12, 0, 0);
      final project = createProject(title: '序列化项目');
      await projectStoreA.saveProject(project);
      await projectStoreB.saveProject(project);

      final skill = ProjectSkillEntity(
        uuid: 'skill-sync-serial',
        projectUuid: project.uuid,
        title: '同步技能',
        description: '技能描述',
        skillType: 'mcp',
        mcpConfig: '{"server":"sync"}',
        fileConfig: '{"path":"/sync"}',
        sortOrder: 5,
        deleted: 0,
        createBy: 'device-A',
        createTime: now,
        updateBy: 'device-B',
        updateTime: now,
      );

      // 设备 A 保存
      await projectStoreA.saveSkill(skill);

      // 通过 toMap/fromMap 模拟网络传输
      final map = skill.toMap();
      final restored = ProjectSkillEntity.fromMap(map);

      // 设备 B 接收并保存
      await projectStoreB.saveSkill(restored);

      // 验证
      final skillsA = await projectStoreA.findSkills(project.uuid);
      final skillsB = await projectStoreB.findSkills(project.uuid);

      expect(skillsA.length, equals(1));
      expect(skillsB.length, equals(1));
      expect(skillsA.first.title, equals(skillsB.first.title));
      expect(skillsA.first.skillType, equals(skillsB.first.skillType));
      expect(skillsA.first.mcpConfig, equals(skillsB.first.mcpConfig));
      expect(skillsA.first.sortOrder, equals(skillsB.first.sortOrder));
    });
  });
}
