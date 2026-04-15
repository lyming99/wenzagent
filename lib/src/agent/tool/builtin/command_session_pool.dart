import 'dart:async';
import 'dart:io';

import '../../../utils/logger.dart';

/// 后台命令会话状态
enum CommandSessionStatus {
  /// 正在运行
  running,

  /// 正常完成（exitCode == 0）
  completed,

  /// 执行失败（exitCode != 0）
  failed,

  /// 被手动终止
  cancelled,

  /// 进程启动失败
  error,
}

/// 单个后台命令会话
///
/// 管理一个后台进程的完整生命周期：
/// - 启动进程并流式收集 stdout/stderr
/// - 环形缓冲区保留尾部输出（编译错误通常在末尾）
/// - 查询状态和输出
/// - 终止进程树
class CommandSession {
  static final _log = Logger('CommandSession');

  /// 会话 ID，格式: bg_{序号}_{时间戳}
  final String sessionId;

  /// 执行的命令
  final String command;

  /// 工作目录
  final String? workingDirectory;

  /// 创建时间
  final DateTime createdAt;

  /// 当前状态
  CommandSessionStatus _status = CommandSessionStatus.running;

  /// 进程退出码（进程结束后有值）
  int? _exitCode;

  /// 进程 PID
  int? _pid;

  /// 状态变更 Completer（用于 waitUntilDone）
  Completer<void>? _doneCompleter;

  // ===== 环形缓冲区 =====

  /// 最大缓冲区大小（字符数）
  final int maxBufferChars;

  /// stdout 缓冲区
  StringBuffer _stdoutBuffer = StringBuffer();

  /// stderr 缓冲区
  StringBuffer _stderrBuffer = StringBuffer();

  /// stdout 总字符数（含被截断的）
  int _stdoutTotalChars = 0;

  /// stderr 总字符数（含被截断的）
  int _stderrTotalChars = 0;

  /// stdout 是否被截断过
  bool _stdoutTruncated = false;

  /// stderr 是否被截断过
  bool _stderrTruncated = false;

  // ===== 进程资源 =====

  Process? _process;
  StreamSubscription<List<int>>? _stdoutSubscription;
  StreamSubscription<List<int>>? _stderrSubscription;

  CommandSession({
    required this.sessionId,
    required this.command,
    this.workingDirectory,
    required this.createdAt,
    this.maxBufferChars = 500 * 1024, // 500KB
  });

  /// 当前状态
  CommandSessionStatus get status => _status;

  /// 退出码
  int? get exitCode => _exitCode;

  /// 进程 PID
  int? get pid => _pid;

  /// 进程是否还在运行
  bool get isRunning => _status == CommandSessionStatus.running;

  /// 运行时长
  Duration get elapsed => DateTime.now().difference(createdAt);

  /// 启动进程并开始流式收集输出
  ///
  /// 启动后立即返回，进程在后台运行。
  Future<void> start() async {
    _doneCompleter = Completer<void>();

    try {
      if (Platform.isWindows) {
        _process = await Process.start(
          'cmd',
          ['/c', command],
          workingDirectory: workingDirectory,
          runInShell: false,
        );
      } else {
        _process = await Process.start(
          'sh',
          ['-c', command],
          workingDirectory: workingDirectory,
          runInShell: false,
        );
      }

      _pid = _process!.pid;
      _status = CommandSessionStatus.running;
      _log.info('Session $sessionId started: pid=$_pid, cmd=$command');

      // 流式收集 stdout
      _stdoutSubscription = _process!.stdout.listen(
        (chunk) {
          final text = systemEncoding.decode(chunk);
          _appendToBuffer(_stdoutBuffer, text, isStdout: true);
        },
        onDone: () {},
        onError: (e) {
          _log.warn('Session $sessionId stdout error: $e');
        },
        cancelOnError: false,
      );

      // 流式收集 stderr
      _stderrSubscription = _process!.stderr.listen(
        (chunk) {
          final text = systemEncoding.decode(chunk);
          _appendToBuffer(_stderrBuffer, text, isStdout: false);
        },
        onDone: () {},
        onError: (e) {
          _log.warn('Session $sessionId stderr error: $e');
        },
        cancelOnError: false,
      );

      // 监听进程退出
      _process!.exitCode.then((code) {
        _exitCode = code;
        if (_status == CommandSessionStatus.running) {
          _status =
              code == 0 ? CommandSessionStatus.completed : CommandSessionStatus.failed;
        }
        _log.info(
          'Session $sessionId ended: exitCode=$code, status=$_status',
        );
        if (_doneCompleter != null && !_doneCompleter!.isCompleted) {
          _doneCompleter!.complete();
        }
      }).catchError((e) {
        _status = CommandSessionStatus.error;
        _exitCode = -1;
        _log.error('Session $sessionId exitCode error: $e');
        if (_doneCompleter != null && !_doneCompleter!.isCompleted) {
          _doneCompleter!.complete();
        }
      });
    } catch (e) {
      _status = CommandSessionStatus.error;
      _exitCode = -1;
      _log.error('Session $sessionId failed to start: $e');
      if (_doneCompleter != null && !_doneCompleter!.isCompleted) {
        _doneCompleter!.complete();
      }
    }
  }

  /// 追加输出到缓冲区（尾部保留策略）
  void _appendToBuffer(StringBuffer buffer, String text, {required bool isStdout}) {
    final totalChars = isStdout ? _stdoutTotalChars : _stderrTotalChars;
    final newTotal = totalChars + text.length;

    if (isStdout) {
      _stdoutTotalChars = newTotal;
    } else {
      _stderrTotalChars = newTotal;
    }

    buffer.write(text);

    // 如果超出上限，截断保留尾部
    if (buffer.length > maxBufferChars) {
      final excess = buffer.length - maxBufferChars;
      final current = buffer.toString();
      buffer.clear();
      buffer.write(current.substring(excess));

      if (isStdout) {
        _stdoutTruncated = true;
      } else {
        _stderrTruncated = true;
      }
    }
  }

  /// 获取 stdout 输出
  ///
  /// [tailChars] 指定只返回最后 N 个字符。默认返回全部缓冲区内容。
  String getStdout({int? tailChars}) {
    final content = _stdoutBuffer.toString();
    if (tailChars != null && tailChars > 0 && content.length > tailChars) {
      return content.substring(content.length - tailChars);
    }
    return content;
  }

  /// 获取 stderr 输出
  String getStderr({int? tailChars}) {
    final content = _stderrBuffer.toString();
    if (tailChars != null && tailChars > 0 && content.length > tailChars) {
      return content.substring(content.length - tailChars);
    }
    return content;
  }

  /// 获取会话摘要
  Map<String, dynamic> getSummary() {
    return {
      'sessionId': sessionId,
      'command': command,
      'workingDirectory': workingDirectory,
      'status': _status.name,
      'exitCode': _exitCode,
      'pid': _pid,
      'createdAt': createdAt.toIso8601String(),
      'elapsedSeconds': elapsed.inSeconds,
      'stdoutTotalChars': _stdoutTotalChars,
      'stderrTotalChars': _stderrTotalChars,
      'stdoutTruncated': _stdoutTruncated,
      'stderrTruncated': _stderrTruncated,
    };
  }

  /// 等待进程结束
  ///
  /// [timeout] 可选超时时间。超时后返回但不会杀死进程。
  /// 返回 true 表示进程已结束，false 表示超时。
  Future<bool> waitUntilDone({Duration? timeout}) async {
    if (_doneCompleter == null) return true;
    if (_doneCompleter!.isCompleted) return true;

    if (timeout != null) {
      try {
        await _doneCompleter!.future.timeout(timeout, onTimeout: () {});
        return true;
      } on TimeoutException {
        return false;
      }
    } else {
      await _doneCompleter!.future;
      return true;
    }
  }

  /// 终止进程（包括进程树）
  void kill() {
    if (_process == null) return;
    if (_status != CommandSessionStatus.running) return;

    _status = CommandSessionStatus.cancelled;

    try {
      if (Platform.isWindows) {
        _killProcessTreeWindows(_process!.pid);
      } else {
        _killProcessGroupUnix(_process!.pid);
      }
    } catch (e) {
      _log.warn('Session $sessionId kill failed: $e');
      try {
        _process?.kill();
      } catch (_) {}
    }

    _cleanupSubscriptions();

    if (_doneCompleter != null && !_doneCompleter!.isCompleted) {
      _doneCompleter!.complete();
    }

    _log.info('Session $sessionId killed');
  }

  /// 释放资源
  void dispose() {
    kill();
    _cleanupSubscriptions();
    _stdoutBuffer.clear();
    _stderrBuffer.clear();
  }

  void _cleanupSubscriptions() {
    try {
      _stdoutSubscription?.cancel();
    } catch (_) {}
    _stdoutSubscription = null;

    try {
      _stderrSubscription?.cancel();
    } catch (_) {}
    _stderrSubscription = null;

    try {
      _process?.stdin.close();
    } catch (_) {}
  }

  void _killProcessTreeWindows(int pid) {
    try {
      Process.runSync('taskkill', ['/T', '/F', '/PID', '$pid'],
          runInShell: true);
    } catch (e) {
      _log.warn('taskkill failed for pid=$pid: $e');
    }
  }

  void _killProcessGroupUnix(int pid) {
    try {
      Process.killPid(-pid, ProcessSignal.sigkill);
    } catch (e) {
      _log.warn('kill process group failed for pgid=$pid: $e');
      try {
        _process?.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }
}

/// 后台命令会话池
///
/// 管理多个 [CommandSession]，提供：
/// - 启动/终止/列出会话
/// - 并发数量限制
/// - 统一清理
class CommandSessionPool {
  static final _log = Logger('CommandSessionPool');

  /// 活跃会话
  final Map<String, CommandSession> _sessions = {};

  /// 最大并发会话数
  final int maxSessions;

  /// 会话序号计数器
  int _sessionCounter = 0;

  /// 单个会话最大缓冲区大小（字符）
  final int sessionMaxBufferChars;

  CommandSessionPool({
    this.maxSessions = 5,
    this.sessionMaxBufferChars = 500 * 1024,
  });

  /// 当前活跃会话数
  int get activeCount =>
      _sessions.values.where((s) => s.isRunning).length;

  /// 总会话数（含已完成的）
  int get totalCount => _sessions.length;

  /// 启动一个后台命令会话
  ///
  /// 返回 [CommandSession]，或 null 表示达到并发上限。
  Future<CommandSession?> startSession({
    required String command,
    String? workingDirectory,
  }) async {
    // 并发限制：仅计算正在运行的会话
    final runningCount = activeCount;
    if (runningCount >= maxSessions) {
      _log.warn(
        'Cannot start session: $runningCount/$maxSessions concurrent sessions running',
      );
      return null;
    }

    _sessionCounter++;
    final sessionId =
        'bg_${_sessionCounter}_${DateTime.now().millisecondsSinceEpoch}';

    final session = CommandSession(
      sessionId: sessionId,
      command: command,
      workingDirectory: workingDirectory,
      createdAt: DateTime.now(),
      maxBufferChars: sessionMaxBufferChars,
    );

    _sessions[sessionId] = session;
    await session.start();

    return session;
  }

  /// 获取指定会话
  CommandSession? getSession(String sessionId) {
    return _sessions[sessionId];
  }

  /// 终止指定会话
  ///
  /// 返回 true 表示成功终止，false 表示会话不存在。
  bool terminateSession(String sessionId) {
    final session = _sessions[sessionId];
    if (session == null) return false;

    session.kill();
    return true;
  }

  /// 终止所有运行中的会话
  void terminateAll() {
    for (final session in _sessions.values) {
      if (session.isRunning) {
        session.kill();
      }
    }
    _log.info('All sessions terminated');
  }

  /// 列出所有会话的摘要
  List<Map<String, dynamic>> listSessions() {
    return _sessions.values.map((s) => s.getSummary()).toList();
  }

  /// 释放所有资源（终止所有进程并清空会话）
  void dispose() {
    terminateAll();
    _sessions.clear();
    _log.info('Pool disposed');
  }
}
