/// 同步水位线实体
///
/// 客户端本地记录每个 employee（会话）已同步到的消息序列号。
class SyncWatermarkEntity {
  /// 会话ID（对应 employee_id）
  final String employeeId;

  /// 已同步到的最大 seq
  int lastSeq;

  /// 清空水位线：当客户端同步时检测到此值，
  /// 应删除本地所有 seq < clearSeq 的消息，然后清除此标记。
  int? clearSeq;

  /// 最后更新时间
  DateTime updateTime;

  SyncWatermarkEntity({
    required this.employeeId,
    this.lastSeq = 0,
    this.clearSeq,
    required this.updateTime,
  });

  factory SyncWatermarkEntity.fromMap(Map<String, dynamic> map) {
    return SyncWatermarkEntity(
      employeeId: map['employeeId'] as String,
      lastSeq: map['lastSeq'] as int? ?? 0,
      clearSeq: map['clearSeq'] as int?,
      updateTime: map['updateTime'] is DateTime
          ? map['updateTime'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(map['updateTime'] as int? ?? 0),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'lastSeq': lastSeq,
      'clearSeq': clearSeq,
      'updateTime': updateTime.millisecondsSinceEpoch,
    };
  }
}
