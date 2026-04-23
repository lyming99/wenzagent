import 'dart:convert';

import 'package:test/test.dart';

import 'package:wenzagent/src/agent/tool/permission_rule.dart';

void main() {
  // ============================================================
  // group: PermissionRule.matches
  // ============================================================
  group('PermissionRule.matches', () {
    test('all 模式：仅匹配工具名', () {
      final rule = PermissionRule(
        tool: 'file_write',
        mode: PermissionMatchMode.all,
      );

      // 工具名匹配，无论参数如何都返回 true
      expect(rule.matches('file_write', {'path': '/any/path'}), isTrue);
      expect(rule.matches('file_write', {}), isTrue);

      // 工具名不匹配
      expect(rule.matches('file_read', {'path': '/any/path'}), isFalse);
    });

    test('exact 模式：精确匹配参数值', () {
      final rule = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '/workspace/project/main.dart',
        mode: PermissionMatchMode.exact,
      );

      // 精确匹配
      expect(
        rule.matches('file_write', {'path': '/workspace/project/main.dart'}),
        isTrue,
      );

      // 部分匹配不算
      expect(
        rule.matches('file_write', {'path': '/workspace/project/main.dart.bak'}),
        isFalse,
      );

      // 不同值
      expect(
        rule.matches('file_write', {'path': '/other/path'}),
        isFalse,
      );
    });

    test('regex 模式：正则匹配', () {
      final rule = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: r'/workspace/.*\.dart',
        mode: PermissionMatchMode.regex,
      );

      // 匹配正则
      expect(
        rule.matches('file_write', {'path': '/workspace/lib/main.dart'}),
        isTrue,
      );

      // 不匹配正则
      expect(
        rule.matches('file_write', {'path': '/workspace/lib/main.py'}),
        isFalse,
      );

      // 部分匹配也算
      expect(
        rule.matches('file_write', {'path': '/workspace/lib/utils/helper.dart'}),
        isTrue,
      );
    });

    test('regex 模式：command_execute 复合命令拆分匹配', () {
      final rule = PermissionRule(
        tool: 'command_execute',
        arg: 'command',
        pattern: r'git\s+status.*',
        mode: PermissionMatchMode.regex,
      );

      // 复合命令中包含匹配的子命令
      expect(
        rule.matches(
          'command_execute',
          {'command': 'git status && echo done'},
        ),
        isTrue,
      );

      // 复合命令中不包含匹配的子命令
      expect(
        rule.matches(
          'command_execute',
          {'command': 'ls -la && echo done'},
        ),
        isFalse,
      );
    });

    test('工具名不匹配返回 false', () {
      final rule = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '/test',
        mode: PermissionMatchMode.exact,
      );

      // 工具名不匹配，即使参数值匹配也返回 false
      expect(
        rule.matches('file_read', {'path': '/test'}),
        isFalse,
      );
    });

    test('arg 为 null 时工具名匹配即通过', () {
      final rule = PermissionRule(
        tool: 'file_write',
        arg: null,
        pattern: '',
        mode: PermissionMatchMode.exact,
      );

      // 工具名匹配，无参数检查
      expect(rule.matches('file_write', {'path': '/any/path'}), isTrue);
      expect(rule.matches('file_write', {}), isTrue);

      // 工具名不匹配
      expect(rule.matches('file_read', {'path': '/any/path'}), isFalse);
    });

    test('参数值非字符串返回 false', () {
      final rule = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '/test',
        mode: PermissionMatchMode.exact,
      );

      // 参数值是数字
      expect(rule.matches('file_write', {'path': 123}), isFalse);

      // 参数值是布尔值
      expect(rule.matches('file_write', {'path': true}), isFalse);

      // 参数值是 null
      expect(rule.matches('file_write', {'path': null}), isFalse);

      // 参数值是列表
      expect(rule.matches('file_write', {'path': ['/test']}), isFalse);
    });
  });

  // ============================================================
  // group: PermissionRule.derivePattern
  // ============================================================
  group('PermissionRule.derivePattern', () {
    test('路径类推导', () {
      // Unix 路径
      expect(
        PermissionRule.derivePattern('/workspace/project/main.dart'),
        equals(r'/workspace/project/.*'),
      );

      // Windows 路径
      expect(
        PermissionRule.derivePattern(r'C:\Users\test\file.txt'),
        equals(r'C:\\Users\\test\\.*'),
      );

      // 根目录路径
      expect(
        PermissionRule.derivePattern('/tmp/file.log'),
        equals(r'/tmp/.*'),
      );

      // 纯目录路径（末尾有分隔符）
      expect(
        PermissionRule.derivePattern('/workspace/project/'),
        equals(r'/workspace/project/.*'),
      );
    });

    test('命令类推导（command_execute）', () {
      expect(
        PermissionRule.derivePattern(
          'git commit -m "msg"',
          permissionType: 'command_execute',
        ),
        equals(r'git\s+commit.*'),
      );

      expect(
        PermissionRule.derivePattern(
          'npm install',
          permissionType: 'command_execute',
        ),
        equals(r'npm\s+install.*'),
      );

      // 单词命令
      expect(
        PermissionRule.derivePattern(
          'ls',
          permissionType: 'command_execute',
        ),
        equals(r'ls.*'),
      );
    });

    test('普通字符串推导', () {
      // 取第一个词 + .*
      expect(
        PermissionRule.derivePattern('hello world foo bar'),
        equals(r'hello.*'),
      );

      // 单个词
      expect(
        PermissionRule.derivePattern('test'),
        equals(r'test.*'),
      );

      // 带特殊字符的字符串（需要转义）
      expect(
        PermissionRule.derivePattern('value.with.dots'),
        equals(r'value\.with\.dots.*'),
      );
    });

    test('空字符串返回 .*', () {
      expect(
        PermissionRule.derivePattern(''),
        equals(r'.*'),
      );

      expect(
        PermissionRule.derivePattern('', permissionType: 'command_execute'),
        equals(r'.*'),
      );
    });
  });

  // ============================================================
  // group: PermissionRule.deriveCommandPattern
  // ============================================================
  group('PermissionRule.deriveCommandPattern', () {
    test('prefix 粒度', () {
      expect(
        PermissionRule.deriveCommandPattern(
          'git commit -m "hello"',
          granularity: CommandPatternGranularity.prefix,
        ),
        equals(r'git.*'),
      );

      expect(
        PermissionRule.deriveCommandPattern(
          'npm install express',
          granularity: CommandPatternGranularity.prefix,
        ),
        equals(r'npm.*'),
      );
    });

    test('base 粒度', () {
      expect(
        PermissionRule.deriveCommandPattern(
          'git commit -m "hello"',
          granularity: CommandPatternGranularity.base,
        ),
        equals(r'git\s+commit.*'),
      );

      expect(
        PermissionRule.deriveCommandPattern(
          'docker build -t myapp .',
          granularity: CommandPatternGranularity.base,
        ),
        equals(r'docker\s+build.*'),
      );

      // 单词命令退化为 prefix
      expect(
        PermissionRule.deriveCommandPattern(
          'ls',
          granularity: CommandPatternGranularity.base,
        ),
        equals(r'ls.*'),
      );
    });

    test('exact 粒度', () {
      // exact 粒度使用 RegExp.escape 转义完整命令
      expect(
        PermissionRule.deriveCommandPattern(
          'git commit -m "hello"',
          granularity: CommandPatternGranularity.exact,
        ),
        equals(RegExp.escape('git commit -m "hello"')),
      );

      expect(
        PermissionRule.deriveCommandPattern(
          'rm -rf /tmp/test',
          granularity: CommandPatternGranularity.exact,
        ),
        equals(RegExp.escape('rm -rf /tmp/test')),
      );
    });

    test('复合命令取第一个子命令', () {
      // 复合命令：取第一个子命令推导
      expect(
        PermissionRule.deriveCommandPattern(
          'git status && echo done',
          granularity: CommandPatternGranularity.base,
        ),
        equals(r'git\s+status.*'),
      );

      expect(
        PermissionRule.deriveCommandPattern(
          'cd /tmp && ls -la',
          granularity: CommandPatternGranularity.prefix,
        ),
        equals(r'cd.*'),
      );
    });

    test('空命令返回 .*', () {
      expect(
        PermissionRule.deriveCommandPattern(
          '',
          granularity: CommandPatternGranularity.prefix,
        ),
        equals(r'.*'),
      );

      expect(
        PermissionRule.deriveCommandPattern(
          '',
          granularity: CommandPatternGranularity.base,
        ),
        equals(r'.*'),
      );

      expect(
        PermissionRule.deriveCommandPattern(
          '',
          granularity: CommandPatternGranularity.exact,
        ),
        equals(r'.*'),
      );
    });
  });

  // ============================================================
  // group: PermissionRule.toJson/fromJson
  // ============================================================
  group('PermissionRule.toJson/fromJson', () {
    test('序列化往返', () {
      final rule = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: r'/workspace/.*\.dart',
        mode: PermissionMatchMode.regex,
      );

      final json = rule.toJson();
      final restored = PermissionRule.fromJson(json);

      expect(restored.tool, equals('file_write'));
      expect(restored.arg, equals('path'));
      expect(restored.pattern, equals(r'/workspace/.*\.dart'));
      expect(restored.mode, equals(PermissionMatchMode.regex));
      expect(restored, equals(rule));
    });

    test('createTime 处理', () {
      final time = DateTime(2025, 1, 15, 10, 30, 0);
      final rule = PermissionRule(
        tool: 'command_execute',
        arg: 'command',
        pattern: r'git\s+status.*',
        mode: PermissionMatchMode.regex,
        createTime: time,
      );

      final json = rule.toJson();
      expect(json['createTime'], equals(time.toIso8601String()));

      final restored = PermissionRule.fromJson(json);
      expect(restored.createTime, equals(time));
    });

    test('createTime 为 null 时序列化不包含该字段', () {
      final rule = PermissionRule(
        tool: 'file_write',
        mode: PermissionMatchMode.all,
      );

      final json = rule.toJson();
      expect(json.containsKey('createTime'), isFalse);

      final restored = PermissionRule.fromJson(json);
      expect(restored.createTime, isNull);
    });

    test('arg 为 null 时序列化不包含该字段', () {
      final rule = PermissionRule(
        tool: 'file_write',
        mode: PermissionMatchMode.all,
      );

      final json = rule.toJson();
      expect(json.containsKey('arg'), isFalse);

      final restored = PermissionRule.fromJson(json);
      expect(restored.arg, isNull);
    });

    test('fromJson 默认值处理', () {
      // mode 缺失时默认为 exact
      final restored = PermissionRule.fromJson({
        'tool': 'file_write',
        'pattern': '/test',
      });
      expect(restored.mode, equals(PermissionMatchMode.exact));
      expect(restored.pattern, equals('/test'));
      expect(restored.arg, isNull);
      expect(restored.createTime, isNull);
    });

    test('equality 和 hashCode', () {
      final rule1 = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '/test',
        mode: PermissionMatchMode.exact,
      );

      final rule2 = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '/test',
        mode: PermissionMatchMode.exact,
      );

      final rule3 = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '/other',
        mode: PermissionMatchMode.exact,
      );

      expect(rule1, equals(rule2));
      expect(rule1.hashCode, equals(rule2.hashCode));
      expect(rule1, isNot(equals(rule3)));
    });

    test('toString', () {
      final rule = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '/test',
        mode: PermissionMatchMode.regex,
      );

      expect(
        rule.toString(),
        equals(
          'PermissionRule(tool: file_write, arg: path, pattern: /test, mode: regex)',
        ),
      );
    });
  });

  // ============================================================
  // group: PermissionConfig.evaluate
  // ============================================================
  group('PermissionConfig.evaluate', () {
    test('黑名单命中 → deny', () {
      final config = PermissionConfig(
        blacklist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'rm\s+-rf.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      expect(
        config.evaluate('command_execute', {'command': 'rm -rf /'}),
        equals(PermissionVerdict.deny),
      );
    });

    test('白名单命中 → allow', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'file_write',
            arg: 'path',
            pattern: r'/workspace/.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      expect(
        config.evaluate('file_write', {'path': '/workspace/lib/main.dart'}),
        equals(PermissionVerdict.allow),
      );
    });

    test('无规则命中 → ask', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'file_write',
            arg: 'path',
            pattern: r'/workspace/.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      // 工具名不在白名单中
      expect(
        config.evaluate('command_execute', {'command': 'ls'}),
        equals(PermissionVerdict.ask),
      );

      // 工具名在白名单但参数不匹配
      expect(
        config.evaluate('file_write', {'path': '/other/path/file.txt'}),
        equals(PermissionVerdict.ask),
      );
    });

    test('黑名单优先于白名单', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
        blacklist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'rm\s+-rf.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      // 白名单匹配所有命令，但黑名单匹配 rm -rf → deny
      expect(
        config.evaluate('command_execute', {'command': 'rm -rf /tmp'}),
        equals(PermissionVerdict.deny),
      );

      // 不在黑名单中，白名单命中 → allow
      expect(
        config.evaluate('command_execute', {'command': 'git status'}),
        equals(PermissionVerdict.allow),
      );
    });

    test('空配置 → ask', () {
      final config = PermissionConfig.empty();

      expect(
        config.evaluate('file_write', {'path': '/any/path'}),
        equals(PermissionVerdict.ask),
      );

      expect(
        config.evaluate('command_execute', {'command': 'ls'}),
        equals(PermissionVerdict.ask),
      );
    });

    test('命令类型复合命令逐条判定', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'git\s+status.*',
            mode: PermissionMatchMode.regex,
          ),
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'echo\s+.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      // 两个子命令都在白名单中 → allow
      expect(
        config.evaluate(
          'command_execute',
          {'command': 'git status && echo done'},
        ),
        equals(PermissionVerdict.allow),
      );

      // 其中一个子命令不在白名单中 → ask
      expect(
        config.evaluate(
          'command_execute',
          {'command': 'git status && ls -la'},
        ),
        equals(PermissionVerdict.ask),
      );
    });

    test('复合命令任一命中黑名单 → deny', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'git\s+status.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
        blacklist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'rm\s+-rf.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      // 第一个子命令在白名单，但第二个命中黑名单 → deny
      expect(
        config.evaluate(
          'command_execute',
          {'command': 'git status && rm -rf /tmp'},
        ),
        equals(PermissionVerdict.deny),
      );

      // 反过来也一样
      expect(
        config.evaluate(
          'command_execute',
          {'command': 'rm -rf /tmp && git status'},
        ),
        equals(PermissionVerdict.deny),
      );
    });

    test('复合命令全部白名单 → allow', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'git\s+status.*',
            mode: PermissionMatchMode.regex,
          ),
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'git\s+diff.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      expect(
        config.evaluate(
          'command_execute',
          {'command': 'git status && git diff'},
        ),
        equals(PermissionVerdict.allow),
      );
    });

    test('单条命令不走复合命令逻辑', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'git\s+status.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      // 单条命令直接匹配
      expect(
        config.evaluate('command_execute', {'command': 'git status'}),
        equals(PermissionVerdict.allow),
      );

      expect(
        config.evaluate('command_execute', {'command': 'ls -la'}),
        equals(PermissionVerdict.ask),
      );
    });

    test('command 参数为 null 或空 → ask', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      expect(
        config.evaluate('command_execute', {}),
        equals(PermissionVerdict.ask),
      );

      expect(
        config.evaluate('command_execute', {'command': ''}),
        equals(PermissionVerdict.ask),
      );
    });
  });

  // ============================================================
  // group: PermissionConfig 不可变操作
  // ============================================================
  group('PermissionConfig 不可变操作', () {
    final whitelistRule = PermissionRule(
      tool: 'file_write',
      arg: 'path',
      pattern: '/test',
      mode: PermissionMatchMode.exact,
    );

    final blacklistRule = PermissionRule(
      tool: 'command_execute',
      arg: 'command',
      pattern: r'rm\s+-rf.*',
      mode: PermissionMatchMode.regex,
    );

    test('addWhitelistRule 返回新实例', () {
      final original = PermissionConfig.empty();
      final updated = original.addWhitelistRule(whitelistRule);

      expect(identical(original, updated), isFalse);
      expect(original.whitelist, isEmpty);
      expect(updated.whitelist, hasLength(1));
      expect(updated.whitelist.first, equals(whitelistRule));
    });

    test('removeWhitelistRule 返回新实例', () {
      final original = PermissionConfig(whitelist: [whitelistRule]);
      final updated = original.removeWhitelistRule(whitelistRule);

      expect(identical(original, updated), isFalse);
      expect(original.whitelist, hasLength(1));
      expect(updated.whitelist, isEmpty);
    });

    test('addBlacklistRule 返回新实例', () {
      final original = PermissionConfig.empty();
      final updated = original.addBlacklistRule(blacklistRule);

      expect(identical(original, updated), isFalse);
      expect(original.blacklist, isEmpty);
      expect(updated.blacklist, hasLength(1));
      expect(updated.blacklist.first, equals(blacklistRule));
    });

    test('removeBlacklistRule 返回新实例', () {
      final original = PermissionConfig(blacklist: [blacklistRule]);
      final updated = original.removeBlacklistRule(blacklistRule);

      expect(identical(original, updated), isFalse);
      expect(original.blacklist, hasLength(1));
      expect(updated.blacklist, isEmpty);
    });

    test('原实例不受影响', () {
      final original = PermissionConfig(
        whitelist: [whitelistRule],
        blacklist: [blacklistRule],
      );

      // 添加新规则
      final added = original.addWhitelistRule(
        PermissionRule(
          tool: 'file_read',
          mode: PermissionMatchMode.all,
        ),
      );
      expect(original.whitelist, hasLength(1));
      expect(added.whitelist, hasLength(2));

      // 移除规则
      final removed = original.removeWhitelistRule(whitelistRule);
      expect(original.whitelist, hasLength(1));
      expect(removed.whitelist, isEmpty);

      // 黑名单操作
      final addedBlack = original.addBlacklistRule(
        PermissionRule(
          tool: 'file_delete',
          mode: PermissionMatchMode.all,
        ),
      );
      expect(original.blacklist, hasLength(1));
      expect(addedBlack.blacklist, hasLength(2));

      final removedBlack = original.removeBlacklistRule(blacklistRule);
      expect(original.blacklist, hasLength(1));
      expect(removedBlack.blacklist, isEmpty);
    });

    test('移除不存在的规则不影响列表', () {
      final rule = PermissionRule(
        tool: 'nonexistent',
        mode: PermissionMatchMode.all,
      );
      final original = PermissionConfig(whitelist: [whitelistRule]);
      final updated = original.removeWhitelistRule(rule);

      expect(updated.whitelist, hasLength(1));
      expect(updated.whitelist.first, equals(whitelistRule));
    });
  });

  // ============================================================
  // group: PermissionConfig 序列化
  // ============================================================
  group('PermissionConfig 序列化', () {
    test('fromJsonString/toJsonString 往返', () {
      final original = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'file_write',
            arg: 'path',
            pattern: r'/workspace/.*',
            mode: PermissionMatchMode.regex,
          ),
          PermissionRule(
            tool: 'command_execute',
            mode: PermissionMatchMode.all,
          ),
        ],
        blacklist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'rm\s+-rf.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      final jsonStr = original.toJsonString();
      final restored = PermissionConfig.fromJsonString(jsonStr);

      expect(restored.whitelist, hasLength(2));
      expect(restored.blacklist, hasLength(1));

      // 验证白名单第一条规则
      expect(restored.whitelist[0].tool, equals('file_write'));
      expect(restored.whitelist[0].arg, equals('path'));
      expect(restored.whitelist[0].pattern, equals(r'/workspace/.*'));
      expect(restored.whitelist[0].mode, equals(PermissionMatchMode.regex));

      // 验证白名单第二条规则（all 模式，无 arg）
      expect(restored.whitelist[1].tool, equals('command_execute'));
      expect(restored.whitelist[1].arg, isNull);
      expect(restored.whitelist[1].mode, equals(PermissionMatchMode.all));

      // 验证黑名单规则
      expect(restored.blacklist[0].tool, equals('command_execute'));
      expect(restored.blacklist[0].pattern, equals(r'rm\s+-rf.*'));
      expect(restored.blacklist[0].mode, equals(PermissionMatchMode.regex));
    });

    test('fromMap/toMap 往返', () {
      final original = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'file_write',
            arg: 'path',
            pattern: '/test/path',
            mode: PermissionMatchMode.exact,
          ),
        ],
        blacklist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'rm\s+-rf.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      final map = original.toMap();
      final restored = PermissionConfig.fromMap(map);

      expect(restored.whitelist, hasLength(1));
      expect(restored.blacklist, hasLength(1));
      expect(restored.whitelist[0].tool, equals('file_write'));
      expect(restored.blacklist[0].tool, equals('command_execute'));
    });

    test('空字符串返回空配置', () {
      final config = PermissionConfig.fromJsonString('');

      expect(config.whitelist, isEmpty);
      expect(config.blacklist, isEmpty);
    });

    test('无效 JSON 返回空配置', () {
      final config = PermissionConfig.fromJsonString('not valid json');

      expect(config.whitelist, isEmpty);
      expect(config.blacklist, isEmpty);
    });

    test('无效 JSON 结构返回空配置', () {
      // 合法 JSON 但不是预期结构（如数组）
      final config = PermissionConfig.fromJsonString('[1, 2, 3]');

      expect(config.whitelist, isEmpty);
      expect(config.blacklist, isEmpty);
    });

    test('空配置序列化返回合法 JSON', () {
      final config = PermissionConfig.empty();
      final jsonStr = config.toJsonString();

      // 应该是合法的 JSON
      final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
      expect(parsed['whitelist'], isEmpty);
      expect(parsed['blacklist'], isEmpty);
    });

    test('序列化包含 createTime', () {
      final time = DateTime(2025, 6, 1, 12, 0, 0);
      final original = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'file_write',
            mode: PermissionMatchMode.all,
            createTime: time,
          ),
        ],
      );

      final jsonStr = original.toJsonString();
      final restored = PermissionConfig.fromJsonString(jsonStr);

      expect(restored.whitelist.first.createTime, equals(time));
    });
  });
}
