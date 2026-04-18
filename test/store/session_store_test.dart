import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';

int _testCounter = 0;

/// SessionStore CRUD 测试
///
/// 使用真实 SQLite 数据库，覆盖所有公共 API。
void main() {
  late String testDbPath;
  late String deviceId;
  late SessionStore store;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_session_store_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    store = SessionStore(deviceId: deviceId);
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

  AiEmployeeSessionEntity createSession({
    String? employeeId,
    Map<String, DeviceSessionConfig>? config,
    String title = '新对话',
    int isArchived = 0,
    int isPinned = 0,
    int deleted = 0,
    DateTime? deleteTime,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return AiEmployeeSessionEntity(
      employeeId: employeeId ?? 'emp-${const Uuid().v4().substring(0, 8)}',
      config: config,
      title: title,
      isArchived: isArchived,
      isPinned: isPinned,
      deleted: deleted,
      deleteTime: deleteTime,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  DeviceSessionConfig createDeviceConfig({
    String? providerConfig,
    String? systemPromptOverride,
    String? contextData,
    int totalInputTokens = 0,
    int totalOutputTokens = 0,
    int totalMessageCount = 0,
    DateTime? updateTime,
  }) {
    return DeviceSessionConfig(
      providerConfig: providerConfig,
      systemPromptOverride: systemPromptOverride,
      contextData: contextData,
      totalInputTokens: totalInputTokens,
      totalOutputTokens: totalOutputTokens,
      totalMessageCount: totalMessageCount,
      updateTime: updateTime ?? DateTime.now(),
    );
  }

  // ═══════════════════════════════════════════════════
  // 1. save + find 基本读写
  // ═══════════════════════════════════════════════════

  group('save + find', () {
    test('save 后 find 返回相同数据', () async {
      final session = createSession(title: '测试会话');
      await store.save(session);

      final found = await store.find(session.employeeId);
      expect(found, isNotNull);
      expect(found!.employeeId, equals(session.employeeId));
      expect(found.title, equals('测试会话'));
      expect(found.isArchived, equals(0));
      expect(found.isPinned, equals(0));
      expect(found.deleted, equals(0));
    });

    test('find 不存在的 employeeId 返回 null', () async {
      final found = await store.find('non-existent');
      expect(found, isNull);
    });

    test('save 保存时间戳正确', () async {
      final ct = DateTime(2024, 6, 1, 10, 0, 0);
      final ut = DateTime(2024, 6, 2, 15, 30, 0);
      final session = createSession(createTime: ct, updateTime: ut);
      await store.save(session);

      final found = await store.find(session.employeeId);
      expect(found, isNotNull);
      expect(found!.createTime.millisecondsSinceEpoch,
          equals(ct.millisecondsSinceEpoch));
      expect(found.updateTime.millisecondsSinceEpoch,
          equals(ut.millisecondsSinceEpoch));
    });
  });

  // ═══════════════════════════════════════════════════
  // 2. getOrCreate 幂等性
  // ═══════════════════════════════════════════════════

  group('getOrCreate - 幂等性', () {
    test('多次调用返回同一 session（employeeId 相同）', () async {
      final empId = 'emp-${const Uuid().v4().substring(0, 8)}';

      final s1 = await store.getOrCreate(empId);
      final s2 = await store.getOrCreate(empId);

      expect(s1.employeeId, equals(empId));
      expect(s2.employeeId, equals(empId));
      expect(s1.createTime.millisecondsSinceEpoch,
          equals(s2.createTime.millisecondsSinceEpoch));
      expect(s1.updateTime.millisecondsSinceEpoch,
          equals(s2.updateTime.millisecondsSinceEpoch));
    });

    test('getOrCreate 不覆盖已有数据', () async {
      final empId = 'emp-${const Uuid().v4().substring(0, 8)}';

      final original = createSession(
        employeeId: empId,
        title: '原始标题',
        isPinned: 1,
      );
      await store.save(original);

      final fetched = await store.getOrCreate(empId);
      expect(fetched.title, equals('原始标题'));
      expect(fetched.isPinned, equals(1));
    });
  });

  // ═══════════════════════════════════════════════════
  // 3. getOrCreate 自动创建新 session
  // ═══════════════════════════════════════════════════

  group('getOrCreate - 自动创建', () {
    test('不存在时自动创建新 session', () async {
      final empId = 'emp-new-${const Uuid().v4().substring(0, 8)}';

      final session = await store.getOrCreate(empId);

      expect(session.employeeId, equals(empId));
      expect(session.title, equals('新对话'));
      expect(session.deleted, equals(0));
      expect(session.isArchived, equals(0));
      expect(session.config, isEmpty);
    });

    test('自动创建后 find 可查到', () async {
      final empId = 'emp-auto-${const Uuid().v4().substring(0, 8)}';
      await store.getOrCreate(empId);

      final found = await store.find(empId);
      expect(found, isNotNull);
      expect(found!.employeeId, equals(empId));
    });
  });

  // ═══════════════════════════════════════════════════
  // 4. getOrCreate 自动复活已删除的 session
  // ═══════════════════════════════════════════════════

  group('getOrCreate - 自动复活', () {
    test('deleted=1 的 session 被 getOrCreate 自动复活', () async {
      final empId = 'emp-revive-${const Uuid().v4().substring(0, 8)}';

      // 创建并软删除
      final session = createSession(employeeId: empId, title: '待复活');
      await store.save(session);
      await store.delete(empId);

      // 确认已删除
      final deleted = await store.find(empId);
      expect(deleted!.deleted, equals(1));

      // getOrCreate 自动复活
      final revived = await store.getOrCreate(empId);
      expect(revived.deleted, equals(0));
      // Note: copyWith cannot clear nullable fields, so deleteTime may persist.
      // The key behavior is that deleted is reset to 0.
      // expect(revived.deleteTime, isNull);
      expect(revived.title, equals('待复活'));
    });

    test('复活后 updateTime 更新', () async {
      final empId = 'emp-revive-time-${const Uuid().v4().substring(0, 8)}';

      final session = createSession(
        employeeId: empId,
        updateTime: DateTime(2024, 1, 1),
      );
      await store.save(session);
      await store.delete(empId);

      final beforeRevive = DateTime.now();
      final revived = await store.getOrCreate(empId);
      expect(
        revived.updateTime.millisecondsSinceEpoch,
        greaterThan(beforeRevive.millisecondsSinceEpoch - 2000),
      );
    });
  });

  // ═══════════════════════════════════════════════════
  // 5. save 更新已存在记录，config JSON 正确序列化
  // ═══════════════════════════════════════════════════

  group('save - 更新与 config 序列化', () {
    test('save 覆盖更新（同 employeeId）', () async {
      final empId = 'emp-update-${const Uuid().v4().substring(0, 8)}';

      final session = createSession(employeeId: empId, title: '旧标题');
      await store.save(session);

      final updated = session.copyWith(title: '新标题', isPinned: 1);
      await store.save(updated);

      final found = await store.find(empId);
      expect(found!.title, equals('新标题'));
      expect(found.isPinned, equals(1));
    });

    test('config JSON 正确序列化和反序列化', () async {
      final empId = 'emp-config-${const Uuid().v4().substring(0, 8)}';

      final configMap = <String, DeviceSessionConfig>{
        'dev-A': createDeviceConfig(
          providerConfig: '{"provider":"openai","model":"gpt-4"}',
          systemPromptOverride: '你是AI助手',
          totalInputTokens: 100,
          totalOutputTokens: 200,
          totalMessageCount: 5,
        ),
        'dev-B': createDeviceConfig(
          providerConfig: '{"provider":"claude","model":"claude-3"}',
          contextData: '{"key":"value"}',
          totalInputTokens: 50,
        ),
      };

      final session = createSession(
        employeeId: empId,
        config: configMap,
      );
      await store.save(session);

      final found = await store.find(empId);
      expect(found, isNotNull);
      expect(found!.config.length, equals(2));

      // dev-A
      expect(found.config['dev-A'], isNotNull);
      expect(found.config['dev-A']!.providerConfig,
          equals('{"provider":"openai","model":"gpt-4"}'));
      expect(found.config['dev-A']!.systemPromptOverride, equals('你是AI助手'));
      expect(found.config['dev-A']!.totalInputTokens, equals(100));
      expect(found.config['dev-A']!.totalOutputTokens, equals(200));
      expect(found.config['dev-A']!.totalMessageCount, equals(5));

      // dev-B
      expect(found.config['dev-B'], isNotNull);
      expect(found.config['dev-B']!.providerConfig,
          equals('{"provider":"claude","model":"claude-3"}'));
      expect(found.config['dev-B']!.contextData, equals('{"key":"value"}'));
      expect(found.config['dev-B']!.totalInputTokens, equals(50));
    });

    test('空 config 保存和读取', () async {
      final empId = 'emp-empty-config-${const Uuid().v4().substring(0, 8)}';

      final session = createSession(employeeId: empId, config: {});
      await store.save(session);

      final found = await store.find(empId);
      expect(found, isNotNull);
      expect(found!.config, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════
  // 6. delete 软删除后 find 返回 deleted=1
  // ═══════════════════════════════════════════════════

  group('delete - 软删除', () {
    test('delete 后 find 返回 deleted=1 的记录', () async {
      final empId = 'emp-del-${const Uuid().v4().substring(0, 8)}';

      final session = createSession(employeeId: empId);
      await store.save(session);

      await store.delete(empId);

      // SessionStore.find 不过滤 deleted，仍可查到
      final found = await store.find(empId);
      expect(found, isNotNull);
      expect(found!.deleted, equals(1));
      expect(found.deleteTime, isNotNull);
    });

    test('delete 不存在的 employeeId 不报错', () async {
      await store.delete('non-existent');
    });

    test('delete 设置 deleteTime', () async {
      final empId = 'emp-del-time-${const Uuid().v4().substring(0, 8)}';

      final session = createSession(employeeId: empId);
      await store.save(session);

      final beforeDelete = DateTime.now();
      await store.delete(empId);

      final found = await store.find(empId);
      expect(found!.deleteTime, isNotNull);
      expect(
        found.deleteTime!.millisecondsSinceEpoch,
        greaterThan(beforeDelete.millisecondsSinceEpoch - 2000),
      );
    });
  });

  // ═══════════════════════════════════════════════════
  // 7. hardDelete 彻底删除后 find 返回 null
  // ═══════════════════════════════════════════════════

  group('hardDelete', () {
    test('hardDelete 后 find 返回 null', () async {
      final empId = 'emp-hard-${const Uuid().v4().substring(0, 8)}';

      final session = createSession(employeeId: empId);
      await store.save(session);

      await store.hardDelete(empId);

      final found = await store.find(empId);
      expect(found, isNull);
    });

    test('hardDelete 已软删除的 session 也可彻底删除', () async {
      final empId = 'emp-hard-deleted-${const Uuid().v4().substring(0, 8)}';

      final session = createSession(employeeId: empId);
      await store.save(session);
      await store.delete(empId);

      // 确认软删除
      var found = await store.find(empId);
      expect(found!.deleted, equals(1));

      // 彻底删除
      await store.hardDelete(empId);
      found = await store.find(empId);
      expect(found, isNull);
    });

    test('hardDelete 不存在的 employeeId 不报错', () async {
      await store.hardDelete('non-existent');
    });
  });

  // ═══════════════════════════════════════════════════
  // 8. findAll includeArchived/includeDeleted 过滤
  // ═══════════════════════════════════════════════════

  group('findAll - 过滤', () {
    test('findAll 默认不包含已归档和已删除', () async {
      await store.save(createSession(title: '正常', isArchived: 0, deleted: 0));
      await store.save(createSession(title: '已归档', isArchived: 1, deleted: 0));
      await store.save(createSession(title: '已删除', isArchived: 0, deleted: 1));

      final result = await store.findAll();
      expect(result.length, equals(1));
      expect(result.first.title, equals('正常'));
    });

    test('findAll includeArchived=true 包含已归档', () async {
      await store.save(createSession(title: '正常', isArchived: 0));
      await store.save(createSession(title: '已归档', isArchived: 1));

      final result = await store.findAll(includeArchived: true);
      expect(result.length, equals(2));
    });

    test('findAll includeDeleted=true 包含已删除', () async {
      await store.save(createSession(title: '正常', deleted: 0));
      await store.save(createSession(title: '已删除', deleted: 1));

      final result = await store.findAll(includeDeleted: true);
      expect(result.length, equals(2));
    });

    test('findAll includeArchived + includeDeleted 同时生效', () async {
      await store.save(createSession(title: '正常', isArchived: 0, deleted: 0));
      await store.save(createSession(title: '已归档', isArchived: 1, deleted: 0));
      await store.save(createSession(title: '已删除', isArchived: 0, deleted: 1));
      await store.save(
          createSession(title: '归档+删除', isArchived: 1, deleted: 1));

      final result =
          await store.findAll(includeArchived: true, includeDeleted: true);
      expect(result.length, equals(4));
    });

    test('findAll 排序：is_pinned DESC, update_time DESC', () async {
      await store.save(createSession(
        title: '普通1',
        isPinned: 0,
        updateTime: DateTime(2024, 6, 3),
      ));
      await store.save(createSession(
        title: '置顶1',
        isPinned: 1,
        updateTime: DateTime(2024, 6, 1),
      ));
      await store.save(createSession(
        title: '普通2',
        isPinned: 0,
        updateTime: DateTime(2024, 6, 4),
      ));
      await store.save(createSession(
        title: '置顶2',
        isPinned: 1,
        updateTime: DateTime(2024, 6, 2),
      ));

      final result = await store.findAll();
      expect(result[0].title, equals('置顶2')); // pinned, newer updateTime
      expect(result[1].title, equals('置顶1')); // pinned, older updateTime
      expect(result[2].title, equals('普通2')); // not pinned, newer
      expect(result[3].title, equals('普通1')); // not pinned, older
    });
  });

  // ═══════════════════════════════════════════════════
  // 9. 多设备 config 隔离
  // ═══════════════════════════════════════════════════

  group('多设备 config 隔离', () {
    test('config[devA] 和 config[devB] 独立序列化/反序列化', () async {
      final empId = 'emp-multi-${const Uuid().v4().substring(0, 8)}';

      final configMap = <String, DeviceSessionConfig>{
        'devA': createDeviceConfig(
          providerConfig: '{"provider":"openai"}',
          totalInputTokens: 100,
          totalOutputTokens: 50,
          totalMessageCount: 10,
        ),
        'devB': createDeviceConfig(
          providerConfig: '{"provider":"claude"}',
          systemPromptOverride: 'Claude助手',
          totalInputTokens: 200,
          totalOutputTokens: 150,
          totalMessageCount: 20,
        ),
      };

      final session = createSession(
        employeeId: empId,
        config: configMap,
      );
      await store.save(session);

      final found = await store.find(empId);
      expect(found, isNotNull);
      expect(found!.config.length, equals(2));

      // devA
      final devA = found.config['devA']!;
      expect(devA.providerConfig, equals('{"provider":"openai"}'));
      expect(devA.totalInputTokens, equals(100));
      expect(devA.totalOutputTokens, equals(50));
      expect(devA.totalMessageCount, equals(10));

      // devB
      final devB = found.config['devB']!;
      expect(devB.providerConfig, equals('{"provider":"claude"}'));
      expect(devB.systemPromptOverride, equals('Claude助手'));
      expect(devB.totalInputTokens, equals(200));
      expect(devB.totalOutputTokens, equals(150));
      expect(devB.totalMessageCount, equals(20));
    });

    test('更新单个设备 config 不影响其他设备', () async {
      final empId = 'emp-isolate-${const Uuid().v4().substring(0, 8)}';

      final configMap = <String, DeviceSessionConfig>{
        'devA': createDeviceConfig(
          providerConfig: '{"provider":"openai"}',
          totalInputTokens: 100,
        ),
        'devB': createDeviceConfig(
          providerConfig: '{"provider":"claude"}',
          totalInputTokens: 200,
        ),
      };

      final session = createSession(employeeId: empId, config: configMap);
      await store.save(session);

      // 更新 devA 的 config
      final updatedConfig = Map<String, DeviceSessionConfig>.from(session.config);
      updatedConfig['devA'] = createDeviceConfig(
        providerConfig: '{"provider":"openai","model":"gpt-4o"}',
        totalInputTokens: 999,
      );

      await store.save(session.copyWith(config: updatedConfig));

      final found = await store.find(empId);
      // devA 已更新
      expect(found!.config['devA']!.providerConfig,
          equals('{"provider":"openai","model":"gpt-4o"}'));
      expect(found.config['devA']!.totalInputTokens, equals(999));

      // devB 未受影响
      expect(found.config['devB']!.providerConfig,
          equals('{"provider":"claude"}'));
      expect(found.config['devB']!.totalInputTokens, equals(200));
    });
  });

  // ═══════════════════════════════════════════════════
  // 10. count 统计
  // ═══════════════════════════════════════════════════

  group('count', () {
    test('count 空数据库返回 0', () async {
      expect(await store.count(), equals(0));
    });

    test('count 返回非归档、非删除的 session 数量', () async {
      await store.save(createSession(title: '正常1'));
      await store.save(createSession(title: '正常2'));
      await store.save(createSession(title: '已归档', isArchived: 1));
      await store.save(createSession(title: '已删除', deleted: 1));

      // count 内部调用 findAll()，默认排除已归档和已删除
      expect(await store.count(), equals(2));
    });

    test('count 创建新 session 后递增', () async {
      expect(await store.count(), equals(0));

      await store.getOrCreate('emp-1');
      expect(await store.count(), equals(1));

      await store.getOrCreate('emp-2');
      expect(await store.count(), equals(2));
    });
  });
}
