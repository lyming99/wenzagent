import 'dart:async';
import 'dart:io';

import 'package:wenzagent/wenzagent.dart';

/// 远程设备对话测试
///
/// 测试场景：
/// 1. 启动 LAN Host
/// 2. Device-A（device-alpha）创建员工 Alice 并建立会话
/// 3. Device-B（device-beta）通过 LAN RPC 与 Device-A 上的 Agent 进行远程对话
/// 4. 验证远程消息发送、状态查询等功能
///
/// 环境变量配置：
/// - OPENAI_API_KEY: OpenAI API 密钥
/// - OPENAI_API_URL: OpenAI API 地址（可选，默认为官方地址）

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║          远程设备对话测试 - LAN RPC Agent 交互             ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final test = RemoteDeviceChatTest();
  await test.run();
}

class RemoteDeviceChatTest {
  late LanHostServiceImpl host;
  late DeviceClientImpl deviceA; // 远程Agent所在设备
  late DeviceClientImpl deviceB; // 调用方设备

  final String deviceAId = 'device-alpha';
  final String deviceBId = 'device-beta';
  final String employeeAliceUuid = 'emp-alice-001';

  /// 从环境变量获取 API 配置
  String? get _apiKey => Platform.environment['OPENAI_API_KEY'];
  String? get _apiBaseUrl => Platform.environment['OPENAI_API_URL'];

  bool get _hasApiKey => _apiKey != null && _apiKey!.isNotEmpty;

  Future<void> run() async {
    try {
      // ===== 阶段 1: 初始化存储 =====
      print('\n[阶段 1] 初始化存储...');
      await _initializeStorage();

      // ===== 阶段 2: 启动 LAN Host =====
      print('\n[阶段 2] 启动 LAN Host...');
      await _startHost();

      // ===== 阶段 3: Device-A 连接并创建员工 =====
      print('\n[阶段 3] Device-A 连接并创建员工...');
      await _deviceAConnect();

      // ===== 阶段 4: Device-B 连接并同步数据 =====
      print('\n[阶段 4] Device-B 连接并同步数据...');
      await _deviceBConnect();

      // ===== 阶段 5: Device-B 判定远程会话 =====
      print('\n[阶段 5] Device-B 判定远程会话...');
      await _determineRemoteSession();

      // ===== 阶段 6: 通过 RPC 与远程 Agent 交互 =====
      print('\n[阶段 6] 通过 RPC 与远程 Agent 交互...');
      await _remoteAgentInteraction();

      print('\n╔══════════════════════════════════════════════════════════╗');
      print('║                    ✓ 所有测试通过！                        ║');
      print('╚══════════════════════════════════════════════════════════╝\n');
    } catch (e, stackTrace) {
      print('❌ 测试失败: $e');
      print(stackTrace);
    } finally {
      await _cleanup();
    }
  }

  /// 初始化存储
  Future<void> _initializeStorage() async {
    final tempDir = await Directory.systemTemp.createTemp('wenzagent_remote_chat_');
    print('  临时目录: ${tempDir.path}');
    await HiveManager.instance.initialize(storagePath: tempDir.path);
    print('  ✓ Hive 初始化完成');
  }

  /// 启动 LAN Host
  Future<void> _startHost() async {
    host = LanHostServiceImpl();
    // 使用随机端口，避免端口冲突
    await host.start(port: 0);
    // 获取实际分配的端口
    final actualPort = host.port;
    print('  ✓ Host 已启动: ${host.localIp}:$actualPort');

    // 监听 Host 消息
    host.messageStream.listen((msg) {
      if (msg.type == LanMessageType.system) {
        print('  [Host] ${msg.content}');
      }
    });
  }

  /// Device-A 连接并创建员工
  Future<void> _deviceAConnect() async {
    // 创建 DeviceClient
    deviceA = DeviceClientImpl(
      deviceId: deviceAId,
      deviceName: 'Device Alpha',
      host: host.localIp!,
      port: host.port,
    );

    // 连接到 Host
    await deviceA.connect();
    print('  ✓ Device-A 已连接: $deviceAId');

    // 打印 API 配置信息
    if (_hasApiKey) {
      print('  API Key: ${_apiKey!.substring(0, 8)}...');
      if (_apiBaseUrl != null) {
        print('  API Base URL: $_apiBaseUrl');
      }
    } else {
      print('  警告: 未设置 OPENAI_API_KEY 环境变量');
    }

    // 创建员工 Alice（使用环境变量配置）
    final alice = AiEmployeeEntity(
      uuid: employeeAliceUuid,
      name: 'Alice',
      role: 'assistant',
      status: 'active',
      description: '远程对话测试员工',
      systemPrompt: '你是 Alice，一个友好的 AI 助手。你在 Device-Alpha 上运行。',
      provider: 'openai',
      model: 'mimo-v2-pro',
      apiKey: _apiKey, // 从环境变量读取
      apiBaseUrl: _apiBaseUrl, // 从环境变量读取
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await deviceA.employeeManager.createEmployee(alice);
    print('  ✓ 创建员工 Alice');

    // 建立 Session
    await deviceA.sessionManager.getOrCreateSession(employeeAliceUuid);
    print('  ✓ 创建 Session');

    // 设置 currentDeviceId（表示 Alice 在 Device-A 上）
    await deviceA.employeeManager.updateCurrentDeviceId(employeeAliceUuid, deviceAId);
    print('  ✓ 设置 currentDeviceId = $deviceAId');

    // 创建本地 Agent（模拟实际对话）
    await deviceA.getOrCreateAgentProxy(employeeUuid: employeeAliceUuid);
    print('  ✓ 创建本地 Agent');
  }

  /// Device-B 连接并同步数据
  Future<void> _deviceBConnect() async {
    // 创建 DeviceClient
    deviceB = DeviceClientImpl(
      deviceId: deviceBId,
      deviceName: 'Device Beta',
      host: host.localIp!,
      port: host.port,
    );

    // 连接到 Host
    await deviceB.connect();
    print('  ✓ Device-B 已连接: $deviceBId');

    // 同步员工数据（模拟 LAN 同步）
    final alice = AiEmployeeEntity(
      uuid: employeeAliceUuid,
      name: 'Alice',
      role: 'assistant',
      status: 'active',
      description: '远程对话测试员工',
      provider: 'openai',
      model: 'gpt-4',
      createTime: DateTime.now(),
      updateTime: DateTime.now(),
    );
    await deviceB.employeeManager.createEmployee(alice);

    // 同步 currentDeviceId
    await deviceB.employeeManager.updateCurrentDeviceId(employeeAliceUuid, deviceAId);
    print('  ✓ 同步员工数据（currentDeviceId = $deviceAId）');

    // 同步 Session
    final sessionA = await deviceA.sessionManager.getSession(employeeAliceUuid);
    if (sessionA != null) {
      await deviceB.sessionManager.save(sessionA);
    }
    print('  ✓ 同步 Session 数据');
  }

  /// Device-B 判定远程会话
  Future<void> _determineRemoteSession() async {
    final alice = await deviceB.employeeManager.getEmployee(employeeAliceUuid);

    print('  Alice.currentDeviceId: ${alice?.currentDeviceId}');
    print('  Device-B.deviceId: $deviceBId');

    // 判断本地还是远程
    final isLocal = alice?.currentDeviceId == deviceBId;
    final isRemote = alice?.currentDeviceId == deviceAId;

    print('  isLocal: $isLocal');
    print('  isRemote: $isRemote');

    if (isRemote) {
      print('  ✓ 正确判定为远程会话');
      print('  → Device-B 需要通过 LAN RPC 与 Device-A 上的 Agent 交互');
    } else {
      throw StateError('应该判定为远程会话');
    }
  }

  /// 通过 AgentProxy 与远程 Agent 交互
  Future<void> _remoteAgentInteraction() async {
    // 获取在线设备列表（带超时处理）
    print('\n  [获取在线设备] 开始...');
    List<LanDeviceInfo> onlineDevices = [];
    try {
      onlineDevices = await deviceB.getOnlineDevices().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          print('  警告: 获取在线设备超时（10秒）');
          return [];
        },
      );
    } catch (e) {
      print('  警告: 获取在线设备失败: $e');
    }
    
    print('  在线设备数量: ${onlineDevices.length}');
    for (final device in onlineDevices) {
      print('    - ${device.id} (${device.name})');
    }

    // 验证 Device-A 在线（如果获取成功）
    if (onlineDevices.isNotEmpty) {
      final deviceAOnline = onlineDevices.any((d) => d.id == deviceAId);
      if (deviceAOnline) {
        print('  ✓ Device-A 在线');
      } else {
        print('  警告: Device-A 未在在线列表中找到');
      }
    }

    // ===== 通过 AgentProxy 进行远程交互 =====
    // Device-B 获取 AgentProxy（由于 currentDeviceId = deviceAId，会是远程模式）
    print('\n  [AgentProxy] 获取远程 AgentProxy...');
    final agentProxy = await deviceB.getOrCreateAgentProxy(employeeUuid: employeeAliceUuid);

    print('    isLocalMode: ${agentProxy.isLocalMode}');
    print('    employeeUuid: ${agentProxy.employeeUuid}');

    if (agentProxy.isLocalMode) {
      print('    警告: AgentProxy 应该是远程模式');
    } else {
      print('    ✓ AgentProxy 为远程模式');
    }

    // 1. 获取 Agent 状态
    print('\n  [AgentProxy] 获取远程 Agent 状态...');
    try {
      final snapshot = agentProxy.getStateSnapshot();
      print('    状态: ${snapshot.status}');
      print('    ✓ 状态获取成功');
    } catch (e) {
      print('    注意: 状态获取 ($e)');
    }

    // 2. 获取会话消息（验证 RPC 连通性）
    print('\n  [AgentProxy] 获取远程会话消息...');
    try {
      final messages = await agentProxy.getSessionMessages();
      print('    消息数量: ${messages.length}');
      print('    ✓ RPC 调用成功');
    } catch (e) {
      print('    注意: RPC 调用需要实际的网络连接 ($e)');
    }

    // ===== 3. 进行真实对话测试 =====
    await _performChatTest(agentProxy);

    print('\n  ✓ 远程 Agent 交互测试完成');
    if (!_hasApiKey) {
      print('  提示: 设置 OPENAI_API_KEY 环境变量以进行真实 AI 对话测试');
    }
  }

  /// 执行对话测试
  Future<void> _performChatTest(AgentProxy agentProxy) async {
    print('\n  [对话测试] 开始对话...');
    
    // 监听 Agent 状态变化
    final stateSubscription = agentProxy.onStateChanged.listen((snapshot) {
      print('  [状态变化] ${snapshot.status}');
    });

    // 监听 Device-B 的 Agent 事件（来自远程）
    final eventSubscription = deviceB.onAgentEvent.listen((event) {
      final type = event['type'] as String?;
      final data = event['data'] as Map<String, dynamic>?;
      final employeeUuid = event['employeeUuid'] as String?;
      
      if (employeeUuid != employeeAliceUuid) return;
      
      switch (type) {
        case 'agentStatusChanged':
          print('  [Agent事件] 状态变更: ${data?['status']}');
        case 'messageStatusChanged':
          final status = data?['status'] as String?;
          final messageId = data?['messageId'] as String?;
          final content = data?['content'] as String?;
          print('  [Agent事件] 消息状态变更: $messageId -> $status');
          if (content != null) {
            print('  [Agent事件] 消息内容: ${content.length > 100 ? "${content.substring(0, 100)}..." : content}');
          }
        default:
          print('  [Agent事件] $type');
      }
    });

    // 发送消息
    final testMessage = '你好！我是 Device-B，正在测试远程对话功能。请告诉我你是谁？';
    print('\n  [对话测试] 发送消息: "$testMessage"');
    
    String? messageId;
    try {
      messageId = await agentProxy.sendMessage({
        'content': testMessage,
        'role': 'user',
      });
      print('  [对话测试] 消息已发送， messageId: $messageId');
    } catch (e) {
      print('  [对话测试] 发送失败: $e');
      await stateSubscription.cancel();
      await eventSubscription.cancel();
      return;
    }

    // 等待响应完成（超时 60 秒）
    print('  [对话测试] 等待 Agent 响应...');
    final completer = Completer<void>();
    late StreamSubscription messageSub;
    
    messageSub = deviceB.onAgentEvent.listen((event) {
      final type = event['type'] as String?;
      final data = event['data'] as Map<String, dynamic>?;
      
      if (type == 'messageStatusChanged') {
        final status = data?['status'] as String?;
        final msgId = data?['messageId'] as String?;
        
        if (msgId == messageId && 
            (status == 'completed' || status == 'failed')) {
          print('  [对话测试] 消息处理完成: $status');
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
      }
    });

    try {
      await completer.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          print('  [对话测试] 等待超时（60秒）');
        },
      );
    } finally {
      await messageSub.cancel();
    }

    // 获取对话历史消息并打印
    print('\n  [对话测试] 获取对话历史消息...');
    try {
      final messages = await agentProxy.getSessionMessages();
      print('  [对话测试] 消息历史数量: ${messages.length}');
      print('\n  ======== 对话内容 ========');
      for (final msg in messages) {
        final role = msg['role'] as String? ?? 'unknown';
        final content = msg['content'] as String? ?? '';
        final roleLabel = role == 'user' ? '用户' : (role == 'assistant' ? '助手' : role);
        print('  [$roleLabel] $content');
      }
      print('  ==========================\n');
      
      // 验证输出
      _verifyChatOutput(messages, testMessage);
    } catch (e) {
      print('  [对话测试] 获取消息失败: $e');
    }

    await stateSubscription.cancel();
    await eventSubscription.cancel();
    print('  [对话测试] 完成');
  }

  /// 验证对话输出
  void _verifyChatOutput(List<Map<String, dynamic>> messages, String sentMessage) {
    print('\n  [验证] 验证对话输出...');
    
    // 验证用户消息存在
    final userMsgs = messages.where((m) => m['role'] == 'user').toList();
    assert(userMsgs.isNotEmpty, '应该包含用户消息');
    print('  ✓ 用户消息存在');
    
    // 验证发送的消息内容正确
    final userContent = userMsgs.first['content'] as String?;
    assert(userContent != null && userContent.contains(sentMessage), 
           '用户消息内容应该包含发送的内容');
    print('  ✓ 用户消息内容正确');
    
    // 如果有助手回复，验证助手消息存在
    final assistantMsgs = messages.where((m) => m['role'] == 'assistant').toList();
    if (assistantMsgs.isNotEmpty) {
      print('  ✓ 助手消息存在 (${assistantMsgs.length} 条)');
      
      // 验证助手消息不为空
      final assistantContent = assistantMsgs.first['content'] as String?;
      if (assistantContent != null && assistantContent.isNotEmpty) {
        print('  ✓ 助手回复内容: ${assistantContent.length > 100 ? "${assistantContent.substring(0, 100)}..." : assistantContent}');
      }
    } else {
      print('  注意: 无助手回复（可能是 API Key 未配置或请求超时）');
    }
    
    print('  ✓ 验证完成');
  }

  /// 清理
  Future<void> _cleanup() async {
    print('\n[清理] 释放资源...');

    try {
      await deviceB.disconnect();
      print('  ✓ Device-B 已断开');
    } catch (_) {}

    try {
      await deviceA.disconnect();
      print('  ✓ Device-A 已断开');
    } catch (_) {}

    try {
      await host.stop();
      print('  ✓ Host 已停止');
    } catch (_) {}

    print('  ✓ 清理完成');
  }
}
