import 'dart:async';
import 'dart:io';

import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

import 'package:wenzagent/src/device/device_client.dart';
import 'package:wenzagent/src/entity/lan_message.dart';
import 'package:wenzagent/src/utils/logger.dart';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

class _ClientConfig {
  final String host;
  final int port;
  final String deviceId;
  final String deviceName;
  final String storagePath;
  final String logLevel;
  final String? topic;

  const _ClientConfig({
    required this.host,
    this.port = 9090,
    this.deviceId = '',
    this.deviceName = 'WenzAgent Client',
    this.storagePath = './data',
    this.logLevel = 'info',
    this.topic,
  });
}

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

_ClientConfig _parseArgs(List<String> args) {
  // Default config file: same name as the executable, next to the binary
  final exePath = Platform.resolvedExecutable;
  final exeDir = File(exePath).parent.path;
  String configPath = '$exeDir${Platform.pathSeparator}wenzagent_client.yaml';
  String? cliHost;
  int? cliPort;
  String? cliDeviceId;
  String? cliDeviceName;
  String? cliStoragePath;
  String? cliLogLevel;
  String? cliTopic;

  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--config':
        if (i + 1 < args.length) configPath = args[++i];
        break;
      case '--host':
        if (i + 1 < args.length) cliHost = args[++i];
        break;
      case '--port':
        if (i + 1 < args.length) cliPort = int.tryParse(args[++i]);
        break;
      case '--device-id':
        if (i + 1 < args.length) cliDeviceId = args[++i];
        break;
      case '--device-name':
        if (i + 1 < args.length) cliDeviceName = args[++i];
        break;
      case '--storage-path':
        if (i + 1 < args.length) cliStoragePath = args[++i];
        break;
      case '--log-level':
        if (i + 1 < args.length) cliLogLevel = args[++i];
        break;
      case '--topic':
        if (i + 1 < args.length) cliTopic = args[++i];
        break;
      case '--version':
        _printVersion();
        exit(0);
      case '--help':
      case '-h':
        _printHelp();
        exit(0);
    }
  }

  // Load YAML config (file may not exist — that's fine)
  final yaml = _loadYamlConfig(configPath);

  final port = cliPort ?? _yamlInt(yaml, 'port') ?? 9090;
  if (port < 1 || port > 65535) {
    stderr.writeln('Error: port must be between 1 and 65535, got $port');
    exit(1);
  }

  final host = cliHost ?? _yamlStr(yaml, 'host') ?? '';
  if (host.isEmpty) {
    stderr.writeln('Error: --host is required (or set "host" in config file)');
    exit(1);
  }

  return _ClientConfig(
    host: host,
    port: port,
    deviceId:
        cliDeviceId ?? _yamlStr(yaml, 'deviceId') ?? const Uuid().v4(),
    deviceName:
        cliDeviceName ?? _yamlStr(yaml, 'deviceName') ?? 'WenzAgent Client',
    storagePath:
        cliStoragePath ?? _yamlStr(yaml, 'storagePath') ?? './data',
    logLevel: cliLogLevel ?? _yamlStr(yaml, 'logLevel') ?? 'info',
    topic: cliTopic ?? _yamlStr(yaml, 'topic'),
  );
}

// ---------------------------------------------------------------------------
// YAML helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _loadYamlConfig(String path) {
  var file = File(path);
  // If the explicit path doesn't exist, try looking next to the executable
  if (!file.existsSync()) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final fallback = '$exeDir${Platform.pathSeparator}${path.split(Platform.pathSeparator).last}';
    file = File(fallback);
  }
  if (!file.existsSync()) return {};
  try {
    final content = file.readAsStringSync();
    final doc = loadYaml(content);
    if (doc is YamlMap) {
      return doc.map((k, v) => MapEntry(k.toString(), v));
    }
  } catch (e) {
    stderr.writeln('Warning: failed to parse config file $path: $e');
  }
  return {};
}

String? _yamlStr(Map<String, dynamic> yaml, String key) {
  final v = yaml[key];
  return v?.toString();
}

int? _yamlInt(Map<String, dynamic> yaml, String key) {
  final v = yaml[key];
  if (v is int) return v;
  if (v is String) return int.tryParse(v);
  return null;
}

// ---------------------------------------------------------------------------
// Help / Version
// ---------------------------------------------------------------------------

void _printHelp() {
  // ignore: avoid_print
  print('''
WenzAgent LAN Client

Usage: dart run bin/wenzagent_client.dart --host <ip> [options]

Options:
  --config <path>       YAML config file path (default: <exe_dir>/wenzagent_client.yaml)
  --host <ip>           Server IP address (required, or set in config)
  --port <int>          Server port (default: 9090)
  --device-id <id>      Device ID (default: auto-generated UUID)
  --device-name <name>  Device display name (default: "WenzAgent Client")
  --storage-path <path> Local storage directory (default: ./data)
  --log-level <level>   Log level: debug|info|warn|error|none (default: info)
  --topic <topic>       Optional group topic
  --version             Print version
  --help, -h            Show this help

Priority: CLI args > YAML config > defaults

YAML config example (wenzagent_client.yaml, place next to the executable):
  host: "192.168.1.100"
  port: 9090
  deviceId: "my-laptop"
  deviceName: "My Laptop"
  storagePath: "./data"
  logLevel: "info"
  topic: ""
''');
}

void _printVersion() {
  // ignore: avoid_print
  print('wenzagent v1.0.0');
}

// ---------------------------------------------------------------------------
// Log level helper
// ---------------------------------------------------------------------------

LogLevel _parseLogLevel(String level) {
  return switch (level.toLowerCase()) {
    'debug' => LogLevel.debug,
    'info' => LogLevel.info,
    'warn' => LogLevel.warn,
    'error' => LogLevel.error,
    'none' => LogLevel.none,
    _ => LogLevel.info,
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final config = _parseArgs(args);

  // Initialize Logger
  Logger.level = _parseLogLevel(config.logLevel);

  final log = Logger('WenzAgentClient');

  // Ensure storage directory exists
  final storageDir = Directory(config.storagePath);
  if (!storageDir.existsSync()) {
    storageDir.createSync(recursive: true);
  }

  // Create DeviceClient
  final client = DeviceClient.getInstance(config.deviceId);

  // Initialize
  await client.initialize(DeviceClientConfig(
    storagePath: config.storagePath,
    host: config.host,
    port: config.port,
    deviceName: config.deviceName,
    topic: config.topic,
  ));

  // Listen to connection state changes
  client.onConnectionStateChanged.listen((state) {
    log.info('Connection state: ${state.name}');
  });

  // --- Ping status logging ---
  DateTime? lastPingSent;
  int pingCount = 0;
  int pongCount = 0;
  Timer? statusTimer;

  client.onLanMessage.listen((msg) {
    if (msg.type == LanMessageType.ping && msg.fromName == 'Host') {
      lastPingSent = DateTime.now();
      pingCount++;
    } else if (msg.type == LanMessageType.pong) {
      pongCount++;
      if (lastPingSent != null) {
        final rtt = DateTime.now().difference(lastPingSent!).inMilliseconds;
        log.info('Ping: ${rtt}ms');
      }
    }
  });

  // Periodically log connection health
  void startStatusTimer() {
    statusTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final state = client.connectionState.name;
      final connected = client.isConnected;
      log.info(
        'Status: connected=$connected, state=$state, '
        'ping_received=$pingCount, pong_sent=$pongCount',
      );
    });
  }

  // Connect to server
  try {
    await client.connect();
  } catch (e) {
    stderr.writeln('Failed to connect to ${config.host}:${config.port}: $e');
    exit(1);
  }

  // Start status timer after connected
  startStatusTimer();

  // Print startup info
  log.info('WenzAgent LAN Client started');
  log.info('  Device ID   : ${config.deviceId}');
  log.info('  Device Name : ${config.deviceName}');
  log.info('  Server      : ${config.host}:${config.port}');
  log.info('  Topic       : ${config.topic ?? "(none)"}');
  log.info('  Storage     : ${config.storagePath}');
  log.info('Press Ctrl+C to stop.');

  // Graceful shutdown on SIGINT
  final shutdownCompleter = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) {
    if (!shutdownCompleter.isCompleted) {
      shutdownCompleter.complete();
    }
  });

  // Wait for shutdown signal
  await shutdownCompleter.future;

  log.info('Shutting down...');

  // Cleanup: cancel status timer -> disconnect -> dispose DeviceClient
  statusTimer?.cancel();
  await client.disconnect();
  await DeviceClient.removeInstance(config.deviceId);

  log.info('Client stopped.');
}
