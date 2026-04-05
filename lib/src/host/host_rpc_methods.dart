import '../persistence/persistence.dart';
import '../rpc/remote_call_server.dart';
import '../service/service.dart';
import 'client_session_manager.dart';

/// Host端RPC方法名常量
class HostRpcConfig {
  // ===== 员工管理 =====
  static const String methodGetEmployees = 'hostGetEmployees';
  static const String methodGetEmployee = 'hostGetEmployee';
  static const String methodCreateEmployee = 'hostCreateEmployee';
  static const String methodUpdateEmployee = 'hostUpdateEmployee';
  static const String methodDeleteEmployee = 'hostDeleteEmployee';

  // ===== 会话管理 =====
  static const String methodGetSessions = 'hostGetSessions';
  static const String methodGetSession = 'hostGetSession';
  static const String methodCreateSession = 'hostCreateSession';
  static const String methodUpdateSession = 'hostUpdateSession';
  static const String methodDeleteSession = 'hostDeleteSession';

  // ===== 技能管理 =====
  static const String methodGetSkills = 'hostGetSkills';
  static const String methodCreateSkill = 'hostCreateSkill';
  static const String methodUpdateSkill = 'hostUpdateSkill';
  static const String methodDeleteSkill = 'hostDeleteSkill';

  // ===== 数据同步 =====
  static const String methodSyncEmployees = 'hostSyncEmployees';
  static const String methodSyncSessions = 'hostSyncSessions';
  static const String methodSyncMessages = 'hostSyncMessages';

  // ===== 设备管理 =====
  static const String methodGetOnlineDevices = 'getOnlineDevices';
  static const String methodGetDeviceInfo = 'getDeviceInfo';
}

/// 注册Host端RPC方法
void registerHostRpcMethods({
  required RemoteCallServer rpcServer,
  required EmployeeManager employeeManager,
  required SessionManager sessionManager,
  required SkillManager skillManager,
  required MessageStoreService messageStore,
  required ClientSessionManager clientSessionManager,
}) {
  // ===== 员工管理方法 =====

  // 获取员工列表
  rpcServer.register(HostRpcConfig.methodGetEmployees, (params) async {
    final employees = await employeeManager.getEmployees(
      keyword: params['keyword'] as String?,
      status: params['status'] as String?,
    );
    return {'employees': employees.map((e) => e.toMap()).toList()};
  });

  // 获取单个员工
  rpcServer.register(HostRpcConfig.methodGetEmployee, (params) async {
    final uuid = params['uuid'] as String;
    final employee = await employeeManager.getEmployee(uuid);
    if (employee == null) {
      throw Exception('Employee not found: $uuid');
    }
    return {'employee': employee.toMap()};
  });

  // 创建员工
  rpcServer.register(HostRpcConfig.methodCreateEmployee, (params) async {
    final employeeData = params['employee'] as Map<String, dynamic>;
    final employee = AiEmployeeEntity.fromMap(employeeData);
    final created = await employeeManager.createEmployee(employee);
    return {'employee': created.toMap()};
  });

  // 更新员工
  rpcServer.register(HostRpcConfig.methodUpdateEmployee, (params) async {
    final employeeData = params['employee'] as Map<String, dynamic>;
    final employee = AiEmployeeEntity.fromMap(employeeData);
    await employeeManager.updateEmployee(employee);
    return {'success': true};
  });

  // 删除员工
  rpcServer.register(HostRpcConfig.methodDeleteEmployee, (params) async {
    final uuid = params['uuid'] as String;
    await employeeManager.deleteEmployee(uuid);
    return {'success': true};
  });

  // ===== 会话管理方法 =====

  // 获取会话列表
  rpcServer.register(HostRpcConfig.methodGetSessions, (params) async {
    final sessions = await sessionManager.getAllSessions(
      employeeUuid: params['employeeUuid'] as String?,
      includeArchived: params['includeArchived'] as bool? ?? false,
    );
    return {'sessions': sessions.map((s) => s.toMap()).toList()};
  });

  // 获取单个会话
  rpcServer.register(HostRpcConfig.methodGetSession, (params) async {
    final uuid = params['uuid'] as String;
    final session = await sessionManager.getSession(uuid);
    if (session == null) {
      throw Exception('Session not found: $uuid');
    }
    return {'session': session.toMap()};
  });

  // 创建会话
  rpcServer.register(HostRpcConfig.methodCreateSession, (params) async {
    final session = await sessionManager.createSession(
      employeeUuid: params['employeeUuid'] as String,
      title: params['title'] as String?,
      projectUuid: params['projectUuid'] as String?,
      providerConfig: params['providerConfig'] as Map<String, dynamic>?,
    );
    return {'session': session.toMap()};
  });

  // 更新会话
  rpcServer.register(HostRpcConfig.methodUpdateSession, (params) async {
    final sessionData = params['session'] as Map<String, dynamic>;
    final session = AiEmployeeSessionEntity.fromMap(sessionData);
    await sessionManager.updateSession(session);
    return {'success': true};
  });

  // 删除会话
  rpcServer.register(HostRpcConfig.methodDeleteSession, (params) async {
    final uuid = params['uuid'] as String;
    await sessionManager.deleteSession(uuid);
    return {'success': true};
  });

  // ===== 技能管理方法 =====

  // 获取员工技能列表
  rpcServer.register(HostRpcConfig.methodGetSkills, (params) async {
    final employeeUuid = params['employeeUuid'] as String;
    final skills = await skillManager.getSkills(employeeUuid);
    return {'skills': skills.map((s) => s.toMap()).toList()};
  });

  // 创建技能
  rpcServer.register(HostRpcConfig.methodCreateSkill, (params) async {
    final skillData = params['skill'] as Map<String, dynamic>;
    final skill = AiEmployeeSkillEntity.fromMap(skillData);
    final created = await skillManager.createSkill(skill);
    return {'skill': created.toMap()};
  });

  // 更新技能
  rpcServer.register(HostRpcConfig.methodUpdateSkill, (params) async {
    final skillData = params['skill'] as Map<String, dynamic>;
    final skill = AiEmployeeSkillEntity.fromMap(skillData);
    await skillManager.updateSkill(skill);
    return {'success': true};
  });

  // 删除技能
  rpcServer.register(HostRpcConfig.methodDeleteSkill, (params) async {
    final uuid = params['uuid'] as String;
    await skillManager.deleteSkill(uuid);
    return {'success': true};
  });

  // ===== 数据同步方法 =====

  // 同步员工数据
  rpcServer.register(HostRpcConfig.methodSyncEmployees, (params) async {
    final employeesData = params['employees'] as List;
    final employees = employeesData
        .map((e) => AiEmployeeEntity.fromMap(e as Map<String, dynamic>))
        .toList();

    for (final employee in employees) {
      final existing = await employeeManager.getEmployee(employee.uuid);
      if (existing == null) {
        await employeeManager.createEmployee(employee);
      } else {
        await employeeManager.updateEmployee(employee);
      }
    }
    return {'count': employees.length};
  });

  // 同步会话数据
  rpcServer.register(HostRpcConfig.methodSyncSessions, (params) async {
    final sessionsData = params['sessions'] as List;
    final sessions = sessionsData
        .map((s) => AiEmployeeSessionEntity.fromMap(s as Map<String, dynamic>))
        .toList();

    for (final session in sessions) {
      final existing = await sessionManager.getSession(session.uuid);
      if (existing == null) {
        // 创建新会话需要employeeUuid
        await sessionManager.createSession(
          employeeUuid: session.employeeUuid,
          title: session.title,
          projectUuid: session.projectUuid,
        );
      } else {
        await sessionManager.updateSession(session);
      }
    }
    return {'count': sessions.length};
  });

  // 同步消息数据
  rpcServer.register(HostRpcConfig.methodSyncMessages, (params) async {
    final messagesData = params['messages'] as List;
    final messages = messagesData
        .map((m) => AiEmployeeMessageEntity.fromMap(m as Map<String, dynamic>))
        .toList();

    await messageStore.addMessages(messages);
    return {'count': messages.length};
  });

  // ===== 设备管理方法 =====

  // 获取在线设备列表
  rpcServer.register(HostRpcConfig.methodGetOnlineDevices, (params) async {
    final devices = clientSessionManager.getOnlineDevicesInfo();
    return {'devices': devices};
  });

  // 获取设备信息
  rpcServer.register(HostRpcConfig.methodGetDeviceInfo, (params) async {
    final deviceId = params['deviceId'] as String;
    final clients = clientSessionManager.getClientsByDeviceId(deviceId);

    if (clients.isEmpty) {
      throw Exception('Device not found: $deviceId');
    }

    final firstClient = clients.first;
    return {
      'device': {
        'deviceId': deviceId,
        'deviceName': firstClient.deviceName,
        'topic': firstClient.topic,
        'connectedAt': firstClient.connectedAt.millisecondsSinceEpoch,
        'clientCount': clients.length,
      },
    };
  });
}
