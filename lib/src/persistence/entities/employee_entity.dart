import 'mcp_server_config.dart';

/// AI员工实体（Hive版本）
class AiEmployeeEntity {
  /// 员工UUID
  final String uuid;

  /// 空间ID
  String? spaceId;

  /// 员工名称
  String name;

  /// 头像
  String? avatar;

  /// 角色
  String role;

  /// 状态
  String status;

  /// 描述
  String? description;

  /// 系统提示词
  String? systemPrompt;

  /// AI提供商 (openai/claude)
  String? provider;

  /// 模型名称
  String? model;

  /// API密钥
  String? apiKey;

  /// API地址
  String? apiBaseUrl;

  /// 模型配置 (JSON)
  String? modelConfig;

  /// 是否启用工具
  int enableTools;

  /// 是否启用MCP
  int enableMcp;

  /// MCP配置 (JSON)
  String? mcpConfig;

  /// 权限配置 (JSON)
  /// 格式: {"allowedTools": ["*"], "fileAccess": ["${workspace}/**"], "commandWhitelist": ["git", "npm"]}
  String? permissionConfig;

  /// 当前所在设备ID（员工上线时绑定）
  String? deviceId;

  /// 是否自动批准
  int autoApprove;

  /// 排序序号
  int sortOrder;

  /// 是否置顶
  int isPinned;

  /// 是否已删除
  int deleted;

  /// 创建时间
  DateTime createTime;

  /// 更新时间
  DateTime updateTime;

  AiEmployeeEntity({
    required this.uuid,
    this.spaceId,
    required this.name,
    this.avatar,
    this.role = 'assistant',
    this.status = 'active',
    this.description,
    this.systemPrompt,
    this.provider,
    this.model,
    this.apiKey,
    this.apiBaseUrl,
    this.modelConfig,
    this.enableTools = 1,
    this.enableMcp = 0,
    this.mcpConfig,
    this.permissionConfig,
    this.deviceId,
    this.autoApprove = 0,
    this.sortOrder = 0,
    this.isPinned = 0,
    this.deleted = 0,
    required this.createTime,
    required this.updateTime,
  });

  /// 从Map创建
  factory AiEmployeeEntity.fromMap(Map<String, dynamic> map) {
    return AiEmployeeEntity(
      uuid: map['uuid'] as String,
      spaceId: map['spaceId'] as String?,
      name: map['name'] as String,
      avatar: map['avatar'] as String?,
      role: map['role'] as String? ?? 'assistant',
      status: map['status'] as String? ?? 'active',
      description: map['description'] as String?,
      systemPrompt: map['systemPrompt'] as String?,
      provider: map['provider'] as String?,
      model: map['model'] as String?,
      apiKey: map['apiKey'] as String?,
      apiBaseUrl: map['apiBaseUrl'] as String?,
      modelConfig: map['modelConfig'] as String?,
      enableTools: map['enableTools'] as int? ?? 1,
      enableMcp: map['enableMcp'] as int? ?? 0,
      mcpConfig: map['mcpConfig'] as String?,
      permissionConfig: map['permissionConfig'] as String?,
      deviceId: map['deviceId'] as String?,
      autoApprove: map['autoApprove'] as int? ?? 0,
      sortOrder: map['sortOrder'] as int? ?? 0,
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
      'name': name,
      'avatar': avatar,
      'role': role,
      'status': status,
      'description': description,
      'systemPrompt': systemPrompt,
      'provider': provider,
      'model': model,
      'apiKey': apiKey,
      'apiBaseUrl': apiBaseUrl,
      'modelConfig': modelConfig,
      'enableTools': enableTools,
      'enableMcp': enableMcp,
      'mcpConfig': mcpConfig,
      'permissionConfig': permissionConfig,
      'deviceId': deviceId,
      'autoApprove': autoApprove,
      'sortOrder': sortOrder,
      'isPinned': isPinned,
      'deleted': deleted,
      'createTime': createTime.millisecondsSinceEpoch,
      'updateTime': updateTime.millisecondsSinceEpoch,
    };
  }

  /// 复制并修改
  AiEmployeeEntity copyWith({
    String? uuid,
    String? spaceId,
    String? name,
    String? avatar,
    String? role,
    String? status,
    String? description,
    String? systemPrompt,
    String? provider,
    String? model,
    String? apiKey,
    String? apiBaseUrl,
    String? modelConfig,
    int? enableTools,
    int? enableMcp,
    String? mcpConfig,
    String? permissionConfig,
    String? deviceId,
    int? autoApprove,
    int? sortOrder,
    int? isPinned,
    int? deleted,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return AiEmployeeEntity(
      uuid: uuid ?? this.uuid,
      spaceId: spaceId ?? this.spaceId,
      name: name ?? this.name,
      avatar: avatar ?? this.avatar,
      role: role ?? this.role,
      status: status ?? this.status,
      description: description ?? this.description,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      provider: provider ?? this.provider,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      modelConfig: modelConfig ?? this.modelConfig,
      enableTools: enableTools ?? this.enableTools,
      enableMcp: enableMcp ?? this.enableMcp,
      mcpConfig: mcpConfig ?? this.mcpConfig,
      permissionConfig: permissionConfig ?? this.permissionConfig,
      deviceId: deviceId ?? this.deviceId,
      autoApprove: autoApprove ?? this.autoApprove,
      sortOrder: sortOrder ?? this.sortOrder,
      isPinned: isPinned ?? this.isPinned,
      deleted: deleted ?? this.deleted,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  /// 获取MCP服务器配置列表
  ///
  /// 支持向后兼容：自动识别旧格式(Map)并转换为新格式(List)
  List<McpServerConfig> getMcpConfigs() {
    return McpServerConfig.parseList(mcpConfig);
  }

  /// 设置MCP服务器配置列表
  ///
  /// 将配置列表序列化为JSON字符串存储
  AiEmployeeEntity setMcpConfigs(List<McpServerConfig> configs) {
    return copyWith(
      mcpConfig: McpServerConfig.toJsonString(configs),
      updateTime: DateTime.now(),
    );
  }

  /// 是否启用MCP
  bool get isMcpEnabled => enableMcp == 1;

  @override
  String toString() {
    return 'AiEmployeeEntity(uuid: $uuid, name: $name, provider: $provider, model: $model)';
  }
}
