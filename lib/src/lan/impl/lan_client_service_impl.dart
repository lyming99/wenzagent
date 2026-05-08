import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../entity/lan_message.dart';
import '../../utils/logger.dart';
import '../entity/client_info.dart';
import '../lan_chunk_service.dart';
import '../lan_client_service.dart';

/// LAN 客户端实现
class LanClientServiceImpl implements LanClientService {
  static final _log = Logger('LanClientService');
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
  bool _kickedOffline = false;  // 被踢下线标志（相同 deviceId 重复登录）
  String? _hostIp;
  int _hostPort = 9090;
  String? _myId;
  String? _localIp;

  final _messageController = StreamController<LanMessage>.broadcast();
  final _binaryChunkController = StreamController<BinaryChunkEvent>.broadcast();
  double _uploadProgress = 0;
  double _downloadProgress = 0;

  // 重连相关
  Timer? _reconnectTimer;
  static const int _reconnectDelay = 5;

  // 心跳 ping 定时器
  Timer? _pingTimer;
  static const Duration _pingInterval = Duration(seconds: 9);

  final LanChunkService _chunkService = LanChunkService();
  final _uuid = const Uuid();

  // 待发送消息队列：断线时缓存，重连后自动重发
  final List<LanMessage> _pendingMessages = [];
  static const int _maxPendingMessages = 100;

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
        if (data is String) {
          // 文本消息（现有逻辑）
          try {
            final msg = LanMessage.fromJson(_parseJson(data));

            // 检查是否被踢下线（重复登录）
            if (msg.type == LanMessageType.system &&
                msg.content == 'kicked:duplicate_login') {
              _kickedOffline = true;
              _addSystemMessage('已被踢下线：相同 deviceId 在其他位置登录');
            }

            _messageController.add(msg);

            if (msg.type == LanMessageType.file && msg.fileId != null) {
              _autoDownloadFile(msg);
            }
          } catch (e) {
            _log.warn('parse server message failed: $e');
          }
        } else {
          // 二进制消息
          _handleBinaryData(data);
        }
      },
      onDone: () {
        _isConnected = false;
        _isConnecting = false;
        if (_manualDisconnect) return;
        if (_kickedOffline) {
          _addSystemMessage('已被踢下线，不再重连');
          return;
        }
        _addSystemMessage('已断开局域网连接');
        _scheduleReconnect();
      },
      onError: (_) {
        _isConnected = false;
        _isConnecting = false;
        if (_manualDisconnect) return;
        if (_kickedOffline) return;
        _addSystemMessage('连接出错');
        _scheduleReconnect();
      },
    );

    _isConnecting = false;
    _isConnected = true;
    _manualDisconnect = false;
    _kickedOffline = false;
    _addSystemMessage('已加入局域网 $hostIp:$port');

    _sendClientInfo();
    _startPingTimer();
    _flushPendingMessages();
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
    _stopPingTimer();

    try {
      await _channel?.sink.close();
    } catch (e) {
      _log.debug('close channel on disconnect failed: $e');
    }
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
  Future<bool> sendLanMessage(LanMessage message) async {
    if (!_isConnected) {
      // 断线时缓存消息，等待重连后重发
      if (_pendingMessages.length < _maxPendingMessages) {
        _pendingMessages.add(message);
        _log.debug('LAN未连接，消息已缓存待重发 (队列: ${_pendingMessages.length})');
        return true;
      } else {
        _log.warn('LAN消息缓存队列已满($_maxPendingMessages)，丢弃消息: ${message.type}');
        return false;
      }
    }
    try {
      _channel?.sink.add(jsonEncode(message.toJson()));
      return true;
    } catch (e) {
      _log.warn('LAN消息发送失败，缓存待重发: $e');
      if (_pendingMessages.length < _maxPendingMessages) {
        _pendingMessages.add(message);
      }
      return false;
    }
  }

  /// 直接发送原始 JSON 字符串到 WebSocket
  void sendRawMessage(String json) {
    if (!_isConnected) return;
    _channel?.sink.add(json);
  }

  @override
  void sendBinaryMessage(Uint8List data) {
    if (!_isConnected) return;
    // ignore: avoid_print
    print('[CLIENT-SEND-BIN] sending ${data.length} bytes');
    _channel?.sink.add(data);
  }

  @override
  Stream<BinaryChunkEvent> get binaryChunkStream =>
      _binaryChunkController.stream;

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
  Future<ClientInfo> getClientInfo() async {
    final ip = await _getLocalIp();
    return ClientInfo(
      id: _myId ?? '',
      ip: ip,
      hostIp: _hostIp,
      hostPort: _hostPort,
      isConnected: _isConnected,
      deviceId: _deviceId,
      topic: _topic,
      name: _getDeviceName(),
    );
  }

  // ==================== Private ====================

  /// 重连成功后重发缓存的消息队列
  void _flushPendingMessages() {
    if (_pendingMessages.isEmpty) return;
    final count = _pendingMessages.length;
    _log.info('开始重发 $count 条缓存消息...');
    for (final msg in List.from(_pendingMessages)) {
      try {
        _channel?.sink.add(jsonEncode(msg.toJson()));
      } catch (e) {
        _log.warn('重发缓存消息失败: $e');
        break; // 发送失败停止重发，保留未发送的消息
      }
    }
    _pendingMessages.clear();
    _log.info('缓存消息重发完成');
  }

  void _scheduleReconnect() {
    _reconnectTimer = Timer(const Duration(seconds: _reconnectDelay), () async {
      try {
        if (_hostIp != null) {
          await connect(_hostIp!, port: _hostPort);
          _addSystemMessage('重连成功');
        }
      } catch (e) {
        _log.debug('reconnect failed, will retry: $e');
        _scheduleReconnect();
      }
    });
  }

  void _startPingTimer() {
    _stopPingTimer();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (!_isConnected) {
        _stopPingTimer();
        return;
      }
      try {
        final ping = LanMessage(
          id: _uuid.v4(),
          type: LanMessageType.ping,
          fromId: _myId,
          timestamp: DateTime.now(),
        );
        _channel?.sink.add(jsonEncode(ping.toJson()));
      } catch (e) {
        _log.debug('send ping failed: $e');
      }
    });
  }

  void _stopPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;
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
    } catch (e) {
      _log.debug('get local IP failed: $e');
    }
    return null;
  }

  String _getDeviceName() {
    try {
      return Platform.localHostname;
    } catch (e) {
      _log.debug('get device name failed, using fallback: $e');
      return 'Unknown';
    }
  }

  Map<String, dynamic> _parseJson(dynamic data) {
    final str = data is String ? data : String.fromCharCodes(data);
    return jsonDecode(str) as Map<String, dynamic>;
  }

  /// 处理 WebSocket 二进制消息
  ///
  /// 帧格式：
  /// [0]    0x01 版本
  /// [1]    0x02 binaryChunk
  /// [2..5] toDeviceId 长度 (uint32 BE)
  /// [6..M] toDeviceId (UTF-8)
  /// [M+1..M+4] requestId 长度 (uint32 BE)
  /// [M+5..N] requestId (UTF-8)
  /// [N+1]  flags (bit0=lastChunk)
  /// [N+2..] 原始二进制数据
  void _handleBinaryData(dynamic data) {
    try {
      final bytes = data is Uint8List
          ? data
          : Uint8List.fromList(data as List<int>);

      // ignore: avoid_print
      print('[CLIENT-RECV-BIN] received ${bytes.length} bytes, hasListener=${_binaryChunkController.hasListener}');

      // 最小帧头长度：version(1) + type(1) + toDeviceIdLen(4) + toDeviceId(0)
      // + requestIdLen(4) + requestId(0) + flags(1) = 11
      if (bytes.length < 11) return;
      if (bytes[0] != 0x01) return; // 版本检查
      if (bytes[1] != 0x02) return; // 类型检查

      int offset = 2;

      // 解析 toDeviceId
      final toDeviceIdLen = ByteData.sublistView(bytes, offset, offset + 4)
          .getUint32(0);
      offset += 4;
      // toDeviceId 在 Client 端不需要，跳过
      offset += toDeviceIdLen;

      // 解析 requestId
      final requestIdLen = ByteData.sublistView(bytes, offset, offset + 4)
          .getUint32(0);
      offset += 4;
      final requestId = utf8.decode(
          bytes.sublist(offset, offset + requestIdLen));
      offset += requestIdLen;

      // 解析 flags
      final flags = bytes[offset];
      offset += 1;
      final isLast = (flags & 0x01) != 0;

      // 提取 payload
      final payload = Uint8List.sublistView(bytes, offset);

      // ignore: avoid_print
      print('[CLIENT-RECV-BIN] parsed: reqId=$requestId, payloadLen=${payload.length}, isLast=$isLast');

      _binaryChunkController.add(BinaryChunkEvent(
        requestId: requestId,
        data: payload,
        isLast: isLast,
      ));
    } catch (e) {
      _log.warn('handle binary data failed: $e');
    }
  }
}
