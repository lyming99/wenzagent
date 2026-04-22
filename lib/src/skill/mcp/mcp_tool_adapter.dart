import '../../agent/tool/agent_tool.dart';
import '../../utils/logger.dart';
import 'mcp_client.dart';

/// MCP Skill 工具适配器
///
/// 将 Type 1 MCP Skill 的远程工具包装为 [AgentTool]。
/// execute 时通过 MCP 客户端调用远程服务器。
class McpToolAdapter extends AgentTool {
  static final _log = Logger('McpToolAdapter');

  final McpClient client;
  final McpToolDefinition definition;

  McpToolAdapter({required this.client, required this.definition});

  @override
  String get name {
    final defName = definition.name;
    if (defName.trim().isEmpty) {
      _log.warn('MCP 工具定义为空名称, 使用 fallback: mcp_unnamed');
      return 'mcp_unnamed';
    }
    return 'mcp_$defName';
  }

  @override
  String get description {
    final desc = definition.description;
    return desc.isEmpty ? 'MCP tool: ${definition.name}' : desc;
  }

  @override
  Map<String, dynamic> get inputJsonSchema {
    final schema = definition.inputSchema;
    // 防御性校验：如果 MCP 服务器返回空 schema，提供默认空参数 schema
    if (schema.isEmpty) {
      _log.debug('MCP 工具 "${definition.name}" 的 inputSchema 为空, '
          '使用默认空参数 schema');
      return const {'type': 'object', 'properties': <String, dynamic>{}};
    }
    // 防御性校验：确保 schema 有 type 字段
    if (schema['type'] == null) {
      _log.debug('MCP 工具 "${definition.name}" 的 inputSchema 缺少 "type" 字段, '
          '补充为 "object"');
      return {'type': 'object', ...schema};
    }
    return schema;
  }

  @override
  bool get requiresPermission => true;

  @override
  String get permissionType => 'mcp';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    try {
      final result = await client.callTool(definition.name, arguments);
      return result.isError
          ? ToolResult.error(result.content)
          : ToolResult.success(result.content);
    } catch (e) {
      _log.error('MCP tool execution failed', e);
      return ToolResult.error('MCP 工具执行失败: $e');
    }
  }
}
