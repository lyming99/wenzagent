import '../../agent/tool/agent_tool.dart';
import 'mcp_client.dart';

/// MCP Skill 工具适配器
///
/// 将 Type 1 MCP Skill 的远程工具包装为 [AgentTool]。
/// execute 时通过 MCP 客户端调用远程服务器。
class McpToolAdapter extends AgentTool {
  final McpClient client;
  final McpToolDefinition definition;

  McpToolAdapter({required this.client, required this.definition});

  @override
  String get name => 'mcp_${definition.name}';

  @override
  String get description => definition.description;

  @override
  Map<String, dynamic> get inputJsonSchema => definition.inputSchema;

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
      print(e);
      return ToolResult.error('MCP 工具执行失败: $e');
    }
  }
}
