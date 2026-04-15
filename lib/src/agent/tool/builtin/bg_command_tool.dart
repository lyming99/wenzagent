import '../../../utils/logger.dart';
import '../agent_tool.dart';
import 'command_session_pool.dart';

/// 后台命令执行工具
///
/// 将长时间运行的命令从"同步等待完成"模式升级为"异步启动 + 轮询查询"模式。
///
/// 支持的 action:
/// - start: 启动后台命令，立即返回 sessionId
/// - status: 查询指定会话的运行状态
/// - output: 查询指定会话的 stdout/stderr 输出
/// - terminate: 终止指定会话
/// - list: 列出所有会话
///
/// 工作流:
/// 1. bg_command(action="start", command="flutter build apk") → 返回 sessionId
/// 2. bg_command(action="status", sessionId="bg_1_xxx") → running, 45s
/// 3. bg_command(action="output", sessionId="bg_1_xxx") → 最近输出
/// 4. 状态变为 completed/failed 后分析 output 并回复用户
class BgCommandTool extends AgentTool {
  static final _log = Logger('BgCommandTool');

  /// 输出查询默认截取的尾部字符数
  static const int _defaultTailChars = 3000;

  /// 由 AgentImpl 注入的命令会话池
  CommandSessionPool? pool;

  @override
  String get name => 'bg_command';

  @override
  String get description =>
      'Execute and manage LONG-RUNNING background commands (compilation, build, '
      'test suites, dev servers, data processing) using an async start + polling model.\n\n'
      'Workflow:\n'
      '1. Call bg_command(action="start", command="...") to launch a command → returns sessionId\n'
      '2. Periodically call bg_command(action="status", sessionId="...") to check progress\n'
      '3. Call bg_command(action="output", sessionId="...") to view recent output\n'
      '4. When status is completed/failed, analyze the output and respond to the user\n'
      '5. Optionally call bg_command(action="terminate", sessionId="...") to kill a running command\n\n'
      'When to use bg_command vs command_execute:\n'
      '- bg_command: compilation, build, test, deploy, dev server, data processing (expected >30s)\n'
      '- command_execute: quick commands like ls, cat, grep, git status (<30s)\n\n'
      'Output uses a tail-retention buffer: if output exceeds 500KB, only the tail is kept. '
      'This ensures error messages (which typically appear at the end) are preserved.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': ['start', 'status', 'output', 'terminate', 'list'],
            'description':
                'Action to perform:\n'
                '- "start": Launch a background command (returns sessionId)\n'
                '- "status": Check command status (running/completed/failed/cancelled)\n'
                '- "output": View stdout/stderr output (supports tailChars)\n'
                '- "terminate": Kill a running command\n'
                '- "list": List all sessions',
          },
          'command': {
            'type': 'string',
            'description':
                'The shell command to execute (required for action="start").',
          },
          'sessionId': {
            'type': 'string',
            'description':
                'Session ID (required for action="status", "output", "terminate").',
          },
          'workingDirectory': {
            'type': 'string',
            'description':
                'Working directory for the command (only for action="start"). '
                'Default: current directory.',
          },
          'tailChars': {
            'type': 'integer',
            'description':
                'Number of tail characters to return for stdout/stderr '
                '(only for action="output"). Default: 3000. '
                'Use a larger value if you need more context.',
          },
        },
        'required': ['action'],
      };

  @override
  bool get requiresPermission => true;

  @override
  String get permissionType => 'command_execute';

  @override
  String get permissionArgKey => 'command';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final action = arguments['action'] as String?;
    if (action == null || action.isEmpty) {
      return ToolResult.error(
        'action is required. Use "start", "status", "output", "terminate", or "list".',
      );
    }

    if (pool == null) {
      return ToolResult.error(
        'Background command service is not available (pool not injected).',
      );
    }

    switch (action) {
      case 'start':
        return await _start(arguments);
      case 'status':
        return _status(arguments);
      case 'output':
        return _output(arguments);
      case 'terminate':
        return _terminate(arguments);
      case 'list':
        return _list();
      default:
        return ToolResult.error(
          'Unknown action: "$action". Use "start", "status", "output", "terminate", or "list".',
        );
    }
  }

  Future<ToolResult> _start(Map<String, dynamic> arguments) async {
    final command = arguments['command'] as String?;
    if (command == null || command.isEmpty) {
      return ToolResult.error('command is required for action="start".');
    }

    final workingDirectory = arguments['workingDirectory'] as String?;

    final session = await pool!.startSession(
      command: command,
      workingDirectory: workingDirectory,
    );

    if (session == null) {
      final running = pool!.activeCount;
      return ToolResult.error(
        'Cannot start: concurrent session limit reached '
        '($running/${pool!.maxSessions}). '
        'Terminate an existing session first using action="terminate" or action="list" to see running sessions.',
      );
    }

    // 检查启动是否立即失败
    if (session.status == CommandSessionStatus.error) {
      return ToolResult.error(
        'Failed to start command: $command\n'
        'Session ID: ${session.sessionId}\n'
        'The process could not be launched. Check the command syntax.',
      );
    }

    _log.info('Started session ${session.sessionId}: $command');

    return ToolResult.success(
      'Background command started.\n'
      'Session ID: ${session.sessionId}\n'
      'PID: ${session.pid}\n'
      'Command: $command\n'
      'Status: running\n\n'
      'Use bg_command(action="status", sessionId="${session.sessionId}") to check progress.\n'
      'Use bg_command(action="output", sessionId="${session.sessionId}") to view output.',
    );
  }

  ToolResult _status(Map<String, dynamic> arguments) {
    final sessionId = arguments['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      return ToolResult.error('sessionId is required for action="status".');
    }

    final session = pool!.getSession(sessionId);
    if (session == null) {
      return ToolResult.error('Session not found: $sessionId');
    }

    final summary = session.getSummary();
    final status = summary['status'] as String;
    final elapsed = summary['elapsedSeconds'] as int;
    final exitCode = summary['exitCode'];

    final buffer = StringBuffer();
    buffer.writeln('Session: $sessionId');
    buffer.writeln('Status: $status');
    buffer.writeln('Elapsed: ${elapsed}s');
    buffer.writeln('Command: ${summary['command']}');

    if (exitCode != null) {
      buffer.writeln('Exit code: $exitCode');
    }

    buffer.writeln();
    buffer.writeln('stdout: ${summary['stdoutTotalChars']} chars'
        '${summary['stdoutTruncated'] == true ? ' (truncated)' : ''}');
    buffer.writeln('stderr: ${summary['stderrTotalChars']} chars'
        '${summary['stderrTruncated'] == true ? ' (truncated)' : ''}');

    return ToolResult.success(buffer.toString().trim());
  }

  ToolResult _output(Map<String, dynamic> arguments) {
    final sessionId = arguments['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      return ToolResult.error('sessionId is required for action="output".');
    }

    final session = pool!.getSession(sessionId);
    if (session == null) {
      return ToolResult.error('Session not found: $sessionId');
    }

    final tailChars =
        arguments['tailChars'] as int? ?? _defaultTailChars;

    final stdout = session.getStdout(tailChars: tailChars);
    final stderr = session.getStderr(tailChars: tailChars);

    final buffer = StringBuffer();
    buffer.writeln('Session: $sessionId');
    buffer.writeln('Status: ${session.status.name}');
    buffer.writeln();

    if (stdout.isNotEmpty) {
      buffer.writeln('--- stdout ---');
      buffer.writeln(stdout);
      if (session.getSummary()['stdoutTruncated'] == true) {
        buffer.writeln(
          '\n[stdout buffer truncated, showing last $tailChars chars of ${session.getSummary()['stdoutTotalChars']} total]',
        );
      }
    }

    if (stderr.isNotEmpty) {
      buffer.writeln('--- stderr ---');
      buffer.writeln(stderr);
      if (session.getSummary()['stderrTruncated'] == true) {
        buffer.writeln(
          '\n[stderr buffer truncated, showing last $tailChars chars of ${session.getSummary()['stderrTotalChars']} total]',
        );
      }
    }

    if (stdout.isEmpty && stderr.isEmpty) {
      buffer.writeln('(no output yet)');
    }

    return ToolResult.success(buffer.toString().trim());
  }

  ToolResult _terminate(Map<String, dynamic> arguments) {
    final sessionId = arguments['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      return ToolResult.error('sessionId is required for action="terminate".');
    }

    final session = pool!.getSession(sessionId);
    if (session == null) {
      return ToolResult.error('Session not found: $sessionId');
    }

    if (!session.isRunning) {
      return ToolResult.success(
        'Session $sessionId is not running (status: ${session.status.name}). '
        'No action needed.',
      );
    }

    final success = pool!.terminateSession(sessionId);
    if (success) {
      return ToolResult.success(
        'Session $sessionId terminated successfully.',
      );
    } else {
      return ToolResult.error('Failed to terminate session $sessionId.');
    }
  }

  ToolResult _list() {
    final sessions = pool!.listSessions();
    if (sessions.isEmpty) {
      return ToolResult.success('No background command sessions.');
    }

    final buffer = StringBuffer();
    buffer.writeln('Background command sessions (${sessions.length}):');
    buffer.writeln();

    for (final s in sessions) {
      final status = s['status'] as String;
      final elapsed = s['elapsedSeconds'] as int;
      final exitCode = s['exitCode'];

      buffer.writeln(
        '  [${s['sessionId']}] ${s['command']}\n'
        '    Status: $status | Elapsed: ${elapsed}s'
        '${exitCode != null ? ' | Exit: $exitCode' : ''}',
      );
    }

    return ToolResult.success(buffer.toString().trim());
  }
}
