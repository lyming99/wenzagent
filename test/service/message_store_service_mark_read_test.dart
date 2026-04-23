import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/persistence/stores/message_store.dart';
import 'package:wenzagent/src/persistence/stores/session_summary_store.dart';
import 'package:wenzagent/src/service/message_store_service.dart';

int _testCounter = 0;

/// MessageStoreService 标记已读功能测试
///
/// 覆盖：
/// - getUnreadCount：从 session_summary 表读取未读计数
/// - getTotalUnreadCount：全局未读总数
/// - markAsReadInDb：批量标记已读（messages 表 + session_summary 表）
/// - markAsReadBySeqInDb：按 seq 标记已读（messages 表 + session_summary 表）
/// - getUnreadMessageIds：获取未读消息 ID 列表
void main() {
  late String testDbPath;
  late String deviceId;
  late MessageStoreServiceImpl service;
  late MessageStore messageStore;
  late SessionSummaryStore summaryStore;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_service_mark_read_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    service = MessageStoreServiceImpl(deviceId: deviceId);
    messageStore = MessageStore(deviceId: deviceId);
    summaryStore = SessionSummaryStore(deviceId: deviceId);
  });

  tearDown(() async {
    service.dispose();
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    MessageStoreService.removeInstance(deviceId);
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

  /// 插入消息并更新摘要（完整流程）
  Future<void> insertMessageWithSummary(ChatMessage msg) async {
    await service.addMessage(deviceId, msg);
  }

  /// 仅写入 messages 表（不更新摘要）
  Future<void> insertMessageOnly(ChatMessage msg) async {
    await messageStore.addWithDeviceId(deviceId, msg);
  }

  /// 手动更新摘要
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

  // ═══════════════════════════════════════════════════
  // getUnreadCount 测试
  // ═══════════════════════════════════════════════════

  group('getUnreadCount', () {
    test('空数据库返回 0', () {
      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(0));
    });

    test('新消息到达后未读计数正确', () async {
      await insertMessageWithSummary(createMessage(
        id: 'svc-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));

      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(1));
    });

    test('user 消息不计入未读', () async {
      await insertMessageWithSummary(createMessage(
        id: 'svc-2', employeeId: 'emp-1', role: 'user', seq: 1,
      ));

      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(0));
    });

    test('已读消息不计入未读', () async {
      await insertMessageWithSummary(createMessage(
        id: 'svc-3', employeeId: 'emp-1', role: 'assistant', isRead: true, seq: 1,
      ));

      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(0));
    });

    test('多条消息累加', () async {
      await insertMessageWithSummary(createMessage(
        id: 'svc-4', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await insertMessageWithSummary(createMessage(
        id: 'svc-5', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));

      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(2));
    });
  });

  // ═══════════════════════════════════════════════════
  // getTotalUnreadCount 测试
  // ═══════════════════════════════════════════════════

  group('getTotalUnreadCount', () {
    test('空数据库返回 0', () {
      expect(service.getTotalUnreadCount(deviceId: deviceId), equals(0));
    });

    test('汇总多个会话的未读数', () async {
      await insertMessageWithSummary(createMessage(
        id: 'total-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await insertMessageWithSummary(createMessage(
        id: 'total-2', employeeId: 'emp-2', role: 'assistant', seq: 2,
      ));

      expect(service.getTotalUnreadCount(deviceId: deviceId), equals(2));
    });
  });

  // ═══════════════════════════════════════════════════
  // getUnreadMessageIds 测试
  // ═══════════════════════════════════════════════════

  group('getUnreadMessageIds', () {
    test('空数据库返回空列表', () {
      expect(service.getUnreadMessageIds(deviceId, 'emp-1'), isEmpty);
    });

    test('仅返回 assistant 且未读的消息 ID', () async {
      await insertMessageWithSummary(createMessage(
        id: 'ids-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await insertMessageWithSummary(createMessage(
        id: 'ids-2', employeeId: 'emp-1', role: 'assistant', isRead: true, seq: 2,
      ));
      await insertMessageWithSummary(createMessage(
        id: 'ids-3', employeeId: 'emp-1', role: 'user', seq: 3,
      ));

      final ids = service.getUnreadMessageIds(deviceId, 'emp-1');
      expect(ids, equals(['ids-1']));
    });

    test('按 create_time 升序排列', () async {
      final now = DateTime.now();
      await insertMessageWithSummary(ChatMessage(
        id: 'ids-later',
        employeeId: 'emp-1',
        role: MessageRole.assistant,
        createdAt: now.add(const Duration(seconds: 1)),
        seq: 2,
      ));
      await insertMessageWithSummary(ChatMessage(
        id: 'ids-earlier',
        employeeId: 'emp-1',
        role: MessageRole.assistant,
        createdAt: now,
        seq: 1,
      ));

      final ids = service.getUnreadMessageIds(deviceId, 'emp-1');
      expect(ids, equals(['ids-earlier', 'ids-later']));
    });
  });

  // ═══════════════════════════════════════════════════
  // markAsReadInDb 测试
  // ═══════════════════════════════════════════════════

  group('markAsReadInDb', () {
    test('批量标记已读后 messages 表和 summary 表同步更新', () async {
      await insertMessageWithSummary(createMessage(
        id: 'mark-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await insertMessageWithSummary(createMessage(
        id: 'mark-2', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));

      // 标记前
      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(2));
      expect(service.getUnreadMessageIds(deviceId, 'emp-1'), hasLength(2));

      // 执行标记已读
      final affected = service.markAsReadInDb(deviceId, 'emp-1');

      // 验证
      expect(affected, equals(2));
      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(0));
      expect(service.getUnreadMessageIds(deviceId, 'emp-1'), isEmpty);
    });

    test('不影响其他员工', () async {
      await insertMessageWithSummary(createMessage(
        id: 'mark-e1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await insertMessageWithSummary(createMessage(
        id: 'mark-e2', employeeId: 'emp-2', role: 'assistant', seq: 2,
      ));

      service.markAsReadInDb(deviceId, 'emp-1');

      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(0));
      expect(service.getUnreadCount(deviceId, 'emp-2'), equals(1));
    });

    test('不影响 user 消息', () async {
      await insertMessageWithSummary(createMessage(
        id: 'mark-user', employeeId: 'emp-1', role: 'user', seq: 1,
      ));
      await insertMessageWithSummary(createMessage(
        id: 'mark-asst', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));

      final affected = service.markAsReadInDb(deviceId, 'emp-1');
      expect(affected, equals(1));
      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(0));
    });

    test('空结果返回 0', () {
      final affected = service.markAsReadInDb(deviceId, 'emp-nonexist');
      expect(affected, equals(0));
    });

    test('重复标记无副作用', () async {
      await insertMessageWithSummary(createMessage(
        id: 'mark-dup', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));

      final affected1 = service.markAsReadInDb(deviceId, 'emp-1');
      expect(affected1, equals(1));

      final affected2 = service.markAsReadInDb(deviceId, 'emp-1');
      expect(affected2, equals(0));
    });

    test('标记后新消息到达重新计数', () async {
      await insertMessageWithSummary(createMessage(
        id: 'mark-new-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));

      service.markAsReadInDb(deviceId, 'emp-1');
      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(0));

      // 新消息到达
      await insertMessageWithSummary(createMessage(
        id: 'mark-new-2', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));
      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(1));
    });
  });

  // ═══════════════════════════════════════════════════
  // markAsReadBySeqInDb 测试
  // ═══════════════════════════════════════════════════

  group('markAsReadBySeqInDb', () {
    test('按 seq 标记已读后 messages 表和 summary 表同步更新', () async {
      // 使用 service.addMessage 完整流程写入（同时更新 messages 和 summary）
      await service.addMessage(deviceId, createMessage(
        id: 'seq-svc-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await service.addMessage(deviceId, createMessage(
        id: 'seq-svc-2', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));
      await service.addMessage(deviceId, createMessage(
        id: 'seq-svc-3', employeeId: 'emp-1', role: 'assistant', seq: 3,
      ));

      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(3));

      // 标记 seq <= 2
      final affected = service.markAsReadBySeqInDb(deviceId, 'emp-1', 2);

      expect(affected, equals(2));
      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(1));
      expect(service.getUnreadMessageIds(deviceId, 'emp-1'), equals(['seq-svc-3']));
    });

    test('readSeq 大于所有消息的 seq 时全部标记', () async {
      await service.addMessage(deviceId, createMessage(
        id: 'seq-svc-all', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));

      final affected = service.markAsReadBySeqInDb(deviceId, 'emp-1', 999);

      expect(affected, equals(1));
      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(0));
    });

    test('readSeq 小于所有消息的 seq 时不标记', () async {
      await service.addMessage(deviceId, createMessage(
        id: 'seq-svc-none', employeeId: 'emp-1', role: 'assistant', seq: 10,
      ));

      final affected = service.markAsReadBySeqInDb(deviceId, 'emp-1', 5);

      expect(affected, equals(0));
      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(1));
    });

    test('不影响其他员工', () async {
      await service.addMessage(deviceId, createMessage(
        id: 'seq-svc-e1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await service.addMessage(deviceId, createMessage(
        id: 'seq-svc-e2', employeeId: 'emp-2', role: 'assistant', seq: 2,
      ));

      service.markAsReadBySeqInDb(deviceId, 'emp-1', 999);

      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(0));
      expect(service.getUnreadCount(deviceId, 'emp-2'), equals(1));
    });
  });

  // ═══════════════════════════════════════════════════
  // 综合场景测试
  // ═══════════════════════════════════════════════════

  group('综合场景', () {
    test('clearAllUnread 完整流程', () async {
      // 1. 多条消息到达
      for (var i = 1; i <= 5; i++) {
        await insertMessageWithSummary(createMessage(
          id: 'e2e-$i', employeeId: 'emp-1', role: 'assistant', content: 'Msg $i', seq: i,
        ));
      }

      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(5));
      expect(service.getTotalUnreadCount(deviceId: deviceId), equals(5));
      expect(service.getUnreadMessageIds(deviceId, 'emp-1'), hasLength(5));

      // 2. clearAllUnread（等价于 markAsReadInDb）
      final affected = service.markAsReadInDb(deviceId, 'emp-1');

      // 3. 验证
      expect(affected, equals(5));
      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(0));
      expect(service.getTotalUnreadCount(deviceId: deviceId), equals(0));
      expect(service.getUnreadMessageIds(deviceId, 'emp-1'), isEmpty);
    });

    test('按 seq 部分标记后，再全部标记', () async {
      for (var i = 1; i <= 5; i++) {
        await service.addMessage(deviceId, createMessage(
          id: 'partial-svc-$i', employeeId: 'emp-1', role: 'assistant', seq: i,
        ));
      }

      // 按 seq=3 标记
      service.markAsReadBySeqInDb(deviceId, 'emp-1', 3);
      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(2));

      // 全部标记
      service.markAsReadInDb(deviceId, 'emp-1');
      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(0));
    });

    test('多会话独立标记已读', () async {
      await insertMessageWithSummary(createMessage(
        id: 'multi-e1-1', employeeId: 'emp-1', role: 'assistant', seq: 1,
      ));
      await insertMessageWithSummary(createMessage(
        id: 'multi-e1-2', employeeId: 'emp-1', role: 'assistant', seq: 2,
      ));
      await insertMessageWithSummary(createMessage(
        id: 'multi-e2-1', employeeId: 'emp-2', role: 'assistant', seq: 3,
      ));

      // 只标记 emp-1
      service.markAsReadInDb(deviceId, 'emp-1');

      expect(service.getUnreadCount(deviceId, 'emp-1'), equals(0));
      expect(service.getUnreadCount(deviceId, 'emp-2'), equals(1));
      expect(service.getTotalUnreadCount(deviceId: deviceId), equals(1));

      // 再标记 emp-2
      service.markAsReadInDb(deviceId, 'emp-2');

      expect(service.getUnreadCount(deviceId, 'emp-2'), equals(0));
      expect(service.getTotalUnreadCount(deviceId: deviceId), equals(0));
    });
  });
}
