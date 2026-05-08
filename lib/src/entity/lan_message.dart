import 'lan_device_info.dart';

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

  /// Wenzbak 数据同步
  wenzbakSync,

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

  /// Agent 工具调用开始
  toolCallStart,

  /// Agent 工具调用结果
  toolCallResult,

  /// Agent 权限请求变更
  agentPermissionChanged,

  /// Agent 会话被清空（跨设备同步）
  agentSessionCleared,

  /// Agent 消息广播（实时新消息推送）
  agentUnreceivedMessagesBatch,

  /// Agent 消息已读状态变更（跨设备同步）
  agentMessageReadStatus,

  /// Agent 消息已读状态变更广播（从 Agent 广播到所有 Device）
  agentMessageReadStatusChanged,

  /// 会话摘要变更（跨设备同步未读计数 + 最新消息）
  agentSessionSummaryChanged,

  /// Agent 确认请求/响应变更（跨设备同步）
  agentConfirmChanged,

  /// Agent Todo 变更（跨设备同步）
  agentTodoChanged,

  /// Agent Spec 变更（跨设备同步）
  agentSpecChanged,

  /// Agent 配置变更（跨设备同步）
  agentConfigChanged,

  /// Agent Token 用量更新（跨设备同步）
  agentTokenUsageUpdated,

  // ===== AI Employee 消息类型 =====

  /// AI 聊天请求
  aiChatRequest,

  /// AI 聊天响应
  aiChatResponse,

  /// AI 聊天完成
  aiChatDone,

  /// AI 聊天错误
  aiChatError,

  /// AI 会话状态
  aiSessionStatus,

  /// AI 中断
  aiInterrupt,

  /// AI 员工绑定
  aiEmployeeBind,

  /// AI 员工绑定响应
  aiEmployeeBound,

  /// AI 切换员工
  aiSwitchEmployee,

  /// AI 员工列表
  aiEmployeeList,

  /// AI 会话列表
  aiSessionList,

  /// AI 会话历史
  aiSessionHistory,

  /// AI 员工变更
  aiEmployeeChange,

  /// AI 查询员工列表广播
  aiQueryEmployeeListBroadcast,

  /// AI 查询会话列表广播
  aiQuerySessionListBroadcast,

  /// AI 查询会话消息广播
  aiQuerySessionMessagesBroadcast,

  // ===== 设备管理消息类型 =====

  /// 设备上线
  deviceOnline,

  /// 设备下线
  deviceOffline,

  /// 设备信息变更
  deviceInfoChanged,

  /// 设备间消息
  deviceMessage,

  /// 请求设备信息广播
  deviceInfoRequest,

  /// 设备信息响应
  deviceInfoResponse,

  // ===== 心跳消息类型 =====

  /// Host -> Client: ping 探测
  ping,

  /// Client -> Host: pong 响应
  pong,

  /// 二进制数据块（用于文件传输等场景）
  ///
  /// 通过 WebSocket 原生二进制帧传输，不走 JSON 序列化。
  /// 帧格式：[version=0x01][type=0x02][toDeviceIdLen(4B)][toDeviceId][requestIdLen(4B)][requestId][flags(1B)][payload]
  binaryChunk,
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

/// 设备事件类型
enum DeviceEventType {
  /// 设备上线
  online,

  /// 设备下线
  offline,

  /// 设备信息变更
  infoChanged,
}

/// 设备事件
class DeviceEvent {
  /// 事件类型
  final DeviceEventType type;

  /// 设备信息
  final LanDeviceInfo device;

  /// 事件时间
  final DateTime timestamp;

  DeviceEvent({
    required this.type,
    required this.device,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}
