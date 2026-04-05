/// AI员工技能实体（Hive版本）
class AiEmployeeSkillEntity {
  /// 技能UUID
  final String uuid;

  /// 员工UUID
  String employeeUuid;

  /// 技能名称
  String name;

  /// 技能描述
  String? description;

  /// 技能类型 (mcp/note/file)
  String skillType;

  /// 技能配置 (JSON)
  String? config;

  /// 是否启用
  int enabled;

  /// 排序序号
  int sortOrder;

  /// 是否已删除
  int deleted;

  /// 创建时间
  DateTime createTime;

  /// 更新时间
  DateTime updateTime;

  AiEmployeeSkillEntity({
    required this.uuid,
    required this.employeeUuid,
    required this.name,
    this.description,
    this.skillType = 'mcp',
    this.config,
    this.enabled = 1,
    this.sortOrder = 0,
    this.deleted = 0,
    required this.createTime,
    required this.updateTime,
  });

  /// 从Map创建
  factory AiEmployeeSkillEntity.fromMap(Map<String, dynamic> map) {
    return AiEmployeeSkillEntity(
      uuid: map['uuid'] as String,
      employeeUuid: map['employeeUuid'] as String,
      name: map['name'] as String,
      description: map['description'] as String?,
      skillType: map['skillType'] as String? ?? 'mcp',
      config: map['config'] as String?,
      enabled: map['enabled'] as int? ?? 1,
      sortOrder: map['sortOrder'] as int? ?? 0,
      deleted: map['deleted'] as int? ?? 0,
      createTime: map['createTime'] is DateTime
          ? map['createTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(map['createTime'] as int? ?? 0),
      updateTime: map['updateTime'] is DateTime
          ? map['updateTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(map['updateTime'] as int? ?? 0),
    );
  }

  /// 转换为Map
  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'employeeUuid': employeeUuid,
      'name': name,
      'description': description,
      'skillType': skillType,
      'config': config,
      'enabled': enabled,
      'sortOrder': sortOrder,
      'deleted': deleted,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateTime': updateTime.millisecondsSinceEpoch,
    };
  }

  /// 复制并修改
  AiEmployeeSkillEntity copyWith({
    String? uuid,
    String? employeeUuid,
    String? name,
    String? description,
    String? skillType,
    String? config,
    int? enabled,
    int? sortOrder,
    int? deleted,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return AiEmployeeSkillEntity(
      uuid: uuid ?? this.uuid,
      employeeUuid: employeeUuid ?? this.employeeUuid,
      name: name ?? this.name,
      description: description ?? this.description,
      skillType: skillType ?? this.skillType,
      config: config ?? this.config,
      enabled: enabled ?? this.enabled,
      sortOrder: sortOrder ?? this.sortOrder,
      deleted: deleted ?? this.deleted,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  @override
  String toString() {
    return 'AiEmployeeSkillEntity(uuid: $uuid, name: $name, skillType: $skillType)';
  }
}
