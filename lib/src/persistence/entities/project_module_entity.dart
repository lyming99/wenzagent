/// 项目模块实体类（wenzagent 模块）
///
/// 对应 wenz_project_modules 表，一个项目下可有多个模块。
class ProjectModuleEntity {
  /// 模块UUID
  final String uuid;

  /// 所属项目UUID
  String projectUuid;

  /// 模块名称
  String title;

  /// 模块描述
  String? description;

  /// 关联笔记UUID
  String? noteUuid;

  /// 排序序号
  int sortOrder;

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

  ProjectModuleEntity({
    required this.uuid,
    required this.projectUuid,
    required this.title,
    this.description,
    this.noteUuid,
    this.sortOrder = 0,
    this.deleted = 0,
    this.deleteBy,
    this.deleteTime,
    this.createBy,
    required this.createTime,
    this.updateBy,
    required this.updateTime,
  });

  factory ProjectModuleEntity.fromMap(Map<String, dynamic> map) {
    return ProjectModuleEntity(
      uuid: map['uuid'] as String,
      projectUuid: map['projectUuid'] as String,
      title: map['title'] as String,
      description: map['description'] as String?,
      noteUuid: map['noteUuid'] as String?,
      sortOrder: map['sortOrder'] as int? ?? 0,
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
      'noteUuid': noteUuid,
      'sortOrder': sortOrder,
      'deleted': deleted,
      'deleteBy': deleteBy,
      'deleteTime': deleteTime?.millisecondsSinceEpoch,
      'createBy': createBy,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateBy': updateBy,
      'updateTime': updateTime.millisecondsSinceEpoch,
    };
  }

  ProjectModuleEntity copyWith({
    String? uuid,
    String? projectUuid,
    String? title,
    String? description,
    String? noteUuid,
    int? sortOrder,
    int? deleted,
    String? deleteBy,
    Object? deleteTime = _sentinel,
    String? createBy,
    DateTime? createTime,
    String? updateBy,
    DateTime? updateTime,
  }) {
    return ProjectModuleEntity(
      uuid: uuid ?? this.uuid,
      projectUuid: projectUuid ?? this.projectUuid,
      title: title ?? this.title,
      description: description ?? this.description,
      noteUuid: noteUuid ?? this.noteUuid,
      sortOrder: sortOrder ?? this.sortOrder,
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

  @override
  String toString() =>
      'ProjectModuleEntity(uuid: $uuid, title: $title, projectUuid: $projectUuid)';
}
