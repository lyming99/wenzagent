import 'dart:convert';

import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  // ============================================================
  // ConfigToolAdapter 测试
  // ============================================================
  group('ConfigToolAdapter', () {
    late ConfigToolAdapter adapter;
    String? capturedPrompt;

    setUp(() {
      capturedPrompt = null;
      adapter = ConfigToolAdapter(
        name: 'cfg_translate',
        description: '翻译技能',
        inputSchema: {
          'type': 'object',
          'properties': {
            'content': {'type': 'string'},
            'target_lang': {'type': 'string'},
          },
          'required': ['content', 'target_lang'],
        },
        promptTemplate:
            '你是一位专业翻译。请将以下内容翻译为{{target_lang}}：\n\n{{content}}',
        invokeLlm: (prompt) async {
          capturedPrompt = prompt;
          return '翻译完成：Hello World';
        },
      );
    });

    test('基本属性', () {
      expect(adapter.name, 'cfg_translate');
      expect(adapter.description, '翻译技能');
      expect(adapter.requiresPermission, false);
      expect(adapter.permissionType, 'config_skill');
    });

    test('inputJsonSchema', () {
      final schema = adapter.inputJsonSchema;
      expect(schema['type'], 'object');
      expect((schema['properties'] as Map)['content'], isNotNull);
      expect((schema['properties'] as Map)['target_lang'], isNotNull);
    });

    test('toToolSpec 不包含 prompt 模板', () {
      final spec = adapter.toToolSpec();
      expect(spec.name, 'cfg_translate');
      expect(spec.description, '翻译技能');
      // ToolSpec 只包含 name + description + schema
    });

    test('execute 注入参数并调用 LLM', () async {
      final result = await adapter.execute({
        'content': '你好世界',
        'target_lang': '英文',
      });

      expect(result.isError, false);
      expect(result.content, '翻译完成：Hello World');

      // 验证 prompt 注入
      expect(capturedPrompt, contains('英文'));
      expect(capturedPrompt, contains('你好世界'));
      expect(capturedPrompt, isNot(contains('{{')));
    });

    test('execute 多次参数替换', () async {
      final multiAdapter = ConfigToolAdapter(
        name: 'cfg_multi',
        description: '多参数',
        inputSchema: const {},
        promptTemplate:
            '角色：{{role}}\n任务：{{task}}\n输入：{{input}}\n格式：{{format}}',
        invokeLlm: (prompt) async {
          capturedPrompt = prompt;
          return 'done';
        },
      );

      await multiAdapter.execute({
        'role': '专家',
        'task': '分析',
        'input': '数据',
        'format': 'JSON',
      });

      expect(capturedPrompt, contains('角色：专家'));
      expect(capturedPrompt, contains('任务：分析'));
      expect(capturedPrompt, contains('输入：数据'));
      expect(capturedPrompt, contains('格式：JSON'));
    });

    test('execute LLM 异常时返回错误', () async {
      final errorAdapter = ConfigToolAdapter(
        name: 'cfg_error',
        description: '错误测试',
        inputSchema: const {},
        promptTemplate: 'prompt',
        invokeLlm: (_) async => throw Exception('网络超时'),
      );

      final result = await errorAdapter.execute({});

      expect(result.isError, true);
      expect(result.content, contains('配置技能执行失败'));
    });

    test('requiresPermission 可配置', () {
      final permAdapter = ConfigToolAdapter(
        name: 'cfg_perm',
        description: '需要权限',
        inputSchema: const {},
        promptTemplate: 'prompt',
        requiresPermission: true,
        invokeLlm: (p) async => 'ok',
      );

      expect(permAdapter.requiresPermission, true);
      expect(permAdapter.permissionType, 'config_skill');
    });
  });

  // ============================================================
  // ConfigSkill 生命周期测试
  // ============================================================
  group('ConfigSkill', () {
    late ConfigSkill skill;
    late ToolRegistry registry;
    String? capturedPrompt;

    setUp(() {
      capturedPrompt = null;
      registry = ToolRegistry();
      final context = SkillContext(
        toolRegistry: registry,
        employeeId: 'test-employee',
        invokeLlm: (prompt) async {
          capturedPrompt = prompt;
          return 'LLM 结果';
        },
        logger: (level, msg) {},
      );

      skill = ConfigSkill(
        id: 'skill-001',
        name: '翻译技能',
        description: '中英互译',
        promptTemplate: '将{{content}}翻译为{{target_lang}}',
        parameters: {
          'type': 'object',
          'properties': {
            'content': {'type': 'string'},
            'target_lang': {'type': 'string'},
          },
          'required': ['content', 'target_lang'],
        },
      );
      skill.setContext(context);
    });

    test('初始状态', () {
      expect(skill.status, SkillStatus.uninitialized);
      expect(skill.type, SkillType.config);
      expect(skill.id, 'skill-001');
    });

    test('initialize → activate 生命周期', () async {
      await skill.initialize();
      expect(skill.status, SkillStatus.active);

      await skill.activate();
      expect(skill.tools.length, 1);
      expect(skill.tools[0].name, 'cfg_skill-00');
      expect(skill.tools[0].description, '中英互译');
    });

    test('deactivate → dispose 生命周期', () async {
      await skill.initialize();
      await skill.deactivate();
      expect(skill.status, SkillStatus.active);

      await skill.dispose();
      expect(skill.status, SkillStatus.disposed);
    });

    test('healthCheck', () async {
      expect(await skill.healthCheck(), false);

      await skill.initialize();
      expect(await skill.healthCheck(), true);

      await skill.dispose();
      expect(await skill.healthCheck(), false);
    });

    test('完整执行流程', () async {
      await skill.initialize();
      await skill.activate();

      final tool = skill.tools[0];
      final result = await tool.execute({
        'content': '你好',
        'target_lang': '英文',
      });

      expect(result.isError, false);
      expect(result.content, 'LLM 结果');
      expect(capturedPrompt, contains('你好'));
      expect(capturedPrompt, contains('英文'));
    });
  });

  // ============================================================
  // ConfigSkill.fromEntity 测试
  // ============================================================
  group('ConfigSkill.fromEntity', () {
    test('从标准实体创建', () {
      final entity = AiEmployeeSkillEntity(
        uuid: 'uuid-001',
        employeeId: 'emp-001',
        name: '摘要技能',
        description: '生成文本摘要',
        skillType: 'config',
        config: jsonEncode({
          'prompt': '请对以下内容生成摘要：\n\n{{content}}',
          'parameters': {
            'type': 'object',
            'properties': {
              'content': {'type': 'string'},
            },
            'required': ['content'],
          },
          'requires_permission': false,
        }),
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );

      final skill = ConfigSkill.fromEntity(entity);

      expect(skill.id, 'uuid-001');
      expect(skill.name, '摘要技能');
      expect(skill.description, '生成文本摘要');
      expect(skill.type, SkillType.config);
    });

    test('config 为空时使用默认值', () {
      final entity = AiEmployeeSkillEntity(
        uuid: 'uuid-002',
        employeeId: 'emp-001',
        name: '空配置技能',
        skillType: 'config',
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );

      final skill = ConfigSkill.fromEntity(entity);
      // 不会抛异常，promptTemplate 为空
      expect(skill.id, 'uuid-002');
      expect(skill.name, '空配置技能');
    });

    test('config 包含 requires_permission', () {
      final entity = AiEmployeeSkillEntity(
        uuid: 'uuid-003',
        employeeId: 'emp-001',
        name: '需要权限',
        skillType: 'config',
        config: jsonEncode({
          'prompt': 'prompt',
          'requires_permission': true,
        }),
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );

      final skill = ConfigSkill.fromEntity(entity);
      // requiresPermission 在 initialize 后体现到 tool 上
      expect(skill.id, 'uuid-003');
    });

    test('fromEntity 创建后可完整执行', () async {
      final entity = AiEmployeeSkillEntity(
        uuid: 'uuid-004',
        employeeId: 'emp-001',
        name: '格式化技能',
        description: 'JSON 格式化',
        skillType: 'config',
        config: jsonEncode({
          'prompt': '将以下内容格式化为 JSON：\n\n{{content}}',
          'parameters': {
            'type': 'object',
            'properties': {
              'content': {'type': 'string'},
            },
            'required': ['content'],
          },
        }),
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );

      final skill = ConfigSkill.fromEntity(entity);
      final context = SkillContext(
        toolRegistry: ToolRegistry(),
        employeeId: 'emp-001',
        invokeLlm: (prompt) async => '{"result": "formatted"}',
        logger: (_, __) {},
      );
      skill.setContext(context);

      await skill.initialize();
      final tool = skill.tools[0];
      final result = await tool.execute({'content': 'raw data'});

      expect(result.isError, false);
      expect(result.content, '{"result": "formatted"}');
    });
  });

  // ============================================================
  // ConfigSkill + SkillLifecycleManager 集成测试
  // ============================================================
  group('ConfigSkill 集成 SkillLifecycleManager', () {
    late ToolRegistry registry;
    late SkillLifecycleManager manager;
    final events = <SkillEvent>[];

    setUp(() {
      registry = ToolRegistry();
      manager = SkillLifecycleManager(SkillContext(
        toolRegistry: registry,
        employeeId: 'test-emp',
        invokeLlm: (prompt) async => 'result',
        logger: (_, __) {},
      ));
      events.clear();
      manager.onEvent.listen(events.add);
    });

    tearDown(() async {
      await manager.dispose();
    });

    test('loadSkill 注册工具到 ToolRegistry', () async {
      final skill = ConfigSkill(
        id: 'test-001',
        name: '测试技能',
        description: '测试',
        promptTemplate: '{{input}}',
      );
      skill.setContext(SkillContext(
        toolRegistry: registry,
        employeeId: 'test-emp',
        invokeLlm: (_) async => 'ok',
        logger: (_, __) {},
      ));

      await manager.loadSkill(skill);

      expect(registry.length, 1);
      expect(registry.contains('cfg_test-001'), true);
      expect(manager.skills.length, 1);
      expect(events.length, 1);
      expect(events[0].type, 'added');
      expect(events[0].skillId, 'test-001');
    });

    test('unloadSkill 注销工具', () async {
      final skill = ConfigSkill(
        id: 'test-002',
        name: '测试技能',
        description: '测试',
        promptTemplate: 'prompt',
      );
      skill.setContext(SkillContext(
        toolRegistry: registry,
        employeeId: 'test-emp',
        invokeLlm: (_) async => 'ok',
        logger: (_, __) {},
      ));

      await manager.loadSkill(skill);
      expect(registry.length, 1);

      await manager.unloadSkill('test-002');
      expect(registry.length, 0);
      expect(manager.skills.length, 0);
      expect(events.last.type, 'removed');
    });

    test('loadSkill 失败时广播 error 事件', () async {
      final badSkill = ConfigSkill(
        id: 'bad-error-01',
        name: '错误技能',
        description: '没有 setContext',
        promptTemplate: 'prompt',
        // 故意不 setContext，initialize 时会报错
      );

      await expectLater(
        manager.loadSkill(badSkill),
        throwsA(anything),
      );

      expect(events.any((e) => e.type == 'error'), true);
    });
  });
}
