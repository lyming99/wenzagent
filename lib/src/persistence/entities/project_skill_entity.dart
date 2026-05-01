/// 项目技能实体类（wenzagent 模块）
///
/// 对应 wenz_project_skills 表，项目下的技能配置。
class ProjectSkillEntity {
  /// 技能UUID
  final String uuid;

  /// 所属项目UUID
  String projectUuid;

  /// 技能名称
  String title;

  /// 技能描述
  String? description;

  /// 技能类型 (note/document/mcp)
  String skillType;

  /// 关联笔记UUID
  String? noteUuid;

  /// 关联文档UUID
  String? documentUuid;

  /// MCP配置 (JSON)
  String? mcpConfig;

  /// 文件配置 (JSON)
  String? fileConfig;

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

  ProjectSkillEntity({
    required this.uuid,
    required this.projectUuid,
    required this.title,
    this.description,
    this.skillType = 'mcp',
    this.noteUuid,
    this.documentUuid,
    this.mcpConfig,
    this.fileConfig,
    this.sortOrder = 0,
    this.deleted = 0,
    this.deleteBy,
    this.deleteTime,
    this.createBy,
    required this.createTime,
    this.updateBy,
    required this.updateTime,
  });

  factory ProjectSkillEntity.fromMap(Map<String, dynamic> map) {
    return ProjectSkillEntity(
      uuid: map['uuid'] as String,
      projectUuid: map['projectUuid'] as String,
      title: map['title'] as String,
      description: map['description'] as String?,
      skillType: map['skillType'] as String? ?? 'mcp',
      noteUuid: map['noteUuid'] as String?,
      documentUuid: map['documentUuid'] as String?,
      mcpConfig: map['mcpConfig'] as String?,
      fileConfig: map['fileConfig'] as String?,
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
      'skillType': skillType,
      'noteUuid': noteUuid,
      'documentUuid': documentUuid,
      'mcpConfig': mcpConfig,
      'fileConfig': fileConfig,
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

  ProjectSkillEntity copyWith({
    String? uuid,
    String? projectUuid,
    String? title,
    String? description,
    String? skillType,
    String? noteUuid,
    String? documentUuid,
    String? mcpConfig,
    String? fileConfig,
    int? sortOrder,
    int? deleted,
    String? deleteBy,
    Object? deleteTime = _sentinel,
    String? createBy,
    DateTime? createTime,
    String? updateBy,
    DateTime? updateTime,
  }) {
    return ProjectSkillEntity(
      uuid: uuid ?? this.uuid,
      projectUuid: projectUuid ?? this.projectUuid,
      title: title ?? this.title,
      description: description ?? this.description,
      skillType: skillType ?? this.skillType,
      noteUuid: noteUuid ?? this.noteUuid,
      documentUuid: documentUuid ?? this.documentUuid,
      mcpConfig: mcpConfig ?? this.mcpConfig,
      fileConfig: fileConfig ?? this.fileConfig,
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
      'ProjectSkillEntity(uuid: $uuid, title: $title, skillType: $skillType, projectUuid: $projectUuid)';
}
