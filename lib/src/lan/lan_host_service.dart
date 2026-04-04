import '../entity/lan_client.dart';
import '../entity/lan_message.dart';

/// 局域网服务端接口
abstract class LanHostService {
  /// 是否正在运行
  bool get isRunning;

  /// 本机 IP
  String? get localIp;

  /// 服务端口
  int get port;

  /// 已连接的客户端列表
  List<LanClient> get clients;

  /// 消息流（接收来自客户端的消息）
  Stream<LanMessage> get messageStream;

  /// 启动服务端
  /// [port] 服务端口
  /// [storageDir] 文件存储目录，为空则使用临时目录
  Future<void> start({int port = 9090, String? storageDir});

  /// 停止服务端
  Future<void> stop();

  /// 广播消息到所有客户端
  void broadcast(LanMessage message);

  /// 发送消息到指定客户端
  void sendToClient(String clientId, LanMessage message);

  /// 发送消息到指定 deviceId
  void sendToDeviceId(String deviceId, LanMessage message);

  /// 断开指定客户端
  void disconnectClient(String clientId);

  /// 保存上传的文件，返回 fileId
  Future<String> saveFile(List<int> data, String fileName);

  /// 获取文件数据
  Future<List<int>?> getFile(String fileId);

  /// 获取服务端信息
  Future<Map<String, dynamic>> getHostInfo();
}
