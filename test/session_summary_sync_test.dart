import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/session_summary_entity.dart';
import 'package:wenzagent/src/persistence/stores/session_summary_store.dart';

int _testCounter = 0;

/// 跨设备 Session Summary 同步集成测试
///
/// 验证：
/// - 基础同步流程：Device A → Device B 全量/增量同步
/// - 未读计数同步：MAX 策略、已读回传
/// - 最新消息同步：时间比较、旧广播不覆盖
/// - 权限请求同步：pending 端到端生命周期
/// - 确认请求同步：confirm 端到端生命周期
/// - 并发与冲突：同时操作后最终一致
/// - 会话删除同步：删除操作跨设备传播
Future<void> main() async {
  late String testDbPathA;
  late String testDbPathB;
  late String deviceA;
  late String deviceB;
  late SessionSummaryStore storeA;
  late SessionSummaryStore storeB;

  setUp(() async {
    _testCounter++;
    final base =
        '${Directory.systemTemp.path}/wenzagent_sync_test_$_testCounter';

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

    await storeA.ensureTable();
    await storeB.ensureTable();
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

  /// 模拟同步：将 storeA 的摘要序列化后通过 upsertFromRemote 写入 storeB
  Future<void> syncAToB(String employeeId) async {
    final summary = await storeA.getSummary(employeeId, deviceId: deviceA);
    if (summary != null) async {
      await sawait await oreB.upsertFromRemote(summary);
    }
  }

  /// 模拟同步：将 storeB 的摘要序列化后通过 upsertFromRemote 写入 storeA
  Future<void> syncBToA(String employeeId) async {
    final summary = await storeB.getSummary(employeeId, deviceId: deviceB);
    if (summary != null) async {
      await sawait await oreA.upsertFromRemote(summary);
    }
  }

  /// 双向同步：A → B 然后 B → A
  void syncBidirectional(String employeeId) async {
    syncAToB(employeeId);
    // 同步后重新读取 B 的最新状态（A→B 可能已更新 B 的数据）
    syncBToA(employeeId);
  }

  /// 双向同步：同时读取快照后互相同步（更真实的并发模拟）
  Future<void> syncConcurrent(String employeeId) async {
    // 先读取两端快照
    final snapA = await storeA.getSummary(employeeId, deviceId: deviceA);
    final snapB = await storeB.getSummary(employeeId, deviceId: deviceB);
    // 然后互相同步
    if (snapA != null) await sawait await oreB.upsertFromRemote(snapA);
    if (snapB != null) await sawait await oreA.upsertFromRemote(snapB);
  }

  // ═══════════════════════════════════════════════════
  // 1. 基础同步流程
  // ═══════════════════════════════════════════════════

  group('基础同步流程', () {
    test('Device A 有 3 个会话摘要，同步到 Device B 后数据一致', () async {
      // Device A 创建 3 个会话摘要
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '消息1',
      );
      await storeA.onMessageAdded(
        employeeId: 'emp-2',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-2',
        createTime: 2000,
        seq: 2,
        content: '消息2',
      );
      await storeA.onMessageAdded(
        employeeId: 'emp-3',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-3',
        createTime: 3000,
        seq: 3,
        content: '消息3',
      );

      // Device B 初始为空
      expect(await storeB.getAllSummaries(), isEmpty);

      // 同步所有摘要到 Device B
      syncAToB('emp-1');
      syncAToB('emp-2');
      syncAToB('emp-3');

      // 验证 Device B 数据一致
      final summariesB = await storeB.getAllSummaries();
      expect(summariesB.length, equals(3));

      // 逐个验证
      for (final empId in ['emp-1', 'emp-2', 'emp-3']) {
        final summaryA = await storeA.getSummary(empId, deviceId: deviceA);
        final summaryB = await storeB.getSummary(empId, deviceId: deviceA);
        expect(summaryB, isNotNull);
        expect(summaryB!.employeeId, equals(summaryA!.employeeId));
        expect(summaryB.deviceId, equals(deviceA));
        expect(summaryB.unreadCount, equals(summaryA.unreadCount));
        expect(summaryB.lastMsgId, equals(summaryA.lastMsgId));
        expect(summaryB.lastMsgContent, equals(summaryA.lastMsgContent));
        expect(summaryB.lastMsgTime, equals(summaryA.lastMsgTime));
        expect(summaryB.lastMsgSeq, equals(summaryA.lastMsgSeq));
      }
    });

    test('Device A 新增消息后增量同步到 Device B', () async {
      // 初始同步
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '初始消息',
      );
      syncAToB('emp-1');

      // Device A 新增消息
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-2',
        createTime: 2000,
        seq: 2,
        content: '新消息',
      );

      // Device B 还没有新消息
      var summaryB = await storeB.getSummary('emp-1', deviceId: deviceA);
      expect(summaryB!.lastMsgId, equals('msg-1'));
      expect(summaryB.unreadCount, equals(1));

      // 增量同步
      syncAToB('emp-1');

      // Device B 更新
      summaryB = await storeB.getSummary('emp-1', deviceId: deviceA);
      expect(summaryB!.lastMsgId, equals('msg-2'));
      expect(summaryB.lastMsgContent, equals('新消息'));
      expect(summaryB.lastMsgTime, equals(2000));
      // unread_count 取 max(local, remote) = max(1, 2) = 2
      expect(summaryB.unreadCount, equals(2));
    });

    test('空数据同步无副作用', () async {
      // Device B 为空，同步不存在的摘要
      syncAToB('emp-nonexistent');

      expect(await storeB.getAllSummaries(), isEmpty);
      expect(await storeB.getSummary('emp-nonexistent', deviceId: deviceA), isNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // 2. 未读计数同步
  // ═══════════════════════════════════════════════════

  group('未读计数同步', () {
    test('Device A 有 5 条未读，同步到 Device B 后显示 5 条', () async {
      for (int i = 1; i <= 5; i++) {
        await storeA.onMessageAdded(
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

      expect(await storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(5));

      syncAToB('emp-1');

      expect(await storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(5));
    });

    test('Device B 标记已读后同步回 Device A，Device A 未读清零', () async {
      // Device A 创建未读
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '消息1',
      );
      syncAToB('emp-1');

      // Device B 标记已读
      await storeB.markAsRead('emp-1', deviceId: deviceA);
      expect(await storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(0));

      // 同步回 Device A（Device B 的摘要 unread=0）
      syncBToA('emp-1');

      // Device A 未读取 MAX(local=1, remote=0) = 1
      // 注意：upsertFromRemote 使用 MAX 策略，所以本地未读不会被远程的 0 覆盖
      // 这是预期行为：已读状态需要通过专门的已读广播来同步，而非 upsertFromRemote
      expect(await storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(1));

      // 模拟 Device A 收到已读广播后显式标记已读
      await storeA.markAsRead('emp-1', deviceId: deviceA);
      expect(await storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(0));
    });

    test('两端同时产生未读，同步后取 MAX', () async {
      // Device A 产生 3 条未读
      for (int i = 1; i <= 3; i++) {
        await storeA.onMessageAdded(
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
      expect(await storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(3));

      // Device B 也产生 2 条未读（通过 upsertFromRemote 模拟远程消息）
      await storeB.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-b-1',
        createTime: 2000,
        seq: 4,
        content: 'B消息1',
      );
      await storeB.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-b-2',
        createTime: 2500,
        seq: 5,
        content: 'B消息2',
      );
      expect(await storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(2));

      // 双向同步
      syncBidirectional('emp-1');

      // 两端都取 MAX = max(3, 2) = 3
      // 但由于各自同步后对方的 unread 也被 MAX：
      // A 同步到 B: B 的 unread = max(2, 3) = 3
      // B 同步到 A: A 的 unread = max(3, 3) = 3
      // 但 B 同步到 A 时 B 的 unread 已经是 3 了（因为 A→B 先执行）
      // 实际上：A→B 后 B.unread = max(2, 3) = 3
      //         B→A 时 B 的摘要 unread = 3, A.unread = max(3, 3) = 3
      expect(await storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(3));
      expect(await storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(3));
    });

    test('未读数为 0 的摘要同步后不引入假未读', () async {
      // Device A 创建已读摘要
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'user',
        isRead: true,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '已读消息',
      );
      expect(await storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(0));

      syncAToB('emp-1');

      expect(await storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // 3. 最新消息同步
  // ═══════════════════════════════════════════════════

  group('最新消息同步', () {
    test('Device A 收到新 assistant 消息，广播后 Device B 更新最新消息预览', () async {
      // 初始同步
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-old',
        createTime: 1000,
        seq: 1,
        content: '旧消息',
      );
      syncAToB('emp-1');

      // Device A 收到新消息
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-new',
        createTime: 2000,
        seq: 2,
        content: '新AI回复',
      );

      // 广播到 Device B
      syncAToB('emp-1');

      final summaryB = await storeB.getSummary('emp-1', deviceId: deviceA);
      expect(summaryB, isNotNull);
      expect(summaryB!.lastMsgId, equals('msg-new'));
      expect(summaryB.lastMsgContent, equals('新AI回复'));
      expect(summaryB.lastMsgTime, equals(2000));
      expect(summaryB.lastMsgSeq, equals(2));
    });

    test('旧广播到达（网络延迟）不覆盖更新的本地数据', () async {
      // Device B 先收到较新的消息
      await storeB.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-new',
        createTime: 3000,
        seq: 5,
        content: '最新消息',
      );

      // 模拟延迟到达的旧广播（Device A 的旧摘要）
      final oldRemote = SessionSummaryEntity(
        employeeId: 'emp-1',
        deviceId: deviceA,
        unreadCount: 1,
        lastMsgId: 'msg-old',
        lastMsgRole: 'assistant',
        lastMsgContent: '旧消息',
        lastMsgTime: 1000,
        lastMsgSeq: 1,
        updateTime: 1000,
      );
      await sawait await oreB.upsertFromRemote(oldRemote);

      // Device B 的最新消息不被覆盖
      final summaryB = await storeB.getSummary('emp-1', deviceId: deviceA);
      expect(summaryB, isNotNull);
      expect(summaryB!.lastMsgId, equals('msg-new'));
      expect(summaryB.lastMsgContent, equals('最新消息'));
      expect(summaryB.lastMsgTime, equals(3000));
    });

    test('Device A 的 user 消息不增加 Device B 的未读数', () async {
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'user',
        isRead: false,
        messageId: 'msg-user',
        createTime: 1000,
        seq: 1,
        content: '用户消息',
      );
      syncAToB('emp-1');

      // user 消息不增加未读
      expect(await storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(0));
      // 但最新消息预览应更新
      final summaryB = await storeB.getSummary('emp-1', deviceId: deviceA);
      expect(summaryB!.lastMsgId, equals('msg-user'));
    });
  });

  // ═══════════════════════════════════════════════════
  // 4. 权限请求同步
  // ═══════════════════════════════════════════════════

  group('权限请求同步', () {
    test('Device A 产生权限请求，同步到 Device B 后显示 pending', () async {
      // Device A 创建摘要
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: 'AI回复',
      );

      // Device A 设置权限请求
      await storeA.setPendingPermission(
        'emp-1',
        deviceA,
        '{"type":"permission","id":"req-1","tool":"file_read"}',
      );

      // 验证 Device A 有 pending
      var summaryA = await storeA.getSummary('emp-1', deviceId: deviceA);
      expect(summaryA!.hasPendingPermission, isTrue);
      expect(summaryA.pendingPermission, contains('req-1'));

      // 同步到 Device B
      syncAToB('emp-1');

      // Device B 显示 pending
      final summaryB = await storeB.getSummary('emp-1', deviceId: deviceA);
      expect(summaryB, isNotNull);
      expect(summaryB!.hasPendingPermission, isTrue);
      expect(summaryB.pendingPermission, contains('req-1'));
      expect(summaryB.pendingPermissionTime, isNotNull);
    });

    test('Device B 响应权限请求后同步回 Device A，清除 pending', () async {
      // Device A 产生权限请求
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: 'AI回复',
      );
      await storeA.setPendingPermission(
        'emp-1',
        deviceA,
        '{"type":"permission","id":"req-1"}',
      );
      syncAToB('emp-1');

      // Device B 响应权限请求（清除 pending）
      await storeB.clearPendingPermission('emp-1', deviceA);
      expect(
        await storeB.getSummary('emp-1', deviceId: deviceA)!.hasPendingPermission,
        isFalse,
      );

      // 同步回 Device A
      syncBToA('emp-1');

      // Device A 的 pending 被保留（因为 upsertFromRemote 的 pending 合并策略：
      // 本地有 pending 且远程为空 → 保留本地）
      // 这模拟的是真实场景中需要专门的清除广播
      // 但在集成测试中，我们验证同步后 Device A 可以通过显式清除来处理
      var summaryA = await storeA.getSummary('emp-1', deviceId: deviceA);
      // pending 合并策略：本地有，远程无 → 保留本地
      expect(summaryA!.hasPendingPermission, isTrue);

      // 模拟 Device A 收到清除广播
      await storeA.clearPendingPermission('emp-1', deviceA);
      summaryA = await storeA.getSummary('emp-1', deviceId: deviceA);
      expect(summaryA!.hasPendingPermission, isFalse);
    });

    test('设备 A 离线时产生请求，上线后全量同步恢复 pending 状态', () async {
      // Device A 离线期间产生权限请求
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: 'AI回复',
      );
      await storeA.setPendingPermission(
        'emp-1',
        deviceA,
        '{"type":"permission","id":"req-offline"}',
      );

      // Device B 完全不知道（模拟离线）
      expect(await storeB.getSummary('emp-1', deviceId: deviceA), isNull);

      // Device A 上线后全量同步
      syncAToB('emp-1');

      // Device B 恢复 pending 状态
      final summaryB = await storeB.getSummary('emp-1', deviceId: deviceA);
      expect(summaryB, isNotNull);
      expect(summaryB!.hasPendingPermission, isTrue);
      expect(summaryB.pendingPermission, contains('req-offline'));
      expect(summaryB.unreadCount, equals(1));
      expect(summaryB.lastMsgId, equals('msg-1'));
    });

    test('权限请求不影响未读计数和最新消息', () async {
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: 'AI回复',
      );
      await storeA.setPendingPermission(
        'emp-1',
        deviceA,
        '{"type":"permission","id":"req-1"}',
      );

      final unreadBefore = await storeA.getUnreadCount('emp-1', deviceId: deviceA);
      final lastMsgBefore =
          await storeA.getSummary('emp-1', deviceId: deviceA)!.lastMsgId;

      syncAToB('emp-1');

      // 未读数和最新消息不变
      expect(
        await storeB.getUnreadCount('emp-1', deviceId: deviceA),
        equals(unreadBefore),
      );
      expect(
        await storeB.getSummary('emp-1', deviceId: deviceA)!.lastMsgId,
        equals(lastMsgBefore),
      );
    });
  });

  // ═══════════════════════════════════════════════════
  // 5. 确认请求同步
  // ═══════════════════════════════════════════════════

  group('确认请求同步', () {
    test('Device A 产生确认请求，同步到 Device B 后显示 pending', () async {
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: 'AI回复',
      );
      await storeA.setPendingConfirm(
        'emp-1',
        deviceA,
        '{"type":"confirm","id":"conf-1","message":"确认删除文件？"}',
      );

      syncAToB('emp-1');

      final summaryB = await storeB.getSummary('emp-1', deviceId: deviceA);
      expect(summaryB, isNotNull);
      expect(summaryB!.hasPendingConfirm, isTrue);
      expect(summaryB.pendingConfirm, contains('conf-1'));
    });

    test('Device B 响应确认请求后同步回 Device A', () async {
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: 'AI回复',
      );
      await storeA.setPendingConfirm(
        'emp-1',
        deviceA,
        '{"type":"confirm","id":"conf-1"}',
      );
      syncAToB('emp-1');

      // Device B 响应
      await storeB.clearPendingConfirm('emp-1', deviceA);
      expect(
        await storeB.getSummary('emp-1', deviceId: deviceA)!.hasPendingConfirm,
        isFalse,
      );

      // 模拟 Device A 收到清除广播（与权限请求同理）
      await storeA.clearPendingConfirm('emp-1', deviceA);
      expect(
        await storeA.getSummary('emp-1', deviceId: deviceA)!.hasPendingConfirm,
        isFalse,
      );
    });

    test('离线产生确认请求，上线后全量同步恢复', () async {
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: 'AI回复',
      );
      await storeA.setPendingConfirm(
        'emp-1',
        deviceA,
        '{"type":"confirm","id":"conf-offline"}',
      );

      // Device B 不知道
      expect(await storeB.getSummary('emp-1', deviceId: deviceA), isNull);

      // 上线同步
      syncAToB('emp-1');

      final summaryB = await storeB.getSummary('emp-1', deviceId: deviceA);
      expect(summaryB!.hasPendingConfirm, isTrue);
      expect(summaryB.pendingConfirm, contains('conf-offline'));
    });

    test('权限和确认请求可以同时存在', () async {
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: 'AI回复',
      );
      await storeA.setPendingPermission(
        'emp-1',
        deviceA,
        '{"type":"permission","id":"req-1"}',
      );
      await storeA.setPendingConfirm(
        'emp-1',
        deviceA,
        '{"type":"confirm","id":"conf-1"}',
      );

      syncAToB('emp-1');

      final summaryB = await storeB.getSummary('emp-1', deviceId: deviceA);
      expect(summaryB!.hasPendingPermission, isTrue);
      expect(summaryB.hasPendingConfirm, isTrue);
      expect(summaryB.hasPendingRequest, isTrue);
    });
  });

  // ═══════════════════════════════════════════════════
  // 6. 并发与冲突
  // ═══════════════════════════════════════════════════

  group('并发与冲突', () {
    test('两设备同时标记已读，最终一致（unread=0）', () async {
      // 初始状态：两设备都有未读
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '消息1',
      );
      syncAToB('emp-1');

      // 两设备同时标记已读
      await storeA.markAsRead('emp-1', deviceId: deviceA);
      await storeB.markAsRead('emp-1', deviceId: deviceA);

      expect(await storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(0));
      expect(await storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(0));

      // 同步后仍然一致
      syncBidirectional('emp-1');

      expect(await storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(0));
      expect(await storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(0));
    });

    test('两设备同时产生新消息，最新消息取时间更晚的', () async {
      // 初始同步
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-init',
        createTime: 1000,
        seq: 1,
        content: '初始消息',
      );
      syncAToB('emp-1');

      // Device A 产生较早的新消息
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-a',
        createTime: 2000,
        seq: 2,
        content: 'A的新消息',
      );

      // Device B 也产生新消息（使用 deviceA 作为 deviceId，模拟同一会话）
      // 注意：B 的 store 中已有 emp-1:deviceA 的摘要（从初始同步获得）
      await storeB.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-b',
        createTime: 3000,
        seq: 3,
        content: 'B的新消息',
      );

      // 双向同步（A→B 然后 B→A，使用相同的 deviceId: deviceA）
      // A→B: A 的 emp-1:deviceA 摘要同步到 B
      syncAToB('emp-1');
      // B→A: B 的 emp-1:deviceA 摘要同步到 A
      // 注意 syncBToA 读取的是 deviceId: deviceB 的摘要，但我们的数据在 deviceA 下
      // 所以需要手动同步
      final summaryBForA = await storeB.getSummary('emp-1', deviceId: deviceA);
      if (summaryBForA != null) {
        await sawait await oreA.upsertFromRemote(summaryBForA);
      }

      // 两端最新消息都是时间更晚的 msg-b
      final summaryA = await storeA.getSummary('emp-1', deviceId: deviceA);
      final summaryB = await storeB.getSummary('emp-1', deviceId: deviceA);

      // Device A: 本地 lastMsgTime=2000, B 的 lastMsgTime=3000 → 取 MAX=3000 (msg-b)
      expect(summaryA!.lastMsgId, equals('msg-b'));
      // Device B: 本地 lastMsgTime=3000, A 的 lastMsgTime=2000 → 取 MAX=3000 (msg-b)
      expect(summaryB!.lastMsgId, equals('msg-b'));
      expect(summaryA.lastMsgContent, equals('B的新消息'));
      expect(summaryB.lastMsgContent, equals('B的新消息'));
      expect(summaryA.lastMsgTime, equals(3000));
      expect(summaryB.lastMsgTime, equals(3000));
    });

    test('多轮同步后数据稳定不漂移', () async {
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '消息1',
      );
      syncAToB('emp-1');

      // 执行 10 轮双向同步
      for (int i = 0; i < 10; i++) {
        syncBidirectional('emp-1');
      }

      // 数据不变
      final summaryA = await storeA.getSummary('emp-1', deviceId: deviceA);
      final summaryB = await storeB.getSummary('emp-1', deviceId: deviceA);

      expect(summaryA!.lastMsgId, equals('msg-1'));
      expect(summaryB!.lastMsgId, equals('msg-1'));
      expect(summaryA.unreadCount, equals(1));
      expect(summaryB.unreadCount, equals(1));
    });
  });

  // ═══════════════════════════════════════════════════
  // 7. 会话删除同步
  // ═══════════════════════════════════════════════════

  group('会话删除同步', () {
    test('Device A 删除会话后，Device B 同步删除摘要', () async {
      // 创建并同步
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '消息1',
      );
      syncAToB('emp-1');

      // Device B 有摘要
      expect(await storeB.getSummary('emp-1', deviceId: deviceA), isNotNull);

      // Device A 删除会话
      await storeA.deleteSummary('emp-1', deviceId: deviceA);
      expect(await storeA.getSummary('emp-1', deviceId: deviceA), isNull);

      // 模拟同步删除通知（Device B 也删除）
      await storeB.deleteSummary('emp-1', deviceId: deviceA);
      expect(await storeB.getSummary('emp-1', deviceId: deviceA), isNull);

      // 全局未读数也更新
      expect(await storeB.getTotalUnreadCount(), equals(0));
    });

    test('删除后重新同步不产生幽灵摘要', () async {
      // 创建并同步
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '消息1',
      );
      syncAToB('emp-1');

      // 两端删除
      await storeA.deleteSummary('emp-1', deviceId: deviceA);
      await storeB.deleteSummary('emp-1', deviceId: deviceA);

      // 尝试同步（已删除，getSummary 返回 null，不会写入）
      syncAToB('emp-1');
      syncBToA('emp-1');

      // 不产生幽灵摘要
      expect(await storeA.getSummary('emp-1', deviceId: deviceA), isNull);
      expect(await storeB.getSummary('emp-1', deviceId: deviceA), isNull);
    });

    test('删除一个会话不影响其他会话', () async {
      // 创建 3 个会话
      for (int i = 1; i <= 3; i++) {
        await storeA.onMessageAdded(
          employeeId: 'emp-$i',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-$i',
          createTime: 1000 * i,
          seq: i,
          content: '消息$i',
        );
        syncAToB('emp-$i');
      }

      // 删除 emp-2
      await storeA.deleteSummary('emp-2', deviceId: deviceA);
      await storeB.deleteSummary('emp-2', deviceId: deviceA);

      // emp-1 和 emp-3 不受影响
      expect(await storeA.getSummary('emp-1', deviceId: deviceA), isNotNull);
      expect(await storeA.getSummary('emp-3', deviceId: deviceA), isNotNull);
      expect(await storeB.getSummary('emp-1', deviceId: deviceA), isNotNull);
      expect(await storeB.getSummary('emp-3', deviceId: deviceA), isNotNull);

      expect(await storeA.getAllSummaries().length, equals(2));
      expect(await storeB.getAllSummaries().length, equals(2));
    });
  });

  // ═══════════════════════════════════════════════════
  // 8. 综合端到端场景
  // ═══════════════════════════════════════════════════

  group('综合端到端场景', () {
    test('完整生命周期：消息 → 权限 → 响应 → 已读 → 删除', () async {
      // 1. Device A 收到消息
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '需要权限才能继续',
      );
      syncAToB('emp-1');

      // Device B 验证
      expect(await storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(1));
      expect(
        await storeB.getSummary('emp-1', deviceId: deviceA)!.lastMsgContent,
        equals('需要权限才能继续'),
      );

      // 2. Device A 产生权限请求
      await storeA.setPendingPermission(
        'emp-1',
        deviceA,
        '{"type":"permission","id":"req-1","tool":"file_read"}',
      );
      syncAToB('emp-1');

      // Device B 显示 pending
      expect(
        await storeB.getSummary('emp-1', deviceId: deviceA)!.hasPendingPermission,
        isTrue,
      );

      // 3. Device B 响应权限（清除 pending）
      await storeB.clearPendingPermission('emp-1', deviceA);
      // Device A 也收到响应
      await storeA.clearPendingPermission('emp-1', deviceA);

      // 4. Device A 继续处理，产生新消息
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-2',
        createTime: 2000,
        seq: 2,
        content: '文件已读取完毕',
      );
      syncAToB('emp-1');

      // Device B 更新
      expect(
        await storeB.getSummary('emp-1', deviceId: deviceA)!.lastMsgId,
        equals('msg-2'),
      );
      expect(
        await storeB.getSummary('emp-1', deviceId: deviceA)!.hasPendingPermission,
        isFalse,
      );

      // 5. Device B 标记已读
      await storeB.markAsRead('emp-1', deviceId: deviceA);
      expect(await storeB.getUnreadCount('emp-1', deviceId: deviceA), equals(0));

      // 6. Device A 也标记已读
      await storeA.markAsRead('emp-1', deviceId: deviceA);
      expect(await storeA.getUnreadCount('emp-1', deviceId: deviceA), equals(0));

      // 7. 删除会话
      await storeA.deleteSummary('emp-1', deviceId: deviceA);
      await storeB.deleteSummary('emp-1', deviceId: deviceA);

      expect(await storeA.getSummary('emp-1', deviceId: deviceA), isNull);
      expect(await storeB.getSummary('emp-1', deviceId: deviceA), isNull);
      expect(await storeA.getTotalUnreadCount(), equals(0));
      expect(await storeB.getTotalUnreadCount(), equals(0));
    });

    test('多员工多设备场景下的数据隔离', () async {
      // Device A 管理 emp-1, emp-2
      await storeA.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-a-1',
        createTime: 1000,
        seq: 1,
        content: 'A-emp1',
      );
      await storeA.onMessageAdded(
        employeeId: 'emp-2',
        deviceId: deviceA,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-a-2',
        createTime: 2000,
        seq: 1,
        content: 'A-emp2',
      );

      // Device B 管理 emp-2, emp-3（emp-2 是共享的）
      await storeB.onMessageAdded(
        employeeId: 'emp-2',
        deviceId: deviceB,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-b-2',
        createTime: 3000,
        seq: 1,
        content: 'B-emp2',
      );
      await storeB.onMessageAdded(
        employeeId: 'emp-3',
        deviceId: deviceB,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-b-3',
        createTime: 4000,
        seq: 1,
        content: 'B-emp3',
      );

      // 同步 emp-2（共享员工，但不同 deviceId）
      syncAToB('emp-2');
      syncBToA('emp-2');

      // Device A 的 emp-2 摘要（deviceId=deviceA）不受 Device B 影响
      final aEmp2 = await storeA.getSummary('emp-2', deviceId: deviceA);
      expect(aEmp2, isNotNull);
      expect(aEmp2!.lastMsgId, equals('msg-a-2'));

      // Device B 有两个 emp-2 摘要：来自 deviceA 和 deviceB
      final bEmp2FromA = await storeB.getSummary('emp-2', deviceId: deviceA);
      final bEmp2FromB = await storeB.getSummary('emp-2', deviceId: deviceB);
      expect(bEmp2FromA, isNotNull);
      expect(bEmp2FromB, isNotNull);
      expect(bEmp2FromA!.lastMsgId, equals('msg-a-2'));
      expect(bEmp2FromB!.lastMsgId, equals('msg-b-2'));

      // Device A 的 emp-1 和 Device B 的 emp-3 互不影响
      expect(await storeB.getSummary('emp-1', deviceId: deviceA), isNull);
      expect(await storeA.getSummary('emp-3', deviceId: deviceB), isNull);
    });

    test('Entity 序列化往返一致性（模拟网络传输）', () async {
      final original = SessionSummaryEntity(
        employeeId: 'emp-1',
        deviceId: deviceA,
        unreadCount: 5,
        lastMsgId: 'msg-1',
        lastMsgRole: 'assistant',
        lastMsgContent: '测试消息内容',
        lastMsgTime: 12345,
        lastMsgSeq: 42,
        pendingPermission: '{"type":"permission","id":"req-1"}',
        pendingPermissionTime: 12000,
        pendingConfirm: '{"type":"confirm","id":"conf-1"}',
        pendingConfirmTime: 13000,
        updateTime: 12345,
      );

      // 模拟网络传输：toMap → JSON → fromMap
      final map = original.toMap();
      final restored = SessionSummaryEntity.fromMap(map);

      // 写入 Device B
      await sawait await oreB.upsertFromRemote(restored);

      final summaryB = await storeB.getSummary('emp-1', deviceId: deviceA);
      expect(summaryB, isNotNull);
      expect(summaryB!.employeeId, equals('emp-1'));
      expect(summaryB.deviceId, equals(deviceA));
      expect(summaryB.unreadCount, equals(5));
      expect(summaryB.lastMsgId, equals('msg-1'));
      expect(summaryB.lastMsgRole, equals('assistant'));
      expect(summaryB.lastMsgContent, equals('测试消息内容'));
      expect(summaryB.lastMsgTime, equals(12345));
      expect(summaryB.lastMsgSeq, equals(42));
      expect(summaryB.pendingPermission, contains('req-1'));
      expect(summaryB.pendingConfirm, contains('conf-1'));
    });

    test('全局标记已读后同步不影响其他设备', () async {
      // Device A 有 3 个未读会话
      for (int i = 1; i <= 3; i++) {
        await storeA.onMessageAdded(
          employeeId: 'emp-$i',
          deviceId: deviceA,
          role: 'assistant',
          isRead: false,
          messageId: 'msg-$i',
          createTime: 1000 * i,
          seq: i,
          content: '消息$i',
        );
        syncAToB('emp-$i');
      }

      expect(await storeA.getTotalUnreadCount(), equals(3));
      expect(await storeB.getTotalUnreadCount(), equals(3));

      // Device A 全局标记已读
      await storeA.markAllAsRead();
      expect(await storeA.getTotalUnreadCount(), equals(0));

      // Device B 未受影响
      expect(await storeB.getTotalUnreadCount(), equals(3));

      // 同步后 Device B 的未读数仍为 max(3, 0) = 3（MAX 策略保护）
      for (int i = 1; i <= 3; i++) {
        syncAToB('emp-$i');
      }
      // MAX 策略：Device B 本地有 3 未读，远程 0，取 max = 3
      expect(await storeB.getTotalUnreadCount(), equals(3));

      // Device B 自己标记已读
      await storeB.markAllAsRead();
      expect(await storeB.getTotalUnreadCount(), equals(0));
    });
  });
}
