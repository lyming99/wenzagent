/// LAN 消息类型枚举
enum LanMessageType {
  /// 文本消息
  text,

  /// 文件消息
  file,

  /// 系统消息
  system,

  /// 客户端信息
  clientInfo,

  /// RPC 请求
  rpcRequest,

  /// RPC 响应
  rpcResponse,

  /// RPC 流式 chunk
  rpcStreamChunk,

  /// RPC 流式结束
  rpcStreamEnd,

  /// RPC 错误
  rpcError,

  /// Agent 状态变更
  agentStatusChanged,

  /// Agent 消息状态变更
  agentMessageStatusChanged,

  /// Agent 权限请求变更
  agentPermissionChanged,
}

/// LAN 消息实体
class LanMessage {
  /// 消息 ID
  String? id;

  /// 消息类型
  LanMessageType? type;

  /// 发送者 ID
  String? fromId;

  /// 发送者名称
  String? fromName;

  /// 消息内容
  String? content;

  /// 文件名（文件消息）
  String? fileName;

  /// 文件大小
  int? fileSize;

  /// 文件 ID（用于缓存管理）
  String? fileId;

  /// 文件哈希（SHA256，用于校验下载完整性）
  String? fileHash;

  /// 分组 Topic
  String? topic;

  /// 目标设备ID（用于定向转发）
  String? toDeviceId;

  /// 时间戳
  DateTime? timestamp;

  LanMessage({
    this.id,
    this.type,
    this.fromId,
    this.fromName,
    this.content,
    this.fileName,
    this.fileSize,
    this.fileId,
    this.fileHash,
    this.topic,
    this.toDeviceId,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// 创建 RPC 请求消息
  factory LanMessage.rpcRequest({
    required String id,
    required String fromId,
    required String toDeviceId,
    required String content,
  }) {
    return LanMessage(
      id: id,
      type: LanMessageType.rpcRequest,
      fromId: fromId,
      toDeviceId: toDeviceId,
      content: content,
    );
  }

  /// 创建 RPC 响应消息
  factory LanMessage.rpcResponse({
    required String id,
    required String fromId,
    required String toDeviceId,
    required String content,
  }) {
    return LanMessage(
      id: id,
      type: LanMessageType.rpcResponse,
      fromId: fromId,
      toDeviceId: toDeviceId,
      content: content,
    );
  }

  /// 创建系统消息
  factory LanMessage.system(String content) {
    return LanMessage(
      type: LanMessageType.system,
      content: content,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type?.name,
        'fromId': fromId,
        'fromName': fromName,
        'content': content,
        'fileName': fileName,
        'fileSize': fileSize,
        'fileId': fileId,
        'fileHash': fileHash,
        'topic': topic,
        'toDeviceId': toDeviceId,
        'timestamp': timestamp?.millisecondsSinceEpoch,
      };

  factory LanMessage.fromJson(Map<String, dynamic> json) => LanMessage(
        id: json['id'] as String?,
        type: json['type'] != null
            ? LanMessageType.values.firstWhere(
                (e) => e.name == json['type'],
                orElse: () => LanMessageType.text,
              )
            : null,
        fromId: json['fromId'] as String?,
        fromName: json['fromName'] as String?,
        content: json['content'] as String?,
        fileName: json['fileName'] as String?,
        fileSize: json['fileSize'] as int?,
        fileId: json['fileId'] as String?,
        fileHash: json['fileHash'] as String?,
        topic: json['topic'] as String?,
        toDeviceId: json['toDeviceId'] as String?,
        timestamp: json['timestamp'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int)
            : null,
      );

  @override
  String toString() {
    return 'LanMessage(id: $id, type: $type, fromId: $fromId, toDeviceId: $toDeviceId)';
  }
}
