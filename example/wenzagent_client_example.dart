/// Example: 模拟调用 bin/wenzagent_client.dart 的 main 方法
///
/// 参数：--host 127.0.0.1 --port 9900 --device-id test --device-name test-device
///
/// 本示例通过 Process 启动子进程来运行 wenzagent_client.dart。
///
/// 用法：
///   dart run example/wenzagent_client_example.dart
library;

import 'dart:async';
import 'dart:io';

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

const _host = '127.0.0.1';
const _port = '9900';
const _deviceId = 'test-device-kimi';
const _deviceName = 'test-device-kimi';

const _extraArgs = <String>[]; // 可追加额外参数，如 '--log-level', 'debug'

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final clientArgs = [
    '--host', _host,
    '--port', _port,
    '--device-id', _deviceId,
    '--device-name', _deviceName,
    ..._extraArgs,
  ];

  print('╔══════════════════════════════════════════════════╗');
  print('║     WenzAgent Client - Example Launcher         ║');
  print('╠══════════════════════════════════════════════════╣');
  print('║  Host       : $_host');
  print('║  Port       : $_port');
  print('║  Device ID  : $_deviceId');
  print('║  Device Name: $_deviceName');
  print('╚══════════════════════════════════════════════════╝');
  print('');

  await _runViaProcess(clientArgs);
}

// ---------------------------------------------------------------------------
// 通过 Process 启动子进程运行 wenzagent_client.dart
// ---------------------------------------------------------------------------

Future<void> _runViaProcess(List<String> clientArgs) async {
  final scriptPath = _resolveClientScript();

  print('Launching: dart $scriptPath ${clientArgs.join(' ')}');
  print('──────────────────────────────────────────────────');

  try {
    final process = await Process.start(
      'dart',
      ['run', scriptPath, ...clientArgs],
      mode: ProcessStartMode.inheritStdio,
    );

    final exitCode = await process.exitCode;

    print('──────────────────────────────────────────────────');
    print('Client process exited with code: $exitCode');
  } catch (e) {
    print('Failed to start client process: $e');
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// 项目根目录
String get _projectRoot {
  // 从当前脚本位置推导项目根目录
  final script = Platform.script.toFilePath();
  // example/wenzagent_client_example.dart -> 项目根
  final exampleDir = File(script).parent.path;
  return File(exampleDir).parent.path;
}

/// 解析 wenzagent_client.dart 的绝对路径
String _resolveClientScript() {
  return '$_projectRoot${Platform.pathSeparator}bin${Platform.pathSeparator}wenzagent_client.dart';
}
