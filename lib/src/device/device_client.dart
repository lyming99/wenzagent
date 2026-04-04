import 'dart:async';

import '../agent/client/agent_proxy.dart';
import '../agent/i_agent.dart';
import '../entity/lan_device_info.dart';

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

/// DeviceClient 抽象类 - 设备级统一入口
///
/// 管理本地和远程 Agent，支持断线重连、设备列表查询、文件上传下载。
abstract class DeviceClient {
  // ===== 只读属性 =====

  /// 设备ID
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

  /// 本地 Agent ID 列表
  List<String> get localAgentIds;

  /// 远程 Agent ID 列表
  List<String> get remoteAgentIds;

  /// 连接状态流
  Stream<DeviceConnectionState> get onStateChanged;

  /// Agent 事件流
  Stream<Map<String, dynamic>> get onAgentEvent;

  // ===== 连接管理 =====

  /// 连接到服务器
  Future<void> connect();

  /// 断开连接
  Future<void> disconnect();

  /// 释放资源
  Future<void> dispose();

  // ===== Agent 管理 =====

  /// 注册本地 Agent
  void registerLocalAgent(String employeeId, IAgent agent);

  /// 注销本地 Agent
  void unregisterLocalAgent(String employeeId);

  /// 获取 Agent 代理
  ///
  /// [deviceId] 设备ID
  /// [employeeId] 员工ID
  ///
  /// - 如果 deviceId == 本地 deviceId，从 localProxies 获取
  /// - 否则从 remoteProxies 创建或获取
  AgentProxy getAgent({
    required String deviceId,
    required String employeeId,
  });

  // ===== 设备管理 =====

  /// 获取在线设备列表
  Future<List<LanDeviceInfo>> getOnlineDevices();

  // ===== 文件传输 =====

  /// 上传文件
  ///
  /// [filePath] 文件路径
  /// [onProgress] 进度回调
  /// 返回文件ID
  Future<String> uploadFile(
    String filePath, {
    void Function(double)? onProgress,
  });

  /// 下载文件
  ///
  /// [fileId] 文件ID
  /// [savePath] 保存路径
  /// [onProgress] 进度回调
  Future<void> downloadFile(
    String fileId,
    String savePath, {
    void Function(double)? onProgress,
  });
}
