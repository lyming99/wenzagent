/// Todo 任务子项状态
enum TodoTaskItemStatus {
  pending,
  inProgress,
  completed;

  static TodoTaskItemStatus fromString(String value) {
    return TodoTaskItemStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => TodoTaskItemStatus.pending,
    );
  }

  String get dbValue => name;
}

/// Todo 任务子项实体（替代旧的 TodoItemEntity）
class TodoTaskItemEntity {
  final String id;
  String employeeId;
  String topicId;
  String title;
  String content;
  String status;
  int sortOrder;
  int deleted;
  DateTime createTime;
  DateTime updateTime;
  DateTime? completedAt;

  TodoTaskItemEntity({
    required this.id,
    required this.employeeId,
    required this.topicId,
    required this.title,
    this.content = '',
    this.status = 'pending',
    this.sortOrder = 0,
    this.deleted = 0,
    required this.createTime,
    required this.updateTime,
    this.completedAt,
  });

  factory TodoTaskItemEntity.fromMap(Map<String, dynamic> map) {
    return TodoTaskItemEntity(
      id: map['id'] as String,
      employeeId: map['employeeId'] as String,
      topicId: map['topicId'] as String,
      title: map['title'] as String,
      content: map['content'] as String? ?? '',
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
      'topicId': topicId,
      'title': title,
      'content': content,
      'status': status,
      'sortOrder': sortOrder,
      'deleted': deleted,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateTime': updateTime.millisecondsSinceEpoch,
      'completedAt': completedAt?.millisecondsSinceEpoch,
    };
  }

  TodoTaskItemEntity copyWith({
    String? id,
    String? employeeId,
    String? topicId,
    String? title,
    String? content,
    String? status,
    int? sortOrder,
    int? deleted,
    DateTime? createTime,
    DateTime? updateTime,
    DateTime? Function()? completedAt,
  }) {
    return TodoTaskItemEntity(
      id: id ?? this.id,
      employeeId: employeeId ?? this.employeeId,
      topicId: topicId ?? this.topicId,
      title: title ?? this.title,
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
  String toString() => 'TodoTaskItemEntity(id: $id, title: $title, status: $status)';
}
