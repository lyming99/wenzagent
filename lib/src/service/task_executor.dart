import 'dart:async';

import 'package:uuid/uuid.dart';

import '../agent/adapter/langchain_chat_adapter.dart';
import '../agent/agent_state.dart';
import '../agent/tool/agent_tool.dart';
import '../agent/tool/builtin/builtin_tools.dart';
import '../agent/tool/tool_registry.dart';
import 'permission_forwarder.dart';

/// 定时任务执行结果
class TaskExecutionResult {
  final bool success;
  final String? output;
  final String? error;
  final Duration duration;

  TaskExecutionResult({
    required this.success,
    this.output,
    this.error,
    required this.duration,
  });

  @override
  String toString() =>
      'TaskExecutionResult(success: $success, duration: ${duration.inSeconds}s'
      '${error != null ? ", error: $error" : ""}'
      '${output != null ? ", output: ${output!.length > 50 ? "${output!.substring(0, 50)}..." : output}" : ""})';
}

/// 定时任务执行器
///
/// 为每个定时任务创建临时、隔离的执行环境：
/// - 不写数据库（不污染对话历史）
/// - 无权限管理（自动批准所有工具）
/// - 无打断判断（单任务顺序执行）
/// - 用完即销毁（不占内存）
///
/// 执行完成后把结果通过 [deliverResult] 送入正式 Agent 通道。
class TaskExecutor {
  /// 获取 Agent 配置（provider、systemPrompt 等）
  ///
  /// 返回 Map 可能包含:
  /// - `providerConfig`: Map — ProviderConfig.toMap()
  /// - `systemPrompt`: String
  /// - `projectContext`: Map
  /// - `tools`: `List<AgentTool>`
  Future<Map<String, dynamic>?> Function(String employeeId)? getAgentConfig;

  /// 把结果推送给用户（走正式 Agent 的消息通道）
  Future<void> Function(String employeeId, String content)? deliverResult;

  /// 权限请求转发回调
  ///
  /// 由 ScheduledTaskManager 注入，将 sub-agent 的权限请求通过主 agent 发送给用户。
  /// 返回用户的权限决策（allow/deny/allowAlways）。
  Future<PermissionDecision> Function(
      AgentPermissionRequest request)? requestPermission;

  /// 执行一个定时任务
  ///
  /// 完整流程:
  /// 1. 创建临时 LangChainChatAdapter
  /// 2. 设置模型（复用正式 Agent 的 Provider）
  /// 3. 注册工具，不设权限管理器
  /// 4. 调用 streamMessage 执行
  /// 5. 收集完整输出
  /// 6. 销毁临时环境
  /// 7. 通过 deliverResult 把结果送达给用户
  Future<TaskExecutionResult> execute({
    required String employeeId,
    required String taskPrompt,
    String? systemPrompt,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final stopwatch = Stopwatch()..start();

    // ① 获取该 Agent 的配置
    final config = await getAgentConfig?.call(employeeId);
    if (config == null) {
      return TaskExecutionResult(
        success: false,
        error: 'Agent $employeeId not found',
        duration: stopwatch.elapsed,
      );
    }

    // ② 创建临时 Adapter（不持久化，纯内存）
    final adapter = LangChainChatAdapter();
    final tempSessionId =
        '__task_${DateTime.now().millisecondsSinceEpoch}';

    try {
      // ③ 初始化临时会话
      await adapter.initSession(employeeId: tempSessionId);

      // ④ 设置模型
      final providerConfig =
          config['providerConfig'] as Map<String, dynamic>?;
      if (providerConfig != null) {
        await adapter.updateProvider(providerConfig);
      }

      // ⑤ 设置上下文（systemPrompt + 项目上下文）
      final context = <String, dynamic>{};
      // 定时任务专属 system prompt：让 LLM 知道自己是提醒助手
      final scheduledSystemPrompt =
          '你是一个定时提醒助手。当前有一个定时提醒触发了，请根据提醒内容，生成一条简洁、友好的温馨提示发送给用户。\n\n'
          '要求：\n'
          '- 直接输出温馨提醒内容，不要说"已设置提醒"、"我会提醒你"之类的话\n'
          '- 语气温暖自然，像朋友一样关心用户\n'
          '- 简洁明了，2-4句话即可\n'
          '- 可以适当加一点表情符号增加亲和力';
      if (config['systemPrompt'] != null) {
        context['systemPrompt'] =
            '${config['systemPrompt']}\n\n$scheduledSystemPrompt';
      } else {
        context['systemPrompt'] = scheduledSystemPrompt;
      }
      if (config['projectContext'] != null) {
        context.addAll(config['projectContext'] as Map<String, dynamic>);
      }
      if (context.isNotEmpty) {
        adapter.setContext(context);
      }

      // ⑥ 注册工具 —— 使用 PermissionForwarder 将权限请求转发到主 agent
      final registry = ToolRegistry();
      final tools =
          config['tools'] as List<AgentTool>? ?? BuiltinTools.readOnly();
      registry.registerTools(tools);
      adapter.setToolRegistry(registry);

      if (requestPermission != null) {
        final forwarder = PermissionForwarder();
        forwarder.onForwardPermissionRequest = requestPermission;
        adapter.setPermissionManager(forwarder);
      } else {
        adapter.setPermissionManager(null);
      }

      // ⑦ 执行任务
      final resultBuffer = StringBuffer();
      bool hasError = false;
      String? errorMsg;

      try {
        await for (final response
            in adapter.streamMessage({
              'content': '提醒内容：$taskPrompt',
              'id': const Uuid().v4(),
            }).timeout(timeout, onTimeout: (sink) {
              sink.addError(TimeoutException(
                  'Task execution timed out', timeout));
              sink.close();
            })) {
          if (response.error != null) {
            hasError = true;
            errorMsg = response.error;
            break;
          }
          if (response.content != null) {
            resultBuffer.write(response.content);
          }
          if (response.isDone) break;
        }
      } on TimeoutException {
        hasError = true;
        errorMsg = '执行超时 (${timeout.inMinutes} 分钟)';
      } catch (e) {
        hasError = true;
        errorMsg = e.toString();
      }

      stopwatch.stop();

      final result = TaskExecutionResult(
        success: !hasError && resultBuffer.isNotEmpty,
        output: resultBuffer.isEmpty ? null : resultBuffer.toString(),
        error: hasError ? (errorMsg ?? '未知错误') : null,
        duration: stopwatch.elapsed,
      );

      // ⑧ 把结果送达给用户
      if (deliverResult != null) {
        if (result.success && result.output != null) {
          await deliverResult!(employeeId, result.output!);
        } else {
          await deliverResult!(employeeId,
              '⚠️ 定时任务「${taskPrompt.length > 30 ? taskPrompt.substring(0, 30) : taskPrompt}」执行失败：${result.error}');
        }
      }

      return result;
    } catch (e) {
      stopwatch.stop();
      return TaskExecutionResult(
        success: false,
        error: 'TaskExecutor 异常: $e',
        duration: stopwatch.elapsed,
      );
    } finally {
      // ⑨ 销毁临时环境
      try {
        await adapter.dispose();
      } catch (_) {}
    }
  }
}
