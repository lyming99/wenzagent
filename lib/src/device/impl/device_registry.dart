import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../entity/lan_device_info.dart';
import '../../entity/lan_message.dart';
import '../../service/service.dart';
import '../device_client.dart';
import 'device_config_manager.dart';
import 'device_connection_manager.dart';

/// 设备注册表
///
/// 负责设备列表缓存、设备注册、在线设备查询。
class DeviceRegistry {
  final String _deviceId;
  String? _deviceName;
  String _host;
  int _port;
  String? _topic;
  late final EmployeeManager _employeeManager = EmployeeManager.getInstance(_deviceId);
  late final DeviceConnectionManager _connectionManager = DeviceConnectionManager.getInstance(_deviceId);
  late final DeviceConfigManager _configManager = DeviceConfigManager.getInstance(_deviceId);

  final Map<String, LanDeviceInfo> _deviceCache = {};

  DeviceRegistry._({
    required String deviceId,
    String? deviceName,
    required String host,
    required int port,
    String? topic,
  })  : _deviceId = deviceId,
        _deviceName = deviceName,
        _host = host,
        _port = port,
        _topic = topic;

  // ===== 单例管理 =====

  static final Map<String, DeviceRegistry> _instances = {};

  static DeviceRegistry getInstance(String deviceId) {
    return _instances.putIfAbsent(
      deviceId,
      () => DeviceRegistry._(
        deviceId: deviceId,
        host: '',
        port: 9090,
      ),
    );
  }

  /// 初始化配置
  void initialize({String? deviceName, String? host, int? port, String? topic}) {
    updateConfig(deviceName: deviceName, host: host, port: port, topic: topic);
  }

  static void removeInstance(String deviceId) {
    _instances.remove(deviceId);
  }

  // ===== 配置更新 =====

  void updateConfig({String? deviceName, String? host, int? port, String? topic}) {
    if (deviceName != null) _deviceName = deviceName;
    if (host != null) _host = host;
    if (port != null) _port = port;
    if (topic != null) _topic = topic;
  }

  // ===== 公开访问 =====

  List<LanDeviceInfo> get cachedDevices => _deviceCache.values.toList();

  void updateDeviceCache(String devId, LanDeviceInfo device) =>
      _deviceCache[devId] = device;

  void removeDeviceCache(String devId) => _deviceCache.remove(devId);

  LanDeviceInfo? getDeviceCache(String devId) => _deviceCache[devId];

  void clearDeviceCache() => _deviceCache.clear();

  bool containsDevice(String devId) => _deviceCache.containsKey(devId);

  /// 获取在线设备列表（通过 HTTP API 查询）
  Future<List<LanDeviceInfo>> getOnlineDevices() async {
    if (!_connectionManager.isConnected) throw StateError('未连接到服务器');
    try {
      final lanClient = _connectionManager.lanClient;
      final apiHost = lanClient?.hostIp ?? _host;
      final apiPort = lanClient?.hostPort ?? _port;
      final qp = <String, String>{};
      if (_topic?.isNotEmpty == true) qp['topic'] = _topic!;
      final uri = Uri.http(
        '$apiHost:$apiPort',
        'api/devices/online',
        qp.isEmpty ? null : qp,
      );
      final client = HttpClient();
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('获取在线设备列表超时'),
      );
      if (response.statusCode != 200) return [];
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final devices =
          (data['devices'] as List?)
              ?.map((d) => LanDeviceInfo.fromMap(d as Map<String, dynamic>))
              .toList() ??
          [];
      return devices.map((device) {
        final cached = _deviceCache[device.id];
        if (cached != null) {
          return cached.copyWith(
            name: device.name ?? cached.name,
            ip: device.ip,
            connectedAt: device.connectedAt,
            isHost: device.isHost,
            status: device.status ?? 'online',
          );
        }
        if (device.id == _deviceId) return _buildLocalDeviceInfo(device);
        return device;
      }).toList();
    } catch (e) {
      print('获取在线设备列表失败: $e');
      return [];
    }
  }

  /// 获取在线设备列表（带员工信息）
  Future<List<DeviceWithEmployeesInfo>> getOnlineDevicesWithEmployees() async {
    final devices = await getOnlineDevices();
    final allEmployees = await _employeeManager.getEmployees();
    final byDevice = <String, List<dynamic>>{};
    for (final emp in allEmployees) {
      if (emp.deviceId != null && emp.deviceId!.isNotEmpty) {
        byDevice.putIfAbsent(emp.deviceId!, () => []).add(emp);
      }
    }
    return devices
        .map(
          (d) => DeviceWithEmployeesInfo(
            deviceId: d.id,
            deviceName: d.name,
            ip: d.ip,
            connectedAt: d.connectedAt,
            employees: (byDevice[d.id] ?? [])
                .map(
                  (e) => EmployeeBriefInfo(
                    uuid: e.uuid,
                    name: e.name,
                    status: e.status,
                    deviceId: e.deviceId,
                  ),
                )
                .toList(),
          ),
        )
        .toList();
  }

  /// 刷新设备缓存
  Future<void> refreshDeviceList() async {
    try {
      final devices = await getOnlineDevices();
      _deviceCache.clear();
      for (final d in devices) {
        _deviceCache[d.id] = d.copyWith(status: 'online');
      }
    } catch (_) {}
  }

  /// 发送设备注册消息
  Future<void> sendDeviceRegistration() async {
    final lc = _connectionManager.lanClient;
    if (lc == null || !lc.isConnected) return;
    String? effectiveName = _deviceName;
    try {
      final config = await _configManager.getDeviceConfig();
      final info = config.deviceInfo;
      if (info.name != null) effectiveName = info.name;
        } catch (_) {}
    final (os, platform) = _detectPlatform();
    lc.sendLanMessage(
      LanMessage(
        type: LanMessageType.clientInfo,
        fromId: _deviceId,
        fromName: effectiveName,
        content: jsonEncode({
          'deviceId': _deviceId,
          'deviceName': effectiveName,
          'topic': _topic,
          'os': os,
          'platform': platform,
          'ip': _connectionManager.localIp,
        }),
        fileName: _deviceId,
        topic: _topic ?? '',
      ),
    );
  }

  /// 向指定设备发送消息
  void sendToDevice(String toDeviceId, LanMessage message) {
    final lc = _connectionManager.lanClient;
    if (lc == null || !lc.isConnected) throw StateError('未连接到服务器');
    lc.sendLanMessage(
      LanMessage(
        type: LanMessageType.deviceMessage,
        fromId: _deviceId,
        fromName: _deviceName,
        toDeviceId: toDeviceId,
        content: message.content,
        fileName: message.fileName,
        topic: message.topic ?? _topic,
      ),
    );
  }

  /// 请求设备信息广播
  void requestDeviceInfoBroadcast() {
    final lc = _connectionManager.lanClient;
    if (lc == null || !lc.isConnected) throw StateError('未连接到服务器');
    lc.sendLanMessage(
      LanMessage(
        type: LanMessageType.deviceInfoRequest,
        fromId: _deviceId,
        fromName: _deviceName,
        content: jsonEncode({
          'deviceId': _deviceId,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
        topic: _topic,
      ),
    );
  }

  // ===== 内部方法 =====

  (String?, String?) _detectPlatform() {
    if (Platform.isAndroid) return ('android', 'mobile');
    if (Platform.isIOS) return ('ios', 'mobile');
    if (Platform.isWindows) return ('windows', 'desktop');
    if (Platform.isMacOS) return ('macos', 'desktop');
    if (Platform.isLinux) return ('linux', 'desktop');
    return (null, null);
  }

  LanDeviceInfo _buildLocalDeviceInfo(LanDeviceInfo base) {
    final (os, platform) = _detectPlatform();
    return base.copyWith(
      name: base.name ?? _deviceName,
      type: base.type ?? platform,
      os: base.os ?? os,
      platform: base.platform ?? platform,
      status: base.status ?? 'online',
    );
  }
}
