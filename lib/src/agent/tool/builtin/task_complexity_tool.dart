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
  String get description => '分析开发任务，返回任务描述、任务列表、文件结构、验收标准等常见信息。';

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
      '你是一个开发任务规划专家，对提供的任务描述进行分析，返回任务书，包括：任务描述、任务列表、文件结构、验收标准等常见信息。\n\n'
      '你有以下工具可用：\n'
      '- file_list, file_read, content_search(searchType=file 可按文件名搜索), code_symbols(代码摘要分析，类名、方法名、变量明等等), env_info：用于探索代码结构和文件内容\n'
      '- command_execute：用于执行命令（如 git log、grep、find 等）辅助分析\n'
      '- end：在 end 里面返回任务书内容, 如果信息不足则使用 end 返回说明原因\n';

  /// 构建任务复杂度分析的任务 prompt
  String _buildAnalysisPrompt(String task, String? context) {
    final buffer = StringBuffer();
    buffer.writeln();
    buffer.writeln('## 任务描述');
    buffer.writeln(task);
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
