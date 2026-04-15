import '../../../service/sub_agent_executor.dart';
import '../../../utils/logger.dart';
import '../agent_tool.dart';

/// 子 Agent 生成工具
///
/// 让主 Agent 可以自主创建子 Agent 处理复杂子任务。
/// 子 Agent 拥有独立的上下文、工具集和执行环境，
/// 执行完成后返回结构化的结果摘要给主 Agent。
///
/// 注入流程（两层注入）：
/// 1. AgentImpl.initialize() 注入 getAvailableTools（工具注册器引用）
/// 2. AgentFactoryImpl 注入 executor（SubAgentExecutor 含 provider/权限/文件读取回调）
///
/// 如果 executor 未注入（例如测试环境），execute() 返回明确的诊断错误。
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
    'bg_command',
    'code_symbols',
  ];

  /// 子 Agent 执行器（由 AgentFactoryImpl 注入）
  ///
  /// 包含 provider 配置获取、权限转发、文件读取等回调。
  /// 如果为 null，说明工厂未完成注入。
  SubAgentExecutor? executor;

  /// 获取主 Agent 可用工具列表的回调（由 AgentImpl.initialize() 注入）
  List<AgentTool> Function()? getAvailableTools;

  /// 读取文件内容回调（由 AgentFactoryImpl 注入）
  Future<String?> Function(String filePath)? readFileContent;

  /// 当前 Agent 的 employeeId（由 AgentFactoryImpl 注入）
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
                'Default: ["file_read", "file_list", "file_search", "content_search", "file_info", "command_execute", "bg_command", "code_symbols"]. '
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

    // 诊断：检查注入状态
    if (executor == null) {
      final diag = StringBuffer(
        'Sub-agent executor is not available. Injection diagnostics:\n',
      );
      diag.writeln('- executor: null (expected: SubAgentExecutor from AgentFactoryImpl)');
      diag.writeln('- employeeId: ${employeeId ?? "null"}');
      diag.writeln('- getAvailableTools: ${getAvailableTools != null ? "injected" : "null"}');
      diag.writeln('- readFileContent: ${readFileContent != null ? "injected" : "null"}');
      diag.writeln();
      diag.writeln('Possible causes:');
      diag.writeln('1. Agent created without going through AgentFactoryImpl');
      diag.writeln('2. _injectSpawnSubAgentCallbacks failed silently (check logs)');
      diag.writeln('3. The agent was not fully initialized before tool use');
      _log.error(diag.toString().trim());
      return ToolResult.error(diag.toString().trim());
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
