/// Todo 主题状态
enum TodoTopicStatus {
  pending,
  inProgress,
  completed;

  static TodoTopicStatus fromString(String value) {
    return TodoTopicStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => TodoTopicStatus.pending,
    );
  }

  String get dbValue => name;
}

/// Todo 主题实体（替代旧的 TodoGroupEntity）
class TodoTopicEntity {
  final String id;
  String employeeId;
  String title;
  String description;
  String status;
  int sortOrder;
  int deleted;
  DateTime createTime;
  DateTime updateTime;
  DateTime? completedAt;

  TodoTopicEntity({
    required this.id,
    required this.employeeId,
    required this.title,
    this.description = '',
    this.status = 'pending',
    this.sortOrder = 0,
    this.deleted = 0,
    required this.createTime,
    required this.updateTime,
    this.completedAt,
  });

  factory TodoTopicEntity.fromMap(Map<String, dynamic> map) {
    return TodoTopicEntity(
      id: map['id'] as String,
      employeeId: map['employeeId'] as String,
      title: map['title'] as String,
      description: map['description'] as String? ?? '',
      status: map['status'] as String? ?? 'pending',
      sortOrder: map['sortOrder'] as int? ?? 0,
      deleted: map['deleted'] as int? ?? 0,
      createTime: map['createTime'] is DateTime
          ? map['createTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(map['createTime'] as int? ?? 0),
      updateTime: map['updateTime'] is DateTime
          ? map['updateTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(map['updateTime'] as int? ?? 0),
      completedAt: map['completedAt'] is int
          ? (map['completedAt'] as int) > 0
              ? DateTime.fromMillisecondsSinceEpoch(map['completedAt'] as int)
              : null
          : map['completedAt'] is DateTime
              ? map['completedAt'] as DateTime
              : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'employeeId': employeeId,
      'title': title,
      'description': description,
      'status': status,
      'sortOrder': sortOrder,
      'deleted': deleted,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateTime': updateTime.millisecondsSinceEpoch,
      'completedAt': completedAt?.millisecondsSinceEpoch,
    };
  }

  TodoTopicEntity copyWith({
    String? id,
    String? employeeId,
    String? title,
    String? description,
    String? status,
    int? sortOrder,
    int? deleted,
    DateTime? createTime,
    DateTime? updateTime,
    DateTime? Function()? completedAt,
  }) {
    return TodoTopicEntity(
      id: id ?? this.id,
      employeeId: employeeId ?? this.employeeId,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      sortOrder: sortOrder ?? this.sortOrder,
      deleted: deleted ?? this.deleted,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
      completedAt: completedAt != null ? completedAt() : this.completedAt,
    );
  }

  @override
  String toString() => 'TodoTopicEntity(id: $id, title: $title, status: $status)';
}
