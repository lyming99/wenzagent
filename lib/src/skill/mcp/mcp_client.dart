/// MCP 工具定义（从服务器获取）
class McpToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const McpToolDefinition({
    required this.name,
    required this.description,
    this.inputSchema = const {},
  });
}

/// MCP 工具调用结果
class McpToolCallResult {
  final String content;
  final bool isError;

  const McpToolCallResult({required this.content, this.isError = false});
}

/// MCP 客户端接口
///
/// 定义与 MCP 服务器交互的标准接口。
/// 具体实现（stdio、SSE、HTTP）通过 McpClientImpl 提供。
abstract class McpClient {
  /// 连接到 MCP 服务器
  Future<void> connect();

  /// 断开连接
  Future<void> disconnect();

  /// 获取服务器提供的工具列表
  Future<List<McpToolDefinition>> listTools();

  /// 调用指定工具
  Future<McpToolCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  );

  /// 健康检查（ping）
  Future<bool> ping();
}
