import 'package:test/test.dart';
import 'package:wenzagent/src/persistence/entities/mcp_server_config.dart';
import 'package:wenzagent/src/persistence/entities/skill_entity.dart';
import 'package:wenzagent/src/skill/mcp/mcp_client.dart';
import 'package:wenzagent/src/skill/mcp/mcp_client_provider.dart';
import 'package:wenzagent/src/skill/mcp/mcp_skill.dart';
import 'package:wenzagent/src/skill/skill.dart';

void main() {
  group('McpClientProvider', () {
    test('defines createClient', () {
      final provider = _MockMcpClientProvider();
      final config = McpServerConfig(
        name: 'test',
        transportType: 'stdio',
        command: 'npx',
      );

      final client = provider.createClient(config);
      expect(client, isA<McpClient>());
      expect(client, isA<_MockMcpClient>());
    });

    test('passes config to createClient', () {
      bool callbackCalled = false;
      final provider = _TrackingMcpClientProvider(() {
        callbackCalled = true;
      });

      final config = McpServerConfig(
        name: 'tracked',
        transportType: 'sse',
        url: 'http://localhost:8080/sse',
      );

      provider.createClient(config);
      expect(callbackCalled, isTrue);
    });
  });

  group('McpSkill', () {
    tearDown(() {
      McpSkill.clientFactory = (config) => _MockMcpClient(config);
    });

    test('uses injected McpClientProvider in eager mode', () async {
      final mockProvider = _MockMcpClientProvider();
      final config = McpServerConfig(
        name: 'test',
        transportType: 'stdio',
        command: 'npx',
      );

      final skill = McpSkill(
        id: 'test-mcp',
        name: 'Test MCP',
        description: 'Test',
        serverConfig: config,
        clientProvider: mockProvider,
      );

      expect(skill.type, equals(SkillType.mcp));
      expect(skill.status, equals(SkillStatus.uninitialized));

      await skill.initialize();
      expect(skill.status, equals(SkillStatus.active));
      expect(skill.tools.length, equals(2));
      await skill.dispose();
      expect(skill.status, equals(SkillStatus.disposed));
    });

    test('falls back to static clientFactory in eager mode', () async {
      final config = McpServerConfig(
        name: 'test',
        transportType: 'stdio',
        command: 'npx',
      );

      McpSkill.clientFactory = (cfg) => _MockMcpClient(cfg);

      final skill = McpSkill(
        id: 'test-mcp-static',
        name: 'Test MCP Static',
        description: 'Test',
        serverConfig: config,
      );

      await skill.initialize();
      expect(skill.status, equals(SkillStatus.active));
      expect(skill.tools.length, equals(2));

      await skill.dispose();
    });

    test('instance provider has priority over static factory', () async {
      bool staticFactoryCalled = false;
      bool instanceProviderCalled = false;

      McpSkill.clientFactory = (cfg) {
        staticFactoryCalled = true;
        return _MockMcpClient(cfg);
      };

      final config = McpServerConfig(
        name: 'test',
        transportType: 'stdio',
        command: 'npx',
      );

      final skill = McpSkill(
        id: 'test-priority',
        name: 'Test Priority',
        description: 'Test',
        serverConfig: config,
        clientProvider: _TrackingMcpClientProvider(() {
          instanceProviderCalled = true;
        }),
      );

      await skill.initialize();

      expect(instanceProviderCalled, isTrue);
      expect(staticFactoryCalled, isFalse);

      await skill.dispose();
    });

    test('healthCheck reflects connection state in eager mode', () async {
      final config = McpServerConfig(
        name: 'test',
        transportType: 'stdio',
        command: 'npx',
      );

      final skill = McpSkill(
        id: 'test-health',
        name: 'Test Health',
        description: 'Test',
        serverConfig: config,
        clientProvider: _MockMcpClientProvider(),
      );

      expect(await skill.healthCheck(), isFalse);

      await skill.initialize();
      expect(await skill.healthCheck(), isTrue);

      await skill.dispose();
      expect(await skill.healthCheck(), isFalse);
    });

    test('serverConfig getter returns config', () {
      final config = McpServerConfig(
        name: 'my_server',
        transportType: 'sse',
        url: 'http://localhost:9090/sse',
      );

      final skill = McpSkill(
        id: 'test-config',
        name: 'Test Config',
        description: 'Test',
        serverConfig: config,
      );

      expect(skill.serverConfig.name, equals('my_server'));
      expect(skill.serverConfig.transportType, equals('sse'));
    });

    test('eager tool names come from MCP server', () async {
      final config = McpServerConfig(
        name: 'test',
        transportType: 'stdio',
        command: 'npx',
      );

      final skill = McpSkill(
        id: 'test-tools',
        name: 'Test Tools',
        description: 'Test',
        serverConfig: config,
        clientProvider: _MockMcpClientProvider(),
      );

      await skill.initialize();
      final toolNames = skill.tools.map((t) => t.name).toList();
      expect(toolNames, equals(['mcp_mock_tool_1', 'mcp_mock_tool_2']));

      await skill.dispose();
    });

    test(
      'fromEntity initializes lazily and connects on first MCP use',
      () async {
        var created = 0;
        _MockMcpClient? client;
        McpSkill.clientFactory = (cfg) {
          created++;
          client = _MockMcpClient(cfg);
          return client!;
        };

        final config = McpServerConfig.stdio(
          name: 'lazy_server',
          command: 'npx',
        );
        final entity = AiEmployeeSkillEntity(
          uuid: 'lazy-skill',
          employeeId: 'emp-1',
          name: 'Lazy MCP',
          description: 'Lazy test',
          skillType: 'mcp',
          config: McpServerConfig.toJsonString([config]),
          createTime: DateTime.now(),
          updateTime: DateTime.now(),
        );

        final skill = McpSkill.fromEntity(entity);
        await skill.initialize();

        expect(created, equals(0));
        expect(skill.status, equals(SkillStatus.active));
        expect(
          skill.tools.map((t) => t.name).toList(),
          equals(['mcp_lazy_server_list_tools', 'mcp_lazy_server_call_tool']),
        );
        expect(await skill.healthCheck(), isFalse);

        final listTool = skill.tools.first;
        final listResult = await listTool.execute({});

        expect(listResult.isError, isFalse);
        expect(listResult.content, contains('mock_tool_1'));
        expect(created, equals(1));
        expect(client!.connectCount, equals(1));
        expect(client!.listToolsCount, equals(1));
        expect(await skill.healthCheck(), isTrue);

        await listTool.execute({});
        expect(client!.listToolsCount, equals(1));

        final callTool = skill.tools.last;
        final callResult = await callTool.execute({
          'toolName': 'mock_tool_1',
          'arguments': {'value': 42},
        });

        expect(callResult.isError, isFalse);
        expect(callResult.content, equals('mock result for mock_tool_1'));
        expect(client!.connectCount, equals(1));
        expect(client!.callToolCount, equals(1));

        await skill.dispose();
      },
    );
  });
}

class _MockMcpClientProvider implements McpClientProvider {
  @override
  McpClient createClient(McpServerConfig config) => _MockMcpClient(config);
}

class _TrackingMcpClientProvider implements McpClientProvider {
  final void Function() onCreated;

  _TrackingMcpClientProvider(this.onCreated);

  @override
  McpClient createClient(McpServerConfig config) {
    onCreated();
    return _MockMcpClient(config);
  }
}

class _MockMcpClient implements McpClient {
  final McpServerConfig config;
  bool connected = false;
  int connectCount = 0;
  int listToolsCount = 0;
  int callToolCount = 0;

  _MockMcpClient(this.config);

  @override
  Future<void> connect() async {
    connectCount++;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
  }

  @override
  Future<List<McpToolDefinition>> listTools() async {
    if (!connected) throw StateError('Not connected');
    listToolsCount++;
    return [
      const McpToolDefinition(name: 'mock_tool_1', description: 'Mock tool 1'),
      const McpToolDefinition(name: 'mock_tool_2', description: 'Mock tool 2'),
    ];
  }

  @override
  Future<McpToolCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    if (!connected) throw StateError('Not connected');
    callToolCount++;
    return McpToolCallResult(content: 'mock result for $name');
  }

  @override
  Future<bool> ping() async => connected;

  @override
  bool get isReconnecting => false;

  @override
  Future<void> reconnect() async {
    connected = true;
  }

  @override
  Stream<McpReconnectEvent> get onReconnect => const Stream.empty();
}
