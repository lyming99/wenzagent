import 'dart:async';

/// 取消令牌
///
/// 用于取消长时间运行的操作。
class CancellationToken {
  bool _isCancelled = false;
  final _cancelController = StreamController<void>.broadcast();

  /// 是否已取消
  bool get isCancelled => _isCancelled;

  /// 取消操作
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _cancelController.add(null);
  }

  /// 取消事件流
  Stream<void> get onCancel => _cancelController.stream;

  /// 释放资源
  void dispose() {
    _cancelController.close();
  }
}
