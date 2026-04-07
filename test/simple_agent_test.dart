import 'dart:io';

import 'package:test/test.dart';
import 'package:wenzagent/src/agent/adapter/provider_config.dart';
import 'package:wenzagent/src/persistence/persistence.dart';

void main() {
  test('环境检查', () {
    final apiKey = Platform.environment['OPENAI_API_KEY'];
    final apiUrl = Platform.environment['OPENAI_API_URL'];
    final apiModel = Platform.environment['OPENAI_API_MODEL'];
    
    print('\n=== 环境变量检查 ===');
    print('OPENAI_API_KEY: ${apiKey != null ? "已设置 (${apiKey.length}字符)" : "未设置"}');
    print('OPENAI_API_URL: ${apiUrl ?? "未设置"}');
    print('OPENAI_API_MODEL: ${apiModel ?? "未设置"}');
    
    expect(apiKey, isNotEmpty, reason: '请设置 OPENAI_API_KEY');
  });
  
  test('Hive初始化', () async {
    print('\n=== 测试Hive初始化 ===');
    
    try {
      // 指定Hive存储路径
      final hivePath = 'D:\\project\\GitHub\\wenzagent\\test_hive';
      await HiveManager.instance.initialize(storagePath: hivePath);
      print('✅ Hive初始化成功');
      print('Storage path: $hivePath');
      print('isInitialized: ${HiveManager.instance.isInitialized}');
      
      await HiveManager.instance.close();
      print('✅ Hive关闭成功');
    } catch (e, stackTrace) {
      print('❌ Hive初始化失败: $e');
      print('Stack trace: $stackTrace');
      rethrow;
    }
  });
  
  test('ProviderConfig创建', () {
    print('\n=== 测试ProviderConfig创建 ===');
    
    final apiKey = Platform.environment['OPENAI_API_KEY']!;
    final apiUrl = Platform.environment['OPENAI_API_URL'] ?? 'https://api.openai.com/v1';
    final apiModel = Platform.environment['OPENAI_API_MODEL'] ?? 'gpt-3.5-turbo';
    
    try {
      final config = ProviderConfig(
        provider: LLMProvider.openai,
        apiKey: apiKey,
        baseUrl: apiUrl,
        model: apiModel,
      );
      
      print('✅ ProviderConfig创建成功');
      print('Provider: ${config.provider}');
      print('Model: ${config.model}');
      print('BaseUrl: ${config.baseUrl}');
      
      // 验证配置
      config.validate();
      print('✅ 配置验证通过');
    } catch (e, stackTrace) {
      print('❌ ProviderConfig创建失败: $e');
      print('Stack trace: $stackTrace');
      rethrow;
    }
  });
}
