/// 上下文压缩元数据实体
///
/// 存储在 context_compression_meta 表中，记录会话级别的压缩状态。
/// DB 只记录压缩位置（prune_start_id = 消息 UUID），压缩在内存中完成。
/// 由 CompressionMetaStore 管理，ContextCompressor 读写。
class CompressionMetaEntity {
  /// 员工/会话 ID
  final String employeeId;

  /// 设备 ID
  final String deviceId;

  /// 压缩边界消息 ID（UUID）
  ///
  /// 从此消息开始保留原文，之前的消息在 LLM 视图中被省略。
  /// 空字符串表示未压缩。
  String pruneStartId;

  /// 上次压缩时间戳（epoch ms）
  int lastCompressionTime;

  /// 压缩后新增的消息数（用于冷却期判断）
  int messagesSinceCompression;

  /// 行更新时间（epoch ms）
  int updateTime;

  CompressionMetaEntity({
    required this.employeeId,
    required this.deviceId,
    this.pruneStartId = '',
    this.lastCompressionTime = 0,
    this.messagesSinceCompression = 0,
    required this.updateTime,
  });

  /// 是否处于压缩状态
  bool get isCompressed => pruneStartId.isNotEmpty;

  /// 转换为 Map（写入 DB）
  Map<String, dynamic> toMap() => {
        'employee_id': employeeId,
        'device_id': deviceId,
        'prune_start_id': pruneStartId,
        'last_compression_time': lastCompressionTime,
        'messages_since_compression': messagesSinceCompression,
        'update_time': updateTime,
      };

  /// 从 Map 创建（读取 DB）
  factory CompressionMetaEntity.fromMap(Map<String, dynamic> map) {
    return CompressionMetaEntity(
      employeeId: (map['employee_id'] ?? '') as String,
      deviceId: (map['device_id'] ?? '') as String,
      pruneStartId: (map['prune_start_id'] ?? '') as String,
      lastCompressionTime: (map['last_compression_time'] ?? 0) as int,
      messagesSinceCompression:
          (map['messages_since_compression'] ?? 0) as int,
      updateTime: (map['update_time'] ?? 0) as int,
    );
  }

  @override
  String toString() =>
      'CompressionMetaEntity('
      'employeeId: $employeeId, '
      'deviceId: $deviceId, '
      'pruneStartId: $pruneStartId, '
      'messagesSinceCompression: $messagesSinceCompression)';
}
