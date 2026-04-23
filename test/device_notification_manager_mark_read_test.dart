import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/agent/entity/agent_message.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_event.dart';
import 'package:wenzagent/src/device/app_context.dart';
import 'package:wenzagent/src/device/impl/data_sync_manager.dart';
import 'package:wenzagent/src/device/impl/device_agent_manager.dart';
import 'package:wenzagent/src/device/impl/device_config_manager.dart';
import 'package:wenzagent/src/device/impl/device_connection_manager.dart';
import 'package:wenzagent/src/device/impl/device_message_handler.dart';
import 'package:wenzagent/src/device/impl/device_notification_manager.dart';
import 'package:wenzagent/src/device/impl/device_registry.dart';
import 'package:wenzagent/src/device/impl/device_rpc_handler.dart';
import 'package:wenzagent/src/device/impl/device_state_holder.dart';
import 'package:wenzagent/src/device/impl/employee_online_tracker.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/service.dart';
import 'package:wenzagent/src/shared/chat_message.dart';

int _testCounter = 0;

/// DeviceNotificationManager.markAllMessagesAsRead 单元测试
///
/// 测试范围：
/// 1. 基本标记已读 —— 未读消息清零、DB 同步
/// 2. 带 fromDeviceId —— 远程会话标记已读
/// 3. 重复标记已读 —— 幂等性
/// 4. 空未读标记已读 —— 无消息时无副作用
/// 5. 多员工独立标记 —— 各员工互不影响
/// 6. 标记已读后内存状态一致性 —— hub 层与 DB 层一致
/// 7. 恢复未读后标记已读 —— DB 恢复 + 内存清零
/// 8. 多设备来源标记已读 —— 指定 fromDeviceId 只清该设备未读
void main() {
  late String testDbPath;
  late String deviceId;
  late DeviceNotificationManager notificationManager;
  late DeviceStateHolder stateHolder;
  late MessageStoreService messageStoreService;
  late EmployeeManager employeeManager;
  late SessionManager sessionManager;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_mark_read_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    // 初始化数据库
    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    // 获取各管理器实例
    employeeManager = EmployeeManager.getInstance(deviceId);
    sessionManager = SessionManager.getInstance(deviceId);
    messageStoreService = MessageStoreService.getInstance(deviceId);
    stateHolder = DeviceStateHolder.getInstance(deviceId);
    notificationManager = DeviceNotificationManager.getInstance(deviceId);
  });

  tearDown(() async {
    // 关闭 StreamControllers
    try {
      await stateHolder.close();
    } catch (_) {}

    // 清理所有单例
    DeviceNotificationManager.removeInstance(deviceId);
    DeviceStateHolder.removeInstance(deviceId);
    DeviceConnectionManager.removeInstance(deviceId);
    DeviceRegistry.removeInstance(deviceId);
    DeviceConfigManager.removeInstance(deviceId);
    DataSyncManager.removeInstance(deviceId);
    EmployeeOnlineTracker.removeInstance(deviceId);
    DeviceAgentManager.removeInstance(deviceId);
    DeviceMessageHandler.removeInstance(deviceId);
    DeviceRpcHandler.removeInstance(deviceId);
    AppContext.dispose(deviceId);

    (employeeManager as EmployeeManagerImpl).dispose();
    (sessionManager as SessionManagerImpl).dispose();
    EmployeeManager.removeInstance(deviceId);
    SessionManager.removeInstance(deviceId);
    MessageStoreService.removeInstance(deviceId);
    SkillManager.removeInstance(deviceId);
    EmployeeConfigService.removeInstance(deviceId);

    // 关闭数据库
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);

    // 删除临时数据库目录
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════
  // 辅助方法
  // ═══════════════════════════════════════════════════

  /// 创建测试用的员工
  Future<String> createTestEmployee({String? uuid, String? name}) async {
    final emp = AiEmployeeEntity(
      uuid: uuid ?? const Uuid().v4(),
      name: name ?? '测试员工',
      role: 'assistant',
      status: 'active',
      deviceId: deviceId,
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    final created = await employeeManager.createEmployee(emp);
    return created.uuid;
  }

  /// 插入未读消息到 DB（assistant 消息，isRead=false）
  Future<List<ChatMessage>> insertUnreadMessages({
    required String employeeId,
    int count = 3,
    String? msgDeviceId,
  }) async {
    final effectiveDeviceId = msgDeviceId ?? deviceId;
    final messages = <ChatMessage>[];
    for (var i = 0; i < count; i++) {
      messages.add(
        ChatMessage.assistant(
          id: 'msg-${const Uuid().v4().substring(0, 8)}',
          employeeId: employeeId,
          content: '未读消息 $i',
          deviceId: effectiveDeviceId,
        ),
      );
    }
    await messageStoreService.addMessages(deviceId, messages);
    return messages;
  }

  /// 等待微任务队列清空
  Future<void> pumpEventQueue() async {
    await Future.delayed(const Duration(milliseconds: 10));
  }

  // ═══════════════════════════════════════════════════
  // Group 1: 基本标记已读
  // ═══════════════════════════════════════════════════

  group('基本标记已读', () {
    test('标记已读后内存未读计数归零', () async {
      final empId = await createTestEmployee();

      // 插入未读消息
      await insertUnreadMessages(employeeId: empId, count: 3);

      // 在 hub 层恢复未读计数（模拟 App 启动后 restoreUnreadStatus）
      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: empId,
        count: 3,
      );
      await pumpEventQueue();

      // 验证未读计数
      expect(stateHolder.notificationHub.getUnreadCount(employeeId: empId),
          equals(3));

      // 标记全部已读
      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      // 验证内存未读计数归零
      expect(stateHolder.notificationHub.getUnreadCount(employeeId: empId),
          equals(0));
    });

    test('标记已读后 DB 中消息 isRead 变为 true', () async {
      final empId = await createTestEmployee();

      // 插入未读消息
      final messages =
          await insertUnreadMessages(employeeId: empId, count: 3);

      // 验证消息初始为未读
      for (final msg in messages) {
        final fetched =
            await messageStoreService.getMessage(deviceId, msg.id);
        expect(fetched?.isRead, isFalse);
      }

      // 标记全部已读
      notificationManager.markAllMessagesAsRead(employeeId: empId);

      // 验证 DB 中消息已读
      for (final msg in messages) {
        final fetched =
            await messageStoreService.getMessage(deviceId, msg.id);
        expect(fetched?.isRead, isTrue);
      }
    });

    test('标记已读后 DB 摘要表 unreadCount 归零', () async {
      final empId = await createTestEmployee();

      // 插入未读消息
      await insertUnreadMessages(employeeId: empId, count: 3);

      // 验证摘要表有未读计数
      final beforeCount =
          messageStoreService.getUnreadCount(deviceId, empId);
      expect(beforeCount, equals(3));

      // 标记全部已读
      notificationManager.markAllMessagesAsRead(employeeId: empId);

      // 验证摘要表未读计数归零
      final afterCount =
          messageStoreService.getUnreadCount(deviceId, empId);
      expect(afterCount, equals(0));
    });

    test('标记已读后广播未读计数变更事件', () async {
      final empId = await createTestEmployee();

      // 在 hub 层设置未读计数
      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: empId,
        count: 5,
      );
      await pumpEventQueue();

      // 订阅未读计数变更事件
      final events = <AgentUnreadCountChangedEvent>[];
      final sub = stateHolder.notificationHub
          .stream()
          .where((e) => e is AgentUnreadCountChangedEvent)
          .cast<AgentUnreadCountChangedEvent>()
          .listen(events.add);

      // 标记全部已读
      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      // 应该有未读计数变更事件
      expect(events.isNotEmpty, isTrue);
      // 最终未读计数应为 0
      final lastCount =
          events.where((e) => e.employeeId == empId).last.unreadCount;
      expect(lastCount, equals(0));

      await sub.cancel();
    });
  });

  // ═══════════════════════════════════════════════════
  // Group 2: 带 fromDeviceId
  // ═══════════════════════════════════════════════════

  group('带 fromDeviceId 标记已读', () {
    test('指定 fromDeviceId 只清除该设备的未读消息', () async {
      final empId = await createTestEmployee();

      // 从两个不同设备插入未读消息
      await insertUnreadMessages(
        employeeId: empId,
        count: 2,
        msgDeviceId: 'device-A',
      );
      await insertUnreadMessages(
        employeeId: empId,
        count: 3,
        msgDeviceId: 'device-B',
      );

      // 在 hub 层恢复两个设备的未读计数
      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: empId,
        count: 2,
        fromDeviceId: 'device-A',
      );
      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: empId,
        count: 3,
        fromDeviceId: 'device-B',
      );
      await pumpEventQueue();

      // 只标记 device-A 的消息已读
      notificationManager.markAllMessagesAsRead(
        employeeId: empId,
        fromDeviceId: 'device-A',
      );
      await pumpEventQueue();

      // device-A 的未读应归零
      expect(
        stateHolder.notificationHub.getUnreadCount(
          employeeId: empId,
          fromDeviceId: 'device-A',
        ),
        equals(0),
      );

      // device-B 的未读应保持不变
      expect(
        stateHolder.notificationHub.getUnreadCount(
          employeeId: empId,
          fromDeviceId: 'device-B',
        ),
        equals(3),
      );

      // DB 中 device-A 的消息已读（markAsReadInDb 标记该设备上该员工的所有消息）
      final unreadADb =
          messageStoreService.getUnreadCount('device-A', empId);
      expect(unreadADb, equals(0));
    });

    test('fromDeviceId 为 null 时使用本机 deviceId', () async {
      final empId = await createTestEmployee();

      // 用本机 deviceId 插入未读消息
      await insertUnreadMessages(employeeId: empId, count: 2);

      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: empId,
        count: 2,
      );
      await pumpEventQueue();

      // 不传 fromDeviceId，应默认使用 _deviceId
      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      // 验证本机消息已读
      expect(
        messageStoreService.getUnreadCount(deviceId, empId),
        equals(0),
      );
      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(0),
      );
    });
  });

  // ═══════════════════════════════════════════════════
  // Group 3: 幂等性
  // ═══════════════════════════════════════════════════

  group('幂等性', () {
    test('重复标记已读不会出错', () async {
      final empId = await createTestEmployee();

      await insertUnreadMessages(employeeId: empId, count: 3);

      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: empId,
        count: 3,
      );
      await pumpEventQueue();

      // 第一次标记
      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(0),
      );

      // 第二次标记（幂等）
      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(0),
      );

      // 第三次标记
      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(0),
      );
    });

    test('重复标记已读后 DB 状态正确', () async {
      final empId = await createTestEmployee();

      await insertUnreadMessages(employeeId: empId, count: 2);

      // 多次标记
      notificationManager.markAllMessagesAsRead(employeeId: empId);
      notificationManager.markAllMessagesAsRead(employeeId: empId);
      notificationManager.markAllMessagesAsRead(employeeId: empId);

      // DB 摘要表未读应为 0
      expect(
        messageStoreService.getUnreadCount(deviceId, empId),
        equals(0),
      );
    });
  });

  // ═══════════════════════════════════════════════════
  // Group 4: 空未读标记已读
  // ═══════════════════════════════════════════════════

  group('空未读标记已读', () {
    test('无消息时标记已读不抛异常', () async {
      final empId = await createTestEmployee();

      // 不插入任何消息，直接标记已读
      expect(
        () => notificationManager.markAllMessagesAsRead(employeeId: empId),
        returnsNormally,
      );
    });

    test('无未读消息时标记已读不抛异常', () async {
      final empId = await createTestEmployee();

      // 插入消息但已读
      final messages = [
        ChatMessage.assistant(
          id: 'msg-already-read',
          employeeId: empId,
          content: '已读消息',
          deviceId: deviceId,
        ),
      ];
      await messageStoreService.addMessages(deviceId, messages);

      // 手动标记为已读
      final msg = await messageStoreService.getMessage(deviceId, 'msg-already-read');
      if (msg != null) {
        await messageStoreService.updateMessage(
          deviceId,
          msg.copyWith(isRead: true),
        );
      }

      // 标记全部已读 —— 不应抛异常
      expect(
        () => notificationManager.markAllMessagesAsRead(employeeId: empId),
        returnsNormally,
      );
    });

    test('hub 无未读计数时标记已读后仍为 0', () async {
      final empId = await createTestEmployee();

      // hub 层无任何未读
      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(0),
      );

      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(0),
      );
    });
  });

  // ═══════════════════════════════════════════════════
  // Group 5: 多员工独立标记
  // ═══════════════════════════════════════════════════

  group('多员工独立标记', () {
    test('标记一个员工已读不影响另一个员工', () async {
      final emp1 = await createTestEmployee();
      final emp2 = await createTestEmployee();

      await insertUnreadMessages(employeeId: emp1, count: 3);
      await insertUnreadMessages(employeeId: emp2, count: 5);

      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: emp1,
        count: 3,
      );
      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: emp2,
        count: 5,
      );
      await pumpEventQueue();

      // 只标记 emp1 已读
      notificationManager.markAllMessagesAsRead(employeeId: emp1);
      await pumpEventQueue();

      // emp1 应归零
      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: emp1),
        equals(0),
      );
      expect(messageStoreService.getUnreadCount(deviceId, emp1), equals(0));

      // emp2 应保持不变
      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: emp2),
        equals(5),
      );
      expect(messageStoreService.getUnreadCount(deviceId, emp2), equals(5));
    });

    test('分别标记两个员工已读', () async {
      final emp1 = await createTestEmployee();
      final emp2 = await createTestEmployee();

      await insertUnreadMessages(employeeId: emp1, count: 2);
      await insertUnreadMessages(employeeId: emp2, count: 4);

      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: emp1,
        count: 2,
      );
      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: emp2,
        count: 4,
      );
      await pumpEventQueue();

      // 分别标记
      notificationManager.markAllMessagesAsRead(employeeId: emp1);
      notificationManager.markAllMessagesAsRead(employeeId: emp2);
      await pumpEventQueue();

      // 两者都应归零
      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: emp1),
        equals(0),
      );
      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: emp2),
        equals(0),
      );
      expect(messageStoreService.getUnreadCount(deviceId, emp1), equals(0));
      expect(messageStoreService.getUnreadCount(deviceId, emp2), equals(0));
    });
  });

  // ═══════════════════════════════════════════════════
  // Group 6: 内存与 DB 一致性
  // ═══════════════════════════════════════════════════

  group('内存与 DB 一致性', () {
    test('标记已读后 hub 和 DB 的未读计数一致', () async {
      final empId = await createTestEmployee();

      await insertUnreadMessages(employeeId: empId, count: 5);

      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: empId,
        count: 5,
      );
      await pumpEventQueue();

      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      // hub 层
      final hubCount =
          stateHolder.notificationHub.getUnreadCount(employeeId: empId);
      // DB 层
      final dbCount = messageStoreService.getUnreadCount(deviceId, empId);

      expect(hubCount, equals(dbCount));
      expect(hubCount, equals(0));
    });

    test('标记已读后 hub 中无未读消息追踪', () async {
      final empId = await createTestEmployee();

      // 通过 hub 的 onRemoteMessage 模拟消息到达
      for (var i = 0; i < 3; i++) {
        stateHolder.notificationHub.onRemoteMessage(
          message: AgentMessage(
            id: 'hub-msg-$i',
            role: 'assistant',
            content: '消息 $i',
            createdAt: DateTime.now(),
          ),
          fromDeviceId: deviceId,
          toDeviceId: deviceId,
          employeeId: empId,
        );
      }
      await pumpEventQueue();

      // 验证 hub 有 3 条未读
      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(3),
      );
      expect(
        stateHolder.notificationHub
            .getUnreadMessages(employeeId: empId)
            .length,
        equals(3),
      );

      // 标记已读
      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      // hub 层无未读消息
      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(0),
      );
      expect(
        stateHolder.notificationHub
            .getUnreadMessages(employeeId: empId)
            .length,
        equals(0),
      );

      // 所有消息都已读
      for (var i = 0; i < 3; i++) {
        expect(
          stateHolder.notificationHub.isMessageRead(
            messageId: 'hub-msg-$i',
            employeeId: empId,
          ),
          isTrue,
        );
      }
    });
  });

  // ═══════════════════════════════════════════════════
  // Group 7: 恢复未读后标记已读
  // ═══════════════════════════════════════════════════

  group('恢复未读后标记已读', () {
    test('通过 restoreUnreadCount 恢复后标记已读正常工作', () async {
      final empId = await createTestEmployee();

      // 插入未读消息
      await insertUnreadMessages(employeeId: empId, count: 4);

      // 模拟 App 重启后恢复未读计数
      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: empId,
        count: 4,
      );
      await pumpEventQueue();

      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(4),
      );

      // 标记已读
      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(0),
      );
      expect(messageStoreService.getUnreadCount(deviceId, empId), equals(0));
    });

    test('通过 restoreUnreadMessages 恢复后标记已读正常工作', () async {
      final empId = await createTestEmployee();

      // 插入未读消息
      await insertUnreadMessages(employeeId: empId, count: 2);

      // 模拟通过 restoreUnreadMessages 恢复
      final unreadMessages = [
        (
          messageId: 'restore-msg-1',
          fromDeviceId: deviceId,
          message: AgentMessage(
            id: 'restore-msg-1',
            role: 'assistant',
            content: '恢复消息 1',
            createdAt: DateTime.now(),
          ),
        ),
        (
          messageId: 'restore-msg-2',
          fromDeviceId: deviceId,
          message: AgentMessage(
            id: 'restore-msg-2',
            role: 'assistant',
            content: '恢复消息 2',
            createdAt: DateTime.now(),
          ),
        ),
      ];

      stateHolder.notificationHub.restoreUnreadMessages(
        employeeId: empId,
        unreadMessages: unreadMessages,
      );
      await pumpEventQueue();

      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(2),
      );

      // 标记已读
      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(0),
      );
      expect(
        stateHolder.notificationHub.isMessageRead(
          messageId: 'restore-msg-1',
          employeeId: empId,
        ),
        isTrue,
      );
      expect(
        stateHolder.notificationHub.isMessageRead(
          messageId: 'restore-msg-2',
          employeeId: empId,
        ),
        isTrue,
      );
    });
  });

  // ═══════════════════════════════════════════════════
  // Group 8: 多设备来源
  // ═══════════════════════════════════════════════════

  group('多设备来源标记已读', () {
    test('多个设备来源时指定 fromDeviceId 只清该设备', () async {
      final empId = await createTestEmployee();

      const deviceA = 'device-A';
      const deviceB = 'device-B';
      const deviceC = 'device-C';

      await insertUnreadMessages(
        employeeId: empId,
        count: 2,
        msgDeviceId: deviceA,
      );
      await insertUnreadMessages(
        employeeId: empId,
        count: 3,
        msgDeviceId: deviceB,
      );
      await insertUnreadMessages(
        employeeId: empId,
        count: 1,
        msgDeviceId: deviceC,
      );

      // 恢复各设备未读计数
      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: empId,
        count: 2,
        fromDeviceId: deviceA,
      );
      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: empId,
        count: 3,
        fromDeviceId: deviceB,
      );
      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: empId,
        count: 1,
        fromDeviceId: deviceC,
      );
      await pumpEventQueue();

      // 只标记 device-B 已读
      notificationManager.markAllMessagesAsRead(
        employeeId: empId,
        fromDeviceId: deviceB,
      );
      await pumpEventQueue();

      // device-A 不变
      expect(
        stateHolder.notificationHub.getUnreadCount(
          employeeId: empId,
          fromDeviceId: deviceA,
        ),
        equals(2),
      );

      // device-B 归零
      expect(
        stateHolder.notificationHub.getUnreadCount(
          employeeId: empId,
          fromDeviceId: deviceB,
        ),
        equals(0),
      );

      // device-C 不变
      expect(
        stateHolder.notificationHub.getUnreadCount(
          employeeId: empId,
          fromDeviceId: deviceC,
        ),
        equals(1),
      );
    });

    test('通过 hub 的 onRemoteMessage 模拟多设备来源后指定标记', () async {
      final empId = await createTestEmployee();

      // 模拟从 device-X 收到 2 条消息
      stateHolder.notificationHub.onRemoteMessage(
        message: AgentMessage(
          id: 'x-msg-1',
          role: 'assistant',
          content: '来自 X',
          createdAt: DateTime.now(),
        ),
        fromDeviceId: 'device-X',
        toDeviceId: deviceId,
        employeeId: empId,
      );
      stateHolder.notificationHub.onRemoteMessage(
        message: AgentMessage(
          id: 'x-msg-2',
          role: 'assistant',
          content: '来自 X',
          createdAt: DateTime.now(),
        ),
        fromDeviceId: 'device-X',
        toDeviceId: deviceId,
        employeeId: empId,
      );

      // 模拟从 device-Y 收到 1 条消息
      stateHolder.notificationHub.onRemoteMessage(
        message: AgentMessage(
          id: 'y-msg-1',
          role: 'assistant',
          content: '来自 Y',
          createdAt: DateTime.now(),
        ),
        fromDeviceId: 'device-Y',
        toDeviceId: deviceId,
        employeeId: empId,
      );
      await pumpEventQueue();

      // 总未读 3，device-X 2 条，device-Y 1 条
      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(3),
      );
      expect(
        stateHolder.notificationHub.getUnreadCount(
          employeeId: empId,
          fromDeviceId: 'device-X',
        ),
        equals(2),
      );
      expect(
        stateHolder.notificationHub.getUnreadCount(
          employeeId: empId,
          fromDeviceId: 'device-Y',
        ),
        equals(1),
      );

      // 只标记 device-X 已读
      notificationManager.markAllMessagesAsRead(
        employeeId: empId,
        fromDeviceId: 'device-X',
      );
      await pumpEventQueue();

      // device-X 归零
      expect(
        stateHolder.notificationHub.getUnreadCount(
          employeeId: empId,
          fromDeviceId: 'device-X',
        ),
        equals(0),
      );

      // device-Y 不变
      expect(
        stateHolder.notificationHub.getUnreadCount(
          employeeId: empId,
          fromDeviceId: 'device-Y',
        ),
        equals(1),
      );

      // device-X 的消息已读
      expect(
        stateHolder.notificationHub.isMessageRead(
          messageId: 'x-msg-1',
          employeeId: empId,
        ),
        isTrue,
      );
      expect(
        stateHolder.notificationHub.isMessageRead(
          messageId: 'x-msg-2',
          employeeId: empId,
        ),
        isTrue,
      );

      // device-Y 的消息未读
      expect(
        stateHolder.notificationHub.isMessageRead(
          messageId: 'y-msg-1',
          employeeId: empId,
        ),
        isFalse,
      );
    });
  });

  // ═══════════════════════════════════════════════════
  // Group 9: markAllMessagesAsReadGlobal
  // ═══════════════════════════════════════════════════

  group('markAllMessagesAsReadGlobal', () {
    test('全局标记已读清零所有员工的未读（通过 onRemoteMessage 添加）', () async {
      final emp1 = await createTestEmployee();
      final emp2 = await createTestEmployee();
      final emp3 = await createTestEmployee();

      // 通过 onRemoteMessage 添加未读（确保 _unreadMessages 有追踪）
      for (var i = 0; i < 2; i++) {
        stateHolder.notificationHub.onRemoteMessage(
          message: AgentMessage(
            id: 'global-msg-1-$i',
            role: 'assistant',
            content: '消息 $i',
            createdAt: DateTime.now(),
          ),
          fromDeviceId: deviceId,
          toDeviceId: deviceId,
          employeeId: emp1,
        );
      }
      for (var i = 0; i < 3; i++) {
        stateHolder.notificationHub.onRemoteMessage(
          message: AgentMessage(
            id: 'global-msg-2-$i',
            role: 'assistant',
            content: '消息 $i',
            createdAt: DateTime.now(),
          ),
          fromDeviceId: deviceId,
          toDeviceId: deviceId,
          employeeId: emp2,
        );
      }
      stateHolder.notificationHub.onRemoteMessage(
        message: AgentMessage(
          id: 'global-msg-3',
          role: 'assistant',
          content: '消息',
          createdAt: DateTime.now(),
        ),
        fromDeviceId: deviceId,
        toDeviceId: deviceId,
        employeeId: emp3,
      );
      await pumpEventQueue();

      // 全局标记已读
      notificationManager.markAllMessagesAsReadGlobal();
      await pumpEventQueue();

      // 所有员工未读归零
      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: emp1),
        equals(0),
      );
      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: emp2),
        equals(0),
      );
      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: emp3),
        equals(0),
      );
    });

    test('全局标记已读后 hub 中无未读员工', () async {
      final emp1 = await createTestEmployee();
      final emp2 = await createTestEmployee();

      // 通过 onRemoteMessage 添加未读
      stateHolder.notificationHub.onRemoteMessage(
        message: AgentMessage(
          id: 'g-msg-1',
          role: 'assistant',
          content: '消息',
          createdAt: DateTime.now(),
        ),
        fromDeviceId: deviceId,
        toDeviceId: deviceId,
        employeeId: emp1,
      );
      stateHolder.notificationHub.onRemoteMessage(
        message: AgentMessage(
          id: 'g-msg-2',
          role: 'assistant',
          content: '消息',
          createdAt: DateTime.now(),
        ),
        fromDeviceId: deviceId,
        toDeviceId: deviceId,
        employeeId: emp2,
      );
      await pumpEventQueue();

      expect(stateHolder.notificationHub.unreadEmployeeIds.length, equals(2));

      notificationManager.markAllMessagesAsReadGlobal();
      await pumpEventQueue();

      // 无未读员工
      expect(stateHolder.notificationHub.unreadEmployeeIds, isEmpty);
    });

    test('无未读时全局标记不抛异常', () async {
      expect(
        () => notificationManager.markAllMessagesAsReadGlobal(),
        returnsNormally,
      );
    });
  });

  // ═══════════════════════════════════════════════════
  // Group 10: 边界场景
  // ═══════════════════════════════════════════════════

  group('边界场景', () {
    test('大量未读消息标记已读', () async {
      final empId = await createTestEmployee();

      await insertUnreadMessages(employeeId: empId, count: 100);

      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: empId,
        count: 100,
      );
      await pumpEventQueue();

      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(0),
      );
      expect(messageStoreService.getUnreadCount(deviceId, empId), equals(0));
    });

    test('单条未读消息标记已读', () async {
      final empId = await createTestEmployee();

      await insertUnreadMessages(employeeId: empId, count: 1);

      stateHolder.notificationHub.restoreUnreadCount(
        employeeId: empId,
        count: 1,
      );
      await pumpEventQueue();

      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(0),
      );
      expect(messageStoreService.getUnreadCount(deviceId, empId), equals(0));
    });

    test('标记已读后新消息到达仍为未读', () async {
      final empId = await createTestEmployee();

      // 先标记已读
      notificationManager.markAllMessagesAsRead(employeeId: empId);
      await pumpEventQueue();

      // 新消息到达
      stateHolder.notificationHub.onRemoteMessage(
        message: AgentMessage(
          id: 'new-after-read',
          role: 'assistant',
          content: '新消息',
          createdAt: DateTime.now(),
        ),
        fromDeviceId: deviceId,
        toDeviceId: deviceId,
        employeeId: empId,
      );
      await pumpEventQueue();

      // 新消息应为未读
      expect(
        stateHolder.notificationHub.getUnreadCount(employeeId: empId),
        equals(1),
      );
      expect(
        stateHolder.notificationHub.isMessageRead(
          messageId: 'new-after-read',
          employeeId: empId,
        ),
        isFalse,
      );
    });
  });
}
