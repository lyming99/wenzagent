import 'dart:async';
import 'dart:io';

import 'package:wenzagent/wenzagent.dart';

void main() async {
  // 检查 API Key
  final apiKey = Platform.environment['OPENAI_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    print('请设置环境变量 OPENAI_API_KEY');
    exit(1);
  }

  print('=== WenzAgent Tool Calling 示例 ===\n');

  // 1. 创建 Agent
  final adapter = LlmChatAdapter();
  final agent = AgentImpl(
    employeeId: 'test-employee-001',
    deviceId: 'test-device-001',
    chatAdapter: adapter,
  );

  // 2. 初始化 Agent（自动注册内置工具）
  await agent.initialize();

  // 3. 配置 LLM Provider
  final providerConfig = ProviderConfig(
    provider: LLMProvider.openai,
    model: 'gpt-4o-mini',
    apiKey: apiKey,
    options: const LLMOptions(temperature: 0.7),
  );
  await agent.setProvider(providerConfig);

  // 4. 查看已注册的工具
  final tools = agent.getRegisteredTools();
  print('已注册 ${tools.length} 个工具:');
  for (final tool in tools) {
    final perm = tool['requiresPermission'] == true ? ' [需要权限]' : '';
    print('  - ${tool['name']}$perm');
  }
  print('');

  // 5. 设置系统提示
  await agent.setContext({
    'systemPrompt':
        '你是一个有用的助手，可以使用工具来帮助用户完成文件操作和命令执行等任务。'
        '请优先使用工具来完成任务，而不是猜测结果。',
  });

  // 6. 监听事件
  agent.onEvent.listen((event) {
    final type = event.type;
    final data = event.data;

    switch (type) {
      case AgentEventType.toolCallStart:
        print('\n  [工具调用] ${data['toolName']}(${data['arguments']})');
        break;
      case AgentEventType.toolCallResult:
        final result = data['result'] as String? ?? '';
        final isError = data['isError'] as bool? ?? false;
        final duration = data['durationMs'] as int?;
        final preview = result.length > 200
            ? '${result.substring(0, 200)}...'
            : result;
        print('  [工具结果] ${isError ? "错误: " : ""}$preview (${duration}ms)');
        break;
      case AgentEventType.toolPermissionRequest:
        print('\n  [权限请求] ${data['description']}');
        // 在实际应用中，这里应该等待用户确认
        // 本示例自动同意
        final requestId = data['requestId'] as String?;
        if (requestId != null) {
          agent.respondToPermission(requestId, PermissionDecision.allow);
        }
        break;
      case AgentEventType.agentStatusChanged:
        // 状态变更静默处理
        break;
      default:
        break;
    }
  });

  // 7. 发送消息测试 - 简单的文件操作
  print('--- 测试 1: 列出当前目录文件 ---');
  await _sendAndWait(agent, '请列出当前目录下的文件');

  print('\n--- 测试 2: 读取文件 ---');
  await _sendAndWait(agent, '请读取 pubspec.yaml 文件的内容');

  print('\n--- 测试完成 ---');

  // 8. 清理
  await agent.dispose();
  print('\nAgent 已销毁');
}

/// 发送消息并等待完成
Future<void> _sendAndWait(AgentImpl agent, String content) async {
  print('用户: $content');
  print('助手: ');

  final completer = Completer<void>();

  // 监听消息状态变更
  late StreamSubscription sub;
  sub = agent.onEvent.listen((event) {
    final type = event.type;
    if (type == AgentEventType.messageStatusChanged) {
      final status = event.data['status'] as String?;
      if (status == 'completed' || status == 'failed') {
        sub.cancel();
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    }
  });

  // 监听流式输出
  late StreamSubscription stateSub;
  stateSub = agent.onStateChanged.listen((_) {});

  await agent.sendMessage(MessageInput(content: content));

  // 等待完成（超时 60 秒）
  await completer.future.timeout(
    const Duration(seconds: 60),
    onTimeout: () {
      print('\n  [超时]');
    },
  );

  await stateSub.cancel();
  print('');
}
