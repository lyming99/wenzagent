import '../../agent/tool/agent_tool.dart';
import '../../utils/logger.dart';
import 'mcp_client.dart';

/// MCP Skill 工具适配器
///
/// 将 Type 1 MCP Skill 的远程工具包装为 [AgentTool]。
/// execute 时通过 MCP 客户端调用远程服务器。
class McpToolAdapter extends AgentTool {
  static final _log = Logger('McpToolAdapter');
  static const int _maxResultContentLength = 8192;

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
      _log.debug(
        'MCP 工具 "${definition.name}" 的 inputSchema 为空, '
        '使用默认空参数 schema',
      );
      return const {'type': 'object', 'properties': <String, dynamic>{}};
    }
    // 防御性校验：确保 schema 有 type 字段
    if (schema['type'] == null) {
      _log.debug(
        'MCP 工具 "${definition.name}" 的 inputSchema 缺少 "type" 字段, '
        '补充为 "object"',
      );
      return {'type': 'object', ...schema};
    }
    return schema;
  }

  @override
  bool get requiresPermission => true;

  @override
  String get permissionType => name;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    try {
      final result = await client.callTool(definition.name, arguments);
      final content = _truncateResultContent(result.content);
      return result.isError
          ? ToolResult.error(content)
          : ToolResult.success(content);
    } catch (e) {
      _log.error('MCP tool execution failed', e);
      return ToolResult.error('MCP 工具执行失败: $e');
    }
  }

  String _truncateResultContent(String content) {
    if (content.length <= _maxResultContentLength) {
      return content;
    }

    _log.warn(
      'MCP tool "${definition.name}" result truncated: '
      '${content.length} chars > $_maxResultContentLength chars',
    );
    return '${content.substring(0, _maxResultContentLength)}'
        '\n\n[MCP结果已截断: 原始${content.length}字符，仅返回前$_maxResultContentLength字符]';
  }
}
