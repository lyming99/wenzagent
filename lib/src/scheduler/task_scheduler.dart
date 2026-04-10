import 'dart:async';

import '../persistence/entities/scheduled_task_entity.dart';
import '../scheduler/cron_expression.dart';

/// 定时任务调度器
///
/// 基于 Timer.periodic(1秒) 的轮询调度器。
/// 负责检测到期任务并触发执行回调。
///
/// 职责边界：
/// - 调度检测（时间到了没）
/// - 下次执行时间计算
/// - 执行状态管理（防重入、连续失败记录）
///
/// 不负责：
/// - 持久化（由上层 ScheduledTaskManager 负责）
/// - 具体执行逻辑（通过 onExecute 回调）
class TaskScheduler {
  /// 任务执行回调
  ///
  /// [task] 到期的任务
  /// 返回是否执行成功
  Future<bool> Function(AiScheduledTaskEntity task)? onExecute;

  /// 任务状态变更回调（用于上层持久化）
  ///
  /// 每次执行后调用，上层应将更新后的 task 持久化到 Hive
  void Function(AiScheduledTaskEntity task)? onTaskUpdated;

  Timer? _timer;
  bool _running = false;

  /// 已注册的任务（taskId -> task）
  final Map<String, AiScheduledTaskEntity> _tasks = {};

  /// 正在执行中的任务 ID 集合（防重入）
  final Set<String> _executingTasks = {};

  /// 最大执行超时标记（超过此时间的任务标记为 timeout）
  static const Duration _maxExecutionDuration = Duration(minutes: 10);

  /// 正在执行的任务开始时间
  final Map<String, DateTime> _executionStartTimes = {};

  /// 启动调度器
  ///
  /// [tasks] 初始任务列表（通常从数据库加载的已启用任务）
  void start(List<AiScheduledTaskEntity> tasks) {
    if (_running) return;

    for (final task in tasks) {
      _ensureNextExecutionAt(task);
      _tasks[task.uuid] = task;
    }

    _running = true;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  /// 停止调度器
  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _tasks.clear();
    _executingTasks.clear();
    _executionStartTimes.clear();
  }

  /// 添加任务
  void addTask(AiScheduledTaskEntity task) {
    _ensureNextExecutionAt(task);
    _tasks[task.uuid] = task;
  }

  /// 移除任务
  void removeTask(String taskId) {
    _tasks.remove(taskId);
    _executingTasks.remove(taskId);
    _executionStartTimes.remove(taskId);
  }

  /// 更新任务
  void updateTask(AiScheduledTaskEntity task) {
    // 重新计算下次执行时间
    _ensureNextExecutionAt(task);
    _tasks[task.uuid] = task;
  }

  /// 是否运行中
  bool get isRunning => _running;

  /// 已注册任务数
  int get scheduledCount => _tasks.length;

  /// 执行中的任务数
  int get executingCount => _executingTasks.length;

  /// 每秒 tick
  void _tick() {
    final now = DateTime.now();
    final toExecute = <AiScheduledTaskEntity>[];

    // ① 检查超时的执行中任务
    final timedOut = <String>[];
    for (final entry in _executionStartTimes.entries) {
      if (now.difference(entry.value) > _maxExecutionDuration) {
        timedOut.add(entry.key);
      }
    }
    for (final taskId in timedOut) {
      _executingTasks.remove(taskId);
      _executionStartTimes.remove(taskId);
      print('[TaskScheduler] 任务执行超时: $taskId');
    }

    // ② 遍历查找到期任务
    for (final task in _tasks.values) {
      // 跳过无效任务
      if (!task.isEnabled) continue;
      if (task.isExpired) {
        _autoDisable(task, '任务已过期');
        continue;
      }
      if (!task.isStarted) continue;

      // 确保有下次执行时间
      if (task.nextExecutionAt == null) {
        final updated = _ensureNextExecutionAt(task);
        _tasks[task.uuid] = updated;
        onTaskUpdated?.call(updated);
        continue;
      }

      // 正在执行中 → 跳过（防重入）
      if (_executingTasks.contains(task.uuid)) continue;

      // 到期 → 收集
      if (!now.isBefore(task.nextExecutionAt!)) {
        toExecute.add(task);
      }
    }

    // ③ 异步执行到期任务
    for (final task in toExecute) {
      _executeTask(task);
    }
  }

  /// 执行单个任务
  Future<void> _executeTask(AiScheduledTaskEntity task) async {
    if (onExecute == null) return;

    // 标记为执行中
    _executingTasks.add(task.uuid);
    _executionStartTimes[task.uuid] = DateTime.now();

    try {
      final success = await onExecute!(task);

      final now = DateTime.now();
      AiScheduledTaskEntity updated;

      if (success) {
        // 执行成功
        updated = task.copyWith(
          lastExecutedAt: now,
          lastExecutionResult: 'success',
          lastExecutionError: null,
          consecutiveFailures: 0,
          updateTime: now,
        );

        // 一次性任务 → 执行成功后禁用
        if (task.repeatType == RepeatType.once) {
          updated = updated.copyWith(enabled: 0);
          _tasks.remove(task.uuid);
          onTaskUpdated?.call(updated);
          return;
        }

        // 计算下次执行时间
        updated = _ensureNextExecutionAt(updated);

        // 如果下次执行时间超出 endAt → 禁用
        if (updated.endAt != null &&
            updated.nextExecutionAt != null &&
            updated.nextExecutionAt!.isAfter(updated.endAt!)) {
          updated = updated.copyWith(enabled: 0);
          _tasks.remove(task.uuid);
        }
      } else {
        // 执行失败
        final failures = task.consecutiveFailures + 1;
        updated = task.copyWith(
          lastExecutedAt: now,
          lastExecutionResult: 'failed',
          consecutiveFailures: failures,
          updateTime: now,
        );

        // 连续失败超限 → 自动禁用
        if (updated.maxConsecutiveFailures > 0 &&
            failures >= updated.maxConsecutiveFailures) {
          print(
              '[TaskScheduler] 任务连续失败 $failures 次，自动禁用: ${task.name}');
          updated = updated.copyWith(
            enabled: 0,
            lastExecutionError: '连续失败 $failures 次，自动禁用',
          );
          _tasks.remove(task.uuid);
        } else {
          // 仍然计算下次执行时间（下次再试）
          updated = _ensureNextExecutionAt(updated);
        }
      }

      // 更新内存中的任务
      if (_tasks.containsKey(task.uuid)) {
        _tasks[task.uuid] = updated;
      }

      // 通知上层持久化
      onTaskUpdated?.call(updated);
    } catch (e) {
      print('[TaskScheduler] 任务执行异常: ${task.uuid}, $e');

      final updated = task.copyWith(
        lastExecutedAt: DateTime.now(),
        lastExecutionResult: 'failed',
        lastExecutionError: e.toString(),
        consecutiveFailures: task.consecutiveFailures + 1,
        updateTime: DateTime.now(),
      );

      if (_tasks.containsKey(task.uuid)) {
        _tasks[task.uuid] = updated;
      }
      onTaskUpdated?.call(updated);
    } finally {
      _executingTasks.remove(task.uuid);
      _executionStartTimes.remove(task.uuid);
    }
  }

  /// 确保任务有 nextExecutionAt
  AiScheduledTaskEntity _ensureNextExecutionAt(AiScheduledTaskEntity task) {
    if (task.nextExecutionAt != null &&
        DateTime.now().isBefore(task.nextExecutionAt!)) {
      return task; // 仍然有效
    }

    final now = DateTime.now();

    if (task.scheduleType == ScheduleType.cron) {
      try {
        final cron = CronExpression.parse(task.scheduleExpression);
        // 基于上次执行时间或 startAt 或当前时间计算
        final base = task.lastExecutedAt ?? task.startAt ?? now;
        final next = cron.next(base);
        return task.copyWith(nextExecutionAt: next);
      } catch (e) {
        print('[TaskScheduler] Cron 解析失败: ${task.scheduleExpression}, $e');
        return task.copyWith(
          enabled: 0,
          lastExecutionError: 'Cron 表达式非法: $e',
          updateTime: now,
        );
      }
    } else {
      // interval 模式
      try {
        final duration = IsoDuration.parse(task.scheduleExpression);
        final base = task.lastExecutedAt ?? task.startAt ?? now;
        return task.copyWith(nextExecutionAt: duration.next(base));
      } catch (e) {
        print(
            '[TaskScheduler] Duration 解析失败: ${task.scheduleExpression}, $e');
        return task.copyWith(
          enabled: 0,
          lastExecutionError: 'Duration 表达式非法: $e',
          updateTime: now,
        );
      }
    }
  }

  /// 自动禁用过期任务
  void _autoDisable(AiScheduledTaskEntity task, String reason) {
    final updated = task.copyWith(
      enabled: 0,
      lastExecutionError: reason,
      updateTime: DateTime.now(),
    );
    _tasks.remove(task.uuid);
    onTaskUpdated?.call(updated);
  }
}
