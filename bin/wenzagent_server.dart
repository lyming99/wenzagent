import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

import 'package:wenzagent/src/entity/lan_message.dart';
import 'package:wenzagent/src/device/device_client.dart';
import 'package:wenzagent/src/host/client_session_manager.dart';
import 'package:wenzagent/src/host/host_rpc_methods.dart';
import 'package:wenzagent/src/lan/impl/lan_host_service_impl.dart';
import 'package:wenzagent/src/lan/entity/client_info.dart';
import 'package:wenzagent/src/lan/lan_client_service.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/rpc/remote_call_server.dart';
import 'package:wenzagent/src/utils/logger.dart';

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

class _ServerConfig {
  final int port;
  final String deviceId;
  final String hostName;
  final String storagePath;
  final String logLevel;

  const _ServerConfig({
    this.port = 9090,
    this.deviceId = '',
    this.hostName = 'WenzAgent Server',
    this.storagePath = './data',
    this.logLevel = 'info',
  });
}

/// Simple CLI argument parser (no external dependency).
_ServerConfig _parseArgs(List<String> args) {
  // Default config file: same name as the executable, next to the binary
  final exePath = Platform.resolvedExecutable;
  final exeDir = File(exePath).parent.path;
  String configPath = '$exeDir${Platform.pathSeparator}wenzagent_server.yaml';
  int? cliPort;
  String? cliDeviceId;
  String? cliHostName;
  String? cliStoragePath;
  String? cliLogLevel;

  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--config':
        if (i + 1 < args.length) configPath = args[++i];
        break;
      case '--port':
        if (i + 1 < args.length) cliPort = int.tryParse(args[++i]);
        break;
      case '--device-id':
        if (i + 1 < args.length) cliDeviceId = args[++i];
        break;
      case '--host-name':
        if (i + 1 < args.length) cliHostName = args[++i];
        break;
      case '--storage-path':
        if (i + 1 < args.length) cliStoragePath = args[++i];
        break;
      case '--log-level':
        if (i + 1 < args.length) cliLogLevel = args[++i];
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

  return _ServerConfig(
    port: port,
    deviceId: cliDeviceId ?? _yamlStr(yaml, 'deviceId') ?? const Uuid().v4(),
    hostName: cliHostName ?? _yamlStr(yaml, 'hostName') ?? 'WenzAgent Server',
    storagePath:
        cliStoragePath ?? _yamlStr(yaml, 'storagePath') ?? './data',
    logLevel: cliLogLevel ?? _yamlStr(yaml, 'logLevel') ?? 'info',
  );
}

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

void _printHelp() {
  // ignore: avoid_print
  print('''
WenzAgent LAN Server

Usage: dart run bin/wenzagent_server.dart [options]

Options:
  --config <path>       YAML config file path (default: <exe_dir>/wenzagent_server.yaml)
  --port <int>          Service port (default: 9090)
  --device-id <id>      Device ID (default: auto-generated UUID)
  --host-name <name>    Device display name (default: "WenzAgent Server")
  --storage-path <path> Storage directory (default: ./data)
  --log-level <level>   Log level: debug|info|warn|error|none (default: info)
  --version             Print version
  --help, -h            Show this help

Priority: CLI args > YAML config > defaults

YAML config example (wenzagent_server.yaml, place next to the executable):
  port: 9090
  deviceId: "host-server-001"
  hostName: "WenzAgent Server"
  storagePath: "./data"
  logLevel: "info"
''');
}

void _printVersion() {
  // ignore: avoid_print
  print('wenzagent v1.0.0');
}

// ---------------------------------------------------------------------------
// Host-side adapter: bridges LanClientService -> LanHostServiceImpl
// ---------------------------------------------------------------------------

/// Adapts [LanHostServiceImpl] to the [LanClientService] interface so that
/// [RemoteCallServer] can send RPC responses through the host.
class _HostLanClientServiceAdapter implements LanClientService {
  final LanHostServiceImpl _hostService;

  _HostLanClientServiceAdapter(this._hostService);

  @override
  bool get isConnected => _hostService.isRunning;

  @override
  bool get isConnecting => false;

  @override
  String get deviceId => _hostService.isRunning ? '__host__' : '';

  @override
  String? get topic => null;

  @override
  String? get hostIp => _hostService.localIp;

  @override
  int get hostPort => _hostService.port;

  @override
  Stream<LanMessage> get messageStream =>
      const Stream.empty();

  @override
  double get uploadProgress => 0.0;

  @override
  double get downloadProgress => 0.0;

  @override
  Future<void> connect(String hostIp, {int port = 9090}) async {
    // No-op on host side
  }

  @override
  Future<void> disconnect() async {
    // No-op on host side
  }

  @override
  Future<void> reconnect() async {
    // No-op on host side
  }

  @override
  void sendMessage(String content) {
    // No-op — use sendLanMessage for RPC
  }

  @override
  Future<bool> sendLanMessage(LanMessage message) async {
    final toDeviceId = message.toDeviceId;
    if (toDeviceId != null && toDeviceId.isNotEmpty) {
      _hostService.sendToDeviceId(toDeviceId, message);
    } else {
      _hostService.broadcast(message);
    }
    return true;
  }

  @override
  Future<String> uploadFile(String filePath) {
    throw UnimplementedError('uploadFile not available on host');
  }

  @override
  Future<void> downloadFile(String fileId, String savePath) {
    throw UnimplementedError('downloadFile not available on host');
  }

  @override
  Future<ClientInfo> getClientInfo() async {
    return ClientInfo(
      id: '__host__',
      hostIp: _hostService.localIp,
      hostPort: _hostService.port,
      isConnected: _hostService.isRunning,
      deviceId: '__host__',
    );
  }

  @override
  void sendBinaryMessage(Uint8List data) {
    // Host 端不支持直接发送二进制消息，二进制帧由 LanHostServiceImpl 转发
  }

  @override
  Stream<BinaryChunkEvent> get binaryChunkStream => const Stream.empty();
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

  // 4. Initialize Logger
  Logger.level = _parseLogLevel(config.logLevel);

  final log = Logger('WenzAgentServer');

  // 5. Ensure storage directory exists
  final storageDir = Directory(config.storagePath);
  if (!storageDir.existsSync()) {
    storageDir.createSync(recursive: true);
  }

  // 6. Initialize DeviceClient (unified entry point for all services)
  final deviceClient = DeviceClient.getInstance(config.deviceId);
  await deviceClient.initialize(DeviceClientConfig(
    storagePath: config.storagePath,
    host: '',
    port: config.port,
    deviceName: config.hostName,
  ));
  final db = DatabaseManager.getInstance(config.deviceId);

  // 7. Get service instances from DeviceClient
  final employeeManager = deviceClient.employeeManager;
  final sessionManager = deviceClient.sessionManager;
  final skillManager = deviceClient.skillManager;
  final messageStore = deviceClient.messageStore;

  // 8. Create ClientSessionManager
  final clientSessionManager = ClientSessionManager();

  // 9. Create host service & adapter
  final hostService = LanHostServiceImpl();
  final adapter = _HostLanClientServiceAdapter(hostService);

  // 10. Create RemoteCallServer and register all Host RPC methods
  final rpcServer = RemoteCallServer(
    clientService: adapter,
    localDeviceId: config.deviceId,
  );
  registerHostRpcMethods(
    rpcServer: rpcServer,
    employeeManager: employeeManager,
    sessionManager: sessionManager,
    skillManager: skillManager,
    messageStore: messageStore,
    clientSessionManager: clientSessionManager,
    projectManager: deviceClient.projectManager,
    globalSkillManager: deviceClient.globalSkillManager,
    deviceId: config.deviceId,
  );

  // 11. Start LanHostServiceImpl
  await hostService.start(port: config.port, storageDir: config.storagePath);

  // 12. Listen to messageStream, forward rpcRequest messages to RPC server
  final messageSub = hostService.messageStream.listen((msg) {
    if (msg.type == LanMessageType.rpcRequest && msg.content != null) {
      try {
        final contentData = jsonDecode(msg.content!) as Map<String, dynamic>;
        final payload = contentData['payload'] as Map<String, dynamic>?;
        if (payload != null) {
          rpcServer.handleRequest(payload);
        }
      } catch (e) {
        log.warn('Failed to parse rpcRequest payload: $e');
      }
    }
  });

  // 13. Print startup info
  log.info('WenzAgent LAN Server started');
  log.info('  Device ID : ${config.deviceId}');
  log.info('  Host Name : ${config.hostName}');
  log.info('  IP        : ${hostService.localIp ?? "unknown"}');
  log.info('  Port      : ${hostService.port}');
  log.info('  Storage   : ${config.storagePath}');
  log.info('Press Ctrl+C to stop.');

  // 14. Graceful shutdown on SIGINT
  final shutdownCompleter = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) {
    if (!shutdownCompleter.isCompleted) {
      shutdownCompleter.complete();
    }
  });

  // 15. Wait for shutdown signal
  await shutdownCompleter.future;

  log.info('Shutting down...');

  // 16. Cleanup: cancel subscription -> stop host -> dispose RPC -> close DB
  await messageSub.cancel();
  await hostService.stop();
  rpcServer.dispose();
  await db.close();
  await DeviceClient.removeInstance(config.deviceId);

  log.info('Server stopped.');
}
