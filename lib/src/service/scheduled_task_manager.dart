import 'dart:async';
import 'dart:convert';

import '../agent/entity/message_input.dart';
import '../agent/i_agent.dart';
import '../agent/impl/agent_impl.dart';
import '../persistence/entities/scheduled_task_entity.dart';
import '../persistence/stores/scheduled_task_store.dart';
import '../scheduler/cron_expression.dart';
import '../scheduler/task_scheduler.dart';
import 'task_executor.dart';

/// 定时任务事件类型
enum ScheduledTaskEventType {
  created,
  updated,
  deleted,
  executed,
  disabled,
}

/// 定时任务事件
class ScheduledTaskEvent {
  final ScheduledTaskEventType type;
  final String taskId;
  final String? employeeId;
  final Map<String, dynamic>? data;

  ScheduledTaskEvent({
    required this.type,
    required this.taskId,
    this.employeeId,
    this.data,
  });

  @override
  String toString() =>
      'ScheduledTaskEvent($type, taskId: $taskId${employeeId != null ? ", employeeId: $employeeId" : ""})';
}

/// 定时任务管理器接口
abstract class ScheduledTaskManager {
  // ===== CRUD =====
  Future<AiScheduledTaskEntity> createTask(AiScheduledTaskEntity task);
  Future<AiScheduledTaskEntity?> getTask(String uuid);
  Future<List<AiScheduledTaskEntity>> getTasks({String? employeeId});
  Future<AiScheduledTaskEntity> updateTask(AiScheduledTaskEntity task);
  Future<void> deleteTask(String uuid);

  // ===== 控制 =====
  Future<void> enableTask(String uuid);
  Future<void> disableTask(String uuid);
  Future<void> triggerTaskNow(String uuid);

  // ===== 生命周期 =====
  Future<void> start();
  Future<void> stop();
  bool get isRunning;

  // ===== 事件 =====
  Stream<ScheduledTaskEvent> get onTaskEvent;
}

/// 定时任务管理器实现
///
/// 组合 Store + Scheduler，提供完整的定时任务生命周期管理。
/// 定时任务触发时通过主 Agent 的 triggerSystemTask 注入 system 消息并触发 LLM 处理。
class ScheduledTaskManagerImpl implements ScheduledTaskManager {
  final ScheduledTaskStore _store;
  final TaskScheduler _scheduler = TaskScheduler();
  final TaskExecutor _taskExecutor = TaskExecutor();

  /// 获取 Agent 实例（由 DeviceClientImpl 注入）
  Future<IAgent?> Function(String employeeId)? getAgent;

  /// 任务执行器（供外部注入配置，如 providerConfig、deliverResult 等）
  TaskExecutor get taskExecutor => _taskExecutor;

  /// 事件广播
  final _eventController =
      StreamController<ScheduledTaskEvent>.broadcast();

  bool _started = false;

  ScheduledTaskManagerImpl({ScheduledTaskStore? store})
      : _store = store ?? ScheduledTaskStore();

  // ===== CRUD =====

  @override
  Future<AiScheduledTaskEntity> createTask(
      AiScheduledTaskEntity task) async {
    final now = DateTime.now();

    // 参数校验
    _validateSchedule(task.scheduleType, task.scheduleExpression);

    final newTask = task.copyWith(
      createTime: now,
      updateTime: now,
    );

    // 计算首次执行时间
    final taskWithNext = _computeFirstExecution(newTask);

    // 持久化
    await _store.save(taskWithNext);

    // 如果调度器已启动，注册到调度器
    if (_started && taskWithNext.isEnabled) {
      _scheduler.addTask(taskWithNext);
    }

    _emit(ScheduledTaskEventType.created, taskWithNext.uuid,
        employeeId: taskWithNext.employeeId,
        data: taskWithNext.toMap());

    return taskWithNext;
  }

  @override
  Future<AiScheduledTaskEntity?> getTask(String uuid) async {
    return _store.find(uuid);
  }

  @override
  Future<List<AiScheduledTaskEntity>> getTasks(
      {String? employeeId}) async {
    if (employeeId != null) {
      return _store.findByEmployee(employeeId);
    }
    return _store.findAll();
  }

  @override
  Future<AiScheduledTaskEntity> updateTask(
      AiScheduledTaskEntity task) async {
    // 参数校验
    _validateSchedule(task.scheduleType, task.scheduleExpression);

    final updated = task.copyWith(updateTime: DateTime.now());

    // 重新计算下次执行时间
    final taskWithNext = _recalcNextExecution(updated);

    await _store.save(taskWithNext);

    if (_started) {
      _scheduler.updateTask(taskWithNext);
    }

    _emit(ScheduledTaskEventType.updated, taskWithNext.uuid,
        employeeId: taskWithNext.employeeId);

    return taskWithNext;
  }

  @override
  Future<void> deleteTask(String uuid) async {
    final task = await _store.find(uuid);
    if (task == null) return;

    await _store.delete(uuid);

    if (_started) {
      _scheduler.removeTask(uuid);
    }

    _emit(ScheduledTaskEventType.deleted, uuid,
        employeeId: task.employeeId);
  }

  // ===== 控制 =====

  @override
  Future<void> enableTask(String uuid) async {
    var task = await _store.find(uuid);
    if (task == null) return;

    task = task.copyWith(enabled: 1, updateTime: DateTime.now());
    task = _recalcNextExecution(task);
    await _store.save(task);

    if (_started) {
      _scheduler.addTask(task);
    }

    _emit(ScheduledTaskEventType.updated, uuid,
        employeeId: task.employeeId);
  }

  @override
  Future<void> disableTask(String uuid) async {
    var task = await _store.find(uuid);
    if (task == null) return;

    task = task.copyWith(enabled: 0, updateTime: DateTime.now());
    await _store.save(task);

    if (_started) {
      _scheduler.removeTask(uuid);
    }

    _emit(ScheduledTaskEventType.updated, uuid,
        employeeId: task.employeeId);
  }

  @override
  Future<void> triggerTaskNow(String uuid) async {
    final task = await _store.find(uuid);
    if (task == null) return;

    // 直接执行，不走调度器
    final success = await _doExecute(task);

    final now = DateTime.now();
    AiScheduledTaskEntity updated;

    if (success) {
      updated = task.copyWith(
        lastExecutedAt: now,
        lastExecutionResult: 'success',
        consecutiveFailures: 0,
        updateTime: now,
      );
      // 重新计算下次执行时间
      updated = _recalcNextExecution(updated);
    } else {
      updated = task.copyWith(
        lastExecutedAt: now,
        lastExecutionResult: 'failed',
        consecutiveFailures: task.consecutiveFailures + 1,
        updateTime: now,
      );
    }

    await _store.save(updated);

    if (_started) {
      _scheduler.updateTask(updated);
    }

    _emit(ScheduledTaskEventType.executed, uuid,
        employeeId: task.employeeId,
        data: {'success': success});
  }

  // ===== 生命周期 =====

  @override
  Future<void> start() async {
    if (_started) return;

    // 设置调度器回调
    _scheduler.onExecute = _doExecute;
    _scheduler.onTaskUpdated = (task) async {
      await _store.save(task);

      _emit(ScheduledTaskEventType.executed, task.uuid,
          employeeId: task.employeeId,
          data: {
            'success': task.lastExecutionResult == 'success',
            'result': task.lastExecutionResult,
            'error': task.lastExecutionError,
          });

      // 如果任务被自动禁用，发出 disabled 事件
      if (!task.isEnabled) {
        _emit(ScheduledTaskEventType.disabled, task.uuid,
            employeeId: task.employeeId,
            data: {'reason': task.lastExecutionError});
      }
    };

    // 从数据库加载所有启用的任务
    final allTasks = await _store.findAll();
    final enabledTasks =
        allTasks.where((t) => t.isEnabled && !t.isExpired).toList();

    // 重新计算 nextExecutionAt（幂等：基于 lastExecutedAt 不重复）
    final readyTasks = <AiScheduledTaskEntity>[];
    for (final task in enabledTasks) {
      final recalced = _recalcNextExecution(task);
      await _store.save(recalced);
      readyTasks.add(recalced);
    }

    // 启动调度器
    _scheduler.start(readyTasks);
    _started = true;

    print('[ScheduledTaskManager] 已启动，加载 ${readyTasks.length} 个定时任务');
  }

  @override
  Future<void> stop() async {
    _scheduler.stop();
    _started = false;
    print('[ScheduledTaskManager] 已停止');
  }

  @override
  bool get isRunning => _started;

  @override
  Stream<ScheduledTaskEvent> get onTaskEvent => _eventController.stream;

  // ===== 内部方法 =====

  /// 核心执行逻辑
  Future<bool> _doExecute(AiScheduledTaskEntity task) async {
    print('[ScheduledTaskManager] 执行任务: ${task.name} (${task.uuid}), '
        'taskType: ${task.taskType}');

    if (task.employeeId == null || task.employeeId!.isEmpty) {
      print('[ScheduledTaskManager] 任务无 employeeId，跳过');
      return false;
    }

    try {
      if (task.taskConfig == null || task.taskConfig!.isEmpty) {
        print('[ScheduledTaskManager] 任务无 taskConfig，跳过');
        return false;
      }

      final config = jsonDecode(task.taskConfig!) as Map<String, dynamic>;

      // 根据 taskType 分发执行路径
      switch (task.taskType) {
        case TaskType.task:
          return await _executeTask(task, config);
        case TaskType.reminder:
        default:
          return await _executeReminder(task, config);
      }
    } catch (e) {
      print('[ScheduledTaskManager] 任务执行异常: $e');
      return false;
    }
  }

  /// 提醒类任务：直接注入助手消息到会话，不调用 LLM API
  ///
  /// 提醒内容在创建时已预渲染（使用 message 字段），
  /// 触发时以 assistant 角色直接写入会话 + 持久化，用户看到的是一条助手消息。
  Future<bool> _executeReminder(AiScheduledTaskEntity task,
      Map<String, dynamic> config) async {
    if (getAgent == null) {
      print('[ScheduledTaskManager] getAgent 未注入');
      return false;
    }

    final agent = await getAgent!(task.employeeId!);
    if (agent == null) {
      print('[ScheduledTaskManager] Agent ${task.employeeId} 不存在');
      return false;
    }

    // 使用预渲染内容或 message 字段作为提醒正文
    final message = (config['preRenderedMessage'] ??
        config['message'] ??
        config['taskPrompt'] ??
        '') as String;
    if (message.isEmpty) return false;

    // 通过 injectReminderMessage 直接注入助手消息（不触发 LLM）
    if (agent is AgentImpl) {
      final msgId = await agent.injectReminderMessage(
        content: message,
        taskName: task.name,
        taskId: task.uuid,
      );
      print('[ScheduledTaskManager] injectReminderMessage: msgId=$msgId');
      return msgId != null;
    }

    // fallback
    await agent.sendMessage(MessageInput(
      content: message,
      employeeId: task.employeeId,
      metadata: {
        'trigger': 'scheduled_reminder',
        'scheduledTaskId': task.uuid,
        'taskName': task.name,
      },
    ));
    return true;
  }

  /// 任务类任务：通过队列发送系统消息到主 agent，让主 agent 根据任务资料执行
  ///
  /// 不再使用 sub-agent 隔离执行，而是：
  /// 1. 将任务资料以 system 消息注入会话上下文
  /// 2. 通过 triggerSystemTask 触发主 agent LLM 处理
  /// 3. 主 agent 拥有完整工具集，可自主执行任务
  /// 4. 权限通过主 agent 原有的 PermissionManager 处理
  Future<bool> _executeTask(AiScheduledTaskEntity task,
      Map<String, dynamic> config) async {
    if (getAgent == null) {
      print('[ScheduledTaskManager] getAgent 未注入');
      return false;
    }

    final agent = await getAgent!(task.employeeId!);
    if (agent == null) {
      print('[ScheduledTaskManager] Agent ${task.employeeId} 不存在');
      return false;
    }

    // 构建任务执行指令（包含任务资料）
    final message = (config['message'] ?? config['taskPrompt'] ?? '') as String;
    if (message.isEmpty) return false;

    // 通过 triggerSystemTask 注入系统消息 + 触发主 agent LLM 处理
    // 任务资料已包含在 message 中，LLM 会根据资料调用工具执行任务
    if (agent is AgentImpl) {
      final taskContent = '【定时任务执行：${task.name}】\n\n'
          '以下是需要执行的定时任务，请根据任务资料和要求开始执行：\n\n'
          '$message';
      final msgId = await agent.triggerSystemTask(
        taskContent: taskContent,
        taskName: task.name,
      );
      print('[ScheduledTaskManager] triggerSystemTask (task): msgId=$msgId');
      return msgId != null;
    }

    // fallback
    await agent.sendMessage(MessageInput(
      content: '【定时任务执行：${task.name}】\n\n$message',
      employeeId: task.employeeId,
      metadata: {
        'trigger': 'scheduled_task',
        'scheduledTaskId': task.uuid,
        'taskName': task.name,
      },
    ));
    return true;
  }

  /// 计算首次执行时间
  AiScheduledTaskEntity _computeFirstExecution(AiScheduledTaskEntity task) {
    if (task.nextExecutionAt != null) return task;

    final now = DateTime.now();

    // startAt 在未来 → nextExecutionAt = startAt
    if (task.startAt != null && task.startAt!.isAfter(now)) {
      return task.copyWith(nextExecutionAt: task.startAt);
    }

    // 否则从现在开始计算
    return _recalcNextExecution(task.copyWith(nextExecutionAt: null));
  }

  /// 重新计算 nextExecutionAt（基于 lastExecutedAt 或 now）
  AiScheduledTaskEntity _recalcNextExecution(AiScheduledTaskEntity task) {
    final now = DateTime.now();

    // 如果已有有效的 nextExecutionAt，不需要重算
    if (task.nextExecutionAt != null &&
        task.nextExecutionAt!.isAfter(now)) {
      return task;
    }

    final base = task.lastExecutedAt ?? task.startAt ?? now;

    try {
      DateTime next;
      if (task.scheduleType == ScheduleType.cron) {
        final cron = CronExpression.parse(task.scheduleExpression);
        next = cron.next(base) ?? now.add(const Duration(minutes: 1));
      } else {
        final duration = IsoDuration.parse(task.scheduleExpression);
        next = duration.next(base);
      }

      // 如果计算出的时间在 startAt 之前 → 调整到 startAt
      if (task.startAt != null && next.isBefore(task.startAt!)) {
        next = task.startAt!;
      }

      return task.copyWith(nextExecutionAt: next);
    } catch (_) {
      return task;
    }
  }

  /// 校验调度表达式
  void _validateSchedule(String scheduleType, String expression) {
    if (scheduleType == ScheduleType.cron) {
      if (!CronExpression.isValid(expression)) {
        throw ArgumentError('非法的 Cron 表达式: $expression');
      }
    } else {
      if (!IsoDuration.isValid(expression)) {
        throw ArgumentError('非法的 Duration 表达式: $expression');
      }
    }
  }

  /// 发送事件
  void _emit(
    ScheduledTaskEventType type,
    String taskId, {
    String? employeeId,
    Map<String, dynamic>? data,
  }) {
    if (!_eventController.isClosed) {
      _eventController.add(ScheduledTaskEvent(
        type: type,
        taskId: taskId,
        employeeId: employeeId,
        data: data,
      ));
    }
  }

  /// 释放资源
  void dispose() {
    stop();
    _eventController.close();
  }
}
