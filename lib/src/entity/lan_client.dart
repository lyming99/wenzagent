/// LAN 客户端实体
class LanClient {
  /// 唯一标识
  String? id;

  /// 客户端 IP
  String? ip;

  /// 设备 ID
  String? deviceId;

  /// 设备名称
  String? name;

  /// 分组 Topic
  String? topic;

  /// 连接时间
  DateTime? connectedAt;

  /// 最后一次 pong 响应时间（Host 端用于判断 Client 存活）
  DateTime? lastPongTime;

  LanClient({
    this.id,
    this.ip,
    this.deviceId,
    this.name,
    this.topic,
    this.connectedAt,
    this.lastPongTime,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'ip': ip,
        'deviceId': deviceId,
        'name': name,
        'topic': topic,
        'connectedAt': connectedAt?.toIso8601String(),
      };

  factory LanClient.fromJson(Map<String, dynamic> json) => LanClient(
        id: json['deviceId'] as String? ?? json['id'] as String?,
        ip: json['ip'] as String?,
        deviceId: json['deviceId'] as String?,
        name: json['name'] as String?,
        topic: json['topic'] as String?,
        connectedAt: json['connectedAt'] != null
            ? DateTime.parse(json['connectedAt'] as String)
            : null,
      );

  LanClient copyWith({
    String? id,
    String? ip,
    String? deviceId,
    String? name,
    String? topic,
    DateTime? connectedAt,
    DateTime? lastPongTime,
  }) {
    return LanClient(
      id: id ?? this.id,
      ip: ip ?? this.ip,
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
      topic: topic ?? this.topic,
      connectedAt: connectedAt ?? this.connectedAt,
      lastPongTime: lastPongTime ?? this.lastPongTime,
    );
  }

  @override
  String toString() {
    return 'LanClient(id: $id, deviceId: $deviceId, name: $name, ip: $ip)';
  }
}
