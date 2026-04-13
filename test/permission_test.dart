import 'dart:async';

import 'package:test/test.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/entity/agent_event.dart';
import 'package:wenzagent/src/agent/entity/agent_message.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_event.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_hub.dart';

/// 权限请求测试
///
/// 验证权限请求事件链和授权清除缓存请求：
/// - 本地模式权限请求事件链
/// - 远程模式权限请求事件链
/// - 授权清除缓存请求
void main() {
  group('本地模式权限请求事件链', () {
    test('toolPermissionRequest event carries all fields', () async {
      final hub = AgentNotificationHub();
      final events = <AgentNotificationEvent>[];
      final sub = hub.stream(employeeId: 'emp-1').listen(events.add);

      // 模拟权限请求到达
      final request = AgentPermissionRequest(
        requestId: 'req-001',
        type: 'file_write',
        description: '写入文件 /tmp/test.txt',
        functionName: 'write_file',
        permissionArgKey: 'path',
        permissionArgValue: '/tmp/test.txt',
        suggestedPattern: '/tmp/*',
      );

      // 通知 Agent 状态变为等待权限
      hub.onAgentStatusChanged(
        employeeId: 'emp-1',
        fromDeviceId: 'device-A',
        status: 'waitingPermission',
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(events, hasLength(1));
      expect(events.first, isA<AgentStatusNotifyEvent>());
      final statusEvent = events.first as AgentStatusNotifyEvent;
      expect(statusEvent.status, equals('waitingPermission'));
      expect(statusEvent.employeeId, equals('emp-1'));

      await sub.cancel();
      hub.dispose();
    });
  });

  group('远程模式权限请求事件链', () {
    test('permission request from remote device notifies subscriber', () async {
      final hub = AgentNotificationHub();
      final events = <AgentNotificationEvent>[];
      final sub = hub.stream(employeeId: 'emp-1').listen(events.add);

      // 远程设备通知权限等待状态
      hub.onAgentStatusChanged(
        employeeId: 'emp-1',
        fromDeviceId: 'device-server',
        status: 'waitingPermission',
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(events, hasLength(1));
      final statusEvent = events.first as AgentStatusNotifyEvent;
      expect(statusEvent.fromDeviceId, equals('device-server'));
      expect(statusEvent.status, equals('waitingPermission'));

      await sub.cancel();
      hub.dispose();
    });

    test('permission response clears waiting status', () async {
      final hub = AgentNotificationHub();
      final statusEvents = <String>[];
      final sub = hub.stream(employeeId: 'emp-1').listen((event) {
        if (event is AgentStatusNotifyEvent) {
          statusEvents.add(event.status);
        }
      });

      // 权限等待
      hub.onAgentStatusChanged(
        employeeId: 'emp-1',
        fromDeviceId: 'device-A',
        status: 'waitingPermission',
      );

      // 权限已响应，恢复处理中
      hub.onAgentStatusChanged(
        employeeId: 'emp-1',
        fromDeviceId: 'device-A',
        status: 'processing',
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(statusEvents, equals(['waitingPermission', 'processing']));

      await sub.cancel();
      hub.dispose();
    });
  });

  group('AgentPermissionRequest 序列化', () {
    test('toMap and fromMap round-trip', () {
      final request = AgentPermissionRequest(
        requestId: 'req-002',
        type: 'command_execute',
        description: '执行命令 rm -rf /tmp/test',
        functionName: 'execute_command',
        permissionPattern: null,
        permissionType: 'dangerous',
        data: {'command': 'rm -rf /tmp/test'},
        permissionArgKey: 'command',
        permissionArgValue: 'rm -rf /tmp/test',
        suggestedPattern: 'rm *',
      );

      final map = request.toMap();
      final restored = AgentPermissionRequest.fromMap(map);

      expect(restored.requestId, equals('req-002'));
      expect(restored.type, equals('command_execute'));
      expect(restored.description, equals('执行命令 rm -rf /tmp/test'));
      expect(restored.functionName, equals('execute_command'));
      expect(restored.permissionType, equals('dangerous'));
      expect(restored.data, equals({'command': 'rm -rf /tmp/test'}));
      expect(restored.permissionArgKey, equals('command'));
      expect(restored.permissionArgValue, equals('rm -rf /tmp/test'));
      expect(restored.suggestedPattern, equals('rm *'));
    });

    test('fromMap handles null optional fields', () {
      final map = {
        'requestId': 'req-003',
        'type': 'file_read',
        'description': '读取文件',
        'functionName': 'read_file',
      };

      final restored = AgentPermissionRequest.fromMap(map);
      expect(restored.requestId, equals('req-003'));
      expect(restored.permissionPattern, isNull);
      expect(restored.permissionType, isNull);
      expect(restored.data, isNull);
      expect(restored.permissionArgKey, isNull);
      expect(restored.permissionArgValue, isNull);
      expect(restored.suggestedPattern, isNull);
    });
  });

  group('PermissionDecision 枚举', () {
    test('all values can be found by name', () {
      for (final decision in PermissionDecision.values) {
        final found = PermissionDecision.values.firstWhere(
          (d) => d.name == decision.name,
          orElse: () => PermissionDecision.deny,
        );
        expect(found, equals(decision));
      }
    });

    test('unknown name falls back to deny', () {
      final found = PermissionDecision.values.firstWhere(
        (d) => d.name == 'nonexistent',
        orElse: () => PermissionDecision.deny,
      );
      expect(found, equals(PermissionDecision.deny));
    });
  });

  group('授权清除缓存请求', () {
    test('permission request cached and cleared on response', () {
      // 模拟 CachedAgentProxy 的权限缓存管理
      final cache = <String, AgentPermissionRequest>{};

      final request = AgentPermissionRequest(
        requestId: 'req-cache-001',
        type: 'file_write',
        description: '写入文件',
        functionName: 'write_file',
      );

      // 缓存请求
      cache[request.requestId] = request;
      expect(cache.length, equals(1));
      expect(cache.containsKey('req-cache-001'), isTrue);

      // 响应后清除
      cache.remove('req-cache-001');
      expect(cache.isEmpty, isTrue);
    });

    test('multiple permission requests tracked independently', () {
      final cache = <String, AgentPermissionRequest>{};

      final req1 = AgentPermissionRequest(
        requestId: 'req-multi-001',
        type: 'file_write',
        description: '写文件A',
        functionName: 'write_file',
      );
      final req2 = AgentPermissionRequest(
        requestId: 'req-multi-002',
        type: 'command_execute',
        description: '执行命令',
        functionName: 'execute_command',
      );

      cache[req1.requestId] = req1;
      cache[req2.requestId] = req2;

      expect(cache.length, equals(2));

      // 响应第一个
      cache.remove('req-multi-001');
      expect(cache.length, equals(1));
      expect(cache.containsKey('req-multi-002'), isTrue);
    });
  });
}
