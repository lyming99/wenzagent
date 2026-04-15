import 'dart:async';

import 'package:uuid/uuid.dart';

import '../agent/adapter/llm_chat_adapter.dart';
import '../agent/agent_state.dart';
import '../agent/entity/entity.dart';
import '../agent/tool/agent_tool.dart';
import '../agent/tool/builtin/builtin_tools.dart';
import '../agent/tool/tool_registry.dart';
import '../utils/logger.dart';
import 'entity/agent_runtime_config.dart';
import 'permission_forwarder.dart';

/// 子 Agent 执行结果
class SubAgentResult {
  /// 是否执行成功
  final bool success;

  /// 结果摘要文本
  final String summary;

  /// 工具调用统计（工具名 → 调用次数）
  final Map<String, int> toolCalls;

  /// 执行耗时
  final Duration duration;

  /// 错误信息（仅在 success=false 时有值）
  final String? error;

  SubAgentResult({
    required this.success,
    required this.summary,
    required this.toolCalls,
    required this.duration,
    this.error,
  });

  @override
  String toString() =>
      'SubAgentResult(success: $success, duration: ${duration.inSeconds}s, '
      'toolCalls: $toolCalls'
      '${error != null ? ", error: $error" : ""}'
      '${summary.length > 50 ? ", summary: ${summary.substring(0, 50)}..." : ", summary: $summary"})';
}

/// 子 Agent 执行器
///
/// 为每个子任务创建临时、隔离的执行环境：
/// - 不写数据库（不污染对话历史）
/// - 上下文完全隔离（独立 session）
/// - 支持自定义 system prompt、工具子集、最大轮次、超时时间
/// - 支持预加载文件到上下文
/// - 权限请求通过 [PermissionForwarder] 转发到主 Agent
/// - 用完即销毁（不占内存）
///
/// 基于 [TaskExecutor] 的模式，泛化为通用子 Agent 执行器。
class SubAgentExecutor {
  static final _log = Logger('SubAgentExecutor');

  /// 默认最大工具调用轮次
  static const int _defaultMaxTurns = 30;

  /// 默认超时时间
  static const Duration _defaultTimeout = Duration(minutes: 5);

  /// summary 最大字符数
  static const int _maxSummaryLength = 8000;

  /// 获取 Agent 配置回调（provider、systemPrompt 等）
  Future<AgentRuntimeConfig?> Function(String employeeId)? getAgentConfig;

  /// 权限请求转发回调
  ///
  /// 将子 Agent 的权限请求通过主 Agent 发送给用户。
  /// 返回用户的权限决策（allow/deny/allowAlways）。
  Future<PermissionDecision> Function(
      AgentPermissionRequest request)? requestPermission;

  /// 读取文件内容回调（用于预加载 context_files）
  ///
  /// 由调用方注入，读取指定路径的文件内容。
  /// 返回 null 表示文件不存在或读取失败。
  Future<String?> Function(String filePath)? readFileContent;

  /// 执行子 Agent 任务
  ///
  /// 完整流程:
  /// 1. 获取 Agent 配置（provider、systemPrompt）
  /// 2. 创建临时 LlmChatAdapter（不持久化）
  /// 3. 注册工具子集，设置权限转发
  /// 4. 预加载 context_files 到用户消息
  /// 5. 执行 LLM 对话，收集输出
  /// 6. 统计工具调用
  /// 7. 销毁临时环境
  Future<SubAgentResult> execute({
    required String employeeId,
    required String taskPrompt,
    String? systemPrompt,
    List<AgentTool>? tools,
    int maxTurns = _defaultMaxTurns,
    Duration timeout = _defaultTimeout,
    List<String>? contextFiles,
  }) async {
    final stopwatch = Stopwatch()..start();

    // ① 获取 Agent 配置
    final config = await getAgentConfig?.call(employeeId);
    if (config == null) {
      return SubAgentResult(
        success: false,
        summary: '',
        toolCalls: const {},
        duration: stopwatch.elapsed,
        error: 'Agent $employeeId not found',
      );
    }

    // ② 创建临时 Adapter（不持久化，纯内存）
    final adapter = LlmChatAdapter();
    final tempSessionId =
        '__sub_agent_${DateTime.now().millisecondsSinceEpoch}_${const Uuid().v4().substring(0, 8)}';

    try {
      // ③ 初始化临时会话
      await adapter.initSession(employeeId: tempSessionId);

      // ④ 设置模型
      if (config.providerConfig != null) {
        await adapter.updateProvider(config.providerConfig!);
      }

      // ⑤ 设置上下文（systemPrompt + 项目上下文）
      final context = <String, dynamic>{};
      final effectiveSystemPrompt = systemPrompt ??
          '你是一个子 Agent，负责完成分配给你的任务。'
              '完成后返回结构化的结果摘要，不要返回完整对话过程。'
              '\n\n要求：\n'
              '- 简洁明了地总结你的发现和结果\n'
              '- 列出关键信息和数据\n'
              '- 如果遇到问题，说明原因和建议的解决方案\n'
              '- 不要包含工具调用的原始输出，只总结关键信息';

      if (config.systemPrompt != null) {
        context['systemPrompt'] =
            '${config.systemPrompt}\n\n$effectiveSystemPrompt';
      } else {
        context['systemPrompt'] = effectiveSystemPrompt;
      }

      if (config.projectContext != null) {
        context.addAll(config.projectContext!);
      }

      if (context.isNotEmpty) {
        adapter.setContext(context);
      }

      // ⑥ 注册工具
      final registry = ToolRegistry();
      final effectiveTools = tools ?? BuiltinTools.readOnly();
      registry.registerTools(effectiveTools);
      adapter.setToolRegistry(registry);

      // 设置权限转发
      if (requestPermission != null) {
        final forwarder = PermissionForwarder();
        forwarder.onForwardPermissionRequest = requestPermission;
        adapter.setPermissionManager(forwarder);
      } else {
        adapter.setPermissionManager(null);
      }

      // ⑦ 构建输入消息（包含预加载文件内容）
      final messageBuilder = StringBuffer();
      if (contextFiles != null && contextFiles.isNotEmpty) {
        messageBuilder.writeln('## 预加载文件内容');
        messageBuilder.writeln();
        for (final filePath in contextFiles) {
          final content = await readFileContent?.call(filePath);
          if (content != null) {
            messageBuilder.writeln('### $filePath');
            messageBuilder.writeln('```');
            messageBuilder.writeln(content);
            messageBuilder.writeln('```');
            messageBuilder.writeln();
          } else {
            messageBuilder.writeln('### $filePath (文件不存在或读取失败)');
            messageBuilder.writeln();
          }
        }
        messageBuilder.writeln('---');
        messageBuilder.writeln();
      }
      messageBuilder.write(taskPrompt);

      // ⑧ 执行任务
      final resultBuffer = StringBuffer();
      final toolCallStats = <String, int>{};
      bool hasError = false;
      String? errorMsg;

      // 订阅工具事件以统计工具调用
      adapter.setToolEventCallback((event) {
        switch (event) {
          case ToolCallStartEvent():
            final name = event.toolName;
            toolCallStats[name] = (toolCallStats[name] ?? 0) + 1;
          case ToolCallResultEvent():
            break;
        }
      });

      try {
        await for (final response
            in adapter.streamMessage(MessageInput(
              content: messageBuilder.toString(),
              id: const Uuid().v4(),
            )).timeout(timeout, onTimeout: (sink) {
          sink.addError(
              TimeoutException('Sub-agent execution timed out', timeout));
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

      var summary = resultBuffer.toString();
      if (summary.length > _maxSummaryLength) {
        summary =
            '${summary.substring(0, _maxSummaryLength)}\n\n[结果已截断，原始输出 ${summary.length} 字符]';
      }

      return SubAgentResult(
        success: !hasError && resultBuffer.isNotEmpty,
        summary: summary.isEmpty ? '' : summary,
        toolCalls: toolCallStats,
        duration: stopwatch.elapsed,
        error: hasError ? (errorMsg ?? '未知错误') : null,
      );
    } catch (e) {
      stopwatch.stop();
      return SubAgentResult(
        success: false,
        summary: '',
        toolCalls: const {},
        duration: stopwatch.elapsed,
        error: 'SubAgentExecutor 异常: $e',
      );
    } finally {
      // ⑨ 销毁临时环境
      try {
        await adapter.dispose();
      } catch (e) {
        _log.debug('dispose temporary adapter failed: $e');
      }
    }
  }
}
