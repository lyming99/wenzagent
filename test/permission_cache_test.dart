import 'package:test/test.dart';
import 'package:wenzagent/src/agent/tool/permission_manager.dart';
import 'package:wenzagent/src/agent/tool/permission_rule.dart';
import 'package:wenzagent/src/agent/tool/agent_tool.dart';
import 'package:wenzagent/src/agent/agent_state.dart';

/// 用于测试的 mock 工具
class _MockTool implements AgentTool {
  @override
  final String name;
  @override
  final String permissionType;
  @override
  final String? permissionArgKey;
  @override
  final bool requiresPermission;

  _MockTool({
    required this.name,
    required this.permissionType,
    this.permissionArgKey,
    this.requiresPermission = true,
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // ===== Bug 修复验证：删除权限后缓存清理 =====

  group('ToolPermissionManager 权限删除缓存清理', () {
    late ToolPermissionManager manager;

    setUp(() {
      manager = ToolPermissionManager();
    });

    test('configure() 先清空再重建缓存', () {
      // 第一次 configure：添加 file_write 的 all 规则
      final config1 = PermissionConfig(whitelist: [
        PermissionRule(
          tool: 'file_write',
          arg: 'path',
          pattern: '.*',
          mode: PermissionMatchMode.all,
        ),
      ]);
      manager.configure(config1);
      expect(manager.allowedAlwaysPatterns, contains('file_write'));

      // 第二次 configure：新配置中不再有 file_write
      final config2 = PermissionConfig(whitelist: [
        PermissionRule(
          tool: 'command_execute',
          arg: 'command',
          pattern: '.*',
          mode: PermissionMatchMode.all,
        ),
      ]);
      manager.configure(config2);

      // file_write 应该被清掉
      expect(manager.allowedAlwaysPatterns, isNot(contains('file_write')));
      // command_write 应该被添加
      expect(manager.allowedAlwaysPatterns, contains('command_execute'));
    });

    test('removeApproval() 清理 all 模式缓存', () {
      final rule = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '.*',
        mode: PermissionMatchMode.all,
      );

      // 添加规则
      manager.addApproval(rule);
      expect(manager.allowedAlwaysPatterns, contains('file_write'));

      // 删除规则
      manager.removeApproval(rule);
      expect(manager.allowedAlwaysPatterns, isNot(contains('file_write')));
    });

    test('removeApproval() 无条件清理缓存 + 重建兜底', () {
      // 添加两条 all 规则
      final rule1 = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '.*',
        mode: PermissionMatchMode.all,
      );
      final rule2 = PermissionRule(
        tool: 'command_execute',
        arg: 'command',
        pattern: '.*',
        mode: PermissionMatchMode.all,
      );
      manager.addApproval(rule1);
      manager.addApproval(rule2);
      expect(manager.allowedAlwaysPatterns, containsAll(['file_write', 'command_execute']));

      // 删除 file_write
      manager.removeApproval(rule1);

      // file_write 被移除
      expect(manager.allowedAlwaysPatterns, isNot(contains('file_write')));
      // command_execute 仍然保留
      expect(manager.allowedAlwaysPatterns, contains('command_execute'));
    });

    test('删除后 checkPermission 不再自动放行', () async {
      final rule = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '.*',
        mode: PermissionMatchMode.all,
      );

      // 添加规则 → 自动放行
      manager.addApproval(rule);
      final tool = _MockTool(
        name: 'file_write',
        permissionType: 'file_write',
        permissionArgKey: 'path',
      );

      // 没有设置 onPermissionRequest，如果缓存命中则 allow，否则 deny
      // all 模式规则在白名单中，evaluate 返回 allow
      var decision = await manager.checkPermission(tool, {'path': '/test'});
      expect(decision, PermissionDecision.allow);

      // 删除规则
      manager.removeApproval(rule);

      // 再次检查：白名单为空，缓存已清理，没有 onPermissionRequest → deny
      decision = await manager.checkPermission(tool, {'path': '/test'});
      expect(decision, PermissionDecision.deny);
    });

    test('reloadPermissionConfig 模拟：删除后重新加载', () async {
      // 初始配置：file_write all 模式
      final config1 = PermissionConfig(whitelist: [
        PermissionRule(
          tool: 'file_write',
          arg: 'path',
          pattern: '.*',
          mode: PermissionMatchMode.all,
        ),
      ]);
      manager.configure(config1);

      final tool = _MockTool(
        name: 'file_write',
        permissionType: 'file_write',
        permissionArgKey: 'path',
      );

      // 初始状态：放行
      var decision = await manager.checkPermission(tool, {'path': '/test'});
      expect(decision, PermissionDecision.allow);

      // 模拟用户在客户端删除规则后，服务端重新加载空配置
      final config2 = PermissionConfig.empty();
      manager.configure(config2);

      // 删除后：白名单为空，缓存已清理 → deny
      decision = await manager.checkPermission(tool, {'path': '/test'});
      expect(decision, PermissionDecision.deny);
    });

    test('删除白名单中的 regex 规则后缓存一致', () {
      // 添加 all 模式和 regex 模式两条规则
      final allRule = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '.*',
        mode: PermissionMatchMode.all,
      );
      final regexRule = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: r'/workspace/.*',
        mode: PermissionMatchMode.regex,
      );
      manager.addApproval(allRule);
      manager.addApproval(regexRule);

      expect(manager.allowedAlwaysPatterns, contains('file_write'));
      expect(manager.config!.whitelist.length, equals(2));

      // 删除 regex 规则
      manager.removeApproval(regexRule);

      // all 规则仍在白名单中，缓存应保持一致
      expect(manager.config!.whitelist.length, equals(1));
      expect(manager.allowedAlwaysPatterns, contains('file_write'));

      // 再删除 all 规则
      manager.removeApproval(allRule);

      // 缓存应完全清空
      expect(manager.allowedAlwaysPatterns, isEmpty);
      expect(manager.config!.whitelist, isEmpty);
    });

    test('删除黑名单规则不影响白名单缓存', () {
      final allRule = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '.*',
        mode: PermissionMatchMode.all,
      );
      final blacklistRule = PermissionRule(
        tool: 'command_execute',
        arg: 'command',
        pattern: r'rm\s+-rf.*',
        mode: PermissionMatchMode.regex,
      );

      manager.addApproval(allRule);
      // 直接配置黑名单
      manager.configure(PermissionConfig(
        whitelist: [allRule],
        blacklist: [blacklistRule],
      ));

      expect(manager.allowedAlwaysPatterns, contains('file_write'));

      // 删除黑名单规则
      manager.removeApproval(blacklistRule);

      // 白名单缓存不受影响
      expect(manager.allowedAlwaysPatterns, contains('file_write'));
      expect(manager.config!.blacklist, isEmpty);
    });

    test('clearAllowedAlways() 清空所有缓存', () async {
      manager.addApproval(PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: '.*',
        mode: PermissionMatchMode.all,
      ));
      manager.addApproval(PermissionRule(
        tool: 'command_execute',
        arg: 'command',
        pattern: '.*',
        mode: PermissionMatchMode.all,
      ));

      expect(manager.allowedAlwaysPatterns.length, equals(2));

      manager.clearAllowedAlways();

      expect(manager.allowedAlwaysPatterns, isEmpty);
    });
  });

  // ===== 复合命令场景下的权限删除 =====

  group('ToolPermissionManager 复合命令权限删除', () {
    late ToolPermissionManager manager;

    setUp(() {
      manager = ToolPermissionManager();
    });

    test('删除白名单规则后复合命令不再自动放行', () async {
      // 添加 git.* 白名单规则
      final rule = PermissionRule(
        tool: 'command_execute',
        arg: 'command',
        pattern: r'git.*',
        mode: PermissionMatchMode.regex,
      );
      manager.addApproval(rule);

      final tool = _MockTool(
        name: 'command_execute',
        permissionType: 'command_execute',
        permissionArgKey: 'command',
      );

      // 复合命令全部在白名单 → allow
      var decision = await manager.checkPermission(
        tool,
        {'command': 'git add . && git commit -m "x" && git push'},
      );
      expect(decision, PermissionDecision.allow);

      // 删除白名单规则
      manager.removeApproval(rule);

      // 复合命令不再匹配 → 需要用户确认（没有 onPermissionRequest → deny）
      decision = await manager.checkPermission(
        tool,
        {'command': 'git add . && git commit -m "x" && git push'},
      );
      expect(decision, PermissionDecision.deny);
    });

    test('删除黑名单规则后复合命令不再被拒绝', () async {
      final blacklistRule = PermissionRule(
        tool: 'command_execute',
        arg: 'command',
        pattern: r'rm\s+-rf.*',
        mode: PermissionMatchMode.regex,
      );

      // 配置黑名单
      manager.configure(PermissionConfig(
        blacklist: [blacklistRule],
      ));

      final tool = _MockTool(
        name: 'command_execute',
        permissionType: 'command_execute',
        permissionArgKey: 'command',
      );

      // 复合命令中包含 rm -rf → deny
      var decision = await manager.checkPermission(
        tool,
        {'command': 'cd /tmp && rm -rf /'},
      );
      expect(decision, PermissionDecision.deny);

      // 删除黑名单规则
      manager.removeApproval(blacklistRule);

      // 复合命令不再被拒绝 → 没有 onPermissionRequest → deny（但原因不同）
      decision = await manager.checkPermission(
        tool,
        {'command': 'cd /tmp && rm -rf /'},
      );
      // 不再是黑名单拒绝（lastDenyMessage 应为 null）
      expect(manager.lastDenyMessage, isNull);
    });
  });
}
