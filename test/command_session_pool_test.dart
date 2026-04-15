import 'dart:io';

import 'package:test/test.dart';
import 'package:wenzagent/src/agent/tool/builtin/bg_command_tool.dart';
import 'package:wenzagent/src/agent/tool/builtin/command_session_pool.dart';

/// Windows-specific helpers
final _isWindows = Platform.isWindows;

/// Long-running command for testing
String get _longCmd =>
    _isWindows ? 'ping -n 30 127.0.0.1' : 'sleep 30';

/// Short-running command for testing
String get _shortSleepCmd =>
    _isWindows ? 'ping -n 2 127.0.0.1 >nul' : 'sleep 1';

void main() {
  group('CommandSession', () {
    test('starts and completes a short command', () async {
      final pool = CommandSessionPool();
      addTearDown(() => pool.dispose());

      final session = await pool.startSession(command: 'echo hello');
      expect(session, isNotNull);
      expect(session!.isRunning, isTrue);
      expect(session.pid, isNotNull);

      final done =
          await session.waitUntilDone(timeout: Duration(seconds: 10));
      expect(done, isTrue);
      expect(session.status, CommandSessionStatus.completed);
      expect(session.exitCode, 0);

      final stdout = session.getStdout();
      expect(stdout, contains('hello'));
    });

    test('captures stderr output', () async {
      final pool = CommandSessionPool();
      addTearDown(() => pool.dispose());

      final cmd = _isWindows ? 'echo error 1>&2' : 'echo error >&2';
      final session = await pool.startSession(command: cmd);
      expect(session, isNotNull);

      final done =
          await session!.waitUntilDone(timeout: Duration(seconds: 10));
      expect(done, isTrue);

      final stderr = session.getStderr();
      expect(stderr, contains('error'));
    });

    test('reports failed status for non-zero exit code', () async {
      final pool = CommandSessionPool();
      addTearDown(() => pool.dispose());

      final cmd = _isWindows ? 'exit /b 1' : 'exit 1';
      final session = await pool.startSession(command: cmd);
      expect(session, isNotNull);

      final done =
          await session!.waitUntilDone(timeout: Duration(seconds: 10));
      expect(done, isTrue);
      expect(session!.status, CommandSessionStatus.failed);
      expect(session.exitCode, 1);
    });

    test('reports failed status for invalid command', () async {
      final pool = CommandSessionPool();
      addTearDown(() => pool.dispose());

      final session = await pool.startSession(
        command: '__nonexistent_command_xyz_123__',
      );
      expect(session, isNotNull);

      final done =
          await session!.waitUntilDone(timeout: Duration(seconds: 10));
      expect(done, isTrue);
      // On Windows cmd /c will exit with non-zero for unknown commands
      // On Unix sh -c will exit with non-zero
      expect(session!.status, isNot(CommandSessionStatus.running));
      expect(session.exitCode, isNot(0));
    });

    test('getStdout with tailChars', () async {
      final pool = CommandSessionPool();
      addTearDown(() => pool.dispose());

      // Use a loop to generate output (works on both platforms)
      final cmd = _isWindows
          ? r'for /L %i in (1,1,500) do @echo AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          : 'for i in `seq 1 500`; do echo AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; done';

      final session = await pool.startSession(command: cmd);
      expect(session, isNotNull);

      final done =
          await session!.waitUntilDone(timeout: Duration(seconds: 15));
      expect(done, isTrue);

      final fullOutput = session!.getStdout();
      // Should have substantial output
      expect(fullOutput.length, greaterThan(1000));

      final tailOutput = session.getStdout(tailChars: 100);
      expect(tailOutput.length, lessThanOrEqualTo(200));
      expect(tailOutput.length, lessThan(fullOutput.length));
    });

    test('kill terminates a running process', () async {
      final pool = CommandSessionPool();
      addTearDown(() => pool.dispose());

      final session = await pool.startSession(command: _longCmd);
      expect(session, isNotNull);
      expect(session!.isRunning, isTrue);

      // Give it a moment to start
      await Future.delayed(Duration(milliseconds: 500));

      session.kill();
      expect(session.status, CommandSessionStatus.cancelled);

      // Kill is idempotent
      session.kill();
      expect(session.status, CommandSessionStatus.cancelled);
    });

    test('getSummary returns structured data', () async {
      final pool = CommandSessionPool();
      addTearDown(() => pool.dispose());

      final session = await pool.startSession(command: 'echo test');
      expect(session, isNotNull);

      final done =
          await session!.waitUntilDone(timeout: Duration(seconds: 10));
      expect(done, isTrue);

      final summary = session!.getSummary();
      expect(summary['sessionId'], isNotNull);
      expect(summary['command'], 'echo test');
      expect(summary['status'], isNotNull);
      expect(summary['exitCode'], isNotNull);
      expect(summary['pid'], isNotNull);
      expect(summary['createdAt'], isNotNull);
      expect(summary['elapsedSeconds'], isNotNull);
    });

    test('output buffer truncation (tail retention)', () async {
      // Use a small buffer to force truncation
      final pool = CommandSessionPool(sessionMaxBufferChars: 200);
      addTearDown(() => pool.dispose());

      // Generate output larger than buffer
      final cmd = _isWindows
          ? r'for /L %i in (1,1,100) do @echo Line_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          : 'for i in `seq 1 100`; do echo Line_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; done';

      final session = await pool.startSession(command: cmd);
      expect(session, isNotNull);

      final done =
          await session!.waitUntilDone(timeout: Duration(seconds: 15));
      expect(done, isTrue);

      final output = session!.getStdout();
      // Buffer should be limited
      expect(output.length, lessThanOrEqualTo(400));

      final summary = session.getSummary();
      expect(summary['stdoutTruncated'], isTrue);
      expect(summary['stdoutTotalChars'], greaterThan(200));
    });

    test('waitUntilDone returns true immediately for completed session',
        () async {
      final pool = CommandSessionPool();
      addTearDown(() => pool.dispose());

      final session = await pool.startSession(command: 'echo test');
      expect(session, isNotNull);

      final done =
          await session!.waitUntilDone(timeout: Duration(seconds: 10));
      expect(done, isTrue);

      // Calling again should return immediately
      final done2 = await session.waitUntilDone();
      expect(done2, isTrue);
    });
  });

  group('CommandSessionPool', () {
    test('enforces concurrent session limit', () async {
      final pool = CommandSessionPool(maxSessions: 2);
      addTearDown(() => pool.dispose());

      // Start 2 sessions (max)
      final s1 = await pool.startSession(command: _longCmd);
      final s2 = await pool.startSession(command: _longCmd);
      expect(s1, isNotNull);
      expect(s2, isNotNull);

      // 3rd should fail
      final s3 = await pool.startSession(command: _longCmd);
      expect(s3, isNull);

      pool.terminateAll();
    });

    test('completed sessions free up concurrency slots', () async {
      final pool = CommandSessionPool(maxSessions: 1);
      addTearDown(() => pool.dispose());

      // Start and complete a session
      final s1 = await pool.startSession(command: 'echo test');
      expect(s1, isNotNull);
      await s1!.waitUntilDone(timeout: Duration(seconds: 10));
      expect(s1.isRunning, isFalse);

      // Should be able to start a new session
      final s2 = await pool.startSession(command: 'echo test2');
      expect(s2, isNotNull);
      await s2!.waitUntilDone(timeout: Duration(seconds: 10));
    });

    test('listSessions returns all sessions', () async {
      final pool = CommandSessionPool();
      addTearDown(() => pool.dispose());

      await pool.startSession(command: 'echo one');
      await pool.startSession(command: 'echo two');

      // Wait for completion to avoid teardown issues
      await Future.delayed(Duration(seconds: 2));

      final list = pool.listSessions();
      expect(list.length, 2);
    });

    test('terminateSession works', () async {
      final pool = CommandSessionPool();
      addTearDown(() => pool.dispose());

      final session = await pool.startSession(command: _longCmd);
      expect(session, isNotNull);

      await Future.delayed(Duration(milliseconds: 300));

      final result = pool.terminateSession(session!.sessionId);
      expect(result, isTrue);
      expect(session.status, CommandSessionStatus.cancelled);
    });

    test('terminateSession returns false for unknown session', () async {
      final pool = CommandSessionPool();
      addTearDown(() => pool.dispose());

      final result = pool.terminateSession('nonexistent');
      expect(result, isFalse);
    });

    test('dispose terminates all running sessions', () async {
      final pool = CommandSessionPool();

      final s1 = await pool.startSession(command: _longCmd);
      final s2 = await pool.startSession(command: _longCmd);
      expect(s1, isNotNull);
      expect(s2, isNotNull);

      await Future.delayed(Duration(milliseconds: 300));

      pool.dispose();

      expect(s1!.status, CommandSessionStatus.cancelled);
      expect(s2!.status, CommandSessionStatus.cancelled);
    });

    test('getSession returns session by id', () async {
      final pool = CommandSessionPool();
      addTearDown(() => pool.dispose());

      final session = await pool.startSession(command: 'echo test');
      expect(session, isNotNull);

      final found = pool.getSession(session!.sessionId);
      expect(found, same(session));

      final notFound = pool.getSession('nonexistent');
      expect(notFound, isNull);
    });

    test('session counter increments', () async {
      final pool = CommandSessionPool();
      addTearDown(() => pool.dispose());

      final s1 = await pool.startSession(command: 'echo a');
      final s2 = await pool.startSession(command: 'echo b');
      expect(s1, isNotNull);
      expect(s2, isNotNull);
      expect(s1!.sessionId, isNot(equals(s2!.sessionId)));
    });

    test('activeCount tracks running sessions', () async {
      final pool = CommandSessionPool(maxSessions: 5);
      addTearDown(() => pool.dispose());

      expect(pool.activeCount, 0);

      await pool.startSession(command: _longCmd);
      await Future.delayed(Duration(milliseconds: 200));
      expect(pool.activeCount, 1);

      await pool.startSession(command: _longCmd);
      await Future.delayed(Duration(milliseconds: 200));
      expect(pool.activeCount, 2);

      pool.terminateAll();
      // After terminate, sessions are cancelled but still in map
      expect(pool.activeCount, 0);
    });
  });

  group('BgCommandTool', () {
    late BgCommandTool tool;
    late CommandSessionPool pool;

    setUp(() {
      pool = CommandSessionPool();
      tool = BgCommandTool();
      tool.pool = pool;
    });

    tearDown(() {
      pool.dispose();
    });

    test('name is bg_command', () {
      expect(tool.name, 'bg_command');
    });

    test('requiresPermission is true', () {
      expect(tool.requiresPermission, isTrue);
    });

    test('permissionType is command_execute', () {
      expect(tool.permissionType, 'command_execute');
    });

    test('permissionArgKey is command', () {
      expect(tool.permissionArgKey, 'command');
    });

    test('start action launches command', () async {
      final result = await tool.execute({
        'action': 'start',
        'command': 'echo hello',
      });

      expect(result.isError, isFalse);
      expect(result.content, contains('Background command started'));
      expect(result.content, contains('Session ID:'));

      // Wait for completion to avoid teardown issues
      await Future.delayed(Duration(seconds: 2));
    });

    test('start without command returns error', () async {
      final result = await tool.execute({
        'action': 'start',
      });

      expect(result.isError, isTrue);
      expect(result.content, contains('command is required'));
    });

    test('status action reports completed session', () async {
      final startResult = await tool.execute({
        'action': 'start',
        'command': 'echo test',
      });
      expect(startResult.isError, isFalse);

      // Extract sessionId
      final match =
          RegExp(r'Session ID: (bg_\d+_\d+)').firstMatch(startResult.content);
      expect(match, isNotNull);
      final sessionId = match!.group(1)!;

      // Wait for completion
      await Future.delayed(Duration(seconds: 2));

      final statusResult = await tool.execute({
        'action': 'status',
        'sessionId': sessionId,
      });

      expect(statusResult.isError, isFalse);
      expect(statusResult.content, contains('completed'));
      expect(statusResult.content, contains('Exit code: 0'));
    });

    test('status action reports running session', () async {
      final startResult = await tool.execute({
        'action': 'start',
        'command': _longCmd,
      });
      expect(startResult.isError, isFalse);

      final match =
          RegExp(r'Session ID: (bg_\d+_\d+)').firstMatch(startResult.content);
      final sessionId = match!.group(1)!;

      final statusResult = await tool.execute({
        'action': 'status',
        'sessionId': sessionId,
      });

      expect(statusResult.isError, isFalse);
      expect(statusResult.content, contains('running'));

      pool.terminateAll();
    });

    test('output action returns stdout', () async {
      final startResult = await tool.execute({
        'action': 'start',
        'command': 'echo test_output_123',
      });

      final match =
          RegExp(r'Session ID: (bg_\d+_\d+)').firstMatch(startResult.content);
      final sessionId = match!.group(1)!;

      await Future.delayed(Duration(seconds: 2));

      final outputResult = await tool.execute({
        'action': 'output',
        'sessionId': sessionId,
      });

      expect(outputResult.isError, isFalse);
      expect(outputResult.content, contains('test_output_123'));
    });

    test('output shows no output yet for running session with no output',
        () async {
      final startResult = await tool.execute({
        'action': 'start',
        'command': _shortSleepCmd,
      });

      final match =
          RegExp(r'Session ID: (bg_\d+_\d+)').firstMatch(startResult.content);
      final sessionId = match!.group(1)!;

      // Don't wait, check output immediately
      // Note: may or may not have output depending on timing
      final outputResult = await tool.execute({
        'action': 'output',
        'sessionId': sessionId,
      });

      expect(outputResult.isError, isFalse);
      // Just verify it doesn't crash
    });

    test('terminate action kills running session', () async {
      final startResult = await tool.execute({
        'action': 'start',
        'command': _longCmd,
      });

      final match =
          RegExp(r'Session ID: (bg_\d+_\d+)').firstMatch(startResult.content);
      final sessionId = match!.group(1)!;

      await Future.delayed(Duration(milliseconds: 500));

      final terminateResult = await tool.execute({
        'action': 'terminate',
        'sessionId': sessionId,
      });

      expect(terminateResult.isError, isFalse);
      expect(terminateResult.content, contains('terminated'));
    });

    test('terminate on already completed session returns info', () async {
      final startResult = await tool.execute({
        'action': 'start',
        'command': 'echo done',
      });

      final match =
          RegExp(r'Session ID: (bg_\d+_\d+)').firstMatch(startResult.content);
      final sessionId = match!.group(1)!;

      await Future.delayed(Duration(seconds: 2));

      final terminateResult = await tool.execute({
        'action': 'terminate',
        'sessionId': sessionId,
      });

      expect(terminateResult.isError, isFalse);
      expect(terminateResult.content, contains('not running'));
    });

    test('list action shows sessions', () async {
      await tool.execute({
        'action': 'start',
        'command': 'echo one',
      });

      await Future.delayed(Duration(milliseconds: 500));

      final listResult = await tool.execute({
        'action': 'list',
      });

      expect(listResult.isError, isFalse);
      expect(listResult.content, contains('Background command sessions'));
      expect(listResult.content, contains('echo one'));
    });

    test('list with no sessions shows empty message', () async {
      final listResult = await tool.execute({
        'action': 'list',
      });

      expect(listResult.isError, isFalse);
      expect(listResult.content, contains('No background command sessions'));
    });

    test('status with unknown sessionId returns error', () async {
      final result = await tool.execute({
        'action': 'status',
        'sessionId': 'nonexistent',
      });

      expect(result.isError, isTrue);
      expect(result.content, contains('Session not found'));
    });

    test('output with unknown sessionId returns error', () async {
      final result = await tool.execute({
        'action': 'output',
        'sessionId': 'nonexistent',
      });

      expect(result.isError, isTrue);
      expect(result.content, contains('Session not found'));
    });

    test('missing action returns error', () async {
      final result = await tool.execute({});

      expect(result.isError, isTrue);
      expect(result.content, contains('action is required'));
    });

    test('unknown action returns error', () async {
      final result = await tool.execute({
        'action': 'invalid',
      });

      expect(result.isError, isTrue);
      expect(result.content, contains('Unknown action'));
    });

    test('without pool returns error', () async {
      final noPoolTool = BgCommandTool();

      final result = await noPoolTool.execute({
        'action': 'start',
        'command': 'echo test',
      });

      expect(result.isError, isTrue);
      expect(result.content, contains('pool not injected'));
    });

    test('start returns error when concurrent limit reached', () async {
      final smallPool = CommandSessionPool(maxSessions: 1);
      final smallTool = BgCommandTool();
      smallTool.pool = smallPool;
      addTearDown(() => smallPool.dispose());

      // Start first session
      final r1 = await smallTool.execute({
        'action': 'start',
        'command': _longCmd,
      });
      expect(r1.isError, isFalse);

      await Future.delayed(Duration(milliseconds: 300));

      // Second should fail
      final r2 = await smallTool.execute({
        'action': 'start',
        'command': _longCmd,
      });
      expect(r2.isError, isTrue);
      expect(r2.content, contains('concurrent session limit'));

      smallPool.terminateAll();
    });

    test('full workflow: start → status → output → terminate', () async {
      // Start
      final startResult = await tool.execute({
        'action': 'start',
        'command': _longCmd,
      });
      expect(startResult.isError, isFalse);

      final match = RegExp(r'Session ID: (bg_\d+_\d+)')
          .firstMatch(startResult.content);
      final sessionId = match!.group(1)!;

      await Future.delayed(Duration(milliseconds: 500));

      // Status (running)
      final status1 = await tool.execute({
        'action': 'status',
        'sessionId': sessionId,
      });
      expect(status1.isError, isFalse);
      expect(status1.content, contains('running'));

      // Output
      final output1 = await tool.execute({
        'action': 'output',
        'sessionId': sessionId,
      });
      expect(output1.isError, isFalse);

      // Terminate
      final terminate = await tool.execute({
        'action': 'terminate',
        'sessionId': sessionId,
      });
      expect(terminate.isError, isFalse);
      expect(terminate.content, contains('terminated'));

      // Status (cancelled)
      final status2 = await tool.execute({
        'action': 'status',
        'sessionId': sessionId,
      });
      expect(status2.isError, isFalse);
      expect(status2.content, contains('cancelled'));
    });
  });
}
