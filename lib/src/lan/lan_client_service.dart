import '../entity/lan_message.dart';

/// 局域网客户端接口
abstract class LanClientService {
  /// 是否已连接
  bool get isConnected;

  /// 是否正在连接
  bool get isConnecting;

  /// 设备 ID
  String get deviceId;

  /// 分组 Topic
  String? get topic;

  /// Host IP
  String? get hostIp;

  /// Host 端口
  int get hostPort;

  /// 消息流（接收来自 Host 的消息）
  Stream<LanMessage> get messageStream;

  /// 上传进度 (0.0 - 1.0)
  double get uploadProgress;

  /// 下载进度 (0.0 - 1.0)
  double get downloadProgress;

  /// 连接到 Host
  Future<void> connect(String hostIp, {int port = 9090});

  /// 断开连接
  Future<void> disconnect();

  /// 发送文本消息
  void sendMessage(String content);

  /// 发送 LanMessage 对象
  void sendLanMessage(LanMessage message);

  /// 上传文件到 Host（返回 fileId）
  Future<String> uploadFile(String filePath);

  /// 从 Host 下载文件
  Future<void> downloadFile(String fileId, String savePath);

  /// 获取客户端信息
  Future<Map<String, dynamic>> getClientInfo();

  /// 手动触发重连
  Future<void> reconnect();
}
