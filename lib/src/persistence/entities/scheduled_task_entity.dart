/// AI 定时任务实体
///
/// 支持两种调度模式:
/// - [ScheduleType.interval]: 按固定时间间隔执行（如每 30 分钟）
/// - [ScheduleType.cron]: 按 cron 表达式执行（如 "0 9 * * 1-5"）
///
/// 支持两种执行策略:
/// - [RepeatType.recurring]: 循环执行
/// - [RepeatType.once]: 仅执行一次，完成后自动标记 disabled
class AiScheduledTaskEntity {
  /// 任务 UUID
  final String uuid;

  /// 所属员工 UUID（关联 Agent），为 null 则为全局任务
  final String? employeeId;

  /// 任务名称
  String name;

  /// 任务描述
  String? description;

  /// 调度类型: "interval" | "cron"
  String scheduleType;

  /// 调度表达式
  ///
  /// - interval 模式: ISO 8601 duration 字符串
  ///   "PT30M"(30分钟), "PT1H"(1小时), "P1D"(1天)
  /// - cron 模式: 标准 5 段 cron 表达式
  ///   "0 9 * * 1-5" 工作日9点, "*/30 * * * *" 每30分钟
  String scheduleExpression;

  /// 执行策略: "recurring" | "once"
  String repeatType;

  /// 任务配置 (JSON)
  ///
  /// 定义任务执行时的行为:
  /// ```json
  /// {
  ///   "action": "sendMessage",
  ///   "message": "请整理今日工作总结",
  ///   "systemPrompt": "...",
  ///   "tools": ["command_execute", "file_read"]
  /// }
  /// ```
  ///
  /// 支持两种任务类型:
  /// - reminder: 提醒类，创建时预渲染提醒内容，触发时注入主 agent session
  /// - task: 任务类，触发时用 sub-agent 执行，权限通过主 agent 请求
  String? taskConfig;

  /// 任务类型: "reminder" | "task"
  ///
  /// - reminder: 提醒类，创建时生成提醒内容，触发时直接注入主 agent 会话
  /// - task: 任务类，触发时创建独立 sub-agent 执行，需要权限时通过主 agent
  String taskType;

  /// 是否启用
  int enabled;

  /// 是否已删除
  int deleted;

  /// 首次执行时间（null 则立即开始调度）
  DateTime? startAt;

  /// 结束时间（null 则不限制）
  DateTime? endAt;

  /// 上次执行时间
  DateTime? lastExecutedAt;

  /// 下次执行时间（调度器计算填入）
  DateTime? nextExecutionAt;

  /// 最后执行结果: "success" | "failed" | "timeout"
  String? lastExecutionResult;

  /// 最后执行错误信息
  String? lastExecutionError;

  /// 连续失败次数
  int consecutiveFailures;

  /// 最大连续失败次数（超过自动禁用，0 = 不限制）
  int maxConsecutiveFailures;

  /// 排序序号
  int sortOrder;

  /// 创建时间
  DateTime createTime;

  /// 更新时间
  DateTime updateTime;

  /// 创建者设备 ID
  String? createdByDeviceId;

  AiScheduledTaskEntity({
    required this.uuid,
    this.employeeId,
    required this.name,
    this.description,
    this.scheduleType = 'interval',
    this.scheduleExpression = 'PT1H',
    this.repeatType = 'recurring',
    this.taskConfig,
    this.taskType = 'reminder',
    this.enabled = 1,
    this.deleted = 0,
    this.startAt,
    this.endAt,
    this.lastExecutedAt,
    this.nextExecutionAt,
    this.lastExecutionResult,
    this.lastExecutionError,
    this.consecutiveFailures = 0,
    this.maxConsecutiveFailures = 5,
    this.sortOrder = 0,
    required this.createTime,
    required this.updateTime,
    this.createdByDeviceId,
  });

  factory AiScheduledTaskEntity.fromMap(Map<String, dynamic> map) {
    return AiScheduledTaskEntity(
      uuid: map['uuid'] as String,
      employeeId: map['employeeId'] as String?,
      name: map['name'] as String,
      description: map['description'] as String?,
      scheduleType: map['scheduleType'] as String? ?? 'interval',
      scheduleExpression: map['scheduleExpression'] as String? ?? 'PT1H',
      repeatType: map['repeatType'] as String? ?? 'recurring',
      taskConfig: map['taskConfig'] as String?,
      taskType: map['taskType'] as String? ?? 'reminder',
      enabled: map['enabled'] as int? ?? 1,
      deleted: map['deleted'] as int? ?? 0,
      startAt: _parseDateTime(map['startAt']),
      endAt: _parseDateTime(map['endAt']),
      lastExecutedAt: _parseDateTime(map['lastExecutedAt']),
      nextExecutionAt: _parseDateTime(map['nextExecutionAt']),
      lastExecutionResult: map['lastExecutionResult'] as String?,
      lastExecutionError: map['lastExecutionError'] as String?,
      consecutiveFailures: map['consecutiveFailures'] as int? ?? 0,
      maxConsecutiveFailures: map['maxConsecutiveFailures'] as int? ?? 5,
      sortOrder: map['sortOrder'] as int? ?? 0,
      createTime:
          _parseDateTime(map['createTime']) ?? DateTime.now(),
      updateTime:
          _parseDateTime(map['updateTime']) ?? DateTime.now(),
      createdByDeviceId: map['createdByDeviceId'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'employeeId': employeeId,
      'name': name,
      'description': description,
      'scheduleType': scheduleType,
      'scheduleExpression': scheduleExpression,
      'repeatType': repeatType,
      'taskConfig': taskConfig,
      'taskType': taskType,
      'enabled': enabled,
      'deleted': deleted,
      'startAt': startAt?.millisecondsSinceEpoch,
      'endAt': endAt?.millisecondsSinceEpoch,
      'lastExecutedAt': lastExecutedAt?.millisecondsSinceEpoch,
      'nextExecutionAt': nextExecutionAt?.millisecondsSinceEpoch,
      'lastExecutionResult': lastExecutionResult,
      'lastExecutionError': lastExecutionError,
      'consecutiveFailures': consecutiveFailures,
      'maxConsecutiveFailures': maxConsecutiveFailures,
      'sortOrder': sortOrder,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateTime': updateTime.millisecondsSinceEpoch,
      'createdByDeviceId': createdByDeviceId,
    };
  }

  /// 复制并修改
  AiScheduledTaskEntity copyWith({
    String? uuid,
    String? employeeId,
    String? name,
    String? description,
    String? scheduleType,
    String? scheduleExpression,
    String? repeatType,
    String? taskConfig,
    String? taskType,
    int? enabled,
    int? deleted,
    DateTime? startAt,
    DateTime? endAt,
    DateTime? lastExecutedAt,
    DateTime? nextExecutionAt,
    String? lastExecutionResult,
    String? lastExecutionError,
    int? consecutiveFailures,
    int? maxConsecutiveFailures,
    int? sortOrder,
    DateTime? createTime,
    DateTime? updateTime,
    String? createdByDeviceId,
    // nullable 覆盖
    bool clearStartAt = false,
    bool clearEndAt = false,
    bool clearLastExecutedAt = false,
    bool clearNextExecutionAt = false,
    bool clearLastExecutionResult = false,
    bool clearLastExecutionError = false,
  }) {
    return AiScheduledTaskEntity(
      uuid: uuid ?? this.uuid,
      employeeId: employeeId ?? this.employeeId,
      name: name ?? this.name,
      description: description ?? this.description,
      scheduleType: scheduleType ?? this.scheduleType,
      scheduleExpression: scheduleExpression ?? this.scheduleExpression,
      repeatType: repeatType ?? this.repeatType,
      taskConfig: taskConfig ?? this.taskConfig,
      taskType: taskType ?? this.taskType,
      enabled: enabled ?? this.enabled,
      deleted: deleted ?? this.deleted,
      startAt: clearStartAt ? null : (startAt ?? this.startAt),
      endAt: clearEndAt ? null : (endAt ?? this.endAt),
      lastExecutedAt:
          clearLastExecutedAt ? null : (lastExecutedAt ?? this.lastExecutedAt),
      nextExecutionAt:
          clearNextExecutionAt ? null : (nextExecutionAt ?? this.nextExecutionAt),
      lastExecutionResult: clearLastExecutionResult
          ? null
          : (lastExecutionResult ?? this.lastExecutionResult),
      lastExecutionError: clearLastExecutionError
          ? null
          : (lastExecutionError ?? this.lastExecutionError),
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      maxConsecutiveFailures:
          maxConsecutiveFailures ?? this.maxConsecutiveFailures,
      sortOrder: sortOrder ?? this.sortOrder,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
      createdByDeviceId: createdByDeviceId ?? this.createdByDeviceId,
    );
  }

  /// 是否已启用且未删除
  bool get isEnabled => enabled == 1 && deleted == 0;

  /// 是否已过期
  bool get isExpired {
    if (endAt == null) return false;
    return DateTime.now().isAfter(endAt!);
  }

  /// 是否已到达开始时间
  bool get isStarted {
    if (startAt == null) return true;
    return !DateTime.now().isBefore(startAt!);
  }

  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  @override
  String toString() =>
      'AiScheduledTaskEntity(uuid: $uuid, name: $name, '
      'schedule: $scheduleType($scheduleExpression), enabled: $enabled)';
}

/// 调度类型常量
class ScheduleType {
  static const String interval = 'interval';
  static const String cron = 'cron';
}

/// 执行策略常量
class RepeatType {
  static const String recurring = 'recurring';
  static const String once = 'once';
}

/// 任务类型常量
class TaskType {
  /// 提醒类：创建时预渲染提醒内容，触发时注入主 agent session
  static const String reminder = 'reminder';

  /// 任务类：触发时用 sub-agent 执行，权限通过主 agent 请求
  static const String task = 'task';
}

/// 任务执行结果常量
class TaskResultType {
  static const String success = 'success';
  static const String failed = 'failed';
  static const String timeout = 'timeout';
}
