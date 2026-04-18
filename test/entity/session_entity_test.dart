import 'package:test/test.dart';
import 'package:wenzagent/src/persistence/persistence.dart';

/// Session Entity 序列化往返测试
///
/// 验证：
/// - A. toMap/fromMap 含 config[deviceId] 嵌套结构
/// - B. fromLegacyMap 旧格式兼容
/// - C. isEffectivelyDeleted 边界条件
/// - D. getOrCreateConfig 幂等性
/// - E. getConfig 返回 null 和正确值
/// - F. copyWith 各字段覆盖
/// - G. 空 config 的 session 序列化
void main() {
  final now = DateTime.now();
  final later = now.add(const Duration(hours: 1));

  AiEmployeeSessionEntity createSession({
    String? employeeId,
    Map<String, DeviceSessionConfig>? config,
    String? title,
    int? isArchived,
    int? isPinned,
    int? deleted,
    DateTime? deleteTime,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return AiEmployeeSessionEntity(
      employeeId: employeeId ?? 'emp-001',
      config: config,
      title: title ?? '新对话',
      isArchived: isArchived ?? 0,
      isPinned: isPinned ?? 0,
      deleted: deleted ?? 0,
      deleteTime: deleteTime,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  DeviceSessionConfig createDeviceConfig({
    String? projectUuid,
    String? providerConfig,
    String? systemPromptOverride,
    String? contextData,
    int? totalInputTokens,
    int? totalOutputTokens,
    int? totalMessageCount,
    DateTime? updateTime,
  }) {
    return DeviceSessionConfig(
      projectUuid: projectUuid,
      providerConfig: providerConfig ?? '{"provider":"openai","model":"gpt-4"}',
      systemPromptOverride: systemPromptOverride,
      contextData: contextData,
      totalInputTokens: totalInputTokens ?? 0,
      totalOutputTokens: totalOutputTokens ?? 0,
      totalMessageCount: totalMessageCount ?? 0,
      updateTime: updateTime ?? now,
    );
  }

  // ═══════════════════════════════════════════════════
  // A. toMap/fromMap 含 config[deviceId] 嵌套结构
  // ═══════════════════════════════════════════════════

  group('A. toMap/fromMap 序列化往返', () {
    test('空 config session 往返', () {
      final original = createSession();
      final map = original.toMap();
      final restored = AiEmployeeSessionEntity.fromMap(map);

      expect(restored.employeeId, equals(original.employeeId));
      expect(restored.title, equals(original.title));
      expect(restored.isArchived, equals(original.isArchived));
      expect(restored.isPinned, equals(original.isPinned));
      expect(restored.deleted, equals(original.deleted));
      expect(restored.deleteTime, isNull);
      expect(restored.config, isEmpty);
    });

    test('单设备 config 往返', () {
      final config = createDeviceConfig(
        providerConfig: '{"provider":"openai","model":"gpt-4"}',
        systemPromptOverride: '你是一个助手',
        totalInputTokens: 100,
        totalOutputTokens: 200,
        totalMessageCount: 5,
      );
      final original = createSession(
        config: {'dev-001': config},
      );

      final map = original.toMap();
      final restored = AiEmployeeSessionEntity.fromMap(map);

      expect(restored.config.length, equals(1));
      expect(restored.config.containsKey('dev-001'), isTrue);

      final rc = restored.config['dev-001']!;
      expect(rc.providerConfig, equals(config.providerConfig));
      expect(rc.systemPromptOverride, equals('你是一个助手'));
      expect(rc.totalInputTokens, equals(100));
      expect(rc.totalOutputTokens, equals(200));
      expect(rc.totalMessageCount, equals(5));
    });

    test('多设备 config 往返', () {
      final configA = createDeviceConfig(
        providerConfig: '{"provider":"openai"}',
        totalInputTokens: 50,
      );
      final configB = createDeviceConfig(
        providerConfig: '{"provider":"claude"}',
        totalInputTokens: 80,
      );
      final original = createSession(
        config: {
          'dev-A': configA,
          'dev-B': configB,
        },
      );

      final map = original.toMap();
      final restored = AiEmployeeSessionEntity.fromMap(map);

      expect(restored.config.length, equals(2));
      expect(restored.config['dev-A']!.providerConfig, equals('{"provider":"openai"}'));
      expect(restored.config['dev-A']!.totalInputTokens, equals(50));
      expect(restored.config['dev-B']!.providerConfig, equals('{"provider":"claude"}'));
      expect(restored.config['dev-B']!.totalInputTokens, equals(80));
    });

    test('含 deleteTime 往返', () {
      final dt = DateTime(2024, 6, 15, 10, 30, 0);
      final original = createSession(
        deleted: 1,
        deleteTime: dt,
      );
      final map = original.toMap();
      final restored = AiEmployeeSessionEntity.fromMap(map);

      expect(restored.deleted, equals(1));
      expect(restored.deleteTime, isNotNull);
      expect(
        restored.deleteTime!.millisecondsSinceEpoch,
        equals(dt.millisecondsSinceEpoch),
      );
    });

    test('时间字段毫秒精度保持', () {
      final ct = DateTime(2024, 1, 1, 0, 0, 0, 123);
      final ut = DateTime(2024, 6, 15, 12, 30, 45, 678);
      final original = createSession(createTime: ct, updateTime: ut);
      final restored = AiEmployeeSessionEntity.fromMap(original.toMap());

      expect(
        restored.createTime.millisecondsSinceEpoch,
        equals(ct.millisecondsSinceEpoch),
      );
      expect(
        restored.updateTime.millisecondsSinceEpoch,
        equals(ut.millisecondsSinceEpoch),
      );
    });

    test('DeviceSessionConfig updateTime 支持 DateTime 对象', () {
      final map = <String, dynamic>{
        'employeeId': 'emp-001',
        'config': {
          'dev-001': {
            'providerConfig': '{"provider":"openai"}',
            'updateTime': later,
          },
        },
        'title': '测试',
        'createTime': now.millisecondsSinceEpoch,
        'updateTime': now.millisecondsSinceEpoch,
      };
      final restored = AiEmployeeSessionEntity.fromMap(map);
      expect(restored.config['dev-001']!.updateTime, equals(later));
    });
  });

  // ═══════════════════════════════════════════════════
  // B. fromLegacyMap 旧格式兼容
  // ═══════════════════════════════════════════════════

  group('B. fromLegacyMap 旧格式兼容', () {
    test('旧格式顶层字段迁移到 config[空字符串]', () {
      final legacyMap = <String, dynamic>{
        'employeeId': 'emp-legacy',
        'providerConfig': '{"provider":"openai","model":"gpt-3.5"}',
        'projectUuid': 'proj-legacy',
        'contextData': '{"key":"value"}',
        'inputTokens': 500,
        'outputTokens': 300,
        'messageCount': 10,
        'title': '旧格式会话',
        'isArchived': 1,
        'isPinned': 1,
        'deleted': 0,
        'createTime': now.millisecondsSinceEpoch,
        'updateTime': now.millisecondsSinceEpoch,
      };

      final restored = AiEmployeeSessionEntity.fromLegacyMap(legacyMap);

      expect(restored.employeeId, equals('emp-legacy'));
      expect(restored.title, equals('旧格式会话'));
      expect(restored.isArchived, equals(1));
      expect(restored.isPinned, equals(1));
      // 旧字段迁移到 config['']
      expect(restored.config.containsKey(''), isTrue);
      final config = restored.config['']!;
      expect(config.providerConfig, equals('{"provider":"openai","model":"gpt-3.5"}'));
      expect(config.projectUuid, equals('proj-legacy'));
      expect(config.contextData, equals('{"key":"value"}'));
      expect(config.totalInputTokens, equals(500));
      expect(config.totalOutputTokens, equals(300));
      expect(config.totalMessageCount, equals(10));
    });

    test('旧格式 uuid 字段作为 employeeId', () {
      final legacyMap = <String, dynamic>{
        'uuid': 'uuid-as-emp-id',
        'title': 'UUID格式',
        'createTime': now.millisecondsSinceEpoch,
        'updateTime': now.millisecondsSinceEpoch,
      };
      final restored = AiEmployeeSessionEntity.fromLegacyMap(legacyMap);
      expect(restored.employeeId, equals('uuid-as-emp-id'));
    });

    test('旧格式无 providerConfig 时 config 为空', () {
      final legacyMap = <String, dynamic>{
        'employeeId': 'emp-no-config',
        'title': '无配置',
        'createTime': now.millisecondsSinceEpoch,
        'updateTime': now.millisecondsSinceEpoch,
      };
      final restored = AiEmployeeSessionEntity.fromLegacyMap(legacyMap);
      expect(restored.config, isEmpty);
    });

    test('旧格式含 deleteTime', () {
      final dt = DateTime(2024, 3, 1);
      final legacyMap = <String, dynamic>{
        'employeeId': 'emp-deleted',
        'deleted': 1,
        'deleteTime': dt.millisecondsSinceEpoch,
        'createTime': now.millisecondsSinceEpoch,
        'updateTime': now.millisecondsSinceEpoch,
      };
      final restored = AiEmployeeSessionEntity.fromLegacyMap(legacyMap);
      expect(restored.deleted, equals(1));
      expect(
        restored.deleteTime!.millisecondsSinceEpoch,
        equals(dt.millisecondsSinceEpoch),
      );
    });
  });

  // ═══════════════════════════════════════════════════
  // C. isEffectivelyDeleted 边界条件
  // ═══════════════════════════════════════════════════

  group('C. isEffectivelyDeleted', () {
    test('deleted=0 → false（正常状态）', () {
      final session = createSession(deleted: 0);
      expect(session.isEffectivelyDeleted(), isFalse);
    });

    test('deleted=1, deleteTime=null → true（无删除时间仍视为已删除）', () {
      final session = createSession(deleted: 1, deleteTime: null);
      expect(session.isEffectivelyDeleted(), isTrue);
    });

    test('deleted=1, deleteTime >= updateTime → true（已删除）', () {
      final ct = DateTime(2024, 1, 1);
      final ut = DateTime(2024, 6, 1);
      final dt = DateTime(2024, 6, 15); // deleteTime > updateTime
      final session = createSession(
        deleted: 1,
        deleteTime: dt,
        createTime: ct,
        updateTime: ut,
      );
      expect(session.isEffectivelyDeleted(), isTrue);
    });

    test('deleted=1, deleteTime == updateTime → true（相等仍视为已删除）', () {
      final t = DateTime(2024, 6, 15);
      final session = createSession(
        deleted: 1,
        deleteTime: t,
        updateTime: t,
      );
      expect(session.isEffectivelyDeleted(), isTrue);
    });

    test('deleted=1, updateTime > deleteTime → false（已复活）', () {
      final dt = DateTime(2024, 6, 1);
      final ut = DateTime(2024, 6, 15); // updateTime > deleteTime
      final session = createSession(
        deleted: 1,
        deleteTime: dt,
        updateTime: ut,
      );
      expect(session.isEffectivelyDeleted(), isFalse);
    });

    test('deleted=1, updateTime 毫秒级 > deleteTime → false（复活）', () {
      final dt = DateTime(2024, 6, 15, 10, 0, 0, 0);
      final ut = DateTime(2024, 6, 15, 10, 0, 0, 1); // 多1毫秒
      final session = createSession(
        deleted: 1,
        deleteTime: dt,
        updateTime: ut,
      );
      expect(session.isEffectivelyDeleted(), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════
  // D. getOrCreateConfig 幂等性
  // ═══════════════════════════════════════════════════

  group('D. getOrCreateConfig', () {
    test('不存在时自动创建', () {
      final session = createSession();
      expect(session.config.containsKey('dev-new'), isFalse);

      final config = session.getOrCreateConfig('dev-new');
      expect(config, isNotNull);
      expect(session.config.containsKey('dev-new'), isTrue);
    });

    test('多次调用返回同一对象', () {
      final session = createSession();
      final config1 = session.getOrCreateConfig('dev-001');
      final config2 = session.getOrCreateConfig('dev-001');
      expect(identical(config1, config2), isTrue);
    });

    test('已存在的 config 不被覆盖', () {
      final original = createDeviceConfig(
        providerConfig: '{"provider":"openai"}',
        totalInputTokens: 42,
      );
      final session = createSession(config: {'dev-001': original});

      final fetched = session.getOrCreateConfig('dev-001');
      expect(identical(fetched, original), isTrue);
      expect(fetched.totalInputTokens, equals(42));
    });

    test('新创建的 config 有合理的默认值', () {
      final session = createSession();
      final config = session.getOrCreateConfig('dev-new');
      expect(config.providerConfig, isNull);
      expect(config.systemPromptOverride, isNull);
      expect(config.contextData, isNull);
      expect(config.totalInputTokens, equals(0));
      expect(config.totalOutputTokens, equals(0));
      expect(config.totalMessageCount, equals(0));
      expect(config.updateTime, isNotNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // E. getConfig 返回 null 和正确值
  // ═══════════════════════════════════════════════════

  group('E. getConfig', () {
    test('不存在返回 null', () {
      final session = createSession();
      expect(session.getConfig('nonexistent'), isNull);
    });

    test('返回正确的 config', () {
      final config = createDeviceConfig(
        providerConfig: '{"provider":"claude"}',
      );
      final session = createSession(config: {'dev-001': config});
      final fetched = session.getConfig('dev-001');
      expect(fetched, isNotNull);
      expect(fetched!.providerConfig, equals('{"provider":"claude"}'));
    });

    test('多设备 config 独立访问', () {
      final configA = createDeviceConfig(providerConfig: '{"provider":"openai"}');
      final configB = createDeviceConfig(providerConfig: '{"provider":"claude"}');
      final session = createSession(config: {
        'dev-A': configA,
        'dev-B': configB,
      });

      expect(session.getConfig('dev-A')!.providerConfig, contains('openai'));
      expect(session.getConfig('dev-B')!.providerConfig, contains('claude'));
      expect(session.getConfig('dev-C'), isNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // F. copyWith 各字段覆盖
  // ═══════════════════════════════════════════════════

  group('F. copyWith', () {
    test('title 覆盖', () {
      final session = createSession(title: '旧标题');
      final updated = session.copyWith(title: '新标题');
      expect(updated.title, equals('新标题'));
      expect(updated.employeeId, equals(session.employeeId));
    });

    test('config 覆盖', () {
      final session = createSession();
      final newConfig = {'dev-X': createDeviceConfig()};
      final updated = session.copyWith(config: newConfig);
      expect(updated.config.length, equals(1));
      expect(updated.config.containsKey('dev-X'), isTrue);
    });

    test('deleted/deleteTime 覆盖', () {
      final dt = DateTime(2024, 12, 31);
      final session = createSession(deleted: 0);
      final updated = session.copyWith(deleted: 1, deleteTime: dt);
      expect(updated.deleted, equals(1));
      expect(updated.deleteTime, equals(dt));
    });

    test('isArchived/isPinned 覆盖', () {
      final session = createSession(isArchived: 0, isPinned: 0);
      final updated = session.copyWith(isArchived: 1, isPinned: 1);
      expect(updated.isArchived, equals(1));
      expect(updated.isPinned, equals(1));
    });

    test('不传参保持原值', () {
      final original = createSession(
        title: '原始标题',
        isArchived: 1,
        deleted: 0,
      );
      final copied = original.copyWith();
      expect(copied.title, equals('原始标题'));
      expect(copied.isArchived, equals(1));
      expect(copied.deleted, equals(0));
      expect(copied.employeeId, equals(original.employeeId));
    });
  });

  // ═══════════════════════════════════════════════════
  // G. toString
  // ═══════════════════════════════════════════════════

  group('G. toString', () {
    test('包含关键信息', () {
      final session = createSession(
        employeeId: 'emp-123',
        title: '测试会话',
        config: {
          'dev-A': createDeviceConfig(),
          'dev-B': createDeviceConfig(),
        },
      );
      final str = session.toString();
      expect(str, contains('emp-123'));
      expect(str, contains('测试会话'));
      expect(str, contains('dev-A'));
      expect(str, contains('dev-B'));
    });
  });
}
