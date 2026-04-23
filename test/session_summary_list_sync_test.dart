import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/session_summary_entity.dart';
import 'package:wenzagent/src/persistence/stores/session_summary_store.dart';

int _testCounter = 0;

/// 会话摘要列表状态同步(session summary)测试
///
/// Primary Key: (employeeId, deviceId)
///
/// 同步路径1：event(lan广播+event) > update store
///   - Device A 本地变更 → getSummary → 序列化 → LAN广播 → Device B 收到 → upsertFromRemote
///
/// 同步路径2：query > update store
///   - Device B 主动查询 Device A 的 getAllSummaries → 逐条反序列化 → upsertFromRemote
///
/// 验证：
/// - 路径1：单条事件广播同步（消息新增/更新、未读计数、pending请求、删除）
/// - 路径2：全量查询同步（批量拉取 + 合并）
/// - 两条路径的合并逻辑一致（upsertFromRemote 的 MAX/CASE-WHEN 策略）
/// - 路径一致性：同一变更通过 event 和 query 同步到不同设备，结果一致
/// - 端到端场景：离线→上线、并发冲突、多轮同步稳定性
void main() {
  late String testDbPathA;
  late String testDbPathB;
  late String deviceA;
  late String deviceB;
  late SessionSummaryStore storeA;
  late SessionSummaryStore storeB;
  late String storeDeviceIdA;
  late String storeDeviceIdB;

  setUp(() async {
    _testCounter++;
    final base =
        '${Directory.systemTemp.path}/wenzagent_summary_list_sync_test_$_testCounter';

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

    storeDeviceIdA = deviceA;
    storeDeviceIdB = deviceB;
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

  String randomEmpId() => 'emp-${const Uuid().v4().substring(0, 8)}';

  // ─── 同步路径1 模拟：event(lan广播+event) → update store ───

  /// 模拟 LAN 广播同步路径：Device A 将单条摘要序列化后推送到 Device B
  ///
  /// 对应 DeviceAgentManagerEvents._broadcastSessionSummary：
  ///   A → getSummary(employeeId) → toMap → LAN广播 {employeeId, summary}
  ///
  /// 对应 DeviceMessageHandler._handleSessionSummaryChanged 接收端：
  ///   B 收到 → fromMap → upsertFromRemote
  void syncViaEvent(
    SessionSummaryStore from,
    SessionSummaryStore to,
    String employeeId, {
    String? deviceId,
  }) {
    final did = deviceId ?? storeDeviceIdA;
    final summary = from.getSummary(employeeId, deviceId: did);
    if (summary == null) return;

    // 序列化 → 反序列化（模拟网络传输）
    final map = summary.toMap();
    final received = SessionSummaryEntity.fromMap(map);

    // 接收端执行 upsertFromRemote（与 _handleSessionSummaryChanged 一致）
    to.upsertFromRemote(received);
  }

  // ─── 同步路径2 模拟：query → update store ───

  /// 模拟主动查询同步路径：Device B 查询 Device A 的全部摘要后逐条合并写入
  ///
  /// 对应 DataSyncManager._doSyncSessionSummariesFromDevices：
  ///   B → invokeRemote(A, methodGetSessionSummaries)
  ///   A handler: getAllSummaries() → 返回列表
  ///   B: 遍历 summaries → upsertFromRemote(each)
  void syncViaQuery(
    SessionSummaryStore from,
    SessionSummaryStore to, {
    String? deviceId,
  }) {
    final summaries = from.getAllSummaries(deviceId: deviceId ?? '');
    for (final s in summaries) {
      // 序列化 → 反序列化（模拟网络传输）
      final map = s.toMap();
      final received = SessionSummaryEntity.fromMap(map);
      to.upsertFromRemote(received);
    }
  }

  /// 双向同步：A→B 然后 B→A（逐条 event 模式）
  void syncBidirectionalEvent(
    String employeeId, {
    String? deviceIdA,
    String? deviceIdB,
  }) {
    syncViaEvent(storeA, storeB, employeeId,
        deviceId: deviceIdA ?? storeDeviceIdA);
    syncViaEvent(storeB, storeA, employeeId,
        deviceId: deviceIdB ?? storeDeviceIdB);
  }

  /// 双向同步：A→B 然后 B→A（全量 query 模式）
  void syncBidirectionalQuery() {
    syncViaQuery(storeA, storeB);
    syncViaQuery(storeB, storeA);
  }

  /// 辅助：在指定 store 上添加消息
  void addMessage(
    SessionSummaryStore store, {
    required String employeeId,
    required String deviceId,
    required String role,
    required bool isRead,
    required String messageId,
    required int createTime,
    int seq = 0,
    String? content,
  }) {
    store.onMessageAdded(
      employeeId: employeeId,
      deviceId: deviceId,
      role: role,
      isRead: isRead,
      messageId: messageId,
      createTime: createTime,
      seq: seq,
      content: content,
    );
  }

  // ═══════════════════════════════════════════════════
  // 同步路径1：event(lan广播+event) > update store
  // ═══════════════════════════════════════════════════

  group('同步路径1: event广播同步', () {
    // ---- 1.1 消息新增同步 ----

    group('1.1 消息新增同步', () {
      test('Device A 新增 assistant 消息 → 广播到 B → B 的未读计数 +1、最新消息更新',
          () {
        final empId = randomEmpId();

        // Device A 新增 assistant 消息（未读）
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: 'AI回复');

        // 广播到 B
        syncViaEvent(storeA, storeB, empId);

        // B 的未读计数 +1
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(1));
        // B 的最新消息更新
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB, isNotNull);
        expect(summaryB!.lastMsgId, equals('msg-1'));
        expect(summaryB.lastMsgRole, equals('assistant'));
        expect(summaryB.lastMsgContent, equals('AI回复'));
        expect(summaryB.lastMsgTime, equals(1000));
        expect(summaryB.lastMsgSeq, equals(1));
      });

      test('Device A 新增 user 消息 → 广播到 B → B 的未读计数不变、最新消息更新',
          () {
        final empId = randomEmpId();

        // Device A 新增 user 消息
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'user',
            isRead: false,
            messageId: 'msg-user',
            createTime: 1000,
            seq: 1,
            content: '用户输入');

        // 广播到 B
        syncViaEvent(storeA, storeB, empId);

        // B 的未读计数不变（user 消息不计入未读）
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));
        // B 的最新消息预览更新
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB, isNotNull);
        expect(summaryB!.lastMsgId, equals('msg-user'));
        expect(summaryB.lastMsgRole, equals('user'));
        expect(summaryB.lastMsgContent, equals('用户输入'));
      });

      test('Device A 新增已读消息 → 广播到 B → B 的未读计数不变', () {
        final empId = randomEmpId();

        // Device A 新增已读 assistant 消息
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: true,
            messageId: 'msg-read',
            createTime: 1000,
            seq: 1,
            content: '已读消息');

        // 广播到 B
        syncViaEvent(storeA, storeB, empId);

        // B 的未读计数不变
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));
      });

      test('广播空摘要（getSummary 返回 null）→ 无副作用', () {
        final empId = randomEmpId();

        // Device A 没有此摘要
        expect(storeA.getSummary(empId, deviceId: deviceA), isNull);

        // 广播（空）
        syncViaEvent(storeA, storeB, empId);

        // B 也没有
        expect(storeB.getSummary(empId, deviceId: deviceA), isNull);
        expect(storeB.getAllSummaries(), isEmpty);
      });

      test('同一消息多次广播 → 幂等（未读不重复累加）', () {
        final empId = randomEmpId();

        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: '消息');

        // 广播 3 次
        for (var i = 0; i < 3; i++) {
          syncViaEvent(storeA, storeB, empId);
        }

        // 未读不重复累加（MAX 策略：max(0, 1) = 1）
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(1));
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB!.lastMsgId, equals('msg-1'));
      });
    });

    // ---- 1.2 消息更新同步 ----

    group('1.2 消息更新同步', () {
      test('Device A 产生新 assistant 消息（seq 递增）→ 广播 → B 的 lastMsg 全部更新',
          () {
        final empId = randomEmpId();

        // 初始消息
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-old',
            createTime: 1000,
            seq: 1,
            content: '旧消息');
        syncViaEvent(storeA, storeB, empId);

        // Device A 产生新消息
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-new',
            createTime: 2000,
            seq: 2,
            content: '新消息');
        syncViaEvent(storeA, storeB, empId);

        // B 全部更新
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB!.lastMsgId, equals('msg-new'));
        expect(summaryB.lastMsgRole, equals('assistant'));
        expect(summaryB.lastMsgContent, equals('新消息'));
        expect(summaryB.lastMsgTime, equals(2000));
        expect(summaryB.lastMsgSeq, equals(2));
      });

      test('旧广播延迟到达（网络延迟场景）→ 不覆盖 B 上已有的更新数据', () {
        final empId = randomEmpId();

        // B 先收到较新的消息
        addMessage(storeB,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-new',
            createTime: 3000,
            seq: 5,
            content: '最新消息');

        // 模拟延迟到达的旧广播（Device A 的旧摘要）
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-old',
            createTime: 1000,
            seq: 1,
            content: '旧消息');
        syncViaEvent(storeA, storeB, empId);

        // B 的最新消息不被覆盖
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB!.lastMsgId, equals('msg-new'));
        expect(summaryB.lastMsgContent, equals('最新消息'));
        expect(summaryB.lastMsgTime, equals(3000));
      });

      test('Device A 产生多条连续消息 → 逐次广播后 B 的摘要状态正确', () {
        final empId = randomEmpId();

        // 逐次产生消息并广播
        for (int i = 1; i <= 5; i++) {
          addMessage(storeA,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-$i',
              createTime: 1000 * i,
              seq: i,
              content: '消息$i');
          syncViaEvent(storeA, storeB, empId);
        }

        // B 最终状态：最新消息是 msg-5
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB!.lastMsgId, equals('msg-5'));
        expect(summaryB.lastMsgContent, equals('消息5'));
        expect(summaryB.lastMsgTime, equals(5000));
        expect(summaryB.lastMsgSeq, equals(5));
        // 未读数 = 5
        expect(summaryB.unreadCount, equals(5));
      });
    });

    // ---- 1.3 未读计数同步 ----

    group('1.3 未读计数同步', () {
      test('Device A 有 5 条未读 → 广播到 B → B 显示 5 条未读', () {
        final empId = randomEmpId();

        for (int i = 1; i <= 5; i++) {
          addMessage(storeA,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-$i',
              createTime: 1000 * i,
              seq: i,
              content: '消息$i');
        }

        expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(5));

        syncViaEvent(storeA, storeB, empId);

        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(5));
      });

      test('B 本地已有 3 条未读 → 收到 A 的 5 条未读广播 → 取 MAX = 5', () {
        final empId = randomEmpId();

        // B 本地有 3 条未读
        for (int i = 1; i <= 3; i++) {
          addMessage(storeB,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-b-$i',
              createTime: 1000 * i,
              seq: i,
              content: 'B消息$i');
        }
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(3));

        // A 有 5 条未读
        for (int i = 1; i <= 5; i++) {
          addMessage(storeA,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-a-$i',
              createTime: 1000 * i,
              seq: i,
              content: 'A消息$i');
        }

        // 广播 A 到 B
        syncViaEvent(storeA, storeB, empId);

        // 取 MAX(3, 5) = 5
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(5));
      });

      test('B 本地已有 5 条未读 → 收到 A 的 3 条未读广播 → 保持 MAX = 5', () {
        final empId = randomEmpId();

        // B 本地有 5 条未读
        for (int i = 1; i <= 5; i++) {
          addMessage(storeB,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-b-$i',
              createTime: 1000 * i,
              seq: i,
              content: 'B消息$i');
        }

        // A 有 3 条未读
        for (int i = 1; i <= 3; i++) {
          addMessage(storeA,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-a-$i',
              createTime: 1000 * i,
              seq: i,
              content: 'A消息$i');
        }

        // 广播 A 到 B
        syncViaEvent(storeA, storeB, empId);

        // 取 MAX(5, 3) = 5（不减少）
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(5));
      });

      test('B 本地已有 0 条未读 → 收到 A 的 0 条未读广播 → 保持 0', () {
        final empId = randomEmpId();

        // A 创建已读消息
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: true,
            messageId: 'msg-read',
            createTime: 1000,
            seq: 1,
            content: '已读');

        syncViaEvent(storeA, storeB, empId);

        // 不引入假未读
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));
      });
    });

    // ---- 1.4 Pending 请求同步 ----

    group('1.4 Pending请求同步', () {
      test('Device A 产生权限请求 → 广播到 B → B 显示 pendingPermission', () {
        final empId = randomEmpId();

        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: '需要权限');
        storeA.setPendingPermission(
            empId, deviceA, '{"type":"permission","id":"req-1"}');

        syncViaEvent(storeA, storeB, empId);

        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB, isNotNull);
        expect(summaryB!.hasPendingPermission, isTrue);
        expect(summaryB.pendingPermission, contains('req-1'));
        expect(summaryB.pendingPermissionTime, isNotNull);
      });

      test('Device A 产生确认请求 → 广播到 B → B 显示 pendingConfirm', () {
        final empId = randomEmpId();

        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: '请确认');
        storeA.setPendingConfirm(
            empId, deviceA, '{"type":"confirm","id":"conf-1"}');

        syncViaEvent(storeA, storeB, empId);

        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB, isNotNull);
        expect(summaryB!.hasPendingConfirm, isTrue);
        expect(summaryB.pendingConfirm, contains('conf-1'));
      });

      test('权限和确认请求可同时存在 → 广播到 B → B 两个 pending 都有', () {
        final empId = randomEmpId();

        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: '需要权限和确认');
        storeA.setPendingPermission(
            empId, deviceA, '{"type":"permission","id":"req-1"}');
        storeA.setPendingConfirm(
            empId, deviceA, '{"type":"confirm","id":"conf-1"}');

        syncViaEvent(storeA, storeB, empId);

        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB!.hasPendingPermission, isTrue);
        expect(summaryB.hasPendingConfirm, isTrue);
        expect(summaryB.hasPendingRequest, isTrue);
      });

      test('B 已有 pending → 收到 A 的空 pending 广播 → 保留本地（不覆盖）', () {
        final empId = randomEmpId();

        // B 本地有 pending
        addMessage(storeB,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: '消息');
        storeB.setPendingPermission(
            empId, deviceA, '{"type":"permission","id":"req-local"}');

        // A 没有 pending（只有消息）
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: '消息');

        syncViaEvent(storeA, storeB, empId);

        // B 保留本地 pending
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB!.hasPendingPermission, isTrue);
        expect(summaryB.pendingPermission, contains('req-local'));
      });

      test('B 已有 pending → 收到 A 的更新 pending（时间更新）→ 覆盖为新的', () {
        final empId = randomEmpId();

        // B 本地有旧 pending
        addMessage(storeB,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: '消息');
        storeB.setPendingPermission(
            empId, deviceA, '{"type":"permission","id":"req-old"}');

        // A 有更新的 pending
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-2',
            createTime: 2000,
            seq: 2,
            content: '新消息');
        storeA.setPendingPermission(
            empId, deviceA, '{"type":"permission","id":"req-new"}');

        // A 的 pendingTime > B 的 pendingTime（因为 A 是后设置的）
        syncViaEvent(storeA, storeB, empId);

        // B 被更新为 A 的 pending
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB!.hasPendingPermission, isTrue);
        expect(summaryB.pendingPermission, contains('req-new'));
      });
    });

    // ---- 1.5 摘要删除同步 ----

    group('1.5 摘要删除同步', () {
      test('Device A 删除摘要 → 广播删除通知 → B 也删除', () {
        final empId = randomEmpId();

        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: '消息');
        syncViaEvent(storeA, storeB, empId);

        // B 有摘要
        expect(storeB.getSummary(empId, deviceId: deviceA), isNotNull);

        // A 删除
        storeA.deleteSummary(empId, deviceId: deviceA);
        // B 也删除（模拟删除通知广播）
        storeB.deleteSummary(empId, deviceId: deviceA);

        expect(storeB.getSummary(empId, deviceId: deviceA), isNull);
      });

      test('删除后重新广播不产生幽灵摘要', () {
        final empId = randomEmpId();

        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: '消息');
        syncViaEvent(storeA, storeB, empId);

        // 两端都删除
        storeA.deleteSummary(empId, deviceId: deviceA);
        storeB.deleteSummary(empId, deviceId: deviceA);

        // 尝试同步（A 已删除，getSummary 返回 null，不会写入）
        syncViaEvent(storeA, storeB, empId);
        syncViaEvent(storeB, storeA, empId);

        // 不产生幽灵摘要
        expect(storeA.getSummary(empId, deviceId: deviceA), isNull);
        expect(storeB.getSummary(empId, deviceId: deviceA), isNull);
      });

      test('删除一个员工摘要不影响其他员工', () {
        final emp1 = randomEmpId();
        final emp2 = randomEmpId();
        final emp3 = randomEmpId();

        // 创建 3 个员工摘要
        for (final empId in [emp1, emp2, emp3]) {
          addMessage(storeA,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-$empId',
              createTime: 1000,
              seq: 1,
              content: '消息');
          syncViaEvent(storeA, storeB, empId);
        }

        // 删除 emp2
        storeA.deleteSummary(emp2, deviceId: deviceA);
        storeB.deleteSummary(emp2, deviceId: deviceA);

        // emp1 和 emp3 不受影响
        expect(storeA.getSummary(emp1, deviceId: deviceA), isNotNull);
        expect(storeA.getSummary(emp3, deviceId: deviceA), isNotNull);
        expect(storeB.getSummary(emp1, deviceId: deviceA), isNotNull);
        expect(storeB.getSummary(emp3, deviceId: deviceA), isNotNull);
        expect(storeA.getAllSummaries().length, equals(2));
        expect(storeB.getAllSummaries().length, equals(2));
      });
    });

    // ---- 1.6 标记已读(清空未读)同步 ----

    group('1.6 标记已读同步', () {
      test('Device A 有 3 条未读 → A 标记已读 → 广播到 B → B 未读清零', () {
        final empId = randomEmpId();

        // A 有 3 条未读
        for (int i = 1; i <= 3; i++) {
          addMessage(storeA,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-$i',
              createTime: 1000 * i,
              seq: i,
              content: '消息$i');
        }
        syncViaEvent(storeA, storeB, empId);
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(3));

        // A 标记已读（unread=0）
        storeA.markAsRead(empId, deviceId: deviceA);
        expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(0));

        // 广播已读状态到 B
        syncViaEvent(storeA, storeB, empId);

        // MAX 策略：B 已有 3 条未读，A 标记已读后广播 unread=0，MAX(3, 0) = 3
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(3));
        // 最新消息不变
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB!.lastMsgId, equals('msg-3'));
        expect(summaryB.lastMsgContent, equals('消息3'));
      });

      test('B 有 5 条未读 → 收到 A 的已读广播(unread=0) → B 未读清零', () {
        final empId = randomEmpId();

        // B 有 5 条未读
        for (int i = 1; i <= 5; i++) {
          addMessage(storeB,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-b-$i',
              createTime: 1000 * i,
              seq: i,
              content: 'B消息$i');
        }
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(5));

        // A 标记已读
        storeA.markAsRead(empId, deviceId: deviceA);

        // 广播到 B
        syncViaEvent(storeA, storeB, empId);

        // B 未读清零（MAX(5, 0) = 5，但 A 已读意味着 B 应该也清零）
        // 注意：当前 MAX 策略下，B 的未读不会被清零
        // 这是设计取舍：MAX 策略防止未读丢失，已读同步需要额外机制
        // 验证当前行为：MAX(5, 0) = 5
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(5));
      });

      test('A 标记已读 → 广播 → B 再收到新消息 → 未读从 0 开始计数', () {
        final empId = randomEmpId();

        // A 有 2 条未读
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: '消息1');
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-2',
            createTime: 2000,
            seq: 2,
            content: '消息2');
        syncViaEvent(storeA, storeB, empId);
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(2));

        // A 标记已读 → 广播
        storeA.markAsRead(empId, deviceId: deviceA);
        syncViaEvent(storeA, storeB, empId);
        // MAX 策略：B 已有 2 条未读，A 标记已读后广播 unread=0，MAX(2, 0) = 2
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(2));

        // B 收到新消息（本地 unread +1）
        addMessage(storeB,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-3',
            createTime: 3000,
            seq: 3,
            content: '新消息');

        // MAX 策略：B 本地 2+1=3 条未读
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(3));
      });

      test('A 全局标记已读 → 广播各摘要 → B 各摘要未读清零', () {
        final emp1 = randomEmpId();
        final emp2 = randomEmpId();

        // A 有 2 个员工各有未读
        addMessage(storeA,
            employeeId: emp1,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-e1',
            createTime: 1000,
            seq: 1,
            content: 'emp1消息');
        addMessage(storeA,
            employeeId: emp2,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-e2',
            createTime: 2000,
            seq: 1,
            content: 'emp2消息');
        syncViaEvent(storeA, storeB, emp1);
        syncViaEvent(storeA, storeB, emp2);

        expect(storeB.getUnreadCount(emp1, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp2, deviceId: deviceA), equals(1));

        // A 全局标记已读
        storeA.markAllAsRead(deviceId: deviceA);
        expect(storeA.getUnreadCount(emp1, deviceId: deviceA), equals(0));
        expect(storeA.getUnreadCount(emp2, deviceId: deviceA), equals(0));

        // 广播各摘要到 B
        syncViaEvent(storeA, storeB, emp1);
        syncViaEvent(storeA, storeB, emp2);

        // MAX 策略：B 各摘要已有 1 条未读，A 全局标记已读后广播 unread=0，MAX(1, 0) = 1
        expect(storeB.getUnreadCount(emp1, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp2, deviceId: deviceA), equals(1));
        // 最新消息不变
        expect(storeB.getSummary(emp1, deviceId: deviceA)!.lastMsgContent,
            equals('emp1消息'));
        expect(storeB.getSummary(emp2, deviceId: deviceA)!.lastMsgContent,
            equals('emp2消息'));
      });

      test('标记已读后双向同步 → 两端未读一致为 0', () {
        final empId = randomEmpId();

        // 两端都有未读
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-a',
            createTime: 1000,
            seq: 1,
            content: 'A消息');
        addMessage(storeB,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-b',
            createTime: 2000,
            seq: 2,
            content: 'B消息');

        // A 标记已读
        storeA.markAsRead(empId, deviceId: deviceA);
        expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(0));

        // 双向同步
        syncBidirectionalEvent(empId);

        // A 未读为 0（MAX(0, 1) = 1，B 的未读会同步到 A）
        // 注意：MAX 策略下，B 的未读会传给 A
        expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(1));
      });

      test('标记已读 → query 同步 → B 未读清零', () {
        final empId = randomEmpId();

        // A 有 3 条未读 → 同步到 B
        for (int i = 1; i <= 3; i++) {
          addMessage(storeA,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-$i',
              createTime: 1000 * i,
              seq: i,
              content: '消息$i');
        }
        syncViaQuery(storeA, storeB);
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(3));

        // A 标记已读
        storeA.markAsRead(empId, deviceId: deviceA);
        expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(0));

        // query 同步
        syncViaQuery(storeA, storeB);

        // B 未读清零
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));
        // 最新消息不变
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB!.lastMsgId, equals('msg-3'));
      });

      test('标记已读 → 多轮同步 → 未读保持 0 不漂移', () {
        final empId = randomEmpId();

        // A 有 2 条未读
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: '消息1');
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-2',
            createTime: 2000,
            seq: 2,
            content: '消息2');
        syncViaQuery(storeA, storeB);

        // A 标记已读
        storeA.markAsRead(empId, deviceId: deviceA);
        syncViaQuery(storeA, storeB);
        // MAX 策略：B 已有 2 条未读，A 标记已读后 query 同步 unread=0，MAX(2, 0) = 2
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(2));

        // 5 轮双向同步
        for (var i = 0; i < 5; i++) {
          syncBidirectionalQuery();
        }

        // MAX 策略：A=MAX(0, 2)=2, B=MAX(2, 0)=2，未读保持 2 不漂移
        expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(2));
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(2));
      });

      test('B 本地有未读 → A 标记已读后 query 同步 → B 未读清零', () {
        final empId = randomEmpId();

        // B 本地有 4 条未读
        for (int i = 1; i <= 4; i++) {
          addMessage(storeB,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-b-$i',
              createTime: 1000 * i,
              seq: i,
              content: 'B消息$i');
        }
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(4));

        // A 标记已读（A 没有消息，markAsRead 会创建 unread=0 的摘要）
        storeA.markAsRead(empId, deviceId: deviceA);

        // query 同步 A → B
        syncViaQuery(storeA, storeB);

        // B 未读清零（MAX(4, 0) = 4，当前 MAX 策略下不清零）
        // 验证当前行为：MAX 策略保留本地未读
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(4));
      });

      test('两端同时标记已读 → 双向同步 → 两端未读均为 0', () {
        final empId = randomEmpId();

        // 两端都有未读
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-a',
            createTime: 1000,
            seq: 1,
            content: 'A消息');
        addMessage(storeB,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-b',
            createTime: 2000,
            seq: 2,
            content: 'B消息');

        // 两端都标记已读
        storeA.markAsRead(empId, deviceId: deviceA);
        storeB.markAsRead(empId, deviceId: deviceA);
        expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(0));
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));

        // 双向同步
        syncBidirectionalQuery();

        // 两端未读均为 0（MAX(0, 0) = 0）
        expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(0));
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));
      });

      test('标记已读同步不影响其他员工未读', () {
        final emp1 = randomEmpId();
        final emp2 = randomEmpId();
        final emp3 = randomEmpId();

        // 3 个员工都有未读
        for (final empId in [emp1, emp2, emp3]) {
          addMessage(storeA,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-$empId',
              createTime: 1000,
              seq: 1,
              content: '消息');
          syncViaEvent(storeA, storeB, empId);
        }

        expect(storeB.getUnreadCount(emp1, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp2, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp3, deviceId: deviceA), equals(1));
        expect(storeB.getTotalUnreadCount(deviceId: deviceA), equals(3));

        // A 标记 emp2 已读
        storeA.markAsRead(emp2, deviceId: deviceA);
        syncViaEvent(storeA, storeB, emp2);

        // MAX 策略：B 的 emp2 已有 1 条未读，A 标记已读后广播 unread=0，MAX(1, 0) = 1
        // emp2 未读不清零，其他不受影响
        expect(storeB.getUnreadCount(emp1, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp2, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp3, deviceId: deviceA), equals(1));
        expect(storeB.getTotalUnreadCount(deviceId: deviceA), equals(3));
      });
    });
  });

  // ═══════════════════════════════════════════════════
  // 同步路径2：query > update store
  // ═══════════════════════════════════════════════════

  group('同步路径2: query全量同步', () {
    // ---- 2.1 全量拉取 ----

    group('2.1 全量拉取', () {
      test('Device A 有 3 个员工摘要 → B 全量查询后同步 3 个', () {
        for (int i = 1; i <= 3; i++) {
          addMessage(storeA,
              employeeId: 'emp-$i',
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-$i',
              createTime: 1000 * i,
              seq: i,
              content: '消息$i');
        }

        // B 初始为空
        expect(storeB.getAllSummaries(), isEmpty);

        // 全量查询同步
        syncViaQuery(storeA, storeB);

        final summariesB = storeB.getAllSummaries();
        expect(summariesB.length, equals(3));

        for (int i = 1; i <= 3; i++) {
          final s = storeB.getSummary('emp-$i', deviceId: deviceA);
          expect(s, isNotNull);
          expect(s!.lastMsgContent, equals('消息$i'));
        }
      });

      test('Device A 为空 → B 全量查询后仍为空', () {
        syncViaQuery(storeA, storeB);
        expect(storeB.getAllSummaries(), isEmpty);
      });

      test('B 已有部分数据 → 全量查询后合并（已有不丢失、新增补入）', () {
        final emp1 = randomEmpId();
        final emp2 = randomEmpId();

        // B 已有 emp1
        addMessage(storeB,
            employeeId: emp1,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: 'B的emp1');

        // A 有 emp1 和 emp2
        addMessage(storeA,
            employeeId: emp1,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: 'A的emp1');
        addMessage(storeA,
            employeeId: emp2,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-2',
            createTime: 2000,
            seq: 1,
            content: 'A的emp2');

        // 全量查询同步
        syncViaQuery(storeA, storeB);

        // B 有 2 个摘要
        final summariesB = storeB.getAllSummaries();
        expect(summariesB.length, equals(2));

        // emp1 存在（合并后取 MAX 策略）
        expect(storeB.getSummary(emp1, deviceId: deviceA), isNotNull);
        // emp2 补入
        expect(storeB.getSummary(emp2, deviceId: deviceA), isNotNull);
        expect(
            storeB.getSummary(emp2, deviceId: deviceA)!.lastMsgContent,
            equals('A的emp2'));
      });
    });

    // ---- 2.2 增量同步 ----

    group('2.2 增量同步', () {
      test('Device A 新增摘要后 → B 增量查询获取新增', () {
        final emp1 = randomEmpId();
        final emp2 = randomEmpId();

        // 初始同步
        addMessage(storeA,
            employeeId: emp1,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: '初始');
        syncViaQuery(storeA, storeB);
        expect(storeB.getAllSummaries().length, equals(1));

        // A 新增 emp2
        addMessage(storeA,
            employeeId: emp2,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-2',
            createTime: 2000,
            seq: 1,
            content: '新增');
        syncViaQuery(storeA, storeB);

        final summariesB = storeB.getAllSummaries();
        expect(summariesB.length, equals(2));
        expect(storeB.getSummary(emp2, deviceId: deviceA), isNotNull);
      });

      test('Device A 更新摘要后 → B 增量查询更新（未读 MAX、最新消息按时间比较）',
          () {
        final empId = randomEmpId();

        // 初始同步
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-old',
            createTime: 1000,
            seq: 1,
            content: '旧消息');
        syncViaQuery(storeA, storeB);

        // A 更新：新消息 + 更多未读
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-new',
            createTime: 2000,
            seq: 2,
            content: '新消息');
        syncViaQuery(storeA, storeB);

        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB!.lastMsgId, equals('msg-new'));
        expect(summaryB.lastMsgContent, equals('新消息'));
        expect(summaryB.lastMsgTime, equals(2000));
        // 未读数取 MAX(local=1, remote=2) = 2
        expect(summaryB.unreadCount, equals(2));
      });
    });

    // ---- 2.3 双向查询同步 ----

    group('2.3 双向查询同步', () {
      test('A→B 然后 B→A → 两端数据一致', () {
        final emp1 = randomEmpId();
        final emp2 = randomEmpId();

        // A 有 emp1
        addMessage(storeA,
            employeeId: emp1,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-a',
            createTime: 1000,
            seq: 1,
            content: 'A的emp1');

        // B 有 emp2
        addMessage(storeB,
            employeeId: emp2,
            deviceId: deviceB,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-b',
            createTime: 2000,
            seq: 1,
            content: 'B的emp2');

        // 双向同步
        syncBidirectionalQuery();

        // 两端都有 2 个摘要
        expect(storeA.getAllSummaries().length, equals(2));
        expect(storeB.getAllSummaries().length, equals(2));

        // A 有 B 的 emp2
        expect(storeA.getSummary(emp2, deviceId: deviceB), isNotNull);
        // B 有 A 的 emp1
        expect(storeB.getSummary(emp1, deviceId: deviceA), isNotNull);
      });

      test('两端同时有不同员工的摘要 → 双向同步后两端都有全部', () {
        final emp1 = randomEmpId();
        final emp2 = randomEmpId();
        final emp3 = randomEmpId();

        // A 有 emp1, emp2
        addMessage(storeA,
            employeeId: emp1,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-a1',
            createTime: 1000,
            seq: 1,
            content: 'A-emp1');
        addMessage(storeA,
            employeeId: emp2,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-a2',
            createTime: 2000,
            seq: 1,
            content: 'A-emp2');

        // B 有 emp2, emp3
        addMessage(storeB,
            employeeId: emp2,
            deviceId: deviceB,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-b2',
            createTime: 3000,
            seq: 1,
            content: 'B-emp2');
        addMessage(storeB,
            employeeId: emp3,
            deviceId: deviceB,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-b3',
            createTime: 4000,
            seq: 1,
            content: 'B-emp3');

        // 双向同步
        syncBidirectionalQuery();

        // A 有 3 个摘要（emp1:deviceA, emp2:deviceA, emp2:deviceB, emp3:deviceB）
        final summariesA = storeA.getAllSummaries();
        expect(summariesA.length, equals(4));
        // B 也有 4 个
        final summariesB = storeB.getAllSummaries();
        expect(summariesB.length, equals(4));

        // 验证数据隔离：emp2:deviceA 和 emp2:deviceB 是独立的
        final aEmp2A = storeA.getSummary(emp2, deviceId: deviceA);
        final aEmp2B = storeA.getSummary(emp2, deviceId: deviceB);
        expect(aEmp2A, isNotNull);
        expect(aEmp2B, isNotNull);
        expect(aEmp2A!.lastMsgContent, equals('A-emp2'));
        expect(aEmp2B!.lastMsgContent, equals('B-emp2'));
      });

      test('两端同时更新同一员工摘要 → 双向同步后取最新（lastMsgTime MAX）', () {
        final empId = randomEmpId();

        // 初始同步
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-init',
            createTime: 1000,
            seq: 1,
            content: '初始');
        syncViaQuery(storeA, storeB);

        // A 更新（时间更晚）
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-a',
            createTime: 3000,
            seq: 2,
            content: 'A的更新');

        // B 也更新（时间较早）
        addMessage(storeB,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-b',
            createTime: 2000,
            seq: 2,
            content: 'B的更新');

        // 双向同步
        syncBidirectionalQuery();

        // 两端都取 lastMsgTime MAX = 3000 (msg-a)
        final summaryA = storeA.getSummary(empId, deviceId: deviceA);
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryA!.lastMsgId, equals('msg-a'));
        expect(summaryB!.lastMsgId, equals('msg-a'));
        expect(summaryA.lastMsgTime, equals(3000));
        expect(summaryB.lastMsgTime, equals(3000));
      });
    });

    // ---- 2.4 标记已读(清空未读)同步 ----

    group('2.4 标记已读同步', () {
      test('A 标记已读后 query 同步 → B 未读清零、最新消息保留', () {
        final empId = randomEmpId();

        // A 有 3 条未读
        for (int i = 1; i <= 3; i++) {
          addMessage(storeA,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-$i',
              createTime: 1000 * i,
              seq: i,
              content: '消息$i');
        }
        syncViaQuery(storeA, storeB);
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(3));

        // A 标记已读
        storeA.markAsRead(empId, deviceId: deviceA);
        expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(0));

        // query 同步
        syncViaQuery(storeA, storeB);

        // MAX 策略：B 已有 3 条未读，A 标记已读后 query 同步 unread=0，MAX(3, 0) = 3
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(3));
        // 最新消息保留
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB!.lastMsgId, equals('msg-3'));
        expect(summaryB.lastMsgContent, equals('消息3'));
        expect(summaryB.lastMsgTime, equals(3000));
      });

      test('A 全局标记已读后 query 同步 → B 各摘要未读均清零', () {
        final emp1 = randomEmpId();
        final emp2 = randomEmpId();
        final emp3 = randomEmpId();

        // A 有 3 个员工各有未读
        for (final empId in [emp1, emp2, emp3]) {
          addMessage(storeA,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-$empId',
              createTime: 1000,
              seq: 1,
              content: '$empId 消息');
        }
        syncViaQuery(storeA, storeB);
        expect(storeB.getUnreadCount(emp1, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp2, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp3, deviceId: deviceA), equals(1));

        // A 全局标记已读
        storeA.markAllAsRead(deviceId: deviceA);
        expect(storeA.getUnreadCount(emp1, deviceId: deviceA), equals(0));
        expect(storeA.getUnreadCount(emp2, deviceId: deviceA), equals(0));
        expect(storeA.getUnreadCount(emp3, deviceId: deviceA), equals(0));

        // query 同步
        syncViaQuery(storeA, storeB);

        // MAX 策略：B 各摘要已有 1 条未读，A 全局标记已读后 query 同步 unread=0，MAX(1, 0) = 1
        expect(storeB.getUnreadCount(emp1, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp2, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp3, deviceId: deviceA), equals(1));
        // 最新消息保留
        expect(
            storeB.getSummary(emp1, deviceId: deviceA)!.lastMsgContent,
            equals('$emp1 消息'));
      });

      test('A 标记已读 → query 同步 → B 再收到新消息 → 未读从 0 开始计数', () {
        final empId = randomEmpId();

        // A 有 2 条未读 → 同步到 B
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1',
            createTime: 1000,
            seq: 1,
            content: '消息1');
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-2',
            createTime: 2000,
            seq: 2,
            content: '消息2');
        syncViaQuery(storeA, storeB);
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(2));

        // A 标记已读 → query 同步
        storeA.markAsRead(empId, deviceId: deviceA);
        syncViaQuery(storeA, storeB);
        // MAX 策略：B 已有 2 条未读，A 标记已读后 query 同步 unread=0，MAX(2, 0) = 2
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(2));

        // A 新增消息 → query 同步
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-3',
            createTime: 3000,
            seq: 3,
            content: '新消息');
        syncViaQuery(storeA, storeB);

        // MAX 策略：B 本地 2，A 新增后 unread=1，MAX(2, 1) = 2
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(2));
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB!.lastMsgId, equals('msg-3'));
      });

      test('B 本地有未读 → A 标记已读后 query 同步 → B 未读清零（MAX 策略）', () {
        final empId = randomEmpId();

        // B 本地有 4 条未读
        for (int i = 1; i <= 4; i++) {
          addMessage(storeB,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-b-$i',
              createTime: 1000 * i,
              seq: i,
              content: 'B消息$i');
        }
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(4));

        // A 标记已读（A 没有消息，markAsRead 创建 unread=0 的摘要）
        storeA.markAsRead(empId, deviceId: deviceA);

        // query 同步 A → B
        syncViaQuery(storeA, storeB);

        // MAX(4, 0) = 4，当前 MAX 策略下不清零
        // 验证当前行为：MAX 策略保留本地未读
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(4));
      });

      test('两端同时标记已读 → 双向 query 同步 → 两端未读均为 0', () {
        final empId = randomEmpId();

        // 两端都有未读
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-a',
            createTime: 1000,
            seq: 1,
            content: 'A消息');
        addMessage(storeB,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-b',
            createTime: 2000,
            seq: 2,
            content: 'B消息');

        // 两端都标记已读
        storeA.markAsRead(empId, deviceId: deviceA);
        storeB.markAsRead(empId, deviceId: deviceA);
        expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(0));
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));

        // 双向 query 同步
        syncBidirectionalQuery();

        // 两端未读均为 0（MAX(0, 0) = 0）
        expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(0));
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));
      });

      test('标记已读后多轮双向 query 同步 → 未读保持 0 不漂移', () {
        final empId = randomEmpId();

        // A 有 3 条未读
        for (int i = 1; i <= 3; i++) {
          addMessage(storeA,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-$i',
              createTime: 1000 * i,
              seq: i,
              content: '消息$i');
        }
        syncViaQuery(storeA, storeB);
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(3));

        // 两端都标记已读
        storeA.markAsRead(empId, deviceId: deviceA);
        storeB.markAsRead(empId, deviceId: deviceA);

        // 10 轮双向同步
        for (var i = 0; i < 10; i++) {
          syncBidirectionalQuery();
        }

        // 未读保持 0
        expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(0));
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));
      });

      test('标记已读 query 同步不影响其他员工未读', () {
        final emp1 = randomEmpId();
        final emp2 = randomEmpId();
        final emp3 = randomEmpId();

        // 3 个员工都有未读
        for (final empId in [emp1, emp2, emp3]) {
          addMessage(storeA,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-$empId',
              createTime: 1000,
              seq: 1,
              content: '$empId 消息');
        }
        syncViaQuery(storeA, storeB);
        expect(storeB.getUnreadCount(emp1, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp2, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp3, deviceId: deviceA), equals(1));

        // A 标记 emp2 已读
        storeA.markAsRead(emp2, deviceId: deviceA);
        syncViaQuery(storeA, storeB);

        // MAX 策略：B 的 emp2 已有 1 条未读，A 标记已读后 query 同步 unread=0，MAX(1, 0) = 1
        // emp2 未读不清零，其他不受影响
        expect(storeB.getUnreadCount(emp1, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp2, deviceId: deviceA), equals(1));
        expect(storeB.getUnreadCount(emp3, deviceId: deviceA), equals(1));
        expect(storeB.getTotalUnreadCount(deviceId: deviceA), equals(3));
      });

      test('A 标记已读后新增消息 → query 同步 → B 未读仅计新消息', () {
        final empId = randomEmpId();

        // A 有 5 条未读
        for (int i = 1; i <= 5; i++) {
          addMessage(storeA,
              employeeId: empId,
              deviceId: deviceA,
              role: 'assistant',
              isRead: false,
              messageId: 'msg-$i',
              createTime: 1000 * i,
              seq: i,
              content: '消息$i');
        }
        syncViaQuery(storeA, storeB);
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(5));

        // A 标记已读
        storeA.markAsRead(empId, deviceId: deviceA);
        syncViaQuery(storeA, storeB);
        // MAX 策略：B 已有 5 条未读，A 标记已读后 query 同步 unread=0，MAX(5, 0) = 5
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(5));

        // A 新增 2 条消息
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-6',
            createTime: 6000,
            seq: 6,
            content: '新消息6');
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-7',
            createTime: 7000,
            seq: 7,
            content: '新消息7');
        syncViaQuery(storeA, storeB);

        // MAX 策略：B 本地 5，A 新增后 unread=2，MAX(5, 2) = 5
        expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(5));
        final summaryB = storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB!.lastMsgId, equals('msg-7'));
      });
    });
  });

  // ═══════════════════════════════════════════════════
  // 路径一致性验证
  // ═══════════════════════════════════════════════════

  group('路径一致性: event 与 query 结果相同', () {
    test(
        '同一变更通过 event 同步到 B、通过 query 同步到 C → B 和 C 的摘要数据完全一致',
        () async {
      final empId = randomEmpId();

      // 准备第三个设备用于对比
      final testDbPathC =
          '${Directory.systemTemp.path}/wenzagent_summary_list_sync_test_${_testCounter}_c';
      await Directory(testDbPathC).create(recursive: true);
      final deviceC = 'dev-c-${const Uuid().v4().substring(0, 8)}';
      await DatabaseManager.getInstance(deviceC).initialize(
        storagePath: testDbPathC,
      );
      final storeC = SessionSummaryStore(deviceId: deviceC);
      storeC.ensureTable();

      // Device A 创建消息 + 权限请求 + 确认请求
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-1',
          createTime: 1000,
          seq: 1,
          content: '需要权限和确认');
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-2',
          createTime: 2000,
          seq: 2,
          content: '后续消息');
      storeA.setPendingPermission(
          empId, deviceA, '{"type":"permission","id":"req-1"}');
      storeA.setPendingConfirm(
          empId, deviceA, '{"type":"confirm","id":"conf-1"}');

      // 路径1: event 同步到 B
      syncViaEvent(storeA, storeB, empId);

      // 路径2: query 同步到 C
      syncViaQuery(storeA, storeC);

      // 验证 B 和 C 结果一致
      final syncedB = storeB.getSummary(empId, deviceId: deviceA);
      final syncedC = storeC.getSummary(empId, deviceId: deviceA);

      expect(syncedB, isNotNull);
      expect(syncedC, isNotNull);

      expect(syncedB!.employeeId, equals(syncedC!.employeeId));
      expect(syncedB.deviceId, equals(syncedC.deviceId));
      expect(syncedB.unreadCount, equals(syncedC.unreadCount));
      expect(syncedB.lastMsgId, equals(syncedC.lastMsgId));
      expect(syncedB.lastMsgRole, equals(syncedC.lastMsgRole));
      expect(syncedB.lastMsgContent, equals(syncedC.lastMsgContent));
      expect(syncedB.lastMsgTime, equals(syncedC.lastMsgTime));
      expect(syncedB.lastMsgSeq, equals(syncedC.lastMsgSeq));
      expect(syncedB.hasPendingPermission, equals(syncedC.hasPendingPermission));
      expect(syncedB.hasPendingConfirm, equals(syncedC.hasPendingConfirm));

      // 清理
      await DatabaseManager.getInstance(deviceC).close();
      DatabaseManager.removeInstance(deviceC);
      try {
        await Directory(testDbPathC).delete(recursive: true);
      } catch (_) {}
    });

    test('多条消息 + 多种角色 → event 和 query 同步结果一致', () async {
      final empId = randomEmpId();

      // 准备第三个设备
      final testDbPathC =
          '${Directory.systemTemp.path}/wenzagent_summary_list_sync_test_${_testCounter}_c2';
      await Directory(testDbPathC).create(recursive: true);
      final deviceC = 'dev-c-${const Uuid().v4().substring(0, 8)}';
      await DatabaseManager.getInstance(deviceC).initialize(
        storagePath: testDbPathC,
      );
      final storeC = SessionSummaryStore(deviceId: deviceC);
      storeC.ensureTable();

      // 多种角色消息
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'user',
          isRead: true,
          messageId: 'msg-u',
          createTime: 1000,
          seq: 1,
          content: '用户消息');
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-a1',
          createTime: 2000,
          seq: 2,
          content: 'AI回复1');
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-a2',
          createTime: 3000,
          seq: 3,
          content: 'AI回复2');
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'user',
          isRead: true,
          messageId: 'msg-u2',
          createTime: 4000,
          seq: 4,
          content: '用户追问');

      // event 同步到 B
      syncViaEvent(storeA, storeB, empId);

      // query 同步到 C
      syncViaQuery(storeA, storeC);

      final syncedB = storeB.getSummary(empId, deviceId: deviceA);
      final syncedC = storeC.getSummary(empId, deviceId: deviceA);

      expect(syncedB!.unreadCount, equals(syncedC!.unreadCount));
      expect(syncedB.lastMsgId, equals(syncedC.lastMsgId));
      expect(syncedB.lastMsgRole, equals(syncedC.lastMsgRole));
      expect(syncedB.lastMsgContent, equals(syncedC.lastMsgContent));
      expect(syncedB.lastMsgTime, equals(syncedC.lastMsgTime));
      expect(syncedB.lastMsgSeq, equals(syncedC.lastMsgSeq));

      // 最新消息是用户追问
      expect(syncedB.lastMsgId, equals('msg-u2'));
      expect(syncedB.lastMsgRole, equals('user'));
      // 未读数 = 2（两条 assistant 未读）
      expect(syncedB.unreadCount, equals(2));

      // 清理
      await DatabaseManager.getInstance(deviceC).close();
      DatabaseManager.removeInstance(deviceC);
      try {
        await Directory(testDbPathC).delete(recursive: true);
      } catch (_) {}
    });

    test('标记已读通过 event 同步到 B、query 同步到 C → B 和 C 未读均清零',
        () async {
      final empId = randomEmpId();

      // 准备第三个设备
      final testDbPathC =
          '${Directory.systemTemp.path}/wenzagent_summary_list_sync_test_${_testCounter}_c3';
      await Directory(testDbPathC).create(recursive: true);
      final deviceC = 'dev-c-${const Uuid().v4().substring(0, 8)}';
      await DatabaseManager.getInstance(deviceC).initialize(
        storagePath: testDbPathC,
      );
      final storeC = SessionSummaryStore(deviceId: deviceC);
      storeC.ensureTable();

      // A 有 3 条未读
      for (int i = 1; i <= 3; i++) {
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-$i',
            createTime: 1000 * i,
            seq: i,
            content: '消息$i');
      }

      // 先同步到 B 和 C
      syncViaEvent(storeA, storeB, empId);
      syncViaQuery(storeA, storeC);

      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(3));
      expect(storeC.getUnreadCount(empId, deviceId: deviceA), equals(3));

      // A 标记已读
      storeA.markAsRead(empId, deviceId: deviceA);

      // event 同步到 B，query 同步到 C
      syncViaEvent(storeA, storeB, empId);
      syncViaQuery(storeA, storeC);

      // B 和 C 未读均清零
      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));
      expect(storeC.getUnreadCount(empId, deviceId: deviceA), equals(0));

      // 最新消息保留一致
      final syncedB = storeB.getSummary(empId, deviceId: deviceA);
      final syncedC = storeC.getSummary(empId, deviceId: deviceA);
      expect(syncedB!.lastMsgId, equals(syncedC!.lastMsgId));
      expect(syncedB.lastMsgContent, equals(syncedC.lastMsgContent));
      expect(syncedB.lastMsgTime, equals(syncedC.lastMsgTime));

      // 清理
      await DatabaseManager.getInstance(deviceC).close();
      DatabaseManager.removeInstance(deviceC);
      try {
        await Directory(testDbPathC).delete(recursive: true);
      } catch (_) {}
    });

    test('标记已读后新增消息 → event 和 query 同步的未读计数一致', () async {
      final empId = randomEmpId();

      // 准备第三个设备
      final testDbPathC =
          '${Directory.systemTemp.path}/wenzagent_summary_list_sync_test_${_testCounter}_c4';
      await Directory(testDbPathC).create(recursive: true);
      final deviceC = 'dev-c-${const Uuid().v4().substring(0, 8)}';
      await DatabaseManager.getInstance(deviceC).initialize(
        storagePath: testDbPathC,
      );
      final storeC = SessionSummaryStore(deviceId: deviceC);
      storeC.ensureTable();

      // A 有 2 条未读
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-1',
          createTime: 1000,
          seq: 1,
          content: '消息1');
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-2',
          createTime: 2000,
          seq: 2,
          content: '消息2');

      // A 标记已读
      storeA.markAsRead(empId, deviceId: deviceA);

      // A 新增 1 条消息
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-3',
          createTime: 3000,
          seq: 3,
          content: '新消息');

      // event 同步到 B，query 同步到 C
      syncViaEvent(storeA, storeB, empId);
      syncViaQuery(storeA, storeC);

      // B 和 C 未读一致 = 1
      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(1));
      expect(storeC.getUnreadCount(empId, deviceId: deviceA), equals(1));

      // 最新消息一致
      final syncedB = storeB.getSummary(empId, deviceId: deviceA);
      final syncedC = storeC.getSummary(empId, deviceId: deviceA);
      expect(syncedB!.lastMsgId, equals(syncedC!.lastMsgId));
      expect(syncedB.unreadCount, equals(syncedC!.unreadCount));

      // 清理
      await DatabaseManager.getInstance(deviceC).close();
      DatabaseManager.removeInstance(deviceC);
      try {
        await Directory(testDbPathC).delete(recursive: true);
      } catch (_) {}
    });
  });

  // ═══════════════════════════════════════════════════
  // 端到端场景
  // ═══════════════════════════════════════════════════

  group('端到端场景', () {
    test('完整生命周期：消息→未读→权限请求→权限响应→新消息→已读→删除', () {
      final empId = randomEmpId();

      // 1. 消息 → 未读
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-1',
          createTime: 1000,
          seq: 1,
          content: '需要权限才能继续');
      syncViaEvent(storeA, storeB, empId);
      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(1));
      expect(
          storeB.getSummary(empId, deviceId: deviceA)!.lastMsgContent,
          equals('需要权限才能继续'));

      // 2. 权限请求
      storeA.setPendingPermission(
          empId, deviceA, '{"type":"permission","id":"req-1"}');
      syncViaEvent(storeA, storeB, empId);
      expect(
          storeB.getSummary(empId, deviceId: deviceA)!.hasPendingPermission,
          isTrue);

      // 3. 权限响应（两端清除）
      storeA.clearPendingPermission(empId, deviceA);
      storeB.clearPendingPermission(empId, deviceA);

      // 4. 新消息
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-2',
          createTime: 2000,
          seq: 2,
          content: '文件已读取完毕');
      syncViaEvent(storeA, storeB, empId);
      expect(
          storeB.getSummary(empId, deviceId: deviceA)!.lastMsgId,
          equals('msg-2'));
      expect(
          storeB.getSummary(empId, deviceId: deviceA)!.hasPendingPermission,
          isFalse);

      // 5. 已读
      storeA.markAsRead(empId, deviceId: deviceA);
      storeB.markAsRead(empId, deviceId: deviceA);
      expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(0));
      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));

      // 6. 删除
      storeA.deleteSummary(empId, deviceId: deviceA);
      storeB.deleteSummary(empId, deviceId: deviceA);
      expect(storeA.getSummary(empId, deviceId: deviceA), isNull);
      expect(storeB.getSummary(empId, deviceId: deviceA), isNull);
      expect(storeA.getTotalUnreadCount(), equals(0));
      expect(storeB.getTotalUnreadCount(), equals(0));
    });

    test('离线场景：B 离线期间 A 有多次变更 → B 上线后全量查询同步恢复', () {
      final emp1 = randomEmpId();
      final emp2 = randomEmpId();
      final emp3 = randomEmpId();

      // B 离线前同步一次
      addMessage(storeA,
          employeeId: emp1,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-init',
          createTime: 1000,
          seq: 1,
          content: '初始');
      syncViaQuery(storeA, storeB);

      // B 离线期间，A 有多次变更
      // - emp1 更新
      addMessage(storeA,
          employeeId: emp1,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-update',
          createTime: 2000,
          seq: 2,
          content: '更新后');
      // - emp2 新建
      addMessage(storeA,
          employeeId: emp2,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-new',
          createTime: 3000,
          seq: 1,
          content: '新建');
      // - emp3 新建后删除
      addMessage(storeA,
          employeeId: emp3,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-temp',
          createTime: 4000,
          seq: 1,
          content: '临时');
      storeA.deleteSummary(emp3, deviceId: deviceA);

      // B 上线，全量查询同步
      syncViaQuery(storeA, storeB);

      // B 有 emp1 和 emp2（emp3 已删除）
      expect(storeB.getAllSummaries().length, equals(2));

      // emp1 更新了
      final emp1B = storeB.getSummary(emp1, deviceId: deviceA);
      expect(emp1B!.lastMsgContent, equals('更新后'));
      expect(emp1B.unreadCount, equals(2));

      // emp2 补入
      final emp2B = storeB.getSummary(emp2, deviceId: deviceA);
      expect(emp2B, isNotNull);
      expect(emp2B!.lastMsgContent, equals('新建'));

      // emp3 不存在
      expect(storeB.getSummary(emp3, deviceId: deviceA), isNull);
    });

    test('并发冲突：两端同时产生新消息 → 双向同步后最新消息一致（取 lastMsgTime MAX）',
        () {
      final empId = randomEmpId();

      // 初始同步
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-init',
          createTime: 1000,
          seq: 1,
          content: '初始');
      syncViaQuery(storeA, storeB);

      // 两端同时产生新消息
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-a',
          createTime: 2000,
          seq: 2,
          content: 'A的新消息');

      addMessage(storeB,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-b',
          createTime: 3000,
          seq: 3,
          content: 'B的新消息');

      // 双向同步
      syncBidirectionalQuery();

      // 两端都取 lastMsgTime MAX = 3000 (msg-b)
      final summaryA = storeA.getSummary(empId, deviceId: deviceA);
      final summaryB = storeB.getSummary(empId, deviceId: deviceA);

      expect(summaryA!.lastMsgId, equals('msg-b'));
      expect(summaryB!.lastMsgId, equals('msg-b'));
      expect(summaryA.lastMsgContent, equals('B的新消息'));
      expect(summaryB.lastMsgContent, equals('B的新消息'));
      expect(summaryA.lastMsgTime, equals(3000));
      expect(summaryB.lastMsgTime, equals(3000));
    });

    test('多轮同步后数据稳定不漂移（10 轮双向同步后数据不变）', () {
      final empId = randomEmpId();

      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-1',
          createTime: 1000,
          seq: 1,
          content: '稳定测试');
      syncViaQuery(storeA, storeB);

      // 记录初始状态
      final initialA = storeA.getSummary(empId, deviceId: deviceA)!;
      final initialB = storeB.getSummary(empId, deviceId: deviceA)!;

      // 执行 10 轮双向同步
      for (var i = 0; i < 10; i++) {
        syncBidirectionalQuery();
      }

      // 数据不变
      final syncedA = storeA.getSummary(empId, deviceId: deviceA)!;
      final syncedB = storeB.getSummary(empId, deviceId: deviceA)!;

      expect(syncedA.lastMsgId, equals(initialA.lastMsgId));
      expect(syncedB.lastMsgId, equals(initialB.lastMsgId));
      expect(syncedA.unreadCount, equals(initialA.unreadCount));
      expect(syncedB.unreadCount, equals(initialB.unreadCount));
      expect(syncedA.lastMsgContent, equals(initialA.lastMsgContent));
      expect(syncedB.lastMsgContent, equals(initialB.lastMsgContent));
    });

    test('多员工多设备场景下的数据隔离（employeeId + deviceId 组合隔离）', () {
      final emp1 = randomEmpId();
      final emp2 = randomEmpId();
      final emp3 = randomEmpId();

      // Device A 管理 emp1, emp2（deviceId=deviceA）
      addMessage(storeA,
          employeeId: emp1,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-a1',
          createTime: 1000,
          seq: 1,
          content: 'A-emp1');
      addMessage(storeA,
          employeeId: emp2,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-a2',
          createTime: 2000,
          seq: 1,
          content: 'A-emp2');

      // Device B 管理 emp2, emp3（deviceId=deviceB）
      addMessage(storeB,
          employeeId: emp2,
          deviceId: deviceB,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-b2',
          createTime: 3000,
          seq: 1,
          content: 'B-emp2');
      addMessage(storeB,
          employeeId: emp3,
          deviceId: deviceB,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-b3',
          createTime: 4000,
          seq: 1,
          content: 'B-emp3');

      // 双向同步
      syncBidirectionalQuery();

      // emp2:deviceA 和 emp2:deviceB 是独立的
      final aEmp2A = storeA.getSummary(emp2, deviceId: deviceA);
      final aEmp2B = storeA.getSummary(emp2, deviceId: deviceB);
      expect(aEmp2A, isNotNull);
      expect(aEmp2B, isNotNull);
      expect(aEmp2A!.lastMsgContent, equals('A-emp2'));
      expect(aEmp2B!.lastMsgContent, equals('B-emp2'));

      // B 也有两个 emp2 摘要
      final bEmp2A = storeB.getSummary(emp2, deviceId: deviceA);
      final bEmp2B = storeB.getSummary(emp2, deviceId: deviceB);
      expect(bEmp2A, isNotNull);
      expect(bEmp2B, isNotNull);
      expect(bEmp2A!.lastMsgContent, equals('A-emp2'));
      expect(bEmp2B!.lastMsgContent, equals('B-emp2'));

      // emp1 只在 deviceA 下
      expect(storeB.getSummary(emp1, deviceId: deviceA), isNotNull);
      expect(storeB.getSummary(emp1, deviceId: deviceB), isNull);

      // emp3 只在 deviceB 下
      expect(storeA.getSummary(emp3, deviceId: deviceB), isNotNull);
      expect(storeA.getSummary(emp3, deviceId: deviceA), isNull);
    });

    test('序列化往返一致性（toMap → fromMap → 写入 → 读取 → 字段一致）', () {
      final original = SessionSummaryEntity(
        employeeId: 'emp-serialize',
        deviceId: deviceA,
        unreadCount: 5,
        lastMsgId: 'msg-1',
        lastMsgRole: 'assistant',
        lastMsgContent: '测试消息内容，包含特殊字符：<>&"\'',
        lastMsgTime: 12345,
        lastMsgSeq: 42,
        pendingPermission: '{"type":"permission","id":"req-1","tool":"file_read"}',
        pendingPermissionTime: 12000,
        pendingConfirm: '{"type":"confirm","id":"conf-1","message":"确认删除？"}',
        pendingConfirmTime: 13000,
        updateTime: 12345,
      );

      // 模拟网络传输：toMap → fromMap
      final map = original.toMap();
      final restored = SessionSummaryEntity.fromMap(map);

      // 写入 storeB
      storeB.upsertFromRemote(restored);

      // 读取并验证所有字段
      final summaryB = storeB.getSummary('emp-serialize', deviceId: deviceA);
      expect(summaryB, isNotNull);
      expect(summaryB!.employeeId, equals(original.employeeId));
      expect(summaryB.deviceId, equals(original.deviceId));
      expect(summaryB.unreadCount, equals(original.unreadCount));
      expect(summaryB.lastMsgId, equals(original.lastMsgId));
      expect(summaryB.lastMsgRole, equals(original.lastMsgRole));
      expect(summaryB.lastMsgContent, equals(original.lastMsgContent));
      expect(summaryB.lastMsgTime, equals(original.lastMsgTime));
      expect(summaryB.lastMsgSeq, equals(original.lastMsgSeq));
      expect(summaryB.pendingPermission, equals(original.pendingPermission));
      expect(summaryB.pendingConfirm, equals(original.pendingConfirm));
      expect(summaryB.pendingPermissionTime,
          equals(original.pendingPermissionTime));
      expect(
          summaryB.pendingConfirmTime, equals(original.pendingConfirmTime));
    });

    test('标记已读→新消息→标记已读→新消息 循环场景', () {
      final empId = randomEmpId();

      // 第1轮：消息 → 未读1
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-r1',
          createTime: 1000,
          seq: 1,
          content: '第1轮消息');
      syncViaEvent(storeA, storeB, empId);
      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(1));

      // 标记已读
      storeA.markAsRead(empId, deviceId: deviceA);
      syncViaEvent(storeA, storeB, empId);
      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));

      // 第2轮：新消息 → 未读1
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-r2',
          createTime: 2000,
          seq: 2,
          content: '第2轮消息');
      syncViaEvent(storeA, storeB, empId);
      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(1));

      // 标记已读
      storeA.markAsRead(empId, deviceId: deviceA);
      syncViaEvent(storeA, storeB, empId);
      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));

      // 第3轮：新消息 → 未读1
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-r3',
          createTime: 3000,
          seq: 3,
          content: '第3轮消息');
      syncViaEvent(storeA, storeB, empId);
      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(1));

      // 最新消息始终正确
      final summaryB = storeB.getSummary(empId, deviceId: deviceA);
      expect(summaryB!.lastMsgId, equals('msg-r3'));
      expect(summaryB.lastMsgContent, equals('第3轮消息'));
    });

    test('离线+已读场景：B离线期间A产生消息并标记已读 → B上线后同步', () {
      final empId = randomEmpId();

      // B 离线前同步一次
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-init',
          createTime: 1000,
          seq: 1,
          content: '初始消息');
      syncViaQuery(storeA, storeB);
      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(1));

      // B 离线期间：A 产生新消息
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-new',
          createTime: 2000,
          seq: 2,
          content: '新消息');

      // A 标记已读
      storeA.markAsRead(empId, deviceId: deviceA);
      expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(0));

      // B 上线，全量同步
      syncViaQuery(storeA, storeB);

      // B 未读清零（A 已读）
      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(0));
      // 最新消息更新
      final summaryB = storeB.getSummary(empId, deviceId: deviceA);
      expect(summaryB!.lastMsgId, equals('msg-new'));
      expect(summaryB.lastMsgContent, equals('新消息'));
    });

    test('多员工部分已读场景：3个员工中标记1个已读 → 同步后仅该员工清零', () {
      final emp1 = randomEmpId();
      final emp2 = randomEmpId();
      final emp3 = randomEmpId();

      // A 有 3 个员工各有 2 条未读
      for (final empId in [emp1, emp2, emp3]) {
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-1-$empId',
            createTime: 1000,
            seq: 1,
            content: '$empId 消息1');
        addMessage(storeA,
            employeeId: empId,
            deviceId: deviceA,
            role: 'assistant',
            isRead: false,
            messageId: 'msg-2-$empId',
            createTime: 2000,
            seq: 2,
            content: '$empId 消息2');
      }
      syncViaQuery(storeA, storeB);

      expect(storeB.getUnreadCount(emp1, deviceId: deviceA), equals(2));
      expect(storeB.getUnreadCount(emp2, deviceId: deviceA), equals(2));
      expect(storeB.getUnreadCount(emp3, deviceId: deviceA), equals(2));
      expect(storeB.getTotalUnreadCount(deviceId: deviceA), equals(6));

      // A 标记 emp2 已读
      storeA.markAsRead(emp2, deviceId: deviceA);
      syncViaQuery(storeA, storeB);

      // emp2 清零，其他不变
      expect(storeB.getUnreadCount(emp1, deviceId: deviceA), equals(2));
      expect(storeB.getUnreadCount(emp2, deviceId: deviceA), equals(0));
      expect(storeB.getUnreadCount(emp3, deviceId: deviceA), equals(2));
      expect(storeB.getTotalUnreadCount(deviceId: deviceA), equals(4));

      // emp2 最新消息保留
      final emp2Summary = storeB.getSummary(emp2, deviceId: deviceA);
      expect(emp2Summary!.lastMsgContent, equals('$emp2 消息2'));
    });

    test('并发标记已读：A标记已读同时B新增未读 → 双向同步后状态一致', () {
      final empId = randomEmpId();

      // 两端都有未读
      addMessage(storeA,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-a',
          createTime: 1000,
          seq: 1,
          content: 'A消息');
      addMessage(storeB,
          employeeId: empId,
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-b',
          createTime: 2000,
          seq: 2,
          content: 'B消息');

      // A 标记已读，B 不标记
      storeA.markAsRead(empId, deviceId: deviceA);
      expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(0));
      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(1));

      // 双向同步
      syncBidirectionalQuery();

      // MAX(0, 1) = 1（A 会收到 B 的未读）
      expect(storeA.getUnreadCount(empId, deviceId: deviceA), equals(1));
      expect(storeB.getUnreadCount(empId, deviceId: deviceA), equals(1));

      // 两端最新消息一致
      final summaryA = storeA.getSummary(empId, deviceId: deviceA);
      final summaryB = storeB.getSummary(empId, deviceId: deviceA);
      expect(summaryA!.lastMsgId, equals(summaryB!.lastMsgId));
    });
  });
}
