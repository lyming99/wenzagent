import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/agent/agent_state.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/agent/rpc/agent_rpc_config.dart';
import 'package:wenzagent/src/entity/host_rpc_request.dart';
import 'package:wenzagent/src/entity/lan_message.dart';
import 'package:wenzagent/src/host/host_rpc_methods.dart';
import 'package:wenzagent/src/lan/entity/client_info.dart';
import 'package:wenzagent/src/lan/lan_client_service.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/rpc/remote_call_server.dart';
import 'package:wenzagent/src/service/service.dart';
import 'package:wenzagent/src/device/app_context.dart';
import 'package:wenzagent/src/device/impl/device_rpc_handler.dart';

int _testCounter = 0;

// ═══════════════════════════════════════════════════════════════
// Fake LanClientService — 记录发送的消息，其余方法空实现
// ═══════════════════════════════════════════════════════════════

class _FakeLanClientService implements LanClientService {
  final List<LanMessage> sentMessages = [];

  @override
  bool isConnected = false;

  @override
  bool isConnecting = false;

  @override
  String deviceId = 'fake-device';

  @override
  String? topic;

  @override
  String? hostIp;

  @override
  int hostPort = 9090;

  @override
  double uploadProgress = 0;

  @override
  double downloadProgress = 0;

  @override
  Stream<LanMessage> get messageStream => const Stream.empty();

  @override
  Future<void> connect(String hostIp, {int port = 9090}) async {}

  @override
  Future<void> disconnect() async {}

  @override
  void sendMessage(String content) {}

  @override
  void sendLanMessage(LanMessage message) {
    sentMessages.add(message);
  }

  @override
  Future<String> uploadFile(String filePath) async => '';

  @override
  Future<void> downloadFile(String fileId, String savePath) async {}

  @override
  Future<ClientInfo> getClientInfo() async => ClientInfo(
        id: 'test',
        hostPort: 9090,
        isConnected: true,
        deviceId: deviceId,
      );

  @override
  Future<void> reconnect() async {}
}

// ═══════════════════════════════════════════════════════════════
// CapturingRpcServer — 继承 RemoteCallServer，公开已注册的 handler
// ═══════════════════════════════════════════════════════════════

class CapturingRpcServer extends RemoteCallServer {
  final Map<String, Future<Map<String, dynamic>> Function(Map<String, dynamic>)>
      capturedHandlers = {};

  CapturingRpcServer({
    required super.clientService,
    required super.localDeviceId,
  });

  @override
  void register(
    String method,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) handler,
  ) {
    capturedHandlers[method] = handler;
    super.register(method, handler);
  }
}

// ═══════════════════════════════════════════════════════════════
// 辅助方法
// ═══════════════════════════════════════════════════════════════

AiEmployeeEntity _createEmployee({
  String? uuid,
  String? name,
  String? deviceId,
  String status = 'active',
  int deleted = 0,
  DateTime? deletedTime,
  DateTime? createTime,
  DateTime? updateTime,
}) {
  final now = DateTime.now();
  return AiEmployeeEntity(
    uuid: uuid ?? const Uuid().v4(),
    name: name ?? '测试员工',
    deviceId: deviceId,
    status: status,
    deleted: deleted,
    deletedTime: deletedTime,
    createTime: createTime ?? now,
    updateTime: updateTime ?? now,
  );
}

AiEmployeeSessionEntity _createSession({
  required String employeeId,
  int deleted = 0,
  DateTime? deleteTime,
  DateTime? createTime,
  DateTime? updateTime,
}) {
  final now = DateTime.now();
  return AiEmployeeSessionEntity(
    employeeId: employeeId,
    deleted: deleted,
    deleteTime: deleteTime,
    createTime: createTime ?? now,
    updateTime: updateTime ?? now,
  );
}

AiEmployeeSkillEntity _createSkill({
  String? uuid,
  required String employeeId,
  String deviceId = '',
  String? name,
}) {
  final now = DateTime.now();
  return AiEmployeeSkillEntity(
    uuid: uuid ?? const Uuid().v4(),
    employeeId: employeeId,
    deviceId: deviceId,
    name: name ?? '测试技能',
    createTime: now,
    updateTime: now,
  );
}

// ═══════════════════════════════════════════════════════════════
// 测试主体
// ═══════════════════════════════════════════════════════════════

void main() {
  late String testDbPath;
  late String deviceId;
  late CapturingRpcServer rpcServer;
  late _FakeLanClientService fakeLanClient;
  late DeviceRpcHandler rpcHandler;
  late EmployeeManager employeeManager;
  late SessionManager sessionManager;
  late SkillManager skillManager;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_rpc_handler_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    fakeLanClient = _FakeLanClientService();
    rpcServer = CapturingRpcServer(
      clientService: fakeLanClient,
      localDeviceId: deviceId,
    );

    employeeManager = EmployeeManager.getInstance(deviceId);
    sessionManager = SessionManager.getInstance(deviceId);
    skillManager = SkillManager.getInstance(deviceId);

    rpcHandler = DeviceRpcHandler.getInstance(deviceId);
    rpcHandler.registerAll(rpcServer);
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    EmployeeManager.removeInstance(deviceId);
    SessionManager.removeInstance(deviceId);
    SkillManager.removeInstance(deviceId);
    MessageStoreService.removeInstance(deviceId);
    EmployeeConfigService.removeInstance(deviceId);
    DeviceRpcHandler.removeInstance(deviceId);
    AppContext.dispose(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════════════
  // Group 1: 方法注册验证
  // ═══════════════════════════════════════════════════════════

  group('方法注册验证', () {
    // Agent RPC 方法列表（在 DeviceRpcHandler 中注册的）
    final agentMethods = <String>[
      AgentRpcConfig.methodSendMessage,
      AgentRpcConfig.methodInterrupt,
      AgentRpcConfig.methodGetSessionMessages,
      AgentRpcConfig.methodGetSessionMessagesByUserCount,
      AgentRpcConfig.methodGetSessionMessagesPaged,
      AgentRpcConfig.methodGetUnreceivedMessages,
      AgentRpcConfig.methodMarkMessagesAsReceived,
      AgentRpcConfig.methodGetMessagesAfterSeq,
      AgentRpcConfig.methodGetMaxSeq,
      AgentRpcConfig.methodGetMinSeq,
      AgentRpcConfig.methodGetClearSeq,
      AgentRpcConfig.methodMarkMessagesAsRead,
      AgentRpcConfig.methodMarkMessagesAsReadBySeq,
      AgentRpcConfig.methodGetMessagesReadStatus,
      AgentRpcConfig.methodGetSessionSummary,
      AgentRpcConfig.methodGetState,
      AgentRpcConfig.methodGetCallingToolIds,
      AgentRpcConfig.methodSetContext,
      AgentRpcConfig.methodGetContext,
      AgentRpcConfig.methodSetProvider,
      AgentRpcConfig.methodClearSession,
      AgentRpcConfig.methodPing,
      AgentRpcConfig.methodGetOrCreateAgent,
      AgentRpcConfig.methodRevokeMessage,
      AgentRpcConfig.methodGetPendingPermission,
      AgentRpcConfig.methodRespondPermission,
      AgentRpcConfig.methodGetPendingConfirm,
      AgentRpcConfig.methodRespondConfirm,
      AgentRpcConfig.methodClearContext,
      AgentRpcConfig.methodGetProvider,
      AgentRpcConfig.methodSetSkills,
      AgentRpcConfig.methodGetSkills,
      AgentRpcConfig.methodSetMcpConfigs,
      AgentRpcConfig.methodGetMcpConfigs,
      AgentRpcConfig.methodSetProject,
      AgentRpcConfig.methodGetProjectUuid,
      AgentRpcConfig.methodCheckPathExists,
      AgentRpcConfig.methodListDirectory,
      AgentRpcConfig.methodGetFileInfo,
      AgentRpcConfig.methodCreateDirectory,
      AgentRpcConfig.methodDeleteFile,
      AgentRpcConfig.methodRenameFile,
      AgentRpcConfig.methodGetRegisteredTools,
      AgentRpcConfig.methodGetCurrentTopics,
      AgentRpcConfig.methodGetPendingTopics,
      AgentRpcConfig.methodGetAllTopics,
      AgentRpcConfig.methodGetCompletedTopics,
      AgentRpcConfig.methodGetTodoStats,
      AgentRpcConfig.methodUpdateTopicContent,
      AgentRpcConfig.methodDeleteTopic,
      AgentRpcConfig.methodUpdateTopicStatus,
      AgentRpcConfig.methodReorderTopics,
      AgentRpcConfig.methodClearCompletedTopics,
      AgentRpcConfig.methodGetTaskItemsByTopic,
      AgentRpcConfig.methodUpdateTaskItemStatus,
      AgentRpcConfig.methodUpdateTaskItemContent,
      AgentRpcConfig.methodDeleteTaskItem,
      AgentRpcConfig.methodReorderTaskItems,
      AgentRpcConfig.methodGetActiveSpecs,
      AgentRpcConfig.methodGetCompletedSpecs,
      AgentRpcConfig.methodGetSpecStats,
      AgentRpcConfig.methodUpdateSpecStatus,
      AgentRpcConfig.methodUpdateSpecContent,
      AgentRpcConfig.methodDeleteSpec,
      AgentRpcConfig.methodClearCompletedSpecs,
      AgentRpcConfig.methodReorderSpecs,
      AgentRpcConfig.methodGetFileOperations,
      AgentRpcConfig.methodGetFileOperationsByMessage,
      AgentRpcConfig.methodClearFileOperations,
    ];

    // Host RPC 方法列表（在 DeviceRpcHandler 中注册的）
    final hostMethods = <String>[
      HostRpcConfig.methodGetEmployees,
      HostRpcConfig.methodGetEmployee,
      HostRpcConfig.methodGetSessions,
      HostRpcConfig.methodGetSkills,
      HostRpcConfig.methodSyncEmployees,
      HostRpcConfig.methodSyncSessions,
      HostRpcConfig.methodSyncMessages,
      HostRpcConfig.methodGetSessionSummaries,
      HostRpcConfig.methodGetOnlineDevices,
      HostRpcConfig.methodUpdateDeviceInfo,
    ];

    test('所有 Agent RPC 方法均已注册', () {
      for (final method in agentMethods) {
        expect(
          rpcServer.hasMethod(method),
          isTrue,
          reason: 'Agent 方法 $method 应已注册',
        );
      }
    });

    test('所有 Host RPC 方法均已注册', () {
      for (final method in hostMethods) {
        expect(
          rpcServer.hasMethod(method),
          isTrue,
          reason: 'Host 方法 $method 应已注册',
        );
      }
    });

    test('已注册的 handler 总数等于 Agent + Host 方法数之和', () {
      // 某些方法可能重复注册（Host 和 Agent 注册同一个 method name），
      // 所以 capturedHandlers 的 key 数量 <= agentMethods.length + hostMethods.length
      final allMethods = <String>{...agentMethods, ...hostMethods};
      expect(
        rpcServer.capturedHandlers.length,
        equals(allMethods.length),
        reason: '注册方法数应等于去重后的方法总数',
      );
    });

    test('未注册的方法返回 false', () {
      expect(rpcServer.hasMethod('nonExistentMethod'), isFalse);
      expect(rpcServer.hasMethod('agentFakeMethod'), isFalse);
      expect(rpcServer.hasMethod('hostFakeMethod'), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 2: Host 员工管理 RPC 测试
  // ═══════════════════════════════════════════════════════════

  group('Host 员工管理 RPC', () {
    test('hostGetEmployees - 返回空列表', () async {
      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodGetEmployees]!;
      final result = await handler({'keyword': null, 'status': null});
      expect(result, contains('employees'));
      expect(result['employees'], isA<List>());
      expect((result['employees'] as List).isEmpty, isTrue);
    });

    test('hostGetEmployees - 返回已创建的员工', () async {
      final emp = _createEmployee(deviceId: deviceId);
      await employeeManager.createEmployee(emp);

      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodGetEmployees]!;
      final result = await handler({});
      expect(result, contains('employees'));
      final employees = result['employees'] as List;
      expect(employees.length, equals(1));
      expect(employees.first['uuid'], equals(emp.uuid));
    });

    test('hostGetEmployee - 获取单个员工', () async {
      final emp = _createEmployee(name: 'Alice', deviceId: deviceId);
      await employeeManager.createEmployee(emp);

      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodGetEmployee]!;
      final result = await handler({'uuid': emp.uuid});
      expect(result, contains('employee'));
      expect(result['employee']['uuid'], equals(emp.uuid));
      expect(result['employee']['name'], equals('Alice'));
    });

    test('hostGetEmployee - 员工不存在时抛出异常', () async {
      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodGetEmployee]!;
      expect(
        () => handler({'uuid': 'non-existent-uuid'}),
        throwsA(isA<Exception>()),
      );
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 3: Host 会话管理 RPC 测试
  // ═══════════════════════════════════════════════════════════

  group('Host 会话管理 RPC', () {
    test('hostGetSessions - 返回空列表', () async {
      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodGetSessions]!;
      final result = await handler({});
      expect(result, contains('sessions'));
      expect(result['sessions'], isA<List>());
      expect((result['sessions'] as List).isEmpty, isTrue);
    });

    test('hostGetSessions - 返回已创建的会话', () async {
      final empId = const Uuid().v4();
      await sessionManager.getOrCreateSession(empId);

      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodGetSessions]!;
      final result = await handler({});
      final sessions = result['sessions'] as List;
      expect(sessions.length, equals(1));
      expect(sessions.first['employeeId'], equals(empId));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 4: Host 技能管理 RPC 测试
  // ═══════════════════════════════════════════════════════════

  group('Host 技能管理 RPC', () {
    test('hostGetSkills - 返回空列表', () async {
      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodGetSkills]!;
      final result = await handler({'employeeId': 'emp-1'});
      expect(result, contains('skills'));
      expect(result['skills'], isA<List>());
      expect((result['skills'] as List).isEmpty, isTrue);
    });

    test('hostGetSkills - 返回已创建的技能', () async {
      final empId = const Uuid().v4();
      final skill = _createSkill(employeeId: empId, deviceId: deviceId);
      await skillManager.createSkill(skill);

      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodGetSkills]!;
      final result = await handler({'employeeId': empId});
      final skills = result['skills'] as List;
      expect(skills.length, equals(1));
      expect(skills.first['name'], equals('测试技能'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 5: Host 同步 RPC 测试 - SyncEmployees
  // ═══════════════════════════════════════════════════════════

  group('Host SyncEmployees RPC', () {
    test('同步新员工到本地', () async {
      final empId = const Uuid().v4();
      final now = DateTime.now();
      final empMap = _createEmployee(uuid: empId, name: '同步员工').toMap();

      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodSyncEmployees]!;
      final result = await handler({'employees': [empMap]});

      expect(result['count'], equals(1));

      // 验证本地已保存
      final local = await employeeManager.getEmployee(empId);
      expect(local, isNotNull);
      expect(local!.name, equals('同步员工'));
    });

    test('同步已存在的员工 - 远程更新时间较新则更新', () async {
      final empId = const Uuid().v4();

      // 先创建本地员工（通过 saveEmployee 保留原始 updateTime）
      final localTime = DateTime.now().subtract(const Duration(hours: 2));
      await employeeManager.saveEmployee(
        _createEmployee(uuid: empId, name: '旧名称', updateTime: localTime),
      );

      // 同步较新的远程员工
      final remoteTime = DateTime.now().subtract(const Duration(hours: 1));
      final remoteMap = _createEmployee(
        uuid: empId,
        name: '新名称',
        updateTime: remoteTime,
      ).toMap();

      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodSyncEmployees]!;
      await handler({'employees': [remoteMap]});

      final local = await employeeManager.getEmployee(empId);
      expect(local!.name, equals('新名称'));
    });

    test('同步已存在的员工 - 本地更新时间较新则不更新', () async {
      final empId = const Uuid().v4();
      final oldTime = DateTime.now().subtract(const Duration(hours: 1));
      final newTime = DateTime.now();

      // 先创建本地较新的员工
      await employeeManager.createEmployee(
        _createEmployee(uuid: empId, name: '本地最新', updateTime: newTime),
      );

      // 同步较旧的远程员工
      final remoteMap = _createEmployee(
        uuid: empId,
        name: '远程旧数据',
        updateTime: oldTime,
      ).toMap();

      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodSyncEmployees]!;
      await handler({'employees': [remoteMap]});

      final local = await employeeManager.getEmployee(empId);
      expect(local!.name, equals('本地最新'));
    });

    test('同步空列表不报错', () async {
      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodSyncEmployees]!;
      final result = await handler({'employees': []});
      expect(result['count'], equals(0));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 6: Host 同步 RPC 测试 - SyncSessions
  // ═══════════════════════════════════════════════════════════

  group('Host SyncSessions RPC', () {
    test('同步新会话到本地', () async {
      final empId = const Uuid().v4();
      final sessionMap = _createSession(employeeId: empId).toMap();

      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodSyncSessions]!;
      final result = await handler({'sessions': [sessionMap]});

      expect(result['count'], equals(1));

      final local = await sessionManager.getSession(empId);
      expect(local, isNotNull);
    });

    test('同步已删除的会话不创建本地记录', () async {
      final empId = const Uuid().v4();
      final sessionMap = _createSession(
        employeeId: empId,
        deleted: 1,
        deleteTime: DateTime.now(),
      ).toMap();

      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodSyncSessions]!;
      await handler({'sessions': [sessionMap]});

      // 本地不应存在该会话
      final local = await sessionManager.getSession(empId);
      expect(local, isNull);
    });

    test('同步已存在的会话 - 远程较新则更新', () async {
      final empId = const Uuid().v4();
      final oldTime = DateTime.now().subtract(const Duration(hours: 1));
      final newTime = DateTime.now();

      // 本地先创建
      await sessionManager.save(_createSession(
        employeeId: empId,
        updateTime: oldTime,
      ));

      // 同步远程较新
      final remoteMap = _createSession(
        employeeId: empId,
        updateTime: newTime,
      ).toMap();

      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodSyncSessions]!;
      await handler({'sessions': [remoteMap]});

      final local = await sessionManager.getSession(empId);
      expect(local, isNotNull);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 7: Host 同步 RPC 测试 - SyncMessages
  // ═══════════════════════════════════════════════════════════

  group('Host SyncMessages RPC', () {
    test('同步空消息列表', () async {
      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodSyncMessages]!;
      final result = await handler({'messages': []});
      expect(result['count'], equals(0));
    });

    test('同步消息返回正确计数', () async {
      final empId = const Uuid().v4();
      final now = DateTime.now();
      final messages = [
        {
          'id': const Uuid().v4(),
          'employeeId': empId,
          'role': 'user',
          'type': 'text',
          'content': 'Hello',
          'createdAt': now.toIso8601String(),
          'deviceId': deviceId,
        },
        {
          'id': const Uuid().v4(),
          'employeeId': empId,
          'role': 'assistant',
          'type': 'text',
          'content': 'Hi there',
          'createdAt': now.toIso8601String(),
          'deviceId': deviceId,
        },
      ];

      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodSyncMessages]!;
      final result = await handler({'messages': messages});
      expect(result['count'], equals(2));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 8: Host 会话摘要 RPC 测试
  // ═══════════════════════════════════════════════════════════

  group('Host 会话摘要 RPC', () {
    test('hostGetSessionSummaries - 返回空列表', () async {
      final handler =
          rpcServer.capturedHandlers[HostRpcConfig.methodGetSessionSummaries]!;
      final result = await handler({});
      expect(result, contains('summaries'));
      expect(result['summaries'], isA<List>());
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 9: Host 设备管理 RPC 测试
  // ═══════════════════════════════════════════════════════════

  group('Host 设备管理 RPC', () {
    test('hostGetOnlineDevices - 返回空设备列表', () async {
      final handler =
          rpcServer.capturedHandlers[HostRpcConfig.methodGetOnlineDevices]!;
      final result = await handler({});
      expect(result, contains('devices'));
      expect(result['devices'], isA<List>());
      expect((result['devices'] as List).isEmpty, isTrue);
    });

    test('hostUpdateDeviceInfo - 更新设备信息', () async {
      final handler =
          rpcServer.capturedHandlers[HostRpcConfig.methodUpdateDeviceInfo]!;
      final result = await handler({
        'deviceInfo': {
          'name': 'Test Device',
          'type': 'desktop',
          'os': 'windows',
        },
      });
      expect(result['success'], isTrue);
    });

    test('hostUpdateDeviceInfo - 缺少 deviceInfo 抛出异常', () async {
      final handler =
          rpcServer.capturedHandlers[HostRpcConfig.methodUpdateDeviceInfo]!;
      expect(
        () => handler({}),
        throwsA(isA<Exception>()),
      );
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 10: Agent Ping RPC 测试
  // ═══════════════════════════════════════════════════════════

  group('Agent Ping RPC', () {
    test('agentPing - 无 employeeId 时返回全局状态', () async {
      final handler = rpcServer.capturedHandlers[AgentRpcConfig.methodPing]!;
      final result = await handler({});
      expect(result['alive'], isTrue);
      expect(result, contains('agentCount'));
      expect(result, contains('deviceId'));
      expect(result['deviceId'], equals(deviceId));
    });

    test('agentPing - 指定不存在的 employeeId 返回 alive=false', () async {
      final handler = rpcServer.capturedHandlers[AgentRpcConfig.methodPing]!;
      final result = await handler({'employeeId': 'non-existent-emp'});
      expect(result['alive'], isFalse);
      expect(result['employeeId'], equals('non-existent-emp'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 11: Agent 文件系统 RPC 测试
  // ═══════════════════════════════════════════════════════════

  group('Agent 文件系统 RPC', () {
    test('agentCheckPathExists - 检查存在的目录', () async {
      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodCheckPathExists]!;
      final result = await handler({
        'employeeId': 'emp-1',
        'path': testDbPath,
      });
      expect(result['exists'], isTrue);
      expect(result['isDirectory'], isTrue);
    });

    test('agentCheckPathExists - 检查不存在的路径', () async {
      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodCheckPathExists]!;
      final result = await handler({
        'employeeId': 'emp-1',
        'path': '/non/existent/path/xyz',
      });
      expect(result['exists'], isFalse);
    });

    test('agentCheckPathExists - 检查存在的文件', () async {
      final testFile = File('$testDbPath/test_file.txt');
      await testFile.writeAsString('hello');

      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodCheckPathExists]!;
      final result = await handler({
        'employeeId': 'emp-1',
        'path': testFile.path,
      });
      expect(result['exists'], isTrue);
      expect(result['isDirectory'], isFalse);
    });

    test('agentListDirectory - 列出存在的目录', () async {
      // 创建一些测试文件
      await File('$testDbPath/file1.txt').writeAsString('a');
      await File('$testDbPath/file2.txt').writeAsString('b');
      await Directory('$testDbPath/subdir').create();

      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodListDirectory]!;
      final result = await handler({
        'employeeId': 'emp-1',
        'path': testDbPath,
      });
      expect(result, contains('items'));
      final items = result['items'] as List;
      // 至少包含 subdir, file1.txt, file2.txt（可能还有 wenzagent.db 等）
      expect(items.length, greaterThanOrEqualTo(3));

      // 目录排在前面
      final dirs = items.where((i) => i['isDirectory'] as bool).toList();
      final files = items.where((i) => !(i['isDirectory'] as bool)).toList();
      if (dirs.isNotEmpty && files.isNotEmpty) {
        // 目录应在文件之前
        final lastDirIdx = items.indexWhere(
            (i) => !(i['isDirectory'] as bool));
        final firstFileIdx = items
            .indexWhere((i) => !(i['isDirectory'] as bool));
        // 验证排序逻辑：所有目录排在文件前
        for (int i = 0; i < items.length - 1; i++) {
          if (!(items[i]['isDirectory'] as bool) &&
              (items[i + 1]['isDirectory'] as bool)) {
            fail('文件不应排在目录前面');
          }
        }
      }
    });

    test('agentListDirectory - 不存在的目录返回错误', () async {
      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodListDirectory]!;
      final result = await handler({
        'employeeId': 'emp-1',
        'path': '/non/existent/dir',
      });
      expect(result['items'], isA<List>());
      expect((result['items'] as List).isEmpty, isTrue);
      expect(result, contains('error'));
    });

    test('agentGetFileInfo - 获取文件信息', () async {
      // 使用独立的临时目录，避免被其他测试的 tearDown 删除
      final infoDir = '${Directory.systemTemp.path}/rpc_file_info_test_${DateTime.now().millisecondsSinceEpoch}';
      await Directory(infoDir).create(recursive: true);
      try {
        final testFile = File('$infoDir/info_test.txt');
        await testFile.writeAsString('test content');

        final handler =
            rpcServer.capturedHandlers[AgentRpcConfig.methodGetFileInfo]!;
        final result = await handler({
          'employeeId': 'emp-1',
          'path': testFile.path,
        });
        expect(result['exists'], isTrue);
        expect(result['isDirectory'], isFalse);
        // 验证 name 是路径的最后一段（与源码 path.split(Platform.pathSeparator).last 一致）
        expect(result['name'], equals(testFile.path.split(Platform.pathSeparator).last));
        expect(result['size'], greaterThan(0));
      } finally {
        await Directory(infoDir).delete(recursive: true);
      }
    });

    test('agentGetFileInfo - 获取目录信息', () async {
      // 使用独立的临时目录
      final infoDir = '${Directory.systemTemp.path}/rpc_dir_info_test_${DateTime.now().millisecondsSinceEpoch}';
      await Directory(infoDir).create(recursive: true);
      try {
        final handler =
            rpcServer.capturedHandlers[AgentRpcConfig.methodGetFileInfo]!;
        final result = await handler({
          'employeeId': 'emp-1',
          'path': infoDir,
        });
        expect(result['exists'], isTrue);
        expect(result['isDirectory'], isTrue);
      } finally {
        await Directory(infoDir).delete(recursive: true);
      }
    });

    test('agentGetFileInfo - 不存在的路径', () async {
      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodGetFileInfo]!;
      final result = await handler({
        'employeeId': 'emp-1',
        'path': '/non/existent/file.txt',
      });
      expect(result['exists'], isFalse);
    });

    test('agentCreateDirectory - 创建目录', () async {
      final newDir = '$testDbPath/new/nested/dir';
      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodCreateDirectory]!;
      final result = await handler({
        'employeeId': 'emp-1',
        'path': newDir,
      });
      expect(result['success'], isTrue);
      expect(await Directory(newDir).exists(), isTrue);
    });

    test('agentDeleteFile - 删除文件', () async {
      final testFile = File('$testDbPath/to_delete.txt');
      await testFile.writeAsString('delete me');
      expect(await testFile.exists(), isTrue);

      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodDeleteFile]!;
      final result = await handler({
        'employeeId': 'emp-1',
        'path': testFile.path,
      });
      expect(result['success'], isTrue);
      expect(await testFile.exists(), isFalse);
    });

    test('agentDeleteFile - 删除目录', () async {
      final testDir = Directory('$testDbPath/to_delete_dir');
      await testDir.create();
      expect(await testDir.exists(), isTrue);

      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodDeleteFile]!;
      final result = await handler({
        'employeeId': 'emp-1',
        'path': testDir.path,
      });
      expect(result['success'], isTrue);
      expect(await testDir.exists(), isFalse);
    });

    test('agentDeleteFile - 不存在的路径返回错误', () async {
      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodDeleteFile]!;
      final result = await handler({
        'employeeId': 'emp-1',
        'path': '/non/existent/path',
      });
      expect(result['success'], isFalse);
      expect(result, contains('error'));
    });

    test('agentRenameFile - 重命名文件', () async {
      final oldFile = File('$testDbPath/old_name.txt');
      await oldFile.writeAsString('content');
      final newPath = '$testDbPath/new_name.txt';

      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodRenameFile]!;
      final result = await handler({
        'employeeId': 'emp-1',
        'oldPath': oldFile.path,
        'newPath': newPath,
      });
      expect(result['success'], isTrue);
      expect(await File(newPath).exists(), isTrue);
    });

    test('agentRenameFile - 不存在的路径返回错误', () async {
      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodRenameFile]!;
      final result = await handler({
        'employeeId': 'emp-1',
        'oldPath': '/non/existent/old.txt',
        'newPath': '/non/existent/new.txt',
      });
      expect(result['success'], isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 12: Agent 同步水位线 RPC 测试
  // ═══════════════════════════════════════════════════════════

  group('Agent 同步水位线 RPC', () {
    test('agentGetClearSeq - 无水位线时返回 0', () async {
      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodGetClearSeq]!;
      final result = await handler({'employeeId': 'emp-1'});
      expect(result['clearSeq'], equals(0));
    });

    test('agentGetClearSeq - 有水位线时返回正确值', () async {
      final empId = 'emp-clear-seq-test';
      final watermarkStore = SyncWatermarkStore(deviceId: deviceId);
      watermarkStore.setClearSeq(empId, 42, deviceId: deviceId);

      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodGetClearSeq]!;
      final result = await handler({'employeeId': empId});
      expect(result['clearSeq'], equals(42));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 13: Agent 会话摘要 RPC 测试
  // ═══════════════════════════════════════════════════════════

  group('Agent 会话摘要 RPC', () {
    test('agentGetSessionSummary - 无摘要时返回空 Map', () async {
      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodGetSessionSummary]!;
      final result = await handler({'employeeId': 'emp-no-summary'});
      // 无摘要时返回空 Map
      expect(result, isA<Map>());
    });

    test('agentGetSessionSummary - 有摘要时返回数据', () async {
      final empId = 'emp-with-summary';
      final summaryStore = SessionSummaryStore(deviceId: deviceId);
      summaryStore.onMessageAdded(
        employeeId: empId,
        deviceId: deviceId,
        role: 'user',
        content: 'Hello',
        messageId: 'msg-1',
        createTime: DateTime.now().millisecondsSinceEpoch,
        isRead: false,
      );

      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodGetSessionSummary]!;
      final result = await handler({'employeeId': empId});
      expect(result, isNotEmpty);
      expect(result['employee_id'], equals(empId));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 14: Agent 技能 RPC 测试
  // ═══════════════════════════════════════════════════════════

  group('Agent 技能 RPC', () {
    test('agentGetSkills - 返回空列表', () async {
      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodGetSkills]!;
      final result = await handler({'employeeId': 'emp-no-skills'});
      expect(result, contains('skills'));
      expect(result['skills'], isA<List>());
      expect((result['skills'] as List).isEmpty, isTrue);
    });

    test('agentGetSkills - 返回已有技能', () async {
      final empId = const Uuid().v4();
      final skill = _createSkill(
        employeeId: empId,
        deviceId: deviceId,
        name: 'Python',
      );
      await skillManager.createSkill(skill);

      final handler =
          rpcServer.capturedHandlers[AgentRpcConfig.methodGetSkills]!;
      final result = await handler({'employeeId': empId});
      final skills = result['skills'] as List;
      expect(skills.length, equals(1));
      expect(skills.first['name'], equals('Python'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 15: Agent 请求反序列化验证
  // ═══════════════════════════════════════════════════════════

  group('Agent 请求反序列化验证', () {
    test('SendMessageRequest.fromMap 正确解析', () {
      final request = SendMessageRequest.fromMap({
        'employeeId': 'emp-1',
        'messageData': {
          'id': 'msg-1',
          'content': 'Hello',
          'type': 'text',
        },
      });
      expect(request.employeeId, equals('emp-1'));
      expect(request.messageData['id'], equals('msg-1'));
    });

    test('InterruptRequest.fromMap 正确解析', () {
      final request = InterruptRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('PingRequest.fromMap - 无 employeeId', () {
      final request = PingRequest.fromMap({});
      expect(request.employeeId, isNull);
    });

    test('PingRequest.fromMap - 有 employeeId', () {
      final request = PingRequest.fromMap({'employeeId': 'emp-1'});
      expect(request.employeeId, equals('emp-1'));
    });

    test('GetOrCreateAgentRequest.fromMap 正确解析', () {
      final request = GetOrCreateAgentRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('SetContextRequest.fromMap 正确解析', () {
      final request = SetContextRequest.fromMap({
        'employeeId': 'emp-1',
        'contextData': {'key': 'value'},
      });
      expect(request.employeeId, equals('emp-1'));
      expect(request.contextData['key'], equals('value'));
    });

    test('GetContextRequest.fromMap 正确解析', () {
      final request = GetContextRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('ClearContextRequest.fromMap 正确解析', () {
      final request = ClearContextRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('SetProviderRequest.fromMap 正确解析', () {
      final request = SetProviderRequest.fromMap({
        'employeeId': 'emp-1',
        'providerConfig': {
          'provider': 'openai',
          'model': 'gpt-4o',
          'apiKey': 'sk-test',
        },
      });
      expect(request.employeeId, equals('emp-1'));
      expect(request.providerConfig['provider'], equals('openai'));
    });

    test('GetProviderRequest.fromMap 正确解析', () {
      final request = GetProviderRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('SetProjectRequest.fromMap - 有项目数据', () {
      final request = SetProjectRequest.fromMap({
        'employeeId': 'emp-1',
        'projectData': {
          'projectUuid': 'proj-1',
          'projectName': 'Test Project',
        },
      });
      expect(request.employeeId, equals('emp-1'));
      expect(request.projectData?['projectUuid'], equals('proj-1'));
    });

    test('SetProjectRequest.fromMap - 无项目数据', () {
      final request = SetProjectRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
      expect(request.projectData, isNull);
    });

    test('GetProjectUuidRequest.fromMap 正确解析', () {
      final request = GetProjectUuidRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('RevokeMessageRequest.fromMap 正确解析', () {
      final request = RevokeMessageRequest.fromMap({
        'employeeId': 'emp-1',
        'messageId': 'msg-1',
      });
      expect(request.employeeId, equals('emp-1'));
      expect(request.messageId, equals('msg-1'));
    });

    test('GetSessionMessagesRequest.fromMap 正确解析', () {
      final request = GetSessionMessagesRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('GetSessionMessagesByUserCountRequest.fromMap 正确解析', () {
      final request = GetSessionMessagesByUserCountRequest.fromMap({
        'employeeId': 'emp-1',
        'userMessageLimit': 10,
      });
      expect(request.employeeId, equals('emp-1'));
      expect(request.userMessageLimit, equals(10));
    });

    test('GetSessionMessagesByUserCountRequest.fromMap - 默认值', () {
      final request = GetSessionMessagesByUserCountRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.userMessageLimit, equals(20));
    });

    test('GetSessionMessagesPagedRequest.fromMap 正确解析', () {
      final request = GetSessionMessagesPagedRequest.fromMap({
        'employeeId': 'emp-1',
        'pageSize': 50,
        'offset': 10,
      });
      expect(request.pageSize, equals(50));
      expect(request.offset, equals(10));
    });

    test('GetUnreceivedMessagesRequest.fromMap 正确解析', () {
      final request = GetUnreceivedMessagesRequest.fromMap({
        'employeeId': 'emp-1',
        'receiverDeviceId': 'dev-1',
        'offset': 5,
        'limit': 30,
      });
      expect(request.employeeId, equals('emp-1'));
      expect(request.receiverDeviceId, equals('dev-1'));
      expect(request.offset, equals(5));
      expect(request.limit, equals(30));
    });

    test('MarkMessagesAsReceivedRequest.fromMap 正确解析', () {
      final request = MarkMessagesAsReceivedRequest.fromMap({
        'employeeId': 'emp-1',
        'receiverDeviceId': 'dev-1',
        'messageReceiveList': [
          {
            'messageId': 'msg-1',
            'updateTime': DateTime.now().toIso8601String(),
          },
        ],
      });
      expect(request.messageReceiveList.length, equals(1));
      expect(request.messageReceiveList.first.messageId, equals('msg-1'));
    });

    test('GetMessagesAfterSeqRequest.fromMap 正确解析', () {
      final request = GetMessagesAfterSeqRequest.fromMap({
        'employeeId': 'emp-1',
        'lastSeq': 100,
        'limit': 50,
      });
      expect(request.lastSeq, equals(100));
      expect(request.limit, equals(50));
    });

    test('GetMessagesAfterSeqRequest.fromMap - 默认值', () {
      final request = GetMessagesAfterSeqRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.lastSeq, equals(0));
      expect(request.limit, equals(20));
    });

    test('ClearSessionRequest.fromMap 正确解析', () {
      final request = ClearSessionRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('MarkMessagesAsReadRequest.fromMap 正确解析', () {
      final request = MarkMessagesAsReadRequest.fromMap({
        'employeeId': 'emp-1',
        'readerDeviceId': 'dev-1',
        'messageIds': ['msg-1', 'msg-2'],
      });
      expect(request.readerDeviceId, equals('dev-1'));
      expect(request.messageIds, equals(['msg-1', 'msg-2']));
    });

    test('MarkMessagesAsReadBySeqRequest.fromMap 正确解析', () {
      final request = MarkMessagesAsReadBySeqRequest.fromMap({
        'employeeId': 'emp-1',
        'readerDeviceId': 'dev-1',
        'readSeq': 42,
      });
      expect(request.readSeq, equals(42));
    });

    test('GetMessagesReadStatusRequest.fromMap 正确解析', () {
      final request = GetMessagesReadStatusRequest.fromMap({
        'employeeId': 'emp-1',
        'deviceId': 'dev-1',
      });
      expect(request.deviceId, equals('dev-1'));
    });

    test('GetMinSeqRequest.fromMap 正确解析', () {
      final request = GetMinSeqRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('GetClearSeqRequest.fromMap 正确解析', () {
      final request = GetClearSeqRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('GetSessionSummaryRequest.fromMap 正确解析', () {
      final request = GetSessionSummaryRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('GetStateRequest.fromMap 正确解析', () {
      final request = GetStateRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('GetCallingToolIdsRequest.fromMap 正确解析', () {
      final request = GetCallingToolIdsRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('GetRegisteredToolsRequest.fromMap 正确解析', () {
      final request = GetRegisteredToolsRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 16: Host 请求反序列化验证
  // ═══════════════════════════════════════════════════════════

  group('Host 请求反序列化验证', () {
    test('GetEmployeesRequest.fromMap 正确解析', () {
      final request = GetEmployeesRequest.fromMap({
        'keyword': 'test',
        'status': 'active',
      });
      expect(request.keyword, equals('test'));
      expect(request.status, equals('active'));
    });

    test('GetEmployeesRequest.fromMap - 空参数', () {
      final request = GetEmployeesRequest.fromMap({});
      expect(request.keyword, isNull);
      expect(request.status, isNull);
    });

    test('GetEmployeeRequest.fromMap 正确解析', () {
      final request = GetEmployeeRequest.fromMap({
        'uuid': 'emp-uuid-1',
      });
      expect(request.uuid, equals('emp-uuid-1'));
    });

    test('GetSessionsRequest.fromMap 正确解析', () {
      final request = GetSessionsRequest.fromMap({
        'includeArchived': true,
      });
      expect(request.includeArchived, isTrue);
    });

    test('GetSessionsRequest.fromMap - 默认值', () {
      final request = GetSessionsRequest.fromMap({});
      expect(request.includeArchived, isFalse);
    });

    test('GetSkillsRequest.fromMap 正确解析', () {
      final request = GetSkillsRequest.fromMap({
        'employeeId': 'emp-1',
      });
      expect(request.employeeId, equals('emp-1'));
    });

    test('SyncEmployeesRequest.fromMap 正确解析', () {
      final request = SyncEmployeesRequest.fromMap({
        'employees': [
          {'uuid': 'emp-1', 'name': 'Test'},
        ],
      });
      expect(request.employees.length, equals(1));
    });

    test('SyncSessionsRequest.fromMap 正确解析', () {
      final request = SyncSessionsRequest.fromMap({
        'sessions': [
          {'employeeId': 'emp-1'},
        ],
      });
      expect(request.sessions.length, equals(1));
    });

    test('SyncMessagesRequest.fromMap 正确解析', () {
      final request = SyncMessagesRequest.fromMap({
        'messages': [
          {'id': 'msg-1', 'employeeId': 'emp-1'},
        ],
      });
      expect(request.messages.length, equals(1));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 17: Agent Todo/Spec 请求反序列化验证
  // ═══════════════════════════════════════════════════════════

  group('Agent Todo 请求反序列化验证', () {
    test('GetCurrentTopicsRequest.fromMap', () {
      final r = GetCurrentTopicsRequest.fromMap({'employeeId': 'e1'});
      expect(r.employeeId, equals('e1'));
    });

    test('GetPendingTopicsRequest.fromMap', () {
      final r = GetPendingTopicsRequest.fromMap({'employeeId': 'e1'});
      expect(r.employeeId, equals('e1'));
    });

    test('GetAllTopicsRequest.fromMap', () {
      final r = GetAllTopicsRequest.fromMap({'employeeId': 'e1'});
      expect(r.employeeId, equals('e1'));
    });

    test('GetCompletedTopicsRequest.fromMap - 默认 limit', () {
      final r = GetCompletedTopicsRequest.fromMap({'employeeId': 'e1'});
      expect(r.limit, equals(50));
    });

    test('GetCompletedTopicsRequest.fromMap - 自定义 limit', () {
      final r = GetCompletedTopicsRequest.fromMap({
        'employeeId': 'e1',
        'limit': 10,
      });
      expect(r.limit, equals(10));
    });

    test('GetTodoStatsRequest.fromMap', () {
      final r = GetTodoStatsRequest.fromMap({'employeeId': 'e1'});
      expect(r.employeeId, equals('e1'));
    });

    test('UpdateTopicContentRequest.fromMap', () {
      final r = UpdateTopicContentRequest.fromMap({
        'employeeId': 'e1',
        'topicId': 't1',
        'title': 'New Title',
        'description': 'New Desc',
      });
      expect(r.topicId, equals('t1'));
      expect(r.title, equals('New Title'));
      expect(r.description, equals('New Desc'));
    });

    test('DeleteTopicRequest.fromMap', () {
      final r = DeleteTopicRequest.fromMap({
        'employeeId': 'e1',
        'topicId': 't1',
      });
      expect(r.topicId, equals('t1'));
    });

    test('UpdateTopicStatusRequest.fromMap', () {
      final r = UpdateTopicStatusRequest.fromMap({
        'employeeId': 'e1',
        'topicId': 't1',
        'status': 'completed',
      });
      expect(r.status, equals('completed'));
    });

    test('ReorderTopicsRequest.fromMap', () {
      final r = ReorderTopicsRequest.fromMap({
        'employeeId': 'e1',
        'topicIds': ['t3', 't1', 't2'],
      });
      expect(r.topicIds, equals(['t3', 't1', 't2']));
    });

    test('ClearCompletedTopicsRequest.fromMap', () {
      final r = ClearCompletedTopicsRequest.fromMap({'employeeId': 'e1'});
      expect(r.employeeId, equals('e1'));
    });

    test('GetTaskItemsByTopicRequest.fromMap', () {
      final r = GetTaskItemsByTopicRequest.fromMap({
        'employeeId': 'e1',
        'topicId': 't1',
      });
      expect(r.topicId, equals('t1'));
    });

    test('UpdateTaskItemStatusRequest.fromMap', () {
      final r = UpdateTaskItemStatusRequest.fromMap({
        'employeeId': 'e1',
        'taskId': 'task-1',
        'status': 'done',
      });
      expect(r.taskId, equals('task-1'));
      expect(r.status, equals('done'));
    });

    test('UpdateTaskItemContentRequest.fromMap', () {
      final r = UpdateTaskItemContentRequest.fromMap({
        'employeeId': 'e1',
        'taskId': 'task-1',
        'title': 'Updated',
        'content': 'New content',
      });
      expect(r.title, equals('Updated'));
      expect(r.content, equals('New content'));
    });

    test('DeleteTaskItemRequest.fromMap', () {
      final r = DeleteTaskItemRequest.fromMap({
        'employeeId': 'e1',
        'taskId': 'task-1',
      });
      expect(r.taskId, equals('task-1'));
    });

    test('ReorderTaskItemsRequest.fromMap', () {
      final r = ReorderTaskItemsRequest.fromMap({
        'employeeId': 'e1',
        'taskItemIds': ['t2', 't1'],
      });
      expect(r.taskItemIds, equals(['t2', 't1']));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 18: Agent Spec 请求反序列化验证
  // ═══════════════════════════════════════════════════════════

  group('Agent Spec 请求反序列化验证', () {
    test('GetActiveSpecsRequest.fromMap', () {
      final r = GetActiveSpecsRequest.fromMap({'employeeId': 'e1'});
      expect(r.employeeId, equals('e1'));
    });

    test('GetCompletedSpecsRequest.fromMap - 默认 limit', () {
      final r = GetCompletedSpecsRequest.fromMap({'employeeId': 'e1'});
      expect(r.limit, equals(50));
    });

    test('GetSpecStatsRequest.fromMap', () {
      final r = GetSpecStatsRequest.fromMap({'employeeId': 'e1'});
      expect(r.employeeId, equals('e1'));
    });

    test('UpdateSpecStatusRequest.fromMap', () {
      final r = UpdateSpecStatusRequest.fromMap({
        'employeeId': 'e1',
        'specId': 's1',
        'status': 'completed',
      });
      expect(r.specId, equals('s1'));
      expect(r.status, equals('completed'));
    });

    test('UpdateSpecContentRequest.fromMap', () {
      final r = UpdateSpecContentRequest.fromMap({
        'employeeId': 'e1',
        'specId': 's1',
        'content': 'Updated spec content',
      });
      expect(r.content, equals('Updated spec content'));
    });

    test('DeleteSpecRequest.fromMap', () {
      final r = DeleteSpecRequest.fromMap({
        'employeeId': 'e1',
        'specId': 's1',
      });
      expect(r.specId, equals('s1'));
    });

    test('ClearCompletedSpecsRequest.fromMap', () {
      final r = ClearCompletedSpecsRequest.fromMap({'employeeId': 'e1'});
      expect(r.employeeId, equals('e1'));
    });

    test('ReorderSpecsRequest.fromMap', () {
      final r = ReorderSpecsRequest.fromMap({
        'employeeId': 'e1',
        'specIds': ['s2', 's1'],
      });
      expect(r.specIds, equals(['s2', 's1']));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 19: Agent 文件操作追踪请求反序列化验证
  // ═══════════════════════════════════════════════════════════

  group('Agent 文件操作追踪请求反序列化验证', () {
    test('GetFileOperationsRequest.fromMap - 默认值', () {
      final r = GetFileOperationsRequest.fromMap({'employeeId': 'e1'});
      expect(r.limit, equals(100));
      expect(r.offset, equals(0));
    });

    test('GetFileOperationsRequest.fromMap - 自定义值', () {
      final r = GetFileOperationsRequest.fromMap({
        'employeeId': 'e1',
        'limit': 50,
        'offset': 10,
      });
      expect(r.limit, equals(50));
      expect(r.offset, equals(10));
    });

    test('GetFileOperationsByMessageRequest.fromMap', () {
      final r = GetFileOperationsByMessageRequest.fromMap({
        'employeeId': 'e1',
        'messageId': 'msg-1',
      });
      expect(r.messageId, equals('msg-1'));
    });

    test('ClearFileOperationsRequest.fromMap', () {
      final r = ClearFileOperationsRequest.fromMap({'employeeId': 'e1'});
      expect(r.employeeId, equals('e1'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 20: Agent 权限/确认请求反序列化验证
  // ═══════════════════════════════════════════════════════════

  group('Agent 权限/确认请求反序列化验证', () {
    test('GetPendingPermissionRequest.fromMap', () {
      final r = GetPendingPermissionRequest.fromMap({'employeeId': 'e1'});
      expect(r.employeeId, equals('e1'));
    });

    test('RespondPermissionRequest.fromMap - 完整参数', () {
      final r = RespondPermissionRequest.fromMap({
        'employeeId': 'e1',
        'requestId': 'req-1',
        'decision': 'allow',
        'scope': 'once',
        'customPattern': null,
      });
      expect(r.requestId, equals('req-1'));
      expect(r.decision, equals('allow'));
      expect(r.scope, equals('once'));
      expect(r.customPattern, isNull);
    });

    test('RespondPermissionRequest.fromMap - 最小参数', () {
      final r = RespondPermissionRequest.fromMap({
        'employeeId': 'e1',
        'requestId': 'req-1',
        'decision': 'deny',
      });
      expect(r.scope, isNull);
      expect(r.customPattern, isNull);
    });

    test('GetPendingConfirmRequest.fromMap', () {
      final r = GetPendingConfirmRequest.fromMap({'employeeId': 'e1'});
      expect(r.employeeId, equals('e1'));
    });

    test('RespondConfirmRequest.fromMap', () {
      final r = RespondConfirmRequest.fromMap({
        'employeeId': 'e1',
        'requestId': 'req-1',
        'selectedOption': 'option_a',
      });
      expect(r.requestId, equals('req-1'));
      expect(r.selectedOption, equals('option_a'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 21: Agent MCP 请求反序列化验证
  // ═══════════════════════════════════════════════════════════

  group('Agent MCP 请求反序列化验证', () {
    test('SetMcpConfigsRequest.fromMap', () {
      final r = SetMcpConfigsRequest.fromMap({
        'employeeId': 'e1',
        'mcpConfigs': [
          {'name': 'server1', 'url': 'http://localhost:3000'},
        ],
      });
      expect(r.mcpConfigs.length, equals(1));
      expect(r.mcpConfigs.first['name'], equals('server1'));
    });

    test('GetMcpConfigsRequest.fromMap', () {
      final r = GetMcpConfigsRequest.fromMap({'employeeId': 'e1'});
      expect(r.employeeId, equals('e1'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 22: Agent 技能请求反序列化验证
  // ═══════════════════════════════════════════════════════════

  group('Agent 技能请求反序列化验证', () {
    test('SetSkillsRequest.fromMap', () {
      final r = SetSkillsRequest.fromMap({
        'employeeId': 'e1',
        'skills': [
          {'name': 'Python', 'skillType': 'mcp'},
        ],
      });
      expect(r.skills.length, equals(1));
      expect(r.skills.first['name'], equals('Python'));
    });

    test('AgentGetSkillsRequest.fromMap', () {
      final r = AgentGetSkillsRequest.fromMap({'employeeId': 'e1'});
      expect(r.employeeId, equals('e1'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 23: Agent 文件操作请求反序列化验证
  // ═══════════════════════════════════════════════════════════

  group('Agent 文件操作请求反序列化验证', () {
    test('CheckPathExistsRequest.fromMap', () {
      final r = CheckPathExistsRequest.fromMap({
        'employeeId': 'e1',
        'path': '/tmp/test',
      });
      expect(r.path, equals('/tmp/test'));
    });

    test('ListDirectoryRequest.fromMap', () {
      final r = ListDirectoryRequest.fromMap({
        'employeeId': 'e1',
        'path': '/tmp',
      });
      expect(r.path, equals('/tmp'));
    });

    test('GetFileInfoRequest.fromMap', () {
      final r = GetFileInfoRequest.fromMap({
        'employeeId': 'e1',
        'path': '/tmp/file.txt',
      });
      expect(r.path, equals('/tmp/file.txt'));
    });

    test('CreateDirectoryRequest.fromMap', () {
      final r = CreateDirectoryRequest.fromMap({
        'employeeId': 'e1',
        'path': '/tmp/newdir',
      });
      expect(r.path, equals('/tmp/newdir'));
    });

    test('DeleteFileRequest.fromMap', () {
      final r = DeleteFileRequest.fromMap({
        'employeeId': 'e1',
        'path': '/tmp/file.txt',
      });
      expect(r.path, equals('/tmp/file.txt'));
    });

    test('RenameFileRequest.fromMap', () {
      final r = RenameFileRequest.fromMap({
        'employeeId': 'e1',
        'oldPath': '/tmp/old.txt',
        'newPath': '/tmp/new.txt',
      });
      expect(r.oldPath, equals('/tmp/old.txt'));
      expect(r.newPath, equals('/tmp/new.txt'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 24: ProviderConfig 反序列化验证
  // ═══════════════════════════════════════════════════════════

  group('ProviderConfig 反序列化验证', () {
    test('ProviderConfig.fromMap - OpenAI', () {
      final config = ProviderConfig.fromMap({
        'provider': 'openai',
        'model': 'gpt-4o',
        'apiKey': 'sk-test',
        'baseUrl': 'https://api.openai.com/v1',
      });
      expect(config.provider.name, equals('openai'));
      expect(config.model, equals('gpt-4o'));
      expect(config.apiKey, equals('sk-test'));
    });

    test('ProviderConfig.fromMap - Anthropic', () {
      final config = ProviderConfig.fromMap({
        'provider': 'anthropic',
        'model': 'claude-3-opus',
        'apiKey': 'sk-ant-test',
      });
      expect(config.provider.name, equals('anthropic'));
    });

    test('ProviderConfig.fromMap - Ollama (无 apiKey)', () {
      final config = ProviderConfig.fromMap({
        'provider': 'ollama',
        'model': 'llama3',
        'baseUrl': 'http://localhost:11434',
      });
      expect(config.provider.name, equals('ollama'));
      expect(config.apiKey, isNull);
    });

    test('ProviderConfig.fromMap - 默认值', () {
      final config = ProviderConfig.fromMap({});
      expect(config.provider.name, equals('openai'));
      expect(config.model, equals('gpt-4o'));
      expect(config.options.temperature, equals(0.7));
    });

    test('ProviderConfig.toMap 往返一致', () {
      final config = ProviderConfig(
        provider: LLMProvider.openai,
        model: 'gpt-4o',
        apiKey: 'sk-test',
        baseUrl: 'https://api.openai.com/v1',
      );
      final map = config.toMap();
      final restored = ProviderConfig.fromMap(map);
      expect(restored.provider, equals(config.provider));
      expect(restored.model, equals(config.model));
      expect(restored.apiKey, equals(config.apiKey));
      expect(restored.baseUrl, equals(config.baseUrl));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 25: ProjectData 反序列化验证
  // ═══════════════════════════════════════════════════════════

  group('ProjectData 反序列化验证', () {
    test('ProjectData.fromMap - 完整数据', () {
      final data = ProjectData.fromMap({
        'projectUuid': 'proj-1',
        'projectName': 'My Project',
        'projectContext': 'A test project',
        'workPath': '/tmp/work',
      });
      expect(data.projectUuid, equals('proj-1'));
      expect(data.projectName, equals('My Project'));
      expect(data.projectContext, equals('A test project'));
      expect(data.workPath, equals('/tmp/work'));
    });

    test('ProjectData.fromMap - 空数据', () {
      final data = ProjectData.fromMap({});
      expect(data.projectUuid, isNull);
      expect(data.projectName, isNull);
    });

    test('ProjectData.toMap 往返一致', () {
      final data = ProjectData(
        projectUuid: 'proj-1',
        projectName: 'Test',
        workPath: '/tmp',
      );
      final map = data.toMap();
      final restored = ProjectData.fromMap(map);
      expect(restored.projectUuid, equals('proj-1'));
      expect(restored.projectName, equals('Test'));
      expect(restored.workPath, equals('/tmp'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 26: RemoteCallServer 集成测试
  // ═══════════════════════════════════════════════════════════

  group('RemoteCallServer 集成测试', () {
    test('通过 handleRequest 调用已注册的方法', () async {
      // 使用真实的 RemoteCallServer 测试完整请求流程
      final realServer = RemoteCallServer(
        clientService: fakeLanClient,
        localDeviceId: deviceId,
      );

      realServer.register('test.method', (params) async {
        return {'echo': params['message']};
      });

      // 构造 RPC 请求 payload
      final payload = {
        'requestId': 'req-1',
        'method': 'test.method',
        'params': {'message': 'hello'},
        'fromDeviceId': 'remote-device',
        'toDeviceId': deviceId,
      };

      await realServer.handleRequest(payload);

      // 验证响应消息被发送
      await Future.delayed(const Duration(milliseconds: 50));
      expect(fakeLanClient.sentMessages.isNotEmpty, isTrue);

      final response = fakeLanClient.sentMessages.last;
      expect(response.type, equals(LanMessageType.rpcResponse));
      expect(response.toDeviceId, equals('remote-device'));
    });

    test('通过 handleRequest 调用未注册的方法发送错误', () async {
      final realServer = RemoteCallServer(
        clientService: fakeLanClient,
        localDeviceId: deviceId,
      );

      fakeLanClient.sentMessages.clear();

      final payload = {
        'requestId': 'req-2',
        'method': 'nonExistent',
        'params': <String, dynamic>{},
        'fromDeviceId': 'remote-device',
        'toDeviceId': deviceId,
      };

      await realServer.handleRequest(payload);
      await Future.delayed(const Duration(milliseconds: 100));

      expect(fakeLanClient.sentMessages.isNotEmpty, isTrue);
      final error = fakeLanClient.sentMessages.last;
      expect(error.type, equals(LanMessageType.rpcError));
    });

    test('dispose 后 handleRequest 不处理请求', () async {
      final realServer = RemoteCallServer(
        clientService: fakeLanClient,
        localDeviceId: deviceId,
      );

      realServer.register('test.afterDispose', (params) async {
        return {'ok': true};
      });

      realServer.dispose();

      fakeLanClient.sentMessages.clear();

      final payload = {
        'requestId': 'req-3',
        'method': 'test.afterDispose',
        'params': {},
        'fromDeviceId': 'remote-device',
        'toDeviceId': deviceId,
      };

      await realServer.handleRequest(payload);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(fakeLanClient.sentMessages.isEmpty, isTrue);
    });

    test('unregister 后 hasMethod 返回 false', () async {
      final realServer = RemoteCallServer(
        clientService: fakeLanClient,
        localDeviceId: deviceId,
      );

      realServer.register('temp.method', (params) async => {});
      expect(realServer.hasMethod('temp.method'), isTrue);

      realServer.unregister('temp.method');
      expect(realServer.hasMethod('temp.method'), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 27: _mergeDeleteTime 静态方法测试
  // ═══════════════════════════════════════════════════════════

  group('_mergeDeleteTime 合并逻辑', () {
    test('两端都无 deleteTime', () async {
      // 通过 SyncEmployees handler 间接测试
      final empId = const Uuid().v4();
      final now = DateTime.now();

      // 创建本地员工（无删除）
      final localEmp = _createEmployee(uuid: empId, deviceId: deviceId);
      // 不设置 deletedTime

      // 先保存本地
      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodSyncEmployees]!;

      // 同步远程员工（也无删除）
      final remoteMap = _createEmployee(uuid: empId, updateTime: now).toMap();
      await handler({'employees': [remoteMap]});

      final local = await employeeManager.getEmployee(empId);
      expect(local!.deleted, equals(0));
      expect(local.deletedTime, isNull);
    });

    test('远程有删除记录，本地无', () async {
      final empId = const Uuid().v4();
      final deleteTime = DateTime.now();

      // 创建本地员工（无删除）
      await employeeManager.createEmployee(
        _createEmployee(uuid: empId, deviceId: deviceId),
      );

      // 同步远程已删除员工
      final remoteMap = _createEmployee(
        uuid: empId,
        deleted: 1,
        deletedTime: deleteTime,
      ).toMap();

      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodSyncEmployees]!;
      await handler({'employees': [remoteMap]});

      final local = await employeeManager.getEmployeeIncludingDeleted(empId);
      expect(local!.deleted, equals(1));
      expect(local.deletedTime, isNotNull);
    });

    test('本地有删除记录，远程无', () async {
      final empId = const Uuid().v4();
      final deleteTime = DateTime.now();

      // 创建本地已删除员工
      await employeeManager.createEmployee(
        _createEmployee(
          uuid: empId,
          deviceId: deviceId,
          deleted: 1,
          deletedTime: deleteTime,
        ),
      );

      // 同步远程未删除员工
      final remoteMap = _createEmployee(uuid: empId).toMap();

      final handler = rpcServer.capturedHandlers[HostRpcConfig.methodSyncEmployees]!;
      await handler({'employees': [remoteMap]});

      final local = await employeeManager.getEmployeeIncludingDeleted(empId);
      expect(local!.deleted, equals(1));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 28: Host 请求 toMap 往返验证
  // ═══════════════════════════════════════════════════════════

  group('Host 请求 toMap 往返验证', () {
    test('GetEmployeesRequest toMap/fromMap 往返', () {
      final original = GetEmployeesRequest(keyword: 'test', status: 'active');
      final restored = GetEmployeesRequest.fromMap(original.toMap());
      expect(restored.keyword, equals('test'));
      expect(restored.status, equals('active'));
    });

    test('GetEmployeeRequest toMap/fromMap 往返', () {
      final original = GetEmployeeRequest(uuid: 'emp-1');
      final restored = GetEmployeeRequest.fromMap(original.toMap());
      expect(restored.uuid, equals('emp-1'));
    });

    test('GetSessionsRequest toMap/fromMap 往返', () {
      final original = GetSessionsRequest(includeArchived: true);
      final restored = GetSessionsRequest.fromMap(original.toMap());
      expect(restored.includeArchived, isTrue);
    });

    test('GetSkillsRequest toMap/fromMap 往返', () {
      final original = GetSkillsRequest(employeeId: 'emp-1');
      final restored = GetSkillsRequest.fromMap(original.toMap());
      expect(restored.employeeId, equals('emp-1'));
    });

    test('SyncEmployeesRequest toMap/fromMap 往返', () {
      final original = SyncEmployeesRequest(employees: [
        {'uuid': 'emp-1', 'name': 'Test'},
      ]);
      final restored = SyncEmployeesRequest.fromMap(original.toMap());
      expect(restored.employees.length, equals(1));
    });

    test('SyncSessionsRequest toMap/fromMap 往返', () {
      final original = SyncSessionsRequest(sessions: [
        {'employeeId': 'emp-1'},
      ]);
      final restored = SyncSessionsRequest.fromMap(original.toMap());
      expect(restored.sessions.length, equals(1));
    });

    test('SyncMessagesRequest toMap/fromMap 往返', () {
      final original = SyncMessagesRequest(messages: [
        {'id': 'msg-1'},
      ]);
      final restored = SyncMessagesRequest.fromMap(original.toMap());
      expect(restored.messages.length, equals(1));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 29: Agent 请求 toMap 往返验证
  // ═══════════════════════════════════════════════════════════

  group('Agent 请求 toMap 往返验证', () {
    test('SendMessageRequest toMap/fromMap 往返', () {
      final original = SendMessageRequest(
        employeeId: 'e1',
        messageData: {'id': 'msg-1', 'content': 'Hello'},
      );
      final restored = SendMessageRequest.fromMap(original.toMap());
      expect(restored.employeeId, equals('e1'));
      expect(restored.messageData['id'], equals('msg-1'));
    });

    test('InterruptRequest toMap/fromMap 往返', () {
      final original = InterruptRequest(employeeId: 'e1');
      final restored = InterruptRequest.fromMap(original.toMap());
      expect(restored.employeeId, equals('e1'));
    });

    test('RevokeMessageRequest toMap/fromMap 往返', () {
      final original = RevokeMessageRequest(
        employeeId: 'e1',
        messageId: 'msg-1',
      );
      final restored = RevokeMessageRequest.fromMap(original.toMap());
      expect(restored.messageId, equals('msg-1'));
    });

    test('SetContextRequest toMap/fromMap 往返', () {
      final original = SetContextRequest(
        employeeId: 'e1',
        contextData: {'key': 'value'},
      );
      final restored = SetContextRequest.fromMap(original.toMap());
      expect(restored.contextData['key'], equals('value'));
    });

    test('SetProviderRequest toMap/fromMap 往返', () {
      final original = SetProviderRequest(
        employeeId: 'e1',
        providerConfig: {'provider': 'openai', 'model': 'gpt-4o'},
      );
      final restored = SetProviderRequest.fromMap(original.toMap());
      expect(restored.providerConfig['provider'], equals('openai'));
    });

    test('SetProjectRequest toMap/fromMap 往返 - 有项目', () {
      final original = SetProjectRequest(
        employeeId: 'e1',
        projectData: {'projectUuid': 'p1'},
      );
      final restored = SetProjectRequest.fromMap(original.toMap());
      expect(restored.projectData?['projectUuid'], equals('p1'));
    });

    test('SetProjectRequest toMap/fromMap 往返 - 无项目', () {
      final original = SetProjectRequest(employeeId: 'e1');
      final restored = SetProjectRequest.fromMap(original.toMap());
      expect(restored.projectData, isNull);
    });

    test('MarkMessagesAsReadBySeqRequest toMap/fromMap 往返', () {
      final original = MarkMessagesAsReadBySeqRequest(
        employeeId: 'e1',
        readerDeviceId: 'd1',
        readSeq: 42,
      );
      final restored = MarkMessagesAsReadBySeqRequest.fromMap(original.toMap());
      expect(restored.readSeq, equals(42));
      expect(restored.readerDeviceId, equals('d1'));
    });

    test('GetMessagesAfterSeqRequest toMap/fromMap 往返', () {
      final original = GetMessagesAfterSeqRequest(
        employeeId: 'e1',
        lastSeq: 100,
        limit: 50,
      );
      final restored = GetMessagesAfterSeqRequest.fromMap(original.toMap());
      expect(restored.lastSeq, equals(100));
      expect(restored.limit, equals(50));
    });

    test('RespondPermissionRequest toMap/fromMap 往返', () {
      final original = RespondPermissionRequest(
        employeeId: 'e1',
        requestId: 'req-1',
        decision: 'allow',
        scope: 'once',
      );
      final restored = RespondPermissionRequest.fromMap(original.toMap());
      expect(restored.decision, equals('allow'));
      expect(restored.scope, equals('once'));
    });

    test('RespondConfirmRequest toMap/fromMap 往返', () {
      final original = RespondConfirmRequest(
        employeeId: 'e1',
        requestId: 'req-1',
        selectedOption: 'option_a',
      );
      final restored = RespondConfirmRequest.fromMap(original.toMap());
      expect(restored.selectedOption, equals('option_a'));
    });

    test('SetSkillsRequest toMap/fromMap 往返', () {
      final original = SetSkillsRequest(
        employeeId: 'e1',
        skills: [
          {'name': 'Python'},
          {'name': 'Dart'},
        ],
      );
      final restored = SetSkillsRequest.fromMap(original.toMap());
      expect(restored.skills.length, equals(2));
    });

    test('SetMcpConfigsRequest toMap/fromMap 往返', () {
      final original = SetMcpConfigsRequest(
        employeeId: 'e1',
        mcpConfigs: [
          {'name': 'server1'},
        ],
      );
      final restored = SetMcpConfigsRequest.fromMap(original.toMap());
      expect(restored.mcpConfigs.length, equals(1));
    });

    test('ReorderTopicsRequest toMap/fromMap 往返', () {
      final original = ReorderTopicsRequest(
        employeeId: 'e1',
        topicIds: ['t3', 't1', 't2'],
      );
      final restored = ReorderTopicsRequest.fromMap(original.toMap());
      expect(restored.topicIds, equals(['t3', 't1', 't2']));
    });

    test('ReorderTaskItemsRequest toMap/fromMap 往返', () {
      final original = ReorderTaskItemsRequest(
        employeeId: 'e1',
        taskItemIds: ['t2', 't1'],
      );
      final restored = ReorderTaskItemsRequest.fromMap(original.toMap());
      expect(restored.taskItemIds, equals(['t2', 't1']));
    });

    test('ReorderSpecsRequest toMap/fromMap 往返', () {
      final original = ReorderSpecsRequest(
        employeeId: 'e1',
        specIds: ['s2', 's1'],
      );
      final restored = ReorderSpecsRequest.fromMap(original.toMap());
      expect(restored.specIds, equals(['s2', 's1']));
    });

    test('UpdateTopicContentRequest toMap/fromMap 往返', () {
      final original = UpdateTopicContentRequest(
        employeeId: 'e1',
        topicId: 't1',
        title: 'Title',
        description: 'Desc',
      );
      final restored = UpdateTopicContentRequest.fromMap(original.toMap());
      expect(restored.topicId, equals('t1'));
      expect(restored.title, equals('Title'));
      expect(restored.description, equals('Desc'));
    });

    test('UpdateSpecContentRequest toMap/fromMap 往返', () {
      final original = UpdateSpecContentRequest(
        employeeId: 'e1',
        specId: 's1',
        content: 'Content',
      );
      final restored = UpdateSpecContentRequest.fromMap(original.toMap());
      expect(restored.content, equals('Content'));
    });

    test('GetFileOperationsRequest toMap/fromMap 往返', () {
      final original = GetFileOperationsRequest(
        employeeId: 'e1',
        limit: 50,
        offset: 10,
      );
      final restored = GetFileOperationsRequest.fromMap(original.toMap());
      expect(restored.limit, equals(50));
      expect(restored.offset, equals(10));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 30: Entity 序列化验证
  // ═══════════════════════════════════════════════════════════

  group('Entity 序列化验证', () {
    test('AiEmployeeEntity toMap/fromMap 往返', () {
      final now = DateTime.now();
      final emp = AiEmployeeEntity(
        uuid: 'emp-1',
        name: 'Test',
        provider: 'openai',
        model: 'gpt-4o',
        apiKey: 'sk-test',
        apiBaseUrl: 'https://api.openai.com',
        projectUuid: 'proj-1',
        projectName: 'Project',
        projectContext: 'Context',
        workPath: '/tmp',
        createTime: now,
        updateTime: now,
      );
      final map = emp.toMap();
      final restored = AiEmployeeEntity.fromMap(map);
      expect(restored.uuid, equals('emp-1'));
      expect(restored.name, equals('Test'));
      expect(restored.provider, equals('openai'));
      expect(restored.model, equals('gpt-4o'));
      expect(restored.apiKey, equals('sk-test'));
      expect(restored.projectUuid, equals('proj-1'));
      expect(restored.projectName, equals('Project'));
    });

    test('AiEmployeeEntity copyWith 正确复制', () {
      final now = DateTime.now();
      final emp = AiEmployeeEntity(
        uuid: 'emp-1',
        name: 'Old',
        createTime: now,
        updateTime: now,
      );
      final updated = emp.copyWith(
        name: 'New',
        provider: 'anthropic',
        model: 'claude-3',
      );
      expect(updated.uuid, equals('emp-1'));
      expect(updated.name, equals('New'));
      expect(updated.provider, equals('anthropic'));
      expect(updated.model, equals('claude-3'));
      // 原始不变
      expect(emp.name, equals('Old'));
    });

    test('AiEmployeeSessionEntity toMap/fromMap 往返', () {
      final now = DateTime.now();
      final session = AiEmployeeSessionEntity(
        employeeId: 'emp-1',
        title: 'Test Session',
        createTime: now,
        updateTime: now,
      );
      final map = session.toMap();
      final restored = AiEmployeeSessionEntity.fromMap(map);
      expect(restored.employeeId, equals('emp-1'));
      expect(restored.title, equals('Test Session'));
    });

    test('AiEmployeeSkillEntity toMap/fromMap 往返', () {
      final now = DateTime.now();
      final skill = AiEmployeeSkillEntity(
        uuid: 'skill-1',
        employeeId: 'emp-1',
        deviceId: 'dev-1',
        name: 'Python',
        skillType: 'mcp',
        createTime: now,
        updateTime: now,
      );
      final map = skill.toMap();
      final restored = AiEmployeeSkillEntity.fromMap(map);
      expect(restored.uuid, equals('skill-1'));
      expect(restored.name, equals('Python'));
      expect(restored.deviceId, equals('dev-1'));
    });

    test('SyncWatermarkEntity toMap/fromMap 往返', () {
      final entity = SyncWatermarkEntity(
        employeeId: 'emp-1',
        deviceId: 'dev-1',
        lastSeq: 42,
        clearSeq: 10,
        updateTime: DateTime.now(),
      );
      final map = entity.toMap();
      final restored = SyncWatermarkEntity.fromMap(map);
      expect(restored.employeeId, equals('emp-1'));
      expect(restored.lastSeq, equals(42));
      expect(restored.clearSeq, equals(10));
    });

    test('SessionSummaryEntity toMap/fromMap 往返', () {
      final entity = SessionSummaryEntity(
        employeeId: 'emp-1',
        deviceId: 'dev-1',
        unreadCount: 5,
        lastMsgId: 'msg-1',
        lastMsgRole: 'user',
        lastMsgContent: 'Hello',
        lastMsgTime: 1234567890,
        updateTime: 1234567890,
      );
      final map = entity.toMap();
      final restored = SessionSummaryEntity.fromMap(map);
      expect(restored.employeeId, equals('emp-1'));
      expect(restored.unreadCount, equals(5));
      expect(restored.lastMsgId, equals('msg-1'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Group 31: PermissionDecision 和 PermissionApprovalScope 枚举验证
  // ═══════════════════════════════════════════════════════════

  group('PermissionDecision 枚举验证', () {
    test('fromString - allow', () {
      expect(PermissionDecision.fromString('allow'), equals(PermissionDecision.allow));
    });

    test('fromString - deny', () {
      expect(PermissionDecision.fromString('deny'), equals(PermissionDecision.deny));
    });

    test('fromString - allowAlways', () {
      expect(PermissionDecision.fromString('allowAlways'), equals(PermissionDecision.allowAlways));
    });

    test('fromString - 未知值默认 deny', () {
      expect(PermissionDecision.fromString('unknown'), equals(PermissionDecision.deny));
    });
  });

  group('PermissionApprovalScope 枚举验证', () {
    test('fromString - once', () {
      expect(PermissionApprovalScope.fromString('once'), equals(PermissionApprovalScope.once));
    });

    test('fromString - exact', () {
      expect(PermissionApprovalScope.fromString('exact'), equals(PermissionApprovalScope.exact));
    });

    test('fromString - pattern', () {
      expect(PermissionApprovalScope.fromString('pattern'), equals(PermissionApprovalScope.pattern));
    });

    test('fromString - all', () {
      expect(PermissionApprovalScope.fromString('all'), equals(PermissionApprovalScope.all));
    });

    test('fromString - 未知值默认 once', () {
      expect(PermissionApprovalScope.fromString('unknown'), equals(PermissionApprovalScope.once));
    });
  });
}
