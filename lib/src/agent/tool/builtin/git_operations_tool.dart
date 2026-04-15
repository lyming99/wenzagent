import 'dart:async';
import 'dart:io';

import '../agent_tool.dart';

/// Git 操作工具
///
/// 支持常用 Git 操作：status、diff、log、commit、add、branch、checkout、stash、show。
/// 写操作（commit、checkout、branch 创建/删除）需要权限确认。
/// 输出自动截断，防止大输出撑爆 LLM context。
class GitOperationsTool extends AgentTool {
  /// 默认超时时间（秒）
  static const int _defaultTimeout = 30;

  /// 耗时操作超时时间（秒）
  static const int _longTimeout = 60;

  /// diff 输出最大字节数
  static const int _maxDiffBytes = 30 * 1024; // 30KB

  /// log 最大行数
  static const int _maxLogLines = 200;

  @override
  String get name => 'git_operations';

  @override
  String get description =>
      'Perform Git operations on a repository. '
      'Supports: status, diff, log, commit, add, branch, checkout, stash, show.\n\n'
      'Read-only operations (status, diff, log, show, stash list) are safe.\n'
      'Write operations (commit, add, checkout, branch create/delete, stash/pop) '
      'require permission confirmation.\n\n'
      'Use this tool when you need to inspect repository state, view changes, '
      'commit code, switch branches, or manage stashes.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': [
              'status',
              'diff',
              'log',
              'commit',
              'add',
              'branch',
              'checkout',
              'stash',
              'show',
            ],
            'description':
                'Git action to perform. '
                '"status" = working tree status, '
                '"diff" = show changes, '
                '"log" = commit history, '
                '"commit" = stage all and commit, '
                '"add" = stage files, '
                '"branch" = list/create/delete branches, '
                '"checkout" = switch branch or restore files, '
                '"stash" = stash/pop/list, '
                '"show" = show commit details.',
          },
          'args': {
            'type': 'string',
            'description':
                'Additional arguments for the action. '
                'For commit: the commit message. '
                'For add: file paths to stage (space-separated). '
                'For branch: branch name (prefix with -d to delete). '
                'For checkout: branch name or file path. '
                'For stash: "pop", "list", or empty to stash. '
                'For show: commit hash or ref.',
          },
          'working_directory': {
            'type': 'string',
            'description':
                'Path to the Git repository. Default: current project working directory.',
          },
        },
        'required': ['action'],
      };

  @override
  bool get requiresPermission => true;

  @override
  String get permissionType => 'git_operations';

  @override
  String? get permissionArgKey => 'action';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final action = arguments['action'] as String?;
    if (action == null || action.isEmpty) {
      return ToolResult.error('action is required');
    }

    final args = arguments['args'] as String? ?? '';
    final workingDirectory = arguments['working_directory'] as String?;

    final timeout = _getTimeout(action);

    try {
      switch (action) {
        case 'status':
          return await _executeGit(
            ['status', '--porcelain'],
            workingDirectory: workingDirectory,
            timeout: timeout,
            label: 'status',
          );
        case 'diff':
          return await _executeDiff(workingDirectory, timeout);
        case 'log':
          return await _executeLog(workingDirectory, timeout);
        case 'commit':
          return await _executeCommit(args, workingDirectory, timeout);
        case 'add':
          return await _executeAdd(args, workingDirectory, timeout);
        case 'branch':
          return await _executeBranch(args, workingDirectory, timeout);
        case 'checkout':
          return await _executeCheckout(args, workingDirectory, timeout);
        case 'stash':
          return await _executeStash(args, workingDirectory, timeout);
        case 'show':
          return await _executeShow(args, workingDirectory, timeout);
        default:
          return ToolResult.error(
            'Unknown action: $action. '
            'Supported: status, diff, log, commit, add, branch, checkout, stash, show.',
          );
      }
    } on TimeoutException {
      return ToolResult.error(
        'Git $action timed out after ${timeout.inSeconds}s',
      );
    } catch (e) {
      return ToolResult.error('Git $action failed: $e');
    }
  }

  /// 获取操作超时时间
  Duration _getTimeout(String action) {
    switch (action) {
      case 'stash':
      case 'log':
        return const Duration(seconds: _longTimeout);
      default:
        return const Duration(seconds: _defaultTimeout);
    }
  }

  /// 执行 git 命令并返回结果
  Future<ToolResult> _executeGit(
    List<String> gitArgs, {
    String? workingDirectory,
    required Duration timeout,
    String? label,
    int? maxOutputBytes,
  }) async {
    final result = await Process.run(
      'git',
      gitArgs,
      workingDirectory: workingDirectory,
      runInShell: true,
    ).timeout(timeout);

    var stdout = result.stdout.toString();
    var stderr = result.stderr.toString();
    final exitCode = result.exitCode;

    // 输出截断
    final maxBytes = maxOutputBytes ?? _maxDiffBytes;
    if (stdout.length > maxBytes) {
      stdout =
          '${stdout.substring(0, maxBytes)}\n\n[Output truncated, total ${stdout.length} characters]';
    }
    if (stderr.length > maxBytes) {
      stderr =
          '${stderr.substring(0, maxBytes)}\n\n[Output truncated, total ${stderr.length} characters]';
    }

    final output = StringBuffer();
    if (stdout.isNotEmpty) {
      output.writeln(stdout.trim());
    }
    if (stderr.isNotEmpty) {
      output.writeln('--- stderr ---');
      output.writeln(stderr.trim());
    }

    if (exitCode != 0 && stderr.isNotEmpty) {
      return ToolResult(
        content: output.toString().trim(),
        isError: true,
      );
    }

    return ToolResult.success(
      output.isEmpty ? 'Git ${label ?? gitArgs.first} completed successfully.' : output.toString().trim(),
    );
  }

  /// 执行 diff（包含 staged 和 unstaged）
  Future<ToolResult> _executeDiff(
    String? workingDirectory, Duration timeout) async {
    final buffer = StringBuffer();

    // unstaged changes
    final unstaged = await _executeGit(
      ['diff'],
      workingDirectory: workingDirectory,
      timeout: timeout,
      label: 'diff (unstaged)',
    );
    if (unstaged.content.isNotEmpty &&
        !unstaged.content.contains('completed successfully')) {
      buffer.writeln('## Unstaged changes');
      buffer.writeln(unstaged.content);
      buffer.writeln();
    }

    // staged changes
    final staged = await _executeGit(
      ['diff', '--cached'],
      workingDirectory: workingDirectory,
      timeout: timeout,
      label: 'diff (staged)',
    );
    if (staged.content.isNotEmpty &&
        !staged.content.contains('completed successfully')) {
      buffer.writeln('## Staged changes');
      buffer.writeln(staged.content);
    }

    if (buffer.isEmpty) {
      return ToolResult.success('No changes detected.');
    }

    return ToolResult.success(buffer.toString().trim());
  }

  /// 执行 log
  Future<ToolResult> _executeLog(
    String? workingDirectory, Duration timeout) async {
    final result = await Process.run(
      'git',
      ['log', '--oneline', '-50'],
      workingDirectory: workingDirectory,
      runInShell: true,
    ).timeout(timeout);

    var stdout = result.stdout.toString();
    final stderr = result.stderr.toString();
    final exitCode = result.exitCode;

    if (exitCode != 0) {
      return ToolResult.error('git log failed: ${stderr.trim()}');
    }

    // 截断行数
    final lines = stdout.trim().split('\n');
    if (lines.length > _maxLogLines) {
      stdout =
          '${lines.take(_maxLogLines).join('\n')}\n\n[Truncated, showing $_maxLogLines of ${lines.length} commits]';
    }

    return ToolResult.success(
      stdout.trim().isEmpty ? 'No commits found.' : stdout.trim(),
    );
  }

  /// 执行 commit（git add -A && git commit）
  Future<ToolResult> _executeCommit(
    String message, String? workingDirectory, Duration timeout) async {
    if (message.isEmpty) {
      return ToolResult.error('Commit message is required (use args parameter)');
    }

    // git add -A
    final addResult = await _executeGit(
      ['add', '-A'],
      workingDirectory: workingDirectory,
      timeout: timeout,
      label: 'add',
    );
    if (addResult.isError) {
      return addResult;
    }

    // git commit -m "message"
    final commitResult = await _executeGit(
      ['commit', '-m', message],
      workingDirectory: workingDirectory,
      timeout: timeout,
      label: 'commit',
    );

    if (commitResult.isError) {
      // Check if it's "nothing to commit" - that's not really an error
      if (commitResult.content.contains('nothing to commit') ||
          commitResult.content.contains('no changes added')) {
        return ToolResult.success(
          'Nothing to commit. Working tree clean.',
        );
      }
      return commitResult;
    }

    return ToolResult.success(
      'Changes committed successfully.\n${commitResult.content}',
    );
  }

  /// 执行 add
  Future<ToolResult> _executeAdd(
    String filePaths, String? workingDirectory, Duration timeout) async {
    if (filePaths.isEmpty) {
      return ToolResult.error('File paths are required for add (use args parameter)');
    }

    final paths = filePaths.split(' ').where((p) => p.isNotEmpty).toList();
    return _executeGit(
      ['add', ...paths],
      workingDirectory: workingDirectory,
      timeout: timeout,
      label: 'add',
    );
  }

  /// 执行 branch（列出/创建/删除）
  Future<ToolResult> _executeBranch(
    String args, String? workingDirectory, Duration timeout) async {
    if (args.isEmpty) {
      // 列出所有分支
      return _executeGit(
        ['branch', '-a'],
        workingDirectory: workingDirectory,
        timeout: timeout,
        label: 'branch list',
      );
    }

    if (args.startsWith('-d ') || args.startsWith('-D ')) {
      // 删除分支
      final branchName = args.substring(args.indexOf(' ') + 1).trim();
      if (branchName.isEmpty) {
        return ToolResult.error('Branch name is required for deletion');
      }
      final flag = args.startsWith('-D ') ? '-D' : '-d';
      return _executeGit(
        ['branch', flag, branchName],
        workingDirectory: workingDirectory,
        timeout: timeout,
        label: 'branch delete',
      );
    }

    // 创建分支
    return _executeGit(
      ['branch', args.trim()],
      workingDirectory: workingDirectory,
      timeout: timeout,
      label: 'branch create',
    );
  }

  /// 执行 checkout
  Future<ToolResult> _executeCheckout(
    String args, String? workingDirectory, Duration timeout) async {
    if (args.isEmpty) {
      return ToolResult.error('Branch name or file path is required for checkout');
    }

    return _executeGit(
      ['checkout', args.trim()],
      workingDirectory: workingDirectory,
      timeout: timeout,
      label: 'checkout',
    );
  }

  /// 执行 stash 操作
  Future<ToolResult> _executeStash(
    String args, String? workingDirectory, Duration timeout) async {
    if (args == 'pop') {
      return _executeGit(
        ['stash', 'pop'],
        workingDirectory: workingDirectory,
        timeout: timeout,
        label: 'stash pop',
      );
    }

    if (args == 'list') {
      return _executeGit(
        ['stash', 'list'],
        workingDirectory: workingDirectory,
        timeout: timeout,
        label: 'stash list',
      );
    }

    // 默认: git stash
    return _executeGit(
      ['stash'],
      workingDirectory: workingDirectory,
      timeout: timeout,
      label: 'stash',
    );
  }

  /// 执行 show
  Future<ToolResult> _executeShow(
    String args, String? workingDirectory, Duration timeout) async {
    if (args.isEmpty) {
      return ToolResult.error('Commit hash or ref is required for show');
    }

    return _executeGit(
      ['show', '--stat', args.trim()],
      workingDirectory: workingDirectory,
      timeout: timeout,
      label: 'show',
    );
  }
}
