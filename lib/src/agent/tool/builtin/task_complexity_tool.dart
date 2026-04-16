import '../../../service/sub_agent_executor.dart';
import '../../../utils/logger.dart';
import '../agent_tool.dart';

/// 开发任务复杂度识别工具
///
/// 使用 SubAgentExecutor 创建只读子 Agent 探索代码库，
/// 对用户任务进行复杂度分析，返回任务等级（小型/中型/复杂）及建议执行策略。
///
/// 注入流程：
/// 1. BuiltinTools.all() 创建实例
/// 2. AgentImpl._injectTaskComplexityCallbacks() 注入 executor / employeeId / readFileContent 回调
class TaskComplexityTool extends AgentTool {
  static final _log = Logger('TaskComplexityTool');

  /// 分析子 Agent 可用工具集：只读工具 + 命令执行，用于探索代码库
  static const List<String> _analysisToolNames = [
    'file_list',
    'file_read',
    'content_search',
    'code_symbols',
    'env_info',
    'command_execute',
    'end',
  ];

  /// 子 Agent 执行器（由 AgentImpl 注入，复用主 Agent 的 provider/权限配置）
  SubAgentExecutor? executor;

  /// 当前 Agent 的 employeeId（由 AgentImpl 注入）
  String? employeeId;

  /// 读取文件内容回调（由 AgentImpl 注入）
  Future<String?> Function(String filePath)? readFileContent;

  /// 获取主 Agent 可用工具列表的回调（由 AgentImpl 注入）
  List<AgentTool> Function()? getAvailableTools;

  @override
  String get name => 'task_complexity';

  @override
  String get description =>
      '分析开发任务的复杂度并推荐委派策略。'
      '通过 AI 评估任务是简单（单次子 Agent 委派）、'
      '中型（待办驱动的多步委派）还是复杂（规格驱动的分阶段委派）。\n\n'
      '在收到新用户任务时调用此工具来确定规划和委派方式。'
      '所有任务都委派给子 Agent 执行，复杂度仅影响规划粒度。';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'task': {'type': 'string', 'description': '要进行复杂度分析的用户任务描述。'},
      'context': {
        'type': 'string',
        'description': '可选的补充上下文，如当前项目信息、相关文件等，有助于评估任务复杂度。',
      },
    },
    'required': ['task'],
  };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final task = arguments['task'] as String?;
    if (task == null || task.isEmpty) {
      return ToolResult.error('task is required');
    }

    // 诊断：检查注入状态
    if (executor == null) {
      final diag = StringBuffer(
        'Task complexity analysis is not available. Injection diagnostics:\n',
      );
      diag.writeln('- executor: null (expected: SubAgentExecutor)');
      diag.writeln('- employeeId: ${employeeId ?? "null"}');
      diag.writeln(
        '- readFileContent: ${readFileContent != null ? "injected" : "null"}',
      );
      diag.writeln(
        '- getAvailableTools: ${getAvailableTools != null ? "injected" : "null"}',
      );
      _log.error(diag.toString().trim());
      return ToolResult.error(diag.toString().trim());
    }

    if (employeeId == null) {
      return ToolResult.error('employeeId is not configured');
    }

    final context = arguments['context'] as String?;

    // 构建子 Agent 的分析任务 prompt
    final taskPrompt = _buildAnalysisPrompt(task, context);

    // 筛选只读工具实例
    final availableTools = getAvailableTools?.call() ?? [];
    final toolMap = <String, AgentTool>{};
    for (final tool in availableTools) {
      toolMap[tool.name] = tool;
    }

    final selectedTools = <AgentTool>[];
    for (final name in _analysisToolNames) {
      final tool = toolMap[name];
      if (tool != null) {
        selectedTools.add(tool);
      }
    }

    if (selectedTools.isEmpty) {
      _log.warn(
        'No read-only tools available, falling back to empty toolset. '
        'Available: ${toolMap.keys.toList()}',
      );
    }

    _log.info(
      'Starting complexity analysis sub-agent: '
      'tools=${selectedTools.map((t) => t.name).toList()}, maxTurns=15',
    );

    try {
      final result = await executor!.execute(
        employeeId: employeeId!,
        taskPrompt: taskPrompt,
        systemPrompt: _analysisSystemPrompt,
        tools: selectedTools.isNotEmpty ? selectedTools : null,
        maxTurns: 100,
      );

      if (!result.success) {
        _log.error('Complexity analysis sub-agent failed: ${result.error}');
        return ToolResult.error(
          'Task complexity analysis failed: ${result.error}',
        );
      }

      if (result.summary.isEmpty) {
        return ToolResult.error('AI returned empty analysis result');
      }

      _log.info(
        'Complexity analysis completed in ${result.duration.inSeconds}s, '
        'tools used: ${result.toolCalls}',
      );

      return ToolResult.success(result.summary);
    } catch (e, st) {
      _log.error('Task complexity analysis failed', e, st);
      return ToolResult.error('Task complexity analysis failed: $e');
    }
  }

  /// 分析子 Agent 的 system prompt
  static const _analysisSystemPrompt =
      '你是一个开发任务复杂度评估专家。你的任务是探索代码库，分析给定的开发任务，判断其复杂度等级并给出委派建议。\n\n'
      '你有以下工具可用：\n'
      '- file_list, file_read, content_search(searchType=file 可按文件名搜索), code_symbols, env_info：用于探索代码结构和文件内容\n'
      '- command_execute：用于执行命令（如 git log、grep、find 等）辅助分析\n'
      '- end：确认任务完成并返回分析结果，如果信息不足则使用 end 说明原因\n\n'
      '请主动探索相关文件和代码结构，基于实际代码库情况做出准确判断。\n\n'
      '重要：主 Agent 是纯粹的规划者和委派者，不直接执行任何文件操作或命令。'
      '所有实际工作都通过 spawn_sub_agent 委派给子 Agent 执行。复杂度等级仅影响规划和委派策略。\n\n'
      '分析完成后，请严格按以下格式输出结果，不要输出其他内容：\n\n'
      '**复杂度等级**：简单/中型/复杂\n\n'
      '**判断依据**：(基于代码库实际情况，简要说明为什么是这个等级)\n\n'
      '**委派策略**：(根据对应等级的做法，给出具体的委派步骤建议)\n\n'
      '**注意事项**：(如有需要特别注意的风险或依赖项)';

  /// 构建任务复杂度分析的任务 prompt
  String _buildAnalysisPrompt(String task, String? context) {
    final buffer = StringBuffer();

    buffer.writeln();
    buffer.writeln('## 任务描述');
    buffer.writeln(
      '请对待分析的任务根据下面的分级标准进行分析评分，探索代码库中与任务相关的文件和结构，返回任务分级，给出分析结果，如果资料不足，则根据待分析的任务描述进行简要分析。',
    );
    buffer.writeln();
    buffer.writeln('## 待分析的任务(用户提供的开发任务或其它任务)');
    buffer.writeln();
    buffer.writeln(task);
    buffer.writeln('## 任务分级标准');
    buffer.writeln();
    buffer.writeln('### 1. 简单任务 → 单次委派');
    buffer.writeln('适用于：单文件修改、简单查询、格式转换等可在 1-3 轮工具调用内完成的工作。');
    buffer.writeln('做法：创建单个待办项，使用 spawn_sub_agent 委派给子 Agent 一次性完成。');
    buffer.writeln();
    buffer.writeln('### 2. 中型任务 → 待办驱动 + 多次委派');
    buffer.writeln('适用于：涉及多文件修改、需要多步骤完成、有明确预期的工作。');
    buffer.writeln('做法：');
    buffer.writeln('1. 使用 todo_manage 创建待办列表，将任务拆分为可独立执行的子项');
    buffer.writeln('2. 对每个待办项，使用 spawn_sub_agent 创建子 Agent 执行');
    buffer.writeln('3. 子 Agent 返回结果后，主 Agent 验收代码质量和需求满足度');
    buffer.writeln('4. 验收通过则标记待办为 completed，不通过则修正后重新委派');
    buffer.writeln('5. 所有待办完成后向用户汇报整体结果');
    buffer.writeln();
    buffer.writeln('### 3. 复杂任务 → Spec 驱动 + 分阶段委派');
    buffer.writeln('适用于：需求不够明确、涉及架构调整、需要多个中型任务协作的工作。');
    buffer.writeln('做法：');
    buffer.writeln('1. 提示用户创建 Spec，使用 spec_manage 记录需求规格');
    buffer.writeln('2. 与用户反复讨论、修正 Spec，直到需求完全对齐');
    buffer.writeln('3. 根据最终 Spec 拆分为多个中型任务，使用 todo_manage 创建待办列表');
    buffer.writeln('4. 按照中型任务的流程逐个委派给子 Agent 执行');
    buffer.writeln('5. 所有待办完成后对照 Spec 做最终检查');
    buffer.writeln();

    if (context != null && context.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('## 补充上下文');
      buffer.writeln();
      buffer.writeln(context);
    }
    buffer.writeln();

    return buffer.toString();
  }
}
