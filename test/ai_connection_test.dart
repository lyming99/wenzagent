// ============================================================================
// AI 连接测试脚本
// ============================================================================
//
// 使用 llm_dart 验证各种 LLM 提供商的 API 连通性。
// 读取 config/ai_test_config.yaml 配置，遍历所有启用的提供商进行测试。
//
// 用法:
//   dart run test/ai_connection_test.dart
//   dart run test/ai_connection_test.dart --config path/to/config.yaml
//   dart run test/ai_connection_test.dart --provider openai
//   dart run test/ai_connection_test.dart --provider anthropic --config my.yaml
// ============================================================================

import 'dart:io';

import 'package:yaml/yaml.dart';

import 'package:wenzagent/wenzagent.dart';

void main(List<String> args) async {
  // ── 解析命令行参数 ──
  String? configPath;
  String? filterProvider;

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--config' && i + 1 < args.length) {
      configPath = args[++i];
    } else if (args[i] == '--provider' && i + 1 < args.length) {
      filterProvider = args[++i];
    } else if (args[i] == '--help' || args[i] == '-h') {
      _printUsage();
      return;
    }
  }

  // ── 加载配置 ──
  configPath ??= 'config/ai_test_config.yaml';

  final configFile = File(configPath);
  if (!configFile.existsSync()) {
    print('❌ 配置文件不存在: $configPath');
    print('   请复制 config/ai_test_config.yaml.example 为 $configPath 并填入实际值');
    exit(1);
  }

  final yamlContent = configFile.readAsStringSync();
  final yamlMap = loadYaml(yamlContent) as YamlMap;

  final providers = yamlMap['providers'] as YamlMap?;
  if (providers == null || providers.isEmpty) {
    print('❌ 配置文件中未找到 providers 节点');
    exit(1);
  }

  final testMessage = (yamlMap['testMessage'] as String?) ?? 'Hi';
  final timeoutSec = (yamlMap['timeout'] as int?) ?? 30;

  print('═══════════════════════════════════════');
  print('  AI Connection Test');
  print('═══════════════════════════════════════');
  print('Config     : $configPath');
  print('Test Msg   : "$testMessage"');
  print('Timeout    : ${timeoutSec}s');
  print('');

  // ── 遍历测试 ──
  final entries = providers.entries.toList();
  int passed = 0;
  int failed = 0;

  for (var i = 0; i < entries.length; i++) {
    final name = entries[i].key as String;
    final config = entries[i].value as YamlMap;

    // 过滤指定提供商
    if (filterProvider != null && name.toLowerCase() != filterProvider.toLowerCase()) {
      continue;
    }

    final providerStr = config['provider'] as String? ?? name;
    final model = config['model'] as String? ?? '';
    final apiKey = config['apiKey'] as String? ?? '';
    final baseUrl = config['baseUrl'] as String? ?? '';

    print('── [${i + 1}/${entries.length}] ${_capitalize(name)} ($model) ──');

    // 跳过未配置的提供商
    final needsKey = providerStr != 'ollama';
    if (needsKey && (apiKey.isEmpty || apiKey == 'sk-xxx' || apiKey == 'sk-ant-xxx' || apiKey == 'AIzaXXX')) {
      print('  ⏭️  跳过（未配置 API Key）');
      print('');
      continue;
    }

    // 构建 ProviderConfig
    final providerConfig = ProviderConfig(
      provider: LLMProvider.values.firstWhere(
        (e) => e.name == providerStr.toLowerCase(),
        orElse: () => LLMProvider.openai,
      ),
      model: model,
      apiKey: apiKey.isNotEmpty ? apiKey : null,
      baseUrl: baseUrl.isNotEmpty ? baseUrl : null,
    );

    // 测试连接
    final result = await AiConnectionTester.testConnection(
      providerConfig,
      testMessage: testMessage,
      timeout: Duration(seconds: timeoutSec),
    );

    if (result.success) {
      passed++;
      // 截断过长的回复
      final displayResponse = result.response != null && result.response!.length > 80
          ? '${result.response!.substring(0, 80)}...'
          : result.response;
      print('  ✅ 成功 (${result.latencyMs}ms): $displayResponse');
    } else {
      failed++;
      print('  ❌ 失败 (${result.latencyMs}ms): ${result.error}');
    }
    print('');
  }

  // ── 汇总 ──
  final total = passed + failed;
  print('═══════════════════════════════════════');
  print('  Summary: $total tests | ✅ $passed passed | ❌ $failed failed');
  print('═══════════════════════════════════════');

  exit(failed > 0 ? 1 : 0);
}

String _capitalize(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1);
}

void _printUsage() {
  print('AI Connection Test - 使用 llm_dart 验证 LLM API 连通性');
  print('');
  print('用法:');
  print('  dart run test/ai_connection_test.dart [选项]');
  print('');
  print('选项:');
  print('  --config <path>    配置文件路径（默认: config/ai_test_config.yaml）');
  print('  --provider <name>  只测试指定提供商（openai/anthropic/google/ollama）');
  print('  --help, -h         显示帮助');
  print('');
  print('示例:');
  print('  dart run test/ai_connection_test.dart');
  print('  dart run test/ai_connection_test.dart --provider openai');
  print('  dart run test/ai_connection_test.dart --config my_config.yaml');
}
