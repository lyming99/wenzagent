// 运行agent功能测试的脚本
// 用法：dart run_test.dart

import 'dart:io';

void main() async {
  // 检查环境变量
  final apiKey = Platform.environment['OPENAI_API_KEY'];
  final apiUrl = Platform.environment['OPENAI_API_URL'];
  final apiModel = Platform.environment['OPENAI_API_MODEL'];
  
  print('=== 环境变量检查 ===');
  print('OPENAI_API_KEY: ${apiKey != null ? "已设置" : "未设置"}');
  print('OPENAI_API_URL: ${apiUrl ?? "未设置（将使用默认值）"}');
  print('OPENAI_API_MODEL: ${apiModel ?? "未设置（将使用默认值）"}');
  
  if (apiKey == null || apiKey.isEmpty) {
    print('\n❌ 错误：请设置环境变量 OPENAI_API_KEY');
    print('\n使用方法：');
    print('Windows (PowerShell):');
    print('  \$env:OPENAI_API_KEY="your-api-key"');
    print('  \$env:OPENAI_API_URL="https://api.openai.com/v1"  # 可选');
    print('  \$env:OPENAI_API_MODEL="gpt-3.5-turbo"  # 可选');
    print('\nLinux/Mac:');
    print('  export OPENAI_API_KEY="your-api-key"');
    print('  export OPENAI_API_URL="https://api.openai.com/v1"  # 可选');
    print('  export OPENAI_API_MODEL="gpt-3.5-turbo"  # 可选');
    exit(1);
  }
  
  print('\n✅ 环境变量检查通过');
  print('\n开始运行测试...\n');
  
  // 运行测试
  final result = await Process.run(
    'dart',
    ['test', 'test/agent_functional_test.dart', '--reporter=expanded'],
  );
  
  print(result.stdout);
  if (result.stderr.isNotEmpty) {
    print('错误输出:');
    print(result.stderr);
  }
  
  exit(result.exitCode);
}
