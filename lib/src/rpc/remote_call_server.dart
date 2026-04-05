import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../entity/lan_message.dart';
import '../lan/lan_client_service.dart';
import 'rpc_protocol.dart';
import 'rpc_config.dart';

/// RPC 服务端
///
/// 职责：
/// - 接收 RPC 请求并执行本地方法
/// - 管理方法处理器注册
/// - 构造并发送响应消息
class RemoteCallServer {
  final LanClientService _clientService;
  final String _localDeviceId;

  final _uuid = const Uuid();

  /// 同步方法处理器（method -> handler）
  final Map<String, Future<Map<String, dynamic>> Function(Map<String, dynamic>)>
      _handlers = {};

  /// 流式方法处理器（method -> handler）
  final Map<String, Stream<RpcStreamEvent> Function(Map<String, dynamic>)>
      _streamHandlers = {};

  /// Host 级别的处理器（支持处理 getOnlineDevices 等 Host 级别方法）
  Future<Map<String, dynamic>> Function(String method, Map<String, dynamic> params)?
      _hostHandler;

  /// 是否已释放
  bool _disposed = false;

  RemoteCallServer({
    required LanClientService clientService,
    required String localDeviceId,
  })  : _clientService = clientService,
        _localDeviceId = localDeviceId;

  /// 注册同步方法处理器
  void register(
    String method,
    Future<Map<String, dynamic>> Function(Map<String, dynamic> params) handler,
  ) {
    _handlers[method] = handler;
  }

  /// 注册流式方法处理器
  void registerStream(
    String method,
    Stream<RpcStreamEvent> Function(Map<String, dynamic> params) handler,
  ) {
    _streamHandlers[method] = handler;
  }

  /// 取消注册方法处理器
  void unregister(String method) {
    _handlers.remove(method);
    _streamHandlers.remove(method);
  }

  /// 检查方法是否已注册
  bool hasMethod(String method) {
    return _handlers.containsKey(method) || _streamHandlers.containsKey(method);
  }

  /// 设置 Host 级别的 RPC 处理器
  void setHostHandler(
    Future<Map<String, dynamic>> Function(String method, Map<String, dynamic> params)
        handler,
  ) {
    _hostHandler = handler;
  }

  /// 处理收到的 RPC 请求
  Future<void> handleRequest(Map<String, dynamic> payload) async {
    if (_disposed) return;

    try {
      final request = RpcRequest.fromJson(payload);
      final method = request.method;

      // 检查是否发给本机的请求
      if (request.toDeviceId.isNotEmpty && request.toDeviceId != _localDeviceId) {
        return;
      }

      // 检查是否是 Host 级别方法
      if (_isHostMethod(method) && _hostHandler != null) {
        await _handleHostRequest(request);
      } else if (_streamHandlers.containsKey(method)) {
        _handleStreamRequest(request);
      } else if (_handlers.containsKey(method)) {
        await _handleSyncRequest(request);
      } else {
        _sendError(
          request.fromDeviceId,
          request.requestId,
          RpcError(
            code: RpcConfig.errorCodeMethodNotRegistered,
            message: '方法未注册: $method',
          ),
        );
      }
    } catch (e) {
      // 处理失败
    }
  }

  /// 清理资源
  void dispose() {
    _disposed = true;
    _handlers.clear();
    _streamHandlers.clear();
    _hostHandler = null;
  }

  // ===== 私有方法 =====

  /// 判断是否是 Host 级别方法
  bool _isHostMethod(String method) {
    return method == RpcConfig.methodGetOnlineDevices;
  }

  /// 处理 Host 级别请求
  Future<void> _handleHostRequest(RpcRequest request) async {
    try {
      if (_hostHandler != null) {
        final result = await _hostHandler!(request.method, request.params);

        _sendResponse(
          request.fromDeviceId,
          RpcResponse.success(request.requestId, result),
        );
      }
    } catch (e) {
      _sendError(
        request.fromDeviceId,
        request.requestId,
        RpcError(
          code: RpcConfig.errorCodeInternalError,
          message: '处理失败: $e',
        ),
      );
    }
  }

  /// 处理同步请求
  Future<void> _handleSyncRequest(RpcRequest request) async {
    final handler = _handlers[request.method];
    if (handler == null) return;

    try {
      final result = await handler(request.params);

      _sendResponse(
        request.fromDeviceId,
        RpcResponse.success(request.requestId, result),
      );
    } catch (e) {
      _sendError(
        request.fromDeviceId,
        request.requestId,
        RpcError(
          code: RpcConfig.errorCodeInternalError,
          message: '内部错误: $e',
        ),
      );
    }
  }

  /// 处理流式请求
  void _handleStreamRequest(RpcRequest request) {
    final handler = _streamHandlers[request.method];
    if (handler == null) return;

    try {
      final stream = handler(request.params);

      final subscription = stream.listen(
        (event) {
          if (event.isDone) {
            _sendStreamEnd(
              request.fromDeviceId,
              RpcStreamEnd(
                requestId: request.requestId,
                result: event.result,
              ),
            );
          } else if (event.chunk != null) {
            _sendStreamChunk(
              request.fromDeviceId,
              RpcStreamChunk(
                requestId: request.requestId,
                chunk: event.chunk!,
              ),
            );
          }
        },
        onError: (error) {
          _sendError(
            request.fromDeviceId,
            request.requestId,
            RpcError(
              code: RpcConfig.errorCodeInternalError,
              message: '流式处理错误: $error',
            ),
          );
        },
        onDone: () {
          // 流结束
        },
      );

      // 设置超时自动取消订阅
      if (request.timeout > 0) {
        Future.delayed(Duration(milliseconds: request.timeout), () {
          subscription.cancel();
        });
      }
    } catch (e) {
      _sendError(
        request.fromDeviceId,
        request.requestId,
        RpcError(
          code: RpcConfig.errorCodeInternalError,
          message: '流式处理启动失败: $e',
        ),
      );
    }
  }

  /// 发送响应消息
  void _sendResponse(String toDeviceId, RpcResponse response) {
    final message = LanMessage(
      id: _uuid.v4(),
      type: LanMessageType.rpcResponse,
      fromId: _localDeviceId,
      toDeviceId: toDeviceId,
      content: jsonEncode({
        'action': 'rpcResponse',
        'payload': response.toJson(),
      }),
    );

    _clientService.sendLanMessage(message);
  }

  /// 发送流式 chunk 消息
  void _sendStreamChunk(String toDeviceId, RpcStreamChunk chunk) {
    final message = LanMessage(
      id: _uuid.v4(),
      type: LanMessageType.rpcStreamChunk,
      fromId: _localDeviceId,
      toDeviceId: toDeviceId,
      content: jsonEncode({
        'action': 'rpcStreamChunk',
        'payload': chunk.toJson(),
      }),
    );

    _clientService.sendLanMessage(message);
  }

  /// 发送流式结束消息
  void _sendStreamEnd(String toDeviceId, RpcStreamEnd end) {
    final message = LanMessage(
      id: _uuid.v4(),
      type: LanMessageType.rpcStreamEnd,
      fromId: _localDeviceId,
      toDeviceId: toDeviceId,
      content: jsonEncode({
        'action': 'rpcStreamEnd',
        'payload': end.toJson(),
      }),
    );

    _clientService.sendLanMessage(message);
  }

  /// 发送错误消息
  void _sendError(String toDeviceId, String requestId, RpcError error) {
    final message = LanMessage(
      id: _uuid.v4(),
      type: LanMessageType.rpcError,
      fromId: _localDeviceId,
      toDeviceId: toDeviceId,
      content: jsonEncode({
        'action': 'rpcError',
        'payload': {
          'requestId': requestId,
          'error': error.toJson(),
        },
      }),
    );

    _clientService.sendLanMessage(message);
  }
}
