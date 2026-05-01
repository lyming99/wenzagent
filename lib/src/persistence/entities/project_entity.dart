/// 项目实体类（wenzagent 模块）
///
/// 对应 wenz_projects 表，存储项目基本信息。
/// 参考 AiEmployeeEntity 的设计模式：fromMap/toMap/copyWith。
class ProjectEntity {
  /// 项目UUID
  final String uuid;

  /// 用户ID
  int? userId;

  /// 空间ID
  String? spaceId;

  /// 项目名称
  String title;

  /// 项目描述
  String? description;

  /// 工作路径
  String? workPath;

  /// Git URL
  String? gitUrl;

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

  ProjectEntity({
    required this.uuid,
    this.userId,
    this.spaceId,
    required this.title,
    this.description,
    this.workPath,
    this.gitUrl,
    this.deleted = 0,
    this.deleteBy,
    this.deleteTime,
    this.createBy,
    required this.createTime,
    this.updateBy,
    required this.updateTime,
  });

  /// 从 Map 创建
  factory ProjectEntity.fromMap(Map<String, dynamic> map) {
    return ProjectEntity(
      uuid: map['uuid'] as String,
      userId: map['userId'] as int?,
      spaceId: map['spaceId'] as String?,
      title: map['title'] as String,
      description: map['description'] as String?,
      workPath: map['workPath'] as String?,
      gitUrl: map['gitUrl'] as String?,
      deleted: map['deleted'] as int? ?? 0,
      deleteBy: map['deleteBy'] as String?,
      deleteTime: _parseDateTime(map['deleteTime']),
      createBy: map['createBy'] as String?,
      createTime: _parseDateTime(map['createTime']) ?? DateTime.now(),
      updateBy: map['updateBy'] as String?,
      updateTime: _parseDateTime(map['updateTime']) ?? DateTime.now(),
    );
  }

  /// 转为 Map
  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'userId': userId,
      'spaceId': spaceId,
      'title': title,
      'description': description,
      'workPath': workPath,
      'gitUrl': gitUrl,
      'deleted': deleted,
      'deleteBy': deleteBy,
      'deleteTime': deleteTime?.millisecondsSinceEpoch,
      'createBy': createBy,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateBy': updateBy,
      'updateTime': updateTime.millisecondsSinceEpoch,
    };
  }

  /// 复制并修改
  ProjectEntity copyWith({
    String? uuid,
    int? userId,
    String? spaceId,
    String? title,
    String? description,
    String? workPath,
    String? gitUrl,
    int? deleted,
    String? deleteBy,
    Object? deleteTime = _sentinel,
    String? createBy,
    DateTime? createTime,
    String? updateBy,
    DateTime? updateTime,
  }) {
    return ProjectEntity(
      uuid: uuid ?? this.uuid,
      userId: userId ?? this.userId,
      spaceId: spaceId ?? this.spaceId,
      title: title ?? this.title,
      description: description ?? this.description,
      workPath: workPath ?? this.workPath,
      gitUrl: gitUrl ?? this.gitUrl,
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

  /// 哨兵值，用于 copyWith 区分"未传参"和"显式传 null"
  static const _sentinel = Object();

  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return null;
  }

  @override
  String toString() =>
      'ProjectEntity(uuid: $uuid, title: $title, workPath: $workPath)';
}
