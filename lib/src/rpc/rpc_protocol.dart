/// RPC 请求
class RpcRequest {
  final String requestId;
  final String method;
  final Map<String, dynamic> params;
  final String fromSpaceId;
  final String toSpaceId;
  final int timeout;

  RpcRequest({
    required this.requestId,
    required this.method,
    required this.params,
    required this.fromSpaceId,
    required this.toSpaceId,
    this.timeout = 30000,
  });

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'method': method,
        'params': params,
        'fromSpaceId': fromSpaceId,
        'toSpaceId': toSpaceId,
        'timeout': timeout,
      };

  factory RpcRequest.fromJson(Map<String, dynamic> json) => RpcRequest(
        requestId: json['requestId'] as String,
        method: json['method'] as String,
        params: json['params'] as Map<String, dynamic>? ?? {},
        fromSpaceId: json['fromSpaceId'] as String,
        toSpaceId: json['toSpaceId'] as String,
        timeout: json['timeout'] as int? ?? 30000,
      );
}

/// RPC 响应
class RpcResponse {
  final String requestId;
  final bool success;
  final Map<String, dynamic>? result;
  final RpcError? error;

  RpcResponse({
    required this.requestId,
    required this.success,
    this.result,
    this.error,
  });

  /// 成功响应
  factory RpcResponse.success(String requestId, Map<String, dynamic> result) {
    return RpcResponse(
      requestId: requestId,
      success: true,
      result: result,
    );
  }

  /// 失败响应
  factory RpcResponse.error(String requestId, RpcError error) {
    return RpcResponse(
      requestId: requestId,
      success: false,
      error: error,
    );
  }

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'success': success,
        if (result != null) 'result': result,
        if (error != null) 'error': error!.toJson(),
      };

  factory RpcResponse.fromJson(Map<String, dynamic> json) => RpcResponse(
        requestId: json['requestId'] as String,
        success: json['success'] as bool,
        result: json['result'] as Map<String, dynamic>?,
        error: json['error'] != null
            ? RpcError.fromJson(json['error'] as Map<String, dynamic>)
            : null,
      );
}

/// RPC 错误
class RpcError {
  final int code;
  final String message;

  RpcError({
    required this.code,
    required this.message,
  });

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
      };

  factory RpcError.fromJson(Map<String, dynamic> json) => RpcError(
        code: json['code'] as int,
        message: json['message'] as String,
      );
}

/// RPC 流式 chunk
class RpcStreamChunk {
  final String requestId;
  final String chunk;

  RpcStreamChunk({
    required this.requestId,
    required this.chunk,
  });

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'chunk': chunk,
      };

  factory RpcStreamChunk.fromJson(Map<String, dynamic> json) => RpcStreamChunk(
        requestId: json['requestId'] as String,
        chunk: json['chunk'] as String,
      );
}

/// RPC 流式结束
class RpcStreamEnd {
  final String requestId;
  final Map<String, dynamic>? result;

  RpcStreamEnd({
    required this.requestId,
    this.result,
  });

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        if (result != null) 'result': result,
      };

  factory RpcStreamEnd.fromJson(Map<String, dynamic> json) => RpcStreamEnd(
        requestId: json['requestId'] as String,
        result: json['result'] as Map<String, dynamic>?,
      );
}

/// RPC 流式事件
class RpcStreamEvent {
  final String? chunk;
  final Map<String, dynamic>? result;
  final bool isDone;

  RpcStreamEvent({
    this.chunk,
    this.result,
    this.isDone = false,
  });

  factory RpcStreamEvent.chunk(String chunk) {
    return RpcStreamEvent(chunk: chunk, isDone: false);
  }

  factory RpcStreamEvent.done(Map<String, dynamic> result) {
    return RpcStreamEvent(result: result, isDone: true);
  }
}

/// RPC 异常
class RpcException implements Exception {
  final int code;
  final String message;

  RpcException(this.code, this.message);

  @override
  String toString() => 'RpcException: [$code] $message';
}
