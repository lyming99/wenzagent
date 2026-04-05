/// AI员工会话实体（Hive版本）
class AiEmployeeSessionEntity {
  /// 会话UUID
  final String uuid;

  /// 空间ID
  String? spaceId;

  /// 员工UUID
  String employeeUuid;

  /// 会话标题
  String title;

  /// Provider配置 (JSON)
  String? providerConfig;

  /// 绑定项目UUID
  String? projectUuid;

  /// 上下文数据 (JSON)
  String? contextData;

  /// 输入token数
  int inputTokens;

  /// 输出token数
  int outputTokens;

  /// 消息数量
  int messageCount;

  /// 是否归档
  int isArchived;

  /// 是否置顶
  int isPinned;

  /// 是否已删除
  int deleted;

  /// 创建时间
  DateTime createTime;

  /// 更新时间
  DateTime updateTime;

  AiEmployeeSessionEntity({
    required this.uuid,
    this.spaceId,
    required this.employeeUuid,
    this.title = '新对话',
    this.providerConfig,
    this.projectUuid,
    this.contextData,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.messageCount = 0,
    this.isArchived = 0,
    this.isPinned = 0,
    this.deleted = 0,
    required this.createTime,
    required this.updateTime,
  });

  /// 从Map创建
  factory AiEmployeeSessionEntity.fromMap(Map<String, dynamic> map) {
    return AiEmployeeSessionEntity(
      uuid: map['uuid'] as String,
      spaceId: map['spaceId'] as String?,
      employeeUuid: map['employeeUuid'] as String,
      title: map['title'] as String? ?? '新对话',
      providerConfig: map['providerConfig'] as String?,
      projectUuid: map['projectUuid'] as String?,
      contextData: map['contextData'] as String?,
      inputTokens: map['inputTokens'] as int? ?? 0,
      outputTokens: map['outputTokens'] as int? ?? 0,
      messageCount: map['messageCount'] as int? ?? 0,
      isArchived: map['isArchived'] as int? ?? 0,
      isPinned: map['isPinned'] as int? ?? 0,
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
      'spaceId': spaceId,
      'employeeUuid': employeeUuid,
      'title': title,
      'providerConfig': providerConfig,
      'projectUuid': projectUuid,
      'contextData': contextData,
      'inputTokens': inputTokens,
      'outputTokens': outputTokens,
      'messageCount': messageCount,
      'isArchived': isArchived,
      'isPinned': isPinned,
      'deleted': deleted,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateTime': updateTime.millisecondsSinceEpoch,
    };
  }

  /// 复制并修改
  AiEmployeeSessionEntity copyWith({
    String? uuid,
    String? spaceId,
    String? employeeUuid,
    String? title,
    String? providerConfig,
    String? projectUuid,
    String? contextData,
    int? inputTokens,
    int? outputTokens,
    int? messageCount,
    int? isArchived,
    int? isPinned,
    int? deleted,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return AiEmployeeSessionEntity(
      uuid: uuid ?? this.uuid,
      spaceId: spaceId ?? this.spaceId,
      employeeUuid: employeeUuid ?? this.employeeUuid,
      title: title ?? this.title,
      providerConfig: providerConfig ?? this.providerConfig,
      projectUuid: projectUuid ?? this.projectUuid,
      contextData: contextData ?? this.contextData,
      inputTokens: inputTokens ?? this.inputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      messageCount: messageCount ?? this.messageCount,
      isArchived: isArchived ?? this.isArchived,
      isPinned: isPinned ?? this.isPinned,
      deleted: deleted ?? this.deleted,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  @override
  String toString() {
    return 'AiEmployeeSessionEntity(uuid: $uuid, employeeUuid: $employeeUuid, title: $title)';
  }
}
