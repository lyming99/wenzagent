import 'dart:async';

import '../agent/client/cached_agent_proxy.dart';
import '../entity/lan_device_info.dart';
import '../entity/lan_message.dart';
import '../persistence/entities/device_config_entity.dart';
import '../service/service.dart';

/// 设备连接状态
enum DeviceConnectionState {
  /// 已断开
  disconnected,

  /// 连接中
  connecting,

  /// 已连接
  connected,

  /// 重连中
  reconnecting,
}

/// LAN消息处理器
typedef LanMessageHandler = void Function(LanMessage message);

/// DeviceClient 抽象类 - 设备级统一入口
///
/// 核心概念：
/// - deviceId = spaceId，作为数据隔离标识
/// - 员工绑定设备 = 员工在该设备上线
/// - AgentProxy = 会话窗口代理，用于与员工对话
/// - 数据同步通过LAN RPC自动实现
///
/// 业务操作通过暴露的Service属性访问：
/// - employeeManager: 员工CRUD操作
/// - sessionManager: 会话管理
/// - skillManager: 技能管理
/// - messageStore: 消息存储
/// - configService: 员工配置管理（包含MCP配置）
abstract class DeviceClient {
  // ===== 只读属性 =====

  /// 设备ID（也是spaceId，用于数据隔离）
  String get deviceId;

  /// 设备名称
  String? get deviceName;

  /// 服务器主机
  String get host;

  /// 服务器端口
  int get port;

  /// 分组主题
  String? get topic;

  /// 当前连接状态
  DeviceConnectionState get connectionState;

  /// 是否已连接
  bool get isConnected;

  /// 本地 AgentProxy ID 列表 (格式: employeeId)
  List<String> get localAgentProxyIds;

  /// 远程 AgentProxy ID 列表 (格式: deviceId:employeeId)
  List<String> get remoteAgentProxyIds;

  /// 连接状态流
  Stream<DeviceConnectionState> get onStateChanged;

  /// Agent 事件流
  Stream<Map<String, dynamic>> get onAgentEvent;

  /// 设备事件流（上线、下线、信息变更）
  Stream<DeviceEvent> get onDeviceEvent;

  /// 缓存的设备列表
  List<LanDeviceInfo> get cachedDevices;

  // ===== Service 属性 =====

  /// 获取员工管理器
  EmployeeManager get employeeManager;

  /// 获取会话管理器
  SessionManager get sessionManager;

  /// 获取技能管理器
  SkillManager get skillManager;

  /// 获取消息存储服务
  MessageStoreService get messageStore;

  /// 获取员工配置服务
  ///
  /// 提供员工完整配置的获取和更新，包括：
  /// - 基础信息、Provider配置、权限配置
  /// - MCP配置（支持多MCP服务）
  EmployeeConfigService get configService;

  // ===== 连接管理 =====

  /// 连接到服务器
  Future<void> connect();

  /// 重新连接到服务器
  ///
  /// [newHost] 新的服务器主机地址，如果为null则使用当前host
  /// [newPort] 新的服务器端口，如果为null则使用当前port
  /// 该方法会先断开当前连接（如果已连接），然后使用新的参数重新连接
  Future<void> reconnect({String? newHost, int? newPort});

  /// 断开连接
  Future<void> disconnect();

  /// 释放资源
  Future<void> dispose();

  // ===== AgentProxy 管理（核心） =====

  /// 获取或创建 AgentProxy
  ///
  /// [employeeId] 员工UUID
  /// [deviceId] 设备ID，为null则使用本设备
  ///
  /// - 如果员工在本设备上线，创建本地AgentProxy（直接调用Agent）
  /// - 如果员工在其他设备上线，创建远程AgentProxy（通过RPC调用）
  ///
  /// 返回的 CachedAgentProxy 会自动判断：
  /// - 本地模式：直接透传，不缓存（本地Agent已有持久化）
  /// - 远程模式：启用缓存，支持离线查看
  ///
  /// 每个 AgentProxy 代表一个员工会话窗口
  Future<CachedAgentProxy> getOrCreateAgentProxy({
    required String employeeId,
    String? deviceId,
  });

  /// 销毁 AgentProxy
  ///
  /// [employeeId] 员工UUID
  Future<void> destroyAgentProxy(String employeeId);

  /// 获取已创建的 AgentProxy
  ///
  /// 会依次查找本地代理和远程代理
  CachedAgentProxy? getAgentProxy(String employeeId);

  /// 获取所有本地 AgentProxy
  List<CachedAgentProxy> getLocalAgentProxies();
  
  /// 获取所有远程 AgentProxy
  List<CachedAgentProxy> getRemoteAgentProxies();
  
  /// 获取所有 AgentProxy（本地 + 远程）
  List<CachedAgentProxy> getAllAgentProxies();

  // ===== 设备管理 =====

  /// 获取在线设备列表
  Future<List<LanDeviceInfo>> getOnlineDevices();

  /// 获取在线设备列表（带员工信息）
  Future<List<DeviceWithEmployeesInfo>> getOnlineDevicesWithEmployees();

  /// 刷新设备缓存列表
  ///
  /// 连接成功后自动调用，也可手动触发刷新
  Future<void> refreshDeviceList();

  /// 向指定设备发送消息
  ///
  /// [toDeviceId] 目标设备 ID
  /// [message] 消息内容
  Future<void> sendToDevice(String toDeviceId, LanMessage message);

  /// 请求设备信息广播
  ///
  /// 向局域网请求所有设备回复自己的详细信息
  Future<void> requestDeviceInfoBroadcast();

  // ===== 设备配置 =====

  /// 获取设备配置
  ///
  /// 如果配置不存在，会自动创建一个默认配置
  Future<DeviceConfigEntity> getDeviceConfig();

  /// 更新设备信息配置
  ///
  /// [deviceInfo] 设备信息配置对象
  Future<void> updateDeviceInfo(DeviceInfoConfig deviceInfo);

  /// 更新设备环境变量
  ///
  /// [environmentVariables] 环境变量映射表
  Future<void> updateEnvironmentVariables(Map<String, String> environmentVariables);

  /// 设置单个环境变量
  ///
  /// [key] 环境变量名
  /// [value] 环境变量值
  Future<void> setEnvironmentVariable(String key, String value);

  /// 删除单个环境变量
  ///
  /// [key] 环境变量名
  Future<void> deleteEnvironmentVariable(String key);

  // ===== 数据同步（内部LAN RPC实现） =====

  /// 从其他设备同步员工数据
  ///
  /// 通过LAN RPC查询其他设备的员工数据并合并
  Future<void> syncEmployeesFromDevices();

  /// 从其他设备同步会话数据
  ///
  /// 通过LAN RPC查询其他设备的会话数据并合并
  Future<void> syncSessionsFromDevices();

  // ===== LAN消息扩展 =====

  /// 设置LAN消息接收处理器
  ///
  /// 外部可通过此方法接收LAN消息，用于自定义数据同步等
  void setLanMessageHandler(LanMessageHandler? handler);

  /// 发送LAN消息
  ///
  /// 外部可通过此方法发送自定义LAN消息
  Future<void> sendLanMessage(LanMessage message);

  /// 发送LAN消息到指定设备
  Future<void> sendLanMessageTo(String toDeviceId, LanMessage message);

  /// 获取LAN消息流
  Stream<LanMessage> get onLanMessage;

  // ===== 文件传输 =====

  /// 上传文件
  Future<String> uploadFile(
    String filePath, {
    void Function(double)? onProgress,
  });

  /// 下载文件
  Future<void> downloadFile(
    String fileId,
    String savePath, {
    void Function(double)? onProgress,
  });
}

/// 设备与员工信息
class DeviceWithEmployeesInfo {
  final String deviceId;
  final String? deviceName;
  final String? ip;
  final DateTime? connectedAt;
  final List<EmployeeBriefInfo> employees;

  DeviceWithEmployeesInfo({
    required this.deviceId,
    this.deviceName,
    this.ip,
    this.connectedAt,
    required this.employees,
  });

  Map<String, dynamic> toMap() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'ip': ip,
    'connectedAt': connectedAt?.millisecondsSinceEpoch,
    'employees': employees.map((e) => e.toMap()).toList(),
  };
}

/// 员工简要信息
class EmployeeBriefInfo {
  final String uuid;
  final String name;
  final String status;
  final String? deviceId;

  EmployeeBriefInfo({
    required this.uuid,
    required this.name,
    required this.status,
    this.deviceId,
  });

  Map<String, dynamic> toMap() => {
    'uuid': uuid,
    'name': name,
    'status': status,
    'deviceId': deviceId,
  };
}
