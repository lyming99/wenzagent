/// Example: 模拟调用 bin/wenzagent_client.dart 的 main 方法
///
/// 参数：--host 127.0.0.1 --port 9900 --device-id test --device-name test-device
///
/// 本示例提供两种方式：
///   方式一：通过 Process 启动子进程（推荐，最接近真实使用方式）
///   方式二：通过 Isolate.spawnUri 运行（纯 Dart，无进程开销）
///
/// 用法：
///   dart run example/wenzagent_client_example.dart
library;

import 'dart:async';
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

  // 选择运行方式（默认方式一，可通过命令行参数切换）
  await _runViaIsolate(clientArgs);
}


// ---------------------------------------------------------------------------
// 方式二：通过 Isolate.spawnUri 运行
// ---------------------------------------------------------------------------

Future<void> _runViaIsolate(List<String> clientArgs) async {
  final scriptPath = _resolveClientScript();
  final scriptUri = Uri.file(scriptPath);

  print('Launching: Isolate.spawnUri($scriptUri)');
  print('──────────────────────────────────────────────────');

  final onExit = ReceivePort();

  try {
    await Isolate.spawnUri(
      scriptUri,
      clientArgs,
      null,
      onExit: onExit.sendPort,
    );

    // 等待 isolate 退出
    await onExit.first;
    print('──────────────────────────────────────────────────');
    print('Client isolate has exited.');
  } catch (e) {
    onExit.close();
    print('Isolate.spawnUri failed: $e');
    print('');
    print('This may happen when running from a snapshot.');
    print('Try the Process mode instead (remove --isolate flag).');
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
