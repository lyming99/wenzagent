import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/persistence/store_merge_util.dart';
import 'package:wenzagent/src/service/skill_manager.dart';
import 'package:wenzagent/src/service/global_skill_manager.dart';

int _testCounter = 0;

/// Skill 同步功能测试
///
/// 验证：
/// - A. 员工技能（AiEmployeeSkillEntity）同步合并逻辑
/// - B. 全局技能（GlobalSkillEntity）同步合并逻辑
/// - C. 跨设备技能同步模拟（设备A → 设备B）
/// - D. 技能删除同步
/// - E. deleteSkillWithSync 流程
/// - F. 序列化往返（toMap/fromMap 在同步场景中的一致性）
/// - G. HostRpcMethods 技能同步逻辑模拟
/// - H. 全局技能 HostRpcMethods 同步逻辑模拟
void main() {
  // ═══════════════════════════════════════════════════
  // A. 员工技能同步合并逻辑
  // ═══════════════════════════════════════════════════

  group('员工技能同步合并逻辑', () {
    late String testDbPath;
    late String deviceId;
    late SkillStore store;
    late SkillManager manager;

    setUp(() async {
      _testCounter++;
      testDbPath =
          '${Directory.systemTemp.path}/wenzagent_skill_sync_test_$_testCounter';
      await Directory(testDbPath).create(recursive: true);
      deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';
      await DatabaseManager.getInstance(deviceId).initialize(
        storagePath: testDbPath,
      );
      store = SkillStore(deviceId: deviceId);
      manager = SkillManager.getInstance(deviceId);
    });

    tearDown(() async {
      (manager as SkillManagerImpl).dispose();
      await DatabaseManager.getInstance(deviceId).close();
      DatabaseManager.removeInstance(deviceId);
      SkillManager.removeInstance(deviceId);
      try {
        await Directory(testDbPath).delete(recursive: true);
      } catch (_) {}
    });

    // 辅助方法：创建员工技能实体
    AiEmployeeSkillEntity createSkillEntity({
      String? uuid,
      String? employeeId,
      String? name,
      String? description,
      String skillType = 'mcp',
      String? config,
      int enabled = 1,
      int sortOrder = 0,
      int deleted = 0,
      DateTime? deleteTime,
      DateTime? createTime,
      DateTime? updateTime,
    }) {
      final now = DateTime.now();
      return AiEmployeeSkillEntity(
        uuid: uuid ?? const Uuid().v4(),
        employeeId: employeeId ?? 'emp-${const Uuid().v4().substring(0, 8)}',
        name: name ?? 'Test Skill',
        description: description,
        skillType: skillType,
        config: config,
        enabled: enabled,
        sortOrder: sortOrder,
        deleted: deleted,
        deleteTime: deleteTime,
        createTime: createTime ?? now,
        updateTime: updateTime ?? now,
      );
    }

    /// 模拟 DataSyncManager._mergeAndSaveSkill 的合并逻辑
    /// 注意：使用 store 直接操作以保留原始 updateTime（与 DataSyncManager 行为一致）
    Future<bool> simulateMergeAndSaveSkill(
      AiEmployeeSkillEntity existing,
      AiEmployeeSkillEntity remote,
    ) async {
      final mergeResult = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: existing.deleteTime,
        localDeleted: existing.deleted,
        remoteDeleteTime: remote.deleteTime,
        remoteDeleted: remote.deleted,
        localUpdateTime: existing.updateTime,
        remoteUpdateTime: remote.updateTime,
      );
      final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
          existing.updateTime, remote.updateTime);
      final shouldUpdateDelete =
          mergeResult.mergedDeleteTime != existing.deleteTime ||
              mergeResult.mergedDeleted != existing.deleted;
      if (shouldUpdateData || shouldUpdateDelete) {
        final merged = (shouldUpdateData ? remote : existing).copyWith(
          deleted: mergeResult.mergedDeleted,
          deleteTime: mergeResult.mergedDeleteTime,
        );
        await store.saveWithDeviceId(deviceId, merged);
        return true;
      }
      return false;
    }

    test('远程新增技能 → 本地不存在 → 直接创建', () async {
      const empId = 'emp-sync-new';
      final remote = createSkillEntity(
        employeeId: empId,
        name: '远程新技能',
        config: '{"server":"remote"}',
      );

      // 模拟同步：本地不存在，直接创建
      final existing = await store.findIncludingDeleted(remote.uuid);
      expect(existing, isNull);

      await store.saveWithDeviceId(deviceId, remote);

      final fetched = await store.find(null, remote.uuid);
      expect(fetched, isNotNull);
      expect(fetched!.name, equals('远程新技能'));
      expect(fetched.config, equals('{"server":"remote"}'));
    });

    test('远程已删除技能 → 本地不存在 → 不创建', () async {
      final remote = createSkillEntity(
        name: '已删除技能',
        deleted: 1,
        deleteTime: DateTime.now(),
      );

      final existing = await store.findIncludingDeleted(remote.uuid);
      expect(existing, isNull);

      // 模拟 _doSyncSkillsFromDevices: remote.deleted == 1 → 不创建
      if (existing == null && remote.deleted != 1) {
        await store.saveWithDeviceId(deviceId, remote);
        fail('不应创建已删除的技能');
      }

      // 验证确实没有创建
      final fetched = await store.findIncludingDeleted(remote.uuid);
      expect(fetched, isNull);
    });

    test('远程数据更新 → 合并后采用远程数据', () async {
      const empId = 'emp-sync-update';
      final now = DateTime.now();

      // 本地创建技能
      final local = createSkillEntity(
        employeeId: empId,
        name: '本地技能',
        config: '{"server":"local"}',
        updateTime: now.subtract(const Duration(hours: 1)),
      );
      await store.saveWithDeviceId(deviceId, local);

      // 模拟远程更新的技能（updateTime 更新）
      final remote = local.copyWith(
        name: '远程更新技能',
        config: '{"server":"remote-updated"}',
        updateTime: now,
      );

      final existing = await store.findIncludingDeleted(local.uuid);
      expect(existing, isNotNull);

      final changed = await simulateMergeAndSaveSkill(existing!, remote);
      expect(changed, isTrue);

      final fetched = await store.find(null, local.uuid);
      expect(fetched, isNotNull);
      expect(fetched!.name, equals('远程更新技能'));
      expect(fetched.config, equals('{"server":"remote-updated"}'));
    });

    test('远程数据较旧 → 不更新', () async {
      const empId = 'emp-sync-old';
      final now = DateTime.now();

      final local = createSkillEntity(
        employeeId: empId,
        name: '本地最新技能',
        config: '{"server":"local"}',
        updateTime: now,
      );
      await store.saveWithDeviceId(deviceId, local);

      final remote = local.copyWith(
        name: '远程旧技能',
        config: '{"server":"remote-old"}',
        updateTime: now.subtract(const Duration(hours: 1)),
      );

      final existing = await store.findIncludingDeleted(local.uuid);
      final changed = await simulateMergeAndSaveSkill(existing!, remote);
      expect(changed, isFalse);

      final fetched = await store.find(null, local.uuid);
      expect(fetched!.name, equals('本地最新技能'));
    });

    test('远程删除 → 本地未删除 → 合并后标记删除', () async {
      const empId = 'emp-sync-delete';
      final now = DateTime.now();

      final local = createSkillEntity(
        employeeId: empId,
        name: '待删除技能',
        updateTime: now.subtract(const Duration(hours: 1)),
      );
      await store.saveWithDeviceId(deviceId, local);

      final remote = local.copyWith(
        deleted: 1,
        deleteTime: now,
        updateTime: now,
      );

      final existing = await store.findIncludingDeleted(local.uuid);
      final changed = await simulateMergeAndSaveSkill(existing!, remote);
      expect(changed, isTrue);

      final fetched = await store.findIncludingDeleted(local.uuid);
      expect(fetched, isNotNull);
      expect(fetched!.deleted, equals(1));
      expect(fetched.deleteTime, isNotNull);
    });

    test('远程复活（deleted=0）且 updateTime 更新 → 允许复活', () async {
      const empId = 'emp-sync-restore';
      final now = DateTime.now();

      // 本地已删除
      final local = createSkillEntity(
        employeeId: empId,
        name: '已删除技能',
        deleted: 1,
        deleteTime: now.subtract(const Duration(hours: 2)),
        updateTime: now.subtract(const Duration(hours: 2)),
      );
      await store.saveWithDeviceId(deviceId, local);

      // 远程复活
      final remote = local.copyWith(
        deleted: 0,
        deleteTime: null,
        name: '已复活技能',
        updateTime: now,
      );

      final existing = await store.findIncludingDeleted(local.uuid);
      final changed = await simulateMergeAndSaveSkill(existing!, remote);
      expect(changed, isTrue);

      final fetched = await store.findIncludingDeleted(local.uuid);
      expect(fetched, isNotNull);
      expect(fetched!.deleted, equals(0));
      expect(fetched.deleteTime, isNull);
      expect(fetched.name, equals('已复活技能'));
    });

    test('双方 updateTime 相同 → 不更新', () async {
      const empId = 'emp-sync-same';
      final sameTime = DateTime(2024, 6, 15, 12, 0, 0);

      final local = createSkillEntity(
        employeeId: empId,
        name: '本地技能',
        updateTime: sameTime,
      );
      await store.saveWithDeviceId(deviceId, local);

      final remote = local.copyWith(
        name: '远程同名技能',
        updateTime: sameTime,
      );

      final existing = await store.findIncludingDeleted(local.uuid);
      final changed = await simulateMergeAndSaveSkill(existing!, remote);
      expect(changed, isFalse);
    });

    test('仅删除状态变化 → 只更新删除状态', () async {
      const empId = 'emp-sync-del-only';
      final now = DateTime.now();

      final local = createSkillEntity(
        employeeId: empId,
        name: '本地技能',
        updateTime: now.subtract(const Duration(minutes: 30)),
      );
      await store.saveWithDeviceId(deviceId, local);

      // 远程数据较旧，但已删除（deleteTime 在本地 updateTime 之后）
      final remote = local.copyWith(
        deleted: 1,
        deleteTime: now.subtract(const Duration(minutes: 5)),
        updateTime: now.subtract(const Duration(hours: 1)),
      );

      final existing = await store.findIncludingDeleted(local.uuid);
      final changed = await simulateMergeAndSaveSkill(existing!, remote);
      // mergeDeleteState: localDeleteTime=null, remoteDeleteTime=now-5min
      // → mergedDeleteTime = remoteDeleteTime, mergedDeleted = 1
      // shouldUpdateDelete = true (null != remoteDeleteTime)
      expect(changed, isTrue);

      final fetched = await store.findIncludingDeleted(local.uuid);
      expect(fetched, isNotNull);
      // 数据不更新（远程较旧），但删除状态更新
      expect(fetched!.deleted, equals(1));
      expect(fetched.name, equals('本地技能')); // 数据保持本地版本
    });

    test('变更事件正确触发', () async {
      const empId = 'emp-sync-events';
      final events = <SkillChangeEvent>[];
      manager.onSkillChanged.listen(events.add);

      final now = DateTime.now();

      // 创建
      final local = createSkillEntity(
        employeeId: empId,
        name: '技能A',
        updateTime: now.subtract(const Duration(hours: 1)),
      );
      await manager.createSkill(local);

      // 合并更新（通过 manager.updateSkill 触发事件）
      final remote = local.copyWith(
        name: '技能A-更新',
        updateTime: now,
      );
      final existing = await store.findIncludingDeleted(local.uuid);
      // 使用 manager.updateSkill 来触发事件
      await manager.updateSkill(
        remote.copyWith(
          deleted: existing!.deleted,
          deleteTime: existing.deleteTime,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events, hasLength(2));
      expect(events[0].type, SkillChangeType.created);
      expect(events[0].skillUuid, local.uuid);
      expect(events[1].type, SkillChangeType.updated);
      expect(events[1].skill!.name, '技能A-更新');
    });
  });

  // ═══════════════════════════════════════════════════
  // B. 全局技能同步合并逻辑
  // ═══════════════════════════════════════════════════

  group('全局技能同步合并逻辑', () {
    late String testDbPath;
    late String deviceId;
    late GlobalSkillStore store;
    late GlobalSkillManager manager;

    setUp(() async {
      _testCounter++;
      testDbPath =
          '${Directory.systemTemp.path}/wenzagent_global_skill_sync_test_$_testCounter';
      await Directory(testDbPath).create(recursive: true);
      deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';
      await DatabaseManager.getInstance(deviceId).initialize(
        storagePath: testDbPath,
      );
      store = GlobalSkillStore(deviceId: deviceId);
      manager = GlobalSkillManager.getInstance(deviceId);
    });

    tearDown(() async {
      (manager as GlobalSkillManagerImpl).dispose();
      await DatabaseManager.getInstance(deviceId).close();
      DatabaseManager.removeInstance(deviceId);
      GlobalSkillManager.removeInstance(deviceId);
      try {
        await Directory(testDbPath).delete(recursive: true);
      } catch (_) {}
    });

    GlobalSkillEntity createGlobalSkill({
      String? uuid,
      String? name,
      String? description,
      String skillType = 'config',
      String? config,
      int enabled = 1,
      int sortOrder = 0,
      int deleted = 0,
      DateTime? deleteTime,
      DateTime? createTime,
      DateTime? updateTime,
    }) {
      final now = DateTime.now();
      return GlobalSkillEntity(
        uuid: uuid ?? const Uuid().v4(),
        name: name ?? 'Global Skill',
        description: description,
        skillType: skillType,
        config: config,
        enabled: enabled,
        sortOrder: sortOrder,
        deleted: deleted,
        deleteTime: deleteTime,
        createTime: createTime ?? now,
        updateTime: updateTime ?? now,
      );
    }

    /// 模拟 DataSyncManager._mergeAndSaveGlobalSkill 的合并逻辑
    Future<bool> simulateMergeAndSaveGlobalSkill(
      GlobalSkillEntity existing,
      GlobalSkillEntity remote,
    ) async {
      final mergeResult = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: existing.deleteTime,
        localDeleted: existing.deleted,
        remoteDeleteTime: remote.deleteTime,
        remoteDeleted: remote.deleted,
        localUpdateTime: existing.updateTime,
        remoteUpdateTime: remote.updateTime,
      );
      final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
          existing.updateTime, remote.updateTime);
      final shouldUpdateDelete =
          mergeResult.mergedDeleteTime != existing.deleteTime ||
              mergeResult.mergedDeleted != existing.deleted;
      if (shouldUpdateData || shouldUpdateDelete) {
        final merged = (shouldUpdateData ? remote : existing).copyWith(
          deleted: mergeResult.mergedDeleted,
          deleteTime: mergeResult.mergedDeleteTime,
        );
        await store.save(merged);
        return true;
      }
      return false;
    }

    test('远程新增全局技能 → 本地不存在 → 直接创建', () async {
      final remote = createGlobalSkill(
        name: '远程全局技能',
        config: '{"type":"global"}',
      );

      final existing = await store.findIncludingDeleted(remote.uuid);
      expect(existing, isNull);

      await store.save(remote);

      final fetched = await store.find(remote.uuid);
      expect(fetched, isNotNull);
      expect(fetched!.name, equals('远程全局技能'));
    });

    test('远程已删除全局技能 → 本地不存在 → 不创建', () async {
      final remote = createGlobalSkill(
        name: '已删除全局技能',
        deleted: 1,
        deleteTime: DateTime.now(),
      );

      final existing = await store.findIncludingDeleted(remote.uuid);
      expect(existing, isNull);

      if (existing == null && remote.deleted != 1) {
        await store.save(remote);
        fail('不应创建已删除的全局技能');
      }

      final fetched = await store.findIncludingDeleted(remote.uuid);
      expect(fetched, isNull);
    });

    test('远程数据更新 → 合并后采用远程数据', () async {
      final now = DateTime.now();

      final local = createGlobalSkill(
        name: '本地全局技能',
        config: '{"v":"1"}',
        updateTime: now.subtract(const Duration(hours: 1)),
      );
      await store.save(local);

      final remote = local.copyWith(
        name: '远程更新全局技能',
        config: '{"v":"2"}',
        updateTime: now,
      );

      final existing = await store.findIncludingDeleted(local.uuid);
      final changed = await simulateMergeAndSaveGlobalSkill(existing!, remote);
      expect(changed, isTrue);

      final fetched = await store.find(local.uuid);
      expect(fetched, isNotNull);
      expect(fetched!.name, equals('远程更新全局技能'));
      expect(fetched.config, equals('{"v":"2"}'));
    });

    test('远程删除 → 本地未删除 → 合并后标记删除', () async {
      final now = DateTime.now();

      final local = createGlobalSkill(
        name: '待删除全局技能',
        updateTime: now.subtract(const Duration(hours: 1)),
      );
      await store.save(local);

      final remote = local.copyWith(
        deleted: 1,
        deleteTime: now,
        updateTime: now,
      );

      final existing = await store.findIncludingDeleted(local.uuid);
      final changed = await simulateMergeAndSaveGlobalSkill(existing!, remote);
      expect(changed, isTrue);

      final fetched = await store.findIncludingDeleted(local.uuid);
      expect(fetched, isNotNull);
      expect(fetched!.deleted, equals(1));
    });

    test('远程复活 → 允许复活', () async {
      final now = DateTime.now();

      final local = createGlobalSkill(
        name: '已删除全局技能',
        deleted: 1,
        deleteTime: now.subtract(const Duration(hours: 2)),
        updateTime: now.subtract(const Duration(hours: 2)),
      );
      await store.save(local);

      final remote = local.copyWith(
        deleted: 0,
        deleteTime: null,
        name: '已复活全局技能',
        updateTime: now,
      );

      final existing = await store.findIncludingDeleted(local.uuid);
      final changed = await simulateMergeAndSaveGlobalSkill(existing!, remote);
      expect(changed, isTrue);

      final fetched = await store.findIncludingDeleted(local.uuid);
      expect(fetched, isNotNull);
      expect(fetched!.deleted, equals(0));
      expect(fetched!.name, equals('已复活全局技能'));
    });

    test('变更事件正确触发', () async {
      final events = <GlobalSkillChangeEvent>[];
      manager.onSkillChanged.listen(events.add);

      final now = DateTime.now();

      final local = createGlobalSkill(
        name: '全局技能A',
        updateTime: now.subtract(const Duration(hours: 1)),
      );
      await manager.createSkill(local);

      final remote = local.copyWith(
        name: '全局技能A-更新',
        updateTime: now,
      );
      // 使用 manager 触发事件
      await manager.updateSkill(remote);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events, hasLength(2));
      expect(events[0].type, GlobalSkillChangeType.created);
      expect(events[1].type, GlobalSkillChangeType.updated);
      expect(events[1].skill!.name, '全局技能A-更新');
    });
  });

  // ═══════════════════════════════════════════════════
  // C. 跨设备技能同步模拟
  // ═══════════════════════════════════════════════════

  group('跨设备员工技能同步模拟', () {
    late String testDbPath;
    late String deviceIdA;
    late String deviceIdB;
    late SkillStore storeA;
    late SkillStore storeB;
    late SkillManager managerA;
    late SkillManager managerB;

    setUp(() async {
      _testCounter++;
      testDbPath =
          '${Directory.systemTemp.path}/wenzagent_skill_cross_device_test_$_testCounter';
      await Directory(testDbPath).create(recursive: true);

      deviceIdA = 'dev-A-${const Uuid().v4().substring(0, 8)}';
      deviceIdB = 'dev-B-${const Uuid().v4().substring(0, 8)}';

      await DatabaseManager.getInstance(deviceIdA).initialize(
        storagePath: testDbPath,
      );
      await DatabaseManager.getInstance(deviceIdB).initialize(
        storagePath: testDbPath,
      );

      storeA = SkillStore(deviceId: deviceIdA);
      storeB = SkillStore(deviceId: deviceIdB);
      managerA = SkillManager.getInstance(deviceIdA);
      managerB = SkillManager.getInstance(deviceIdB);
    });

    tearDown(() async {
      (managerA as SkillManagerImpl).dispose();
      (managerB as SkillManagerImpl).dispose();
      await DatabaseManager.getInstance(deviceIdA).close();
      await DatabaseManager.getInstance(deviceIdB).close();
      DatabaseManager.removeInstance(deviceIdA);
      DatabaseManager.removeInstance(deviceIdB);
      SkillManager.removeInstance(deviceIdA);
      SkillManager.removeInstance(deviceIdB);
      try {
        await Directory(testDbPath).delete(recursive: true);
      } catch (_) {}
    });

    AiEmployeeSkillEntity createSkillEntity({
      String? uuid,
      String? employeeId,
      String? name,
      String skillType = 'mcp',
      String? config,
      int enabled = 1,
      int deleted = 0,
      DateTime? deleteTime,
      DateTime? createTime,
      DateTime? updateTime,
    }) {
      final now = DateTime.now();
      return AiEmployeeSkillEntity(
        uuid: uuid ?? const Uuid().v4(),
        employeeId: employeeId ?? 'emp-${const Uuid().v4().substring(0, 8)}',
        name: name ?? 'Test Skill',
        skillType: skillType,
        config: config,
        enabled: enabled,
        deleted: deleted,
        deleteTime: deleteTime,
        createTime: createTime ?? now,
        updateTime: updateTime ?? now,
      );
    }

    /// 模拟从设备A同步技能到设备B（使用 store 直接操作保留原始时间戳）
    /// 注意：同步时需要将设备A的技能的 deviceId 重置为设备B的 deviceId
    Future<void> simulateSyncFromAToB() async {
      final allSkillsA = await storeA.findAll();
      for (final remote in allSkillsA) {
        // 模拟同步传输：重置 deviceId 为目标设备的 ID
        final remoteForB = remote.copyWith(deviceId: deviceIdB);
        final existing = await storeB.findIncludingDeleted(remote.uuid);
        if (existing == null) {
          if (remoteForB.deleted != 1) {
            await storeB.saveWithDeviceId(deviceIdB, remoteForB);
          }
        } else {
          final mergeResult = StoreMergeUtil.mergeDeleteState(
            localDeleteTime: existing.deleteTime,
            localDeleted: existing.deleted,
            remoteDeleteTime: remoteForB.deleteTime,
            remoteDeleted: remoteForB.deleted,
            localUpdateTime: existing.updateTime,
            remoteUpdateTime: remoteForB.updateTime,
          );
          final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
              existing.updateTime, remoteForB.updateTime);
          final shouldUpdateDelete =
              mergeResult.mergedDeleteTime != existing.deleteTime ||
                  mergeResult.mergedDeleted != existing.deleted;
          if (shouldUpdateData || shouldUpdateDelete) {
            final merged = (shouldUpdateData ? remoteForB : existing).copyWith(
              deleted: mergeResult.mergedDeleted,
              deleteTime: mergeResult.mergedDeleteTime,
            );
            await storeB.saveWithDeviceId(deviceIdB, merged);
          }
        }
      }
    }

    test('设备A创建技能 → 同步到设备B', () async {
      const empId = 'emp-cross-1';

      // 设备A创建技能
      await storeA.saveWithDeviceId(
        deviceIdA,
        createSkillEntity(
          employeeId: empId,
          name: 'A设备技能',
          config: '{"server":"A"}',
        ),
      );

      // 同步前，设备B没有技能
      var skillsB = await storeB.findByEmployeeWithDeviceId(deviceIdB, empId);
      expect(skillsB, isEmpty);

      // 执行同步
      await simulateSyncFromAToB();

      // 同步后，设备B有技能
      skillsB = await storeB.findByEmployeeWithDeviceId(deviceIdB, empId);
      expect(skillsB, hasLength(1));
      expect(skillsB.first.name, equals('A设备技能'));
    });

    test('设备A更新技能 → 同步到设备B', () async {
      const empId = 'emp-cross-2';
      final now = DateTime.now();

      // 设备A创建技能
      final skillA = createSkillEntity(
        employeeId: empId,
        name: '原始技能',
        config: '{"v":"1"}',
        updateTime: now.subtract(const Duration(hours: 1)),
      );
      await storeA.saveWithDeviceId(deviceIdA, skillA);

      // 先同步到B
      await simulateSyncFromAToB();

      // 设备A更新技能
      await storeA.saveWithDeviceId(
        deviceIdA,
        skillA.copyWith(
          name: '更新后技能',
          config: '{"v":"2"}',
          updateTime: now,
        ),
      );

      // 再次同步
      await simulateSyncFromAToB();

      final skillsB = await storeB.findByEmployeeWithDeviceId(deviceIdB, empId);
      expect(skillsB, hasLength(1));
      expect(skillsB.first.name, equals('更新后技能'));
      expect(skillsB.first.config, equals('{"v":"2"}'));
    });

    test('设备A删除技能 → 同步到设备B（软删除传播）', () async {
      const empId = 'emp-cross-3';

      // 设备A创建技能
      final skillA = createSkillEntity(
        employeeId: empId,
        name: '待删除技能',
      );
      await storeA.saveWithDeviceId(deviceIdA, skillA);

      // 先同步到B
      await simulateSyncFromAToB();

      // 设备A删除技能
      await storeA.delete(null, skillA.uuid);

      // 再次同步
      await simulateSyncFromAToB();

      // 设备B也应该看不到该技能
      final skillsB = await storeB.findByEmployeeWithDeviceId(deviceIdB, empId);
      expect(skillsB, isEmpty);

      // 但通过 findIncludingDeleted 能查到已删除记录
      final deletedB = await storeB.findIncludingDeleted(skillA.uuid);
      expect(deletedB, isNotNull);
      expect(deletedB!.deleted, equals(1));
    });

    test('设备A和B都有技能 → 互相同步不冲突', () async {
      const empId = 'emp-cross-4';

      // 设备A创建技能1
      await storeA.saveWithDeviceId(
        deviceIdA,
        createSkillEntity(employeeId: empId, name: 'A技能'),
      );

      // 设备B创建技能2
      await storeB.saveWithDeviceId(
        deviceIdB,
        createSkillEntity(employeeId: empId, name: 'B技能'),
      );

      // A → B 同步
      await simulateSyncFromAToB();

      final skillsB = await storeB.findByEmployeeWithDeviceId(deviceIdB, empId);
      expect(skillsB, hasLength(2));
      final names = skillsB.map((s) => s.name).toSet();
      expect(names, containsAll(['A技能', 'B技能']));
    });

    test('设备A和B修改同一技能 → 取 updateTime 更新的版本', () async {
      const empId = 'emp-cross-5';
      final now = DateTime.now();

      // 设备A创建技能
      final skillA = createSkillEntity(
        employeeId: empId,
        name: '原始技能',
        updateTime: now.subtract(const Duration(hours: 2)),
      );
      await storeA.saveWithDeviceId(deviceIdA, skillA);

      // 先同步到B
      await simulateSyncFromAToB();

      // 设备B修改（较旧）
      final skillB = (await storeB.find(null, skillA.uuid))!;
      await storeB.saveWithDeviceId(
        deviceIdB,
        skillB.copyWith(
          name: 'B修改的技能',
          updateTime: now.subtract(const Duration(hours: 1)),
        ),
      );

      // 设备A修改（较新）
      await storeA.saveWithDeviceId(
        deviceIdA,
        skillA.copyWith(
          name: 'A修改的技能',
          updateTime: now,
        ),
      );

      // A → B 同步
      await simulateSyncFromAToB();

      // 设备B应该采用A的版本（updateTime 更新）
      final fetchedB = await storeB.find(null, skillA.uuid);
      expect(fetchedB!.name, equals('A修改的技能'));
    });

    test('多技能批量同步', () async {
      const empId = 'emp-cross-batch';

      // 设备A创建3个技能
      for (var i = 1; i <= 3; i++) {
        await storeA.saveWithDeviceId(
          deviceIdA,
          createSkillEntity(
            employeeId: empId,
            name: '技能$i',
            skillType: i == 1 ? 'mcp' : (i == 2 ? 'config' : 'folder'),
            config: '{"index":$i}',
          ),
        );
      }

      // 同步到B
      await simulateSyncFromAToB();

      final skillsB = await storeB.findByEmployeeWithDeviceId(deviceIdB, empId);
      expect(skillsB, hasLength(3));
      for (var i = 1; i <= 3; i++) {
        expect(skillsB.any((s) => s.name == '技能$i'), isTrue);
      }
    });
  });

  // ═══════════════════════════════════════════════════
  // D. 技能删除同步
  // ═══════════════════════════════════════════════════

  group('deleteSkillWithSync 流程模拟', () {
    late String testDbPath;
    late String deviceId;
    late SkillStore store;
    late SkillManager manager;

    setUp(() async {
      _testCounter++;
      testDbPath =
          '${Directory.systemTemp.path}/wenzagent_skill_delete_sync_test_$_testCounter';
      await Directory(testDbPath).create(recursive: true);
      deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';
      await DatabaseManager.getInstance(deviceId).initialize(
        storagePath: testDbPath,
      );
      store = SkillStore(deviceId: deviceId);
      manager = SkillManager.getInstance(deviceId);
    });

    tearDown(() async {
      (manager as SkillManagerImpl).dispose();
      await DatabaseManager.getInstance(deviceId).close();
      DatabaseManager.removeInstance(deviceId);
      SkillManager.removeInstance(deviceId);
      try {
        await Directory(testDbPath).delete(recursive: true);
      } catch (_) {}
    });

    AiEmployeeSkillEntity createSkillEntity({
      String? uuid,
      String? employeeId,
      String? name,
      String skillType = 'mcp',
      String? config,
    }) {
      final now = DateTime.now();
      return AiEmployeeSkillEntity(
        uuid: uuid ?? const Uuid().v4(),
        employeeId: employeeId ?? 'emp-${const Uuid().v4().substring(0, 8)}',
        name: name ?? 'Test Skill',
        skillType: skillType,
        config: config,
        createTime: now,
        updateTime: now,
      );
    }

    /// 模拟 DataSyncManager.deleteSkillWithSync 的核心逻辑
    Future<AiEmployeeSkillEntity?> simulateDeleteSkillWithSync(
        String skillId) async {
      final skill = await store.findIncludingDeleted(skillId);
      await manager.deleteSkill(skillId);
      if (skill != null) {
        return skill.copyWith(
          deleted: 1,
          deleteTime: DateTime.now(),
          updateTime: DateTime.now(),
        );
      }
      return null;
    }

    test('删除存在的技能 → 返回带删除标记的快照', () async {
      const empId = 'emp-del-sync-1';
      final skill = createSkillEntity(employeeId: empId, name: '待删除技能');
      await manager.createSkill(skill);

      final deleteSnapshot = await simulateDeleteSkillWithSync(skill.uuid);

      expect(deleteSnapshot, isNotNull);
      expect(deleteSnapshot!.uuid, equals(skill.uuid));
      expect(deleteSnapshot.deleted, equals(1));
      expect(deleteSnapshot.deleteTime, isNotNull);
      expect(deleteSnapshot.name, equals('待删除技能'));

      // 验证本地已删除
      final fetched = await store.find(null, skill.uuid);
      expect(fetched, isNull);
    });

    test('删除不存在的技能 → 返回 null', () async {
      final result = await simulateDeleteSkillWithSync('non-existent-uuid');
      expect(result, isNull);
    });

    test('删除快照可用于同步到其他设备', () async {
      const empId = 'emp-del-sync-broadcast';

      // 设备A创建并删除技能
      final skill = createSkillEntity(employeeId: empId, name: '广播删除技能');
      await manager.createSkill(skill);
      final deleteSnapshot = await simulateDeleteSkillWithSync(skill.uuid);

      // 模拟设备B收到删除快照后的合并
      // （设备B之前同步过该技能）
      // 先在B的数据库中创建一份
      final skillOnB = skill.copyWith();
      await store.saveWithDeviceId(deviceId, skillOnB);

      // 模拟收到删除同步数据
      final existingOnB = await store.findIncludingDeleted(skill.uuid);
      expect(existingOnB, isNotNull);
      expect(existingOnB!.deleted, equals(0));

      // 合并删除快照
      final mergeResult = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: existingOnB.deleteTime,
        localDeleted: existingOnB.deleted,
        remoteDeleteTime: deleteSnapshot!.deleteTime,
        remoteDeleted: deleteSnapshot.deleted,
        localUpdateTime: existingOnB.updateTime,
        remoteUpdateTime: deleteSnapshot.updateTime,
      );
      final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
          existingOnB.updateTime, deleteSnapshot.updateTime);
      final shouldUpdateDelete =
          mergeResult.mergedDeleteTime != existingOnB.deleteTime ||
              mergeResult.mergedDeleted != existingOnB.deleted;

      expect(shouldUpdateData || shouldUpdateDelete, isTrue);

      final merged = (shouldUpdateData ? deleteSnapshot : existingOnB).copyWith(
        deleted: mergeResult.mergedDeleted,
        deleteTime: mergeResult.mergedDeleteTime,
      );
      await store.saveWithDeviceId(deviceId, merged);

      // 设备B的技能也被标记删除
      final fetchedB = await store.find(null, skill.uuid);
      expect(fetchedB, isNull);

      final deletedB = await store.findIncludingDeleted(skill.uuid);
      expect(deletedB!.deleted, equals(1));
    });

    test('连续删除和恢复 → 正确处理', () async {
      const empId = 'emp-del-sync-restore';
      final now = DateTime.now();

      // 创建 → 删除 → 恢复
      final skill = createSkillEntity(employeeId: empId, name: '恢复测试');
      await manager.createSkill(skill);
      await manager.deleteSkill(skill.uuid);

      // 模拟远程恢复（updateTime 更新）
      final restored = skill.copyWith(
        deleted: 0,
        deleteTime: null,
        name: '已恢复技能',
        updateTime: now.add(const Duration(hours: 1)),
      );

      final existing = await store.findIncludingDeleted(skill.uuid);
      expect(existing!.deleted, equals(1));

      final mergeResult = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: existing.deleteTime,
        localDeleted: existing.deleted,
        remoteDeleteTime: restored.deleteTime,
        remoteDeleted: restored.deleted,
        localUpdateTime: existing.updateTime,
        remoteUpdateTime: restored.updateTime,
      );

      expect(mergeResult.mergedDeleted, equals(0));
      expect(mergeResult.mergedDeleteTime, isNull);

      await store.saveWithDeviceId(
        deviceId,
        restored.copyWith(
          deleted: mergeResult.mergedDeleted,
          deleteTime: mergeResult.mergedDeleteTime,
        ),
      );

      final fetched = await store.find(null, skill.uuid);
      expect(fetched, isNotNull);
      expect(fetched!.deleted, equals(0));
      expect(fetched.name, equals('已恢复技能'));
    });
  });

  // ═══════════════════════════════════════════════════
  // E. 序列化往返（同步场景一致性）
  // ═══════════════════════════════════════════════════

  group('同步场景序列化往返', () {
    test('AiEmployeeSkillEntity toMap/fromMap 在同步中保持一致', () {
      final now = DateTime.now();

      final skill = AiEmployeeSkillEntity(
        uuid: 'skill-sync-123',
        employeeId: 'emp-sync-123',
        deviceId: 'dev-sync-123',
        name: '同步测试技能',
        description: '测试序列化往返',
        skillType: 'mcp',
        config: '{"server":"sync-test","port":8080}',
        enabled: 1,
        sortOrder: 5,
        deleted: 0,
        createTime: now.subtract(const Duration(days: 1)),
        updateTime: now,
      );

      // 模拟同步：toMap → 传输 → fromMap
      final map = skill.toMap();
      final restored = AiEmployeeSkillEntity.fromMap(map);

      expect(restored.uuid, equals(skill.uuid));
      expect(restored.employeeId, equals(skill.employeeId));
      expect(restored.deviceId, equals(skill.deviceId));
      expect(restored.name, equals(skill.name));
      expect(restored.description, equals(skill.description));
      expect(restored.skillType, equals(skill.skillType));
      expect(restored.config, equals(skill.config));
      expect(restored.enabled, equals(skill.enabled));
      expect(restored.sortOrder, equals(skill.sortOrder));
      expect(restored.deleted, equals(skill.deleted));
      expect(
        restored.createTime.millisecondsSinceEpoch,
        equals(skill.createTime.millisecondsSinceEpoch),
      );
      expect(
        restored.updateTime.millisecondsSinceEpoch,
        equals(skill.updateTime.millisecondsSinceEpoch),
      );
    });

    test('已删除的 AiEmployeeSkillEntity 序列化往返', () {
      final now = DateTime.now();
      final skill = AiEmployeeSkillEntity(
        uuid: 'skill-del-sync',
        employeeId: 'emp-del',
        name: '已删除技能',
        deleted: 1,
        deleteTime: now,
        createTime: now.subtract(const Duration(days: 1)),
        updateTime: now,
      );

      final map = skill.toMap();
      final restored = AiEmployeeSkillEntity.fromMap(map);

      expect(restored.deleted, equals(1));
      expect(restored.deleteTime, isNotNull);
      expect(
        restored.deleteTime!.millisecondsSinceEpoch,
        equals(now.millisecondsSinceEpoch),
      );
    });

    test('GlobalSkillEntity toMap/fromMap 在同步中保持一致', () {
      final now = DateTime.now();

      final skill = GlobalSkillEntity(
        uuid: 'global-sync-123',
        name: '全局同步技能',
        description: '全局技能描述',
        skillType: 'config',
        config: '{"type":"global","version":2}',
        enabled: 1,
        sortOrder: 3,
        deleted: 0,
        createTime: now.subtract(const Duration(days: 1)),
        updateTime: now,
      );

      final map = skill.toMap();
      final restored = GlobalSkillEntity.fromMap(map);

      expect(restored.uuid, equals(skill.uuid));
      expect(restored.name, equals(skill.name));
      expect(restored.description, equals(skill.description));
      expect(restored.skillType, equals(skill.skillType));
      expect(restored.config, equals(skill.config));
      expect(restored.enabled, equals(skill.enabled));
      expect(restored.sortOrder, equals(skill.sortOrder));
      expect(restored.deleted, equals(skill.deleted));
    });

    test('已删除的 GlobalSkillEntity 序列化往返', () {
      final now = DateTime.now();
      final skill = GlobalSkillEntity(
        uuid: 'global-del-sync',
        name: '已删除全局技能',
        deleted: 1,
        deleteTime: now,
        createTime: now.subtract(const Duration(days: 1)),
        updateTime: now,
      );

      final map = skill.toMap();
      final restored = GlobalSkillEntity.fromMap(map);

      expect(restored.deleted, equals(1));
      expect(restored.deleteTime, isNotNull);
    });

    test('copyWith 后序列化往返保持一致', () {
      final now = DateTime.now();
      final original = AiEmployeeSkillEntity(
        uuid: 'skill-copy-sync',
        employeeId: 'emp-copy',
        name: '原始',
        skillType: 'config',
        config: '{"v":1}',
        createTime: now,
        updateTime: now,
      );

      final modified = original.copyWith(
        name: '修改后',
        config: '{"v":2}',
        updateTime: now.add(const Duration(hours: 1)),
      );

      final map = modified.toMap();
      final restored = AiEmployeeSkillEntity.fromMap(map);

      expect(restored.name, equals('修改后'));
      expect(restored.config, equals('{"v":2}'));
      expect(restored.uuid, equals(original.uuid));
      expect(restored.employeeId, equals(original.employeeId));
    });
  });

  // ═══════════════════════════════════════════════════
  // F. StoreMergeUtil 在技能同步场景中的行为
  // ═══════════════════════════════════════════════════

  group('StoreMergeUtil 技能同步场景', () {
    test('双方都未删除 → mergedDeleted=0', () {
      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: null,
        localDeleted: 0,
        remoteDeleteTime: null,
        remoteDeleted: 0,
      );
      expect(result.mergedDeleted, equals(0));
      expect(result.mergedDeleteTime, isNull);
    });

    test('本地已删除 + 远程未删除 + 远程更新 → 允许复活', () {
      final now = DateTime.now();
      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: now.subtract(const Duration(hours: 1)),
        localDeleted: 1,
        remoteDeleteTime: null,
        remoteDeleted: 0,
        localUpdateTime: now.subtract(const Duration(hours: 1)),
        remoteUpdateTime: now,
      );
      expect(result.mergedDeleted, equals(0));
      expect(result.mergedDeleteTime, isNull);
    });

    test('本地未删除 + 远程已删除 + 远程更新 → 标记删除', () {
      final now = DateTime.now();
      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: null,
        localDeleted: 0,
        remoteDeleteTime: now,
        remoteDeleted: 1,
        localUpdateTime: now.subtract(const Duration(hours: 1)),
        remoteUpdateTime: now,
      );
      expect(result.mergedDeleted, equals(1));
      expect(result.mergedDeleteTime, isNotNull);
    });

    test('双方都删除 → 取 deleteTime 更大的', () {
      final dt1 = DateTime(2024, 6, 15, 10, 0, 0);
      final dt2 = DateTime(2024, 6, 15, 12, 0, 0);

      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: dt1,
        localDeleted: 1,
        remoteDeleteTime: dt2,
        remoteDeleted: 1,
        localUpdateTime: dt1,
        remoteUpdateTime: dt2,
      );
      expect(result.mergedDeleted, equals(1));
      expect(
        result.mergedDeleteTime!.millisecondsSinceEpoch,
        equals(dt2.millisecondsSinceEpoch),
      );
    });

    test('shouldUpdateData 远程更新 → true', () {
      final now = DateTime.now();
      expect(
        StoreMergeUtil.shouldUpdateData(
          now.subtract(const Duration(hours: 1)),
          now,
        ),
        isTrue,
      );
    });

    test('shouldUpdateData 远程较旧 → false', () {
      final now = DateTime.now();
      expect(
        StoreMergeUtil.shouldUpdateData(
          now,
          now.subtract(const Duration(hours: 1)),
        ),
        isFalse,
      );
    });

    test('shouldUpdateData 时间相同 → false', () {
      final same = DateTime(2024, 6, 15, 12, 0, 0);
      expect(StoreMergeUtil.shouldUpdateData(same, same), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════
  // G. HostRpcMethods 技能同步逻辑模拟
  // ═══════════════════════════════════════════════════

  group('HostRpcMethods 技能同步逻辑模拟', () {
    late String testDbPath;
    late String deviceId;
    late SkillStore store;
    late SkillManager skillManager;

    setUp(() async {
      _testCounter++;
      testDbPath =
          '${Directory.systemTemp.path}/wenzagent_skill_rpc_sync_test_$_testCounter';
      await Directory(testDbPath).create(recursive: true);
      deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';
      await DatabaseManager.getInstance(deviceId).initialize(
        storagePath: testDbPath,
      );
      store = SkillStore(deviceId: deviceId);
      skillManager = SkillManager.getInstance(deviceId);
    });

    tearDown(() async {
      (skillManager as SkillManagerImpl).dispose();
      await DatabaseManager.getInstance(deviceId).close();
      DatabaseManager.removeInstance(deviceId);
      SkillManager.removeInstance(deviceId);
      try {
        await Directory(testDbPath).delete(recursive: true);
      } catch (_) {}
    });

    /// 模拟 HostRpcConfig.methodSyncSkills 的处理逻辑
    /// 使用 store 直接操作以保留原始 updateTime
    Future<int> simulateSyncSkills(
        List<AiEmployeeSkillEntity> skills) async {
      for (final skill in skills) {
        final existing = await store.findIncludingDeleted(skill.uuid);
        if (existing == null) {
          await store.saveWithDeviceId(deviceId, skill);
        } else {
          final mergeResult = StoreMergeUtil.mergeDeleteState(
            localDeleteTime: existing.deleteTime,
            localDeleted: existing.deleted,
            remoteDeleteTime: skill.deleteTime,
            remoteDeleted: skill.deleted,
            localUpdateTime: existing.updateTime,
            remoteUpdateTime: skill.updateTime,
          );
          final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
              existing.updateTime, skill.updateTime);
          final shouldUpdateDelete =
              mergeResult.mergedDeleteTime != existing.deleteTime ||
                  mergeResult.mergedDeleted != existing.deleted;

          if (shouldUpdateData || shouldUpdateDelete) {
            final base = shouldUpdateData ? skill : existing;
            await store.saveWithDeviceId(
              deviceId,
              base.copyWith(
                deleted: mergeResult.mergedDeleted,
                deleteTime: mergeResult.mergedDeleteTime,
              ),
            );
          }
        }
      }
      return skills.length;
    }

    /// 模拟 HostRpcConfig.methodGetAllSkills 的处理逻辑
    Future<List<Map<String, dynamic>>> simulateGetAllSkills(
        {bool includeDeleted = false}) async {
      final skills = await store.findAll();
      final filtered = includeDeleted
          ? skills
          : skills.where((s) => s.deleted != 1).toList();
      return filtered.map((s) => s.toMap()).toList();
    }

    test('methodSyncSkills 批量同步新技能', () async {
      final now = DateTime.now();
      final skills = List.generate(
        3,
        (i) => AiEmployeeSkillEntity(
          uuid: 'rpc-skill-$i',
          employeeId: 'emp-rpc',
          name: 'RPC技能$i',
          skillType: 'mcp',
          config: '{"index":$i}',
          createTime: now,
          updateTime: now,
        ),
      );

      final count = await simulateSyncSkills(skills);
      expect(count, equals(3));

      final allSkills = await simulateGetAllSkills();
      expect(allSkills, hasLength(3));
    });

    test('methodSyncSkills 合并已存在的技能', () async {
      final now = DateTime.now();

      // 先创建本地技能
      await store.saveWithDeviceId(
        deviceId,
        AiEmployeeSkillEntity(
          uuid: 'rpc-merge-1',
          employeeId: 'emp-rpc-merge',
          name: '本地技能',
          config: '{"v":"local"}',
          createTime: now.subtract(const Duration(hours: 2)),
          updateTime: now.subtract(const Duration(hours: 1)),
        ),
      );

      // 模拟远程同步（更新版本）
      final count = await simulateSyncSkills([
        AiEmployeeSkillEntity(
          uuid: 'rpc-merge-1',
          employeeId: 'emp-rpc-merge',
          name: '远程更新技能',
          config: '{"v":"remote"}',
          createTime: now.subtract(const Duration(hours: 2)),
          updateTime: now,
        ),
      ]);
      expect(count, equals(1));

      final fetched = await store.find(null, 'rpc-merge-1');
      expect(fetched, isNotNull);
      expect(fetched!.name, equals('远程更新技能'));
      expect(fetched.config, equals('{"v":"remote"}'));
    });

    test('methodGetAllSkills 含已删除', () async {
      final now = DateTime.now();

      await store.saveWithDeviceId(
        deviceId,
        AiEmployeeSkillEntity(
          uuid: 'rpc-del-1',
          employeeId: 'emp-rpc-del',
          name: '正常技能',
          createTime: now,
          updateTime: now,
        ),
      );

      await store.saveWithDeviceId(
        deviceId,
        AiEmployeeSkillEntity(
          uuid: 'rpc-del-2',
          employeeId: 'emp-rpc-del',
          name: '待删除技能',
          createTime: now,
          updateTime: now,
        ),
      );
      await store.delete(null, 'rpc-del-2');

      // 不含已删除
      final activeSkills = await simulateGetAllSkills(includeDeleted: false);
      expect(activeSkills, hasLength(1));

      // 含已删除
      final allSkills = await simulateGetAllSkills(includeDeleted: true);
      expect(allSkills, hasLength(2));
    });

    test('methodSyncSkills 处理删除同步', () async {
      final now = DateTime.now();

      // 先创建
      await store.saveWithDeviceId(
        deviceId,
        AiEmployeeSkillEntity(
          uuid: 'rpc-sync-del',
          employeeId: 'emp-rpc-sync-del',
          name: '同步删除测试',
          createTime: now.subtract(const Duration(hours: 1)),
          updateTime: now.subtract(const Duration(hours: 1)),
        ),
      );

      // 模拟远程删除同步
      await simulateSyncSkills([
        AiEmployeeSkillEntity(
          uuid: 'rpc-sync-del',
          employeeId: 'emp-rpc-sync-del',
          name: '同步删除测试',
          deleted: 1,
          deleteTime: now,
          createTime: now.subtract(const Duration(hours: 1)),
          updateTime: now,
        ),
      ]);

      final fetched = await store.find(null, 'rpc-sync-del');
      expect(fetched, isNull);

      final deleted = await store.findIncludingDeleted('rpc-sync-del');
      expect(deleted, isNotNull);
      expect(deleted!.deleted, equals(1));
    });
  });

  // ═══════════════════════════════════════════════════
  // H. 全局技能 HostRpcMethods 同步逻辑模拟
  // ═══════════════════════════════════════════════════

  group('HostRpcMethods 全局技能同步逻辑模拟', () {
    late String testDbPath;
    late String deviceId;
    late GlobalSkillStore store;
    late GlobalSkillManager globalSkillManager;

    setUp(() async {
      _testCounter++;
      testDbPath =
          '${Directory.systemTemp.path}/wenzagent_global_skill_rpc_test_$_testCounter';
      await Directory(testDbPath).create(recursive: true);
      deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';
      await DatabaseManager.getInstance(deviceId).initialize(
        storagePath: testDbPath,
      );
      store = GlobalSkillStore(deviceId: deviceId);
      globalSkillManager = GlobalSkillManager.getInstance(deviceId);
    });

    tearDown(() async {
      (globalSkillManager as GlobalSkillManagerImpl).dispose();
      await DatabaseManager.getInstance(deviceId).close();
      DatabaseManager.removeInstance(deviceId);
      GlobalSkillManager.removeInstance(deviceId);
      try {
        await Directory(testDbPath).delete(recursive: true);
      } catch (_) {}
    });

    /// 模拟 HostRpcConfig.methodSyncGlobalSkills 的处理逻辑
    Future<int> simulateSyncGlobalSkills(
        List<GlobalSkillEntity> skills) async {
      for (final skill in skills) {
        final existing = await store.findIncludingDeleted(skill.uuid);
        if (existing == null) {
          await store.save(skill);
        } else {
          final mergeResult = StoreMergeUtil.mergeDeleteState(
            localDeleteTime: existing.deleteTime,
            localDeleted: existing.deleted,
            remoteDeleteTime: skill.deleteTime,
            remoteDeleted: skill.deleted,
            localUpdateTime: existing.updateTime,
            remoteUpdateTime: skill.updateTime,
          );
          final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
              existing.updateTime, skill.updateTime);
          final shouldUpdateDelete =
              mergeResult.mergedDeleteTime != existing.deleteTime ||
                  mergeResult.mergedDeleted != existing.deleted;

          if (shouldUpdateData || shouldUpdateDelete) {
            final base = shouldUpdateData ? skill : existing;
            await store.save(base.copyWith(
              deleted: mergeResult.mergedDeleted,
              deleteTime: mergeResult.mergedDeleteTime,
            ));
          }
        }
      }
      return skills.length;
    }

    test('批量同步全局技能', () async {
      final now = DateTime.now();
      final skills = List.generate(
        2,
        (i) => GlobalSkillEntity(
          uuid: 'global-rpc-$i',
          name: '全局RPC技能$i',
          skillType: 'config',
          config: '{"global":$i}',
          createTime: now,
          updateTime: now,
        ),
      );

      final count = await simulateSyncGlobalSkills(skills);
      expect(count, equals(2));

      final all = await store.findAll();
      expect(all, hasLength(2));
    });

    test('同步已删除的全局技能 → 合并删除状态', () async {
      final now = DateTime.now();

      await store.save(GlobalSkillEntity(
        uuid: 'global-del-rpc',
        name: '全局删除测试',
        createTime: now.subtract(const Duration(hours: 1)),
        updateTime: now.subtract(const Duration(hours: 1)),
      ));

      await simulateSyncGlobalSkills([
        GlobalSkillEntity(
          uuid: 'global-del-rpc',
          name: '全局删除测试',
          deleted: 1,
          deleteTime: now,
          createTime: now.subtract(const Duration(hours: 1)),
          updateTime: now,
        ),
      ]);

      final fetched = await store.find('global-del-rpc');
      expect(fetched, isNull);

      final deleted = await store.findIncludingDeleted('global-del-rpc');
      expect(deleted, isNotNull);
      expect(deleted!.deleted, equals(1));
    });

    test('同步更新全局技能 → 采用较新版本', () async {
      final now = DateTime.now();

      await store.save(GlobalSkillEntity(
        uuid: 'global-update-rpc',
        name: '旧版本',
        config: '{"v":1}',
        createTime: now.subtract(const Duration(hours: 2)),
        updateTime: now.subtract(const Duration(hours: 1)),
      ));

      await simulateSyncGlobalSkills([
        GlobalSkillEntity(
          uuid: 'global-update-rpc',
          name: '新版本',
          config: '{"v":2}',
          createTime: now.subtract(const Duration(hours: 2)),
          updateTime: now,
        ),
      ]);

      final fetched = await store.find('global-update-rpc');
      expect(fetched, isNotNull);
      expect(fetched!.name, equals('新版本'));
      expect(fetched.config, equals('{"v":2}'));
    });
  });
}
