import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_event.dart';
import 'package:wenzagent/src/agent/notification/agent_notification_hub.dart';
import 'package:wenzagent/src/agent/tool/command_splitter.dart';
import 'package:wenzagent/src/agent/tool/permission_manager.dart';
import 'package:wenzagent/src/agent/tool/permission_rule.dart';

/// 复合命令权限队列测试
///
/// 验证复合命令场景下的权限请求行为：
/// - 复合命令被正确拆分为子命令
/// - 每个子命令触发独立的权限请求
/// - 黑名单子命令直接拒绝，白名单子命令直接放行
/// - 用户对子命令的授权/拒绝决策正确影响整体结果
/// - 权限请求事件正确携带子命令信息
void main() {
  // ===== 复合命令拆分基础验证 =====

  group('复合命令拆分基础', () {
    test('cd xxx & rm -rf * 拆分为 2 条子命令', () {
      final command = 'cd xxx & rm -rf *';
      expect(CommandSplitter.isCompound(command), isTrue);

      final subCommands = CommandSplitter.split(command);
      expect(subCommands, hasLength(2));
      expect(subCommands[0], equals('cd xxx'));
      expect(subCommands[1], equals('rm -rf *'));
    });

    test('git add . && git commit && git push 拆分为 3 条子命令', () {
      final command = 'git add . && git commit -m "init" && git push';
      final subCommands = CommandSplitter.split(command);
      expect(subCommands, hasLength(3));
      expect(subCommands[0], equals('git add .'));
      expect(subCommands[1], equals('git commit -m init'));
      expect(subCommands[2], equals('git push'));
    });

    test('cat file | grep error | wc -l 拆分为 3 条子命令', () {
      final command = 'cat file | grep error | wc -l';
      final subCommands = CommandSplitter.split(command);
      expect(subCommands, hasLength(3));
      expect(subCommands[0], equals('cat file'));
      expect(subCommands[1], equals('grep error'));
      expect(subCommands[2], equals('wc -l'));
    });

    test('混合分隔符 cd /tmp ; ls && cat a | grep b 拆分为 4 条', () {
      final command = 'cd /tmp ; ls && cat a | grep b';
      final subCommands = CommandSplitter.split(command);
      expect(subCommands, hasLength(4));
      expect(subCommands, equals(['cd /tmp', 'ls', 'cat a', 'grep b']));
    });

    test('引号内的分隔符不被拆分', () {
      final command = 'echo "cd /tmp && rm -rf /" & ls';
      final subCommands = CommandSplitter.split(command);
      expect(subCommands, hasLength(2));
      expect(subCommands[0], equals('echo cd /tmp && rm -rf /'));
      expect(subCommands[1], equals('ls'));
    });
  });

  // ===== PermissionConfig 复合命令逐条判定 =====

  group('PermissionConfig 复合命令逐条判定', () {
    test('全部子命令不在名单 → 全部 ask', () {
      final config = PermissionConfig();
      final command = 'cd /tmp & rm -rf *';

      // 每个子命令都应该返回 ask
      final subCommands = CommandSplitter.split(command);
      for (final cmd in subCommands) {
        expect(
          config.evaluate('command_execute', {'command': cmd}),
          equals(PermissionVerdict.ask),
        );
      }
    });

    test('任一子命令命中黑名单 → deny', () {
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

      // rm -rf * 命中黑名单 → deny
      expect(
        config.evaluate('command_execute', {'command': 'rm -rf *'}),
        equals(PermissionVerdict.deny),
      );
    });

    test('所有子命令命中白名单 → allow', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'(cd|ls).*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      // cd /tmp 和 ls 都在白名单 → allow
      expect(
        config.evaluate('command_execute', {'command': 'cd /tmp & ls'}),
        equals(PermissionVerdict.allow),
      );
    });

    test('部分子命令在白名单 → 部分允许部分 ask', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'cd.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      final subCommands = CommandSplitter.split('cd /tmp & rm -rf *');

      // cd /tmp → allow（白名单命中）
      expect(
        config.evaluate('command_execute', {'command': subCommands[0]}),
        equals(PermissionVerdict.allow),
      );

      // rm -rf * → ask（不在白名单也不在黑名单）
      expect(
        config.evaluate('command_execute', {'command': subCommands[1]}),
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

      // rm -rf * 在黑名单中，即使 .* 白名单覆盖一切 → deny
      expect(
        config.evaluate('command_execute', {'command': 'rm -rf *'}),
        equals(PermissionVerdict.deny),
      );

      // cd /tmp 不在黑名单，在白名单 → allow
      expect(
        config.evaluate('command_execute', {'command': 'cd /tmp'}),
        equals(PermissionVerdict.allow),
      );
    });
  });

  // ===== 复合命令权限请求队列模拟 =====

  group('复合命令权限请求队列模拟', () {
    /// 子命令权限检查结果
    ({String subCommand, PermissionVerdict verdict, AgentPermissionRequest? request, String? denyReason})
        _checkSubCommand(PermissionConfig config, String cmd, int index, int total) {
      final verdict = config.evaluate('command_execute', {'command': cmd});

      AgentPermissionRequest? request;
      String? denyReason;

      if (verdict == PermissionVerdict.deny) {
        denyReason = '安全策略阻止: 命令匹配黑名单规则';
      } else if (verdict == PermissionVerdict.ask) {
        final suggestedPattern = PermissionRule.derivePattern(
          cmd,
          permissionType: 'command_execute',
        );
        request = AgentPermissionRequest(
          requestId: 'perm_${index}_command_execute',
          type: 'tool_execution',
          description: '子命令 ${index + 1}/$total 请求执行权限',
          functionName: 'command_execute',
          permissionPattern: 'command_execute',
          permissionType: 'command_execute',
          permissionArgKey: 'command',
          permissionArgValue: cmd,
          suggestedPattern: suggestedPattern,
        );
      }

      return (subCommand: cmd, verdict: verdict, request: request, denyReason: denyReason);
    }

    test('cd /tmp & rm -rf * → 2 条权限请求', () {
      final config = PermissionConfig();
      final compoundCommand = 'cd /tmp & rm -rf *';
      final subCommands = CommandSplitter.split(compoundCommand);

      final results = <({String subCommand, PermissionVerdict verdict, AgentPermissionRequest? request, String? denyReason})>[];
      for (var i = 0; i < subCommands.length; i++) {
        results.add(_checkSubCommand(config, subCommands[i], i, subCommands.length));
      }

      // 应该有 2 条子命令的判定结果
      expect(results, hasLength(2));

      // 第 1 条：cd /tmp → ask（需要用户确认）
      expect(results[0].subCommand, equals('cd /tmp'));
      expect(results[0].verdict, equals(PermissionVerdict.ask));
      expect(results[0].request, isNotNull);
      expect(results[0].request!.permissionArgValue, equals('cd /tmp'));

      // 第 2 条：rm -rf * → ask（需要用户确认）
      expect(results[1].subCommand, equals('rm -rf *'));
      expect(results[1].verdict, equals(PermissionVerdict.ask));
      expect(results[1].request, isNotNull);
      expect(results[1].request!.permissionArgValue, equals('rm -rf *'));
    });

    test('cd /tmp & rm -rf * 黑名单 → 0 条权限请求，rm 直接拒绝', () {
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

      final compoundCommand = 'cd /tmp & rm -rf *';
      final subCommands = CommandSplitter.split(compoundCommand);

      final results = <({String subCommand, PermissionVerdict verdict, AgentPermissionRequest? request, String? denyReason})>[];
      for (var i = 0; i < subCommands.length; i++) {
        results.add(_checkSubCommand(config, subCommands[i], i, subCommands.length));
      }

      expect(results, hasLength(2));

      // cd /tmp → ask
      expect(results[0].verdict, equals(PermissionVerdict.ask));
      expect(results[0].request, isNotNull);

      // rm -rf * → deny（黑名单命中，不生成请求，直接拒绝）
      expect(results[1].verdict, equals(PermissionVerdict.deny));
      expect(results[1].request, isNull);
      expect(results[1].denyReason, isNotNull);
    });

    test('git add . && git commit && git push 白名单 → 0 条权限请求', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'git.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      final compoundCommand = 'git add . && git commit -m "x" && git push';
      final subCommands = CommandSplitter.split(compoundCommand);

      final results = <({String subCommand, PermissionVerdict verdict, AgentPermissionRequest? request, String? denyReason})>[];
      for (var i = 0; i < subCommands.length; i++) {
        results.add(_checkSubCommand(config, subCommands[i], i, subCommands.length));
      }

      expect(results, hasLength(3));

      // 所有子命令都在白名单 → 全部 allow，无请求
      for (final item in results) {
        expect(item.verdict, equals(PermissionVerdict.allow));
        expect(item.request, isNull);
      }
    });

    test('cd /tmp & rm -rf * & ls → cd 和 ls 在白名单，rm 需请求', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'(cd|ls).*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      final compoundCommand = 'cd /tmp & rm -rf * & ls -la';
      final subCommands = CommandSplitter.split(compoundCommand);

      final results = <({String subCommand, PermissionVerdict verdict, AgentPermissionRequest? request, String? denyReason})>[];
      for (var i = 0; i < subCommands.length; i++) {
        results.add(_checkSubCommand(config, subCommands[i], i, subCommands.length));
      }

      expect(results, hasLength(3));

      // cd /tmp → allow（白名单）
      expect(results[0].verdict, equals(PermissionVerdict.allow));
      expect(results[0].request, isNull);

      // rm -rf * → ask（需要请求）
      expect(results[1].verdict, equals(PermissionVerdict.ask));
      expect(results[1].request, isNotNull);
      expect(results[1].request!.permissionArgValue, equals('rm -rf *'));

      // ls -la → allow（白名单）
      expect(results[2].verdict, equals(PermissionVerdict.allow));
      expect(results[2].request, isNull);
    });

    test('管道 cat file | grep error | wc -l → 部分需要请求', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'(cat|grep).*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      final compoundCommand = 'cat file | grep error | wc -l';
      final subCommands = CommandSplitter.split(compoundCommand);

      final results = <({String subCommand, PermissionVerdict verdict, AgentPermissionRequest? request, String? denyReason})>[];
      for (var i = 0; i < subCommands.length; i++) {
        results.add(_checkSubCommand(config, subCommands[i], i, subCommands.length));
      }

      expect(results, hasLength(3));

      // cat file → allow
      expect(results[0].verdict, equals(PermissionVerdict.allow));

      // grep error → allow
      expect(results[1].verdict, equals(PermissionVerdict.allow));

      // wc -l → ask（不在白名单）
      expect(results[2].verdict, equals(PermissionVerdict.ask));
      expect(results[2].request, isNotNull);
      expect(results[2].request!.permissionArgValue, equals('wc -l'));
    });

    test('suggestedPattern 正确推导子命令模式', () {
      final config = PermissionConfig();
      final compoundCommand = 'cd /tmp & rm -rf *';
      final subCommands = CommandSplitter.split(compoundCommand);

      final results = <({String subCommand, PermissionVerdict verdict, AgentPermissionRequest? request, String? denyReason})>[];
      for (var i = 0; i < subCommands.length; i++) {
        results.add(_checkSubCommand(config, subCommands[i], i, subCommands.length));
      }

      // cd /tmp → suggestedPattern 应为 "cd\\s+/tmp.*"（base 粒度：命令名+第一个参数）
      expect(results[0].request!.suggestedPattern, equals(r'cd\s+/tmp.*'));

      // rm -rf * → suggestedPattern 应为 "rm\\s+-rf.*"
      expect(results[1].request!.suggestedPattern, equals(r'rm\s+-rf.*'));
    });
  });

  // ===== 权限请求事件链验证 =====

  group('复合命令权限请求事件链', () {
    test('复合命令逐条发送权限 pending 事件', () async {
      final hub = AgentNotificationHub();
      final events = <AgentNotificationEvent>[];
      final sub = hub.stream(employeeId: 'emp-1').listen(events.add);

      final compoundCommand = 'cd /tmp & rm -rf *';
      final subCommands = CommandSplitter.split(compoundCommand);

      // 模拟逐条发送权限请求 pending 事件
      for (var i = 0; i < subCommands.length; i++) {
        final cmd = subCommands[i];
        final request = AgentPermissionRequest(
          requestId: 'perm_${i}_command_execute',
          type: 'tool_execution',
          description: '子命令 ${i + 1}/${subCommands.length} 请求执行权限',
          functionName: 'command_execute',
          permissionPattern: 'command_execute',
          permissionType: 'command_execute',
          permissionArgKey: 'command',
          permissionArgValue: cmd,
          suggestedPattern: PermissionRule.derivePattern(
            cmd,
            permissionType: 'command_execute',
          ),
        );

        hub.onPermissionPending(
          employeeId: 'emp-1',
          fromDeviceId: 'device-1',
          permissionJson: jsonEncode(request.toMap()),
        );
      }

      // 等待事件传播
      await Future.delayed(Duration(milliseconds: 100));

      // 应该收到 2 条权限 pending 事件
      expect(events, hasLength(2));

      // 第 1 条事件：cd /tmp
      expect(events[0], isA<AgentPermissionPendingEvent>());
      final pending0 = events[0] as AgentPermissionPendingEvent;
      final req0 = AgentPermissionRequest.fromMap(
        jsonDecode(pending0.permissionJson) as Map<String, dynamic>,
      );
      expect(req0.permissionArgValue, equals('cd /tmp'));
      expect(req0.suggestedPattern, equals(r'cd\s+/tmp.*'));

      // 第 2 条事件：rm -rf *
      expect(events[1], isA<AgentPermissionPendingEvent>());
      final pending1 = events[1] as AgentPermissionPendingEvent;
      final req1 = AgentPermissionRequest.fromMap(
        jsonDecode(pending1.permissionJson) as Map<String, dynamic>,
      );
      expect(req1.permissionArgValue, equals('rm -rf *'));
      expect(req1.suggestedPattern, equals(r'rm\s+-rf.*'));

      sub.cancel();
    });

    test('用户逐条授权后所有子命令被允许', () async {
      final config = PermissionConfig();
      final compoundCommand = 'cd /tmp & rm -rf *';
      final subCommands = CommandSplitter.split(compoundCommand);

      // 模拟用户对每条子命令的授权决策
      final userDecisions = <String, PermissionDecision>{
        'cd /tmp': PermissionDecision.allow,
        'rm -rf *': PermissionDecision.allow,
      };

      // 逐条检查并记录结果
      final results = <String, PermissionDecision>{};
      for (final cmd in subCommands) {
        final verdict =
            config.evaluate('command_execute', {'command': cmd});

        if (verdict == PermissionVerdict.allow) {
          results[cmd] = PermissionDecision.allow;
        } else if (verdict == PermissionVerdict.deny) {
          results[cmd] = PermissionDecision.deny;
        } else {
          // ask → 模拟用户授权
          results[cmd] = userDecisions[cmd] ?? PermissionDecision.deny;
        }
      }

      // 所有子命令都被用户允许
      expect(results['cd /tmp'], equals(PermissionDecision.allow));
      expect(results['rm -rf *'], equals(PermissionDecision.allow));
    });

    test('用户拒绝某条子命令后整体中止', () async {
      final config = PermissionConfig();
      final compoundCommand = 'cd /tmp & rm -rf * & ls -la';
      final subCommands = CommandSplitter.split(compoundCommand);

      // 模拟用户拒绝 rm -rf *
      final userDecisions = <String, PermissionDecision>{
        'cd /tmp': PermissionDecision.allow,
        'rm -rf *': PermissionDecision.deny,
        // ls -la 不会被检查到，因为前面的子命令被拒绝后中止
      };

      final results = <String, PermissionDecision>{};
      var aborted = false;

      for (final cmd in subCommands) {
        if (aborted) break;

        final verdict =
            config.evaluate('command_execute', {'command': cmd});

        if (verdict == PermissionVerdict.allow) {
          results[cmd] = PermissionDecision.allow;
        } else if (verdict == PermissionVerdict.deny) {
          results[cmd] = PermissionDecision.deny;
          aborted = true;
        } else {
          final decision = userDecisions[cmd] ?? PermissionDecision.deny;
          results[cmd] = decision;
          if (decision == PermissionDecision.deny) {
            aborted = true;
          }
        }
      }

      // cd /tmp 被允许
      expect(results['cd /tmp'], equals(PermissionDecision.allow));
      // rm -rf * 被用户拒绝
      expect(results['rm -rf *'], equals(PermissionDecision.deny));
      // ls -la 因为前面被拒绝，未执行检查
      expect(results.containsKey('ls -la'), isFalse);
    });

    test('黑名单子命令直接拒绝，不发送权限请求', () async {
      final hub = AgentNotificationHub();
      final events = <AgentNotificationEvent>[];
      final sub = hub.stream(employeeId: 'emp-1').listen(events.add);

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

      final compoundCommand = 'cd /tmp & rm -rf *';
      final subCommands = CommandSplitter.split(compoundCommand);

      for (var i = 0; i < subCommands.length; i++) {
        final cmd = subCommands[i];
        final verdict =
            config.evaluate('command_execute', {'command': cmd});

        if (verdict == PermissionVerdict.deny) {
          // 黑名单命中 → 发送状态变更通知（拒绝），不发送权限 pending 请求
          hub.onAgentStatusChanged(
            employeeId: 'emp-1',
            fromDeviceId: 'device-1',
            status: 'permissionDenied',
            extra: {
              'toolName': 'command_execute',
              'command': cmd,
              'reason': '安全策略阻止: 命令匹配黑名单规则',
            },
          );
        } else if (verdict == PermissionVerdict.ask) {
          // ask → 发送权限 pending 事件
          final request = AgentPermissionRequest(
            requestId: 'perm_${i}_command_execute',
            type: 'tool_execution',
            description: '子命令 ${i + 1}/${subCommands.length} 请求执行权限',
            functionName: 'command_execute',
            permissionPattern: 'command_execute',
            permissionType: 'command_execute',
            permissionArgKey: 'command',
            permissionArgValue: cmd,
            suggestedPattern: PermissionRule.derivePattern(
              cmd,
              permissionType: 'command_execute',
            ),
          );
          hub.onPermissionPending(
            employeeId: 'emp-1',
            fromDeviceId: 'device-1',
            permissionJson: jsonEncode(request.toMap()),
          );
        }
      }

      await Future.delayed(Duration(milliseconds: 100));

      // 应该收到 1 条权限 pending + 1 条状态变更
      expect(events, hasLength(2));

      // 第 1 条：cd /tmp 的权限 pending
      expect(events[0], isA<AgentPermissionPendingEvent>());
      final pending0 = events[0] as AgentPermissionPendingEvent;
      final req0 = AgentPermissionRequest.fromMap(
        jsonDecode(pending0.permissionJson) as Map<String, dynamic>,
      );
      expect(req0.permissionArgValue, equals('cd /tmp'));

      // 第 2 条：rm -rf * 的状态变更通知（拒绝）
      expect(events[1], isA<AgentStatusNotifyEvent>());
      final statusEvent = events[1] as AgentStatusNotifyEvent;
      expect(statusEvent.status, equals('permissionDenied'));
      expect(statusEvent.extra!['command'], equals('rm -rf *'));

      sub.cancel();
    });
  });

  // ===== 复杂复合命令场景 =====

  group('复杂复合命令场景', () {
    test('三段管道 cat file | grep error | wc -l 逐条判定', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'(cat|grep|wc).*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      final subCommands =
          CommandSplitter.split('cat file | grep error | wc -l');
      expect(subCommands, hasLength(3));

      // 所有子命令都在白名单
      for (final cmd in subCommands) {
        expect(
          config.evaluate('command_execute', {'command': cmd}),
          equals(PermissionVerdict.allow),
        );
      }
    });

    test('混合分隔符 cd /tmp ; npm install && echo done 逐条判定', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'(cd|echo).*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      final subCommands = CommandSplitter.split(
          'cd /tmp ; npm install && echo done');
      expect(subCommands, hasLength(3));

      // cd /tmp → allow
      expect(
        config.evaluate('command_execute', {'command': subCommands[0]}),
        equals(PermissionVerdict.allow),
      );

      // npm install → ask
      expect(
        config.evaluate('command_execute', {'command': subCommands[1]}),
        equals(PermissionVerdict.ask),
      );

      // echo done → allow
      expect(
        config.evaluate('command_execute', {'command': subCommands[2]}),
        equals(PermissionVerdict.allow),
      );
    });

    test('用户 allowAlways 后同类命令不再请求', () {
      // 模拟用户对 cd 类命令选择了"始终允许"
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'cd.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      // 第一次：cd /tmp → allow（白名单）
      expect(
        config.evaluate('command_execute', {'command': 'cd /tmp'}),
        equals(PermissionVerdict.allow),
      );

      // 后续同类命令：cd /var → allow（白名单匹配）
      expect(
        config.evaluate('command_execute', {'command': 'cd /var'}),
        equals(PermissionVerdict.allow),
      );

      // 但其他命令仍然需要确认
      expect(
        config.evaluate('command_execute', {'command': 'rm -rf *'}),
        equals(PermissionVerdict.ask),
      );
    });

    test('引号保护防止拆分绕过', () {
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

      // 'echo "rm -rf /"' 中的 rm 不是命令，不应被黑名单命中
      final subCommands =
          CommandSplitter.split('echo "rm -rf /" & ls');
      expect(subCommands, hasLength(2));

      // echo "rm -rf /" → 命中黑名单（regex dotAll 匹配整个字符串，包含 rm -rf / 子串）
      expect(
        config.evaluate(
            'command_execute', {'command': subCommands[0]}),
        equals(PermissionVerdict.deny),
      );

      // ls → 不命中黑名单
      expect(
        config.evaluate(
            'command_execute', {'command': subCommands[1]}),
        equals(PermissionVerdict.ask),
      );
    });
  });
}
