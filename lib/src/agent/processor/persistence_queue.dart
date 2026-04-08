import 'dart:async';

/// 持久化任务类型
enum PersistenceTaskType {
  /// 持久化消息
  message,

  /// 持久化会话
  session,
}

/// 持久化任务
class PersistenceTask {
  /// 任务类型
  final PersistenceTaskType type;

  /// 任务ID（用于日志和调试）
  final String taskId;

  /// 持久化消息的数据
  final Map<String, dynamic>? messageData;

  /// 持久化会话的数据
  final Map<String, dynamic>? sessionData;

  /// 持久化函数
  final Future<void> Function(Map<String, dynamic> data) persistFunc;

  /// 重试次数
  int retryCount;

  /// 最大重试次数
  final int maxRetries;

  /// 创建时间
  final DateTime createdAt;

  PersistenceTask({
    required this.type,
    required this.taskId,
    required this.persistFunc,
    this.messageData,
    this.sessionData,
    this.retryCount = 0,
    this.maxRetries = 3,
  }) : createdAt = DateTime.now();

  /// 获取任务数据
  Map<String, dynamic>? get data {
    switch (type) {
      case PersistenceTaskType.message:
        return messageData;
      case PersistenceTaskType.session:
        return sessionData;
    }
  }

  /// 是否可以重试
  bool get canRetry => retryCount < maxRetries;

  /// 重试
  PersistenceTask retry() {
    return PersistenceTask(
      type: type,
      taskId: taskId,
      persistFunc: persistFunc,
      messageData: messageData,
      sessionData: sessionData,
      retryCount: retryCount + 1,
      maxRetries: maxRetries,
    );
  }
}

/// 持久化队列
///
/// 用于异步处理持久化任务，避免阻塞主流程。
/// 任务按顺序执行，支持重试和错误处理。
class PersistenceQueue {
  /// 任务队列
  final List<PersistenceTask> _queue = [];

  /// 是否正在处理任务
  bool _isProcessing = false;

  /// 是否已销毁
  bool _disposed = false;

  /// 处理锁，防止并发处理
  bool _processingLock = false;

  /// 当前处理的任务
  PersistenceTask? _currentTask;

  /// 统计信息
  int _totalTasks = 0;
  int _completedTasks = 0;
  int _failedTasks = 0;

  /// 任务最终失败回调（重试耗尽后触发）
  void Function(PersistenceTask task, Object error)? onTaskFailed;

  /// 添加消息持久化任务
  ///
  /// [messageData] 消息数据
  /// [persistFunc] 持久化函数
  void addMessageTask(
    Map<String, dynamic> messageData,
    Future<void> Function(Map<String, dynamic> data) persistFunc,
  ) {
    if (_disposed) return;

    final task = PersistenceTask(
      type: PersistenceTaskType.message,
      taskId:
          'msg_${messageData['id']}_${DateTime.now().millisecondsSinceEpoch}',
      messageData: messageData,
      persistFunc: persistFunc,
    );

    _addTask(task);
  }

  /// 添加会话持久化任务
  ///
  /// [sessionData] 会话数据
  /// [persistFunc] 持久化函数
  void addSessionTask(
    Map<String, dynamic> sessionData,
    Future<void> Function(Map<String, dynamic> data) persistFunc,
  ) {
    if (_disposed) return;

    final task = PersistenceTask(
      type: PersistenceTaskType.session,
      taskId:
          'session_${sessionData['uuid']}_${DateTime.now().millisecondsSinceEpoch}',
      sessionData: sessionData,
      persistFunc: persistFunc,
    );

    _addTask(task);
  }

  /// 添加任务到队列
  void _addTask(PersistenceTask task) {
    _queue.add(task);
    _totalTasks++;
    print(
      '[PersistenceQueue] Task added: ${task.type} (${task.taskId}), queue length: ${_queue.length}',
    );

    // 如果当前没有在处理，开始处理
    if (!_isProcessing && !_processingLock) {
      _startProcessing();
    }
  }

  /// 开始处理队列
  void _startProcessing() {
    if (_disposed || _isProcessing || _processingLock) return;

    _isProcessing = true;
    print(
      '[PersistenceQueue] Starting to process queue, ${_queue.length} tasks pending',
    );

    _processNext();
  }

  /// 处理下一个任务
  Future<void> _processNext() async {
    if (_disposed || _processingLock) {
      _isProcessing = false;
      return;
    }

    if (_queue.isEmpty) {
      _isProcessing = false;
      print('[PersistenceQueue] Queue empty, processing stopped');
      return;
    }

    final task = _queue.removeAt(0);
    _currentTask = task;
    _processingLock = true;

    print(
      '[PersistenceQueue] Processing task: ${task.type} (${task.taskId}), retry: ${task.retryCount}/${task.maxRetries}',
    );

    try {
      final data = task.data;
      if (data != null) {
        await task.persistFunc(data);
        _completedTasks++;
        print(
          '[PersistenceQueue] Task completed: ${task.type} (${task.taskId})',
        );
      }
    } catch (e) {
      print(
        '[PersistenceQueue] Task failed: ${task.type} (${task.taskId}), error: $e',
      );

      if (task.canRetry) {
        // 重试
        print(
          '[PersistenceQueue] Retrying task: ${task.type} (${task.taskId}), attempt ${task.retryCount + 1}',
        );
        final retryTask = task.retry();
        // 将重试任务添加到队列头部，优先处理
        _queue.insert(0, retryTask);
      } else {
        // 达到最大重试次数，放弃
        _failedTasks++;
        print(
          '[PersistenceQueue] Task failed permanently: ${task.type} (${task.taskId})',
        );
        // 通知上层任务最终失败
        onTaskFailed?.call(task, e);
      }
    } finally {
      _currentTask = null;
      _processingLock = false;

      // 继续处理下一个任务
      if (!_disposed) {
        Future.microtask(() => _processNext());
      }
    }
  }

  /// 等待所有任务完成（用于测试）
  Future<void> waitForAll({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final stopwatch = Stopwatch()..start();
    while (!_disposed && (_isProcessing || _queue.isNotEmpty)) {
      if (stopwatch.elapsed >= timeout) {
        print(
          '[PersistenceQueue] Wait timeout, ${_queue.length} tasks remaining',
        );
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    stopwatch.stop();
    print(
      '[PersistenceQueue] Wait completed, ${_queue.length} tasks remaining',
    );
  }

  /// 销毁队列
  ///
  /// 等待当前任务完成后停止处理
  Future<void> dispose() async {
    if (_disposed) return;

    print('[PersistenceQueue] Disposing, ${_queue.length} tasks in queue');

    // 等待当前任务完成
    if (_processingLock) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    _disposed = true;
    _isProcessing = false;

    print(
      '[PersistenceQueue] Disposed, statistics: total=$_totalTasks, completed=$_completedTasks, failed=$_failedTasks, remaining=${_queue.length}',
    );
  }

  /// 队列长度
  int get queueLength => _queue.length;

  /// 是否正在处理
  bool get isProcessing => _isProcessing || _processingLock;

  /// 当前任务
  PersistenceTask? get currentTask => _currentTask;

  /// 统计信息
  Map<String, int> get statistics => {
    'total': _totalTasks,
    'completed': _completedTasks,
    'failed': _failedTasks,
    'remaining': _queue.length,
  };
}
