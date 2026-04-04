import 'package:wenzagent/wenzagent.dart';

void main() async {
  // 示例：创建 LAN Host 服务端
  final host = LanHostServiceImpl();
  await host.start(port: 9090);
  print('Host started at ${host.localIp}:${host.port}');

  // 监听消息
  host.messageStream.listen((message) {
    print('Received: ${message.type} from ${message.fromId}');
  });

  // 示例：创建 LAN Client
  final client = LanClientServiceImpl(deviceId: 'client-001');
  await client.connect(host.localIp!, port: 9090);
  print('Client connected');

  // 发送消息
  client.sendMessage('Hello from client!');

  // 等待一会儿
  await Future.delayed(Duration(seconds: 5));

  // 清理
  await client.disconnect();
  await host.stop();
  print('Done');
}
