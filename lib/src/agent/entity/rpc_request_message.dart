/// RPC 请求参数实体类 - 消息相关请求
///
/// 撤回消息请求
class RevokeMessageRequest {
  final String employeeId;
  final String messageId;

  const RevokeMessageRequest({
    required this.employeeId,
    required this.messageId,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'messageId': messageId,
    };
  }

  factory RevokeMessageRequest.fromMap(Map<String, dynamic> map) {
    return RevokeMessageRequest(
      employeeId: map['employeeId'] as String,
      messageId: map['messageId'] as String,
    );
  }
}

/// 发送消息请求
class SendMessageRequest {
  final String employeeId;
  final Map<String, dynamic> messageData;

  const SendMessageRequest({
    required this.employeeId,
    required this.messageData,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'messageData': messageData,
    };
  }

  factory SendMessageRequest.fromMap(Map<String, dynamic> map) {
    return SendMessageRequest(
      employeeId: map['employeeId'] as String,
      messageData: map['messageData'] as Map<String, dynamic>,
    );
  }
}

/// 获取会话消息请求
class GetSessionMessagesRequest {
  final String employeeId;

  const GetSessionMessagesRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetSessionMessagesRequest.fromMap(Map<String, dynamic> map) {
    return GetSessionMessagesRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 根据用户消息计数获取会话消息请求
///
/// 统计用户发送的消息数（role='user'），达到 [userMessageLimit] 条时停止，
/// 返回该时间段内的所有消息（包括user和assistant）
class GetSessionMessagesByUserCountRequest {
  final String employeeId;

  /// 用户消息数量限制（默认20条）
  final int userMessageLimit;

  const GetSessionMessagesByUserCountRequest({
    required this.employeeId,
    this.userMessageLimit = 20,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'userMessageLimit': userMessageLimit,
    };
  }

  factory GetSessionMessagesByUserCountRequest.fromMap(Map<String, dynamic> map) {
    return GetSessionMessagesByUserCountRequest(
      employeeId: map['employeeId'] as String,
      userMessageLimit: map['userMessageLimit'] as int? ?? 20,
    );
  }
}

/// 获取未接收消息请求
///
/// 查询指定设备的未接收消息（本机deviceId，而非proxy的deviceId）
class GetUnreceivedMessagesRequest {
  final String employeeId;

  /// 接收设备的ID（本机设备ID）
  final String receiverDeviceId;

  /// 偏移量（跳过的消息数），默认0
  final int offset;

  /// 每批数量限制，默认20条
  final int limit;

  const GetUnreceivedMessagesRequest({
    required this.employeeId,
    required this.receiverDeviceId,
    this.offset = 0,
    this.limit = 20,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'receiverDeviceId': receiverDeviceId,
      'offset': offset,
      'limit': limit,
    };
  }

  factory GetUnreceivedMessagesRequest.fromMap(Map<String, dynamic> map) {
    return GetUnreceivedMessagesRequest(
      employeeId: map['employeeId'] as String,
      receiverDeviceId: map['receiverDeviceId'] as String,
      offset: map['offset'] as int? ?? 0,
      limit: map['limit'] as int? ?? 20,
    );
  }
}

/// 标记消息为已接收请求
///
/// 更新消息接收状态到服务端，后续查询不会返回已接收消息（除非状态更新）
class MarkMessagesAsReceivedRequest {
  final String employeeId;

  /// 接收设备的ID（本机设备ID）
  final String receiverDeviceId;

  /// 消息接收列表（包含消息ID和更新时间）
  final List<MessageReceiveInfo> messageReceiveList;

  const MarkMessagesAsReceivedRequest({
    required this.employeeId,
    required this.receiverDeviceId,
    required this.messageReceiveList,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'receiverDeviceId': receiverDeviceId,
      'messageReceiveList': messageReceiveList.map((m) => m.toMap()).toList(),
    };
  }

  factory MarkMessagesAsReceivedRequest.fromMap(Map<String, dynamic> map) {
    return MarkMessagesAsReceivedRequest(
      employeeId: map['employeeId'] as String,
      receiverDeviceId: map['receiverDeviceId'] as String,
      messageReceiveList: (map['messageReceiveList'] as List)
          .map((m) => MessageReceiveInfo.fromMap(m as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 消息接收信息
class MessageReceiveInfo {
  final String messageId;
  final DateTime updateTime;

  const MessageReceiveInfo({
    required this.messageId,
    required this.updateTime,
  });

  Map<String, dynamic> toMap() {
    return {
      'messageId': messageId,
      'updateTime': updateTime.toIso8601String(),
    };
  }

  factory MessageReceiveInfo.fromMap(Map<String, dynamic> map) {
    return MessageReceiveInfo(
      messageId: map['messageId'] as String,
      updateTime: DateTime.parse(map['updateTime'] as String),
    );
  }
}

/// 增量拉取消息请求（基于 LSN）
///
/// 客户端通过 lastSeq 获取 seq > lastSeq 的消息
class GetMessagesAfterSeqRequest {
  final String employeeId;

  /// 客户端已同步到的最大 seq
  final int lastSeq;

  /// 每批数量限制，默认20条
  final int limit;

  const GetMessagesAfterSeqRequest({
    required this.employeeId,
    this.lastSeq = 0,
    this.limit = 20,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'lastSeq': lastSeq,
      'limit': limit,
    };
  }

  factory GetMessagesAfterSeqRequest.fromMap(Map<String, dynamic> map) {
    return GetMessagesAfterSeqRequest(
      employeeId: map['employeeId'] as String,
      lastSeq: map['lastSeq'] as int? ?? 0,
      limit: map['limit'] as int? ?? 20,
    );
  }
}

/// 分页获取会话消息请求
class GetSessionMessagesPagedRequest {
  final String employeeId;

  /// 每页数量
  final int pageSize;

  /// 偏移量（跳过的消息数）
  final int offset;

  const GetSessionMessagesPagedRequest({
    required this.employeeId,
    this.pageSize = 20,
    this.offset = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'pageSize': pageSize,
      'offset': offset,
    };
  }

  factory GetSessionMessagesPagedRequest.fromMap(Map<String, dynamic> map) {
    return GetSessionMessagesPagedRequest(
      employeeId: map['employeeId'] as String,
      pageSize: map['pageSize'] as int? ?? 20,
      offset: map['offset'] as int? ?? 0,
    );
  }
}

/// 清空会话请求
class ClearSessionRequest {
  final String employeeId;

  const ClearSessionRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory ClearSessionRequest.fromMap(Map<String, dynamic> map) {
    return ClearSessionRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 标记消息为已读请求
///
/// 当用户打开会话查看消息时，设备通过此方法通知 Agent 消息已读
class MarkMessagesAsReadRequest {
  final String employeeId;

  /// 已读设备ID
  final String readerDeviceId;

  /// 指定消息ID列表，为 null 则标记该员工所有消息
  final List<String>? messageIds;

  const MarkMessagesAsReadRequest({
    required this.employeeId,
    required this.readerDeviceId,
    this.messageIds,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'readerDeviceId': readerDeviceId,
      if (messageIds != null) 'messageIds': messageIds,
    };
  }

  factory MarkMessagesAsReadRequest.fromMap(Map<String, dynamic> map) {
    return MarkMessagesAsReadRequest(
      employeeId: map['employeeId'] as String,
      readerDeviceId: map['readerDeviceId'] as String,
      messageIds: (map['messageIds'] as List?)?.cast<String>(),
    );
  }
}

/// 查询消息已读状态请求
///
/// 设备重新打开时可通过此方法从 Agent 查询哪些消息已读
class GetMessagesReadStatusRequest {
  final String employeeId;

  /// 查询设备ID
  final String deviceId;

  const GetMessagesReadStatusRequest({
    required this.employeeId,
    required this.deviceId,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'deviceId': deviceId,
    };
  }

  factory GetMessagesReadStatusRequest.fromMap(Map<String, dynamic> map) {
    return GetMessagesReadStatusRequest(
      employeeId: map['employeeId'] as String,
      deviceId: map['deviceId'] as String,
    );
  }
}
