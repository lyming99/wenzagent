import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../entity/lan_client.dart';
import '../../entity/lan_message.dart';
import 'lan_file_cache_service.dart';
import '../lan_host_service.dart';

/// LAN 服务端实现
class LanHostServiceImpl implements LanHostService {
  // 全局单例
  static LanHostServiceImpl? _instance;

  factory LanHostServiceImpl() {
    _instance ??= LanHostServiceImpl._internal();
    return _instance!;
  }

  LanHostServiceImpl._internal();

  static LanHostServiceImpl get instance => _instance ?? LanHostServiceImpl();

  HttpServer? _server;
  final List<LanClient> _clients = [];
  final List<WebSocketChannel> _clientChannels = [];
  bool _isRunning = false;
  String? _localIp;
  int _port = 9090;
  String? _myId;

  final _messageController = StreamController<LanMessage>.broadcast();
  final LanFileCacheService _cacheService = LanFileCacheService();
  final _uuid = const Uuid();

  @override
  bool get isRunning => _isRunning;

  @override
  String? get localIp => _localIp;

  @override
  int get port => _port;

  @override
  List<LanClient> get clients => List.unmodifiable(_clients);

  @override
  Stream<LanMessage> get messageStream => _messageController.stream;

  @override
  Future<void> start({int port = 9090, String? storageDir}) async {
    if (_isRunning) return;
    _isRunning = true;

    _myId ??= _uuid.v4();
    _localIp ??= await _getLocalIp();

    await _cacheService.ensureInitialized(storageDir: storageDir);
    _cacheService.cleanup();

    final handler =
        shelf.Cascade().add(_webSocketHandler()).add(_httpHandler()).handler;

    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    _port = port; // 更新为实际分配的端口

    _addSystemMessage('服务端已启动，IP: $_localIp:$_port');
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;

    final channels = List<WebSocketChannel>.from(_clientChannels);
    _clientChannels.clear();
    _clients.clear();

    for (final channel in channels) {
      try {
        await channel.sink.close();
      } catch (_) {}
    }
    await _server?.close(force: true);
    _server = null;

    _addSystemMessage('服务端已停止');
  }

  @override
  void broadcast(LanMessage message) {
    final data = jsonEncode(message.toJson());
    final topic = message.topic;

    for (int i = 0; i < _clientChannels.length; i++) {
      if (topic != null && topic.isNotEmpty) {
        if (_clients[i].topic != topic) continue;
      }
      try {
        _clientChannels[i].sink.add(data);
      } catch (_) {}
    }
    _messageController.add(message);
  }

  @override
  void sendToClient(String clientId, LanMessage message) {
    final idx = _clients.indexWhere((c) => c.id == clientId);
    if (idx == -1) return;

    final channel = _clientChannels[idx];
    try {
      channel.sink.add(jsonEncode(message.toJson()));
    } catch (_) {}
  }

  @override
  void sendToDeviceId(String deviceId, LanMessage message) {
    final idx = _clients.indexWhere((c) => c.deviceId == deviceId);
    if (idx == -1) return;

    final channel = _clientChannels[idx];
    try {
      channel.sink.add(jsonEncode(message.toJson()));
    } catch (_) {}
  }

  @override
  void disconnectClient(String clientId) {
    final idx = _clients.indexWhere((c) => c.id == clientId);
    if (idx == -1) return;

    try {
      _clientChannels[idx].sink.close();
    } catch (_) {}

    final clientName = _clients[idx].name;
    _clients.removeAt(idx);
    _clientChannels.removeAt(idx);
    _addSystemMessage('客户端 ${clientName ?? clientId} 已断开');
  }

  @override
  Future<String> saveFile(List<int> data, String fileName) async {
    return await _cacheService.saveFile(data, fileName);
  }

  @override
  Future<List<int>?> getFile(String fileId) async {
    return await _cacheService.getFile(fileId);
  }

  @override
  Future<Map<String, dynamic>> getHostInfo() async {
    return {
      'isRunning': _isRunning,
      'ip': _localIp,
      'port': _port,
      'clients': _clients.map((c) => c.toJson()).toList(),
    };
  }

  // ==================== Private ====================

  shelf.Handler _webSocketHandler() {
    return webSocketHandler((WebSocketChannel channel, String? subprotocol) {
      final clientId = _uuid.v4();
      final client = LanClient(
        id: clientId,
        connectedAt: DateTime.now(),
      );

      _clients.add(client);
      _clientChannels.add(channel);

      _sendToChannel(
          channel,
          LanMessage(
            id: _uuid.v4(),
            type: LanMessageType.clientInfo,
            fromId: _myId,
            fromName: 'Host',
            content: 'request_info',
          ));

      channel.stream.listen(
        (data) {
          try {
            final msg = LanMessage.fromJson(_parseJson(data));
            _handleClientMessage(clientId, msg);
          } catch (_) {}
        },
        onDone: () {
          final clientName = _clients
              .firstWhere((c) => c.id == clientId,
                  orElse: () => LanClient(id: clientId))
              .name;
          _clients.removeWhere((c) => c.id == clientId);
          _clientChannels.remove(channel);
          _addSystemMessage('客户端 ${clientName ?? clientId} 已断开');
        },
        onError: (error) {
          _clients.removeWhere((c) => c.id == clientId);
          _clientChannels.remove(channel);
        },
      );
    });
  }

  shelf.Handler _httpHandler() {
    return (shelf.Request request) async {
      if (request.method == 'POST' && request.url.path == 'upload') {
        return await _handleFileUpload(request);
      } else if (request.method == 'GET' && request.url.path == 'download') {
        return await _handleFileDownload(request);
      }
      return shelf.Response.notFound('Not found');
    };
  }

  Future<shelf.Response> _handleFileUpload(shelf.Request request) async {
    try {
      final contentType = request.headers['content-type'] ?? '';
      String? fileName;
      if (contentType.contains('filename=')) {
        final match = RegExp(r'filename="([^"]+)"').firstMatch(contentType);
        fileName = match?.group(1);
      }
      fileName ??= request.headers['x-file-name'] ?? 'unknown';

      final contentLength = request.contentLength;
      final (fileId, fileSize) = await _cacheService.saveFileFromStream(
        request.read(),
        fileName,
        contentLength,
      );

      return shelf.Response.ok(jsonEncode({
        'status': 'ok',
        'fileId': fileId,
      }));
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'status': 'error', 'message': '$e'}),
      );
    }
  }

  Future<shelf.Response> _handleFileDownload(shelf.Request request) async {
    final fileId = request.url.queryParameters['fileId'];
    if (fileId == null) {
      return shelf.Response.badRequest(body: 'Missing fileId');
    }

    final metadata = _cacheService.getMetadata(fileId);
    if (metadata == null) {
      return shelf.Response.notFound('File not found');
    }

    final stream = _cacheService.getFileStream(fileId);
    if (stream == null) {
      return shelf.Response.notFound('File not found');
    }

    return shelf.Response.ok(
      stream,
      headers: {
        'content-type': 'application/octet-stream',
        'content-disposition': 'attachment; filename="${metadata.fileName}"',
        'content-length': '${metadata.fileSize}',
      },
    );
  }

  void _handleClientMessage(String clientId, LanMessage msg) {
    msg.fromId ??= clientId;

    if (msg.type == LanMessageType.clientInfo) {
      if (msg.content == 'heartbeat') {
        _messageController.add(msg);
        return;
      }

      final idx = _clients.indexWhere((c) => c.id == clientId);
      if (idx != -1) {
        final newDeviceId = msg.fileName;

        // 断线重连时清理同一 deviceId 的旧连接
        if (newDeviceId != null && newDeviceId.isNotEmpty) {
          _removeStaleClientsWithDeviceId(newDeviceId, excludeClientId: clientId);
        }

        _clients[idx] = _clients[idx].copyWith(
          ip: msg.content,
          name: msg.fromName,
          deviceId: msg.fileName,
          topic: msg.topic,
        );
      }
      _messageController.add(msg);
      return;
    }

    final data = jsonEncode(msg.toJson());
    final client = _clients.firstWhere((c) => c.id == clientId);
    final topic = client.topic;

    // 检查是否需要定向转发
    if (_needsForwarding(msg)) {
      _forwardMessage(clientId, msg, topic, data);
    } else {
      // 广播给同 topic 的其他客户端
      for (int i = 0; i < _clientChannels.length; i++) {
        if (_clients[i].id == client.id) continue;
        if (_clients[i].topic != topic) continue;
        try {
          _clientChannels[i].sink.add(data);
        } catch (_) {}
      }
    }

    _messageController.add(msg);
  }

  /// 判断消息是否需要定向转发
  bool _needsForwarding(LanMessage message) {
    final type = message.type;
    return type == LanMessageType.rpcRequest ||
        type == LanMessageType.rpcResponse ||
        type == LanMessageType.rpcStreamChunk ||
        type == LanMessageType.rpcStreamEnd ||
        type == LanMessageType.rpcError ||
        type == LanMessageType.agentStatusChanged ||
        type == LanMessageType.agentMessageStatusChanged ||
        type == LanMessageType.agentPermissionChanged;
  }

  /// 定向转发消息
  void _forwardMessage(
      String fromClientId, LanMessage msg, String? topic, String data) {
    // 优先检查消息顶层的 toDeviceId
    String? toDeviceId = msg.toDeviceId;

    // 如果顶层没有，尝试从 content 中解析
    if ((toDeviceId == null || toDeviceId.isEmpty) &&
        msg.content != null &&
        msg.content!.isNotEmpty) {
      try {
        final contentData = jsonDecode(msg.content!) as Map<String, dynamic>;
        final payload = contentData['payload'] as Map<String, dynamic>?;
        toDeviceId = payload?['toDeviceId'] as String?;
      } catch (_) {}
    }

    if (toDeviceId != null && toDeviceId.isNotEmpty) {
      final idx = _clients.indexWhere((c) => c.deviceId == toDeviceId);
      if (idx != -1 && _clients[idx].id != fromClientId) {
        try {
          _clientChannels[idx].sink.add(data);
        } catch (e) {
          // 转发失败
        }
      }
    } else {
      // 没有 toDeviceId，广播给同 topic 的其他客户端
      for (int i = 0; i < _clientChannels.length; i++) {
        if (_clients[i].id == fromClientId) continue;
        if (topic != null && _clients[i].topic != topic) continue;
        try {
          _clientChannels[i].sink.add(data);
        } catch (_) {}
      }
    }
  }

  void _sendToChannel(WebSocketChannel channel, LanMessage msg) {
    try {
      channel.sink.add(jsonEncode(msg.toJson()));
    } catch (_) {}
  }

  void _removeStaleClientsWithDeviceId(String deviceId,
      {required String excludeClientId}) {
    final staleIndices = <int>[];
    for (int i = 0; i < _clients.length; i++) {
      if (_clients[i].deviceId == deviceId && _clients[i].id != excludeClientId) {
        staleIndices.add(i);
      }
    }

    if (staleIndices.isEmpty) return;

    for (final idx in staleIndices.reversed) {
      final staleChannel = _clientChannels[idx];
      // 先发送被踢下线消息
      try {
        _sendToChannel(staleChannel, LanMessage(
          id: _uuid.v4(),
          type: LanMessageType.system,
          content: 'kicked:duplicate_login',
          timestamp: DateTime.now(),
        ));
      } catch (_) {}
      _clients.removeAt(idx);
      _clientChannels.removeAt(idx);
      // 延迟关闭连接，确保消息能被接收
      Future.delayed(const Duration(milliseconds: 100), () {
        try {
          staleChannel.sink.close();
        } catch (_) {}
      });
    }
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

  Map<String, dynamic> _parseJson(dynamic data) {
    final str = data is String ? data : String.fromCharCodes(data);
    return jsonDecode(str) as Map<String, dynamic>;
  }
}
