import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';

int _testCounter = 0;

/// SessionStore 完整单元测试
///
/// 覆盖所有公共 API：find, getOrCreate, save, findAll, delete, hardDelete, count
/// 以及实体方法：isEffectivelyDeleted, DeviceSessionConfig 序列化, fromLegacyMap 兼容
void main() {
  late String testDbPath;
  late String deviceId;
  late SessionStore store;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_session_test_$_testCounter';
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

  /// 创建一个测试用会话实体
  AiEmployeeSessionEntity createSession({
    String? employeeId,
    String title = '测试会话',
    int isArchived = 0,
    int isPinned = 0,
    int deleted = 0,
    DateTime? deleteTime,
    DateTime? createTime,
    DateTime? updateTime,
    Map<String, DeviceSessionConfig>? config,
  }) {
    final now = DateTime.now();
    return AiEmployeeSessionEntity(
      employeeId: employeeId ?? const Uuid().v4(),
      title: title,
      isArchived: isArchived,
      isPinned: isPinned,
      deleted: deleted,
      deleteTime: deleteTime,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
      config: config,
    );
  }

  /// 创建一个测试用设备配置
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
  // find 查找测试
  // ═══════════════════════════════════════════════════

  group('find 查找测试', () {
    test('查找存在的会话', () async {
      final session = createSession(employeeId: 'emp-001', title: '我的会话');
      await store.save(session);

      final found = await store.find('emp-001');

      expect(found, isNotNull);
      expect(found!.employeeId, equals('emp-001'));
      expect(found.title, equals('我的会话'));
    });

    test('查找不存在的会话返回 null', () async {
      final found = await store.find('non-existent-id');

      expect(found, isNull);
    });

    test('查找后验证 config 映射正确反序列化', () async {
      final deviceConfig = createDeviceConfig(
        providerConfig: '{"provider":"openai","model":"gpt-4"}',
        systemPromptOverride: '你是一个助手',
        totalInputTokens: 100,
        totalOutputTokens: 50,
        totalMessageCount: 3,
      );
      final session = createSession(
        employeeId: 'emp-config',
        config: {'phone': deviceConfig},
      );
      await store.save(session);

      final found = await store.find('emp-config');

      expect(found, isNotNull);
      expect(found!.config, contains('phone'));
      final restored = found.config['phone']!;
      expect(restored.providerConfig,
          equals('{"provider":"openai","model":"gpt-4"}'));
      expect(restored.systemPromptOverride, equals('你是一个助手'));
      expect(restored.totalInputTokens, equals(100));
      expect(restored.totalOutputTokens, equals(50));
      expect(restored.totalMessageCount, equals(3));
    });
  });

  // ═══════════════════════════════════════════════════
  // getOrCreate 获取或创建测试
  // ═══════════════════════════════════════════════════

  group('getOrCreate 获取或创建测试', () {
    test('不存在时自动创建（默认值验证）', () async {
      final session = await store.getOrCreate('new-emp');

      expect(session.employeeId, equals('new-emp'));
      expect(session.title, equals('新对话'));
      expect(session.isArchived, equals(0));
      expect(session.isPinned, equals(0));
      expect(session.deleted, equals(0));
      expect(session.deleteTime, isNull);
      expect(session.config, isEmpty);

      // 验证已持久化
      final found = await store.find('new-emp');
      expect(found, isNotNull);
      expect(found!.employeeId, equals('new-emp'));
    });

    test('存在时直接返回', () async {
      final original = createSession(
        employeeId: 'existing-emp',
        title: '已有会话',
        isPinned: 1,
      );
      await store.save(original);

      final result = await store.getOrCreate('existing-emp');

      expect(result.employeeId, equals('existing-emp'));
      expect(result.title, equals('已有会话'));
      expect(result.isPinned, equals(1));
    });

    test('软删除状态自动复活（deleted=0, deleteTime=null）', () async {
      // 先创建并软删除
      final session = createSession(employeeId: 'revive-emp');
      await store.save(session);
      await store.delete('revive-emp');

      // 确认已软删除
      final deleted = await store.find('revive-emp');
      expect(deleted!.deleted, equals(1));
      expect(deleted.deleteTime, isNotNull);

      // getOrCreate 应自动复活
      final revived = await store.getOrCreate('revive-emp');

      expect(revived.deleted, equals(0));
      expect(revived.deleteTime, isNull);
      expect(revived.title, equals('测试会话'));

      // 验证持久化后也是复活状态
      final fromDb = await store.find('revive-emp');
      expect(fromDb!.deleted, equals(0));
      expect(fromDb.deleteTime, isNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // save 保存测试
  // ═══════════════════════════════════════════════════

  group('save 保存测试', () {
    test('新增会话', () async {
      final session = createSession(employeeId: 'save-new', title: '新增测试');
      await store.save(session);

      final found = await store.find('save-new');
      expect(found, isNotNull);
      expect(found!.title, equals('新增测试'));
    });

    test('更新已有会话（INSERT OR REPLACE）', () async {
      final original = createSession(
        employeeId: 'save-update',
        title: '原始标题',
        isPinned: 0,
      );
      await store.save(original);

      // 更新
      final updated = original.copyWith(
        title: '更新标题',
        isPinned: 1,
        updateTime: DateTime.now().add(const Duration(hours: 1)),
      );
      await store.save(updated);

      final found = await store.find('save-update');
      expect(found, isNotNull);
      expect(found!.title, equals('更新标题'));
      expect(found.isPinned, equals(1));
    });

    test('保存带设备配置的会话，验证 config 序列化/反序列化', () async {
      final config1 = createDeviceConfig(
        providerConfig: '{"provider":"openai"}',
        totalInputTokens: 500,
      );
      final config2 = createDeviceConfig(
        providerConfig: '{"provider":"anthropic"}',
        totalInputTokens: 300,
      );
      final session = createSession(
        employeeId: 'save-config',
        config: {'device-a': config1, 'device-b': config2},
      );
      await store.save(session);

      final found = await store.find('save-config');
      expect(found, isNotNull);
      expect(found!.config.keys, containsAll(['device-a', 'device-b']));

      expect(found.config['device-a']!.providerConfig,
          equals('{"provider":"openai"}'));
      expect(found.config['device-a']!.totalInputTokens, equals(500));
      expect(found.config['device-b']!.providerConfig,
          equals('{"provider":"anthropic"}'));
      expect(found.config['device-b']!.totalInputTokens, equals(300));
    });
  });

  // ═══════════════════════════════════════════════════
  // findAll 列表测试
  // ═══════════════════════════════════════════════════

  group('findAll 列表测试', () {
    test('空表返回空列表', () async {
      final list = await store.findAll();

      expect(list, isEmpty);
    });

    test('默认排除已删除和已归档', () async {
      final normal = createSession(employeeId: 'normal', title: '正常');
      final archived =
          createSession(employeeId: 'archived', title: '已归档', isArchived: 1);
      final deleted =
          createSession(employeeId: 'deleted', title: '已删除', deleted: 1);
      await store.save(normal);
      await store.save(archived);
      await store.save(deleted);

      final list = await store.findAll();

      expect(list.length, equals(1));
      expect(list.first.employeeId, equals('normal'));
    });

    test('includeDeleted=true 包含已删除', () async {
      final normal = createSession(employeeId: 'normal-2', title: '正常');
      final deleted = createSession(
        employeeId: 'deleted-2',
        title: '已删除',
        deleted: 1,
      );
      await store.save(normal);
      await store.save(deleted);

      final list = await store.findAll(includeDeleted: true);

      expect(list.length, equals(2));
      expect(list.map((s) => s.employeeId), containsAll(['normal-2', 'deleted-2']));
    });

    test('includeArchived=true 包含已归档', () async {
      final normal = createSession(employeeId: 'normal-3', title: '正常');
      final archived = createSession(
        employeeId: 'archived-3',
        title: '已归档',
        isArchived: 1,
      );
      await store.save(normal);
      await store.save(archived);

      final list = await store.findAll(includeArchived: true);

      expect(list.length, equals(2));
      expect(list.map((s) => s.employeeId), containsAll(['normal-3', 'archived-3']));
    });

    test('排序：is_pinned DESC, update_time DESC', () async {
      final now = DateTime.now();
      final pinnedOld = createSession(
        employeeId: 'pinned-old',
        isPinned: 1,
        updateTime: now.subtract(const Duration(hours: 2)),
      );
      final pinnedNew = createSession(
        employeeId: 'pinned-new',
        isPinned: 1,
        updateTime: now.subtract(const Duration(hours: 1)),
      );
      final unpinnedNew = createSession(
        employeeId: 'unpinned-new',
        isPinned: 0,
        updateTime: now,
      );
      final unpinnedOld = createSession(
        employeeId: 'unpinned-old',
        isPinned: 0,
        updateTime: now.subtract(const Duration(hours: 3)),
      );
      await store.save(pinnedOld);
      await store.save(pinnedNew);
      await store.save(unpinnedNew);
      await store.save(unpinnedOld);

      final list = await store.findAll();

      expect(list.length, equals(4));
      // 置顶的排在前面，置顶内按更新时间倒序
      expect(list[0].employeeId, equals('pinned-new'));
      expect(list[1].employeeId, equals('pinned-old'));
      // 非置顶的排在后面，按更新时间倒序
      expect(list[2].employeeId, equals('unpinned-new'));
      expect(list[3].employeeId, equals('unpinned-old'));
    });
  });

  // ═══════════════════════════════════════════════════
  // delete 软删除测试
  // ═══════════════════════════════════════════════════

  group('delete 软删除测试', () {
    test('软删除后 deleted=1, deleteTime 有值', () async {
      final session = createSession(employeeId: 'soft-del');
      await store.save(session);

      await store.delete('soft-del');

      final found = await store.find('soft-del');
      expect(found, isNotNull);
      expect(found!.deleted, equals(1));
      expect(found.deleteTime, isNotNull);
    });

    test('软删除后 find 仍能找到', () async {
      final session = createSession(employeeId: 'soft-find');
      await store.save(session);

      await store.delete('soft-find');

      final found = await store.find('soft-find');
      expect(found, isNotNull);
      expect(found!.employeeId, equals('soft-find'));
    });

    test('软删除后 findAll 默认不包含', () async {
      final session = createSession(employeeId: 'soft-findall');
      await store.save(session);
      expect(await store.findAll(), hasLength(1));

      await store.delete('soft-findall');

      final list = await store.findAll();
      expect(list, isEmpty);
    });

    test('软删除不存在的会话无副作用', () async {
      // 不应抛出异常
      await store.delete('non-existent-soft');
      expect(await store.findAll(), isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════
  // hardDelete 硬删除测试
  // ═══════════════════════════════════════════════════

  group('hardDelete 硬删除测试', () {
    test('硬删除后 find 返回 null', () async {
      final session = createSession(employeeId: 'hard-del');
      await store.save(session);
      expect(await store.find('hard-del'), isNotNull);

      await store.hardDelete('hard-del');

      expect(await store.find('hard-del'), isNull);
    });

    test('硬删除不存在的会话无副作用', () async {
      // 不应抛出异常
      await store.hardDelete('non-existent-hard');
      expect(await store.findAll(), isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════
  // count 计数测试
  // ═══════════════════════════════════════════════════

  group('count 计数测试', () {
    test('空表计数为 0', () async {
      expect(await store.count(), equals(0));
    });

    test('新增后计数正确', () async {
      await store.save(createSession(employeeId: 'count-1'));
      await store.save(createSession(employeeId: 'count-2'));
      await store.save(createSession(employeeId: 'count-3'));

      expect(await store.count(), equals(3));
    });

    test('已删除的不计入', () async {
      await store.save(createSession(employeeId: 'count-active'));
      await store.save(createSession(employeeId: 'count-deleted'));
      await store.delete('count-deleted');

      expect(await store.count(), equals(1));
    });

    test('已归档的不计入', () async {
      await store.save(createSession(employeeId: 'count-normal'));
      await store.save(createSession(
        employeeId: 'count-archived',
        isArchived: 1,
      ));

      expect(await store.count(), equals(1));
    });
  });

  // ═══════════════════════════════════════════════════
  // isEffectivelyDeleted 判定测试
  // ═══════════════════════════════════════════════════

  group('isEffectivelyDeleted 判定测试', () {
    test('deleted=0 返回 false', () async {
      final session = createSession(employeeId: 'eff-1', deleted: 0);
      expect(session.isEffectivelyDeleted(), isFalse);
    });

    test('deleted=1, deleteTime >= updateTime 返回 true（仍处于删除状态）',
        () async {
      final now = DateTime.now();
      // deleteTime == updateTime
      final session1 = createSession(
        employeeId: 'eff-2a',
        deleted: 1,
        deleteTime: now,
        updateTime: now,
      );
      expect(session1.isEffectivelyDeleted(), isTrue);

      // deleteTime > updateTime
      final session2 = createSession(
        employeeId: 'eff-2b',
        deleted: 1,
        deleteTime: now.add(const Duration(seconds: 1)),
        updateTime: now,
      );
      expect(session2.isEffectivelyDeleted(), isTrue);
    });

    test('deleted=1, deleteTime < updateTime 返回 false（已复活）', () async {
      final now = DateTime.now();
      final session = createSession(
        employeeId: 'eff-3',
        deleted: 1,
        deleteTime: now,
        updateTime: now.add(const Duration(hours: 1)),
      );
      expect(session.isEffectivelyDeleted(), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════
  // DeviceSessionConfig 序列化测试
  // ═══════════════════════════════════════════════════

  group('DeviceSessionConfig 序列化测试', () {
    test('toMap/fromMap 往返', () async {
      final now = DateTime.now();
      final original = DeviceSessionConfig(
        projectUuid: 'proj-123',
        providerConfig: '{"provider":"openai","model":"gpt-4"}',
        systemPromptOverride: '自定义提示词',
        contextData: '{"key":"value"}',
        totalInputTokens: 1000,
        totalOutputTokens: 500,
        totalMessageCount: 20,
        updateTime: now,
      );

      final map = original.toMap();
      final restored = DeviceSessionConfig.fromMap(map);

      expect(restored.projectUuid, equals('proj-123'));
      expect(restored.providerConfig,
          equals('{"provider":"openai","model":"gpt-4"}'));
      expect(restored.systemPromptOverride, equals('自定义提示词'));
      expect(restored.contextData, equals('{"key":"value"}'));
      expect(restored.totalInputTokens, equals(1000));
      expect(restored.totalOutputTokens, equals(500));
      expect(restored.totalMessageCount, equals(20));
      expect(restored.updateTime.millisecondsSinceEpoch,
          equals(now.millisecondsSinceEpoch));
    });

    test('copyWith 正确工作', () async {
      final now = DateTime.now();
      final original = DeviceSessionConfig(
        providerConfig: '{"provider":"openai"}',
        totalInputTokens: 100,
        totalOutputTokens: 200,
        totalMessageCount: 10,
        updateTime: now,
      );

      // 修改部分字段
      final copied = original.copyWith(
        providerConfig: '{"provider":"anthropic"}',
        totalInputTokens: 300,
      );

      expect(copied.providerConfig, equals('{"provider":"anthropic"}'));
      expect(copied.totalInputTokens, equals(300));
      // 未修改的字段保留原值
      expect(copied.totalOutputTokens, equals(200));
      expect(copied.totalMessageCount, equals(10));
      expect(copied.updateTime, equals(now));
    });

    test('多设备配置映射的序列化/反序列化', () async {
      final now = DateTime.now();
      final configMap = {
        'phone': DeviceSessionConfig(
          providerConfig: '{"provider":"openai"}',
          totalInputTokens: 100,
          updateTime: now,
        ),
        'tablet': DeviceSessionConfig(
          providerConfig: '{"provider":"anthropic"}',
          totalInputTokens: 200,
          totalOutputTokens: 50,
          updateTime: now.add(const Duration(hours: 1)),
        ),
        'desktop': DeviceSessionConfig(
          providerConfig: '{"provider":"google"}',
          totalMessageCount: 5,
          updateTime: now.add(const Duration(hours: 2)),
        ),
      };

      // 通过 SessionStore 保存并读取，验证完整往返
      final session = createSession(
        employeeId: 'multi-device',
        config: configMap,
      );
      await store.save(session);

      final found = await store.find('multi-device');
      expect(found, isNotNull);
      expect(found!.config.length, equals(3));

      // 验证每个设备配置
      expect(found.config['phone']!.providerConfig,
          equals('{"provider":"openai"}'));
      expect(found.config['phone']!.totalInputTokens, equals(100));

      expect(found.config['tablet']!.providerConfig,
          equals('{"provider":"anthropic"}'));
      expect(found.config['tablet']!.totalInputTokens, equals(200));
      expect(found.config['tablet']!.totalOutputTokens, equals(50));

      expect(found.config['desktop']!.providerConfig,
          equals('{"provider":"google"}'));
      expect(found.config['desktop']!.totalMessageCount, equals(5));
    });
  });

  // ═══════════════════════════════════════════════════
  // fromLegacyMap 兼容性测试
  // ═══════════════════════════════════════════════════

  group('fromLegacyMap 兼容性测试', () {
    test('旧格式 providerConfig 迁移到 config[""]', () async {
      final legacyMap = {
        'employeeId': 'legacy-1',
        'providerConfig': '{"provider":"openai","model":"gpt-3.5"}',
        'title': '旧会话',
        'createTime': DateTime.now().millisecondsSinceEpoch,
        'updateTime': DateTime.now().millisecondsSinceEpoch,
      };

      final entity = AiEmployeeSessionEntity.fromLegacyMap(legacyMap);

      expect(entity.employeeId, equals('legacy-1'));
      expect(entity.config, contains(''));
      expect(entity.config['']!.providerConfig,
          equals('{"provider":"openai","model":"gpt-3.5"}'));
      expect(entity.title, equals('旧会话'));
    });

    test('旧格式 projectUuid 迁移', () async {
      final legacyMap = {
        'employeeId': 'legacy-2',
        'projectUuid': 'proj-legacy-123',
        'createTime': DateTime.now().millisecondsSinceEpoch,
        'updateTime': DateTime.now().millisecondsSinceEpoch,
      };

      final entity = AiEmployeeSessionEntity.fromLegacyMap(legacyMap);

      expect(entity.config, contains(''));
      expect(entity.config['']!.projectUuid, equals('proj-legacy-123'));
    });

    test('旧格式统计字段迁移', () async {
      final now = DateTime.now();
      final legacyMap = {
        'employeeId': 'legacy-3',
        'providerConfig': '{"provider":"openai"}',
        'inputTokens': 1500,
        'outputTokens': 800,
        'messageCount': 42,
        'contextData': '{"threadId":"t-001"}',
        'createTime': now.millisecondsSinceEpoch,
        'updateTime': now.millisecondsSinceEpoch,
      };

      final entity = AiEmployeeSessionEntity.fromLegacyMap(legacyMap);

      expect(entity.config, contains(''));
      final deviceConfig = entity.config['']!;
      expect(deviceConfig.totalInputTokens, equals(1500));
      expect(deviceConfig.totalOutputTokens, equals(800));
      expect(deviceConfig.totalMessageCount, equals(42));
      expect(deviceConfig.contextData, equals('{"threadId":"t-001"}'));
    });

    test('旧格式使用 uuid 字段作为 employeeId 回退', () async {
      final legacyMap = {
        'uuid': 'fallback-uuid-123',
        'createTime': DateTime.now().millisecondsSinceEpoch,
        'updateTime': DateTime.now().millisecondsSinceEpoch,
      };

      final entity = AiEmployeeSessionEntity.fromLegacyMap(legacyMap);

      expect(entity.employeeId, equals('fallback-uuid-123'));
    });

    test('旧格式完整迁移后可持久化并读取', () async {
      final now = DateTime.now();
      final legacyMap = {
        'employeeId': 'legacy-persist',
        'providerConfig': '{"provider":"anthropic"}',
        'projectUuid': 'proj-old',
        'inputTokens': 999,
        'outputTokens': 111,
        'messageCount': 7,
        'title': '迁移测试',
        'isArchived': 0,
        'isPinned': 1,
        'deleted': 0,
        'createTime': now.millisecondsSinceEpoch,
        'updateTime': now.millisecondsSinceEpoch,
      };

      final entity = AiEmployeeSessionEntity.fromLegacyMap(legacyMap);
      await store.save(entity);

      final found = await store.find('legacy-persist');
      expect(found, isNotNull);
      expect(found!.title, equals('迁移测试'));
      expect(found.isPinned, equals(1));
      expect(found.config['']!.providerConfig, equals('{"provider":"anthropic"}'));
      expect(found.config['']!.projectUuid, equals('proj-old'));
      expect(found.config['']!.totalInputTokens, equals(999));
      expect(found.config['']!.totalOutputTokens, equals(111));
      expect(found.config['']!.totalMessageCount, equals(7));
    });
  });

  // ═══════════════════════════════════════════════════
  // getConfig / getOrCreateConfig 便捷方法测试
  // ═══════════════════════════════════════════════════

  group('getConfig / getOrCreateConfig 便捷方法测试', () {
    test('getConfig 返回已有配置', () async {
      final config = createDeviceConfig(providerConfig: '{"provider":"openai"}');
      final session = createSession(
        employeeId: 'getcfg',
        config: {'dev1': config},
      );

      expect(session.getConfig('dev1'), isNotNull);
      expect(session.getConfig('dev1')!.providerConfig,
          equals('{"provider":"openai"}'));
      expect(session.getConfig('nonexistent'), isNull);
    });

    test('getOrCreateConfig 不存在时自动创建', () async {
      final session = createSession(employeeId: 'getorcreate');

      expect(session.config, isEmpty);
      final created = session.getOrCreateConfig('new-device');
      expect(created, isNotNull);
      expect(created.updateTime, isNotNull);
      // 同时应已添加到 config map 中
      expect(session.config, contains('new-device'));
    });

    test('getOrCreateConfig 已存在时直接返回', () async {
      final now = DateTime.now();
      final config = DeviceSessionConfig(
        providerConfig: '{"provider":"anthropic"}',
        updateTime: now,
      );
      final session = createSession(
        employeeId: 'getorcreate-exist',
        config: {'dev2': config},
      );

      final result = session.getOrCreateConfig('dev2');
      expect(result.providerConfig, equals('{"provider":"anthropic"}'));
    });
  });

  // ═══════════════════════════════════════════════════
  // copyWith 哨兵值测试
  // ═══════════════════════════════════════════════════

  group('copyWith 哨兵值测试', () {
    test('copyWith 不传 deleteTime 保留原值', () async {
      final now = DateTime.now();
      final session = createSession(
        employeeId: 'cw-keep',
        deleteTime: now,
      );

      final copied = session.copyWith(title: '新标题');
      expect(copied.deleteTime, isNotNull);
      expect(copied.deleteTime!.millisecondsSinceEpoch,
          equals(now.millisecondsSinceEpoch));
    });

    test('copyWith 显式传 deleteTime:null 清除删除时间', () async {
      final session = createSession(
        employeeId: 'cw-clear',
        deleteTime: DateTime.now(),
      );

      final copied = session.copyWith(deleteTime: null);
      expect(copied.deleteTime, isNull);
    });
  });
}
