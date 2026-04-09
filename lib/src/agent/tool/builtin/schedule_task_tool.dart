import '../agent_tool.dart';

/// 定时任务工具
///
/// 让 Agent 可以自主创建、查询、取消定时任务。
/// 用户说"每天9点汇报工作"时，LLM 自动调用此工具设置定时。
///
/// 执行流程：
/// 1. LLM 分析用户意图 → 调用 schedule_task(action="create", ...)
/// 2. 权限审批（requiresPermission = true）
/// 3. 通过 onCreateTask 回调注册到 ScheduledTaskManager
/// 4. 到达触发时间 → TaskExecutor 执行 → 结果送达用户
class ScheduleTaskTool extends AgentTool {
  /// 创建任务回调（由 ScheduledTaskManager 注入）
  ///
  /// 参数: {name, message, schedule}
  /// 返回: {taskId, name, schedule, nextExecutionAt}
  Future<Map<String, dynamic>> Function(Map<String, dynamic> task)?
      onCreateTask;

  /// 取消任务回调
  Future<bool> Function(String taskId)? onCancelTask;

  /// 查询任务回调
  Future<List<Map<String, dynamic>>> Function(
      {String? employeeId})? onListTasks;

  @override
  String get name => 'schedule_task';

  @override
  String get description =>
      'Create, query, or cancel scheduled recurring tasks. '
      'IMPORTANT: This tool ONLY registers/manages schedules — it does NOT '
      'execute the task content immediately. The task will be executed automatically '
      'when the scheduled time arrives.\n\n'
      'Use this tool when the user asks you to do something on a schedule, '
      'e.g. "remind me every day at 9am", "report work status every Friday", '
      '"check logs every 4 hours".\n\n'
      'Task types (taskType parameter):\n'
      '- "reminder" (default): A simple notification. The message you write will be '
      'directly delivered to the user as an assistant message when triggered. '
      'No tools will be executed. Write the reminder content as the message — it '
      'will be shown to the user as-is. Good for: reminders, notifications, alarms.\n'
      '- "task": An autonomous execution task. When triggered, a system message '
      'containing your instructions will be injected into the main agent via a queue, '
      'and the agent will use its tools to execute the task. Write detailed, '
      'self-contained instructions including what tools to use and what to produce. '
      'Good for: log checking, data collection, file operations, API calls.\n\n'
      'The "message" parameter is the content that will be used when the schedule '
      'triggers. Do NOT try to execute the message content now — just pass it as-is '
      'to this tool.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': ['create', 'list', 'cancel', 'delete'],
            'description':
                'Action to perform: create a new task, list existing tasks, '
                'cancel/delete a task (both remove the task permanently). '
                'Use "delete" when the user wants to remove/stop a scheduled task.',
          },
          'message': {
            'type': 'string',
            'description':
                'The task instruction to be executed when the schedule triggers. '
                'This is NOT executed now — it will be sent to you as a message '
                'at the future scheduled time. Write it as a clear, self-contained '
                'instruction that your future self can understand and act on, '
                'including which tools to use and what output to produce.',
          },
          'schedule': {
            'type': 'string',
            'description':
                'Schedule expression.\n'
                '- Cron: "0 9 * * 1-5" (weekdays 9am), "*/30 * * * *" (every 30 min)\n'
                '- ISO 8601 duration: "PT1H" (every hour), "P1D" (every day), "PT30M" (every 30 min)',
          },
          'name': {
            'type': 'string',
            'description':
                'A short name for the task, e.g. "Daily work report".',
          },
          'taskId': {
            'type': 'string',
            'description': 'Task ID (required for action=cancel or action=delete).',
          },
          'repeatType': {
            'type': 'string',
            'enum': ['once', 'recurring'],
            'description':
                'Execution strategy (only for action=create). '
                'IMPORTANT: You MUST always explicitly set this field based on user intent. '
                '"once" = execute only once then auto-disable. '
                '"recurring" = repeat on schedule indefinitely. '
                'If the user says "every X", "periodically", "daily", "weekly", '
                'or any recurring pattern, use "recurring". '
                'If the user wants a one-time reminder or action, use "once".',
          },
          'taskType': {
            'type': 'string',
            'enum': ['reminder', 'task'],
            'description':
                'Task type (only for action=create). '
                '"reminder" = reminder notification. The message you write is the '
                'final reminder content — it will be directly delivered to the user '
                'as an assistant message when triggered. No LLM API call, no tool execution. '
                '"task" = autonomous execution task. When triggered, your instructions '
                '(the message) will be injected into the main agent via a queue as a '
                'system message. The agent will then use its available tools to execute '
                'the task. Write detailed instructions for your future self. '
                'Default: "reminder". Use "task" ONLY when the scheduled action '
                'requires tool usage (e.g. file operations, API calls, code execution).',
          },
        },
        'required': ['action'],
      };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final action = arguments['action'] as String?;
    print('[ScheduleTaskTool] execute called, arguments: $arguments');
    print('[ScheduleTaskTool] action=$action, '
        'onCreateTask=${onCreateTask != null}, '
        'onCancelTask=${onCancelTask != null}, '
        'onListTasks=${onListTasks != null}');

    if (action == null || action.isEmpty) {
      return ToolResult.error('action is required. Use "create", "list", "cancel", or "delete".');
    }

    switch (action) {
      case 'create':
        return await _create(arguments);
      case 'list':
        return await _list();
      case 'cancel':
      case 'delete':
        return await _cancel(arguments);
      default:
        return ToolResult.error(
            'Unknown action: $action. Use "create", "list", "cancel", or "delete".');
    }
  }

  Future<ToolResult> _create(Map<String, dynamic> arguments) async {
    final message = arguments['message'] as String?;
    final schedule = arguments['schedule'] as String?;
    final name = arguments['name'] as String?;
    final taskType = arguments['taskType'] as String? ?? 'reminder';

    print('[ScheduleTaskTool] _create: name=$name, '
        'message=${message != null ? "${message.length > 50 ? "${message.substring(0, 50)}..." : message}" : null}, '
        'schedule=$schedule, taskType=$taskType');

    if (message == null || message.isEmpty) {
      print('[ScheduleTaskTool] _create failed: message is empty');
      return ToolResult.error('message is required');
    }
    if (schedule == null || schedule.isEmpty) {
      print('[ScheduleTaskTool] _create failed: schedule is empty');
      return ToolResult.error('schedule is required');
    }
    if (onCreateTask == null) {
      print('[ScheduleTaskTool] _create failed: onCreateTask callback is NOT injected! '
          'ScheduledTaskManager may not be wired up.');
      return ToolResult.error(
          'Scheduled task service is not available (onCreateTask is null)');
    }

    try {
      final result = await onCreateTask!({
        'name': name ?? 'Scheduled task',
        'message': message,
        'schedule': schedule,
        'taskType': taskType,
      });
      print('[ScheduleTaskTool] _create success: result=$result');
      return ToolResult.success(
        '✅ Scheduled task created successfully.\n'
        'Task ID: ${result['taskId']}\n'
        'Name: ${result['name']}\n'
        'Type: $taskType\n'
        'Schedule: ${result['schedule']}\n'
        'Next execution: ${result['nextExecutionAt']}\n\n'
        'The task is now registered. It will be executed automatically at the '
        'scheduled time — no further action needed now.',
        metadata: result,
      );
    } catch (e, st) {
      print('[ScheduleTaskTool] _create exception: $e\n$st');
      return ToolResult.error('Failed to create task: $e');
    }
  }

  Future<ToolResult> _list() async {
    if (onListTasks == null) {
      return ToolResult.error('Scheduled task service is not available');
    }
    try {
      final tasks = await onListTasks!();
      if (tasks.isEmpty) {
        return ToolResult.success('No scheduled tasks found.');
      }
      final buffer = StringBuffer('📋 Scheduled tasks:\n');
      for (final t in tasks) {
        buffer.writeln(
            '  • [${t['taskId']}] ${t['name']} | '
            '${t['schedule']} | next: ${t['nextExecutionAt'] ?? 'N/A'} | '
            'enabled: ${t['enabled']}');
      }
      return ToolResult.success(buffer.toString());
    } catch (e) {
      return ToolResult.error('Failed to list tasks: $e');
    }
  }

  Future<ToolResult> _cancel(Map<String, dynamic> arguments) async {
    final taskId = arguments['taskId'] as String?;
    if (taskId == null || taskId.isEmpty) {
      return ToolResult.error('taskId is required for cancel action');
    }
    if (onCancelTask == null) {
      return ToolResult.error('Scheduled task service is not available');
    }
    try {
      final success = await onCancelTask!(taskId);
      if (success) {
        return ToolResult.success('Task $taskId has been deleted.');
      } else {
        return ToolResult.error('Task $taskId not found.');
      }
    } catch (e) {
      return ToolResult.error('Failed to delete task: $e');
    }
  }
}
