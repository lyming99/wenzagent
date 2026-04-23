import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';

int _testCounter = 0;

/// SessionSummaryStore 标记已读功能测试
///
/// 覆盖：
/// - getUnreadCount：获取未读计数
/// - getTotalUnreadCount：获取全局未读总数
/// - markAsRead：标记指定会话为已读（unread_count = 0）
/// - markAsReadBySeq：按 seq 标记已读（减少 unread_count）
/// - markAllAsRead：全局标记已读
/// - onMessageAdded：新消息到达时未读计数 +1
/// - onMessageSoftDeleted：软删除时未读计数 -1（如为未读）
void main() {
  late String testDbPath;
  late String deviceId;
  late SessionSummaryStore summaryStore;
  late MessageStore messageStore;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_summary_mark_read_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    summaryStore = SessionSummaryStore(deviceId: deviceId);
    messageStore = MessageStore(deviceId: deviceId);
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════
  // 辅助方法
  // ═══════════════════════════════════════════════════

  /// 通过 onMessageAdded 更新摘要
  void addSummaryMessage({
    required String employeeId,
    required String messageId,
    String role = 'assistant',
    bool isRead = false,
    int createTime = 0,
    int seq = 0,
    String content = 'test',
  }) {
    summaryStore.onMessageAdded(
      employeeId: employeeId,
      deviceId: deviceId,
      role: role,
      isRead: isRead,
      messageId: messageId,
      createTime: createTime > 0 ? createTime : DateTime.now().millisecondsSinceEpoch,
      seq: seq,
      content: content,
    );
  }

  /// 插入消息到 messages 表
  Future<void> insertMessage(ChatMessage msg) async {
    await messageStore.addWithDeviceId(deviceId, msg);
  }

  // ═══════════════════════════════════════════════════
  // getUnreadCount 测试
  // ═══════════════════════════════════════════════════

  group('getUnreadCount', () {
    test('不存在的会话返回 0', () {
      expect(summaryStore.getUnreadCount('emp-nonexist', deviceId: deviceId), equals(0));
    });

    test('assistant 未读消息计数正确', () {
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-1', role: 'assistant', isRead: false);
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
    });

    test('assistant 已读消息不计入未读', () {
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-1', role: 'assistant', isRead: true);
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('user 消息不计入未读', () {
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-1', role: 'user', isRead: false);
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('多条消息累加', () {
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-1', role: 'assistant', isRead: false);
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-2', role: 'assistant', isRead: false);
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-3', role: 'user', isRead: false);
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(2));
    });
  });

  // ═══════════════════════════════════════════════════
  // getTotalUnreadCount 测试
  // ═══════════════════════════════════════════════════

  group('getTotalUnreadCount', () {
    test('空数据库返回 0', () {
      expect(summaryStore.getTotalUnreadCount(deviceId: deviceId), equals(0));
    });

    test('汇总所有会话的未读数', () {
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-1', role: 'assistant', isRead: false);
      addSummaryMessage(employeeId: 'emp-2', messageId: 'msg-2', role: 'assistant', isRead: false);
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-3', role: 'assistant', isRead: false);
      expect(summaryStore.getTotalUnreadCount(deviceId: deviceId), equals(3));
    });

    test('忽略 unread_count = 0 的会话', () {
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-1', role: 'assistant', isRead: true);
      addSummaryMessage(employeeId: 'emp-2', messageId: 'msg-2', role: 'user', isRead: false);
      expect(summaryStore.getTotalUnreadCount(deviceId: deviceId), equals(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // markAsRead 测试
  // ═══════════════════════════════════════════════════

  group('markAsRead', () {
    test('将未读计数置为 0', () {
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-1', role: 'assistant', isRead: false);
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-2', role: 'assistant', isRead: false);

      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(2));

      summaryStore.markAsRead('emp-1', deviceId: deviceId);

      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('对不存在的会话执行无异常', () {
      summaryStore.markAsRead('emp-nonexist', deviceId: deviceId);
      expect(summaryStore.getUnreadCount('emp-nonexist', deviceId: deviceId), equals(0));
    });

    test('对已为 0 的会话执行无副作用', () {
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-1', role: 'assistant', isRead: true);

      summaryStore.markAsRead('emp-1', deviceId: deviceId);

      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('不影响其他会话的未读计数', () {
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-1', role: 'assistant', isRead: false);
      addSummaryMessage(employeeId: 'emp-2', messageId: 'msg-2', role: 'assistant', isRead: false);

      summaryStore.markAsRead('emp-1', deviceId: deviceId);

      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
      expect(summaryStore.getUnreadCount('emp-2', deviceId: deviceId), equals(1));
    });

    test('标记后新消息到达重新计数', () {
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-1', role: 'assistant', isRead: false);

      summaryStore.markAsRead('emp-1', deviceId: deviceId);
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));

      // 新消息到达
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-2', role: 'assistant', isRead: false);
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
    });
  });

  // ═══════════════════════════════════════════════════
  // markAsReadBySeq 测试
  // ═══════════════════════════════════════════════════

  group('markAsReadBySeq', () {
    test('按 seq 减少未读计数', () async {
      // 插入 3 条 assistant 消息到 messages 表
      await insertMessage(ChatMessage(
        id: 'seq-1', employeeId: 'emp-1', role: MessageRole.assistant,
        createdAt: DateTime.now(), seq: 1,
      ));
      await insertMessage(ChatMessage(
        id: 'seq-2', employeeId: 'emp-1', role: MessageRole.assistant,
        createdAt: DateTime.now(), seq: 2,
      ));
      await insertMessage(ChatMessage(
        id: 'seq-3', employeeId: 'emp-1', role: MessageRole.assistant,
        createdAt: DateTime.now(), seq: 3,
      ));

      // 更新摘要
      addSummaryMessage(employeeId: 'emp-1', messageId: 'seq-1', role: 'assistant', isRead: false, seq: 1);
      addSummaryMessage(employeeId: 'emp-1', messageId: 'seq-2', role: 'assistant', isRead: false, seq: 2);
      addSummaryMessage(employeeId: 'emp-1', messageId: 'seq-3', role: 'assistant', isRead: false, seq: 3);

      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(3));

      // 标记 seq <= 2 为已读
      summaryStore.markAsReadBySeq('emp-1', 2, deviceId: deviceId);

      // 未读计数应减少 2
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
    });

    test('readSeq 大于所有消息的 seq 时全部标记已读', () async {
      await insertMessage(ChatMessage(
        id: 'seq-all-1', employeeId: 'emp-1', role: MessageRole.assistant,
        createdAt: DateTime.now(), seq: 1,
      ));
      addSummaryMessage(employeeId: 'emp-1', messageId: 'seq-all-1', role: 'assistant', isRead: false, seq: 1);

      summaryStore.markAsReadBySeq('emp-1', 999, deviceId: deviceId);

      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('readSeq 小于所有消息的 seq 时不减少', () async {
      await insertMessage(ChatMessage(
        id: 'seq-none', employeeId: 'emp-1', role: MessageRole.assistant,
        createdAt: DateTime.now(), seq: 10,
      ));
      addSummaryMessage(employeeId: 'emp-1', messageId: 'seq-none', role: 'assistant', isRead: false, seq: 10);

      summaryStore.markAsReadBySeq('emp-1', 5, deviceId: deviceId);

      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
    });

    test('不存在的会话执行无异常', () {
      summaryStore.markAsReadBySeq('emp-nonexist', 10, deviceId: deviceId);
    });

    test('未读计数不会变为负数', () async {
      // 摘要中有 1 条未读
      await insertMessage(ChatMessage(
        id: 'seq-neg', employeeId: 'emp-1', role: MessageRole.assistant,
        createdAt: DateTime.now(), seq: 1,
      ));
      addSummaryMessage(employeeId: 'emp-1', messageId: 'seq-neg', role: 'assistant', isRead: false, seq: 1);

      // 标记 seq <= 999（messages 表中只有 1 条匹配）
      summaryStore.markAsReadBySeq('emp-1', 999, deviceId: deviceId);

      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // markAllAsRead 测试
  // ═══════════════════════════════════════════════════

  group('markAllAsRead', () {
    test('全局标记已读（指定 deviceId）', () {
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-1', role: 'assistant', isRead: false);
      addSummaryMessage(employeeId: 'emp-2', messageId: 'msg-2', role: 'assistant', isRead: false);

      summaryStore.markAllAsRead(deviceId: deviceId);

      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
      expect(summaryStore.getUnreadCount('emp-2', deviceId: deviceId), equals(0));
      expect(summaryStore.getTotalUnreadCount(deviceId: deviceId), equals(0));
    });

    test('全局标记已读（不指定 deviceId）', () {
      addSummaryMessage(employeeId: 'emp-1', messageId: 'msg-1', role: 'assistant', isRead: false);

      summaryStore.markAllAsRead();

      expect(summaryStore.getTotalUnreadCount(), equals(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // 综合场景测试
  // ═══════════════════════════════════════════════════

  group('综合场景', () {
    test('完整流程：消息到达 → 未读累加 → 标记已读 → 新消息到达', () async {
      // 1. 消息到达
      await insertMessage(ChatMessage(
        id: 'e2e-1', employeeId: 'emp-1', role: MessageRole.assistant,
        content: 'Hi', createdAt: DateTime.now(), seq: 1,
      ));
      addSummaryMessage(employeeId: 'emp-1', messageId: 'e2e-1', role: 'assistant', isRead: false, seq: 1);

      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(1));

      // 2. 再来一条
      await insertMessage(ChatMessage(
        id: 'e2e-2', employeeId: 'emp-1', role: MessageRole.assistant,
        content: 'Hello', createdAt: DateTime.now(), seq: 2,
      ));
      addSummaryMessage(employeeId: 'emp-1', messageId: 'e2e-2', role: 'assistant', isRead: false, seq: 2);

      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(2));

      // 3. 标记全部已读
      summaryStore.markAsRead('emp-1', deviceId: deviceId);
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));

      // 4. 新消息到达后重新计数
      await insertMessage(ChatMessage(
        id: 'e2e-3', employeeId: 'emp-1', role: MessageRole.assistant,
        content: 'New', createdAt: DateTime.now(), seq: 3,
      ));
      addSummaryMessage(employeeId: 'emp-1', messageId: 'e2e-3', role: 'assistant', isRead: false, seq: 3);

      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
    });

    test('按 seq 部分标记后，再全部标记', () async {
      await insertMessage(ChatMessage(
        id: 'part-1', employeeId: 'emp-1', role: MessageRole.assistant,
        createdAt: DateTime.now(), seq: 1,
      ));
      await insertMessage(ChatMessage(
        id: 'part-2', employeeId: 'emp-1', role: MessageRole.assistant,
        createdAt: DateTime.now(), seq: 2,
      ));
      await insertMessage(ChatMessage(
        id: 'part-3', employeeId: 'emp-1', role: MessageRole.assistant,
        createdAt: DateTime.now(), seq: 3,
      ));
      addSummaryMessage(employeeId: 'emp-1', messageId: 'part-1', role: 'assistant', isRead: false, seq: 1);
      addSummaryMessage(employeeId: 'emp-1', messageId: 'part-2', role: 'assistant', isRead: false, seq: 2);
      addSummaryMessage(employeeId: 'emp-1', messageId: 'part-3', role: 'assistant', isRead: false, seq: 3);

      // 按 seq=2 标记
      summaryStore.markAsReadBySeq('emp-1', 2, deviceId: deviceId);
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(1));

      // 再全部标记
      summaryStore.markAsRead('emp-1', deviceId: deviceId);
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });
  });
}
