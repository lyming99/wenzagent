import '../../../service/sub_agent_executor.dart';
import '../../../utils/logger.dart';
import '../agent_tool.dart';

/// 子 Agent 生成工具
///
/// 让主 Agent 可以自主创建子 Agent 处理复杂子任务。
/// 子 Agent 拥有独立的上下文、工具集和执行环境，
/// 执行完成后返回结构化的结果摘要给主 Agent。
///
/// 使用场景：
/// - 任务需要深度分析大量文件
/// - 需要广泛探索代码库
/// - 任务复杂度足够高，需要专注的独立处理
///
/// 设计要点：
/// - 子 Agent 默认只能使用只读工具，降低风险
/// - 子 Agent 不可递归调用 spawn_sub_agent
/// - 回调由 AgentFactoryImpl 注入（类似 ScheduleTaskTool 的注入模式）
class SpawnSubAgentTool extends AgentTool {
  static final _log = Logger('SpawnSubAgentTool');

  /// 默认允许子 Agent 使用的工具列表
  static const List<String> _defaultToolNames = [
    'file_read',
    'file_list',
    'file_search',
    'content_search',
    'file_info',
    'command_execute',
  ];

  /// 子 Agent 执行器（由外部注入）
  SubAgentExecutor? executor;

  /// 获取主 Agent 可用工具列表的回调（用于按名称筛选工具子集）
  List<AgentTool> Function()? getAvailableTools;

  /// 读取文件内容回调（用于 context_files 预加载）
  Future<String?> Function(String filePath)? readFileContent;

  /// 当前 Agent 的 employeeId（用于获取配置）
  String? employeeId;

  @override
  String get name => 'spawn_sub_agent';

  @override
  String get description =>
      'Spawn a sub-agent to handle a complex sub-task autonomously. '
      'The sub-agent has its own isolated context and can use tools to complete the task. '
      'It returns a structured summary of its findings, not the full conversation.\n\n'
      'Use this tool when:\n'
      '- The task requires deep analysis of many files\n'
      '- You need to explore the codebase extensively\n'
      '- The task is complex enough to benefit from focused, isolated attention\n'
      '- You want to parallelize work by delegating a sub-task\n\n'
      'The sub-agent cannot spawn further sub-agents (no recursion). '
      'It operates with a restricted set of tools for safety.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'task': {
            'type': 'string',
            'description':
                'A clear, detailed description of the sub-task for the sub-agent to complete. '
                'Include all necessary context and expected output format.',
          },
          'system_prompt': {
            'type': 'string',
            'description':
                'Optional custom system prompt for the sub-agent. '
                'If not provided, a default prompt focusing on task completion and summary will be used.',
          },
          'tools': {
            'type': 'array',
            'items': {
              'type': 'string',
            },
            'description':
                'List of tool names the sub-agent is allowed to use. '
                'Default: ["file_read", "file_list", "file_search", "content_search", "file_info", "command_execute"]. '
                'The sub-agent cannot use "spawn_sub_agent" to prevent recursion.',
          },
          'max_turns': {
            'type': 'integer',
            'description':
                'Maximum number of tool-calling iterations for the sub-agent. Default: 30.',
          },
          'context_files': {
            'type': 'array',
            'items': {
              'type': 'string',
            },
            'description':
                'List of file paths to preload into the sub-agent context before task execution. '
                'Useful for providing the sub-agent with relevant code or documentation.',
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

    if (executor == null) {
      return ToolResult.error(
        'Sub-agent executor is not available. '
        'The executor callback has not been injected.',
      );
    }

    if (employeeId == null) {
      return ToolResult.error('employeeId is not configured');
    }

    // 解析参数
    final systemPrompt = arguments['system_prompt'] as String?;
    final requestedToolNames =
        (arguments['tools'] as List?)?.cast<String>() ?? _defaultToolNames;
    final maxTurns = arguments['max_turns'] as int? ?? 30;
    final contextFiles =
        (arguments['context_files'] as List?)?.cast<String>();

    // 安全：禁止递归调用 spawn_sub_agent
    final safeToolNames =
        requestedToolNames.where((name) => name != 'spawn_sub_agent').toList();

    // 从主 Agent 的工具注册器获取工具实例
    final availableTools = getAvailableTools?.call() ?? [];
    final toolMap = <String, AgentTool>{};
    for (final tool in availableTools) {
      toolMap[tool.name] = tool;
    }

    final selectedTools = <AgentTool>[];
    for (final name in safeToolNames) {
      final tool = toolMap[name];
      if (tool != null) {
        selectedTools.add(tool);
      } else {
        _log.debug('Requested tool "$name" not found, skipping');
      }
    }

    if (selectedTools.isEmpty) {
      return ToolResult.error(
        'No valid tools available for the sub-agent. '
        'Requested: $safeToolNames, Available: ${toolMap.keys.toList()}',
      );
    }

    _log.info(
      'Spawning sub-agent: tools=${selectedTools.map((t) => t.name).toList()}, '
      'maxTurns=$maxTurns, contextFiles=${contextFiles?.length ?? 0}',
    );

    // 执行子 Agent
    final result = await executor!.execute(
      employeeId: employeeId!,
      taskPrompt: task,
      systemPrompt: systemPrompt,
      tools: selectedTools,
      maxTurns: maxTurns,
      contextFiles: contextFiles,
    );

    // 构建返回结果
    if (result.success) {
      final toolCallSummary = result.toolCalls.isEmpty
          ? 'No tools were called.'
          : result.toolCalls.entries
              .map((e) => '${e.key}: ${e.value} calls')
              .join(', ');

      return ToolResult.success(
        '## Sub-agent Result\n\n'
        '${result.summary}\n\n'
        '---\n'
        'Execution time: ${result.duration.inSeconds}s | '
        'Tools used: $toolCallSummary',
      );
    } else {
      return ToolResult.error(
        'Sub-agent execution failed: ${result.error}\n\n'
        'Partial output: ${result.summary.isNotEmpty ? result.summary : "(none)"}',
      );
    }
  }
}
