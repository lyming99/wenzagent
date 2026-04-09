import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as mcp_sdk;

import '../../persistence/entities/mcp_server_config.dart';
import 'mcp_client.dart';

/// 基于 mcp_dart SDK 的 MCP 客户端实现
///
/// 支持 3 种传输类型：
/// - **stdio**：通过子进程标准输入输出通信（本地 MCP 服务器）
/// - **sse**：通过 Server-Sent Events 通信（远程 MCP 服务器，旧版协议）
/// - **http**：通过 Streamable HTTP 通信（远程 MCP 服务器，新版协议）
class McpClientImpl implements McpClient {
  final McpServerConfig _config;
  mcp_sdk.McpClient? _client;
  mcp_sdk.Transport? _transport;
  bool _connected = false;

  McpClientImpl(this._config);

  @override
  Future<void> connect() async {
    _transport = _createTransport(_config);

    _client = mcp_sdk.McpClient(
      const mcp_sdk.Implementation(name: 'wenzagent', version: '1.0.0'),
    );

    _transport!.onclose = () {
      _connected = false;
    };
    _transport!.onerror = (error) {
      stderr.writeln('[McpClient] transport error: $error');
    };

    await _client!.connect(_transport!);
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    if (_client != null) {
      await _client!.close();
    }
    _connected = false;
  }

  @override
  Future<List<McpToolDefinition>> listTools() async {
    if (_client == null || !_connected) {
      throw StateError('MCP 客户端未连接');
    }
    final result = await _client!.listTools();
    return result.tools.map((tool) => McpToolDefinition(
      name: tool.name,
      description: tool.description ?? '',
      inputSchema: tool.inputSchema.toJson(),
    )).toList();
  }

  @override
  Future<McpToolCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    if (_client == null || !_connected) {
      throw StateError('MCP 客户端未连接');
    }
    final result = await _client!.callTool(
      mcp_sdk.CallToolRequest(name: name, arguments: arguments),
    );

    final buffer = StringBuffer();
    bool isError = result.isError;
    for (final content in result.content) {
      if (content is mcp_sdk.TextContent) {
        buffer.writeln(content.text);
      } else if (content is mcp_sdk.ImageContent) {
        buffer.writeln('[Image: ${content.mimeType}]');
      } else if (content is mcp_sdk.EmbeddedResource) {
        buffer.writeln('[Resource: ${content.resource.uri}]');
      }
    }
    return McpToolCallResult(
      content: buffer.toString().trimRight(),
      isError: isError,
    );
  }

  @override
  Future<bool> ping() async {
    if (_client == null || !_connected) return false;
    try {
      await _client!.ping();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 根据 [McpServerConfig.transportType] 创建对应的传输层
  ///
  /// 支持三种类型：
  /// - `stdio`：本地子进程通信
  /// - `sse`：Server-Sent Events（旧版远程协议）
  /// - `http`：Streamable HTTP（新版远程协议，支持 SSE 流式响应）
  static mcp_sdk.Transport _createTransport(McpServerConfig config) {
    switch (config.transportType) {
      case 'stdio':
        if (config.command == null || config.command!.isEmpty) {
          throw ArgumentError('stdio 传输类型需要配置 command');
        }
        return mcp_sdk.StdioClientTransport(
          mcp_sdk.StdioServerParameters(
            command: config.command!,
            args: config.args ?? [],
            environment: config.env != null
                ? Map<String, String>.from(config.env!)
                : null,
            stderrMode: ProcessStartMode.normal,
          ),
        );

      case 'sse':
        if (config.url == null || config.url!.isEmpty) {
          throw ArgumentError('SSE 传输类型需要配置 url');
        }
        return mcp_sdk.StreamableHttpClientTransport(
          Uri.parse(config.url!),
          opts: _buildHttpTransportOptions(config),
        );

      case 'http':
        if (config.url == null || config.url!.isEmpty) {
          throw ArgumentError('HTTP 传输类型需要配置 url');
        }
        return mcp_sdk.StreamableHttpClientTransport(
          Uri.parse(config.url!),
          opts: _buildHttpTransportOptions(config),
        );

      default:
        throw ArgumentError('不支持的传输类型: ${config.transportType}，'
            '支持的类型: stdio, sse, http');
    }
  }

  /// 构建 HTTP 传输层选项（headers 等）
  static mcp_sdk.StreamableHttpClientTransportOptions? _buildHttpTransportOptions(
    McpServerConfig config,
  ) {
    if (config.headers == null || config.headers!.isEmpty) return null;
    return mcp_sdk.StreamableHttpClientTransportOptions(
      requestInit: {
        'headers': config.headers!,
      },
    );
  }
}
