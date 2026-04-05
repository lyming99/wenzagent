/// 客户端会话信息
class ClientSession {
  /// 客户端ID
  final String clientId;

  /// 设备ID
  final String deviceId;

  /// 设备名称
  final String? deviceName;

  /// 分组主题
  final String? topic;

  /// 连接时间
  final DateTime connectedAt;

  /// 订阅的员工UUID集合
  final Set<String> subscribedEmployees;

  /// 当前空间ID
  final String? currentSpaceId;

  ClientSession({
    required this.clientId,
    required this.deviceId,
    this.deviceName,
    this.topic,
    required this.connectedAt,
    Set<String>? subscribedEmployees,
    this.currentSpaceId,
  }) : subscribedEmployees = subscribedEmployees ?? {};

  /// 复制并修改
  ClientSession copyWith({
    String? clientId,
    String? deviceId,
    String? deviceName,
    String? topic,
    DateTime? connectedAt,
    Set<String>? subscribedEmployees,
    String? currentSpaceId,
  }) {
    return ClientSession(
      clientId: clientId ?? this.clientId,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      topic: topic ?? this.topic,
      connectedAt: connectedAt ?? this.connectedAt,
      subscribedEmployees: subscribedEmployees ?? Set.from(this.subscribedEmployees),
      currentSpaceId: currentSpaceId ?? this.currentSpaceId,
    );
  }

  /// 转换为Map
  Map<String, dynamic> toMap() {
    return {
      'clientId': clientId,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'topic': topic,
      'connectedAt': connectedAt.millisecondsSinceEpoch,
      'subscribedEmployees': subscribedEmployees.toList(),
      'currentSpaceId': currentSpaceId,
    };
  }

  /// 从Map创建
  factory ClientSession.fromMap(Map<String, dynamic> map) {
    return ClientSession(
      clientId: map['clientId'] as String,
      deviceId: map['deviceId'] as String,
      deviceName: map['deviceName'] as String?,
      topic: map['topic'] as String?,
      connectedAt: map['connectedAt'] is DateTime
          ? map['connectedAt'] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(map['connectedAt'] as int? ?? 0),
      subscribedEmployees: map['subscribedEmployees'] != null
          ? Set<String>.from(map['subscribedEmployees'] as List)
          : null,
      currentSpaceId: map['currentSpaceId'] as String?,
    );
  }

  @override
  String toString() {
    return 'ClientSession(clientId: $clientId, deviceId: $deviceId, deviceName: $deviceName)';
  }
}

/// 客户端会话管理器
class ClientSessionManager {
  /// 客户端会话映射 (clientId -> ClientSession)
  final Map<String, ClientSession> _clients = {};

  /// 设备ID到客户端ID的映射 (deviceId -> Set<clientId>)
  final Map<String, Set<String>> _deviceClients = {};

  /// 主题到客户端的映射 (topic -> Set<clientId>)
  final Map<String, Set<String>> _topicClients = {};

  /// 员工订阅映射 (employeeUuid -> Set<clientId>)
  final Map<String, Set<String>> _employeeSubscribers = {};

  /// 注册客户端
  void registerClient(ClientSession session) {
    _clients[session.clientId] = session;

    // 更新设备索引
    _deviceClients.putIfAbsent(session.deviceId, () => {});
    _deviceClients[session.deviceId]!.add(session.clientId);

    // 更新主题索引
    if (session.topic != null && session.topic!.isNotEmpty) {
      _topicClients.putIfAbsent(session.topic!, () => {});
      _topicClients[session.topic!]!.add(session.clientId);
    }
  }

  /// 注销客户端
  ClientSession? unregisterClient(String clientId) {
    final session = _clients.remove(clientId);
    if (session == null) return null;

    // 更新设备索引
    _deviceClients[session.deviceId]?.remove(clientId);
    if (_deviceClients[session.deviceId]?.isEmpty ?? false) {
      _deviceClients.remove(session.deviceId);
    }

    // 更新主题索引
    if (session.topic != null && session.topic!.isNotEmpty) {
      _topicClients[session.topic]?.remove(clientId);
      if (_topicClients[session.topic]?.isEmpty ?? false) {
        _topicClients.remove(session.topic);
      }
    }

    // 更新员工订阅索引
    for (final employeeUuid in session.subscribedEmployees) {
      _employeeSubscribers[employeeUuid]?.remove(clientId);
      if (_employeeSubscribers[employeeUuid]?.isEmpty ?? false) {
        _employeeSubscribers.remove(employeeUuid);
      }
    }

    return session;
  }

  /// 获取客户端信息
  ClientSession? getClient(String clientId) {
    return _clients[clientId];
  }

  /// 获取指定设备的所有客户端
  List<ClientSession> getClientsByDeviceId(String deviceId) {
    final clientIds = _deviceClients[deviceId];
    if (clientIds == null || clientIds.isEmpty) return [];

    return clientIds
        .map((id) => _clients[id])
        .whereType<ClientSession>()
        .toList();
  }

  /// 获取同主题的所有客户端
  List<ClientSession> getClientsByTopic(String topic) {
    final clientIds = _topicClients[topic];
    if (clientIds == null || clientIds.isEmpty) return [];

    return clientIds
        .map((id) => _clients[id])
        .whereType<ClientSession>()
        .toList();
  }

  /// 订阅员工
  void subscribeEmployee(String clientId, String employeeUuid) {
    final session = _clients[clientId];
    if (session == null) return;

    session.subscribedEmployees.add(employeeUuid);

    // 更新员工订阅索引
    _employeeSubscribers.putIfAbsent(employeeUuid, () => {});
    _employeeSubscribers[employeeUuid]!.add(clientId);
  }

  /// 取消订阅员工
  void unsubscribeEmployee(String clientId, String employeeUuid) {
    final session = _clients[clientId];
    if (session == null) return;

    session.subscribedEmployees.remove(employeeUuid);

    // 更新员工订阅索引
    _employeeSubscribers[employeeUuid]?.remove(clientId);
    if (_employeeSubscribers[employeeUuid]?.isEmpty ?? false) {
      _employeeSubscribers.remove(employeeUuid);
    }
  }

  /// 获取订阅指定员工的所有客户端
  List<ClientSession> getClientsByEmployee(String employeeUuid) {
    final clientIds = _employeeSubscribers[employeeUuid];
    if (clientIds == null || clientIds.isEmpty) return [];

    return clientIds
        .map((id) => _clients[id])
        .whereType<ClientSession>()
        .toList();
  }

  /// 获取所有客户端
  List<ClientSession> getAllClients() {
    return _clients.values.toList();
  }

  /// 获取客户端数量
  int get clientCount => _clients.length;

  /// 获取设备数量
  int get deviceCount => _deviceClients.length;

  /// 清空所有客户端
  void clear() {
    _clients.clear();
    _deviceClients.clear();
    _topicClients.clear();
    _employeeSubscribers.clear();
  }

  /// 获取所有在线设备信息
  List<Map<String, dynamic>> getOnlineDevicesInfo() {
    return _deviceClients.entries.map((entry) {
      final clients = entry.value
          .map((id) => _clients[id])
          .whereType<ClientSession>()
          .toList();
      final firstClient = clients.isNotEmpty ? clients.first : null;

      return {
        'deviceId': entry.key,
        'deviceName': firstClient?.deviceName,
        'topic': firstClient?.topic,
        'connectedAt': firstClient?.connectedAt.millisecondsSinceEpoch,
        'clientCount': clients.length,
        'spaceId': firstClient?.currentSpaceId,
      };
    }).toList();
  }
}
