import 'package:test/test.dart';
import 'package:wenzagent/src/agent/tool/agent_tool.dart';
import 'package:wenzagent/src/agent/tool/permission_manager.dart';
import 'package:wenzagent/src/agent/tool/permission_rule.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/skill/mcp/mcp_tool_adapter.dart';
import 'package:wenzagent/src/skill/mcp/mcp_client.dart';

/// Mock MCP 客户端
class _MockMcpClient implements McpClient {
  final String content;

  _MockMcpClient({this.content = ''});

  @override
  Future<McpToolCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    return McpToolCallResult(
      content: content.isEmpty ? 'result of $name' : content,
    );
  }

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<McpToolDefinition>> listTools() async => [];

  @override
  Future<bool> ping() async => true;

  @override
  bool get isReconnecting => false;

  @override
  Future<void> reconnect() async {}

  @override
  Stream<McpReconnectEvent> get onReconnect => const Stream.empty();
}

/// Mock 工具（用于对比内置工具行为）
class _MockBuiltinTool extends AgentTool {
  final String _name;
  final String _permissionType;
  final String? _permissionArgKey;

  _MockBuiltinTool({
    required String name,
    required String permissionType,
    String? permissionArgKey,
  }) : _name = name,
       _permissionType = permissionType,
       _permissionArgKey = permissionArgKey;

  @override
  String get name => _name;

  @override
  String get description => 'mock tool: $name';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': <String, dynamic>{},
  };

  @override
  bool get requiresPermission => true;

  @override
  String get permissionType => _permissionType;

  @override
  String? get permissionArgKey => _permissionArgKey;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async =>
      ToolResult.success('ok');
}

void main() {
  // ===== 修复验证: permissionType 现在等于工具名 =====

  group('修复验证: permissionType 精确到工具名', () {
    test('不同 MCP 工具的 permissionType 各不相同', () {
      final client = _MockMcpClient();

      final toolA = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(name: 'read_file', description: '读取文件'),
      );
      final toolB = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(
          name: 'execute_command',
          description: '执行命令',
        ),
      );
      final toolC = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(
          name: 'delete_resource',
          description: '删除资源',
        ),
      );

      // ✅ 修复后：每个 MCP 工具的 permissionType 等于其工具名
      expect(toolA.permissionType, equals('mcp_read_file'));
      expect(toolB.permissionType, equals('mcp_execute_command'));
      expect(toolC.permissionType, equals('mcp_delete_resource'));

      // permissionType 互不相同
      expect(toolA.permissionType == toolB.permissionType, isFalse);
      expect(toolA.permissionType == toolC.permissionType, isFalse);
      expect(toolB.permissionType == toolC.permissionType, isFalse);
    });

    test('permissionType 与 name 一致', () {
      final client = _MockMcpClient();
      final tool = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(name: 'query_db', description: '查询数据库'),
      );

      // ✅ 修复后：permissionType 等于 name
      expect(tool.permissionType, equals(tool.name));
      expect(tool.permissionType, equals('mcp_query_db'));
    });

    test('权限请求中 permissionType 精确到具体工具', () async {
      final client = _MockMcpClient();
      final tool = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(
          name: 'dangerous_op',
          description: '危险操作',
        ),
      );

      final manager = ToolPermissionManager();
      AgentPermissionRequest? capturedRequest;
      manager.onPermissionRequest = (request) async {
        capturedRequest = request;
        return PermissionDecision.allow;
      };

      await manager.checkPermission(tool, {'target': 'important_data'});

      // ✅ 修复后：权限请求中 permissionType 精确到工具名
      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.permissionType, equals('mcp_dangerous_op'));
      expect(capturedRequest!.functionName, equals('mcp_dangerous_op'));
    });
  });

  // ===== 修复验证: allowAlways 不再影响其他 MCP 工具 =====

  group('修复验证: allowAlways 精确到工具', () {
    test('允许一个 MCP 工具后，其他 MCP 工具不受影响', () async {
      final client = _MockMcpClient();

      final toolA = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(name: 'safe_read', description: '安全读取'),
      );
      final toolB = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(
          name: 'dangerous_delete',
          description: '危险删除',
        ),
      );

      final manager = ToolPermissionManager();

      // 用户允许 safe_read 并选择"始终允许"
      manager.onPermissionRequest = (request) async {
        return PermissionDecision.allowAlways;
      };
      await manager.checkPermission(toolA, {});

      // ✅ 修复后：allowAlways 缓存中存的是 'mcp_safe_read'（而非 'mcp'）
      expect(manager.allowedAlwaysPatterns, contains('mcp_safe_read'));
      expect(
        manager.allowedAlwaysPatterns,
        isNot(contains('mcp_dangerous_delete')),
      );

      // dangerous_delete 仍需用户确认
      PermissionDecision? decisionB;
      manager.onPermissionRequest = (request) async {
        decisionB = PermissionDecision.deny;
        return PermissionDecision.deny;
      };
      final result = await manager.checkPermission(toolB, {});

      // ✅ 修复后：dangerous_delete 不被自动允许
      expect(result, equals(PermissionDecision.deny));
      expect(decisionB, isNotNull); // onPermissionRequest 被调用了
    });

    test('白名单 all 模式规则只影响指定工具', () async {
      final client = _MockMcpClient();

      final allowedTool = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(name: 'safe_read', description: '安全读取'),
      );
      final otherTool = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(
          name: 'dangerous_delete',
          description: '危险删除',
        ),
      );

      // 只允许 mcp_safe_read
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'mcp_safe_read', // ✅ 精确到工具名
            mode: PermissionMatchMode.all,
          ),
        ],
      );

      final manager = ToolPermissionManager();
      manager.configure(config);

      // ✅ safe_read 被允许
      final safeDecision = await manager.checkPermission(allowedTool, {});
      expect(safeDecision, equals(PermissionDecision.allow));

      // ✅ dangerous_delete 不受影响（需要用户确认）
      PermissionDecision? capturedDecision;
      manager.onPermissionRequest = (request) async {
        capturedDecision = PermissionDecision.deny;
        return PermissionDecision.deny;
      };
      final dangerDecision = await manager.checkPermission(otherTool, {});
      expect(dangerDecision, equals(PermissionDecision.deny));
      expect(capturedDecision, isNotNull);
    });
  });

  // ===== 修复验证: 权限规则持久化精确到工具 =====

  group('修复验证: 权限规则持久化精确到工具', () {
    test('持久化的规则 tool 字段为具体工具名', () async {
      final client = _MockMcpClient();
      final tool = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(name: 'db_query', description: '数据库查询'),
      );

      final manager = ToolPermissionManager();
      PermissionConfig? savedConfig;
      manager.onConfigChanged = (config) {
        savedConfig = config;
      };

      // 模拟 _persistApproval 的行为：
      // 修复后 request.permissionType = 'mcp_db_query'
      final requestTool = tool.permissionType; // 'mcp_db_query'
      final rule = PermissionRule(
        tool: requestTool, // ✅ 'mcp_db_query' 而非 'mcp'
        pattern: '.*',
        mode: PermissionMatchMode.regex,
      );
      manager.addApproval(rule);

      // ✅ 持久化的规则精确到工具
      expect(savedConfig, isNotNull);
      expect(savedConfig!.whitelist.length, equals(1));
      expect(savedConfig!.whitelist.first.tool, equals('mcp_db_query'));
    });

    test('序列化/反序列化后规则保留精确工具名', () {
      final rule = PermissionRule(
        tool: 'mcp_db_query',
        pattern: '/workspace/.*',
        mode: PermissionMatchMode.regex,
      );

      final json = rule.toJson();
      expect(json['tool'], equals('mcp_db_query'));

      final restored = PermissionRule.fromJson(json);
      expect(restored.tool, equals('mcp_db_query'));

      // ✅ 反序列化后仍然精确
    });
  });

  // ===== 修复验证: 黑名单精确阻止 =====

  group('修复验证: 黑名单精确阻止特定 MCP 工具', () {
    test('黑名单只阻止指定工具，不影响其他 MCP 工具', () async {
      final client = _MockMcpClient();

      final safeTool = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(name: 'safe_read', description: '安全读取'),
      );
      final dangerTool = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(
          name: 'danger_delete',
          description: '危险删除',
        ),
      );

      // 只阻止 mcp_danger_delete
      final config = PermissionConfig(
        blacklist: [
          PermissionRule(
            tool: 'mcp_danger_delete', // ✅ 精确到工具名
            mode: PermissionMatchMode.all,
          ),
        ],
      );

      final manager = ToolPermissionManager();
      manager.configure(config);

      // ✅ safe_read 不受影响
      PermissionDecision? safeCaptured;
      manager.onPermissionRequest = (request) async {
        safeCaptured = PermissionDecision.allow;
        return PermissionDecision.allow;
      };
      final safeDecision = await manager.checkPermission(safeTool, {});
      expect(safeDecision, equals(PermissionDecision.allow));
      expect(safeCaptured, isNotNull); // 需要用户确认（无白名单）

      // ✅ danger_delete 被阻止
      final dangerDecision = await manager.checkPermission(dangerTool, {});
      expect(dangerDecision, equals(PermissionDecision.deny));
    });

    test('PermissionConfig.evaluate 使用精确的 permissionType', () {
      final rule = PermissionRule(
        tool: 'mcp_danger_delete',
        mode: PermissionMatchMode.all,
      );

      final config = PermissionConfig(blacklist: [rule]);

      // ✅ 修复后：evaluate 传入的是 tool.permissionType = 'mcp_danger_delete'
      expect(config.matchesBlacklist('mcp_danger_delete', {}), isTrue);
      // ✅ 其他 MCP 工具不受影响
      expect(config.matchesBlacklist('mcp_safe_read', {}), isFalse);
    });
  });

  // ===== 修复验证: 权限请求 UI 信息精确 =====

  group('修复验证: 权限请求 UI 信息精确', () {
    test('不同 MCP 工具的权限请求 permissionType 不同', () async {
      final clientA = _MockMcpClient();
      final clientB = _MockMcpClient();

      final fsTool = McpToolAdapter(
        client: clientA,
        definition: McpToolDefinition(name: 'read', description: '读取文件'),
      );
      final dbTool = McpToolAdapter(
        client: clientB,
        definition: McpToolDefinition(name: 'query', description: '查询数据库'),
      );

      final manager = ToolPermissionManager();
      AgentPermissionRequest? fsRequest;
      AgentPermissionRequest? dbRequest;

      manager.onPermissionRequest = (request) async {
        if (fsRequest == null) {
          fsRequest = request;
        } else {
          dbRequest = request;
        }
        return PermissionDecision.deny;
      };

      await manager.checkPermission(fsTool, {'path': '/data/file.txt'});
      await manager.checkPermission(dbTool, {'sql': 'SELECT * FROM users'});

      // ✅ 修复后：两个请求的 permissionType 不同
      expect(fsRequest!.permissionType, equals('mcp_read'));
      expect(dbRequest!.permissionType, equals('mcp_query'));
      expect(fsRequest!.permissionType == dbRequest!.permissionType, isFalse);
    });

    test('工具名与 permissionType 一致，规则可直接用工具名匹配', () {
      final client = _MockMcpClient();
      final tool = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(name: 'read_file', description: '读取文件'),
      );

      // ✅ 修复后：name == permissionType
      expect(tool.name, equals('mcp_read_file'));
      expect(tool.permissionType, equals('mcp_read_file'));
      expect(tool.name, equals(tool.permissionType));

      // 用户可以用工具名设置规则，且能正确匹配
      final rule = PermissionRule(
        tool: 'mcp_read_file',
        mode: PermissionMatchMode.all,
      );
      final config = PermissionConfig(whitelist: [rule]);

      // ✅ 匹配！因为 evaluate 传入的 toolName='mcp_read_file' == rule.tool
      expect(config.matchesWhitelist('mcp_read_file', {}), isTrue);
      // ✅ 其他工具不匹配
      expect(config.matchesWhitelist('mcp_write_file', {}), isFalse);
    });
  });

  // ===== 修复验证: 综合场景 =====

  group('修复验证: 综合场景', () {
    test('多个 MCP 工具独立控制权限', () async {
      final client = _MockMcpClient();

      final readFile = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(name: 'read_file', description: '读取文件'),
      );
      final writeFile = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(name: 'write_file', description: '写入文件'),
      );
      final deleteFile = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(name: 'delete_file', description: '删除文件'),
      );

      // 配置：允许 read_file，阻止 delete_file，write_file 需确认
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(tool: 'mcp_read_file', mode: PermissionMatchMode.all),
        ],
        blacklist: [
          PermissionRule(
            tool: 'mcp_delete_file',
            mode: PermissionMatchMode.all,
          ),
        ],
      );

      final manager = ToolPermissionManager();
      manager.configure(config);

      // ✅ read_file 被允许
      expect(
        await manager.checkPermission(readFile, {}),
        equals(PermissionDecision.allow),
      );

      // ✅ delete_file 被阻止
      expect(
        await manager.checkPermission(deleteFile, {}),
        equals(PermissionDecision.deny),
      );

      // ✅ write_file 需要用户确认
      PermissionDecision? writeCaptured;
      manager.onPermissionRequest = (request) async {
        writeCaptured = PermissionDecision.allow;
        return PermissionDecision.allow;
      };
      expect(
        await manager.checkPermission(writeFile, {}),
        equals(PermissionDecision.allow),
      );
      expect(writeCaptured, isNotNull);
    });

    test('MCP 权限修复总结', () {
      final client = _MockMcpClient();
      final tool = McpToolAdapter(
        client: client,
        definition: McpToolDefinition(
          name: 'example',
          description: '示例工具',
          inputSchema: {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
          },
        ),
      );

      // ✅ P1 已修复: permissionType 精确到工具名
      expect(tool.permissionType, equals('mcp_example'));

      // ✅ P3: requiresPermission 为 true
      expect(tool.requiresPermission, isTrue);

      // ✅ P4 已修复: name == permissionType
      expect(tool.name, equals(tool.permissionType));

      // 仍存在的问题（需要后续优化）：
      // - P2: permissionArgKey 仍为 null（需从 inputSchema 推导）
      // - P5: 没有携带 MCP 服务器标识
    });
  });

  group('MCP 工具结果截断', () {
    test('超长 MCP 调用结果会在返回给 Agent 前截断', () async {
      final longContent = List.filled(9000, 'a').join();
      final client = _MockMcpClient(content: longContent);
      final tool = McpToolAdapter(
        client: client,
        definition: const McpToolDefinition(
          name: 'long_result',
          description: 'returns long content',
          inputSchema: {'type': 'object'},
        ),
      );

      final result = await tool.execute({});

      expect(result.isError, isFalse);
      expect(result.content.length, lessThan(longContent.length));
      expect(result.content, startsWith(longContent.substring(0, 8192)));
      expect(result.content, contains('MCP结果已截断'));
      expect(result.content, contains('原始9000字符'));
    });
  });
}
