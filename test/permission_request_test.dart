import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  group('权限请求缓存测试', () {
    test('权限请求可以被缓存和获取', () {
      // 创建权限请求
      final request1 = AgentPermissionRequest(
        requestId: 'req-001',
        type: 'file_write',
        description: '写入文件',
        functionName: 'writeFile',
        data: {'path': '/test/file.txt'},
      );

      final request2 = AgentPermissionRequest(
        requestId: 'req-002',
        type: 'command_execute',
        description: '执行命令',
        functionName: 'executeCommand',
        data: {'command': 'ls'},
      );

      // 验证权限请求的创建
      expect(request1.requestId, equals('req-001'));
      expect(request1.type, equals('file_write'));
      expect(request1.functionName, equals('writeFile'));

      expect(request2.requestId, equals('req-002'));
      expect(request2.type, equals('command_execute'));
      expect(request2.functionName, equals('executeCommand'));

      // 验证序列化和反序列化
      final map1 = request1.toMap();
      final restored1 = AgentPermissionRequest.fromMap(map1);
      expect(restored1.requestId, equals('req-001'));
      expect(restored1.type, equals('file_write'));

      final map2 = request2.toMap();
      final restored2 = AgentPermissionRequest.fromMap(map2);
      expect(restored2.requestId, equals('req-002'));
      expect(restored2.type, equals('command_execute'));
    });

    test('权限请求缓存Map操作', () {
      final cache = <String, AgentPermissionRequest>{};

      // 添加权限请求
      final request = AgentPermissionRequest(
        requestId: 'req-003',
        type: 'file_read',
        description: '读取文件',
        functionName: 'readFile',
      );

      cache[request.requestId] = request;
      expect(cache.length, equals(1));
      expect(cache.containsKey('req-003'), isTrue);

      // 获取权限请求
      final retrieved = cache['req-003'];
      expect(retrieved, isNotNull);
      expect(retrieved!.requestId, equals('req-003'));

      // 删除权限请求
      cache.remove('req-003');
      expect(cache.isEmpty, isTrue);
    });

    test('权限决策枚举', () {
      expect(PermissionDecision.allow.name, equals('allow'));
      expect(PermissionDecision.deny.name, equals('deny'));
      expect(PermissionDecision.allowAlways.name, equals('allowAlways'));

      expect(
        PermissionDecision.fromString('allow'),
        equals(PermissionDecision.allow),
      );
      expect(
        PermissionDecision.fromString('deny'),
        equals(PermissionDecision.deny),
      );
      expect(
        PermissionDecision.fromString('unknown'),
        equals(PermissionDecision.deny), // 默认返回 deny
      );
    });

    test('AgentStatus 包含 waitingPermission 状态', () {
      expect(AgentStatus.waitingPermission.name, equals('waitingPermission'));
      expect(
        AgentStatus.fromString('waitingPermission'),
        equals(AgentStatus.waitingPermission),
      );
    });
  });
}
