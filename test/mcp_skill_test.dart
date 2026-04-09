import 'dart:convert';

import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

/// 测试用 Mock MCP 客户端
class MockMcpClient extends McpClient {
  bool connected = false;
  final List<McpToolDefinition> mockTools;
  final Map<String, String> mockResults;
  bool shouldFail = false;

  MockMcpClient({
    this.mockTools = const [],
    this.mockResults = const {},
  });

  @override
  Future<void> connect() async {
    if (shouldFail) throw Exception('连接失败');
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
  }

  @override
  Future<List<McpToolDefinition>> listTools() async {
    if (shouldFail) throw Exception('获取工具列表失败');
    return mockTools;
  }

  @override
  Future<McpToolCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final result = mockResults[name] ?? 'no result for $name';
    return McpToolCallResult(content: result);
  }

  @override
  Future<bool> ping() async => connected;
}

/// 返回 isError 的客户端
class _ErrorMcpClient extends McpClient {
  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<McpToolDefinition>> listTools() async => [];

  @override
  Future<McpToolCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    return McpToolCallResult(content: '远程工具错误', isError: true);
  }

  @override
  Future<bool> ping() async => true;
}

/// 抛异常的客户端
class _ExceptionMcpClient extends McpClient {
  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<McpToolDefinition>> listTools() async => [];

  @override
  Future<McpToolCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    throw Exception('连接断开');
  }

  @override
  Future<bool> ping() async => false;
}

void main() {
  // ============================================================
  // McpToolDefinition / McpToolCallResult 数据类
  // ============================================================
  group('MCP 数据类', () {
    test('McpToolDefinition 创建', () {
      final def = McpToolDefinition(
        name: 'get_weather',
        description: '获取天气信息',
        inputSchema: {
          'type': 'object',
          'properties': {'location': {'type': 'string'}},
          'required': ['location'],
        },
      );
      expect(def.name, 'get_weather');
      expect(def.description, '获取天气信息');
      expect(def.inputSchema['type'], 'object');
    });

    test('McpToolDefinition 默认 inputSchema', () {
      final def = McpToolDefinition(name: 'simple', description: '简单工具');
      expect(def.inputSchema, isEmpty);
    });

    test('McpToolCallResult 成功', () {
      final result = McpToolCallResult(content: '晴 25°C');
      expect(result.content, '晴 25°C');
      expect(result.isError, false);
    });

    test('McpToolCallResult 错误', () {
      final result = McpToolCallResult(content: '城市不存在', isError: true);
      expect(result.content, '城市不存在');
      expect(result.isError, true);
    });
  });

  // ============================================================
  // McpToolAdapter 测试
  // ============================================================
  group('McpToolAdapter', () {
    late MockMcpClient client;
    late McpToolAdapter adapter;

    setUp(() {
      client = MockMcpClient(
        mockResults: {'get_weather': '北京 晴 25°C'},
      );
      adapter = McpToolAdapter(
        client: client,
        definition: const McpToolDefinition(
          name: 'get_weather',
          description: '获取天气',
          inputSchema: {
            'type': 'object',
            'properties': {'location': {'type': 'string'}},
            'required': ['location'],
          },
        ),
      );
    });

    test('基本属性', () {
      expect(adapter.name, 'mcp_get_weather');
      expect(adapter.description, '获取天气');
      expect(adapter.requiresPermission, true);
      expect(adapter.permissionType, 'mcp');
    });

    test('toToolSpec', () {
      final spec = adapter.toToolSpec();
      expect(spec.name, 'mcp_get_weather');
      expect(spec.description, '获取天气');
      expect(spec.inputJsonSchema['type'], 'object');
    });

    test('execute 成功调用', () async {
      final result = await adapter.execute({'location': '北京'});
      expect(result.isError, false);
      expect(result.content, '北京 晴 25°C');
    });

    test('execute MCP 返回错误', () async {
      final errAdapter = McpToolAdapter(
        client: _ErrorMcpClient(),
        definition: const McpToolDefinition(name: 'fail', description: 'fail'),
      );
      final result = await errAdapter.execute({});
      expect(result.isError, true);
      expect(result.content, '远程工具错误');
    });

    test('execute 客户端异常', () async {
      final excAdapter = McpToolAdapter(
        client: _ExceptionMcpClient(),
        definition: const McpToolDefinition(name: 'exc', description: 'exc'),
      );
      final result = await excAdapter.execute({});
      expect(result.isError, true);
      expect(result.content, contains('MCP 工具执行失败'));
    });

    test('多个工具名称隔离', () {
      final a = McpToolAdapter(
        client: client,
        definition: const McpToolDefinition(name: 'tool_a', description: 'A'),
      );
      final b = McpToolAdapter(
        client: client,
        definition: const McpToolDefinition(name: 'tool_b', description: 'B'),
      );
      expect(a.name, 'mcp_tool_a');
      expect(b.name, 'mcp_tool_b');
    });
  });

  // ============================================================
  // McpSkill 生命周期测试
  // ============================================================
  group('McpSkill', () {
    late MockMcpClient mockClient;
    late McpSkill skill;

    setUp(() {
      mockClient = MockMcpClient(
        mockTools: const [
          McpToolDefinition(
            name: 'read_file',
            description: '读取文件',
            inputSchema: {
              'type': 'object',
              'properties': {'path': {'type': 'string'}},
            },
          ),
          McpToolDefinition(name: 'list_dir', description: '列出目录'),
        ],
        mockResults: {
          'read_file': 'file content here',
          'list_dir': 'dir1\ndir2',
        },
      );
      McpSkill.clientFactory = (_) => mockClient;

      skill = McpSkill(
        id: 'mcp-001',
        name: '文件系统',
        description: 'MCP 文件系统工具',
        serverConfig: McpServerConfig.stdio(
          name: 'filesystem',
          command: 'npx',
          args: ['-y', '@modelcontextprotocol/server-filesystem'],
        ),
      );
    });

    tearDown(() {
      McpSkill.clientFactory = null;
    });

    test('初始状态', () {
      expect(skill.status, SkillStatus.uninitialized);
      expect(skill.type, SkillType.mcp);
      expect(skill.tools, isEmpty);
    });

    test('initialize 成功', () async {
      await skill.initialize();
      expect(skill.status, SkillStatus.active);
      expect(skill.tools.length, 2);
      expect(skill.tools[0].name, 'mcp_read_file');
      expect(skill.tools[1].name, 'mcp_list_dir');
    });

    test('initialize 客户端工厂未设置', () async {
      McpSkill.clientFactory = null;
      final bad = McpSkill(
        id: 'bad',
        name: 'bad',
        description: '',
        serverConfig: McpServerConfig.stdio(name: 'bad', command: 'cmd'),
      );
      expect(() => bad.initialize(), throwsA(isA<UnsupportedError>()));
      expect(bad.status, SkillStatus.error);
    });

    test('initialize 连接失败', () async {
      McpSkill.clientFactory = (_) {
        final c = MockMcpClient();
        c.shouldFail = true;
        return c;
      };
      final fail = McpSkill(
        id: 'fail',
        name: 'fail',
        description: '',
        serverConfig: McpServerConfig.stdio(name: 'fail', command: 'cmd'),
      );
      expect(() => fail.initialize(), throwsA(isA<Exception>()));
      await Future.delayed(Duration.zero);
      expect(fail.status, SkillStatus.error);
    });

    test('deactivate → dispose', () async {
      await skill.initialize();
      expect(mockClient.connected, true);

      await skill.deactivate();
      expect(mockClient.connected, false);

      await skill.dispose();
      expect(skill.status, SkillStatus.disposed);
      expect(skill.tools, isEmpty);
    });

    test('healthCheck', () async {
      expect(await skill.healthCheck(), false);
      await skill.initialize();
      expect(await skill.healthCheck(), true);
      await skill.dispose();
      expect(await skill.healthCheck(), false);
    });

    test('通过工具执行远程调用', () async {
      await skill.initialize();
      final result = await skill.tools[0].execute({'path': '/test/file.txt'});
      expect(result.isError, false);
      expect(result.content, 'file content here');
    });
  });

  // ============================================================
  // McpSkill.fromEntity 测试
  // ============================================================
  group('McpSkill.fromEntity', () {
    test('从标准实体创建', () {
      final entity = AiEmployeeSkillEntity(
        uuid: 'mcp-uuid-001',
        employeeId: 'emp-001',
        name: '文件系统',
        description: 'MCP 文件系统',
        skillType: 'mcp',
        config: jsonEncode([
          {
            'name': 'filesystem',
            'transportType': 'stdio',
            'command': 'npx',
            'args': ['-y', '@modelcontextprotocol/server-filesystem', '/tmp'],
            'env': {},
          },
        ]),
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );
      final skill = McpSkill.fromEntity(entity);
      expect(skill.id, 'mcp-uuid-001');
      expect(skill.name, '文件系统');
      expect(skill.type, SkillType.mcp);
    });

    test('config 为空时抛异常', () {
      final entity = AiEmployeeSkillEntity(
        uuid: 'mcp-uuid-002',
        employeeId: 'emp-001',
        name: '空配置',
        skillType: 'mcp',
        config: '',
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );
      expect(() => McpSkill.fromEntity(entity), throwsA(isA<ArgumentError>()));
    });

    test('config 无效 JSON 时抛异常', () {
      final entity = AiEmployeeSkillEntity(
        uuid: 'mcp-uuid-003',
        employeeId: 'emp-001',
        name: '无效JSON',
        skillType: 'mcp',
        config: 'not json',
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );
      expect(() => McpSkill.fromEntity(entity), throwsA(isA<ArgumentError>()));
    });
  });

  // ============================================================
  // McpSkill + SkillLifecycleManager 集成测试
  // ============================================================
  group('McpSkill 集成 SkillLifecycleManager', () {
    late ToolRegistry registry;
    late SkillLifecycleManager manager;
    final events = <SkillEvent>[];

    setUp(() {
      registry = ToolRegistry();
      manager = SkillLifecycleManager(SkillContext(
        toolRegistry: registry,
        employeeId: 'test-emp',
        invokeLlm: (_) async => 'result',
        logger: (_, __) {},
      ));
      events.clear();
      manager.onEvent.listen(events.add);

      McpSkill.clientFactory = (_) => MockMcpClient(
        mockTools: const [
          McpToolDefinition(name: 'tool_x', description: '工具X'),
        ],
        mockResults: {'tool_x': 'X result'},
      );
    });

    tearDown(() async {
      McpSkill.clientFactory = null;
      await manager.dispose();
    });

    test('loadSkill 注册 MCP 工具', () async {
      final skill = McpSkill(
        id: 'mcp-int-001',
        name: '测试MCP',
        description: '测试',
        serverConfig: McpServerConfig.stdio(name: 'test', command: 'echo'),
      );
      await manager.loadSkill(skill);

      expect(registry.length, 1);
      expect(registry.contains('mcp_tool_x'), true);
      expect(manager.skills.length, 1);
      expect(events.any((e) => e.type == 'added'), true);
    });

    test('unloadSkill 注销工具并断开连接', () async {
      final skill = McpSkill(
        id: 'mcp-int-002',
        name: '测试MCP',
        description: '测试',
        serverConfig: McpServerConfig.stdio(name: 'test', command: 'echo'),
      );
      await manager.loadSkill(skill);
      expect(registry.length, 1);

      await manager.unloadSkill('mcp-int-002');
      expect(registry.length, 0);
      expect(manager.skills.length, 0);
      expect(events.any((e) => e.type == 'removed'), true);
    });

    test('loadSkill 失败广播 error 事件', () async {
      McpSkill.clientFactory = (_) {
        final c = MockMcpClient();
        c.shouldFail = true;
        return c;
      };

      final failSkill = McpSkill(
        id: 'mcp-int-fail',
        name: '失败MCP',
        description: '测试',
        serverConfig: McpServerConfig.stdio(name: 'fail', command: 'cmd'),
      );

      await expectLater(manager.loadSkill(failSkill), throwsA(isA<Exception>()));
      expect(events.any((e) => e.type == 'error'), true);
    });

    test('通过 ToolRegistry 执行已注册的 MCP 工具', () async {
      final skill = McpSkill(
        id: 'mcp-int-003',
        name: '测试MCP',
        description: '测试',
        serverConfig: McpServerConfig.stdio(name: 'test', command: 'echo'),
      );
      await manager.loadSkill(skill);

      final tool = registry.getTool('mcp_tool_x');
      expect(tool, isNotNull);

      final result = await tool!.execute({});
      expect(result.isError, false);
      expect(result.content, 'X result');
    });
  });
}
