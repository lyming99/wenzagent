// ============================================================================
// 会话列表示例
// ============================================================================
//
// 演示如何在前端实现：
// 1. 订阅通知事件（未读计数、最新消息）
// 2. 订阅员工在线状态变化
// 3. 显示会话列表（含未读角标）
// 4. App 启动时恢复未读状态（调用 restoreUnreadStatus）
// 5. 监听 onEmployeeChanged/onSessionChanged/onDataSynced 事件
//
// 依赖：wenzagent (DeviceClient)
// 此示例为伪代码，展示集成模式。Flutter 中将 Stream 替换为 StreamBuilder 即可。
// ============================================================================

import 'package:wenzagent/wenzagent.dart';

void main() async {
  // ============================================================
  // 1. 初始化 DeviceClient
  // ============================================================
  //
  // DeviceClient 是前端的主入口，管理所有 Agent 代理、事件流、
  // 跨设备同步。

  final deviceId = 'my-phone';
  final client = DeviceClient.getInstance(deviceId);

  await client.initialize(DeviceClientConfig(
    dbPath: '/tmp/wenzagent_db',
    host: '192.168.1.100',
    port: 9527,
    topic: 'default',
    deviceName: 'My Phone',
  ));

  // ============================================================
  // 2. 订阅通知事件
  // ============================================================

  // 2a. 订阅未读计数变化
  final unreadSub = client.notificationHub.subscribeUnreadCount(
    (event) {
      print('[会话列表] 未读数变化: '
          'employeeId=${event.employeeId}, '
          'count=${event.unreadCount}');
      // Flutter: 更新 ListView 角标
      // setState(() { unreadCounts[event.employeeId] = event.unreadCount; });
    },
  );

  // 2b. 订阅所有通知事件（通过 stream）
  final eventSub = client.notificationHub.stream().listen((event) {
    if (event is AgentMessageArrivedEvent) {
      print('[会话列表] 新消息: '
          'employeeId=${event.employeeId}, '
          'content=${event.message.content?.substring(0, 20)}...');
    } else if (event is AgentLatestMessageUpdatedEvent) {
      print('[会话列表] 最新消息更新: '
          'employeeId=${event.employeeId}, '
          'content=${event.latestMessage.content?.substring(0, 20)}...');
    } else if (event is AgentLatestMessageClearedEvent) {
      print('[会话列表] 最新消息清除: employeeId=${event.employeeId}');
    } else if (event is AgentUnreadCountChangedEvent) {
      print('[会话列表] 未读数变化: '
          'employeeId=${event.employeeId}, count=${event.unreadCount}');
    }
  });

  // 2c. 订阅员工在线状态变化
  final onlineSub = client.onEmployeeOnlineChanged.listen((event) {
    print('[会话列表] 员工状态变化: '
        'employeeId=${event.employeeId}, '
        'isOnline=${event.isOnline}');
    // Flutter: 更新员工在线/离线状态图标
  });

  // ============================================================
  // 3. 监听数据同步事件（员工/会话变更）
  // ============================================================
  //
  // 当其他设备修改了员工配置、切换了项目/模型、删除了会话时，
  // 本地会收到这些事件。前端应监听并刷新 UI。

  final employeeChangeSub = client.onEmployeeChanged.listen((event) {
    print('[会话列表] 员工数据变更: '
        'type=${event.type}, employeeId=${event.employee?.uuid}');
    // Flutter: 刷新员工列表（可能影响名称、模型、项目等显示）
    // setState(() { /* reload employee list */ });
  });

  final sessionChangeSub = client.onSessionChanged.listen((event) {
    print('[会话列表] 会话数据变更: '
        'type=${event.type}, employeeId=${event.session?.employeeId}');
    // Flutter: 刷新会话列表（可能影响排序、归档状态等）
    // setState(() { /* reload session list */ });
  });

  final dataSyncSub = client.onDataSynced.listen((event) {
    print('[会话列表] 数据同步完成: '
        'employees=${event.changedEmployeeIds.length}, '
        'sessions=${event.changedSessionIds.length}');
    // Flutter: 刷新所有相关 UI
  });

  // ============================================================
  // 4. 连接到设备并同步
  // ============================================================

  await client.connect();

  // 连接后同步员工和会话数据
  await client.syncEmployeesFromDevices();
  await client.syncSessionsFromDevices();

  // ============================================================
  // 5. App 启动时恢复未读状态
  // ============================================================
  //
  // App 重启后，内存中的未读计数丢失，需要从数据库恢复。
  // 调用 restoreUnreadStatus() 会自动：
  // 1. 从数据库读取所有未读的 assistant 消息
  // 2. 恢复 NotificationHub 中的未读计数和消息映射
  // 3. 恢复每个会话的最新消息缓存
  // 4. 触发未读计数变更事件，通知 UI 刷新

  await client.restoreUnreadStatus();
  print('[会话列表] 未读状态已从数据库恢复');

  // 也可以单独查询某员工的未读数
  final employeeIds = ['employee-uuid-1', 'employee-uuid-2'];
  for (final employeeId in employeeIds) {
    final unreadCount = client.notificationHub.getUnreadCount(
      employeeId: employeeId,
    );
    print('[会话列表] 恢复未读数: '
        'employeeId=$employeeId, count=$unreadCount');

    final unreadMessages = client.notificationHub.getUnreadMessages(
      employeeId: employeeId,
    );
    print('[会话列表] 未读消息ID列表: '
        'employeeId=$employeeId, '
        'ids=${unreadMessages.map((e) => e.message.id).join(', ')}');
  }

  // ============================================================
  // 6. 显示会话列表
  // ============================================================
  //
  // 使用 EmployeeManager 获取员工列表，结合未读数显示。

  final employees = await client.employeeManager.getEmployees();
  print('\n=== 会话列表 ===');

  for (final employee in employees) {
    final unread = client.notificationHub.getUnreadCount(
      employeeId: employee.uuid,
    );
    final online = client.isEmployeeOnline(employee.uuid);

    print(
      '${online == true ? '🟢' : '⚪'} '
      '${employee.name} '
      '${unread > 0 ? '($unread)' : ''}',
    );
  }

  // ============================================================
  // 7. 设置会话打开/关闭（影响自动已读）
  // ============================================================

  // 打开会话窗口时通知系统，新消息将自动标记为已读
  client.notificationHub.shouldAutoMarkAsReadCallback = ({
    required String employeeId,
    String? fromDeviceId,
  }) {
    final currentSession = client.currentOpenSession;
    final isOpen = currentSession?.employeeId == employeeId;
    print('[会话列表] 会话窗口是否打开: '
        'employeeId=$employeeId, isOpen=$isOpen');
    return isOpen;
  };

  await client.setCurrentOpenSession(employeeId: 'employee-uuid-1');

  // 关闭会话窗口
  client.clearCurrentOpenSession();

  // ============================================================
  // 8. 清理
  // ============================================================

  unreadSub.cancel();
  eventSub.cancel();
  onlineSub.cancel();
  employeeChangeSub.cancel();
  sessionChangeSub.cancel();
  dataSyncSub.cancel();
  await client.disconnect();

  print('\n=== 示例结束 ===');
}
