import 'lan_client.dart';

/// LAN 设备信息（返回给客户端）
class LanDeviceInfo {
  /// 设备 ID
  final String id;

  /// 设备名称
  final String? name;

  /// 设备 IP
  final String? ip;

  /// 连接时间
  final DateTime? connectedAt;

  /// 是否为 Host
  final bool isHost;

  /// 设备类型 (mobile, desktop, web)
  final String? type;

  /// 操作系统 (android, ios, windows, macos, linux)
  final String? os;

  /// 操作系统版本
  final String? osVersion;

  /// 应用版本
  final String? appVersion;

  /// 平台标识
  final String? platform;

  /// 所属空间 ID
  final String? spaceId;

  /// 设备上的员工数量
  final int? employeeCount;

  /// 设备状态 (online, offline)
  final String? status;

  LanDeviceInfo({
    required this.id,
    this.name,
    this.ip,
    this.connectedAt,
    this.isHost = false,
    this.type,
    this.os,
    this.osVersion,
    this.appVersion,
    this.platform,
    this.spaceId,
    this.employeeCount,
    this.status,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'ip': ip,
        'connectedAt': connectedAt?.toIso8601String(),
        'isHost': isHost,
        if (type != null) 'type': type,
        if (os != null) 'os': os,
        if (osVersion != null) 'osVersion': osVersion,
        if (appVersion != null) 'appVersion': appVersion,
        if (platform != null) 'platform': platform,
        if (spaceId != null) 'spaceId': spaceId,
        if (employeeCount != null) 'employeeCount': employeeCount,
        if (status != null) 'status': status,
      };

  factory LanDeviceInfo.fromMap(Map<String, dynamic> map) {
    return LanDeviceInfo(
      id: map['deviceId'] as String? ?? map['id'] as String? ?? '',
      name: map['name'] as String?,
      ip: map['ip'] as String?,
      connectedAt: map['connectedAt'] != null
          ? DateTime.parse(map['connectedAt'] as String)
          : null,
      isHost: map['isHost'] as bool? ?? false,
      type: map['type'] as String?,
      os: map['os'] as String?,
      osVersion: map['osVersion'] as String?,
      appVersion: map['appVersion'] as String?,
      platform: map['platform'] as String?,
      spaceId: map['spaceId'] as String?,
      employeeCount: map['employeeCount'] as int?,
      status: map['status'] as String?,
    );
  }

  factory LanDeviceInfo.fromLanClient(LanClient client) {
    return LanDeviceInfo(
      id: client.deviceId ?? client.id ?? '',
      name: client.name,
      ip: client.ip,
      connectedAt: client.connectedAt,
      isHost: false,
      status: 'online',
    );
  }

  /// 创建副本，支持覆盖指定字段
  LanDeviceInfo copyWith({
    String? id,
    String? name,
    String? ip,
    DateTime? connectedAt,
    bool? isHost,
    String? type,
    String? os,
    String? osVersion,
    String? appVersion,
    String? platform,
    String? spaceId,
    int? employeeCount,
    String? status,
  }) {
    return LanDeviceInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      connectedAt: connectedAt ?? this.connectedAt,
      isHost: isHost ?? this.isHost,
      type: type ?? this.type,
      os: os ?? this.os,
      osVersion: osVersion ?? this.osVersion,
      appVersion: appVersion ?? this.appVersion,
      platform: platform ?? this.platform,
      spaceId: spaceId ?? this.spaceId,
      employeeCount: employeeCount ?? this.employeeCount,
      status: status ?? this.status,
    );
  }

  @override
  String toString() {
    return 'LanDeviceInfo(id: ${id.substring(0, id.length > 8 ? 8 : id.length)}, name: $name, ip: $ip)';
  }
}
