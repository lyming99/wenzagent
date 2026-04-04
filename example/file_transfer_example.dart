import 'dart:async';
import 'dart:io';

import 'package:wenzagent/wenzagent.dart';

/// 示例1：文件上传下载
///
/// 演示 Host 端提供文件服务，Client 端上传和下载文件。
Future<void> fileTransferExample() async {
  print('=== 文件上传下载示例 ===\n');

  // 1. 启动 Host (使用端口 0 让系统自动分配)
  final host = LanHostServiceImpl();
  await host.start(port: 0); // 端口 0 表示自动分配
  print('Host 已启动: ${host.localIp}:${host.port}');

  // 2. 创建测试文件
  final testDir = Directory('${Directory.systemTemp.path}/wenzagent_test');
  if (!await testDir.exists()) {
    await testDir.create(recursive: true);
  }

  final uploadFile = File('${testDir.path}/upload_test.txt');
  await uploadFile.writeAsString('这是一个测试文件的内容\nHello WenzAgent!\n' * 100);
  print('创建测试文件: ${uploadFile.path}');

  // 3. Client 连接到 Host
  final client = LanClientServiceImpl(deviceId: 'file-client');
  await client.connect(host.localIp!, port: host.port);
  print('Client 已连接');

  // 4. 上传文件
  print('\n--- 上传文件 ---');
  try {
    final fileId = await client.uploadFile(uploadFile.path);
    print('上传成功! fileId: $fileId');
  } catch (e) {
    print('上传失败: $e');
  }

  // 5. 下载文件
  print('\n--- 下载文件 ---');
  final downloadFile = File('${testDir.path}/download_test.txt');

  // 先通过 Host 保存一个文件获取 fileId
  final testData = await uploadFile.readAsBytes();
  final fileId = await host.saveFile(testData, 'test.txt');
  print('Host 保存文件: $fileId');

  try {
    await client.downloadFile(fileId, downloadFile.path);
    print('下载成功: ${downloadFile.path}');

    // 验证内容
    final downloadedContent = await downloadFile.readAsString();
    final originalContent = await uploadFile.readAsString();
    if (downloadedContent == originalContent) {
      print('✓ 文件内容验证成功!');
    } else {
      print('✗ 文件内容不匹配!');
    }
  } catch (e) {
    print('下载失败: $e');
  }

  // 6. 清理
  await client.disconnect();
  await host.stop();

  // 清理测试目录
  if (await testDir.exists()) {
    await testDir.delete(recursive: true);
  }

  print('\n示例完成!');
}

void main() async {
  await fileTransferExample();
}
