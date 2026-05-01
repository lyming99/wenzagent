/// 项目工单实体类（wenzagent 模块）
///
/// 对应 wenz_project_issues 表，项目下的工单/任务追踪。
class ProjectIssueEntity {
  /// 工单UUID
  final String uuid;

  /// 所属项目UUID
  String projectUuid;

  /// 工单标题
  String title;

  /// 工单描述
  String? description;

  /// 状态 (open/in_progress/closed)
  String status;

  /// 优先级 (high/medium/low)
  String priority;

  /// 负责人
  String? assignee;

  /// 关闭时间
  DateTime? closeTime;

  /// 是否已删除
  int deleted;

  /// 删除人
  String? deleteBy;

  /// 删除时间
  DateTime? deleteTime;

  /// 创建人
  String? createBy;

  /// 创建时间
  DateTime createTime;

  /// 更新人
  String? updateBy;

  /// 更新时间
  DateTime updateTime;

  ProjectIssueEntity({
    required this.uuid,
    required this.projectUuid,
    required this.title,
    this.description,
    this.status = 'open',
    this.priority = 'medium',
    this.assignee,
    this.closeTime,
    this.deleted = 0,
    this.deleteBy,
    this.deleteTime,
    this.createBy,
    required this.createTime,
    this.updateBy,
    required this.updateTime,
  });

  factory ProjectIssueEntity.fromMap(Map<String, dynamic> map) {
    return ProjectIssueEntity(
      uuid: map['uuid'] as String,
      projectUuid: map['projectUuid'] as String,
      title: map['title'] as String,
      description: map['description'] as String?,
      status: map['status'] as String? ?? 'open',
      priority: map['priority'] as String? ?? 'medium',
      assignee: map['assignee'] as String?,
      closeTime: _parseDateTime(map['closeTime']),
      deleted: map['deleted'] as int? ?? 0,
      deleteBy: map['deleteBy'] as String?,
      deleteTime: _parseDateTime(map['deleteTime']),
      createBy: map['createBy'] as String?,
      createTime: _parseDateTime(map['createTime']) ?? DateTime.now(),
      updateBy: map['updateBy'] as String?,
      updateTime: _parseDateTime(map['updateTime']) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'projectUuid': projectUuid,
      'title': title,
      'description': description,
      'status': status,
      'priority': priority,
      'assignee': assignee,
      'closeTime': closeTime?.millisecondsSinceEpoch,
      'deleted': deleted,
      'deleteBy': deleteBy,
      'deleteTime': deleteTime?.millisecondsSinceEpoch,
      'createBy': createBy,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateBy': updateBy,
      'updateTime': updateTime.millisecondsSinceEpoch,
    };
  }

  ProjectIssueEntity copyWith({
    String? uuid,
    String? projectUuid,
    String? title,
    String? description,
    String? status,
    String? priority,
    String? assignee,
    Object? closeTime = _sentinel,
    int? deleted,
    String? deleteBy,
    Object? deleteTime = _sentinel,
    String? createBy,
    DateTime? createTime,
    String? updateBy,
    DateTime? updateTime,
  }) {
    return ProjectIssueEntity(
      uuid: uuid ?? this.uuid,
      projectUuid: projectUuid ?? this.projectUuid,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      assignee: assignee ?? this.assignee,
      closeTime: identical(closeTime, _sentinel)
          ? this.closeTime
          : closeTime as DateTime?,
      deleted: deleted ?? this.deleted,
      deleteBy: deleteBy ?? this.deleteBy,
      deleteTime: identical(deleteTime, _sentinel)
          ? this.deleteTime
          : deleteTime as DateTime?,
      createBy: createBy ?? this.createBy,
      createTime: createTime ?? this.createTime,
      updateBy: updateBy ?? this.updateBy,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  static const _sentinel = Object();

  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return null;
  }

  bool get isOpen => status == 'open';
  bool get isInProgress => status == 'in_progress';
  bool get isClosed => status == 'closed';

  @override
  String toString() =>
      'ProjectIssueEntity(uuid: $uuid, title: $title, status: $status, projectUuid: $projectUuid)';
}
