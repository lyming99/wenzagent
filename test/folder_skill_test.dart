import 'dart:convert';

import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  // ============================================================
  // SkillMdParser 解析器测试
  // ============================================================
  group('SkillMdParser', () {
    test('解析带 frontmatter 的 SKILL.md', () {
      const content = '''---
name: code_review
description: 代码审查技能
version: 1.0.0
tools:
  - name: review_security
    description: 审查代码安全问题
    prompt_file: review_security.md
    requires_permission: false
    parameters:
      type: object
      properties:
        code:
          type: string
          description: 待审查的代码
      required: [code]
---

# 代码审查技能

## 通用审查规则
1. 检查代码逻辑
''';

      final doc = SkillMdParser.parse(content);

      expect(doc.isRawMarkdown, false);
      expect(doc.frontmatter['name'], 'code_review');
      expect(doc.frontmatter['description'], '代码审查技能');
      expect(doc.frontmatter['version'], '1.0.0');
      expect(doc.body, contains('代码审查技能'));
      expect(doc.body, contains('通用审查规则'));
    });

    test('解析纯 Markdown（无 frontmatter）', () {
      const content = '''# 代码摘要

请对以下代码生成简洁摘要：

{{code}}
''';

      final doc = SkillMdParser.parse(content);

      expect(doc.isRawMarkdown, true);
      expect(doc.frontmatter['_raw'], true);
      expect(doc.body, contains('代码摘要'));
      expect(doc.body, contains('{{code}}'));
    });

    test('解析 skill.yaml 格式（无 body）', () {
      const content = '''---
name: translate
description: 翻译技能
tools:
  - name: translate_text
    description: 翻译文本
    parameters:
      type: object
      properties:
        text:
          type: string
        target:
          type: string
      required: [text, target]
---''';

      final doc = SkillMdParser.parse(content);

      expect(doc.isRawMarkdown, false);
      expect(doc.frontmatter['name'], 'translate');
      expect(doc.body, isEmpty);
    });

    test('frontmatter 工具列表解析', () {
      const content = '''---
name: multi_tool
description: 多工具技能
tools:
  - name: tool_a
    description: 工具A
  - name: tool_b
    description: 工具B
---
正文内容
''';

      final doc = SkillMdParser.parse(content);
      final toolsList = doc.frontmatter['tools'] as List;

      expect(toolsList.length, 2);
      expect(toolsList[0]['name'], 'tool_a');
      expect(toolsList[1]['name'], 'tool_b');
    });

    test('嵌套 YAML 参数解析', () {
      const content = '''---
name: test
description: 测试
tools:
  - name: analyze
    description: 分析
    parameters:
      type: object
      properties:
        input:
          type: string
          description: 输入数据
        options:
          type: object
          properties:
            mode:
              type: string
              enum: [fast, slow]
      required: [input]
---
''';

      final doc = SkillMdParser.parse(content);
      final params = (doc.frontmatter['tools'] as List)[0]['parameters']
          as Map<String, dynamic>;

      expect(params['type'], 'object');
      expect(params['required'], ['input']);
      final props = params['properties'] as Map<String, dynamic>;
      expect(props['input']['type'], 'string');
      final options = props['options']['properties'] as Map<String, dynamic>;
      expect(options['mode']['enum'], ['fast', 'slow']);
    });
  });

  // ============================================================
  // FolderSkillConfig 测试
  // ============================================================
  group('FolderSkillConfig', () {
    test('从纯 Markdown 创建（自动推断）', () {
      const content = '''# 代码摘要

请对以下代码生成简洁摘要：

{{code}}
''';

      final doc = SkillMdParser.parse(content);
      final config = FolderSkillConfig.fromDocument(doc, '/skills/code_summary');

      expect(config.name, 'code_summary');
      expect(config.description, '代码摘要');
      expect(config.tools.length, 1);
      expect(config.tools[0].name, 'code_summary');
      expect(config.tools[0].parameters['type'], 'object');
      expect(config.promptBody, contains('代码摘要'));
    });

    test('从带 frontmatter 的文档创建', () {
      const content = '''---
name: code_review
description: 代码审查技能
tools:
  - name: review_security
    description: 审查代码安全问题
    prompt_file: review_security.md
    resource_file: checklist.md
    requires_permission: true
    parameters:
      type: object
      properties:
        code: { type: string }
      required: [code]
---

## 通用审查规则
''';

      final doc = SkillMdParser.parse(content);
      final config = FolderSkillConfig.fromDocument(doc, '/skills/code_review');

      expect(config.name, 'code_review');
      expect(config.description, '代码审查技能');
      expect(config.tools.length, 1);
      expect(config.tools[0].name, 'review_security');
      expect(config.tools[0].promptFile, 'review_security.md');
      expect(config.tools[0].resourceFile, 'checklist.md');
      expect(config.tools[0].requiresPermission, true);
      expect(config.promptBody, contains('通用审查规则'));
    });

    test('frontmatter 无 tools 时创建默认工具', () {
      const content = '''---
name: simple
description: 简单技能
---

正文内容
''';

      final doc = SkillMdParser.parse(content);
      final config = FolderSkillConfig.fromDocument(doc, '/skills/simple');

      expect(config.name, 'simple');
      expect(config.tools.length, 1);
      expect(config.tools[0].name, 'simple');
      expect(config.tools[0].parameters['type'], 'object');
    });
  });

  // ============================================================
  // FolderToolDef 测试
  // ============================================================
  group('FolderToolDef', () {
    test('fromMap 基本解析', () {
      final map = {
        'name': 'review',
        'description': '代码审查',
        'prompt_file': 'review.md',
        'resource_file': 'checklist.md',
        'requires_permission': true,
        'parameters': {
          'type': 'object',
          'properties': {'code': {'type': 'string'}},
          'required': ['code'],
        },
      };

      final def = FolderToolDef.fromMap(map);

      expect(def.name, 'review');
      expect(def.description, '代码审查');
      expect(def.promptFile, 'review.md');
      expect(def.resourceFile, 'checklist.md');
      expect(def.requiresPermission, true);
      expect(def.parameters['type'], 'object');
    });

    test('fromMap 兼容旧字段名 prompt/resource', () {
      final map = {
        'name': 'old_tool',
        'description': '旧格式',
        'prompt': 'prompt.md',
        'resource': 'resource.md',
        'requiresPermission': true,
      };

      final def = FolderToolDef.fromMap(map);

      expect(def.promptFile, 'prompt.md');
      expect(def.resourceFile, 'resource.md');
      expect(def.requiresPermission, true);
    });

    test('fromMap 默认值', () {
      final def = FolderToolDef.fromMap({});

      expect(def.name, '');
      expect(def.description, '');
      expect(def.promptFile, isNull);
      expect(def.resourceFile, isNull);
      expect(def.requiresPermission, false);
      expect(def.parameters, isEmpty);
    });
  });

  // ============================================================
  // FolderToolAdapter 测试
  // ============================================================
  group('FolderToolAdapter', () {
    late FolderToolAdapter adapter;
    String? capturedPrompt;

    setUp(() {
      capturedPrompt = null;
      adapter = FolderToolAdapter(
        skillPath: '/test/skills/code_review',
        toolDef: const FolderToolDef(
          name: 'review_security',
          description: '审查代码安全问题',
          parameters: {
            'type': 'object',
            'properties': {'code': {'type': 'string'}},
            'required': ['code'],
          },
        ),
        promptBody: '请审查以下代码的安全问题：\n\n{{code}}',
        invokeLlm: (prompt) async {
          capturedPrompt = prompt;
          return '审查完成：发现3个安全问题';
        },
      );
    });

    test('基本属性', () {
      expect(adapter.name, 'review_security');
      expect(adapter.description, '审查代码安全问题');
      expect(adapter.requiresPermission, false);
      expect(adapter.permissionType, 'folder_skill');
    });

    test('toToolSpec 不包含 prompt 内容', () {
      final spec = adapter.toToolSpec();
      expect(spec.name, 'review_security');
      expect(spec.description, '审查代码安全问题');
      expect(spec.inputJsonSchema, isA<Map>());
      // ToolSpec 不包含 prompt，只有 name + description + schema
    });

    test('execute 注入参数并调用 LLM', () async {
      final result = await adapter.execute({'code': 'void main() {}'});

      expect(result.isError, false);
      expect(result.content, '审查完成：发现3个安全问题');
      expect(capturedPrompt, contains('void main() {}'));
      expect(capturedPrompt, isNot(contains('{{code}}')));
    });

    test('execute 多个参数注入', () async {
      final multiAdapter = FolderToolAdapter(
        skillPath: '/test/skills/translate',
        toolDef: const FolderToolDef(
          name: 'translate',
          description: '翻译',
          parameters: {
            'type': 'object',
            'properties': {
              'source_lang': {'type': 'string'},
              'target_lang': {'type': 'string'},
              'content': {'type': 'string'},
            },
          },
        ),
        promptBody: '将{{source_lang}}翻译为{{target_lang}}：\n\n{{content}}',
        invokeLlm: (prompt) async {
          capturedPrompt = prompt;
          return '翻译结果';
        },
      );

      await multiAdapter.execute({
        'source_lang': '中文',
        'target_lang': '英文',
        'content': '你好',
      });

      expect(capturedPrompt, contains('中文'));
      expect(capturedPrompt, contains('英文'));
      expect(capturedPrompt, contains('你好'));
      expect(capturedPrompt, isNot(contains('{{')));
    });

    test('execute LLM 异常时返回错误', () async {
      final errorAdapter = FolderToolAdapter(
        skillPath: '/test/skills/error',
        toolDef: const FolderToolDef(
          name: 'error_tool',
          description: '会出错',
        ),
        promptBody: 'prompt',
        invokeLlm: (_) async => throw Exception('LLM 调用失败'),
      );

      final result = await errorAdapter.execute({});

      expect(result.isError, true);
      expect(result.content, contains('技能执行失败'));
    });

    test('工具描述作为 promptBody 兜底', () async {
      final fallbackAdapter = FolderToolAdapter(
        skillPath: '/test/skills/fallback',
        toolDef: const FolderToolDef(
          name: 'fallback',
          description: '兜底描述 {{input}}',
          // promptBody 为空，将使用 description
        ),
        promptBody: '',
        invokeLlm: (prompt) async {
          capturedPrompt = prompt;
          return 'ok';
        },
      );

      await fallbackAdapter.execute({'input': 'hello'});
      expect(capturedPrompt, contains('兜底描述'));
      expect(capturedPrompt, contains('hello'));
    });
  });
}
