import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../entity/lan_message.dart';
import '../lan/lan_client_service.dart';
import '../utils/logger.dart';
import 'rpc_protocol.dart';
import 'rpc_config.dart';

/// RPC 客户端管理器
///
/// 职责：
/// - 发起 RPC 调用并管理响应
/// - 自动管理 requestId、超时、错误传递
/// - 支持同步调用和流式调用
class RemoteCallManager {
  static final _log = Logger('RemoteCallManager');
  final LanClientService _clientService;
  final String _localDeviceId;

  final _uuid = const Uuid();

  /// 待处理的请求（requestId -> Completer）
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};

  /// 待处理的流式请求（requestId -> StreamController）
  final Map<String, StreamController<RpcStreamEvent>> _pendingStreams = {};

  /// 超时定时器（requestId -> Timer）
  final Map<String, Timer> _timeoutTimers = {};

  /// 是否已释放
  bool _disposed = false;

  RemoteCallManager({
    required LanClientService clientService,
    required String localDeviceId,
  })  : _clientService = clientService,
        _localDeviceId = localDeviceId;

  /// 发起同步 RPC 调用
  Future<T> invoke<T>(
    String method,
    Map<String, dynamic> params, {
    required String toDeviceId,
    int timeout = RpcConfig.defaultTimeout,
  }) async {
    if (_disposed) {
      throw Exception('RemoteCallManager 已释放');
    }

    final requestId = _uuid.v4();

    // 创建请求
    final request = RpcRequest(
      requestId: requestId,
      method: method,
      params: params,
      fromDeviceId: _localDeviceId,
      toDeviceId: toDeviceId,
      timeout: timeout,
    );

    // 发送消息
    _sendRpcRequest(request);

    // 创建 Completer
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[requestId] = completer;

    // 设置超时
    _setupTimeout(requestId, timeout);

    try {
      final result = await completer.future;
      return result as T;
    } catch (e) {
      _cleanupRequest(requestId);
      rethrow;
    }
  }

  /// 发起流式 RPC 调用
  ///
  /// 返回的 Stream 在首个事件中携带 [requestId]，
  /// 调用方可通过 [requestId] 关联二进制通道的数据。
  ///
  /// **重要**：如果需要提前知道 requestId（例如在二进制帧到达前开始过滤），
  /// 请使用 [invokeStreamWithId]，它返回 (requestId, stream) 对。
  Stream<RpcStreamEvent> invokeStream(
    String method,
    Map<String, dynamic> params, {
    required String toDeviceId,
    int timeout = RpcConfig.streamTimeout,
  }) {
    final result = invokeStreamWithId(
      method,
      params,
      toDeviceId: toDeviceId,
      timeout: timeout,
    );
    return result.stream;
  }

  /// 发起流式 RPC 调用，同时返回 requestId 和 stream
  ///
  /// 与 [invokeStream] 不同，此方法在发送 RPC 请求前就生成 requestId，
  /// 允许调用方在二进制帧到达前就开始按 requestId 过滤。
  ///
  /// 这解决了 downloadFileByMeta 中的时序问题：
  /// 二进制帧可能在第一个 RPC 文本事件到达之前就已到达，
  /// 如果此时 requestId 尚未设置，帧数据会被静默丢弃。
  ({String requestId, Stream<RpcStreamEvent> stream}) invokeStreamWithId(
    String method,
    Map<String, dynamic> params, {
    required String toDeviceId,
    int timeout = RpcConfig.streamTimeout,
  }) {
    if (_disposed) {
      throw Exception('RemoteCallManager 已释放');
    }

    final requestId = _uuid.v4();

    // 创建 StreamController（在发送请求之前，确保 listener 已就绪）
    final controller = StreamController<RpcStreamEvent>(
      onCancel: () => _cleanupRequest(requestId),
    );
    _pendingStreams[requestId] = controller;

    // 创建请求并发送
    final request = RpcRequest(
      requestId: requestId,
      method: method,
      params: params,
      fromDeviceId: _localDeviceId,
      toDeviceId: toDeviceId,
      timeout: timeout,
    );

    _sendRpcRequest(request);

    // 设置超时（timeout <= 0 表示不设置超时，用于长连接流）
    if (timeout > 0) {
      _setupTimeout(requestId, timeout);
    }

    return (requestId: requestId, stream: controller.stream);
  }

  /// 处理收到的 RPC 响应
  void handleResponse(Map<String, dynamic> payload) {
    if (_disposed) return;

    try {
      final response = RpcResponse.fromJson(payload);
      final completer = _pendingRequests[response.requestId];

      if (completer != null && !completer.isCompleted) {
        _timeoutTimers.remove(response.requestId)?.cancel();

        completer.complete({
          'success': response.success,
          'result': response.result,
          'error': response.error?.toJson(),
        });

        _pendingRequests.remove(response.requestId);
      }
    } catch (e) {
      _log.warn('handle RPC response failed: $e');
    }
  }

  /// 处理收到的流式 chunk
  void handleStreamChunk(Map<String, dynamic> payload) {
    if (_disposed) return;

    try {
      final chunk = RpcStreamChunk.fromJson(payload);
      final controller = _pendingStreams[chunk.requestId];

      if (controller != null && !controller.isClosed) {
        // 将 requestId 注入事件，供调用方关联二进制通道
        controller.add(
          RpcStreamEvent.chunk(chunk.chunk, requestId: chunk.requestId),
        );
      }
    } catch (e) {
      _log.warn('handle RPC stream chunk failed: $e');
    }
  }

  /// 处理收到的流式结束
  void handleStreamEnd(Map<String, dynamic> payload) {
    if (_disposed) return;

    try {
      final end = RpcStreamEnd.fromJson(payload);
      final controller = _pendingStreams[end.requestId];

      if (controller != null && !controller.isClosed) {
        _timeoutTimers.remove(end.requestId)?.cancel();

        controller.add(
          RpcStreamEvent.done(end.result ?? {}, requestId: end.requestId),
        );
        controller.close();

        _pendingStreams.remove(end.requestId);
      }
    } catch (e) {
      _log.warn('handle RPC stream end failed: $e');
    }
  }

  /// 处理收到的 RPC 错误
  void handleError(Map<String, dynamic> payload) {
    if (_disposed) return;

    try {
      final requestId = payload['requestId'] as String?;
      final errorData = payload['error'] as Map<String, dynamic>?;

      if (requestId == null) return;

      // 处理同步请求的错误
      final completer = _pendingRequests[requestId];
      if (completer != null && !completer.isCompleted) {
        _timeoutTimers.remove(requestId)?.cancel();

        final error = errorData != null
            ? RpcException(
                errorData['code'] as int? ?? RpcConfig.errorCodeInternalError,
                errorData['message'] as String? ?? '未知错误',
              )
            : RpcException(RpcConfig.errorCodeInternalError, '未知错误');

        completer.completeError(error);
        _pendingRequests.remove(requestId);
        return;
      }

      // 处理流式请求的错误
      final controller = _pendingStreams[requestId];
      if (controller != null && !controller.isClosed) {
        _timeoutTimers.remove(requestId)?.cancel();

        final error = errorData != null
            ? RpcException(
                errorData['code'] as int? ?? RpcConfig.errorCodeInternalError,
                errorData['message'] as String? ?? '未知错误',
              )
            : RpcException(RpcConfig.errorCodeInternalError, '未知错误');

        controller.addError(error);
        controller.close();
        _pendingStreams.remove(requestId);
      }
    } catch (e) {
      _log.warn('handle RPC error failed: $e');
    }
  }

  /// 释放资源
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    for (final timer in _timeoutTimers.values) {
      timer.cancel();
    }
    _timeoutTimers.clear();

    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(
            Exception('RemoteCallManager 已释放'));
      }
    }
    _pendingRequests.clear();

    for (final controller in _pendingStreams.values) {
      if (!controller.isClosed) {
        controller.addError(
            Exception('RemoteCallManager 已释放'));
        controller.close();
      }
    }
    _pendingStreams.clear();
  }

  // ===== 内部方法 =====

  void _sendRpcRequest(RpcRequest request) {
    final message = LanMessage(
      id: _uuid.v4(),
      type: LanMessageType.rpcRequest,
      fromId: _localDeviceId,
      toDeviceId: request.toDeviceId,
      content: jsonEncode({
        'action': 'rpcRequest',
        'payload': request.toJson(),
      }),
    );

    _clientService.sendLanMessage(message);
  }

  /// 设置超时
  void _setupTimeout(String requestId, int timeoutMs) {
    final timer = Timer(Duration(milliseconds: timeoutMs), () {
      _cleanupRequest(requestId);

      // 尝试完成 completer（同步调用）
      final completer = _pendingRequests[requestId];
      if (completer != null && !completer.isCompleted) {
        completer.completeError(
            TimeoutException('RPC 调用超时', Duration(milliseconds: timeoutMs)));
        _pendingRequests.remove(requestId);
      }

      // 尝试关闭 controller（流式调用）
      final controller = _pendingStreams[requestId];
      if (controller != null && !controller.isClosed) {
        controller.addError(
            TimeoutException('RPC 流式调用超时', Duration(milliseconds: timeoutMs)));
        controller.close();
        _pendingStreams.remove(requestId);
      }
    });

    _timeoutTimers[requestId] = timer;
  }

  void _cleanupRequest(String requestId) {
    _timeoutTimers.remove(requestId)?.cancel();
    _pendingRequests.remove(requestId);
    final controller = _pendingStreams.remove(requestId);
    if (controller != null && !controller.isClosed) {
      controller.close();
    }
  }
}
