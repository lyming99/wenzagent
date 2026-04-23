/// Example: 直接调用 bin/wenzagent_client.dart 的 main 方法
///
/// 参数：--host 127.0.0.1 --port 9900 --device-id test --device-name test-device
///
/// 本示例通过 Isolate.spawnUri 在同一进程内以独立 Isolate 运行 client，
/// 而非通过 Process 启动子进程。
///
/// 用法：
///   dart run example/wenzagent_client_example.dart
library;

import 'dart:io';
import 'dart:isolate';

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
  final clientArgs = <String>[
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

  await _runViaIsolate(clientArgs);
}

// ---------------------------------------------------------------------------
// 通过 Isolate.spawnUri 在同一进程内运行 wenzagent_client.dart
// ---------------------------------------------------------------------------

Future<void> _runViaIsolate(List<String> clientArgs) async {
  final scriptUri = Uri.file(_resolveClientScript());

  print('Spawning Isolate: $scriptUri');
  print('Args: ${clientArgs.join(' ')}');
  print('──────────────────────────────────────────────────');

  final receivePort = ReceivePort();

  try {
    final isolate = await Isolate.spawnUri(
      scriptUri,
      clientArgs,
      receivePort.sendPort,
    );

    // 监听 isolate 消息
    await receivePort.first;

    isolate.kill(priority: Isolate.immediate);
  } catch (e) {
    print('Failed to spawn isolate: $e');
  } finally {
    receivePort.close();
  }

  print('──────────────────────────────────────────────────');
  print('Client isolate finished.');
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// 项目根目录
String get _projectRoot {
  final script = Platform.script.toFilePath();
  // example/wenzagent_client_example.dart -> 项目根
  final exampleDir = File(script).parent.path;
  return File(exampleDir).parent.path;
}

/// 解析 wenzagent_client.dart 的绝对路径
String _resolveClientScript() {
  return '$_projectRoot${Platform.pathSeparator}bin${Platform.pathSeparator}wenzagent_client.dart';
}
