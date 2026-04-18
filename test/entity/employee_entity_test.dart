import 'dart:convert';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';

/// Employee Entity 序列化往返测试
///
/// 验证：
/// - A. toMap/fromMap 所有字段零丢失
/// - B. copyWith 各字段独立覆盖
/// - C. deletedTime null 和非 null 场景
/// - D. getMcpConfigs / setMcpConfigs 方法
/// - E. isMcpEnabled getter
void main() {
  // ═══════════════════════════════════════════════════
  // 辅助方法
  // ═══════════════════════════════════════════════════

  final now = DateTime.now();
  final later = now.add(const Duration(hours: 1));

  AiEmployeeEntity createFullEmployee({
    String? uuid,
    String? name,
    String? avatar,
    String? role,
    String? status,
    String? description,
    String? systemPrompt,
    String? provider,
    String? model,
    String? apiKey,
    String? apiBaseUrl,
    String? modelConfig,
    int? enableTools,
    int? enableMcp,
    String? projectUuid,
    String? projectName,
    String? projectContext,
    String? workPath,
    String? mcpConfig,
    String? permissionConfig,
    String? deviceId,
    String? currentDeviceId,
    int? autoApprove,
    int? sortOrder,
    int? isPinned,
    int? deleted,
    DateTime? deletedTime,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return AiEmployeeEntity(
      uuid: uuid ?? const Uuid().v4(),
      name: name ?? '测试员工',
      avatar: avatar ?? 'https://example.com/avatar.png',
      role: role ?? 'assistant',
      status: status ?? 'active',
      description: description ?? '这是一个测试员工',
      systemPrompt: systemPrompt ?? '你是一个AI助手',
      provider: provider ?? 'openai',
      model: model ?? 'gpt-4',
      apiKey: apiKey ?? 'sk-test-key',
      apiBaseUrl: apiBaseUrl ?? 'https://api.openai.com/v1',
      modelConfig: modelConfig ?? '{"temperature": 0.7}',
      enableTools: enableTools ?? 1,
      enableMcp: enableMcp ?? 0,
      projectUuid: projectUuid ?? 'proj-001',
      projectName: projectName ?? '测试项目',
      projectContext: projectContext ?? '项目上下文',
      workPath: workPath ?? '/home/user/project',
      mcpConfig: mcpConfig,
      permissionConfig:
          permissionConfig ?? '{"allowedTools": ["*"]}',
      deviceId: deviceId ?? 'dev-001',
      currentDeviceId: currentDeviceId ?? 'dev-001',
      autoApprove: autoApprove ?? 0,
      sortOrder: sortOrder ?? 0,
      isPinned: isPinned ?? 0,
      deleted: deleted ?? 0,
      deletedTime: deletedTime,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  // ═══════════════════════════════════════════════════
  // A. toMap/fromMap 所有字段零丢失
  // ═══════════════════════════════════════════════════

  group('A. toMap/fromMap 序列化往返', () {
    test('完整字段往返 - 零丢失', () {
      final original = createFullEmployee();
      final map = original.toMap();
      final restored = AiEmployeeEntity.fromMap(map);

      // 所有字段逐一比较
      expect(restored.uuid, equals(original.uuid));
      expect(restored.name, equals(original.name));
      expect(restored.avatar, equals(original.avatar));
      expect(restored.role, equals(original.role));
      expect(restored.status, equals(original.status));
      expect(restored.description, equals(original.description));
      expect(restored.systemPrompt, equals(original.systemPrompt));
      expect(restored.provider, equals(original.provider));
      expect(restored.model, equals(original.model));
      expect(restored.apiKey, equals(original.apiKey));
      expect(restored.apiBaseUrl, equals(original.apiBaseUrl));
      expect(restored.modelConfig, equals(original.modelConfig));
      expect(restored.enableTools, equals(original.enableTools));
      expect(restored.enableMcp, equals(original.enableMcp));
      expect(restored.projectUuid, equals(original.projectUuid));
      expect(restored.projectName, equals(original.projectName));
      expect(restored.projectContext, equals(original.projectContext));
      expect(restored.workPath, equals(original.workPath));
      expect(restored.mcpConfig, equals(original.mcpConfig));
      expect(restored.permissionConfig, equals(original.permissionConfig));
      expect(restored.deviceId, equals(original.deviceId));
      expect(restored.currentDeviceId, equals(original.currentDeviceId));
      expect(restored.autoApprove, equals(original.autoApprove));
      expect(restored.sortOrder, equals(original.sortOrder));
      expect(restored.isPinned, equals(original.isPinned));
      expect(restored.deleted, equals(original.deleted));
      expect(restored.deletedTime, isNull); // 原始为 null
      expect(
        restored.createTime.millisecondsSinceEpoch,
        equals(original.createTime.millisecondsSinceEpoch),
      );
      expect(
        restored.updateTime.millisecondsSinceEpoch,
        equals(original.updateTime.millisecondsSinceEpoch),
      );
    });

    test('完整字段往返 - 含 deletedTime', () {
      final deleteTime = DateTime(2024, 6, 15, 10, 30, 0);
      final original = createFullEmployee(
        deleted: 1,
        deletedTime: deleteTime,
      );
      final map = original.toMap();
      final restored = AiEmployeeEntity.fromMap(map);

      expect(restored.deleted, equals(1));
      expect(restored.deletedTime, isNotNull);
      expect(
        restored.deletedTime!.millisecondsSinceEpoch,
        equals(deleteTime.millisecondsSinceEpoch),
      );
    });

    test('null 字段正确处理', () {
      final original = AiEmployeeEntity(
        uuid: 'test-uuid',
        name: '最小员工',
        createTime: now,
        updateTime: now,
      );
      final map = original.toMap();
      final restored = AiEmployeeEntity.fromMap(map);

      expect(restored.uuid, equals('test-uuid'));
      expect(restored.name, equals('最小员工'));
      expect(restored.avatar, isNull);
      expect(restored.description, isNull);
      expect(restored.systemPrompt, isNull);
      expect(restored.provider, isNull);
      expect(restored.model, isNull);
      expect(restored.apiKey, isNull);
      expect(restored.apiBaseUrl, isNull);
      expect(restored.modelConfig, isNull);
      expect(restored.projectUuid, isNull);
      expect(restored.projectName, isNull);
      expect(restored.projectContext, isNull);
      expect(restored.workPath, isNull);
      expect(restored.mcpConfig, isNull);
      expect(restored.permissionConfig, isNull);
      expect(restored.deviceId, isNull);
      expect(restored.currentDeviceId, isNull);
      expect(restored.deletedTime, isNull);
      // 默认值
      expect(restored.role, equals('assistant'));
      expect(restored.status, equals('active'));
      expect(restored.enableTools, equals(1));
      expect(restored.enableMcp, equals(0));
      expect(restored.autoApprove, equals(0));
      expect(restored.sortOrder, equals(0));
      expect(restored.isPinned, equals(0));
      expect(restored.deleted, equals(0));
    });

    test('toMap 输出类型正确', () {
      final original = createFullEmployee(
        deletedTime: DateTime(2024, 1, 1),
      );
      final map = original.toMap();

      expect(map['uuid'], isA<String>());
      expect(map['name'], isA<String>());
      expect(map['avatar'], isA<String>());
      expect(map['role'], isA<String>());
      expect(map['enableTools'], isA<int>());
      expect(map['enableMcp'], isA<int>());
      expect(map['deleted'], isA<int>());
      expect(map['deletedTime'], isA<int>());
      expect(map['createTime'], isA<int>());
      expect(map['updateTime'], isA<int>());
    });

    test('fromMap 支持 DateTime 对象类型', () {
      final map = <String, dynamic>{
        'uuid': 'test-uuid',
        'name': '测试',
        'createTime': now,
        'updateTime': now,
        'deletedTime': later,
      };
      final restored = AiEmployeeEntity.fromMap(map);

      expect(restored.createTime, equals(now));
      expect(restored.updateTime, equals(now));
      expect(restored.deletedTime, equals(later));
    });

    test('fromMap 默认值正确', () {
      final map = <String, dynamic>{
        'uuid': 'test-uuid',
        'name': '测试',
        'createTime': now.millisecondsSinceEpoch,
        'updateTime': now.millisecondsSinceEpoch,
      };
      final restored = AiEmployeeEntity.fromMap(map);

      expect(restored.role, equals('assistant'));
      expect(restored.status, equals('active'));
      expect(restored.enableTools, equals(1));
      expect(restored.enableMcp, equals(0));
      expect(restored.autoApprove, equals(0));
      expect(restored.sortOrder, equals(0));
      expect(restored.isPinned, equals(0));
      expect(restored.deleted, equals(0));
      expect(restored.deletedTime, isNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // B. copyWith 各字段独立覆盖
  // ═══════════════════════════════════════════════════

  group('B. copyWith 各字段独立覆盖', () {
    late AiEmployeeEntity base;

    setUp(() {
      base = createFullEmployee();
    });

    test('copyWith - name 覆盖', () {
      final updated = base.copyWith(name: '新名字');
      expect(updated.name, equals('新名字'));
      expect(updated.uuid, equals(base.uuid));
      expect(updated.role, equals(base.role));
    });

    test('copyWith - provider 相关字段覆盖', () {
      final updated = base.copyWith(
        provider: 'claude',
        model: 'claude-3-opus',
        apiKey: 'sk-new-key',
        apiBaseUrl: 'https://api.anthropic.com',
      );
      expect(updated.provider, equals('claude'));
      expect(updated.model, equals('claude-3-opus'));
      expect(updated.apiKey, equals('sk-new-key'));
      expect(updated.apiBaseUrl, equals('https://api.anthropic.com'));
      // 其他字段不变
      expect(updated.name, equals(base.name));
    });

    test('copyWith - project 相关字段覆盖', () {
      final updated = base.copyWith(
        projectUuid: 'proj-002',
        projectName: '新项目',
        projectContext: '新上下文',
        workPath: '/new/path',
      );
      expect(updated.projectUuid, equals('proj-002'));
      expect(updated.projectName, equals('新项目'));
      expect(updated.projectContext, equals('新上下文'));
      expect(updated.workPath, equals('/new/path'));
    });

    test('copyWith - deleted/deletedTime 覆盖', () {
      final deleteTime = DateTime(2024, 12, 31);
      final updated = base.copyWith(deleted: 1, deletedTime: deleteTime);
      expect(updated.deleted, equals(1));
      expect(updated.deletedTime, equals(deleteTime));
    });

    test('copyWith - deviceId/currentDeviceId 覆盖', () {
      final updated = base.copyWith(
        deviceId: 'dev-002',
        currentDeviceId: 'dev-003',
      );
      expect(updated.deviceId, equals('dev-002'));
      expect(updated.currentDeviceId, equals('dev-003'));
    });

    test('copyWith - 不传参保持原值', () {
      final copied = base.copyWith();
      expect(copied.uuid, equals(base.uuid));
      expect(copied.name, equals(base.name));
      expect(copied.provider, equals(base.provider));
      expect(copied.model, equals(base.model));
      expect(copied.deleted, equals(base.deleted));
      expect(copied.deletedTime, equals(base.deletedTime));
    });

    test('copyWith - status 覆盖', () {
      final updated = base.copyWith(status: 'inactive');
      expect(updated.status, equals('inactive'));
    });

    test('copyWith - mcpConfig/permissionConfig 覆盖', () {
      final newMcpConfig = jsonEncode([
        {'name': 'test-server', 'transportType': 'stdio', 'command': 'node'}
      ]);
      final newPermissionConfig = jsonEncode({
        'allowedTools': ['file_read'],
      });
      final updated = base.copyWith(
        mcpConfig: newMcpConfig,
        permissionConfig: newPermissionConfig,
      );
      expect(updated.mcpConfig, equals(newMcpConfig));
      expect(updated.permissionConfig, equals(newPermissionConfig));
    });
  });

  // ═══════════════════════════════════════════════════
  // C. deletedTime null 和非 null 场景
  // ═══════════════════════════════════════════════════

  group('C. deletedTime 场景', () {
    test('deletedTime 为 null 时 toMap 输出 null', () {
      final emp = createFullEmployee(deleted: 0, deletedTime: null);
      final map = emp.toMap();
      expect(map['deletedTime'], isNull);
    });

    test('deletedTime 有值时 toMap 输出毫秒时间戳', () {
      final dt = DateTime(2024, 6, 15, 10, 30, 0);
      final emp = createFullEmployee(deleted: 1, deletedTime: dt);
      final map = emp.toMap();
      expect(map['deletedTime'], equals(dt.millisecondsSinceEpoch));
    });

    test('deletedTime 毫秒时间戳 → fromMap 正确还原', () {
      final dt = DateTime(2024, 6, 15, 10, 30, 0);
      final emp = createFullEmployee(deleted: 1, deletedTime: dt);
      final restored = AiEmployeeEntity.fromMap(emp.toMap());
      expect(
        restored.deletedTime!.millisecondsSinceEpoch,
        equals(dt.millisecondsSinceEpoch),
      );
    });

    test('deletedTime DateTime 对象 → fromMap 正确还原', () {
      final dt = DateTime(2024, 6, 15, 10, 30, 0);
      final map = <String, dynamic>{
        'uuid': 'test-uuid',
        'name': '测试',
        'deleted': 1,
        'deletedTime': dt,
        'createTime': now.millisecondsSinceEpoch,
        'updateTime': now.millisecondsSinceEpoch,
      };
      final restored = AiEmployeeEntity.fromMap(map);
      expect(restored.deletedTime, equals(dt));
    });

    test('deleted=0 + deletedTime=null → 正常状态', () {
      final emp = createFullEmployee(deleted: 0, deletedTime: null);
      expect(emp.deleted, equals(0));
      expect(emp.deletedTime, isNull);
    });

    test('deleted=1 + deletedTime 有值 → 软删除状态', () {
      final dt = DateTime(2024, 6, 15);
      final emp = createFullEmployee(deleted: 1, deletedTime: dt);
      expect(emp.deleted, equals(1));
      expect(emp.deletedTime, isNotNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // D. getMcpConfigs / setMcpConfigs 方法
  // ═══════════════════════════════════════════════════

  group('D. getMcpConfigs / setMcpConfigs', () {
    test('getMcpConfigs - mcpConfig 为 null 返回空列表', () {
      final emp = createFullEmployee(mcpConfig: null);
      expect(emp.getMcpConfigs(), isEmpty);
    });

    test('getMcpConfigs - mcpConfig 为空字符串返回空列表', () {
      final emp = createFullEmployee(mcpConfig: '');
      expect(emp.getMcpConfigs(), isEmpty);
    });

    test('getMcpConfigs - 新格式 List JSON', () {
      final configs = [
        McpServerConfig.stdio(name: 'server1', command: 'node'),
        McpServerConfig.sse(name: 'server2', url: 'http://localhost:3000'),
      ];
      final json = McpServerConfig.toJsonString(configs);
      final emp = createFullEmployee(mcpConfig: json);

      final parsed = emp.getMcpConfigs();
      expect(parsed.length, equals(2));
      expect(parsed[0].name, equals('server1'));
      expect(parsed[0].transportType, equals('stdio'));
      expect(parsed[0].command, equals('node'));
      expect(parsed[1].name, equals('server2'));
      expect(parsed[1].transportType, equals('sse'));
      expect(parsed[1].url, equals('http://localhost:3000'));
    });

    test('getMcpConfigs - 旧格式 Map JSON 兼容', () {
      final legacyJson = jsonEncode({
        'filesystem': {
          'command': 'npx',
          'args': ['-y', '@modelcontextprotocol/server-filesystem'],
        },
        'web-server': {
          'url': 'http://localhost:8080',
          'transportType': 'sse',
        },
      });
      final emp = createFullEmployee(mcpConfig: legacyJson);

      final parsed = emp.getMcpConfigs();
      expect(parsed.length, equals(2));

      final fs = parsed.firstWhere((c) => c.name == 'filesystem');
      expect(fs.command, equals('npx'));
      expect(fs.args, equals(['-y', '@modelcontextprotocol/server-filesystem']));
      expect(fs.transportType, equals('stdio')); // 旧格式默认 stdio

      final web = parsed.firstWhere((c) => c.name == 'web-server');
      expect(web.url, equals('http://localhost:8080'));
      expect(web.transportType, equals('sse'));
    });

    test('getMcpConfigs - 无效 JSON 返回空列表', () {
      final emp = createFullEmployee(mcpConfig: 'not-valid-json');
      expect(emp.getMcpConfigs(), isEmpty);
    });

    test('setMcpConfigs - 设置并序列化', () {
      final emp = createFullEmployee();
      expect(emp.mcpConfig, isNull);

      final configs = [
        McpServerConfig.stdio(name: 'test', command: 'node'),
      ];
      final updated = emp.setMcpConfigs(configs);

      // mcpConfig 已更新为 JSON 字符串
      expect(updated.mcpConfig, isNotNull);
      final parsed = updated.getMcpConfigs();
      expect(parsed.length, equals(1));
      expect(parsed[0].name, equals('test'));

      // updateTime 已更新
      expect(
        updated.updateTime.millisecondsSinceEpoch,
        greaterThanOrEqualTo(emp.updateTime.millisecondsSinceEpoch),
      );
    });

    test('setMcpConfigs → getMcpConfigs 往返一致性', () {
      final original = [
        McpServerConfig.stdio(
          name: 'server1',
          command: 'npx',
          args: ['-y', 'some-package'],
          env: {'KEY': 'VALUE'},
        ),
        McpServerConfig.http(
          name: 'server2',
          url: 'http://localhost:4000',
          headers: {'Authorization': 'Bearer token'},
        ),
      ];

      final emp = createFullEmployee();
      final updated = emp.setMcpConfigs(original);
      final parsed = updated.getMcpConfigs();

      expect(parsed.length, equals(original.length));
      for (int i = 0; i < original.length; i++) {
        expect(parsed[i].name, equals(original[i].name));
        expect(parsed[i].transportType, equals(original[i].transportType));
      }
    });
  });

  // ═══════════════════════════════════════════════════
  // E. isMcpEnabled getter
  // ═══════════════════════════════════════════════════

  group('E. isMcpEnabled', () {
    test('enableMcp = 0 → isMcpEnabled = false', () {
      final emp = createFullEmployee(enableMcp: 0);
      expect(emp.isMcpEnabled, isFalse);
    });

    test('enableMcp = 1 → isMcpEnabled = true', () {
      final emp = createFullEmployee(enableMcp: 1);
      expect(emp.isMcpEnabled, isTrue);
    });
  });

  // ═══════════════════════════════════════════════════
  // F. toString
  // ═══════════════════════════════════════════════════

  group('F. toString', () {
    test('toString 包含关键信息', () {
      final emp = createFullEmployee(
        uuid: 'test-uuid-123',
        name: '测试AI',
        provider: 'openai',
        model: 'gpt-4',
      );
      final str = emp.toString();
      expect(str, contains('test-uuid-123'));
      expect(str, contains('测试AI'));
      expect(str, contains('openai'));
      expect(str, contains('gpt-4'));
    });
  });
}
