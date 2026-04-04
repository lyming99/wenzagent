import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../entity/lan_message.dart';
import '../lan_chunk_service.dart';
import '../lan_client_service.dart';

/// LAN 客户端实现
class LanClientServiceImpl implements LanClientService {
  // 多实例管理：key = deviceId
  static final Map<String, LanClientServiceImpl> _instances = {};

  factory LanClientServiceImpl({String? deviceId, String? topic}) {
    final id = deviceId ?? 'default';
    return _instances.putIfAbsent(
      id,
      () => LanClientServiceImpl._internal(id, topic: topic),
    );
  }

  LanClientServiceImpl._internal(this._deviceId, {String? topic})
      : _topic = topic;

  /// 释放指定 deviceId 的实例
  static Future<void> dispose(String deviceId) async {
    final instance = _instances.remove(deviceId);
    if (instance != null) {
      await instance._doDisconnect();
    }
  }

  /// 释放所有实例
  static Future<void> disposeAll() async {
    final instances = List<LanClientServiceImpl>.from(_instances.values);
    _instances.clear();
    for (final instance in instances) {
      await instance._doDisconnect();
    }
  }

  /// 获取所有活跃的 deviceId
  static List<String> get activeDeviceIds => _instances.keys.toList();

  /// 检查指定 deviceId 是否已连接
  static bool isDeviceConnected(String deviceId) =>
      _instances[deviceId]?._isConnected ?? false;

  final String _deviceId;
  final String? _topic;

  WebSocketChannel? _channel;
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _manualDisconnect = false;
  String? _hostIp;
  int _hostPort = 9090;
  String? _myId;
  String? _localIp;

  final _messageController = StreamController<LanMessage>.broadcast();
  double _uploadProgress = 0;
  double _downloadProgress = 0;

  // 重连相关
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  static const int _reconnectDelay = 5;

  final LanChunkService _chunkService = LanChunkService();
  final _uuid = const Uuid();

  @override
  bool get isConnected => _isConnected;

  @override
  bool get isConnecting => _isConnecting;

  @override
  String get deviceId => _deviceId;

  @override
  String? get topic => _topic;

  @override
  String? get hostIp => _hostIp;

  @override
  int get hostPort => _hostPort;

  @override
  Stream<LanMessage> get messageStream => _messageController.stream;

  @override
  double get uploadProgress => _uploadProgress;

  @override
  double get downloadProgress => _downloadProgress;

  @override
  Future<void> connect(String hostIp, {int port = 9090}) async {
    if (_isConnected || _isConnecting) return;

    _hostIp = hostIp;
    _hostPort = port;
    _myId ??= _uuid.v4();
    _localIp ??= await _getLocalIp();

    final uri = Uri.parse('ws://$hostIp:$port/ws');
    _channel = WebSocketChannel.connect(uri);

    _isConnecting = true;
    _addSystemMessage('正在连接 $hostIp:$port...');

    try {
      await _channel!.ready;
    } catch (e) {
      _isConnecting = false;
      _addSystemMessage('连接失败: $e');
      rethrow;
    }

    _channel!.stream.listen(
      (data) {
        try {
          final msg = LanMessage.fromJson(_parseJson(data));
          _messageController.add(msg);

          if (msg.type == LanMessageType.file && msg.fileId != null) {
            _autoDownloadFile(msg);
          }
        } catch (_) {}
      },
      onDone: () {
        _isConnected = false;
        _isConnecting = false;
        _stopHeartbeat();
        if (_manualDisconnect) return;
        _addSystemMessage('已断开局域网连接');
        _scheduleReconnect();
      },
      onError: (_) {
        _isConnected = false;
        _isConnecting = false;
        _stopHeartbeat();
        if (_manualDisconnect) return;
        _addSystemMessage('连接出错');
        _scheduleReconnect();
      },
    );

    _isConnecting = false;
    _isConnected = true;
    _manualDisconnect = false;
    _addSystemMessage('已加入局域网 $hostIp:$port');

    _sendClientInfo();
    _startHeartbeat();
  }

  @override
  Future<void> disconnect() async {
    await _doDisconnect();
    _addSystemMessage('已离开局域网');
  }

  Future<void> _doDisconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopHeartbeat();

    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _isConnected = false;
    _isConnecting = false;
  }

  @override
  void sendMessage(String content) {
    if (!_isConnected) return;

    final msg = LanMessage(
      id: _uuid.v4(),
      type: LanMessageType.text,
      fromId: _myId,
      fromName: _getDeviceName(),
      content: content,
    );

    _channel?.sink.add(jsonEncode(msg.toJson()));
  }

  @override
  void sendLanMessage(LanMessage message) {
    if (!_isConnected) return;
    _channel?.sink.add(jsonEncode(message.toJson()));
  }

  /// 直接发送原始 JSON 字符串到 WebSocket
  void sendRawMessage(String json) {
    if (!_isConnected) return;
    _channel?.sink.add(json);
  }

  @override
  Future<String> uploadFile(String filePath) async {
    if (!_isConnected) throw Exception('未连接');

    final uri = Uri.parse('http://$_hostIp:$_hostPort/upload');

    final metadata = await _chunkService.uploadFile(
      filePath,
      uri.toString(),
      (progress, sent, total) => _uploadProgress = progress,
    );

    return metadata.fileId;
  }

  @override
  Future<void> downloadFile(String fileId, String savePath) async {
    if (!_isConnected) throw Exception('未连接');

    final uri = Uri.parse('http://$_hostIp:$_hostPort/download?fileId=$fileId');

    await _chunkService.downloadFile(
      fileId,
      savePath,
      uri.toString(),
      (progress, sent, total) => _downloadProgress = progress,
    );
  }

  @override
  Future<void> reconnect() async {
    await disconnect();
    if (_hostIp != null) {
      await connect(_hostIp!, port: _hostPort);
    }
  }

  @override
  Future<Map<String, dynamic>> getClientInfo() async {
    final ip = await _getLocalIp();
    return {
      'id': _myId,
      'ip': ip,
      'hostIp': _hostIp,
      'hostPort': _hostPort,
      'isConnected': _isConnected,
      'deviceId': _deviceId,
      'topic': _topic,
      'name': _getDeviceName(),
    };
  }

  // ==================== Private ====================

  void _scheduleReconnect() {
    _reconnectTimer = Timer(const Duration(seconds: _reconnectDelay), () async {
      try {
        if (_hostIp != null) {
          await connect(_hostIp!, port: _hostPort);
          _addSystemMessage('重连成功');
        }
      } catch (_) {
        _scheduleReconnect();
      }
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_isConnected) {
        try {
          final msg = LanMessage(
            id: _uuid.v4(),
            type: LanMessageType.clientInfo,
            fromId: _myId,
            content: 'heartbeat',
          );
          _channel?.sink.add(jsonEncode(msg.toJson()));
        } catch (_) {
          _isConnected = false;
          _stopHeartbeat();
          _scheduleReconnect();
        }
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _autoDownloadFile(LanMessage msg) async {
    try {
      final savePath =
          '${Directory.systemTemp.path}/lan_download_${msg.fileId}_${msg.fileName ?? 'file'}';
      final uri = 'http://$_hostIp:$_hostPort/download?fileId=${msg.fileId}';
      await _chunkService.downloadFile(
        msg.fileId!,
        savePath,
        uri,
        (progress, sent, total) => _downloadProgress = progress,
      );
      _addSystemMessage('文件已下载: ${msg.fileName ?? 'file'}');
    } catch (e) {
      _addSystemMessage('文件下载失败: $e');
    }
  }

  void _sendClientInfo() {
    final msg = LanMessage(
      id: _uuid.v4(),
      type: LanMessageType.clientInfo,
      fromId: _myId,
      fromName: _getDeviceName(),
      content: _localIp ?? '',
      fileName: _deviceId,
      topic: _topic ?? '',
    );
    _channel?.sink.add(jsonEncode(msg.toJson()));
  }

  void _addSystemMessage(String text) {
    _messageController.add(LanMessage(
      id: _uuid.v4(),
      type: LanMessageType.system,
      content: text,
      timestamp: DateTime.now(),
    ));
  }

  Future<String?> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  String _getDeviceName() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'Unknown';
    }
  }

  Map<String, dynamic> _parseJson(dynamic data) {
    final str = data is String ? data : String.fromCharCodes(data);
    return jsonDecode(str) as Map<String, dynamic>;
  }
}
