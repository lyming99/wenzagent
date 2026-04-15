/// Todo 分组实体
class TodoGroupEntity {
  /// 分组 UUID
  final String id;

  /// 员工 UUID
  String employeeId;

  /// 分组名称
  String name;

  /// 排序序号
  int sortOrder;

  /// 是否已删除（软删除）
  int deleted;

  /// 创建时间
  DateTime createTime;

  /// 更新时间
  DateTime updateTime;

  TodoGroupEntity({
    required this.id,
    required this.employeeId,
    required this.name,
    this.sortOrder = 0,
    this.deleted = 0,
    required this.createTime,
    required this.updateTime,
  });

  /// 从 Map 创建
  factory TodoGroupEntity.fromMap(Map<String, dynamic> map) {
    return TodoGroupEntity(
      id: map['id'] as String,
      employeeId: map['employeeId'] as String,
      name: map['name'] as String,
      sortOrder: map['sortOrder'] as int? ?? 0,
      deleted: map['deleted'] as int? ?? 0,
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

  /// 转换为 Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'employeeId': employeeId,
      'name': name,
      'sortOrder': sortOrder,
      'deleted': deleted,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateTime': updateTime.millisecondsSinceEpoch,
    };
  }

  /// 复制并修改
  TodoGroupEntity copyWith({
    String? id,
    String? employeeId,
    String? name,
    int? sortOrder,
    int? deleted,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return TodoGroupEntity(
      id: id ?? this.id,
      employeeId: employeeId ?? this.employeeId,
      name: name ?? this.name,
      sortOrder: sortOrder ?? this.sortOrder,
      deleted: deleted ?? this.deleted,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  @override
  String toString() {
    return 'TodoGroupEntity(id: $id, name: $name, employeeId: $employeeId)';
  }
}
