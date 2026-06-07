import 'dart:convert';

import '../../agent/tool/agent_tool.dart';
import '../../utils/logger.dart';
import 'mcp_client.dart';

/// Adapts a discovered MCP tool into an [AgentTool].
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
      _log.warn('MCP tool definition has an empty name, using mcp_unnamed');
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
    if (schema.isEmpty) {
      _log.debug(
        'MCP tool "${definition.name}" has an empty input schema, '
        'using an empty object schema',
      );
      return const {'type': 'object', 'properties': <String, dynamic>{}};
    }
    if (schema['type'] == null) {
      _log.debug(
        'MCP tool "${definition.name}" input schema is missing "type", '
        'defaulting to "object"',
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
      final content = _truncateResultContent(definition.name, result.content);
      return result.isError
          ? ToolResult.error(content)
          : ToolResult.success(content);
    } catch (e) {
      _log.error('MCP tool execution failed', e);
      return ToolResult.error('MCP tool execution failed: $e');
    }
  }

  String _truncateResultContent(String toolName, String content) {
    return truncateMcpResultContent(
      logger: _log,
      toolName: toolName,
      content: content,
      maxLength: _maxResultContentLength,
    );
  }
}

/// Lazy entry point for discovering tools from a single MCP server.
class McpToolListAdapter extends AgentTool {
  final String serverName;
  final Future<List<McpToolDefinition>> Function() listTools;

  McpToolListAdapter({required this.serverName, required this.listTools});

  String get _serverSegment => sanitizeMcpToolSegment(serverName);

  @override
  String get name => 'mcp_${_serverSegment}_list_tools';

  @override
  String get description =>
      'List tools exposed by MCP server "$serverName". '
      'The server is connected lazily on first use.';

  @override
  Map<String, dynamic> get inputJsonSchema => const {
    'type': 'object',
    'properties': <String, dynamic>{},
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    try {
      final tools = await listTools();
      return ToolResult.success(
        jsonEncode({
          'server': serverName,
          'tools': tools
              .map(
                (t) => {
                  'name': t.name,
                  'description': t.description,
                  'inputSchema': t.inputSchema,
                },
              )
              .toList(),
        }),
      );
    } catch (e) {
      return ToolResult.error('MCP tool discovery failed: $e');
    }
  }
}

/// Lazy entry point for invoking a tool on a single MCP server.
class McpToolCallAdapter extends AgentTool {
  static final _log = Logger('McpToolCallAdapter');
  static const int _maxResultContentLength = 8192;

  final String serverName;
  final Future<McpToolCallResult> Function(
    String toolName,
    Map<String, dynamic> arguments,
  )
  callTool;

  McpToolCallAdapter({required this.serverName, required this.callTool});

  String get _serverSegment => sanitizeMcpToolSegment(serverName);

  @override
  String get name => 'mcp_${_serverSegment}_call_tool';

  @override
  String get description =>
      'Call a tool on MCP server "$serverName". '
      'Use mcp_${_serverSegment}_list_tools first to discover available '
      'tool names and schemas, then pass the original MCP tool name.';

  @override
  Map<String, dynamic> get inputJsonSchema => const {
    'type': 'object',
    'properties': {
      'toolName': {
        'type': 'string',
        'description': 'Original MCP tool name from the server.',
      },
      'arguments': {
        'type': 'object',
        'description': 'Arguments for the MCP tool.',
      },
    },
    'required': ['toolName'],
  };

  @override
  bool get requiresPermission => true;

  @override
  String get permissionType => name;

  @override
  String? get permissionArgKey => 'toolName';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final toolName = arguments['toolName'] as String?;
    if (toolName == null || toolName.trim().isEmpty) {
      return ToolResult.error('Missing MCP toolName');
    }

    final rawArgs = arguments['arguments'];
    if (rawArgs != null && rawArgs is! Map) {
      return ToolResult.error('MCP tool arguments must be an object');
    }

    try {
      final result = await callTool(
        toolName,
        rawArgs == null
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(rawArgs),
      );
      final content = truncateMcpResultContent(
        logger: _log,
        toolName: toolName,
        content: result.content,
        maxLength: _maxResultContentLength,
      );
      return result.isError
          ? ToolResult.error(content)
          : ToolResult.success(content);
    } catch (e) {
      _log.error('Lazy MCP tool execution failed', e);
      return ToolResult.error('MCP tool execution failed: $e');
    }
  }
}

String truncateMcpResultContent({
  required Logger logger,
  required String toolName,
  required String content,
  required int maxLength,
}) {
  if (content.length <= maxLength) {
    return content;
  }

  logger.warn(
    'MCP tool "$toolName" result truncated: '
    '${content.length} chars > $maxLength chars',
  );
  return '${content.substring(0, maxLength)}'
      '\n\n[MCP结果已截断: 原始${content.length}字符，仅返回前$maxLength字符]';
}

String sanitizeMcpToolSegment(String value) {
  final sanitized = value
      .trim()
      .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  final fallback = sanitized.isEmpty ? 'server' : sanitized;
  return fallback.length <= 40 ? fallback : fallback.substring(0, 40);
}
