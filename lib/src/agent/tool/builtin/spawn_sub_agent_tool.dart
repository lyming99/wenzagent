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
  ///
  /// 包含除 todo_manage、spec_manage、schedule_task、spawn_sub_agent 外的所有工具。
  /// - todo_manage/spec_manage: 这些是主 Agent 的任务管理工具，子 Agent 不应操作。
  /// - schedule_task: 定时任务由主 Agent 管理。
  /// - spawn_sub_agent: 禁止递归生成子 Agent。
  static const List<String> _defaultToolNames = [
    'end',
    'file_read',
    'file_write',
    'file_list',
    'content_search',
    'file_info',
    'file_copy',
    'file_delete',
    'file_patch',
    'directory_create',
    'command_execute',
    'bg_command',
    'git_operations',
    'code_symbols',
    'env_info',
    'web_fetch',
    'web_search_prime',
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
      '创建子 Agent 自主执行任务。'
      '子 Agent 在独立上下文中运行，拥有所有文件操作、命令执行、搜索等执行工具，'
      '返回结构化的工作摘要。\n\n'
      '适用于复杂的多步骤任务需要独立上下文执行，'
      '或需要隔离执行环境的场景。\n'
      '子 Agent 可以：\n'
      '- 读取、写入、补丁和删除文件\n'
      '- 执行命令和管理后台进程\n'
      '- 搜索文件、内容和代码符号\n'
      '- 执行 Git 操作\n'
      '- 获取网页内容和搜索互联网\n\n'
      '子 Agent 不能递归创建子 Agent，'
      '也不能管理待办/规格/定时任务（由主 Agent 负责）。';

  @override
  Map<String, dynamic> get inputJsonSchema => {
    'type': 'object',
    'properties': {
      'task': {
        'type': 'string',
        'description':
            '子任务的清晰详细描述，包含所有必要的上下文和预期输出格式。',
      },
      'system_prompt': {
        'type': 'string',
        'description':
            '子 Agent 的自定义系统提示词。'
            '如未提供，使用聚焦于任务完成和结果摘要的默认提示词。',
      },
      'tools': {
        'type': 'array',
        'items': {'type': 'string'},
        'description':
            '子 Agent 可使用的工具名称列表。'
            '默认包含除 todo_manage、spec_manage、schedule_task、spawn_sub_agent 外的所有工具。'
            '子 Agent 不能使用 "spawn_sub_agent"（防止递归），'
            '也不能使用 "todo_manage"/"spec_manage"/"schedule_task"（由主 Agent 管理）。',
      },
      'max_turns': {
        'type': 'integer',
        'description':
            '子 Agent 的最大工具调用轮次。默认：100。',
      },
      'context_files': {
        'type': 'array',
        'items': {'type': 'string'},
        'description':
            '任务执行前预加载到子 Agent 上下文的文件路径列表。'
            '用于向子 Agent 提供相关代码或文档。',
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
      diag.writeln(
        '- executor: null (expected: SubAgentExecutor from AgentFactoryImpl)',
      );
      diag.writeln('- employeeId: ${employeeId ?? "null"}');
      diag.writeln(
        '- getAvailableTools: ${getAvailableTools != null ? "injected" : "null"}',
      );
      diag.writeln(
        '- readFileContent: ${readFileContent != null ? "injected" : "null"}',
      );
      diag.writeln();
      diag.writeln('Possible causes:');
      diag.writeln('1. Agent created without going through AgentFactoryImpl');
      diag.writeln(
        '2. _injectSpawnSubAgentCallbacks failed silently (check logs)',
      );
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
    final maxTurns = arguments['max_turns'] as int? ?? 100;
    final contextFiles = (arguments['context_files'] as List?)?.cast<String>();

    // 安全：禁止子 Agent 使用仅限主 Agent 的工具
    const restrictedTools = {
      'spawn_sub_agent', // 禁止递归
      'todo_manage', // 任务管理由主 Agent 负责
      'spec_manage', // 规格管理由主 Agent 负责
      'schedule_task', // 定时任务由主 Agent 负责
    };
    final safeToolNames = requestedToolNames
        .where((name) => !restrictedTools.contains(name))
        .toList();

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
