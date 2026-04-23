import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/session_summary_entity.dart';
import 'package:wenzagent/src/persistence/stores/session_summary_store.dart';

int _testCounter = 0;

/// 标记已读后 syncSessionSummariesFromDevices 数量没变 —— 回归测试 v2
///
/// 问题场景：
/// 1. Device A 有 3 条未读消息（employeeId=emp-1, deviceId=deviceA）
/// 2. Device A 的摘要同步到 Device B（Device B 中存储为 emp-1+deviceA）
/// 3. Device A 标记已读 → unread_count = 0
/// 4. Device B 还没同步到已读状态，其摘要中 unread_count = 3
/// 5. Device A 调用 syncSessionSummariesFromDevices（从 Device B 拉取摘要）
/// 6. upsertFromRemote 使用 MAX(local, remote) 策略 → MAX(0, 3) = 3
/// 7. Device A 的 unread_count 从 0 变回 3 ❌
///
/// 根本原因：
/// upsertFromRemote 的 MAX 策略无法区分"未读消息"和"已读后同步过来的旧数据"。
/// 已读状态应该通过专门的已读广播（agentSessionSummaryChanged）来同步，
/// 而非通过全量摘要同步覆盖。
///
/// v2 与 v1 测试的区别：
/// v1 测试的 syncBToA 方法使用 sourceDeviceId = deviceB，
/// 但摘要的 deviceId 是 deviceA，导致 getSummary 返回 null，同步不生效。
/// v2 修复了 syncBToA，正确使用摘要的原始 deviceId。
void main() {
  late String testDbPathA;
  late String testDbPathB;
  late String deviceA;
  late String deviceB;
  late SessionSummaryStore storeA;
  late SessionSummaryStore storeB;

  setUp(() async {
    _testCounter++;
    final base =
        '${Directory.systemTemp.path}/wenzagent_mark_read_sync_v2_test_$_testCounter';

    testDbPathA = '$base/device_a';
    testDbPathB = '$base/device_b';
    await Directory(testDbPathA).create(recursive: true);
    await Directory(testDbPathB).create(recursive: true);

    deviceA = 'dev-a-${const Uuid().v4().substring(0, 8)}';
    deviceB = 'dev-b-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceA).initialize(
      storagePath: testDbPathA,
    );
    await DatabaseManager.getInstance(deviceB).initialize(
      storagePath: testDbPathB,
    );

    storeA = SessionSummaryStore(deviceId: deviceA);
    storeB = SessionSummaryStore(deviceId: deviceB);

    storeA.ensureTable();
    storeB.ensureTable();
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceA).close();
    await DatabaseManager.getInstance(deviceB).close();
    DatabaseManager.removeInstance(deviceA);
    DatabaseManager.removeInstance(deviceB);
    try {
      await Directory(testDbPathA).delete(recursive: true);
      await Directory(testDbPathB).delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════
  // 辅助方法
  // ═══════════════════════════════════════════════════

  /// 模拟 syncSessionSummariesFromDevices：
  /// 将 storeB 中所有摘要同步到 storeA（通过 getAllSummaries + upsertFromRemote）
  ///
  /// 这与 DataSyncManager._doSyncSessionSummariesFromDevices 的真实行为一致：
  /// 从远程设备拉取所有摘要，逐条 upsertFromRemote。
  void syncAllBToA() {
    final summaries = storeB.getAllSummaries();
    for (final summary in summaries) {
      storeA.upsertFromRemote(summary);
    }
  }

  /// 模拟 syncSessionSummariesFromDevices：
  /// 将 storeA 中所有摘要同步到 storeB
  void syncAllAToB() {
    final summaries = storeA.getAllSummaries();
    for (final summary in summaries) {
      storeB.upsertFromRemote(summary);
    }
  }

  // ═══════════════════════════════════════════════════
  // 核心回归测试：标记已读后同步不应恢复未读数
  // ═══════════════════════════════════════════════════

  group('标记已读后同步数量不变（回归测试 v2）', () {
    test('场景1：本地标记已读后，从远程同步不应恢复未读数', () {
      // ---- 步骤1: Device A 产生 3 条未读 ----
      for (int i = 1; i <= 3; i++) {
        storeA.onMessageAdded(
          employeeId: 'emp-1',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-$i',
          createTime: 1000 + i * 100,
          seq: i,
          content: '消息$i',
        );
      }
      expect(storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(3));

      // ---- 步骤2: Device A 的摘要同步到 Device B（模拟初始全量同步）----
      syncAllAToB();
      // Device B 中存储了 (emp-1, deviceA) 的摘要，unread_count = 3
      expect(storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(3));

      // ---- 步骤3: Device A 标记已读 ----
      storeA.markAsRead('emp-1', deviceId: deviceA);
      expect(storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(0));

      // ---- 步骤4: Device B 还没收到已读广播，其摘要中 unread_count 仍为 3 ----
      expect(storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(3));

      // ---- 步骤5: Device A 调用 syncSessionSummariesFromDevices ----
      // 从 Device B 拉取所有摘要 → upsertFromRemote → MAX(0, 3) = 3 ❌
      syncAllBToA();

      // ---- 验证：Device A 的未读数不应该被恢复 ----
      // 当前行为（BUG）：MAX(0, 3) = 3，未读数恢复
      // 期望行为：已读状态不应被全量同步覆盖，应保持 0
      final unreadAfterSync =
          storeA.getUnreadCount('emp-1', deviceId: deviceA);
      expect(
        unreadAfterSync,
        equals(0),
        reason: '标记已读后，从远程同步不应恢复未读数。'
            '当前 upsertFromRemote 使用 MAX 策略导致已读状态被覆盖。'
            '实际值: $unreadAfterSync',
      );
    });

    test('场景2：本地标记已读后，远程有更新的消息但未读数更多，同步后不应恢复', () {
      // ---- 步骤1: Device A 产生 2 条未读 ----
      storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-a-1',
        createTime: 1000,
        seq: 1,
        content: 'A的消息1',
      );
      storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-a-2',
        createTime: 2000,
        seq: 2,
        content: 'A的消息2',
      );

      // ---- 步骤2: 同步到 Device B ----
      syncAllAToB();
      expect(storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(2));

      // ---- 步骤3: Device A 标记已读 ----
      storeA.markAsRead('emp-1', deviceId: deviceA);
      expect(storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(0));

      // ---- 步骤4: Device B 未收到已读广播 ----
      expect(storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(2));

      // ---- 步骤5: Device A 从 Device B 同步摘要 ----
      syncAllBToA();

      // ---- 验证 ----
      final unreadAfterSync =
          storeA.getUnreadCount('emp-1', deviceId: deviceA);
      expect(
        unreadAfterSync,
        equals(0),
        reason: '标记已读后，即使远程有旧数据也不应恢复未读数。'
            '实际值: $unreadAfterSync',
      );
    });

    test('场景3：双向同步后标记已读，再次同步不应恢复', () {
      // ---- 步骤1: Device A 有 5 条未读 ----
      for (int i = 1; i <= 5; i++) {
        storeA.onMessageAdded(
          employeeId: 'emp-1',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-$i',
          createTime: 1000 + i * 100,
          seq: i,
          content: '消息$i',
        );
      }

      // ---- 步骤2: 双向同步 ----
      syncAllAToB();
      syncAllBToA();

      expect(storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(5));
      expect(storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(5));

      // ---- 步骤3: Device A 标记已读 ----
      storeA.markAsRead('emp-1', deviceId: deviceA);
      expect(storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(0));

      // ---- 步骤4: Device B 还没同步到已读状态 ----
      expect(storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(5));

      // ---- 步骤5: 再次双向同步（模拟设备重连后 syncAllFromDevices）----
      syncAllAToB(); // A(0) → B: MAX(5, 0) = 5, B不变
      syncAllBToA(); // B(5) → A: MAX(0, 5) = 5 ❌

      // ---- 验证 ----
      final unreadA = storeA.getUnreadCount('emp-1', deviceId: deviceA);
      expect(
        unreadA,
        equals(0),
        reason: '双向同步后标记已读，再次同步不应恢复。实际值: $unreadA',
      );
    });

    test('场景4：多员工分别标记已读，同步后各员工独立正确', () {
      // ---- 步骤1: 3 个员工各有未读 ----
      for (final empId in ['emp-1', 'emp-2', 'emp-3']) {
        storeA.onMessageAdded(
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: '${empId}-msg-1',
          createTime: 1000,
          seq: 1,
          content: '$empId 的消息',
        );
        storeA.onMessageAdded(
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: '${empId}-msg-2',
          createTime: 2000,
          seq: 2,
          content: '$empId 的消息2',
        );
      }

      // ---- 步骤2: 同步到 Device B ----
      syncAllAToB();

      // ---- 步骤3: 只标记 emp-1 和 emp-3 已读，emp-2 保持未读 ----
      storeA.markAsRead('emp-1', deviceId: deviceA);
      storeA.markAsRead('emp-3', deviceId: deviceA);
      // emp-2 不标记

      expect(storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(0));
      expect(storeA.getUnreadCount('emp-2', deviceId: deviceA), equals(2));
      expect(storeA.getUnreadCount('emp-3', deviceId: deviceA), equals(0));

      // ---- 步骤4: 从 Device B 同步回来 ----
      syncAllBToA();

      // ---- 验证：已读的不应恢复，未读的保持 ----
      expect(
        storeA.getUnreadCount('emp-1', deviceId: deviceA),
        equals(0),
        reason: 'emp-1 已标记已读，同步后不应恢复',
      );
      expect(
        storeA.getUnreadCount('emp-2', deviceId: deviceA),
        equals(2),
        reason: 'emp-2 未标记已读，同步后保持未读',
      );
      expect(
        storeA.getUnreadCount('emp-3', deviceId: deviceA),
        equals(0),
        reason: 'emp-3 已标记已读，同步后不应恢复',
      );
    });

    test('场景5：标记已读后远程有新消息，同步后不应恢复旧消息的已读状态', () {
      // ---- 步骤1: Device A 有 3 条未读 ----
      for (int i = 1; i <= 3; i++) {
        storeA.onMessageAdded(
          employeeId: 'emp-1',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-$i',
          createTime: 1000 + i * 100,
          seq: i,
          content: '消息$i',
        );
      }
      syncAllAToB();

      // ---- 步骤2: Device A 标记已读 ----
      storeA.markAsRead('emp-1', deviceId: deviceA);
      expect(storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(0));

      // ---- 步骤3: Device B 的摘要被远程更新（模拟 Device B 尚未收到已读广播，
      //      同时远程有新消息到来，B 中 unread_count 变成 5）----
      // 直接构造远程摘要实体（绕过 onMessageAdded 的 UPSERT 逻辑）
      final remoteSummary = SessionSummaryEntity(
        employeeId: 'emp-1',
        deviceId: deviceA,
        unreadCount: 5, // 3 old (未收到已读广播) + 2 new
        lastMsgId: 'msg-5',
        lastMsgRole: 'assistant',
        lastMsgContent: '新消息5',
        lastMsgTime: 5000,
        lastMsgSeq: 5,
        updateTime: 5000,
      );
      storeB.upsertFromRemote(remoteSummary);
      expect(storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(5));

      // ---- 步骤4: 从 Device B 同步 ----
      syncAllBToA();

      // ---- 验证 ----
      // 当前行为：MAX(0, 5) = 5，所有旧消息的未读也恢复了
      // 期望行为：已读的 3 条不应恢复，只应有新消息的 2 条未读
      final unreadAfterSync =
          storeA.getUnreadCount('emp-1', deviceId: deviceA);
      expect(
        unreadAfterSync,
        equals(0),
        reason: '标记已读后，即使远程有新消息，也不应通过 upsertFromRemote '
            '恢复已读消息的未读数。实际值: $unreadAfterSync。'
            '（注：精确计算新消息未读数需要消息级别同步，此处验证最低限度——不应恢复已读）',
      );
    });

    test('场景6：全局标记已读后，同步不应恢复任何员工的未读数', () {
      // ---- 步骤1: 多个员工有未读 ----
      for (int i = 1; i <= 3; i++) {
        storeA.onMessageAdded(
          employeeId: 'emp-$i',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-$i',
          createTime: 1000 + i * 100,
          seq: i,
          content: '消息$i',
        );
      }

      // ---- 步骤2: 同步到 Device B ----
      syncAllAToB();

      // ---- 步骤3: Device A 全局标记已读 ----
      storeA.markAllAsRead(deviceId: deviceA);

      for (int i = 1; i <= 3; i++) {
        expect(storeA.getUnreadCount('emp-$i', deviceId: deviceA), equals(0));
      }

      // ---- 步骤4: 从 Device B 同步回来 ----
      syncAllBToA();

      // ---- 验证：所有员工不应恢复未读 ----
      for (int i = 1; i <= 3; i++) {
        expect(
          storeA.getUnreadCount('emp-$i', deviceId: deviceA),
          equals(0),
          reason: 'emp-$i 全局标记已读后，同步不应恢复未读数',
        );
      }
    });

    test('场景7：连续多次同步不应恢复已读状态', () {
      // ---- 步骤1: Device A 有 10 条未读 ----
      for (int i = 1; i <= 10; i++) {
        storeA.onMessageAdded(
          employeeId: 'emp-1',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-$i',
          createTime: 1000 + i * 100,
          seq: i,
          content: '消息$i',
        );
      }
      syncAllAToB();
      expect(storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(10));

      // ---- 步骤2: 标记已读 ----
      storeA.markAsRead('emp-1', deviceId: deviceA);
      expect(storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(0));

      // ---- 步骤3: 连续 5 次从 Device B 同步 ----
      for (int i = 0; i < 5; i++) {
        syncAllBToA();
      }

      // ---- 验证 ----
      expect(
        storeA.getUnreadCount('emp-1', deviceId: deviceA),
        equals(0),
        reason: '连续多次同步不应恢复已读状态',
      );
    });
  });

  // ═══════════════════════════════════════════════════
  // 补充测试：验证正常同步流程不受影响
  // ═══════════════════════════════════════════════════

  group('正常同步流程（不受影响）', () {
    test('未标记已读时，同步应正确传递未读数', () {
      storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '消息1',
      );

      syncAllAToB();

      expect(storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(1));
    });

    test('两端都有未读时，同步取 MAX 是正确的', () {
      // Device A 有 3 条未读（employeeId=emp-1, deviceId=deviceA）
      for (int i = 1; i <= 3; i++) {
        storeA.onMessageAdded(
          employeeId: 'emp-1',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-a-$i',
          createTime: 1000 + i * 100,
          seq: i,
          content: 'A消息$i',
        );
      }
      expect(storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(3));

      // Device B 有 5 条未读（employeeId=emp-1, deviceId=deviceB，不同 deviceId）
      for (int i = 1; i <= 5; i++) {
        storeB.onMessageAdded(
          employeeId: 'emp-1',
          deviceId: deviceB,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-b-$i',
          createTime: 1000 + i * 100,
          seq: i,
          content: 'B消息$i',
        );
      }
      expect(storeB.getUnreadCount('emp-1', deviceId: deviceB), equals(5));

      // 双向同步
      syncAllAToB();
      syncAllBToA();

      // 各自的原始摘要不变
      expect(storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(3));
      expect(storeB.getUnreadCount('emp-1', deviceId: deviceB), equals(5));

      // 同步过来的摘要也是正确的
      expect(storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(3));
      expect(storeA.getUnreadCount('emp-1', deviceId: deviceB), equals(5));
    });

    test('新消息到来后同步应正确累加未读', () {
      // Device A 有 2 条未读
      storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '消息1',
      );
      storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-2',
        createTime: 2000,
        seq: 2,
        content: '消息2',
      );
      syncAllAToB();

      // Device B 也产生 1 条未读（同 employeeId+deviceId）
      // 通过直接构造远程摘要模拟
      final remoteSummary = SessionSummaryEntity(
        employeeId: 'emp-1',
        deviceId: deviceA,
        unreadCount: 3,
        lastMsgId: 'msg-b-1',
        lastMsgRole: 'assistant',
        lastMsgContent: 'B的新消息',
        lastMsgTime: 3000,
        lastMsgSeq: 3,
        updateTime: 3000,
      );
      storeB.upsertFromRemote(remoteSummary);

      // 同步到 A：MAX(2, 3) = 3
      syncAllBToA();
      expect(storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(3));
    });
  });
}
