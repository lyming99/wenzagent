import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../device/impl/file_transfer_token_manager.dart';
import '../../entity/lan_client.dart';
import '../../entity/lan_device_info.dart';
import '../../entity/lan_message.dart';
import '../../utils/logger.dart';
import '../entity/host_info.dart';
import 'lan_file_cache_service.dart';
import '../lan_host_service.dart';

/// LAN 服务端实现
class LanHostServiceImpl implements LanHostService {
  static final _log = Logger('LanHostService');
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

  /// 心跳检测定时器
  Timer? _heartbeatTimer;
  /// 客户端 ping 超时时间：超过此时间未收到 ping 则判定掉线
  static const Duration _pingTimeout = Duration(seconds: 10);

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

    final handler = shelf.Cascade()
        .add(_webSocketHandler())
        .add(_httpHandler())
        .handler;

    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    _port = _server?.port ?? port; // 使用实际分配的端口

    _startHeartbeatTimer();
    _addSystemMessage('服务端已启动，IP: $_localIp:$_port');
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;
    _stopHeartbeatTimer();

    final channels = List<WebSocketChannel>.from(_clientChannels);
    _clientChannels.clear();
    _clients.clear();

    for (final channel in channels) {
      try {
        await channel.sink.close();
      } catch (e) {
        _log.debug('close channel on stop failed: $e');
      }
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
      } catch (e) {
        _markClientOffline(i, reason: '广播消息失败');
      }
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
    } catch (e) {
      _log.warn('sendToClient failed: $e');
    }
  }

  @override
  void sendToDeviceId(String deviceId, LanMessage message) {
    final idx = _clients.indexWhere((c) => c.deviceId == deviceId);
    if (idx == -1) return;

    final channel = _clientChannels[idx];
    try {
      channel.sink.add(jsonEncode(message.toJson()));
    } catch (e) {
      _log.warn('sendToDeviceId failed: $e');
    }
  }

  @override
  void disconnectClient(String clientId) {
    final idx = _clients.indexWhere((c) => c.id == clientId);
    if (idx == -1) return;

    // 先保存 client 引用和 channel 引用
    final client = _clients[idx];
    final channel = _clientChannels[idx];
    final clientName = client.name;

    try {
      channel.sink.close();
    } catch (e) {
      _log.debug('close channel on disconnect failed: $e');
    }

    // 关闭后重新查找（sink.close 可能同步触发 onDone 已移除 client）
    final newIdx = _clients.indexOf(client);
    if (newIdx == -1) return; // 已被 onDone 移除

    _clients.removeAt(newIdx);
    _clientChannels.remove(channel);
    _addSystemMessage('客户端 ${clientName ?? clientId} 已断开');

    // 广播设备下线
    if (client.deviceId != null && client.deviceId!.isNotEmpty) {
      _broadcastDeviceOffline(LanDeviceInfo.fromLanClient(client));
    }
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
  Future<HostInfo> getHostInfo() async {
    return HostInfo(
      isRunning: _isRunning,
      ip: _localIp,
      port: _port,
      clients: _clients.map((c) => c.toJson()).toList(),
    );
  }

  // ==================== Private ====================

  shelf.Handler _webSocketHandler() {
    return webSocketHandler((WebSocketChannel channel, String? subprotocol) {
      final clientId = _uuid.v4();
      final client = LanClient(id: clientId, connectedAt: DateTime.now());

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
        ),
      );

      channel.stream.listen(
        (data) {
          if (data is String) {
            // 文本消息（现有逻辑）
            try {
              final msg = LanMessage.fromJson(_parseJson(data));
              _handleClientMessage(clientId, msg);
            } catch (e) {
              _log.warn('parse client message failed: $e');
            }
          } else {
            // 二进制消息转发
            _handleBinaryForward(clientId, data);
          }
        },
        onDone: () {
          final disconnectedClient = _clients.firstWhere(
            (c) => c.id == clientId,
            orElse: () => LanClient(id: clientId),
          );
          final clientName = disconnectedClient.name;
          final device = disconnectedClient.deviceId != null &&
                  disconnectedClient.deviceId!.isNotEmpty
              ? LanDeviceInfo.fromLanClient(disconnectedClient)
              : null;
          _clients.removeWhere((c) => c.id == clientId);
          _clientChannels.remove(channel);
          _addSystemMessage('客户端 ${clientName ?? clientId} 已断开');
          // 广播设备下线
          if (device != null) {
            _broadcastDeviceOffline(device);
          }
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
      final path = request.url.path;

      if (request.method == 'POST' && path == 'upload') {
        return await _handleFileUpload(request);
      } else if (request.method == 'GET' && path == 'download') {
        return await _handleFileDownload(request);
      } else if (request.method == 'GET' && path == 'api/devices/online') {
        return await _handleGetOnlineDevices(request);
      } else if (request.method == 'GET' && path == 'file-download') {
        return await _handleRemoteFileDownload(request);
      } else if (request.method == 'POST' && path == 'file-upload') {
        return await _handleRemoteFileUpload(request);
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

      return shelf.Response.ok(jsonEncode({'status': 'ok', 'fileId': fileId}));
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

  /// 处理获取在线设备列表的 HTTP 请求
  Future<shelf.Response> _handleGetOnlineDevices(shelf.Request request) async {
    try {
      // 获取 topic 查询参数（可选）
      final topicFilter = request.url.queryParameters['topic'];

      // 根据 topic 过滤设备
      var filteredClients = _clients;
      if (topicFilter != null && topicFilter.isNotEmpty) {
        filteredClients = _clients
            .where((client) => client.topic == topicFilter)
            .toList();
      }

      final devices = filteredClients.map((client) {
        final info = LanDeviceInfo.fromLanClient(client);
        return info.toMap();
      }).toList();

      return shelf.Response.ok(
        jsonEncode({'devices': devices}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': '$e'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  /// 处理远程文件下载 HTTP 请求
  ///
  /// 通过临时 Token 鉴权，读取目标设备上的指定文件并流式返回。
  /// 支持 Range 头实现断点续传。
  Future<shelf.Response> _handleRemoteFileDownload(shelf.Request request) async {
    final token = request.url.queryParameters['token'];
    if (token == null || token.isEmpty) {
      return shelf.Response.badRequest(body: 'Missing token');
    }

    // 验证并消费 Token
    final transferToken = FileTransferTokenManager.validateAndConsume(token, 'download');
    if (transferToken == null) {
      return shelf.Response.forbidden('Invalid or expired token');
    }

    final filePath = transferToken.filePath;
    final file = File(filePath);

    if (!await file.exists()) {
      return shelf.Response.notFound('File not found');
    }

    final fileSize = await file.length();
    final fileName = filePath.split(Platform.pathSeparator).last;

    // 处理 Range 请求（断点续传）
    final rangeHeader = request.headers['range'];
    if (rangeHeader != null) {
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (match != null) {
        final start = int.parse(match.group(1)!);
        final end = match.group(2) != null && match.group(2)!.isNotEmpty
            ? int.parse(match.group(2)!)
            : fileSize - 1;

        if (start >= fileSize || end >= fileSize || start > end) {
          return shelf.Response(416, headers: {
            'content-range': 'bytes */$fileSize',
          });
        }

        final stream = file.openRead(start, end + 1);
        return shelf.Response(206, body: stream, headers: {
          'content-type': 'application/octet-stream',
          'content-disposition': 'attachment; filename="$fileName"',
          'content-range': 'bytes $start-$end/$fileSize',
          'content-length': '${end - start + 1}',
          'accept-ranges': 'bytes',
        });
      }
    }

    // 全量下载
    final stream = file.openRead();
    return shelf.Response.ok(stream, headers: {
      'content-type': 'application/octet-stream',
      'content-disposition': 'attachment; filename="$fileName"',
      'content-length': '$fileSize',
      'accept-ranges': 'bytes',
    });
  }

  /// 处理远程文件上传 HTTP 请求
  ///
  /// 通过临时 Token 鉴权，将请求体写入目标设备上的指定路径。
  Future<shelf.Response> _handleRemoteFileUpload(shelf.Request request) async {
    final token = request.url.queryParameters['token'];
    if (token == null || token.isEmpty) {
      return shelf.Response.badRequest(body: 'Missing token');
    }

    // 验证并消费 Token
    final transferToken = FileTransferTokenManager.validateAndConsume(token, 'upload');
    if (transferToken == null) {
      return shelf.Response.forbidden('Invalid or expired token');
    }

    final filePath = transferToken.filePath;
    final overwrite = transferToken.overwrite;

    try {
      // 确保父目录存在
      final file = File(filePath);
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      // 检查文件是否已存在
      if (await file.exists() && !overwrite) {
        return shelf.Response(409, body: 'File already exists');
      }

      // 流式写入
      final sink = file.openWrite(mode: FileMode.write);
      int totalBytes = 0;

      try {
        await for (final chunk in request.read()) {
          sink.add(chunk);
          totalBytes += chunk.length;
        }
        await sink.close();
      } catch (e) {
        await sink.close();
        // 清理不完整的文件
        try { await file.delete(); } catch (_) {}
        return shelf.Response.internalServerError(body: 'Write failed: $e');
      }

      return shelf.Response.ok(jsonEncode({
        'status': 'ok',
        'bytesWritten': totalBytes,
        'filePath': filePath,
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return shelf.Response.internalServerError(
        body: 'Upload failed: $e',
      );
    }
  }

  void _handleClientMessage(String clientId, LanMessage msg) {
    msg.fromId ??= clientId;

    // 处理 Client 发来的 ping，更新 lastPingTime
    if (msg.type == LanMessageType.ping) {
      final idx = _clients.indexWhere((c) => c.id == clientId);
      if (idx != -1) {
        _clients[idx] = _clients[idx].copyWith(lastPingTime: DateTime.now());
      }
      return;
    }

    if (msg.type == LanMessageType.clientInfo) {
      if (msg.content == 'heartbeat') {
        _messageController.add(msg);
        return;
      }

      final idx = _clients.indexWhere((c) => c.id == clientId);
      if (idx != -1) {
        final oldDeviceId = _clients[idx].deviceId;
        final newDeviceId = msg.fileName;

        // 断线重连时清理同一 deviceId 的旧连接
        // 注意：移除旧连接后 _clients 列表会变化，需要重新查找索引
        if (newDeviceId != null && newDeviceId.isNotEmpty) {
          _removeStaleClientsWithDeviceId(
            newDeviceId,
            excludeClientId: clientId,
          );
        }

        // 重新查找索引（_removeStaleClientsWithDeviceId 可能已修改 _clients）
        final newIdx = _clients.indexWhere((c) => c.id == clientId);
        if (newIdx == -1) {
          _messageController.add(msg);
          return;
        }

        // 从 content JSON 中解析设备信息
        String? clientIp;
        try {
          final contentData = jsonDecode(msg.content!) as Map<String, dynamic>;
          clientIp = contentData['ip'] as String?;
        } catch (e) {
          _log.debug('parse client ip from content failed: $e');
        }

        _clients[newIdx] = _clients[newIdx].copyWith(
          ip: clientIp,
          name: msg.fromName,
          deviceId: msg.fileName,
          topic: msg.topic,
        );

        // 新设备注册时广播上线通知
        final isNewDevice = (oldDeviceId == null || oldDeviceId.isEmpty) &&
            newDeviceId != null &&
            newDeviceId.isNotEmpty;
        if (isNewDevice) {
          _broadcastDeviceOnline(_clients[newIdx]);
        }
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
        } catch (e) {
          _log.warn('broadcast to client failed: $e');
        }
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
        type == LanMessageType.agentTokenUsageUpdated ||
        type == LanMessageType.agentPermissionChanged ||
        type == LanMessageType.agentSessionCleared ||
        type == LanMessageType.deviceOnline ||
        type == LanMessageType.deviceOffline ||
        type == LanMessageType.deviceInfoChanged ||
        type == LanMessageType.deviceMessage ||
        type == LanMessageType.deviceInfoRequest ||
        type == LanMessageType.deviceInfoResponse;
  }

  /// 定向转发消息
  void _forwardMessage(
    String fromClientId,
    LanMessage msg,
    String? topic,
    String data,
  ) {
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
      } catch (e) {
        _log.debug('parse toDeviceId from content failed: $e');
      }
    }

    if (toDeviceId != null && toDeviceId.isNotEmpty) {
      final idx = _clients.indexWhere((c) => c.deviceId == toDeviceId);
      if (idx != -1 && _clients[idx].id != fromClientId) {
        try {
          _clientChannels[idx].sink.add(data);
        } catch (e) {
          // 转发失败，标记客户端离线
          _markClientOffline(idx, reason: '消息转发失败');
        }
      }
    } else {
      // 没有 toDeviceId，广播给同 topic 的其他客户端
      for (int i = 0; i < _clientChannels.length; i++) {
        if (_clients[i].id == fromClientId) continue;
        if (topic != null && _clients[i].topic != topic) continue;
        try {
          _clientChannels[i].sink.add(data);
        } catch (e) {
          _markClientOffline(i, reason: '消息转发失败');
        }
      }
    }
  }

  void _sendToChannel(WebSocketChannel channel, LanMessage msg) {
    try {
      channel.sink.add(jsonEncode(msg.toJson()));
    } catch (e) {
      _log.warn('send to channel failed: $e');
    }
  }

  void _removeStaleClientsWithDeviceId(
    String deviceId, {
    required String excludeClientId,
  }) {
    // 收集需要踢掉的 client 及其 channel（使用快照避免并发问题）
    final staleEntries = <(LanClient client, WebSocketChannel channel)>[];
    for (int i = 0; i < _clients.length; i++) {
      if (_clients[i].deviceId == deviceId &&
          _clients[i].id != excludeClientId) {
        staleEntries.add((_clients[i], _clientChannels[i]));
      }
    }

    if (staleEntries.isEmpty) return;

    for (final (staleClient, staleChannel) in staleEntries) {
      // 先发送被踢下线消息
      try {
        _sendToChannel(
          staleChannel,
          LanMessage(
            id: _uuid.v4(),
            type: LanMessageType.system,
            content: 'kicked:duplicate_login',
            timestamp: DateTime.now(),
          ),
        );
      } catch (e) {
        _log.debug('send kick message to stale client failed: $e');
      }

      // 按引用移除（避免索引错位）
      _clients.remove(staleClient);
      _clientChannels.remove(staleChannel);

      // 延迟关闭连接，确保消息能被接收
      Future.delayed(const Duration(milliseconds: 100), () {
        try {
          staleChannel.sink.close();
        } catch (e) {
          _log.debug('close stale channel failed: $e');
        }
      });
    }
  }

  /// 广播设备上线事件
  void _broadcastDeviceOnline(LanClient client) {
    final device = LanDeviceInfo.fromLanClient(client);
    final msg = LanMessage(
      id: _uuid.v4(),
      type: LanMessageType.deviceOnline,
      fromId: _myId,
      fromName: 'Host',
      content: jsonEncode(device.toMap()),
      topic: client.topic,
      timestamp: DateTime.now(),
    );
    broadcast(msg);
  }

  /// 广播设备下线事件
  void _broadcastDeviceOffline(LanDeviceInfo device) {
    final msg = LanMessage(
      id: _uuid.v4(),
      type: LanMessageType.deviceOffline,
      fromId: _myId,
      fromName: 'Host',
      content: jsonEncode(device.toMap()),
      timestamp: DateTime.now(),
    );
    // 下线事件广播给所有客户端（需要通知同 topic 的设备）
    final data = jsonEncode(msg.toJson());
    for (int i = 0; i < _clientChannels.length; i++) {
      try {
        _clientChannels[i].sink.add(data);
      } catch (e) {
        _log.warn('broadcast device offline failed: $e');
      }
    }
    _messageController.add(msg);
  }

  void _addSystemMessage(String text) {
    _messageController.add(
      LanMessage(
        id: _uuid.v4(),
        type: LanMessageType.system,
        content: text,
        timestamp: DateTime.now(),
      ),
    );
  }

  // ===== 心跳检测机制 =====

  /// 启动心跳检测定时器
  void _startHeartbeatTimer() {
    _stopHeartbeatTimer();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_isRunning) {
        _stopHeartbeatTimer();
        return;
      }
      _doHeartbeatCheck();
    });
  }

  /// 停止心跳检测定时器
  void _stopHeartbeatTimer() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// 检查所有已注册 Client 的心跳超时
  void _doHeartbeatCheck() {
    final now = DateTime.now();

    // 收集超时的 Client（使用快照避免并发修改问题）
    final timedOutEntries = <({LanClient client, WebSocketChannel? channel})>[];

    for (int i = 0; i < _clients.length; i++) {
      final client = _clients[i];
      // 只对已注册 deviceId 的 Client 做心跳检测
      if (client.deviceId == null || client.deviceId!.isEmpty) continue;

      WebSocketChannel? channel;
      if (i < _clientChannels.length) {
        channel = _clientChannels[i];
      }

      // 检查超时：
      // - 已有 lastPingTime 的客户端，超过 _pingTimeout 未收到 ping 则判定超时
      // - 刚连接的客户端（lastPingTime == null），连接超过 _pingTimeout 才判定超时
      final lastPing = client.lastPingTime;
      if (lastPing != null && now.difference(lastPing) > _pingTimeout) {
        timedOutEntries.add((client: client, channel: channel));
      } else if (lastPing == null && client.connectedAt != null &&
                 now.difference(client.connectedAt!) > _pingTimeout) {
        timedOutEntries.add((client: client, channel: channel));
      }
    }

    // 按对象引用移除超时的 Client
    for (final entry in timedOutEntries) {
      // 先关闭通道（sink.close 可能同步触发 onDone 回调移除 client）
      if (entry.channel != null) {
        try {
          entry.channel!.sink.close();
        } catch (e) {
          _log.debug('close channel on heartbeat timeout failed: $e');
        }
      }

      // 关闭后重新查找索引（sink.close 的 onDone 可能已移除了该 client）
      final idx = _clients.indexOf(entry.client);
      if (idx == -1) continue;

      final clientName = entry.client.name;
      final clientDeviceId = entry.client.deviceId;

      _clients.removeAt(idx);
      if (entry.channel != null) {
        _clientChannels.remove(entry.channel);
      }

      _addSystemMessage('客户端 ${clientName ?? "unknown"} 心跳超时，已断开');

      // 广播设备下线
      if (clientDeviceId != null && clientDeviceId.isNotEmpty) {
        _broadcastDeviceOffline(
          LanDeviceInfo(
            id: clientDeviceId,
            name: entry.client.name ?? '',
            ip: entry.client.ip ?? '',
            status: 'offline',
            connectedAt: entry.client.connectedAt,
          ),
        );
      }
    }
  }

  /// 标记客户端离线并移除
  void _markClientOffline(int clientIndex, {required String reason}) {
    if (clientIndex < 0 || clientIndex >= _clients.length) return;
    if (clientIndex >= _clientChannels.length) return;

    final client = _clients[clientIndex];
    final channel = _clientChannels[clientIndex];
    final clientName = client.name;
    final clientDeviceId = client.deviceId;

    try {
      channel.sink.close();
    } catch (e) {
      _log.debug('close channel on mark offline failed: $e');
    }

    // 关闭后重新查找（sink.close 的 onDone 可能已移除）
    final newIdx = _clients.indexOf(client);
    if (newIdx == -1) return;

    _clients.removeAt(newIdx);
    _clientChannels.remove(channel);

    _addSystemMessage('客户端 ${clientName ?? "unknown"} $reason，已断开');

    if (clientDeviceId != null && clientDeviceId.isNotEmpty) {
      _broadcastDeviceOffline(
        LanDeviceInfo(
          id: clientDeviceId,
          name: client.name ?? '',
          ip: client.ip ?? '',
          status: 'offline',
          connectedAt: client.connectedAt,
        ),
      );
    }
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

  Map<String, dynamic> _parseJson(dynamic data) {
    final str = data is String ? data : String.fromCharCodes(data);
    return jsonDecode(str) as Map<String, dynamic>;
  }

  /// 处理二进制消息转发
  ///
  /// 解析二进制帧头中的 toDeviceId，定向转发给目标设备。
  /// 不解析 payload 内容，直接转发原始字节（零拷贝）。
  ///
  /// 帧格式：
  /// [0]    0x01 版本
  /// [1]    0x02 binaryChunk
  /// [2..5] toDeviceId 长度 (uint32 BE)
  /// [6..M] toDeviceId (UTF-8)
  /// [M+1..] requestId + flags + payload（不解析）
  void _handleBinaryForward(String fromClientId, dynamic data) {
    try {
      final bytes = data is Uint8List
          ? data
          : Uint8List.fromList(data as List<int>);

      // 最小帧头：version(1) + type(1) + toDeviceIdLen(4) = 6
      if (bytes.length < 6) return;
      if (bytes[0] != 0x01) return; // 版本检查
      if (bytes[1] != 0x02) return; // 类型检查

      // 解析 toDeviceId
      final toDeviceIdLen = ByteData.sublistView(bytes, 2, 6).getUint32(0);
      if (bytes.length < 6 + toDeviceIdLen) return;
      final toDeviceId = utf8.decode(bytes.sublist(6, 6 + toDeviceIdLen));

      // ignore: avoid_print
      print('[HOST-BIN-FWD] from=$fromClientId, to=$toDeviceId, totalBytes=${bytes.length}, clients=${_clients.map((c) => c.deviceId).toList()}');

      if (toDeviceId.isEmpty) return;

      // 查找目标设备并转发
      final idx = _clients.indexWhere((c) => c.deviceId == toDeviceId);
      if (idx != -1 && _clients[idx].id != fromClientId) {
        try {
          _clientChannels[idx].sink.add(bytes);
        } catch (e) {
          _log.warn('binary forward to device $toDeviceId failed: $e');
          _markClientOffline(idx, reason: '二进制消息转发失败');
        }
      }
    } catch (e) {
      _log.warn('handle binary forward failed: $e');
    }
  }
}
