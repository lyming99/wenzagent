import '../../agent/tool/agent_tool.dart';
import '../../persistence/entities/mcp_server_config.dart';
import '../../persistence/entities/skill_entity.dart';
import '../skill.dart';
import 'mcp_client.dart';
import 'mcp_client_impl.dart';
import 'mcp_tool_adapter.dart';

/// Type 1: MCP Skill 实现
///
/// 通过 MCP 协议连接远程服务器，获取工具列表并包装为 AgentTool。
/// 执行时通过 MCP 客户端直接调用远程工具，无 prompt，无需二次 LLM 调用。
class McpSkill implements Skill {
  final String _id;
  final String _name;
  final String _description;
  final McpServerConfig _serverConfig;

  SkillStatus _status = SkillStatus.uninitialized;
  List<AgentTool> _tools = [];
  McpClient? _client;

  /// MCP 客户端工厂（可注入，便于测试和扩展）
  ///
  /// 默认使用 [McpClientImpl]（基于 mcp_dart SDK）。
  /// 测试时可通过 `McpSkill.clientFactory = (config) => MockMcpClient(...)` 注入 Mock。
  static McpClient Function(McpServerConfig)? clientFactory =
      (config) => McpClientImpl(config);

  McpSkill({
    required String id,
    required String name,
    required String description,
    required McpServerConfig serverConfig,
  })  : _id = id,
        _name = name,
        _description = description,
        _serverConfig = serverConfig;

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

  @override
  List<AgentTool> get tools => _tools;

  @override
  Future<void> initialize() async {
    _status = SkillStatus.initializing;
    try {
      _client = clientFactory!(_serverConfig);
      await _client!.connect();
      final mcpTools = await _client!.listTools();
      _tools = mcpTools
          .map((t) => McpToolAdapter(client: _client!, definition: t))
          .toList();
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
  }

  @override
  Future<void> dispose() async {
    await _client?.disconnect();
    _client = null;
    _tools.clear();
    _status = SkillStatus.disposed;
  }

  @override
  Future<bool> healthCheck() async {
    if (_client == null) return false;
    try {
      return await _client!.ping();
    } catch (_) {
      return false;
    }
  }

  /// 从 AiEmployeeSkillEntity 创建
  ///
  /// config 格式为 McpServerConfig 列表的 JSON 字符串：
  /// ```json
  /// [{"name":"fs","transportType":"stdio","command":"npx","args":[...]}]
  /// ```
  static McpSkill fromEntity(AiEmployeeSkillEntity entity) {
    final configs = McpServerConfig.parseList(entity.config);
    if (configs.isEmpty) {
      throw ArgumentError('MCP Skill 配置为空: ${entity.uuid}');
    }
    return McpSkill(
      id: entity.uuid,
      name: entity.name,
      description: entity.description ?? '',
      serverConfig: configs.first,
    );
  }
}
