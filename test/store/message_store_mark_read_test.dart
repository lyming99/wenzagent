import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';

int _testCounter = 0;

/// MessageStore 标记已读功能测试
///
/// 覆盖：
/// - getUnreadCount：统计未读消息数量
/// - getUnreadMessageIds：获取未读消息 ID 列表
/// - getReadStatusMap：获取所有消息的已读状态
/// - markAsReadByUuid：按 UUID 标记单条消息已读
/// - markAsReadByEmployee：按员工批量标记已读
/// - markAsReadBySeq：按 seq 批量标记已读
void main() {
  late String testDbPath;
  late String deviceId;
  late MessageStore store;
  late SessionSummaryStore summaryStore;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_msg_mark_read_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    store = MessageStore(deviceId: deviceId);
    summaryStore = SessionSummaryStore(deviceId: deviceId);
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

  ChatMessage createMessage({
    required String id,
    required String employeeId,
    String role = 'assistant',
    String content = 'test',
    bool isRead = false,
    int seq = 0,
  }) {
    return ChatMessage(
      id: id,
      employeeId: employeeId,
      role: MessageRole.fromString(role),
      type: 'text',
      content: content,
      createdAt: DateTime.now(),
      isRead: isRead,
      seq: seq,
    );
  }

  /// 插入消息到数据库（通过 store.addWithDeviceId）
  Future<void> insertMessage(ChatMessage msg) async {
    await store.addWithDeviceId(deviceId, msg);
  }

  /// 插入消息并更新摘要（模拟完整流程）
  Future<void> insertMessageWithSummary(ChatMessage msg) async {
    await store.addWithDeviceId(deviceId, msg);
    summaryStore.onMessageAdded(
      employeeId: msg.employeeId,
      deviceId: deviceId,
      role: msg.role.name,
      isRead: msg.isRead,
      messageId: msg.id,
      createTime: msg.createdAt.millisecondsSinceEpoch,
      seq: msg.seq,
      content: msg.content,
    );
  }

  // ═══════════════════════════════════════════════════
  // getUnreadCount 测试
  // ═══════════════════════════════════════════════════

  group('getUnreadCount', () {
    test('空数据库返回 0', () {
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('仅统计 assistant 且 is_read=0 且 deleted=0 的消息', () async {
      // assistant 未读消息
      await insertMessage(createMessage(
        id: 'msg-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      // assistant 已读消息
      await insertMessage(createMessage(
        id: 'msg-2', employeeId: 'emp-1', role: 'assistant', isRead: true, seq: 2,
      ));
      // user 消息（不算未读）
      await insertMessage(createMessage(
        id: 'msg-3', employeeId: 'emp-1', role: 'user', seq: 3,
      ));

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
    });

    test('按 deviceId 隔离', () async {
      await insertMessage(createMessage(
        id: 'msg-a', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));

      // 使用当前 deviceId
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
      // 不存在的 deviceId
      expect(store.getUnreadCount('emp-1', deviceId: 'other-device'), equals(0));
    });

    test('不传 deviceId 时统计所有设备', () async {
      await insertMessage(createMessage(
        id: 'msg-x', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));

      expect(store.getUnreadCount('emp-1'), equals(1));
    });

    test('多个员工互不影响', () async {
      await insertMessage(createMessage(
        id: 'msg-e1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await insertMessage(createMessage(
        id: 'msg-e2', employeeId: 'emp-2', role: 'assistant', seq: 2,
      ));

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
      expect(store.getUnreadCount('emp-2', deviceId: deviceId), equals(1));
    });
  });

  // ═══════════════════════════════════════════════════
  // getUnreadMessageIds 测试
  // ═══════════════════════════════════════════════════

  group('getUnreadMessageIds', () {
    test('空数据库返回空列表', () {
      expect(store.getUnreadMessageIds('emp-1', deviceId: deviceId), isEmpty);
    });

    test('仅返回 assistant 且 is_read=0 的消息 ID', () async {
      await insertMessage(createMessage(
        id: 'unread-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await insertMessage(createMessage(
        id: 'read-1', employeeId: 'emp-1', role: 'assistant', isRead: true, seq: 2,
      ));
      await insertMessage(createMessage(
        id: 'user-1', employeeId: 'emp-1', role: 'user', seq: 3,
      ));

      final ids = store.getUnreadMessageIds('emp-1', deviceId: deviceId);
      expect(ids, equals(['unread-1']));
    });

    test('按 create_time 升序排列', () async {
      final now = DateTime.now();
      await insertMessage(ChatMessage(
        id: 'later',
        employeeId: 'emp-1',
        role: MessageRole.assistant,
        createdAt: now.add(const Duration(seconds: 2)),
        seq: 2,
      ));
      await insertMessage(ChatMessage(
        id: 'earlier',
        employeeId: 'emp-1',
        role: MessageRole.assistant,
        createdAt: now,
        seq: 1,
      ));

      final ids = store.getUnreadMessageIds('emp-1', deviceId: deviceId);
      expect(ids, equals(['earlier', 'later']));
    });

    test('按 deviceId 隔离', () async {
      await insertMessage(createMessage(
        id: 'local-unread', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));

      final ids = store.getUnreadMessageIds('emp-1', deviceId: deviceId);
      expect(ids, equals(['local-unread']));

      final otherIds = store.getUnreadMessageIds('emp-1', deviceId: 'other');
      expect(otherIds, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════
  // getReadStatusMap 测试
  // ═══════════════════════════════════════════════════

  group('getReadStatusMap', () {
    test('返回 assistant 消息的已读状态 Map', () async {
      await insertMessage(createMessage(
        id: 'map-unread', employeeId: 'emp-1', role: 'assistant', isRead: false, seq: 1,
      ));
      await insertMessage(createMessage(
        id: 'map-read', employeeId: 'emp-1', role: 'assistant', isRead: true, seq: 2,
      ));

      final statusMap = store.getReadStatusMap('emp-1', deviceId: deviceId);
      expect(statusMap['map-unread'], isFalse);
      expect(statusMap['map-read'], isTrue);
    });

    test('不包含 user 角色消息', () async {
      await insertMessage(createMessage(
        id: 'user-msg', employeeId: 'emp-1', role: 'user', seq: 1,
      ));
      await insertMessage(createMessage(
        id: 'asst-msg', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));

      final statusMap = store.getReadStatusMap('emp-1', deviceId: deviceId);
      expect(statusMap, isNot(contains('user-msg')));
      expect(statusMap, contains('asst-msg'));
    });

    test('不包含已删除消息', () async {
      await insertMessage(createMessage(
        id: 'deleted-msg', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      // 软删除
      await store.softDeleteForSync('deleted-msg', deviceId: deviceId);

      final statusMap = store.getReadStatusMap('emp-1', deviceId: deviceId);
      expect(statusMap, isNot(contains('deleted-msg')));
    });
  });

  // ═══════════════════════════════════════════════════
  // markAsReadByUuid 测试
  // ═══════════════════════════════════════════════════

  group('markAsReadByUuid', () {
    test('标记单条未读消息为已读', () async {
      await insertMessage(createMessage(
        id: 'uuid-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(1));

      store.markAsReadByUuid('uuid-1');

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('标记已读消息无副作用', () async {
      await insertMessage(createMessage(
        id: 'uuid-2', employeeId: 'emp-1', role: 'assistant', isRead: true, seq: 1,
      ));

      store.markAsReadByUuid('uuid-2');

      // 仍然是 0 未读
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('标记不存在的消息无异常', () {
      // 不应抛出异常
      store.markAsReadByUuid('non-existent-uuid');
    });

    test('标记后 getReadStatusMap 反映变更', () async {
      await insertMessage(createMessage(
        id: 'uuid-3', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));

      expect(store.getReadStatusMap('emp-1', deviceId: deviceId)['uuid-3'], isFalse);

      store.markAsReadByUuid('uuid-3');

      expect(store.getReadStatusMap('emp-1', deviceId: deviceId)['uuid-3'], isTrue);
    });

    test('标记后 getUnreadMessageIds 不再包含该消息', () async {
      await insertMessage(createMessage(
        id: 'uuid-4', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await insertMessage(createMessage(
        id: 'uuid-5', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));

      store.markAsReadByUuid('uuid-4');

      final ids = store.getUnreadMessageIds('emp-1', deviceId: deviceId);
      expect(ids, equals(['uuid-5']));
    });
  });

  // ═══════════════════════════════════════════════════
  // markAsReadByEmployee 测试
  // ═══════════════════════════════════════════════════

  group('markAsReadByEmployee', () {
    test('批量标记指定员工的所有未读消息为已读', () async {
      await insertMessage(createMessage(
        id: 'batch-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await insertMessage(createMessage(
        id: 'batch-2', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));
      await insertMessage(createMessage(
        id: 'batch-3', employeeId: 'emp-1', role: 'assistant', isRead: true, seq: 3,
      ));

      final affected = store.markAsReadByEmployee('emp-1', deviceId: deviceId);
      expect(affected, equals(2));
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('不影响其他员工的消息', () async {
      await insertMessage(createMessage(
        id: 'batch-e1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await insertMessage(createMessage(
        id: 'batch-e2', employeeId: 'emp-2', role: 'assistant', seq: 2,
      ));

      store.markAsReadByEmployee('emp-1', deviceId: deviceId);

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
      expect(store.getUnreadCount('emp-2', deviceId: deviceId), equals(1));
    });

    test('不影响 user 角色消息', () async {
      await insertMessage(createMessage(
        id: 'batch-user', employeeId: 'emp-1', role: 'user', seq: 1,
      ));
      await insertMessage(createMessage(
        id: 'batch-asst', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));

      store.markAsReadByEmployee('emp-1', deviceId: deviceId);

      // user 消息不计入未读，标记后 assistant 未读为 0
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('不影响已删除消息', () async {
      await insertMessage(createMessage(
        id: 'batch-del', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await store.softDeleteForSync('batch-del', deviceId: deviceId);

      final affected = store.markAsReadByEmployee('emp-1', deviceId: deviceId);
      expect(affected, equals(0));
    });

    test('空结果返回 0', () {
      final affected = store.markAsReadByEmployee('emp-nonexist', deviceId: deviceId);
      expect(affected, equals(0));
    });

    test('按 deviceId 隔离', () async {
      await insertMessage(createMessage(
        id: 'batch-dev', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));

      // 标记另一个 deviceId 的消息
      final affected = store.markAsReadByEmployee('emp-1', deviceId: 'other-device');
      expect(affected, equals(0));

      // 当前 deviceId 的消息仍然未读
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
    });

    test('不传 deviceId 时标记所有设备的消息', () async {
      await insertMessage(createMessage(
        id: 'batch-all-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await insertMessage(createMessage(
        id: 'batch-all-2', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));

      final affected = store.markAsReadByEmployee('emp-1');
      expect(affected, equals(2));
      expect(store.getUnreadCount('emp-1'), equals(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // markAsReadBySeq 测试
  // ═══════════════════════════════════════════════════

  group('markAsReadBySeq', () {
    test('标记 seq <= readSeq 的所有未读消息为已读', () async {
      await insertMessage(createMessage(
        id: 'seq-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await insertMessage(createMessage(
        id: 'seq-2', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));
      await insertMessage(createMessage(
        id: 'seq-3', employeeId: 'emp-1', role: 'assistant', seq: 3,
      ));

      final affected = store.markAsReadBySeq('emp-1', 2, deviceId: deviceId);
      expect(affected, equals(2));
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(1));

      // seq-3 仍然未读
      final unreadIds = store.getUnreadMessageIds('emp-1', deviceId: deviceId);
      expect(unreadIds, equals(['seq-3']));
    });

    test('不影响已读消息', () async {
      await insertMessage(createMessage(
        id: 'seq-r1', employeeId: 'emp-1', role: 'assistant', isRead: true, seq: 1,
      ));
      await insertMessage(createMessage(
        id: 'seq-r2', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));

      final affected = store.markAsReadBySeq('emp-1', 5, deviceId: deviceId);
      // 只有 seq-r2 被标记（seq-r1 已读）
      expect(affected, equals(1));
    });

    test('readSeq 小于所有消息的 seq 时不标记任何消息', () async {
      await insertMessage(createMessage(
        id: 'seq-h1', employeeId: 'emp-1', role: 'assistant', seq: 10,
      ));
      await insertMessage(createMessage(
        id: 'seq-h2', employeeId: 'emp-1', role: 'assistant', seq: 20,
      ));

      final affected = store.markAsReadBySeq('emp-1', 5, deviceId: deviceId);
      expect(affected, equals(0));
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(2));
    });

    test('按 deviceId 隔离', () async {
      await insertMessage(createMessage(
        id: 'seq-dev-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));

      final affected = store.markAsReadBySeq('emp-1', 100, deviceId: 'other-device');
      expect(affected, equals(0));
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
    });

    test('不影响 user 角色消息', () async {
      await insertMessage(createMessage(
        id: 'seq-user', employeeId: 'emp-1', role: 'user', seq: 1,
      ));
      await insertMessage(createMessage(
        id: 'seq-asst', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));

      final affected = store.markAsReadBySeq('emp-1', 5, deviceId: deviceId);
      // 只标记 assistant 消息
      expect(affected, equals(1));
    });

    test('不影响已删除消息', () async {
      await insertMessage(createMessage(
        id: 'seq-del', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await store.softDeleteForSync('seq-del', deviceId: deviceId);

      final affected = store.markAsReadBySeq('emp-1', 5, deviceId: deviceId);
      expect(affected, equals(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // 综合场景测试
  // ═══════════════════════════════════════════════════

  group('综合场景', () {
    test('clearAllUnread 完整流程：插入消息 → 标记已读 → 验证', () async {
      // 1. 插入 3 条未读 assistant 消息
      await insertMessageWithSummary(createMessage(
        id: 'flow-1', employeeId: 'emp-1', role: 'assistant', content: 'Hello', seq: 1,
      ));
      await insertMessageWithSummary(createMessage(
        id: 'flow-2', employeeId: 'emp-1', role: 'assistant', content: 'World', seq: 2,
      ));
      await insertMessageWithSummary(createMessage(
        id: 'flow-3', employeeId: 'emp-1', role: 'assistant', content: 'Test', seq: 3,
      ));

      // 2. 验证未读状态
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(3));
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(3));
      final unreadIds = store.getUnreadMessageIds('emp-1', deviceId: deviceId);
      expect(unreadIds, equals(['flow-1', 'flow-2', 'flow-3']));

      // 3. 执行 clearAllUnread（等价于 markAsReadByEmployee + summaryStore.markAsRead）
      final affected = store.markAsReadByEmployee('emp-1', deviceId: deviceId);
      summaryStore.markAsRead('emp-1', deviceId: deviceId);

      // 4. 验证已读状态
      expect(affected, equals(3));
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
      expect(store.getUnreadMessageIds('emp-1', deviceId: deviceId), isEmpty);

      // 5. 验证 getReadStatusMap 全部为 true
      final statusMap = store.getReadStatusMap('emp-1', deviceId: deviceId);
      expect(statusMap['flow-1'], isTrue);
      expect(statusMap['flow-2'], isTrue);
      expect(statusMap['flow-3'], isTrue);
    });

    test('按 seq 部分标记已读后，再全部标记已读', () async {
      // 使用 insertMessage（写入 messages 表）+ onMessageAdded（更新摘要）
      await insertMessage(createMessage(
        id: 'partial-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      addSummaryMessage(employeeId: 'emp-1', messageId: 'partial-1', role: 'assistant', isRead: false, seq: 1);
      await insertMessage(createMessage(
        id: 'partial-2', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));
      addSummaryMessage(employeeId: 'emp-1', messageId: 'partial-2', role: 'assistant', isRead: false, seq: 2);
      await insertMessage(createMessage(
        id: 'partial-3', employeeId: 'emp-1', role: 'assistant', seq: 3,
      ));
      addSummaryMessage(employeeId: 'emp-1', messageId: 'partial-3', role: 'assistant', isRead: false, seq: 3);

      // 先按 seq=2 标记
      store.markAsReadBySeq('emp-1', 2, deviceId: deviceId);
      summaryStore.markAsReadBySeq('emp-1', 2, deviceId: deviceId);

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(1));

      // 再全部标记已读
      store.markAsReadByEmployee('emp-1', deviceId: deviceId);
      summaryStore.markAsRead('emp-1', deviceId: deviceId);

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('多次标记已读不产生副作用', () async {
      await insertMessage(createMessage(
        id: 'multi-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));

      // 第一次标记
      final affected1 = store.markAsReadByEmployee('emp-1', deviceId: deviceId);
      expect(affected1, equals(1));

      // 第二次标记（无新消息被标记）
      final affected2 = store.markAsReadByEmployee('emp-1', deviceId: deviceId);
      expect(affected2, equals(0));

      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
    });

    test('新消息到达后未读计数正确累加', () async {
      await insertMessageWithSummary(createMessage(
        id: 'accum-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(1));

      // 标记已读
      store.markAsReadByEmployee('emp-1', deviceId: deviceId);
      summaryStore.markAsRead('emp-1', deviceId: deviceId);
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(0));
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(0));

      // 新消息到达
      await insertMessageWithSummary(createMessage(
        id: 'accum-2', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));
      expect(store.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
      expect(summaryStore.getUnreadCount('emp-1', deviceId: deviceId), equals(1));
    });
  });
}
