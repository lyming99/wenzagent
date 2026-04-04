import '../agent_state.dart';
import 'cancellation_token.dart';
import 'message_queue.dart';

/// 流式响应
class StreamResponse {
  final String? content;
  final bool isDone;
  final String? error;

  const StreamResponse({
    this.content,
    this.isDone = false,
    this.error,
  });

  factory StreamResponse.chunk(String content) {
    return StreamResponse(content: content, isDone: false);
  }

  factory StreamResponse.done() {
    return const StreamResponse(isDone: true);
  }

  factory StreamResponse.error(String error) {
    return StreamResponse(error: error, isDone: true);
  }
}

/// 聊天适配器接口
///
/// 定义 Agent 与 AI 模型交互的接口。
/// 具体实现由外部注入。
abstract class IChatAdapter {
  /// 当前会话UUID
  String? get currentSessionUuid;

  /// 当前消息列表
  List<Map<String, dynamic>> get currentMessages;

  /// 当前上下文
  Map<String, dynamic>? get currentContext;

  /// 是否正在流式输出
  bool get isStreaming;

  /// 初始化会话
  Future<void> initSession({
    required String employeeUuid,
    String? sessionUuid,
  });

  /// 流式发送消息
  Stream<StreamResponse> streamMessage(
    Map<String, dynamic> messageData, {
    CancellationToken? cancellationToken,
  });

  /// 停止流式输出
  Future<void> stopStreaming();

  /// 获取会话列表
  Future<List<Map<String, dynamic>>> getSessionsByEmployee(String employeeUuid);

  /// 获取会话消息
  Future<List<Map<String, dynamic>>> getSessionMessages(String sessionUuid);

  /// 创建新会话
  Future<String> createNewSession({required String employeeUuid, String? title});

  /// 切换会话
  Future<void> switchSession(String sessionUuid);

  /// 清空当前会话
  Future<void> clearCurrentSession();

  /// 设置上下文
  void setContext(Map<String, dynamic> contextData);

  /// 清除上下文
  void clearContext();

  /// 更新 Provider 配置
  Future<void> updateProvider(Map<String, dynamic> providerConfig);

  /// 获取 Provider 配置
  Map<String, dynamic>? getProviderConfig();

  /// 更新项目上下文
  Future<void> updateProjectContext(Map<String, dynamic>? projectContext);

  /// 释放资源
  Future<void> dispose();
}

/// 消息处理器状态回调
typedef MessageStatusCallback = void Function(
  String messageId,
  AgentMessageStatus status, {
  String? error,
});

/// 流式消息函数类型
typedef StreamMessageFunc = Stream<StreamResponse> Function(
  String messageId,
  Map<String, dynamic> messageData, {
  CancellationToken? cancellationToken,
});

/// 消息处理器
///
/// 负责消息的排队、处理、中断等逻辑。
class MessageProcessor {
  final StreamMessageFunc _streamMessage;
  final Future<void> Function() _stopStreaming;

  final MessageQueue _queue = MessageQueue();
  String? _currentProcessingMessageId;
  CancellationToken? _currentCancellationToken;
  bool _disposed = false;

  AgentStatus _status = AgentStatus.idle;

  /// 状态变更回调
  void Function(AgentStatus status)? onStateChanged;

  /// 消息状态变更回调
  MessageStatusCallback? onMessageStatusChanged;

  MessageProcessor({
    required StreamMessageFunc streamMessage,
    required Future<void> Function() stopStreaming,
  })  : _streamMessage = streamMessage,
        _stopStreaming = stopStreaming;

  /// 当前处理中的消息ID
  String? get currentProcessingMessageId => _currentProcessingMessageId;

  /// 排队中的消息ID列表
  List<String> get queuedMessageIds => _queue.messageIds;

  /// 队列长度
  int get queueLength => _queue.length;

  /// 当前状态
  AgentStatus get status => _status;

  /// 提交消息到队列
  Future<void> submitMessage(
    String messageId,
    Map<String, dynamic> messageData, {
    List<Map<String, dynamic>>? recentContext,
  }) async {
    if (_disposed) throw Exception('MessageProcessor 已销毁');

    final item = MessageQueueItem(
      messageId: messageId,
      messageData: messageData,
    );

    _queue.enqueue(item);
    onMessageStatusChanged?.call(messageId, AgentMessageStatus.queued);

    // 如果当前没有在处理，开始处理
    if (_status == AgentStatus.idle) {
      _processNext();
    }
  }

  /// 中断当前处理
  Future<void> interruptCurrentTask() async {
    if (_currentCancellationToken != null) {
      _currentCancellationToken!.cancel();
    }
    await _stopStreaming();

    if (_currentProcessingMessageId != null) {
      onMessageStatusChanged?.call(
        _currentProcessingMessageId!,
        AgentMessageStatus.interrupted,
      );
    }

    _currentProcessingMessageId = null;
    _currentCancellationToken = null;
    _setStatus(AgentStatus.idle);

    // 处理下一条消息
    _processNext();
  }

  /// 撤回消息
  Future<void> revokeMessage(String messageId) async {
    if (_queue.contains(messageId)) {
      _queue.revoke(messageId);
      onMessageStatusChanged?.call(messageId, AgentMessageStatus.revoked);
    }
  }

  /// 设置权限阻塞
  void setPermissionBlocked(String? requestId) {
    if (requestId != null) {
      _setStatus(AgentStatus.waitingPermission);
    } else {
      _setStatus(AgentStatus.processing);
    }
  }

  /// 释放资源
  void dispose() {
    _disposed = true;
    _queue.clear();
    _currentCancellationToken?.cancel();
    _currentCancellationToken = null;
    _currentProcessingMessageId = null;
  }

  // ===== 私有方法 =====

  void _processNext() {
    if (_disposed) return;

    final item = _queue.dequeue();
    if (item == null) {
      _setStatus(AgentStatus.idle);
      return;
    }

    _currentProcessingMessageId = item.messageId;
    _currentCancellationToken = CancellationToken();
    _setStatus(AgentStatus.processing);
    onMessageStatusChanged?.call(item.messageId, AgentMessageStatus.processing);

    _processMessage(item.messageId, item.messageData);
  }

  Future<void> _processMessage(
    String messageId,
    Map<String, dynamic> messageData,
  ) async {
    try {
      final stream = _streamMessage(
        messageId,
        messageData,
        cancellationToken: _currentCancellationToken,
      );

      bool hasContent = false;

      await for (final response in stream) {
        if (_currentCancellationToken?.isCancelled ?? false) {
          break;
        }

        if (response.error != null) {
          onMessageStatusChanged?.call(
            messageId,
            AgentMessageStatus.failed,
            error: response.error,
          );
          _finishProcessing();
          return;
        }

        if (!hasContent && response.content != null && response.content!.isNotEmpty) {
          hasContent = true;
          _setStatus(AgentStatus.streaming);
        }

        if (response.isDone) {
          onMessageStatusChanged?.call(messageId, AgentMessageStatus.completed);
          _finishProcessing();
          return;
        }
      }

      // 流正常结束
      if (!_disposed && _currentProcessingMessageId == messageId) {
        onMessageStatusChanged?.call(messageId, AgentMessageStatus.completed);
        _finishProcessing();
      }
    } catch (e) {
      if (!_disposed && _currentProcessingMessageId == messageId) {
        onMessageStatusChanged?.call(
          messageId,
          AgentMessageStatus.failed,
          error: e.toString(),
        );
        _finishProcessing();
      }
    }
  }

  void _finishProcessing() {
    _currentProcessingMessageId = null;
    _currentCancellationToken?.dispose();
    _currentCancellationToken = null;
    _setStatus(AgentStatus.idle);

    // 处理下一条消息
    if (!_disposed) {
      Future.microtask(() => _processNext());
    }
  }

  void _setStatus(AgentStatus newStatus) {
    if (_status == newStatus) return;
    _status = newStatus;
    onStateChanged?.call(newStatus);
  }
}
