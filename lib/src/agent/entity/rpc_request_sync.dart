// RPC 请求参数实体类 - 同步水位线相关请求

/// 获取最小 seq 请求
///
/// 客户端查询远程最早保留消息的 seq，
/// 用于清理本地过期消息（seq < minSeq 的可以安全删除）
class GetMinSeqRequest {
  final String employeeId;

  const GetMinSeqRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetMinSeqRequest.fromMap(Map<String, dynamic> map) {
    return GetMinSeqRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 获取清空水位线请求
///
/// 客户端查询服务端是否设置了清空水位线，
/// 如果 clearSeq > 0，客户端应删除本地 seq < clearSeq 的消息。
class GetClearSeqRequest {
  final String employeeId;

  const GetClearSeqRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetClearSeqRequest.fromMap(Map<String, dynamic> map) {
    return GetClearSeqRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 更新同步水位线请求
///
/// 客户端同步完成后更新本地水位线
class UpdateSyncWatermarkRequest {
  final String employeeId;

  /// 已同步到的最大 seq
  final int lastSeq;

  const UpdateSyncWatermarkRequest({
    required this.employeeId,
    required this.lastSeq,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'lastSeq': lastSeq,
    };
  }

  factory UpdateSyncWatermarkRequest.fromMap(Map<String, dynamic> map) {
    return UpdateSyncWatermarkRequest(
      employeeId: map['employeeId'] as String,
      lastSeq: map['lastSeq'] as int,
    );
  }
}
