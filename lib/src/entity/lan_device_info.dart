import 'lan_client.dart';

/// LAN 设备信息（返回给客户端）
class LanDeviceInfo {
  /// 设备 ID
  final String id;

  /// 设备名称
  final String? name;

  /// 设备 IP
  final String? ip;

  /// 设备所属空间 ID
  final String? spaceId;

  /// 连接时间
  final DateTime? connectedAt;

  /// 是否为 Host
  final bool isHost;

  LanDeviceInfo({
    required this.id,
    this.name,
    this.ip,
    this.spaceId,
    this.connectedAt,
    this.isHost = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'ip': ip,
        'spaceId': spaceId,
        'connectedAt': connectedAt?.toIso8601String(),
        'isHost': isHost,
      };

  factory LanDeviceInfo.fromMap(Map<String, dynamic> map) {
    return LanDeviceInfo(
      id: map['id'] as String? ?? '',
      name: map['name'] as String?,
      ip: map['ip'] as String?,
      spaceId: map['spaceId'] as String?,
      connectedAt: map['connectedAt'] != null
          ? DateTime.parse(map['connectedAt'] as String)
          : null,
      isHost: map['isHost'] as bool? ?? false,
    );
  }

  factory LanDeviceInfo.fromLanClient(LanClient client) {
    return LanDeviceInfo(
      id: client.id ?? '',
      name: client.name,
      ip: client.ip,
      spaceId: client.spaceId,
      connectedAt: client.connectedAt,
      isHost: false,
    );
  }

  @override
  String toString() {
    return 'LanDeviceInfo(id: ${id.substring(0, id.length > 8 ? 8 : id.length)}, name: $name, ip: $ip, spaceId: $spaceId)';
  }
}
