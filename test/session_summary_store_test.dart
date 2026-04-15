import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/session_summary_entity.dart';
import 'package:wenzagent/src/persistence/stores/session_summary_store.dart';

int _testCounter = 0;

/// SessionSummaryStore 测试
///
/// 验证：
/// - upsertFromRemote 合并策略：远程数据更新时覆盖，旧时不覆盖
/// - 未读计数取本地和远程的最大值
/// - onMessageAdded 正确更新未读数和最新消息
/// - getAllSummaries 按 deviceId 过滤
/// - markAsRead 清零未读数
void main() {
  late String testDbPath;
  late String deviceId;
  late SessionSummaryStore store;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_summary_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    store = SessionSummaryStore(deviceId: deviceId);
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════
  // upsertFromRemote 合并策略测试
  // ═══════════════════════════════════════════════════

  group('upsertFromRemote 合并策略', () {
    test('首次写入远程摘要应成功插入', () {
      final remote = SessionSummaryEntity(
        employeeId: 'emp-1',
        deviceId: deviceId,
        unreadCount: 3,
        lastMsgId: 'msg-1',
        lastMsgRole: 'assistant',
        lastMsgContent: '你好',
        lastMsgTime: 1000,
        lastMsgSeq: 1,
        updateTime: 1000,
      );

      store.upsertFromRemote(remote);

      final summary = store.getSummary('emp-1', deviceId: deviceId);
      expect(summary, isNotNull);
      expect(summary!.unreadCount, equals(3));
      expect(summary.lastMsgId, equals('msg-1'));
      expect(summary.lastMsgContent, equals('你好'));
      expect(summary.lastMsgTime, equals(1000));
    });

    test('远程 lastMsgTime 更新时覆盖本地最新消息', () {
      // 先写入本地数据
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-old',
        createTime: 1000,
        seq: 1,
        content: '旧消息',
      );

      // 远程有更新的数据
      final remote = SessionSummaryEntity(
        employeeId: 'emp-1',
        deviceId: deviceId,
        unreadCount: 2,
        lastMsgId: 'msg-new',
        lastMsgRole: 'assistant',
        lastMsgContent: '新消息',
        lastMsgTime: 2000,
        lastMsgSeq: 5,
        updateTime: 2000,
      );

      store.upsertFromRemote(remote);

      final summary = store.getSummary('emp-1', deviceId: deviceId);
      expect(summary, isNotNull);
      expect(summary!.lastMsgId, equals('msg-new'));
      expect(summary.lastMsgContent, equals('新消息'));
      expect(summary.lastMsgTime, equals(2000));
    });

    test('远程 lastMsgTime 更旧时保留本地最新消息', () {
      // 先写入本地新数据
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-local-new',
        createTime: 2000,
        seq: 5,
        content: '本地最新消息',
      );

      // 远程有更旧的数据
      final remote = SessionSummaryEntity(
        employeeId: 'emp-1',
        deviceId: deviceId,
        unreadCount: 0,
        lastMsgId: 'msg-remote-old',
        lastMsgRole: 'assistant',
        lastMsgContent: '远程旧消息',
        lastMsgTime: 1000,
        lastMsgSeq: 1,
        updateTime: 1000,
      );

      store.upsertFromRemote(remote);

      final summary = store.getSummary('emp-1', deviceId: deviceId);
      expect(summary, isNotNull);
      // 本地最新消息应保留，不被远程旧数据覆盖
      expect(summary!.lastMsgId, equals('msg-local-new'));
      expect(summary.lastMsgContent, equals('本地最新消息'));
      expect(summary.lastMsgTime, equals(2000));
    });

    test('未读数取本地和远程的最大值', () {
      // 本地未读数为 2
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '消息1',
      );
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-2',
        createTime: 1100,
        seq: 2,
        content: '消息2',
      );

      // 远程未读数为 3（比本地大）
      final remote = SessionSummaryEntity(
        employeeId: 'emp-1',
        deviceId: deviceId,
        unreadCount: 3,
        lastMsgId: 'msg-remote',
        lastMsgRole: 'assistant',
        lastMsgContent: '远程消息',
        lastMsgTime: 500,
        lastMsgSeq: 1,
        updateTime: 500,
      );

      store.upsertFromRemote(remote);

      final summary = store.getSummary('emp-1', deviceId: deviceId);
      expect(summary, isNotNull);
      // 未读数应为 max(本地2, 远程3) = 3
      expect(summary!.unreadCount, equals(3));
    });

    test('远程 lastMsgTime 为 null 时不覆盖本地数据', () {
      // 先写入本地数据
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-local',
        createTime: 1000,
        seq: 1,
        content: '本地消息',
      );

      // 远程没有最新消息（lastMsgTime 为 null）
      final remote = SessionSummaryEntity(
        employeeId: 'emp-1',
        deviceId: deviceId,
        unreadCount: 0,
        updateTime: 500,
      );

      store.upsertFromRemote(remote);

      final summary = store.getSummary('emp-1', deviceId: deviceId);
      expect(summary, isNotNull);
      // 本地消息应保留
      expect(summary!.lastMsgId, equals('msg-local'));
      expect(summary.lastMsgContent, equals('本地消息'));
    });
  });

  // ═══════════════════════════════════════════════════
  // onMessageAdded 测试
  // ═══════════════════════════════════════════════════

  group('onMessageAdded', () {
    test('assistant 未读消息增加未读计数', () {
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: 'AI 回复',
      );

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
    });

    test('user 消息不增加未读计数', () {
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'user',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '用户消息',
      );

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('已读消息不增加未读计数', () {
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'assistant',
        isRead: true,
        messageId: 'msg-1',
        createTime: 1000,
        seq: 1,
        content: '已读回复',
      );

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('最新消息按 createTime 更新', () {
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'user',
        isRead: true,
        messageId: 'msg-old',
        createTime: 1000,
        seq: 1,
        content: '旧消息',
      );

      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-new',
        createTime: 2000,
        seq: 2,
        content: '新消息',
      );

      final summary = store.getSummary('emp-1', deviceId: deviceId);
      expect(summary!.lastMsgId, equals('msg-new'));
      expect(summary.lastMsgTime, equals(2000));
    });
  });

  // ═══════════════════════════════════════════════════
  // getAllSummaries 过滤测试
  // ═══════════════════════════════════════════════════

  group('getAllSummaries', () {
    test('无 deviceId 过滤返回所有摘要', () {
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: 'device-A',
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        content: '消息A',
      );
      store.onMessageAdded(
        employeeId: 'emp-2',
        deviceId: 'device-B',
        role: 'assistant',
        isRead: false,
        messageId: 'msg-2',
        createTime: 2000,
        content: '消息B',
      );

      final all = store.getAllSummaries();
      expect(all.length, equals(2));
    });

    test('指定 deviceId 过滤返回对应摘要', () {
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: 'device-A',
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        content: '消息A',
      );
      store.onMessageAdded(
        employeeId: 'emp-2',
        deviceId: 'device-B',
        role: 'assistant',
        isRead: false,
        messageId: 'msg-2',
        createTime: 2000,
        content: '消息B',
      );

      final filtered = store.getAllSummaries(deviceId: 'device-A');
      expect(filtered.length, equals(1));
      expect(filtered.first.employeeId, equals('emp-1'));
    });
  });

  // ═══════════════════════════════════════════════════
  // markAsRead 测试
  // ═══════════════════════════════════════════════════

  group('markAsRead', () {
    test('标记已读后未读数清零', () {
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        content: '消息1',
      );
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-2',
        createTime: 2000,
        content: '消息2',
      );

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(2));

      store.markAsRead('emp-1', deviceId: deviceId);
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // 综合场景：同步后本地数据不被旧远程数据覆盖
  // ═══════════════════════════════════════════════════

  group('综合场景：同步数据合并', () {
    test('本地新消息不被远程旧摘要覆盖', () {
      // 1. 本地收到新消息
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-local-1',
        createTime: 3000,
        seq: 10,
        content: '本地最新AI回复',
      );

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
      expect(
        store.getSummary('emp-1', deviceId: deviceId)?.lastMsgId,
        equals('msg-local-1'),
      );

      // 2. 从远程同步摘要（数据更旧，lastMsgTime=1000 < 3000）
      final remoteSummary = SessionSummaryEntity(
        employeeId: 'emp-1',
        deviceId: deviceId,
        unreadCount: 0,
        lastMsgId: null,
        lastMsgRole: null,
        lastMsgContent: null,
        lastMsgTime: 1000,
        lastMsgSeq: 1,
        updateTime: 1000,
      );
      store.upsertFromRemote(remoteSummary);

      // 3. 验证本地数据没有被覆盖
      final summary = store.getSummary('emp-1', deviceId: deviceId);
      expect(summary!.lastMsgId, equals('msg-local-1'));
      expect(summary.lastMsgContent, equals('本地最新AI回复'));
      expect(summary.lastMsgTime, equals(3000));
      // 未读数应保留（max(1, 0) = 1）
      expect(summary.unreadCount, equals(1));
    });

    test('多次同步不会丢失未读数', () {
      // 1. 本地产生未读
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-1',
        createTime: 1000,
        content: '消息1',
      );
      store.onMessageAdded(
        employeeId: 'emp-1',
        deviceId: deviceId,
        role: 'assistant',
        isRead: false,
        messageId: 'msg-2',
        createTime: 2000,
        content: '消息2',
      );

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(2));

      // 2. 远程同步多次（远程未读数为 0）
      for (var i = 0; i < 3; i++) {
        store.upsertFromRemote(SessionSummaryEntity(
          employeeId: 'emp-1',
          deviceId: deviceId,
          unreadCount: 0,
          lastMsgTime: 500,
          updateTime: 500,
        ));
      }

      // 3. 未读数应保留（max(2, 0) = 2）
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(2));
    });
  });
}
