import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/wenzagent.dart';

int _testCounter = 0;

/// 员工信息同步 - 双路径测试
///
/// 参考结构：
/// - cli-client: DeviceClient 初始化 + LAN 连接 + 消息收发
/// - employee_crud_sync_test: Store CRUD + 合并逻辑 + 序列化往返
/// - event_broadcast_test: AgentEvent 流 + LAN 广播 + 事件映射
///
/// 验证两条同步路径：
/// - 路径1：event(lan广播+event) → update store
///   DeviceA 修改员工 → EmployeeChangeEvent → LAN 广播(aiEmployeeChange)
///   → DeviceB 收到 → 合并更新本地 store
///
/// - 路径2：query → update store
///   DeviceB 主动调用 syncEmployeesFromDevices → RPC query
///   → 拉取远程员工列表 → 合并更新本地 store
void main() {
  late String testDbPath;
  late String deviceIdA;
  late String deviceIdB;
  late EmployeeStore storeA;
  late EmployeeStore storeB;
  late EmployeeManager managerA;
  late EmployeeManager managerB;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_employee_sync_dual_path_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceIdA = 'dev-A-${const Uuid().v4().substring(0, 8)}';
    deviceIdB = 'dev-B-${const Uuid().v4().substring(0, 8)}';

    // 初始化两个设备的数据库
    await DatabaseManager.getInstance(deviceIdA).initialize(
      storagePath: testDbPath,
    );
    await DatabaseManager.getInstance(deviceIdB).initialize(
      storagePath: testDbPath,
    );

    storeA = EmployeeStore(deviceId: deviceIdA);
    storeB = EmployeeStore(deviceId: deviceIdB);
    managerA = EmployeeManager.getInstance(deviceIdA);
    managerB = EmployeeManager.getInstance(deviceIdB);
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceIdA).close();
    await DatabaseManager.getInstance(deviceIdB).close();
    DatabaseManager.removeInstance(deviceIdA);
    DatabaseManager.removeInstance(deviceIdB);
    EmployeeManager.removeInstance(deviceIdA);
    EmployeeManager.removeInstance(deviceIdB);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════
  // 辅助方法
  // ═══════════════════════════════════════════════════

  AiEmployeeEntity createEmployee({
    String? uuid,
    String? name,
    String? deviceId,
    String? description,
    String? systemPrompt,
    String? provider,
    String? model,
    String status = 'active',
    int deleted = 0,
    DateTime? deletedTime,
    int isPinned = 0,
    int sortOrder = 0,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return AiEmployeeEntity(
      uuid: uuid ?? const Uuid().v4(),
      name: name ?? '测试员工',
      deviceId: deviceId,
      description: description,
      systemPrompt: systemPrompt,
      provider: provider,
      model: model,
      status: status,
      deleted: deleted,
      deletedTime: deletedTime,
      isPinned: isPinned,
      sortOrder: sortOrder,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  /// 模拟 DataSyncManager._mergeAndSaveEmployee 的合并逻辑
  /// 返回 (shouldSave, mergedEntity)
  (bool, AiEmployeeEntity?) simulateMerge(
    AiEmployeeEntity existing,
    AiEmployeeEntity remote,
  ) {
    final mergeResult = StoreMergeUtil.mergeDeleteState(
      localDeleteTime: existing.deletedTime,
      localDeleted: existing.deleted,
      remoteDeleteTime: remote.deletedTime,
      remoteDeleted: remote.deleted,
      localUpdateTime: existing.updateTime,
      remoteUpdateTime: remote.updateTime,
    );
    final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
      existing.updateTime,
      remote.updateTime,
    );
    final shouldUpdateDelete =
        mergeResult.mergedDeleteTime != existing.deletedTime ||
        mergeResult.mergedDeleted != existing.deleted;
    if (shouldUpdateData || shouldUpdateDelete) {
      final base = shouldUpdateData ? remote : existing;
      return (true, base.copyWith(
        deleted: mergeResult.mergedDeleted,
        deletedTime: mergeResult.mergedDeleteTime,
      ));
    }
    return (false, null);
  }

  /// 模拟 hostSyncEmployees RPC handler 的合并逻辑（与 host_rpc_methods.dart 一致）
  /// 返回 (changed, mergedEntity)
  (bool, AiEmployeeEntity?) simulateSyncEmployeesMerge(
    AiEmployeeEntity? existing,
    AiEmployeeEntity remote,
  ) {
    if (existing == null) {
      return (true, remote);
    }
    // 合并：deleteTime 独立比较，数据按 updateTime 合并
    final mergeResult = StoreMergeUtil.mergeDeleteState(
      localDeleteTime: existing.deletedTime,
      localDeleted: existing.deleted,
      remoteDeleteTime: remote.deletedTime,
      remoteDeleted: remote.deleted,
      localUpdateTime: existing.updateTime,
      remoteUpdateTime: remote.updateTime,
    );
    final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
      existing.updateTime, remote.updateTime,
    );
    final shouldUpdateDelete =
        mergeResult.mergedDeleteTime != existing.deletedTime ||
        mergeResult.mergedDeleted != existing.deleted;

    if (shouldUpdateData || shouldUpdateDelete) {
      final base = shouldUpdateData ? remote : existing;
      return (true, base.copyWith(
        deleted: mergeResult.mergedDeleted,
        deletedTime: mergeResult.mergedDeleteTime,
      ));
    }
    return (false, null);
  }

  /// 模拟 _doSyncEmployeesFromDevices 的拉取合并逻辑
  /// 本地不存在时：远程未删除的直接保存，已删除的不保存
  /// 返回 (changed, mergedEntity)
  (bool, AiEmployeeEntity?) simulateQuerySyncMerge(
    AiEmployeeEntity? existing,
    AiEmployeeEntity remote,
  ) {
    if (existing == null) {
      if (remote.deleted != 1) {
        return (true, remote);
      }
      return (false, null);
    }
    return simulateMerge(existing, remote);
  }

  /// 保存到 DeviceB（使用 storeB.save 避免 managerB.saveEmployee 干扰时间戳）
  Future<void> saveToDeviceB(AiEmployeeEntity entity) async {
    await storeB.save(entity);
  }

  // ═══════════════════════════════════════════════════
  // 路径1：event(lan广播+event) → update store
  // ═══════════════════════════════════════════════════

  group('路径1：event(lan广播+event) → update store', () {
    // --------------------------------------------------
    // 1.1 EmployeeChangeEvent 发射验证
    // --------------------------------------------------
    group('1.1 EmployeeChangeEvent 发射', () {
      test('createEmployee 后发射 EmployeeChangeEvent(created)', () async {
        final events = <EmployeeChangeEvent>[];
        final sub = managerA.onEmployeeEvent.listen(events.add);

        final emp = createEmployee(name: '张三');
        await managerA.createEmployee(emp);

        await Future.delayed(const Duration(milliseconds: 50));

        expect(events.length, equals(1));
        expect(events[0].type, equals(EmployeeChangeType.created));
        expect(events[0].employeeId, equals(emp.uuid));
        expect(events[0].employee, isNotNull);
        expect(events[0].employee!.name, equals('张三'));

        await sub.cancel();
      });

      test('updateEmployee 后发射 EmployeeChangeEvent(updated)', () async {
        final emp = createEmployee(name: '张三');
        await managerA.createEmployee(emp);

        final events = <EmployeeChangeEvent>[];
        final sub = managerA.onEmployeeEvent.listen(events.add);

        final updated = emp.copyWith(name: '李四', description: '已更新');
        await managerA.updateEmployee(updated);

        await Future.delayed(const Duration(milliseconds: 50));

        expect(events.length, equals(1));
        expect(events[0].type, equals(EmployeeChangeType.updated));
        expect(events[0].employeeId, equals(emp.uuid));
        expect(events[0].employee!.name, equals('李四'));

        await sub.cancel();
      });

      test('deleteEmployee 后发射 EmployeeChangeEvent(deleted)', () async {
        final emp = createEmployee(name: '张三');
        await managerA.createEmployee(emp);

        final events = <EmployeeChangeEvent>[];
        final sub = managerA.onEmployeeEvent.listen(events.add);

        await managerA.deleteEmployee(emp.uuid);

        await Future.delayed(const Duration(milliseconds: 50));

        expect(events.length, equals(1));
        expect(events[0].type, equals(EmployeeChangeType.deleted));
        expect(events[0].employeeId, equals(emp.uuid));

        await sub.cancel();
      });

      test('saveEmployee (同步场景) 对已存在的员工发射 updated 事件', () async {
        final emp = createEmployee(name: '张三');
        await managerA.createEmployee(emp);

        final events = <EmployeeChangeEvent>[];
        final sub = managerA.onEmployeeEvent.listen(events.add);

        final syncedEmp = emp.copyWith(
          name: '同步更新',
          description: '从远程同步',
          updateTime: DateTime.now().add(const Duration(seconds: 1)),
        );
        await managerA.saveEmployee(syncedEmp);

        await Future.delayed(const Duration(milliseconds: 50));

        expect(events.length, equals(1));
        expect(events[0].type, equals(EmployeeChangeType.updated));
        expect(events[0].employee!.name, equals('同步更新'));

        await sub.cancel();
      });

      test('saveEmployee (同步场景) 对不存在的员工发射 created 事件', () async {
        final events = <EmployeeChangeEvent>[];
        final sub = managerA.onEmployeeEvent.listen(events.add);

        final newEmp = createEmployee(name: '远程同步来的员工');
        await managerA.saveEmployee(newEmp);

        await Future.delayed(const Duration(milliseconds: 50));

        expect(events.length, equals(1));
        expect(events[0].type, equals(EmployeeChangeType.created));

        await sub.cancel();
      });
    });

    // --------------------------------------------------
    // 1.2 序列化往返（模拟 LAN 传输）
    // --------------------------------------------------
    group('1.2 序列化往返（模拟 LAN 传输）', () {
      test('AiEmployeeEntity toMap → fromMap 往返一致性', () {
        final emp = createEmployee(
          name: '张三',
          description: '测试描述',
          systemPrompt: '你是一个助手',
          provider: 'openai',
          model: 'gpt-4',
          status: 'active',
          isPinned: 1,
          sortOrder: 5,
        );

        final map = emp.toMap();
        final restored = AiEmployeeEntity.fromMap(map);

        expect(restored.uuid, equals(emp.uuid));
        expect(restored.name, equals(emp.name));
        expect(restored.description, equals(emp.description));
        expect(restored.systemPrompt, equals(emp.systemPrompt));
        expect(restored.provider, equals(emp.provider));
        expect(restored.model, equals(emp.model));
        expect(restored.status, equals(emp.status));
        expect(restored.isPinned, equals(emp.isPinned));
        expect(restored.sortOrder, equals(emp.sortOrder));
        expect(restored.deleted, equals(emp.deleted));
        expect(restored.deletedTime, equals(emp.deletedTime));
        expect(
          restored.createTime.millisecondsSinceEpoch,
          equals(emp.createTime.millisecondsSinceEpoch),
        );
        expect(
          restored.updateTime.millisecondsSinceEpoch,
          equals(emp.updateTime.millisecondsSinceEpoch),
        );
      });

      test('已删除员工的序列化往返保留 deleted/deletedTime', () {
        final now = DateTime.now();
        final emp = createEmployee(
          name: '已删除员工',
          deleted: 1,
          deletedTime: now,
        );

        final map = emp.toMap();
        final restored = AiEmployeeEntity.fromMap(map);

        expect(restored.deleted, equals(1));
        expect(restored.deletedTime, isNotNull);
        expect(
          restored.deletedTime!.millisecondsSinceEpoch,
          equals(now.millisecondsSinceEpoch),
        );
      });

      test('模拟 LAN 消息包装和解析', () {
        final emp = createEmployee(name: '张三');
        final event = EmployeeChangeEvent(
          type: EmployeeChangeType.updated,
          employeeId: emp.uuid,
          employee: emp,
        );

        final lanMsg = LanMessage(
          type: LanMessageType.aiEmployeeChange,
          fromId: deviceIdA,
          content: '{"employee": ${jsonEncode(emp.toMap())}, '
              '"changeType": "${event.type.name}"}',
        );

        final content = jsonDecode(lanMsg.content!) as Map<String, dynamic>;
        final employeeData = content['employee'] as Map<String, dynamic>;
        final restored = AiEmployeeEntity.fromMap(employeeData);

        expect(restored.uuid, equals(emp.uuid));
        expect(restored.name, equals(emp.name));
      });
    });

    // --------------------------------------------------
    // 1.3 Event 路径：DeviceA 修改 → 广播 → DeviceB 合并更新
    // --------------------------------------------------
    group('1.3 Event 路径：DeviceA 修改 → 广播 → DeviceB 合并', () {
      test('DeviceA 创建员工 → 广播 → DeviceB 新增保存', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(name: '新员工', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime);
        await storeA.save(emp);

        // 模拟广播：从 storeA 读取实际数据确保毫秒精度一致
        final remoteEmp = await storeA.findIncludingDeleted(emp.uuid);
        final existing = await storeB.findIncludingDeleted(emp.uuid);
        final (changed, merged) = simulateSyncEmployeesMerge(existing, remoteEmp!);

        expect(changed, isTrue);
        expect(merged, isNotNull);

        await saveToDeviceB(merged!);

        final stored = await storeB.find(null, emp.uuid);
        expect(stored, isNotNull);
        expect(stored!.name, equals('新员工'));
        expect(stored.uuid, equals(emp.uuid));
      });

      test('DeviceA 更新员工 → 广播 → DeviceB 合并更新', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(
          name: '原始名称', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
        );
        await storeA.save(emp);
        await storeB.save(emp);

        final updatedTime = DateTime(2099, 1, 1, 12, 5, 0);
        final updated = emp.copyWith(
          name: '更新后名称', description: '新增描述', updateTime: updatedTime,
        );
        await storeA.save(updated);

        // 模拟广播：从 store 读取确保毫秒精度一致
        final remoteEmp = await storeA.findIncludingDeleted(emp.uuid);
        final existing = await storeB.findIncludingDeleted(emp.uuid);
        final (changed, merged) = simulateSyncEmployeesMerge(existing, remoteEmp!);

        expect(changed, isTrue);
        expect(merged, isNotNull);
        expect(merged!.name, equals('更新后名称'));
        expect(merged.description, equals('新增描述'));

        await saveToDeviceB(merged);

        final stored = await storeB.find(null, emp.uuid);
        expect(stored, isNotNull);
        expect(stored!.name, equals('更新后名称'));
        expect(stored.description, equals('新增描述'));
      });

      test('DeviceA 删除员工 → 广播 → DeviceB 软删除同步', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(
          name: '待删除员工', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
        );
        await storeA.save(emp);
        await storeB.save(emp);

        final deleteTime = DateTime(2099, 1, 1, 12, 5, 0);
        await storeA.save(emp.copyWith(
          deleted: 1, deletedTime: deleteTime, updateTime: deleteTime,
        ));

        final deletedEmp = await storeA.findIncludingDeleted(emp.uuid);
        expect(deletedEmp, isNotNull);
        expect(deletedEmp!.deleted, equals(1));

        final existing = await storeB.findIncludingDeleted(emp.uuid);
        final (changed, merged) = simulateSyncEmployeesMerge(existing, deletedEmp);

        expect(changed, isTrue);
        expect(merged, isNotNull);
        expect(merged!.deleted, equals(1));
        expect(merged.deletedTime, isNotNull);

        await saveToDeviceB(merged);

        final stored = await storeB.find(null, emp.uuid);
        expect(stored, isNull);

        final storedIncDel = await storeB.findIncludingDeleted(emp.uuid);
        expect(storedIncDel, isNotNull);
        expect(storedIncDel!.deleted, equals(1));
      });

      test('DeviceA 更新但 DeviceB 有更新 → updateTime 更大者胜出', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(
          name: '原始', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
        );
        await storeA.save(emp);
        await storeB.save(emp);

        final bUpdateTime = DateTime(2099, 1, 1, 12, 8, 0);
        await storeB.save(emp.copyWith(name: 'DeviceB修改', updateTime: bUpdateTime));

        final aUpdateTime = DateTime(2099, 1, 1, 12, 5, 0);
        await storeA.save(emp.copyWith(name: 'DeviceA修改', updateTime: aUpdateTime));

        final remoteEmp = await storeA.findIncludingDeleted(emp.uuid);
        final existing = await storeB.findIncludingDeleted(emp.uuid);
        final (changed, merged) = simulateSyncEmployeesMerge(existing, remoteEmp!);

        expect(changed, isFalse);
      });

      test('DeviceA 更新但 DeviceB 有更新 → DeviceA 更新者胜出', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(
          name: '原始', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
        );
        await storeA.save(emp);
        await storeB.save(emp);

        final bUpdateTime = DateTime(2099, 1, 1, 12, 5, 0);
        await storeB.save(emp.copyWith(name: 'DeviceB修改', updateTime: bUpdateTime));

        final aUpdateTime = DateTime(2099, 1, 1, 12, 8, 0);
        await storeA.save(emp.copyWith(name: 'DeviceA修改', updateTime: aUpdateTime));

        final remoteEmp = await storeA.findIncludingDeleted(emp.uuid);
        final existing = await storeB.findIncludingDeleted(emp.uuid);
        final (changed, merged) = simulateSyncEmployeesMerge(existing, remoteEmp!);

        expect(changed, isTrue);
        expect(merged!.name, equals('DeviceA修改'));
      });

      test('deleteTime 合并：双方都删除 → 取 deleteTime 更大者', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(
          name: '双删员工', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
        );
        await storeA.save(emp);
        await storeB.save(emp);

        final aDeleteTime = DateTime(2099, 1, 1, 12, 10, 0);
        await storeA.save(emp.copyWith(
          deleted: 1, deletedTime: aDeleteTime, updateTime: aDeleteTime,
        ));

        final bDeleteTime = DateTime(2099, 1, 1, 12, 15, 0);
        await storeB.save(emp.copyWith(
          deleted: 1, deletedTime: bDeleteTime, updateTime: bDeleteTime,
        ));

        final remoteEmp = await storeA.findIncludingDeleted(emp.uuid);
        final existing = await storeB.findIncludingDeleted(emp.uuid);
        final (changed, merged) = simulateSyncEmployeesMerge(existing, remoteEmp!);

        expect(changed, isFalse);
      });

      test('deleteTime 合并：DeviceA 删除 DeviceB 未删 → 删除传播', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(
          name: '单删员工', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
        );
        await storeA.save(emp);
        await storeB.save(emp);

        final aDeleteTime = DateTime(2099, 1, 1, 12, 10, 0);
        await storeA.save(emp.copyWith(
          deleted: 1, deletedTime: aDeleteTime, updateTime: aDeleteTime,
        ));

        final remoteEmp = await storeA.findIncludingDeleted(emp.uuid);
        final existing = await storeB.findIncludingDeleted(emp.uuid);
        final (changed, merged) = simulateSyncEmployeesMerge(existing, remoteEmp!);

        expect(changed, isTrue);
        expect(merged!.deleted, equals(1));
        expect(merged.deletedTime, isNotNull);
      });
    });

    // --------------------------------------------------
    // 1.4 Event 路径：多次广播合并（防重复/幂等）
    // --------------------------------------------------
    group('1.4 Event 路径：多次广播合并（幂等性）', () {
      test('同一员工重复广播 → 合并幂等，数据不变', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(
          name: '重复广播员工', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
        );
        await storeA.save(emp);

        // 第一次广播到 DeviceB
        final remoteEmp = await storeA.findIncludingDeleted(emp.uuid);
        final existing1 = await storeB.findIncludingDeleted(emp.uuid);
        final (changed1, merged1) = simulateSyncEmployeesMerge(existing1, remoteEmp!);
        expect(changed1, isTrue);
        await saveToDeviceB(merged1!);

        // 第二次广播同一数据
        final existing2 = await storeB.findIncludingDeleted(emp.uuid);
        final (changed2, merged2) = simulateSyncEmployeesMerge(existing2, remoteEmp);
        expect(changed2, isFalse);
      });

      test('快速连续更新 → 最终状态一致', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(
          name: 'V1', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
        );
        await storeA.save(emp);

        for (var i = 2; i <= 4; i++) {
          final t = DateTime(2099, 1, 1, 12, 0, i * 2);
          await storeA.save(emp.copyWith(name: 'V$i', updateTime: t));

          final remoteEmp = await storeA.findIncludingDeleted(emp.uuid);
          final existing = await storeB.findIncludingDeleted(emp.uuid);
          final (changed, merged) = simulateSyncEmployeesMerge(existing, remoteEmp!);
          if (changed && merged != null) {
            await saveToDeviceB(merged);
          }
        }

        final stored = await storeB.find(null, emp.uuid);
        expect(stored, isNotNull);
        expect(stored!.name, equals('V4'));
      });
    });
  });

  // ═══════════════════════════════════════════════════
  // 路径2：query → update store
  // ═══════════════════════════════════════════════════

  group('路径2：query → update store', () {
    // --------------------------------------------------
    // 2.1 Query 拉取：新增员工同步
    // --------------------------------------------------
    group('2.1 Query 拉取：新增员工同步', () {
      test('DeviceB query → 发现 DeviceA 新员工 → 保存到本地', () async {
        final emp = createEmployee(name: 'DeviceA员工', deviceId: deviceIdA);
        await storeA.save(emp);

        final remoteEmployees = await storeA.findAll(null);
        expect(remoteEmployees.length, equals(1));

        for (final remote in remoteEmployees) {
          final existing = await storeB.findIncludingDeleted(remote.uuid);
          final (changed, merged) = simulateQuerySyncMerge(existing, remote);
          if (changed && merged != null) {
            await saveToDeviceB(merged);
          }
        }

        final stored = await storeB.find(null, emp.uuid);
        expect(stored, isNotNull);
        expect(stored!.name, equals('DeviceA员工'));
      });

      test('DeviceB query → DeviceA 有多个员工 → 全部同步', () async {
        final emps = [
          createEmployee(name: '员工1', deviceId: deviceIdA),
          createEmployee(name: '员工2', deviceId: deviceIdA),
          createEmployee(name: '员工3', deviceId: deviceIdA),
        ];
        for (final e in emps) {
          await storeA.save(e);
        }

        final remoteEmployees = await storeA.findAll(null);
        expect(remoteEmployees.length, equals(3));

        for (final remote in remoteEmployees) {
          final existing = await storeB.findIncludingDeleted(remote.uuid);
          final (changed, merged) = simulateQuerySyncMerge(existing, remote);
          if (changed && merged != null) {
            await saveToDeviceB(merged);
          }
        }

        final localEmployees = await storeB.findAll(null);
        expect(localEmployees.length, equals(3));
      });

      test('DeviceB query → DeviceA 有已删除员工 → 不同步已删除', () async {
        final deletedEmp = createEmployee(
          name: '已删除', deviceId: deviceIdA, deleted: 1,
          deletedTime: DateTime.now(),
        );
        await storeA.save(deletedEmp);

        final remoteEmployees = await storeA.findAll(null, includeDeleted: true);
        expect(remoteEmployees.length, equals(1));

        for (final remote in remoteEmployees) {
          final existing = await storeB.findIncludingDeleted(remote.uuid);
          final (changed, merged) = simulateQuerySyncMerge(existing, remote);
          expect(changed, isFalse);
        }

        final stored = await storeB.find(null, deletedEmp.uuid);
        expect(stored, isNull);
      });

      test('DeviceB query → DeviceA 有已删除员工但本地也有 → 合并删除状态', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(
          name: '共同员工', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
        );
        await storeA.save(emp);
        await storeB.save(emp);

        final deleteTime = DateTime(2099, 1, 1, 12, 10, 0);
        await storeA.save(emp.copyWith(
          deleted: 1, deletedTime: deleteTime, updateTime: deleteTime,
        ));

        final remoteEmployees = await storeA.findAll(null, includeDeleted: true);
        for (final remote in remoteEmployees) {
          final existing = await storeB.findIncludingDeleted(remote.uuid);
          final (changed, merged) = simulateQuerySyncMerge(existing, remote);
          if (changed && merged != null) {
            await saveToDeviceB(merged);
          }
        }

        final stored = await storeB.find(null, emp.uuid);
        expect(stored, isNull);
      });
    });

    // --------------------------------------------------
    // 2.2 Query 拉取：更新合并
    // --------------------------------------------------
    group('2.2 Query 拉取：更新合并', () {
      test('DeviceA 更新员工 → DeviceB query → 合并更新', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(
          name: '原始', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
        );
        await storeA.save(emp);
        await storeB.save(emp);

        final updatedTime = DateTime(2099, 1, 1, 12, 10, 0);
        await storeA.save(emp.copyWith(
          name: 'DeviceA更新', description: '新描述', updateTime: updatedTime,
        ));

        final remoteEmployees = await storeA.findAll(null);
        for (final remote in remoteEmployees) {
          final existing = await storeB.findIncludingDeleted(remote.uuid);
          final (changed, merged) = simulateQuerySyncMerge(existing, remote);
          if (changed && merged != null) {
            await saveToDeviceB(merged);
          }
        }

        final stored = await storeB.find(null, emp.uuid);
        expect(stored!.name, equals('DeviceA更新'));
        expect(stored.description, equals('新描述'));
      });

      test('DeviceB 本地更新 → DeviceA 远程更新 → query 合并取最新', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(
          name: '原始', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
        );
        await storeA.save(emp);
        await storeB.save(emp);

        final bTime = DateTime(2099, 1, 1, 12, 5, 0);
        await storeB.save(emp.copyWith(name: 'DeviceB修改', updateTime: bTime));

        final aTime = DateTime(2099, 1, 1, 12, 8, 0);
        await storeA.save(emp.copyWith(name: 'DeviceA修改', updateTime: aTime));

        final remoteEmployees = await storeA.findAll(null);
        for (final remote in remoteEmployees) {
          final existing = await storeB.findIncludingDeleted(remote.uuid);
          final (changed, merged) = simulateQuerySyncMerge(existing, remote);
          if (changed && merged != null) {
            await saveToDeviceB(merged);
          }
        }

        final stored = await storeB.find(null, emp.uuid);
        expect(stored!.name, equals('DeviceA修改'));
      });

      test('DeviceB 本地更新 → DeviceA 远程更新 → query 合并保留本地', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(
          name: '原始', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
        );
        await storeA.save(emp);
        await storeB.save(emp);

        final aTime = DateTime(2099, 1, 1, 12, 5, 0);
        await storeA.save(emp.copyWith(name: 'DeviceA修改', updateTime: aTime));

        final bTime = DateTime(2099, 1, 1, 12, 8, 0);
        await storeB.save(emp.copyWith(name: 'DeviceB修改', updateTime: bTime));

        final remoteEmployees = await storeA.findAll(null);
        for (final remote in remoteEmployees) {
          final existing = await storeB.findIncludingDeleted(remote.uuid);
          final (changed, merged) = simulateQuerySyncMerge(existing, remote);
          if (changed && merged != null) {
            await saveToDeviceB(merged);
          }
        }

        final stored = await storeB.find(null, emp.uuid);
        expect(stored!.name, equals('DeviceB修改'));
      });
    });

    // --------------------------------------------------
    // 2.3 Query 拉取：跨设备员工列表
    // --------------------------------------------------
    group('2.3 Query 拉取：跨设备员工列表', () {
      test('DeviceA 和 DeviceB 各有不同员工 → query 后两端数据一致', () async {
        final empA = createEmployee(name: 'DeviceA员工', deviceId: deviceIdA);
        await storeA.save(empA);

        final empB = createEmployee(name: 'DeviceB员工', deviceId: deviceIdB);
        await storeB.save(empB);

        final remoteFromA = await storeA.findAll(null);
        for (final remote in remoteFromA) {
          final existing = await storeB.findIncludingDeleted(remote.uuid);
          final (changed, merged) = simulateQuerySyncMerge(existing, remote);
          if (changed && merged != null) {
            await saveToDeviceB(merged);
          }
        }

        final allB = await storeB.findAll(null);
        expect(allB.length, equals(2));
        expect(allB.any((e) => e.uuid == empA.uuid), isTrue);
        expect(allB.any((e) => e.uuid == empB.uuid), isTrue);
      });

      test('query 拉取后 EmployeeManager.getEmployees 返回正确列表', () async {
        final emp1 = createEmployee(name: '员工1', deviceId: deviceIdA);
        final emp2 = createEmployee(name: '员工2', deviceId: deviceIdA);
        await storeA.save(emp1);
        await storeA.save(emp2);

        final remoteEmployees = await storeA.findAll(null);
        for (final remote in remoteEmployees) {
          final existing = await storeB.findIncludingDeleted(remote.uuid);
          final (changed, merged) = simulateQuerySyncMerge(existing, remote);
          if (changed && merged != null) {
            await saveToDeviceB(merged);
          }
        }

        final employees = await managerB.getEmployees();
        expect(employees.length, equals(2));
      });

      test('query 拉取后 EmployeeManager.getEmployeeStats 统计正确', () async {
        final emp1 = createEmployee(name: '活跃员工', deviceId: deviceIdA, status: 'active', isPinned: 1);
        final emp2 = createEmployee(name: '非活跃员工', deviceId: deviceIdA, status: 'inactive');
        await storeA.save(emp1);
        await storeA.save(emp2);

        final remoteEmployees = await storeA.findAll(null);
        for (final remote in remoteEmployees) {
          final existing = await storeB.findIncludingDeleted(remote.uuid);
          final (changed, merged) = simulateQuerySyncMerge(existing, remote);
          if (changed && merged != null) {
            await saveToDeviceB(merged);
          }
        }

        final stats = await managerB.getEmployeeStats();
        expect(stats, isNotNull);
      });
    });

    // --------------------------------------------------
    // 2.4 Query 拉取：deleteTime 合并
    // --------------------------------------------------
    group('2.4 Query 拉取：deleteTime 合并', () {
      test('远程删除本地未删 → 删除同步', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(name: '待同步删除', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime);
        await storeA.save(emp);
        await storeB.save(emp);

        final deleteTime = DateTime(2099, 1, 1, 12, 10, 0);
        await storeA.save(emp.copyWith(
          deleted: 1, deletedTime: deleteTime, updateTime: deleteTime,
        ));

        final remoteEmployees = await storeA.findAll(null, includeDeleted: true);
        for (final remote in remoteEmployees) {
          final existing = await storeB.findIncludingDeleted(remote.uuid);
          final (changed, merged) = simulateQuerySyncMerge(existing, remote);
          if (changed && merged != null) {
            await saveToDeviceB(merged);
          }
        }

        final stored = await storeB.find(null, emp.uuid);
        expect(stored, isNull);
      });

      test('本地删除远程未删 → 本地保持删除（query 不复活）', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(name: '已本地删除', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime);
        await storeA.save(emp);
        await storeB.save(emp);

        final deleteTime = DateTime(2099, 1, 1, 12, 10, 0);
        await storeB.save(emp.copyWith(
          deleted: 1, deletedTime: deleteTime, updateTime: deleteTime,
        ));

        final remoteEmployees = await storeA.findAll(null);
        for (final remote in remoteEmployees) {
          final existing = await storeB.findIncludingDeleted(remote.uuid);
          final (changed, merged) = simulateQuerySyncMerge(existing, remote);
          if (changed && merged != null) {
            await saveToDeviceB(merged);
          }
        }

        final stored = await storeB.find(null, emp.uuid);
        expect(stored, isNull);
      });

      test('双方都删除 → 取 deleteTime 更大者', () async {
        final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
        final emp = createEmployee(name: '双删', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime);
        await storeA.save(emp);
        await storeB.save(emp);

        final aDeleteTime = DateTime(2099, 1, 1, 12, 10, 0);
        await storeA.save(emp.copyWith(
          deleted: 1, deletedTime: aDeleteTime, updateTime: aDeleteTime,
        ));

        final bDeleteTime = DateTime(2099, 1, 1, 12, 15, 0);
        await storeB.save(emp.copyWith(
          deleted: 1, deletedTime: bDeleteTime, updateTime: bDeleteTime,
        ));

        final remoteEmployees = await storeA.findAll(null, includeDeleted: true);
        for (final remote in remoteEmployees) {
          final existing = await storeB.findIncludingDeleted(remote.uuid);
          final (changed, merged) = simulateQuerySyncMerge(existing, remote);
          expect(changed, isFalse);
        }
      });
    });
  });

  // ═══════════════════════════════════════════════════
  // 综合场景：两条路径交替执行
  // ═══════════════════════════════════════════════════

  group('综合场景：两条路径交替执行', () {
    test('先 event 同步 → 再 query 同步 → 数据最终一致', () async {
      final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
      final emp = createEmployee(
        name: '初始版本', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
      );
      await storeA.save(emp);

      // Event 路径：DeviceB 收到广播
      var existing = await storeB.findIncludingDeleted(emp.uuid);
      var (changed, merged) = simulateSyncEmployeesMerge(existing, emp);
      expect(changed, isTrue);
      await saveToDeviceB(merged!);

      var stored = await storeB.find(null, emp.uuid);
      expect(stored, isNotNull);
      expect(stored!.name, equals('初始版本'));

      // 阶段2：DeviceA 更新员工
      final updateTime = DateTime(2099, 1, 1, 12, 5, 0);
      final updated = emp.copyWith(name: 'event更新版本', updateTime: updateTime);
      await storeA.save(updated);

      existing = await storeB.findIncludingDeleted(emp.uuid);
      (changed, merged) = simulateSyncEmployeesMerge(existing, updated);
      expect(changed, isTrue);
      await saveToDeviceB(merged!);

      stored = await storeB.find(null, emp.uuid);
      expect(stored!.name, equals('event更新版本'));

      // 阶段3：DeviceB 主动 query 拉取
      final remoteEmployees = await storeA.findAll(null);
      for (final remote in remoteEmployees) {
        existing = await storeB.findIncludingDeleted(remote.uuid);
        (changed, merged) = simulateQuerySyncMerge(existing, remote);
        if (changed && merged != null) {
          await saveToDeviceB(merged);
        }
      }

      // 验证最终一致
      final storedA = await storeA.find(null, emp.uuid);
      final storedB = await storeB.find(null, emp.uuid);
      expect(storedA!.name, equals(storedB!.name));
    });

    test('多设备并发更新 → 最终通过 query 统一', () async {
      final baseTime = DateTime(2099, 1, 1, 12, 0, 0);
      final v1 = createEmployee(
        name: 'V1', deviceId: deviceIdA, createTime: baseTime, updateTime: baseTime,
      );
      await storeA.save(v1);
      await storeB.save(v1);

      final v2Time = DateTime(2099, 1, 1, 12, 5, 0);
      await storeA.save(v1.copyWith(name: 'V2', updateTime: v2Time));

      final v3Time = DateTime(2099, 1, 1, 12, 8, 0);
      await storeB.save(v1.copyWith(name: 'V3', updateTime: v3Time));

      // 模拟 DeviceA 广播 V2 到 DeviceB
      var existing = await storeB.findIncludingDeleted(v1.uuid);
      var (changed, merged) = simulateSyncEmployeesMerge(existing, (await storeA.findIncludingDeleted(v1.uuid))!);
      expect(changed, isFalse);

      // 模拟 DeviceB query 拉取 DeviceA 数据
      final remoteEmployees = await storeA.findAll(null);
      for (final remote in remoteEmployees) {
        existing = await storeB.findIncludingDeleted(remote.uuid);
        (changed, merged) = simulateSyncEmployeesMerge(existing, remote);
        expect(changed, isFalse);
      }

      // 验证 DeviceB 保持 V3
      final stored = await storeB.find(null, v1.uuid);
      expect(stored!.name, equals('V3'));
    });

    test('创建 → 更新 → 删除 → 复活 全生命周期同步', () async {
      final t0 = DateTime(2099, 1, 1, 12, 0, 0);
      final emp = createEmployee(
        name: '生命周期员工', deviceId: deviceIdA, createTime: t0, updateTime: t0,
      );
      await storeA.save(emp);

      // 1. 创建广播
      await saveToDeviceB(emp);

      var stored = await storeB.find(null, emp.uuid);
      expect(stored, isNotNull);
      expect(stored!.name, equals('生命周期员工'));

      // 2. 更新
      final t1 = DateTime(2099, 1, 1, 12, 5, 0);
      final updated = emp.copyWith(name: '已更新', updateTime: t1);
      await storeA.save(updated);

      var existing = await storeB.findIncludingDeleted(emp.uuid);
      var (changed, merged) = simulateSyncEmployeesMerge(existing, updated);
      expect(changed, isTrue);
      await saveToDeviceB(merged!);

      stored = await storeB.find(null, emp.uuid);
      expect(stored!.name, equals('已更新'));

      // 3. 删除
      final t2 = DateTime(2099, 1, 1, 12, 10, 0);
      await storeA.save(emp.copyWith(
        deleted: 1, deletedTime: t2, updateTime: t2,
      ));

      existing = await storeB.findIncludingDeleted(emp.uuid);
      (changed, merged) = simulateSyncEmployeesMerge(existing, (await storeA.findIncludingDeleted(emp.uuid))!);
      expect(changed, isTrue);
      await saveToDeviceB(merged!);

      stored = await storeB.find(null, emp.uuid);
      expect(stored, isNull);

      // 4. 复活
      final t3 = DateTime(2099, 1, 1, 12, 15, 0);
      var revived = emp.copyWith(
        name: '复活员工', deleted: 0, deletedTime: null, updateTime: t3,
      );
      await storeA.save(revived);

      existing = await storeB.findIncludingDeleted(emp.uuid);
      (changed, merged) = simulateSyncEmployeesMerge(existing, revived);
      expect(changed, isTrue);
      await saveToDeviceB(merged!);

      stored = await storeB.find(null, emp.uuid);
      expect(stored, isNotNull);
      expect(stored!.name, equals('复活员工'));
      expect(stored.deleted, equals(0));
    });
  });
}
