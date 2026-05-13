/// AI员工技能实体
class AiEmployeeSkillEntity {
  /// 技能UUID
  final String uuid;

  /// 员工UUID
  String employeeId;

  /// 设备ID（仅作为元数据保留，不再用于查询隔离）
  @Deprecated('deviceId 不再用于查询隔离，仅保留作为元数据')
  String deviceId;

  /// 技能名称
  String name;

  /// 技能描述
  String? description;

  /// 技能类型 (mcp/note/file)
  String skillType;

  /// 技能配置 (JSON)
  String? config;

  /// 关联的全局技能 UUID（用于从 global skill 库引用的技能）
  String? globalSkillId;

  /// 原始技能文件夹名称（用于从 LAN 同步时定位远端文件夹）
  /// 当员工 skill 的 name 与源 skill 的文件夹名不一致时，通过此字段定位正确的文件夹
  String? originName;

  /// 是否启用
  int enabled;

  /// 排序序号
  int sortOrder;

  /// 是否已删除
  int deleted;

  /// 删除时间（软删除时使用）
  DateTime? deleteTime;

  /// 创建时间
  DateTime createTime;

  /// 更新时间
  DateTime updateTime;

  AiEmployeeSkillEntity({
    required this.uuid,
    required this.employeeId,
    this.deviceId = '',
    required this.name,
    this.description,
    this.skillType = 'mcp',
    this.config,
    this.globalSkillId,
    this.originName,
    this.enabled = 1,
    this.sortOrder = 0,
    this.deleted = 0,
    this.deleteTime,
    required this.createTime,
    required this.updateTime,
  });

  /// 从Map创建
  factory AiEmployeeSkillEntity.fromMap(Map<String, dynamic> map) {
    return AiEmployeeSkillEntity(
      uuid: map['uuid'] as String,
      employeeId: map['employeeId'] as String,
      deviceId: map['deviceId'] as String? ?? '',
      name: map['name'] as String,
      description: map['description'] as String?,
      skillType: map['skillType'] as String? ?? 'mcp',
      config: map['config'] as String?,
      globalSkillId: map['globalSkillId'] as String?,
      originName: map['originName'] as String?,
      enabled: map['enabled'] as int? ?? 1,
      sortOrder: map['sortOrder'] as int? ?? 0,
      deleted: map['deleted'] as int? ?? 0,
      deleteTime: map['deleteTime'] != null
          ? (map['deleteTime'] is DateTime
              ? map['deleteTime'] as DateTime
              : DateTime.fromMillisecondsSinceEpoch(map['deleteTime'] as int))
          : null,
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
      'employeeId': employeeId,
      'deviceId': deviceId,
      'name': name,
      'description': description,
      'skillType': skillType,
      'config': config,
      'globalSkillId': globalSkillId,
      'originName': originName,
      'enabled': enabled,
      'sortOrder': sortOrder,
      'deleted': deleted,
      'deleteTime': deleteTime?.millisecondsSinceEpoch,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateTime': updateTime.millisecondsSinceEpoch,
    };
  }

  /// 哨兵值，用于 copyWith 区分"未传参"和"显式传 null"
  static const _sentinel = Object();

  /// 复制并修改
  AiEmployeeSkillEntity copyWith({
    String? uuid,
    String? employeeId,
    String? deviceId,
    String? name,
    String? description,
    String? skillType,
    String? config,
    String? globalSkillId,
    String? originName,
    int? enabled,
    int? sortOrder,
    int? deleted,
    Object? deleteTime = _sentinel,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return AiEmployeeSkillEntity(
      uuid: uuid ?? this.uuid,
      employeeId: employeeId ?? this.employeeId,
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
      description: description ?? this.description,
      skillType: skillType ?? this.skillType,
      config: config ?? this.config,
      globalSkillId: globalSkillId ?? this.globalSkillId,
      originName: originName ?? this.originName,
      enabled: enabled ?? this.enabled,
      sortOrder: sortOrder ?? this.sortOrder,
      deleted: deleted ?? this.deleted,
      deleteTime: identical(deleteTime, _sentinel)
          ? this.deleteTime
          : deleteTime as DateTime?,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  @override
  String toString() {
    return 'AiEmployeeSkillEntity(uuid: $uuid, name: $name, skillType: $skillType)';
  }
}
