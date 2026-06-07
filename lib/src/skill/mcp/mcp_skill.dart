import '../../agent/tool/agent_tool.dart';
import '../../persistence/entities/mcp_server_config.dart';
import '../../persistence/entities/skill_entity.dart';
import '../../utils/logger.dart';
import '../skill.dart';
import 'mcp_client.dart';
import 'mcp_client_impl.dart';
import 'mcp_client_provider.dart';
import 'mcp_tool_adapter.dart';

/// Type 1: MCP Skill implementation.
///
/// In eager mode it connects to the MCP server and registers every remote tool
/// during initialization. In lazy mode it only registers lightweight discovery
/// and call entry tools; the actual MCP client is created and connected on the
/// first MCP call.
class McpSkill implements Skill {
  static final _log = Logger('McpSkill');

  final String _id;
  final String _name;
  final String _description;
  final McpServerConfig _serverConfig;
  final bool _lazyLoad;

  /// MCP client provider. The instance provider has priority over the static
  /// [clientFactory] fallback.
  final McpClientProvider? _clientProvider;

  SkillStatus _status = SkillStatus.uninitialized;
  List<AgentTool> _tools = [];
  McpClient? _client;
  bool _connected = false;
  Future<void>? _connectFuture;
  Future<List<McpToolDefinition>>? _toolLoadFuture;
  List<McpToolDefinition>? _mcpToolDefinitions;

  /// MCP client factory, injectable for tests and SDK users.
  static McpClient Function(McpServerConfig)? clientFactory = (config) =>
      McpClientImpl(config);

  McpSkill({
    required String id,
    required String name,
    required String description,
    required McpServerConfig serverConfig,
    McpClientProvider? clientProvider,
    bool lazyLoad = false,
  }) : _id = id,
       _name = name,
       _description = description,
       _serverConfig = serverConfig,
       _lazyLoad = lazyLoad,
       _clientProvider = clientProvider;

  @override
  String get id => _id;

  @override
  String get name => _name;

  @override
  String get description => _description;

  @override
  SkillType get type => SkillType.mcp;

  @override
  SkillStatus get status => _status;

  McpServerConfig get serverConfig => _serverConfig;

  @override
  List<AgentTool> get tools => _tools;

  @override
  Future<void> initialize() async {
    _status = SkillStatus.initializing;
    try {
      if (_lazyLoad) {
        _tools = [
          McpToolListAdapter(
            serverName: _serverConfig.name,
            listTools: _ensureRemoteToolsLoaded,
          ),
          McpToolCallAdapter(
            serverName: _serverConfig.name,
            callTool: _callRemoteTool,
          ),
        ];
        _log.debug(
          'MCP lazy load ready: $_name, registered ${_tools.length} entry tools',
        );
      } else {
        final client = _ensureClient();
        await _ensureConnected();
        final mcpTools = await client.listTools();
        _mcpToolDefinitions = mcpTools;
        _tools = mcpTools
            .map((t) => McpToolAdapter(client: client, definition: t))
            .toList();
        _log.debug('MCP eager load complete: $_name, tools=${_tools.length}');
      }
      _status = SkillStatus.active;
    } catch (e) {
      _status = SkillStatus.error;
      rethrow;
    }
  }

  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {
    await _client?.disconnect();
    _client = null;
    _connected = false;
    _connectFuture = null;
  }

  @override
  Future<void> dispose() async {
    await _client?.disconnect();
    _client = null;
    _connected = false;
    _connectFuture = null;
    _toolLoadFuture = null;
    _mcpToolDefinitions = null;
    _tools.clear();
    _status = SkillStatus.disposed;
  }

  @override
  Future<bool> healthCheck() async {
    if (_client == null || !_connected) return false;
    try {
      return await _client!.ping();
    } catch (e) {
      _log.debug('healthCheck ping failed, using fallback: $e');
      return false;
    }
  }

  McpClient _ensureClient() {
    if (_client != null) return _client!;

    if (_clientProvider != null) {
      _client = _clientProvider.createClient(_serverConfig);
    } else {
      final factory = clientFactory;
      if (factory == null) {
        throw UnsupportedError('McpSkill.clientFactory is not configured');
      }
      _client = factory(_serverConfig);
    }
    return _client!;
  }

  Future<void> _ensureConnected() async {
    if (_connected) return;

    final currentConnect = _connectFuture;
    if (currentConnect != null) {
      await currentConnect;
      return;
    }

    final client = _ensureClient();
    _connectFuture = client
        .connect()
        .then((_) {
          _connected = true;
        })
        .whenComplete(() {
          _connectFuture = null;
        });
    await _connectFuture;
  }

  Future<List<McpToolDefinition>> _ensureRemoteToolsLoaded() async {
    final cached = _mcpToolDefinitions;
    if (cached != null) return cached;

    final currentLoad = _toolLoadFuture;
    if (currentLoad != null) return currentLoad;

    _toolLoadFuture =
        () async {
          await _ensureConnected();
          final tools = await _ensureClient().listTools();
          _mcpToolDefinitions = tools;
          _log.debug(
            'MCP tools discovered lazily: $_name, count=${tools.length}',
          );
          return tools;
        }().whenComplete(() {
          _toolLoadFuture = null;
        });
    return _toolLoadFuture!;
  }

  Future<McpToolCallResult> _callRemoteTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    await _ensureConnected();
    return _ensureClient().callTool(toolName, arguments);
  }

  /// Creates a runtime MCP skill from persisted employee skill data.
  ///
  /// Persisted/config driven MCP skills are lazy by default so changing config
  /// and opening chat sessions never waits for remote MCP startup.
  static McpSkill fromEntity(AiEmployeeSkillEntity entity) {
    final configs = McpServerConfig.parseList(entity.config);
    if (configs.isEmpty) {
      throw ArgumentError('MCP Skill config is empty: ${entity.uuid}');
    }
    return McpSkill(
      id: entity.uuid,
      name: entity.name,
      description: entity.description ?? '',
      serverConfig: configs.first,
      lazyLoad: true,
    );
  }
}
