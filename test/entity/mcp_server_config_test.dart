import 'dart:convert';

import 'package:test/test.dart';
import 'package:wenzagent/src/persistence/entities/mcp_server_config.dart';

void main() {
  group('McpRetryConfig', () {
    test('default values', () {
      const config = McpRetryConfig();
      expect(config.maxRetries, 3);
      expect(config.retryDelay, 1000);
      expect(config.exponentialBackoff, true);
    });

    test('fromMap/toMap round trip', () {
      const original = McpRetryConfig(
        maxRetries: 5,
        retryDelay: 2000,
        exponentialBackoff: false,
      );

      final map = original.toMap();
      final restored = McpRetryConfig.fromMap(map);

      expect(restored, original);
      expect(map, {
        'maxRetries': 5,
        'retryDelay': 2000,
        'exponentialBackoff': false,
      });
    });

    test('fromMap missing fields use defaults', () {
      final config = McpRetryConfig.fromMap({});
      expect(config.maxRetries, 3);
      expect(config.retryDelay, 1000);
      expect(config.exponentialBackoff, true);
    });

    test('copyWith modifies field correctly', () {
      const original = McpRetryConfig();
      final modified = original.copyWith(maxRetries: 10);
      expect(modified.maxRetries, 10);
      expect(modified.retryDelay, 1000);
      expect(modified.exponentialBackoff, true);
      expect(original.maxRetries, 3);
    });

    test('copyWith modifies all fields', () {
      const original = McpRetryConfig();
      final modified = original.copyWith(
        maxRetries: 1,
        retryDelay: 500,
        exponentialBackoff: false,
      );
      expect(modified.maxRetries, 1);
      expect(modified.retryDelay, 500);
      expect(modified.exponentialBackoff, false);
    });

    test('copyWith no params preserves original', () {
      const original = McpRetryConfig(
        maxRetries: 7,
        retryDelay: 3000,
        exponentialBackoff: false,
      );
      final copy = original.copyWith();
      expect(copy, original);
    });

    test('equality - equal', () {
      const a = McpRetryConfig(maxRetries: 3, retryDelay: 1000, exponentialBackoff: true);
      const b = McpRetryConfig(maxRetries: 3, retryDelay: 1000, exponentialBackoff: true);
      expect(a, b);
    });

    test('equality - not equal', () {
      const a = McpRetryConfig(maxRetries: 3);
      const b = McpRetryConfig(maxRetries: 5);
      expect(a, isNot(b));
    });

    test('equality - each field differs individually', () {
      const base = McpRetryConfig(maxRetries: 3, retryDelay: 1000, exponentialBackoff: true);
      expect(base, isNot(const McpRetryConfig(maxRetries: 0)));
      expect(base, isNot(const McpRetryConfig(retryDelay: 0)));
      expect(base, isNot(const McpRetryConfig(exponentialBackoff: false)));
    });

    test('hashCode consistency', () {
      const a = McpRetryConfig(maxRetries: 3, retryDelay: 1000, exponentialBackoff: true);
      const b = McpRetryConfig(maxRetries: 3, retryDelay: 1000, exponentialBackoff: true);
      expect(a.hashCode, b.hashCode);
    });

    test('toString format', () {
      const config = McpRetryConfig(maxRetries: 5, retryDelay: 2000, exponentialBackoff: false);
      expect(
        config.toString(),
        'McpRetryConfig(maxRetries: 5, retryDelay: 2000, exponentialBackoff: false)',
      );
    });
  });

  group('McpServerConfig fromMap/toMap', () {
    test('full fields round trip', () {
      const retry = McpRetryConfig(maxRetries: 5, retryDelay: 2000, exponentialBackoff: false);
      final original = McpServerConfig(
        name: 'test-server',
        displayName: 'Test Server',
        description: 'A test server',
        transportType: 'stdio',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-filesystem'],
        env: {'NODE_ENV': 'production'},
        url: 'http://localhost:8080',
        headers: {'Authorization': 'Bearer token'},
        enabled: false,
        autoStart: false,
        timeout: 30000,
        retryConfig: retry,
      );

      final map = original.toMap();
      final restored = McpServerConfig.fromMap(map);

      expect(restored.name, original.name);
      expect(restored.displayName, original.displayName);
      expect(restored.description, original.description);
      expect(restored.transportType, original.transportType);
      expect(restored.command, original.command);
      expect(restored.args, original.args);
      expect(restored.env, original.env);
      expect(restored.url, original.url);
      expect(restored.headers, original.headers);
      expect(restored.enabled, original.enabled);
      expect(restored.autoStart, original.autoStart);
      expect(restored.timeout, original.timeout);
      expect(restored.retryConfig, original.retryConfig);
    });

    test('null optional fields handled correctly', () {
      final original = McpServerConfig(name: 'minimal', transportType: 'stdio');

      final map = original.toMap();
      final restored = McpServerConfig.fromMap(map);

      expect(restored.name, 'minimal');
      expect(restored.displayName, isNull);
      expect(restored.description, isNull);
      expect(restored.transportType, 'stdio');
      expect(restored.command, isNull);
      expect(restored.args, isNull);
      expect(restored.env, isNull);
      expect(restored.url, isNull);
      expect(restored.headers, isNull);
      expect(restored.enabled, true);
      expect(restored.autoStart, true);
      expect(restored.timeout, isNull);
      expect(restored.retryConfig, isNull);
    });

    test('args deserialization', () {
      final config = McpServerConfig.fromMap({
        'name': 's',
        'transportType': 'stdio',
        'args': ['--flag', 'value'],
      });
      expect(config.args, ['--flag', 'value']);
    });

    test('env deserialization', () {
      final config = McpServerConfig.fromMap({
        'name': 's',
        'transportType': 'stdio',
        'env': {'KEY': 'value'},
      });
      expect(config.env, {'KEY': 'value'});
    });

    test('retryConfig nested deserialization', () {
      final config = McpServerConfig.fromMap({
        'name': 's',
        'transportType': 'stdio',
        'retryConfig': {
          'maxRetries': 10,
          'retryDelay': 500,
          'exponentialBackoff': false,
        },
      });
      expect(config.retryConfig, isNotNull);
      expect(config.retryConfig!.maxRetries, 10);
      expect(config.retryConfig!.retryDelay, 500);
      expect(config.retryConfig!.exponentialBackoff, false);
    });

    test('toMap excludes null optional fields', () {
      final config = McpServerConfig(name: 'minimal', transportType: 'stdio');
      final map = config.toMap();
      expect(map.containsKey('displayName'), false);
      expect(map.containsKey('description'), false);
      expect(map.containsKey('command'), false);
      expect(map.containsKey('args'), false);
      expect(map.containsKey('env'), false);
      expect(map.containsKey('url'), false);
      expect(map.containsKey('headers'), false);
      expect(map.containsKey('timeout'), false);
      expect(map.containsKey('retryConfig'), false);
      expect(map.containsKey('name'), true);
      expect(map.containsKey('transportType'), true);
      expect(map.containsKey('enabled'), true);
      expect(map.containsKey('autoStart'), true);
    });

    test('fromMap missing name and transportType uses defaults', () {
      final config = McpServerConfig.fromMap({});
      expect(config.name, '');
      expect(config.transportType, 'stdio');
    });
  });

  group('McpServerConfig factory methods', () {
    test('stdio factory', () {
      final config = McpServerConfig.stdio(
        name: 'fs',
        displayName: 'Filesystem',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-filesystem'],
        env: {'HOME': '/tmp'},
      );

      expect(config.name, 'fs');
      expect(config.displayName, 'Filesystem');
      expect(config.transportType, 'stdio');
      expect(config.command, 'npx');
      expect(config.args, ['-y', '@modelcontextprotocol/server-filesystem']);
      expect(config.env, {'HOME': '/tmp'});
      expect(config.enabled, true);
      expect(config.autoStart, true);
      expect(config.url, isNull);
      expect(config.headers, isNull);
    });

    test('sse factory', () {
      final config = McpServerConfig.sse(
        name: 'remote',
        displayName: 'Remote Server',
        url: 'http://localhost:8080/sse',
        headers: {'Authorization': 'Bearer token123'},
        enabled: false,
        timeout: 15000,
      );

      expect(config.name, 'remote');
      expect(config.displayName, 'Remote Server');
      expect(config.transportType, 'sse');
      expect(config.url, 'http://localhost:8080/sse');
      expect(config.headers, {'Authorization': 'Bearer token123'});
      expect(config.enabled, false);
      expect(config.timeout, 15000);
      expect(config.command, isNull);
      expect(config.args, isNull);
      expect(config.env, isNull);
    });

    test('http factory', () {
      final config = McpServerConfig.http(
        name: 'api',
        url: 'http://localhost:3000/mcp',
        headers: {'X-API-Key': 'secret'},
        autoStart: false,
      );

      expect(config.name, 'api');
      expect(config.transportType, 'http');
      expect(config.url, 'http://localhost:3000/mcp');
      expect(config.headers, {'X-API-Key': 'secret'});
      expect(config.autoStart, false);
      expect(config.enabled, true);
      expect(config.command, isNull);
      expect(config.args, isNull);
      expect(config.env, isNull);
    });

    test('factory methods support retryConfig', () {
      const retry = McpRetryConfig(maxRetries: 5);
      final config = McpServerConfig.stdio(
        name: 's',
        command: 'cmd',
        retryConfig: retry,
      );
      expect(config.retryConfig, retry);
    });
  });

  group('McpServerConfig copyWith', () {
    late McpServerConfig original;

    setUp(() {
      original = McpServerConfig(
        name: 'server1',
        displayName: 'Server One',
        description: 'Desc',
        transportType: 'stdio',
        command: 'npx',
        args: ['-y'],
        env: {'K': 'V'},
        url: 'http://url',
        headers: {'H': 'V'},
        enabled: true,
        autoStart: true,
        timeout: 5000,
        retryConfig: const McpRetryConfig(),
      );
    });

    test('modify single field', () {
      final modified = original.copyWith(name: 'new-name');
      expect(modified.name, 'new-name');
      expect(modified.displayName, 'Server One');
      expect(modified.transportType, 'stdio');
      expect(modified.command, 'npx');
    });

    test('modify multiple fields', () {
      final modified = original.copyWith(
        name: 'renamed',
        enabled: false,
        timeout: 10000,
      );
      expect(modified.name, 'renamed');
      expect(modified.enabled, false);
      expect(modified.timeout, 10000);
      expect(modified.displayName, 'Server One');
      expect(modified.transportType, 'stdio');
    });

    test('no params preserves original', () {
      final copy = original.copyWith();
      expect(copy, original);
      expect(copy.displayName, original.displayName);
      expect(copy.description, original.description);
      expect(copy.args, original.args);
      expect(copy.env, original.env);
      expect(copy.url, original.url);
      expect(copy.headers, original.headers);
      expect(copy.autoStart, original.autoStart);
      expect(copy.timeout, original.timeout);
      expect(copy.retryConfig, original.retryConfig);
    });

    test('modify transportType', () {
      final modified = original.copyWith(transportType: 'sse');
      expect(modified.transportType, 'sse');
      expect(modified.name, original.name);
    });
  });

  group('McpServerConfig parseList', () {
    test('new format List parsing', () {
      final json = jsonEncode([
        {
          'name': 'fs',
          'transportType': 'stdio',
          'command': 'npx',
          'args': ['-y', 'pkg'],
        },
        {
          'name': 'remote',
          'transportType': 'sse',
          'url': 'http://localhost:8080',
        },
      ]);

      final list = McpServerConfig.parseList(json);
      expect(list.length, 2);
      expect(list[0].name, 'fs');
      expect(list[0].transportType, 'stdio');
      expect(list[0].command, 'npx');
      expect(list[0].args, ['-y', 'pkg']);
      expect(list[1].name, 'remote');
      expect(list[1].transportType, 'sse');
      expect(list[1].url, 'http://localhost:8080');
    });

    test('legacy format Map parsing', () {
      final json = jsonEncode({
        'filesystem': {
          'command': 'npx',
          'args': ['-y', '@modelcontextprotocol/server-filesystem'],
          'env': {'HOME': '/tmp'},
        },
        'remote': {
          'command': 'node',
          'args': ['server.js'],
        },
      });

      final list = McpServerConfig.parseList(json);
      expect(list.length, 2);
      expect(list[0].name, 'filesystem');
      expect(list[0].transportType, 'stdio');
      expect(list[0].command, 'npx');
      expect(list[0].args, ['-y', '@modelcontextprotocol/server-filesystem']);
      expect(list[0].env, {'HOME': '/tmp'});
      expect(list[1].name, 'remote');
      expect(list[1].command, 'node');
      expect(list[1].args, ['server.js']);
    });

    test('null returns empty list', () {
      expect(McpServerConfig.parseList(null), isEmpty);
    });

    test('empty string returns empty list', () {
      expect(McpServerConfig.parseList(''), isEmpty);
    });

    test('invalid JSON returns empty list without throwing', () {
      expect(McpServerConfig.parseList('not json at all'), isEmpty);
      expect(McpServerConfig.parseList('{broken json'), isEmpty);
      expect(McpServerConfig.parseList('123'), isEmpty);
      expect(McpServerConfig.parseList('"just a string"'), isEmpty);
    });

    test('empty List returns empty list', () {
      expect(McpServerConfig.parseList('[]'), isEmpty);
    });

    test('empty Map returns empty list', () {
      expect(McpServerConfig.parseList('{}'), isEmpty);
    });
  });

  group('McpServerConfig toJsonString', () {
    test('list to JSON string', () {
      final configs = [
        McpServerConfig.stdio(name: 'fs', command: 'npx'),
        McpServerConfig.sse(name: 'remote', url: 'http://localhost:8080'),
      ];

      final jsonStr = McpServerConfig.toJsonString(configs);
      final decoded = jsonDecode(jsonStr) as List;

      expect(decoded.length, 2);
      expect((decoded[0] as Map)['name'], 'fs');
      expect((decoded[0] as Map)['transportType'], 'stdio');
      expect((decoded[1] as Map)['name'], 'remote');
      expect((decoded[1] as Map)['transportType'], 'sse');
    });

    test('empty list to JSON string', () {
      final jsonStr = McpServerConfig.toJsonString([]);
      expect(jsonStr, '[]');
    });

    test('parseList + toJsonString round trip', () {
      final original = [
        McpServerConfig.stdio(
          name: 'fs',
          displayName: 'Filesystem',
          command: 'npx',
          args: ['-y', 'pkg'],
          env: {'KEY': 'value'},
          enabled: false,
          timeout: 10000,
          retryConfig: const McpRetryConfig(maxRetries: 5),
        ),
        McpServerConfig.sse(
          name: 'remote',
          url: 'http://localhost:8080/sse',
          headers: {'Auth': 'token'},
        ),
      ];

      final jsonStr = McpServerConfig.toJsonString(original);
      final restored = McpServerConfig.parseList(jsonStr);

      expect(restored.length, original.length);
      expect(restored[0].name, original[0].name);
      expect(restored[0].displayName, original[0].displayName);
      expect(restored[0].transportType, original[0].transportType);
      expect(restored[0].command, original[0].command);
      expect(restored[0].args, original[0].args);
      expect(restored[0].env, original[0].env);
      expect(restored[0].enabled, original[0].enabled);
      expect(restored[0].timeout, original[0].timeout);
      expect(restored[0].retryConfig, original[0].retryConfig);
      expect(restored[1].name, original[1].name);
      expect(restored[1].transportType, original[1].transportType);
      expect(restored[1].url, original[1].url);
      expect(restored[1].headers, original[1].headers);
    });
  });

  group('McpServerConfig equality', () {
    test('equal configs', () {
      final a = McpServerConfig.stdio(name: 's', command: 'npx');
      final b = McpServerConfig.stdio(name: 's', command: 'npx');
      expect(a, b);
    });

    test('different name', () {
      final a = McpServerConfig.stdio(name: 'a', command: 'npx');
      final b = McpServerConfig.stdio(name: 'b', command: 'npx');
      expect(a, isNot(b));
    });

    test('different transportType', () {
      final a = McpServerConfig(name: 's', transportType: 'stdio', command: 'npx');
      final b = McpServerConfig(name: 's', transportType: 'sse', command: 'npx');
      expect(a, isNot(b));
    });

    test('different command', () {
      final a = McpServerConfig.stdio(name: 's', command: 'npx');
      final b = McpServerConfig.stdio(name: 's', command: 'node');
      expect(a, isNot(b));
    });

    test('different enabled', () {
      final a = McpServerConfig.stdio(name: 's', command: 'npx', enabled: true);
      final b = McpServerConfig.stdio(name: 's', command: 'npx', enabled: false);
      expect(a, isNot(b));
    });

    test('non-equality fields differ but still equal', () {
      final a = McpServerConfig.stdio(name: 's', command: 'npx', displayName: 'AAA', timeout: 1000);
      final b = McpServerConfig.stdio(name: 's', command: 'npx', displayName: 'BBB', timeout: 9999);
      expect(a, b);
    });

    test('hashCode consistency', () {
      final a = McpServerConfig.stdio(name: 's', command: 'npx');
      final b = McpServerConfig.stdio(name: 's', command: 'npx');
      expect(a.hashCode, b.hashCode);
    });

    test('identical object equals itself', () {
      final config = McpServerConfig.stdio(name: 's', command: 'npx');
      expect(config, config);
    });
  });
}
