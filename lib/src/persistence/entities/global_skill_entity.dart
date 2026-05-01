/// 全局技能实体（独立于员工）
///
/// 与 AiEmployeeSkillEntity 不同，GlobalSkillEntity 不绑定到特定员工，
/// 而是作为全局技能库存在，可被任意员工引用。
class GlobalSkillEntity {
  /// 技能UUID
  final String uuid;

  /// 技能名称
  String name;

  /// 技能描述
  String? description;

  /// 技能类型 (config/folder)
  String skillType;

  /// 技能配置 (JSON)
  String? config;

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

  GlobalSkillEntity({
    required this.uuid,
    required this.name,
    this.description,
    this.skillType = 'config',
    this.config,
    this.enabled = 1,
    this.sortOrder = 0,
    this.deleted = 0,
    this.deleteTime,
    required this.createTime,
    required this.updateTime,
  });

  /// 从Map创建
  factory GlobalSkillEntity.fromMap(Map<String, dynamic> map) {
    return GlobalSkillEntity(
      uuid: map['uuid'] as String,
      name: map['name'] as String,
      description: map['description'] as String?,
      skillType: map['skillType'] as String? ?? 'config',
      config: map['config'] as String?,
      enabled: map['enabled'] as int? ?? 1,
      sortOrder: map['sortOrder'] as int? ?? 0,
      deleted: map['deleted'] as int? ?? 0,
      deleteTime: map['deleteTime'] != null
          ? (map['deleteTime'] is DateTime
              ? map['deleteTime'] as DateTime
              : DateTime.fromMillisecondsSinceEpoch(
                  map['deleteTime'] as int))
          : null,
      createTime: map['createTime'] is DateTime
          ? map['createTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(
              map['createTime'] as int? ?? 0),
      updateTime: map['updateTime'] is DateTime
          ? map['updateTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(
              map['updateTime'] as int? ?? 0),
    );
  }

  /// 转换为Map
  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'name': name,
      'description': description,
      'skillType': skillType,
      'config': config,
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
  GlobalSkillEntity copyWith({
    String? uuid,
    String? name,
    String? description,
    String? skillType,
    String? config,
    int? enabled,
    int? sortOrder,
    int? deleted,
    Object? deleteTime = _sentinel,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return GlobalSkillEntity(
      uuid: uuid ?? this.uuid,
      name: name ?? this.name,
      description: description ?? this.description,
      skillType: skillType ?? this.skillType,
      config: config ?? this.config,
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
    return 'GlobalSkillEntity(uuid: $uuid, name: $name, skillType: $skillType)';
  }
}
