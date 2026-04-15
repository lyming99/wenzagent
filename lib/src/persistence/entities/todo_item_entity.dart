/// Todo 项状态
enum TodoStatus {
  pending,
  inProgress,
  completed;

  static TodoStatus fromString(String value) {
    return TodoStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => TodoStatus.pending,
    );
  }

  /// 数据库存储值（与 Dart 枚举名一致）
  String get dbValue => name;
}

/// Todo 项实体
class TodoItemEntity {
  /// UUID
  final String id;

  /// 员工 UUID
  String employeeId;

  /// 所属分组 ID（可空，null 表示未分组）
  String? groupId;

  /// 内容
  String content;

  /// 状态 (pending/in_progress/completed)
  String status;

  /// 排序序号
  int sortOrder;

  /// 是否已删除（软删除）
  int deleted;

  /// 创建时间
  DateTime createTime;

  /// 更新时间
  DateTime updateTime;

  /// 完成时间（可空）
  DateTime? completedAt;

  TodoItemEntity({
    required this.id,
    required this.employeeId,
    this.groupId,
    required this.content,
    this.status = 'pending',
    this.sortOrder = 0,
    this.deleted = 0,
    required this.createTime,
    required this.updateTime,
    this.completedAt,
  });

  /// 从 Map 创建
  factory TodoItemEntity.fromMap(Map<String, dynamic> map) {
    return TodoItemEntity(
      id: map['id'] as String,
      employeeId: map['employeeId'] as String,
      groupId: map['groupId'] as String?,
      content: map['content'] as String,
      status: map['status'] as String? ?? 'pending',
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
      completedAt: map['completedAt'] is int
          ? (map['completedAt'] as int) > 0
              ? DateTime.fromMillisecondsSinceEpoch(map['completedAt'] as int)
              : null
          : map['completedAt'] is DateTime
              ? map['completedAt'] as DateTime
              : null,
    );
  }

  /// 转换为 Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'employeeId': employeeId,
      'groupId': groupId,
      'content': content,
      'status': status,
      'sortOrder': sortOrder,
      'deleted': deleted,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateTime': updateTime.millisecondsSinceEpoch,
      'completedAt': completedAt?.millisecondsSinceEpoch,
    };
  }

  /// 复制并修改
  TodoItemEntity copyWith({
    String? id,
    String? employeeId,
    String? groupId,
    String? content,
    String? status,
    int? sortOrder,
    int? deleted,
    DateTime? createTime,
    DateTime? updateTime,
    DateTime? Function()? completedAt,
  }) {
    return TodoItemEntity(
      id: id ?? this.id,
      employeeId: employeeId ?? this.employeeId,
      groupId: groupId ?? this.groupId,
      content: content ?? this.content,
      status: status ?? this.status,
      sortOrder: sortOrder ?? this.sortOrder,
      deleted: deleted ?? this.deleted,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
      completedAt: completedAt != null ? completedAt() : this.completedAt,
    );
  }

  @override
  String toString() {
    return 'TodoItemEntity(id: $id, content: $content, status: $status)';
  }
}
