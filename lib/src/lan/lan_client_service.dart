import 'dart:typed_data';

import '../entity/lan_message.dart';
import 'entity/client_info.dart';

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
  ///
  /// 返回 true 表示发送成功或已缓存待重发，false 表示发送失败且无法缓存。
  /// 断线时消息会自动缓存，重连后自动重发。
  Future<bool> sendLanMessage(LanMessage message);

  /// 上传文件到 Host（返回 fileId）
  Future<String> uploadFile(String filePath);

  /// 从 Host 下载文件
  Future<void> downloadFile(String fileId, String savePath);

  /// 获取客户端信息
  Future<ClientInfo> getClientInfo();

  /// 手动触发重连
  Future<void> reconnect();

  /// 发送二进制消息（通过 WebSocket 原生二进制帧）
  void sendBinaryMessage(Uint8List data);

  /// 二进制 chunk 事件流
  ///
  /// 接收解析后的二进制帧，按 requestId 分发。
  Stream<BinaryChunkEvent> get binaryChunkStream;
}

/// 二进制 chunk 事件
///
/// 解析 WebSocket 二进制帧后的结构化事件。
class BinaryChunkEvent {
  /// 关联的 RPC 请求 ID
  final String requestId;

  /// 原始二进制数据（不含帧头）
  final Uint8List data;

  /// 是否为最后一个 chunk
  final bool isLast;

  const BinaryChunkEvent({
    required this.requestId,
    required this.data,
    required this.isLast,
  });

  @override
  String toString() =>
      'BinaryChunkEvent(requestId: $requestId, dataLen: ${data.length}, isLast: $isLast)';
}
