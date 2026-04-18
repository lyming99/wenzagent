import 'package:test/test.dart';
import 'package:wenzagent/src/persistence/persistence.dart';

/// DeviceSessionConfig 序列化测试
///
/// 验证：
/// - A. fromMap/toMap 往返零丢失
/// - B. updateTime 支持 DateTime 和 int
/// - C. copyWith 各字段覆盖
/// - D. 默认值验证
void main() {
  final now = DateTime.now();

  DeviceSessionConfig createConfig({
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
      providerConfig: providerConfig,
      systemPromptOverride: systemPromptOverride,
      contextData: contextData,
      totalInputTokens: totalInputTokens ?? 0,
      totalOutputTokens: totalOutputTokens ?? 0,
      totalMessageCount: totalMessageCount ?? 0,
      updateTime: updateTime ?? now,
    );
  }

  // ═══════════════════════════════════════════════════
  // A. fromMap/toMap 往返零丢失
  // ═══════════════════════════════════════════════════

  group('A. fromMap/toMap 往返', () {
    test('完整字段往返', () {
      final original = createConfig(
        projectUuid: 'proj-001',
        providerConfig: '{"provider":"openai","model":"gpt-4"}',
        systemPromptOverride: '你是一个AI助手',
        contextData: '{"workspace":"/home/user"}',
        totalInputTokens: 1000,
        totalOutputTokens: 2000,
        totalMessageCount: 50,
      );
      final map = original.toMap();
      final restored = DeviceSessionConfig.fromMap(map);

      expect(restored.projectUuid, equals('proj-001'));
      expect(restored.providerConfig, equals('{"provider":"openai","model":"gpt-4"}'));
      expect(restored.systemPromptOverride, equals('你是一个AI助手'));
      expect(restored.contextData, equals('{"workspace":"/home/user"}'));
      expect(restored.totalInputTokens, equals(1000));
      expect(restored.totalOutputTokens, equals(2000));
      expect(restored.totalMessageCount, equals(50));
      expect(
        restored.updateTime.millisecondsSinceEpoch,
        equals(original.updateTime.millisecondsSinceEpoch),
      );
    });

    test('所有字段为 null 的往返', () {
      final original = DeviceSessionConfig(updateTime: now);
      final map = original.toMap();
      final restored = DeviceSessionConfig.fromMap(map);

      expect(restored.projectUuid, isNull);
      expect(restored.providerConfig, isNull);
      expect(restored.systemPromptOverride, isNull);
      expect(restored.contextData, isNull);
      expect(restored.totalInputTokens, equals(0));
      expect(restored.totalOutputTokens, equals(0));
      expect(restored.totalMessageCount, equals(0));
    });

    test('toMap 输出类型正确', () {
      final config = createConfig(
        providerConfig: '{"provider":"openai"}',
        totalInputTokens: 100,
      );
      final map = config.toMap();

      expect(map['projectUuid'], isNull);
      expect(map['providerConfig'], isA<String>());
      expect(map['totalInputTokens'], isA<int>());
      expect(map['totalOutputTokens'], isA<int>());
      expect(map['totalMessageCount'], isA<int>());
      expect(map['updateTime'], isA<int>()); // 毫秒时间戳
    });
  });

  // ═══════════════════════════════════════════════════
  // B. updateTime 支持 DateTime 和 int
  // ═══════════════════════════════════════════════════

  group('B. updateTime 类型兼容', () {
    test('fromMap - updateTime 为 int (毫秒时间戳)', () {
      final ts = DateTime(2024, 6, 15, 10, 30, 0).millisecondsSinceEpoch;
      final map = <String, dynamic>{
        'updateTime': ts,
      };
      final config = DeviceSessionConfig.fromMap(map);
      expect(config.updateTime.millisecondsSinceEpoch, equals(ts));
    });

    test('fromMap - updateTime 为 DateTime 对象', () {
      final dt = DateTime(2024, 6, 15, 10, 30, 0);
      final map = <String, dynamic>{
        'updateTime': dt,
      };
      final config = DeviceSessionConfig.fromMap(map);
      expect(config.updateTime, equals(dt));
    });

    test('fromMap - updateTime 缺失时默认为 epoch 0', () {
      final map = <String, dynamic>{};
      final config = DeviceSessionConfig.fromMap(map);
      expect(config.updateTime.millisecondsSinceEpoch, equals(0));
    });

    test('toMap 始终输出 int', () {
      final config = DeviceSessionConfig(updateTime: now);
      final map = config.toMap();
      expect(map['updateTime'], isA<int>());
      expect(map['updateTime'], equals(now.millisecondsSinceEpoch));
    });
  });

  // ═══════════════════════════════════════════════════
  // C. copyWith 各字段覆盖
  // ═══════════════════════════════════════════════════

  group('C. copyWith', () {
    test('providerConfig 覆盖', () {
      final original = createConfig(providerConfig: '{"provider":"openai"}');
      final updated = original.copyWith(
        providerConfig: '{"provider":"claude"}',
      );
      expect(updated.providerConfig, equals('{"provider":"claude"}'));
      expect(updated.systemPromptOverride, equals(original.systemPromptOverride));
    });

    test('systemPromptOverride 覆盖', () {
      final original = createConfig(systemPromptOverride: '旧提示词');
      final updated = original.copyWith(systemPromptOverride: '新提示词');
      expect(updated.systemPromptOverride, equals('新提示词'));
    });

    test('contextData 覆盖', () {
      final original = createConfig(contextData: '{"old":true}');
      final updated = original.copyWith(contextData: '{"new":true}');
      expect(updated.contextData, equals('{"new":true}'));
    });

    test('统计字段覆盖', () {
      final original = createConfig(
        totalInputTokens: 100,
        totalOutputTokens: 200,
        totalMessageCount: 10,
      );
      final updated = original.copyWith(
        totalInputTokens: 500,
        totalOutputTokens: 800,
        totalMessageCount: 30,
      );
      expect(updated.totalInputTokens, equals(500));
      expect(updated.totalOutputTokens, equals(800));
      expect(updated.totalMessageCount, equals(30));
    });

    test('updateTime 覆盖', () {
      final original = createConfig(updateTime: now);
      final later = now.add(const Duration(hours: 1));
      final updated = original.copyWith(updateTime: later);
      expect(updated.updateTime, equals(later));
    });

    test('不传参保持原值', () {
      final original = createConfig(
        providerConfig: '{"provider":"openai"}',
        systemPromptOverride: '提示词',
        totalInputTokens: 42,
      );
      final copied = original.copyWith();
      expect(copied.providerConfig, equals(original.providerConfig));
      expect(copied.systemPromptOverride, equals(original.systemPromptOverride));
      expect(copied.totalInputTokens, equals(42));
    });
  });

  // ═══════════════════════════════════════════════════
  // D. 默认值验证
  // ═══════════════════════════════════════════════════

  group('D. 默认值', () {
    test('构造函数默认值', () {
      final config = DeviceSessionConfig(updateTime: now);
      expect(config.projectUuid, isNull);
      expect(config.providerConfig, isNull);
      expect(config.systemPromptOverride, isNull);
      expect(config.contextData, isNull);
      expect(config.totalInputTokens, equals(0));
      expect(config.totalOutputTokens, equals(0));
      expect(config.totalMessageCount, equals(0));
    });

    test('fromMap 默认值', () {
      final map = <String, dynamic>{
        'updateTime': now.millisecondsSinceEpoch,
      };
      final config = DeviceSessionConfig.fromMap(map);
      expect(config.totalInputTokens, equals(0));
      expect(config.totalOutputTokens, equals(0));
      expect(config.totalMessageCount, equals(0));
    });
  });
}
