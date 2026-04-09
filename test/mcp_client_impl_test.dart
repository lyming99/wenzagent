import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:wenzagent/wenzagent.dart';

void main() {
  // ============================================================
  // McpServerConfig 工厂方法
  // ============================================================
  group('McpServerConfig 工厂方法', () {
    test('stdio 配置', () {
      final config = McpServerConfig.stdio(
        name: 'filesystem',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-filesystem'],
        env: {'NODE_ENV': 'test'},
      );
      expect(config.name, 'filesystem');
      expect(config.transportType, 'stdio');
      expect(config.command, 'npx');
      expect(config.args, ['-y', '@modelcontextprotocol/server-filesystem']);
      expect(config.env!['NODE_ENV'], 'test');
      expect(config.url, isNull);
    });

    test('sse 配置', () {
      final config = McpServerConfig.sse(
        name: 'remote-sse',
        url: 'http://localhost:8080/sse',
        headers: {'Authorization': 'Bearer token123'},
      );
      expect(config.name, 'remote-sse');
      expect(config.transportType, 'sse');
      expect(config.url, 'http://localhost:8080/sse');
      expect(config.headers!['Authorization'], 'Bearer token123');
      expect(config.command, isNull);
    });

    test('http 配置', () {
      final config = McpServerConfig.http(
        name: 'remote-http',
        url: 'http://localhost:9090/mcp',
        headers: {'X-Api-Key': 'key-abc'},
        timeout: 30000,
      );
      expect(config.name, 'remote-http');
      expect(config.transportType, 'http');
      expect(config.url, 'http://localhost:9090/mcp');
      expect(config.headers!['X-Api-Key'], 'key-abc');
      expect(config.timeout, 30000);
    });
  });

  // ============================================================
  // McpClientImpl — 未连接时的错误处理
  // ============================================================
  group('McpClientImpl 未连接状态', () {
    final stdioConfig = McpServerConfig.stdio(
      name: 'test',
      command: 'echo',
    );
    late McpClientImpl client;

    setUp(() {
      client = McpClientImpl(stdioConfig);
    });

    test('listTools 未连接时抛 StateError', () async {
      expect(
        () => client.listTools(),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('未连接'),
        )),
      );
    });

    test('callTool 未连接时抛 StateError', () async {
      expect(
        () => client.callTool('tool', {}),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('未连接'),
        )),
      );
    });

    test('ping 未连接时返回 false', () async {
      expect(await client.ping(), false);
    });

    test('disconnect 未初始化时不会崩溃', () async {
      await client.disconnect(); // 不应抛异常
    });
  });

  // ============================================================
  // McpClientImpl — 传输层创建参数校验
  // ============================================================
  group('McpClientImpl 传输层参数校验', () {
    test('stdio 缺少 command 抛 ArgumentError', () async {
      final config = McpServerConfig(
        name: 'bad-stdio',
        transportType: 'stdio',
      );
      final client = McpClientImpl(config);
      expect(
        () => client.connect(),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('command'),
        )),
      );
    });

    test('sse 缺少 url 抛 ArgumentError', () async {
      final config = McpServerConfig(
        name: 'bad-sse',
        transportType: 'sse',
      );
      final client = McpClientImpl(config);
      expect(
        () => client.connect(),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('url'),
        )),
      );
    });

    test('http 缺少 url 抛 ArgumentError', () async {
      final config = McpServerConfig(
        name: 'bad-http',
        transportType: 'http',
      );
      final client = McpClientImpl(config);
      expect(
        () => client.connect(),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('url'),
        )),
      );
    });

    test('未知传输类型抛 ArgumentError', () async {
      final config = McpServerConfig(
        name: 'bad-type',
        transportType: 'grpc',
      );
      final client = McpClientImpl(config);
      expect(
        () => client.connect(),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('不支持的传输类型'),
        )),
      );
    });
  });

  // ============================================================
  // McpClientImpl — stdio 集成测试 (需要真实 MCP 服务器)
  // ============================================================
  group('McpClientImpl stdio 集成', () {
    late McpClientImpl client;

    tearDown(() async {
      await client.disconnect();
    });

    test('连接真实 MCP 服务器并获取工具列表', () async {
      // stdio 集成测试需要本地 Node.js / npx 环境
      // 环境不具备时自动跳过
      final config = McpServerConfig.stdio(
        name: 'filesystem',
        command: 'npx',
        args: ['-y', '@anthropic/mcp-filesystem-server', Directory.systemTemp.path],
      );
      client = McpClientImpl(config);

      try {
        await client.connect().timeout(Duration(seconds: 15));
      } catch (_) {
        markTestSkipped('需要 Node.js / npx 环境');
        return;
      }

      final tools = await client.listTools();
      expect(tools, isNotEmpty);

      // filesystem 服务器通常提供 read_file, write_file 等工具
      final toolNames = tools.map((t) => t.name).toList();
      print('[stdio] 可用工具: $toolNames');

      // ping 测试
      expect(await client.ping(), true);
    }, timeout: Timeout(Duration(seconds: 60)));
  });

  // ============================================================
  // McpClientImpl — SSE/HTTP 集成测试 (使用本地 mock 服务器)
  // ============================================================
  group('McpClientImpl HTTP/SSE 集成', () {
    late HttpServer mockServer;
    late String baseUrl;
    late StreamController<String>? sseController;

    /// 启动一个 mock MCP Streamable HTTP 服务器
    Future<void> startMockServer() async {
      sseController = StreamController<String>.broadcast();

      var handler = const shelf.Pipeline()
          .addHandler((shelf.Request request) async {
        if (request.method == 'POST') {
          // 处理 JSON-RPC 请求
          final body = await request.readAsString();
          final rpc = jsonDecode(body) as Map<String, dynamic>;
          final method = rpc['method'] as String?;

          switch (method) {
            case 'initialize':
              return shelf.Response(200,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'jsonrpc': '2.0',
                    'id': rpc['id'],
                    'result': {
                      'protocolVersion': '2025-03-26',
                      'capabilities': {'tools': {'listChanged': false}},
                      'serverInfo': {'name': 'mock-mcp', 'version': '1.0.0'},
                    },
                  }));

            case 'notifications/initialized':
              return shelf.Response(200, body: '');

            case 'tools/list':
              return shelf.Response(200,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'jsonrpc': '2.0',
                    'id': rpc['id'],
                    'result': {
                      'tools': [
                        {
                          'name': 'hello',
                          'description': 'Say hello',
                          'inputSchema': {
                            'type': 'object',
                            'properties': {
                              'name': {'type': 'string'}
                            },
                            'required': ['name'],
                          },
                        },
                        {
                          'name': 'add',
                          'description': 'Add two numbers',
                          'inputSchema': {
                            'type': 'object',
                            'properties': {
                              'a': {'type': 'number'},
                              'b': {'type': 'number'},
                            },
                            'required': ['a', 'b'],
                          },
                        },
                      ],
                    },
                  }));

            case 'tools/call':
              final params =
                  rpc['params'] as Map<String, dynamic>?;
              final toolName = params?['name'] as String?;
              var content = 'unknown tool';
              var isError = false;

              if (toolName == 'hello') {
                final argName = params?['arguments']?['name'] ?? 'World';
                content = 'Hello, $argName!';
              } else if (toolName == 'add') {
                final a = params?['arguments']?['a'] ?? 0;
                final b = params?['arguments']?['b'] ?? 0;
                content = 'Result: ${a + b}';
              } else {
                isError = true;
                content = 'Tool not found: $toolName';
              }

              return shelf.Response(200,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'jsonrpc': '2.0',
                    'id': rpc['id'],
                    'result': {
                      'content': [
                        {'type': 'text', 'text': content}
                      ],
                      'isError': isError,
                    },
                  }));

            case 'ping':
              return shelf.Response(200,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'jsonrpc': '2.0',
                    'id': rpc['id'],
                    'result': {},
                  }));

            default:
              return shelf.Response(400, body: 'Unknown method: $method');
          }
        }

        return shelf.Response(405, body: 'Method not allowed');
      });

      mockServer = await shelf_io.serve(handler, '127.0.0.1', 0);
      baseUrl = 'http://127.0.0.1:${mockServer.port}/mcp';
    }

    setUp(() async {
      await startMockServer();
    });

    tearDown(() async {
      await sseController?.close();
      await mockServer.close(force: true);
    });

    test('HTTP 传输: connect → listTools → callTool → ping → disconnect',
        () async {
      final config = McpServerConfig.http(
        name: 'mock-http',
        url: baseUrl,
      );
      final client = McpClientImpl(config);

      // connect
      await client.connect();

      // listTools
      final tools = await client.listTools();
      expect(tools.length, 2);
      expect(tools[0].name, 'hello');
      expect(tools[1].name, 'add');
      expect(tools[0].inputSchema['type'], 'object');

      // callTool — hello
      final helloResult = await client.callTool('hello', {'name': 'MCP'});
      expect(helloResult.isError, false);
      expect(helloResult.content, 'Hello, MCP!');

      // callTool — add
      final addResult = await client.callTool('add', {'a': 3, 'b': 7});
      expect(addResult.isError, false);
      expect(addResult.content, 'Result: 10');

      // callTool — 不存在的工具
      final errResult = await client.callTool('nonexistent', {});
      expect(errResult.isError, true);
      expect(errResult.content, contains('Tool not found'));

      // ping
      expect(await client.ping(), true);

      // disconnect
      await client.disconnect();
    }, timeout: Timeout(Duration(seconds: 15)));

    test('SSE 传输: connect → listTools → callTool', () async {
      final config = McpServerConfig.sse(
        name: 'mock-sse',
        url: baseUrl,
      );
      final client = McpClientImpl(config);

      await client.connect();

      final tools = await client.listTools();
      expect(tools.length, 2);

      final result = await client.callTool('hello', {'name': 'SSE'});
      expect(result.isError, false);
      expect(result.content, 'Hello, SSE!');

      await client.disconnect();
    }, timeout: Timeout(Duration(seconds: 15)));

    test('HTTP 带 headers 传输', () async {
      // 收集所有请求的 headers
      final capturedHeaders = <Map<String, String>>[];

      // 需要重启服务器以捕获 headers
      await mockServer.close(force: true);

      var handler = const shelf.Pipeline().addHandler(
        (shelf.Request request) async {
          // 捕获所有请求的 headers
          capturedHeaders.add(Map<String, String>.from(request.headers));

          if (request.method == 'GET') {
            // SSE 连接 — 返回 200 但无内容（简化处理）
            return shelf.Response(200,
                headers: {'Content-Type': 'text/event-stream'}, body: '');
          }

          if (request.method == 'POST') {
            final body = await request.readAsString();
            final rpc = jsonDecode(body) as Map<String, dynamic>;
            final method = rpc['method'] as String?;

            if (method == 'initialize') {
              return shelf.Response(200,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'jsonrpc': '2.0',
                    'id': rpc['id'],
                    'result': {
                      'protocolVersion': '2025-03-26',
                      'capabilities': {},
                      'serverInfo': {
                        'name': 'headers-test',
                        'version': '1.0.0'
                      },
                    },
                  }));
            } else if (method == 'notifications/initialized') {
              return shelf.Response(200, body: '');
            } else if (method == 'ping') {
              return shelf.Response(200,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'jsonrpc': '2.0',
                    'id': rpc['id'],
                    'result': {},
                  }));
            }
          }
          return shelf.Response(405, body: 'Method not allowed');
        },
      );

      mockServer = await shelf_io.serve(handler, '127.0.0.1', 0);
      final headerUrl = 'http://127.0.0.1:${mockServer.port}/mcp';

      final config = McpServerConfig.http(
        name: 'headers-test',
        url: headerUrl,
        headers: {
          'X-Custom-Auth': 'test-token-123',
          'X-Request-Id': 'req-001',
        },
      );

      final client = McpClientImpl(config);
      await client.connect();
      await client.disconnect();

      // 验证自定义 headers 被传递到至少一个请求中
      expect(
        capturedHeaders.any(
          (h) => h['x-custom-auth'] == 'test-token-123',
        ),
        true,
        reason: 'POST 请求应包含 X-Custom-Auth header',
      );
      expect(
        capturedHeaders.any(
          (h) => h['x-request-id'] == 'req-001',
        ),
        true,
        reason: 'POST 请求应包含 X-Request-Id header',
      );
    }, timeout: Timeout(Duration(seconds: 15)));
  });
}
