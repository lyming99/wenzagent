/// LAN 客户端实体
class LanClient {
  /// 唯一标识
  String? id;

  /// 客户端 IP
  String? ip;

  /// 空间 ID
  String? spaceId;

  /// 设备名称
  String? name;

  /// 分组 Topic
  String? topic;

  /// 连接时间
  DateTime? connectedAt;

  LanClient({
    this.id,
    this.ip,
    this.spaceId,
    this.name,
    this.topic,
    this.connectedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'ip': ip,
        'spaceId': spaceId,
        'name': name,
        'topic': topic,
        'connectedAt': connectedAt?.toIso8601String(),
      };

  factory LanClient.fromJson(Map<String, dynamic> json) => LanClient(
        id: json['id'] as String?,
        ip: json['ip'] as String?,
        spaceId: json['spaceId'] as String?,
        name: json['name'] as String?,
        topic: json['topic'] as String?,
        connectedAt: json['connectedAt'] != null
            ? DateTime.parse(json['connectedAt'] as String)
            : null,
      );

  LanClient copyWith({
    String? id,
    String? ip,
    String? spaceId,
    String? name,
    String? topic,
    DateTime? connectedAt,
  }) {
    return LanClient(
      id: id ?? this.id,
      ip: ip ?? this.ip,
      spaceId: spaceId ?? this.spaceId,
      name: name ?? this.name,
      topic: topic ?? this.topic,
      connectedAt: connectedAt ?? this.connectedAt,
    );
  }

  @override
  String toString() {
    return 'LanClient(id: $id, spaceId: $spaceId, name: $name, ip: $ip)';
  }
}
