import 'dart:io';

import '../../agent/agent_state.dart';
import '../../agent/entity/entity.dart';
import '../../agent/rpc/agent_rpc_config.dart';
import '../../entity/host_rpc_request.dart';
import '../../host/host_rpc_methods.dart';
import '../../persistence/persistence.dart';
import '../../rpc/remote_call_server.dart';
import '../../service/service.dart';
import 'data_sync_manager.dart';
import 'device_agent_manager.dart';
import 'device_config_manager.dart';

/// RPC 方法注册器
///
/// 负责将所有 Agent 和 Host RPC 方法注册到 [RemoteCallServer]。
class DeviceRpcHandler {
  final String _deviceId;
  late final EmployeeManager _employeeManager = EmployeeManager.getInstance(_deviceId);
  late final SessionManager _sessionManager = SessionManager.getInstance(_deviceId);
  late final SkillManager _skillManager = SkillManager.getInstance(_deviceId);
  late final MessageStoreService _messageStoreService = MessageStoreService.getInstance(_deviceId);
  late final DeviceAgentManager _agentManager = DeviceAgentManager.getInstance(_deviceId);
  late final DeviceConfigManager _configManager = DeviceConfigManager.getInstance(_deviceId);
  late final DataSyncManager _dataSyncManager = DataSyncManager.getInstance(_deviceId);

  DeviceRpcHandler._({required String deviceId}) : _deviceId = deviceId;

  // ===== 单例管理 =====

  static final Map<String, DeviceRpcHandler> _instances = {};

  static DeviceRpcHandler getInstance(String deviceId) {
    return _instances.putIfAbsent(
      deviceId,
      () => DeviceRpcHandler._(deviceId: deviceId),
    );
  }

  static void removeInstance(String deviceId) {
    _instances.remove(deviceId);
  }

  /// 注册所有 RPC 方法到服务器
  void registerAll(RemoteCallServer rpcServer) {
    _registerAgentMethods(rpcServer);
    _registerHostMethods(rpcServer);
  }

  void _registerAgentMethods(RemoteCallServer rpcServer) {
    // Agent 对话操作
    rpcServer.register(AgentRpcConfig.methodSendMessage, (params) async {
      final request = SendMessageRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);

      print('[DeviceRpcHandler] RPC sendMessage 接收到消息数据: ${request.messageData}');
      print('[DeviceRpcHandler] 消息ID: ${request.messageData['id']}');

      final input = MessageInput.fromMap(request.messageData);
      print('[DeviceRpcHandler] MessageInput.id: ${input.id}');

      final messageId = await agent.sendMessage(input);
      print('[DeviceRpcHandler] Agent返回的消息ID: $messageId');

      return {'messageId': messageId};
    });

    rpcServer.register(AgentRpcConfig.methodInterrupt, (params) async {
      final request = InterruptRequest.fromMap(params);
      final agent = _agentManager.getLocalAgent(request.employeeId);
      if (agent == null) return {};
      await agent.interrupt();
      return {};
    });

    rpcServer.register(AgentRpcConfig.methodGetSessionMessages, (params) async {
      final request = GetSessionMessagesRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final messages = await agent.getSessionMessages();
      return {'messages': messages.map((m) => m.toMap()).toList()};
    });

    rpcServer.register(AgentRpcConfig.methodGetSessionMessagesByUserCount, (params) async {
      final request = GetSessionMessagesByUserCountRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final messages = await agent.getSessionMessagesByUserCount(
        userMessageLimit: request.userMessageLimit,
      );
      return {'messages': messages.map((m) => m.toMap()).toList()};
    });

    rpcServer.register(AgentRpcConfig.methodGetSessionMessagesPaged, (params) async {
      final request = GetSessionMessagesPagedRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final messages = await agent.getSessionMessagesPaged(
        pageSize: request.pageSize,
        offset: request.offset,
      );
      return {'messages': messages.map((m) => m.toMap()).toList()};
    });

    rpcServer.register(AgentRpcConfig.methodGetUnreceivedMessages, (params) async {
      final request = GetUnreceivedMessagesRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final messages = await agent.getUnreceivedMessages(
        receiverDeviceId: request.receiverDeviceId,
        offset: request.offset,
        limit: request.limit,
      );
      return {'messages': messages.map((m) => m.toMap()).toList()};
    });

    rpcServer.register(AgentRpcConfig.methodMarkMessagesAsReceived, (params) async {
      final request = MarkMessagesAsReceivedRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.markMessagesAsReceived(
        receiverDeviceId: request.receiverDeviceId,
        messageReceiveList: request.messageReceiveList,
      );
      return {'success': true};
    });

    // LSN 增量拉取消息
    rpcServer.register(AgentRpcConfig.methodGetMessagesAfterSeq, (params) async {
      final request = GetMessagesAfterSeqRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final messages = await agent.getMessagesAfterSeq(
        employeeId: request.employeeId,
        lastSeq: request.lastSeq,
        limit: request.limit,
      );
      return {'messages': messages.map((m) => m.toMap()).toList()};
    });

    // 获取最大 seq
    rpcServer.register(AgentRpcConfig.methodGetMaxSeq, (params) async {
      print('[DeviceRpcHandler] RPC getMaxSeq');
      final request = GetSessionMessagesRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final maxSeq = await agent.getMaxSeq(employeeId: request.employeeId);
      return {'maxSeq': maxSeq};
    });

    // 获取最小 seq
    rpcServer.register(AgentRpcConfig.methodGetMinSeq, (params) async {
      final request = GetMinSeqRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final minSeq = await agent.getMinSeq(employeeId: request.employeeId);
      return {'minSeq': minSeq};
    });

    // 获取清空水位线
    rpcServer.register(AgentRpcConfig.methodGetClearSeq, (params) async {
      final request = GetClearSeqRequest.fromMap(params);
      final watermarkStore = SyncWatermarkStore(deviceId: _deviceId);
      final clearSeq = watermarkStore.getClearSeq(request.employeeId, deviceId: _deviceId) ?? 0;
      return {'clearSeq': clearSeq};
    });

    // 标记消息为已读
    rpcServer.register(AgentRpcConfig.methodMarkMessagesAsRead, (params) async {
      final request = MarkMessagesAsReadRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.markMessagesAsRead(
        readerDeviceId: request.readerDeviceId,
        employeeId: request.employeeId,
        messageIds: request.messageIds,
      );
      return {'success': true};
    });

    // 查询消息已读状态
    rpcServer.register(AgentRpcConfig.methodGetMessagesReadStatus, (params) async {
      final request = GetMessagesReadStatusRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final result = await agent.getMessagesReadStatus(
        deviceId: request.deviceId,
        employeeId: request.employeeId,
      );
      return result.toMap();
    });

    rpcServer.register(AgentRpcConfig.methodGetState, (params) async {
      final request = GetStateRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      return agent.getStateSnapshot().toMap();
    });

    rpcServer.register(AgentRpcConfig.methodGetCallingToolIds, (params) async {
      final request = GetCallingToolIdsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      return {'callingToolIds': agent.getCallingToolIds()};
    });

    rpcServer.register(AgentRpcConfig.methodSetContext, (params) async {
      final request = SetContextRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.setContext(request.contextData);
      return {};
    });

    rpcServer.register(AgentRpcConfig.methodGetContext, (params) async {
      final request = GetContextRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      return {'context': agent.getCurrentContext()};
    });

    rpcServer.register(AgentRpcConfig.methodSetProvider, (params) async {
      final request = SetProviderRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final providerConfig = ProviderConfig.fromMap(request.providerConfig);
      await agent.setProvider(providerConfig);

      // 同步更新 Employee 实体的 provider 信息
      final employee = await _employeeManager.getEmployee(request.employeeId);
      if (employee != null) {
        final newProvider = providerConfig.provider.name;
        final newModel = providerConfig.model;
        final newApiKey = providerConfig.apiKey;
        final newBaseUrl = providerConfig.baseUrl;
        if (employee.provider != newProvider ||
            employee.model != newModel ||
            employee.apiKey != newApiKey ||
            employee.apiBaseUrl != newBaseUrl) {
          await _employeeManager.updateEmployee(
            employee.copyWith(
              provider: newProvider,
              model: newModel,
              apiKey: newApiKey,
              apiBaseUrl: newBaseUrl,
            ),
          );
          print('[DeviceRpcHandler] methodSetProvider: Employee provider synced: provider=$newProvider, model=$newModel');
        }
      }

      // 广播到其他设备
      await _dataSyncManager.broadcastEmployeeToAllDevices(request.employeeId);

      return {};
    });

    rpcServer.register(AgentRpcConfig.methodClearSession, (params) async {
      final request = ClearSessionRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.clearCurrentSession();
      return {};
    });

    rpcServer.register(AgentRpcConfig.methodPing, (params) async {
      final request = PingRequest.fromMap(params);
      if (request.employeeId != null && request.employeeId!.isNotEmpty) {
        final agent = _agentManager.getLocalAgent(request.employeeId!);
        return {
          'alive': agent != null && agent.isAlive,
          'employeeId': request.employeeId,
        };
      }
      return {
        'alive': true,
        'agentCount': _agentManager.localAgentCount,
        'deviceId': _deviceId,
      };
    });

    rpcServer.register(AgentRpcConfig.methodGetOrCreateAgent, (params) async {
      final request = GetOrCreateAgentRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      return {
        'employeeId': request.employeeId,
        'status': agent.status.name,
      };
    });

    // 消息撤回
    rpcServer.register(AgentRpcConfig.methodRevokeMessage, (params) async {
      final request = RevokeMessageRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.revokeMessage(request.messageId);
      return {};
    });

    // 权限管理方法
    rpcServer.register(AgentRpcConfig.methodGetPendingPermission, (params) async {
      final request = GetPendingPermissionRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final permissionRequest = agent.getPendingPermissionRequest();
      return {'request': permissionRequest?.toMap()};
    });

    rpcServer.register(AgentRpcConfig.methodRespondPermission, (params) async {
      final request = RespondPermissionRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);

      final decision = PermissionDecision.values.firstWhere(
        (d) => d.name == request.decision,
        orElse: () => PermissionDecision.deny,
      );

      await agent.respondToPermission(request.requestId, decision);
      return {};
    });

    // 上下文管理
    rpcServer.register(AgentRpcConfig.methodClearContext, (params) async {
      final request = ClearContextRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.clearContext();
      return {};
    });

    // 模型管理
    rpcServer.register(AgentRpcConfig.methodGetProvider, (params) async {
      final request = GetProviderRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      return {'providerConfig': agent.getProviderConfig()?.toMap()};
    });

    // 技能管理
    rpcServer.register(AgentRpcConfig.methodSetSkills, (params) async {
      final request = SetSkillsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.setSkills(request.skills);
      return {};
    });

    rpcServer.register(AgentRpcConfig.methodGetSkills, (params) async {
      final request = AgentGetSkillsRequest.fromMap(params);
      final store = SkillStore(deviceId: _deviceId);
      final entities = await store.findByEmployeeWithDeviceId(_deviceId, request.employeeId);
      return {'skills': entities.map((e) => e.toMap()).toList()};
    });

    // MCP 管理
    rpcServer.register(AgentRpcConfig.methodSetMcpConfigs, (params) async {
      final request = SetMcpConfigsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.setMcpConfigs(request.mcpConfigs);
      return {};
    });

    rpcServer.register(AgentRpcConfig.methodGetMcpConfigs, (params) async {
      final request = GetMcpConfigsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      return {'mcpConfigs': agent.getMcpConfigs()};
    });

    // 项目管理
    rpcServer.register(AgentRpcConfig.methodSetProject, (params) async {
      final request = SetProjectRequest.fromMap(params);
      print('[DeviceRpcHandler] agentSetProject RPC: employeeId=${request.employeeId}, projectData=${request.projectData}');
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final projectData = request.projectData != null
          ? ProjectData.fromMap(request.projectData!)
          : null;
      print('[DeviceRpcHandler] agentSetProject: parsed projectUuid=${projectData?.projectUuid}, projectName=${projectData?.projectName}');
      await agent.setProject(projectData);

      // 同步更新 Employee 实体的项目信息
      final projectUuid = projectData?.projectUuid;
      final employee = await _employeeManager.getEmployee(request.employeeId);
      if (employee != null && employee.projectUuid != projectUuid) {
        await _employeeManager.updateEmployee(
          employee.copyWith(
            projectUuid: projectUuid,
            projectName: projectData?.projectName,
            projectContext: projectData?.projectContext,
            workPath: projectData?.workPath,
          ),
        );
        print('[DeviceRpcHandler] agentSetProject: Employee project synced: uuid=${employee.projectUuid} -> $projectUuid, name=${projectData?.projectName}');
      }

      // 广播到其他设备
      await _dataSyncManager.broadcastEmployeeToAllDevices(request.employeeId);

      return {};
    });

    rpcServer.register(AgentRpcConfig.methodGetProjectUuid, (params) async {
      final request = GetProjectUuidRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      return {'projectUuid': agent.getCurrentProjectUuid()};
    });

    // 文件系统操作
    rpcServer.register(AgentRpcConfig.methodCheckPathExists, (params) async {
      final request = CheckPathExistsRequest.fromMap(params);
      final path = request.path;
      try {
        final dir = await Directory(path).exists();
        if (dir) {
          return {'exists': true, 'isDirectory': true};
        }
        final file = await File(path).exists();
        return {'exists': file, 'isDirectory': false};
      } catch (e) {
        return {'exists': false, 'error': e.toString()};
      }
    });

    rpcServer.register(AgentRpcConfig.methodListDirectory, (params) async {
      final request = ListDirectoryRequest.fromMap(params);
      final dir = Directory(request.path);
      if (!await dir.exists()) {
        return {'items': [], 'error': '目录不存在'};
      }
      final items = <Map<String, dynamic>>[];
      try {
        await for (final entity in dir.list(recursive: false, followLinks: false)) {
          try {
            final stat = await entity.stat();
            final entityPath = entity.path;
            final entityName = entityPath.split(Platform.pathSeparator).last;
            if (entityName.isEmpty) continue;
            items.add({
              'name': entityName,
              'path': entityPath,
              'isDirectory': entity is Directory,
              'size': stat.size,
              'modified': stat.modified.toIso8601String(),
            });
          } catch (_) {
            continue;
          }
        }
        items.sort((a, b) {
          final aDir = a['isDirectory'] as bool;
          final bDir = b['isDirectory'] as bool;
          if (aDir && !bDir) return -1;
          if (!aDir && bDir) return 1;
          return (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase());
        });
        return {'items': items};
      } catch (e) {
        return {'items': [], 'error': e.toString()};
      }
    });

    rpcServer.register(AgentRpcConfig.methodGetFileInfo, (params) async {
      final request = GetFileInfoRequest.fromMap(params);
      final path = request.path;
      try {
        final file = File(path);
        if (await file.exists()) {
          final stat = await file.stat();
          final name = path.split(Platform.pathSeparator).last;
          return {
            'exists': true,
            'name': name,
            'path': path,
            'isDirectory': false,
            'size': stat.size,
            'modified': stat.modified.toIso8601String(),
          };
        }
        final dir = Directory(path);
        if (await dir.exists()) {
          final stat = await dir.stat();
          final name = path.split(Platform.pathSeparator).last;
          return {
            'exists': true,
            'name': name,
            'path': path,
            'isDirectory': true,
            'size': stat.size,
            'modified': stat.modified.toIso8601String(),
          };
        }
        return {'exists': false};
      } catch (e) {
        return {'exists': false, 'error': e.toString()};
      }
    });

    rpcServer.register(AgentRpcConfig.methodCreateDirectory, (params) async {
      final request = CreateDirectoryRequest.fromMap(params);
      try {
        await Directory(request.path).create(recursive: true);
        return {'success': true};
      } catch (e) {
        return {'success': false, 'error': e.toString()};
      }
    });

    rpcServer.register(AgentRpcConfig.methodDeleteFile, (params) async {
      final request = DeleteFileRequest.fromMap(params);
      final path = request.path;
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          return {'success': true};
        }
        final dir = Directory(path);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
          return {'success': true};
        }
        return {'success': false, 'error': '路径不存在'};
      } catch (e) {
        return {'success': false, 'error': e.toString()};
      }
    });

    rpcServer.register(AgentRpcConfig.methodRenameFile, (params) async {
      final request = RenameFileRequest.fromMap(params);
      try {
        final entity = File(request.oldPath);
        if (await entity.exists()) {
          await entity.rename(request.newPath);
          return {'success': true};
        }
        final dir = Directory(request.oldPath);
        if (await dir.exists()) {
          await dir.rename(request.newPath);
          return {'success': true};
        }
        return {'success': false, 'error': '路径不存在'};
      } catch (e) {
        return {'success': false, 'error': e.toString()};
      }
    });

    // 工具管理
    rpcServer.register(AgentRpcConfig.methodGetRegisteredTools, (params) async {
      final request = GetRegisteredToolsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      return {'tools': agent.getRegisteredTools()};
    });
  }

  void _registerHostMethods(RemoteCallServer rpcServer) {
    // 员工管理方法
    rpcServer.register(HostRpcConfig.methodGetEmployees, (params) async {
      final request = GetEmployeesRequest.fromMap(params);
      final employees = await _employeeManager.getEmployees(
        keyword: request.keyword,
        status: request.status,
      );
      return {'employees': employees.map((e) => e.toMap()).toList()};
    });

    rpcServer.register(HostRpcConfig.methodGetEmployee, (params) async {
      final request = GetEmployeeRequest.fromMap(params);
      final employee = await _employeeManager.getEmployee(request.uuid);
      if (employee == null) {
        throw Exception('Employee not found: ${request.uuid}');
      }
      return {'employee': employee.toMap()};
    });

    // 会话管理方法
    rpcServer.register(HostRpcConfig.methodGetSessions, (params) async {
      final request = GetSessionsRequest.fromMap(params);
      final includeDeleted = params['includeDeleted'] as bool? ?? false;
      final sessions = await _sessionManager.getAllSessions(
        includeArchived: request.includeArchived,
        includeDeleted: includeDeleted,
      );
      return {'sessions': sessions.map((s) => s.toMap()).toList()};
    });

    // 技能管理方法
    rpcServer.register(HostRpcConfig.methodGetSkills, (params) async {
      final request = GetSkillsRequest.fromMap(params);
      final skills = await _skillManager.getSkills(request.employeeId);
      return {'skills': skills.map((s) => s.toMap()).toList()};
    });

    // 数据同步方法
    rpcServer.register(HostRpcConfig.methodSyncEmployees, (params) async {
      final request = SyncEmployeesRequest.fromMap(params);
      final employees = request.employees
          .map((e) => AiEmployeeEntity.fromMap(e))
          .toList();
      for (final employee in employees) {
        final existing = await _employeeManager.getEmployeeIncludingDeleted(employee.uuid);
        if (existing == null) {
          // 本地不存在（含已删除） → 直接保存
          await _employeeManager.saveEmployee(employee);
        } else {
          // 合并：deleteTime 独立比较，数据按 updateTime 合并
          final localDT = existing.deletedTime;
          final remoteDT = employee.deletedTime;
          DateTime? mergedDeleteTime;
          int mergedDeleted;

          if (localDT == null && remoteDT == null) {
            mergedDeleteTime = null;
            mergedDeleted = 0;
          } else if (localDT == null) {
            mergedDeleteTime = remoteDT;
            mergedDeleted = employee.deleted;
          } else if (remoteDT == null) {
            mergedDeleteTime = localDT;
            mergedDeleted = existing.deleted;
          } else {
            if (localDT.isAfter(remoteDT)) {
              mergedDeleteTime = localDT;
              mergedDeleted = existing.deleted;
            } else {
              mergedDeleteTime = remoteDT;
              mergedDeleted = employee.deleted;
            }
          }

          final shouldUpdateData =
              employee.updateTime.isAfter(existing.updateTime);
          final shouldUpdateDelete =
              mergedDeleteTime != localDT || mergedDeleted != existing.deleted;

          if (shouldUpdateData || shouldUpdateDelete) {
            final base = shouldUpdateData ? employee : existing;
            await _employeeManager.updateEmployee(base.copyWith(
              deleted: mergedDeleted,
              deletedTime: mergedDeleteTime,
            ));
          }
        }
        // 热更新已运行 Agent 的权限配置
        if (existing != null &&
            (employee.permissionConfig != existing.permissionConfig)) {
          _agentManager.reloadPermissionConfig(employee.uuid, employee);
        }
      }
      return {'count': employees.length};
    });

    rpcServer.register(HostRpcConfig.methodSyncSessions, (params) async {
      final request = SyncSessionsRequest.fromMap(params);
      final sessions = request.sessions
          .map((s) => AiEmployeeSessionEntity.fromMap(s))
          .toList();
      for (final session in sessions) {
        final existing = await _sessionManager.getSession(session.employeeId);
        if (existing == null) {
          if (session.deleted != 1) {
            await _sessionManager.save(session);
          }
        } else {
          // 合并 deleteTime：取较大者决定 deleted 状态
          final (dt, d) = _mergeDeleteTime(
            existing.deleteTime, existing.deleted,
            session.deleteTime, session.deleted,
          );
          final shouldUpdateData = session.updateTime.isAfter(existing.updateTime);
          final shouldUpdateDelete = dt != existing.deleteTime || d != existing.deleted;
          if (shouldUpdateData || shouldUpdateDelete) {
            await _sessionManager.save(
              (shouldUpdateData ? session : existing).copyWith(
                deleted: d,
                deleteTime: dt,
              ),
            );
          }
        }
      }
      return {'count': sessions.length};
    });

    rpcServer.register(HostRpcConfig.methodSyncMessages, (params) async {
      final request = SyncMessagesRequest.fromMap(params);
      final messages = request.messages
          .map((m) => ChatMessage.fromJson(m))
          .toList();
      await _messageStoreService.addMessages(messages);
      return {'count': messages.length};
    });

    // 设备管理方法
    rpcServer.register(HostRpcConfig.methodGetOnlineDevices, (params) async {
      return {'devices': []};
    });

    // 远程更新设备信息
    rpcServer.register(HostRpcConfig.methodUpdateDeviceInfo, (params) async {
      final deviceInfoMap = params['deviceInfo'] as Map<String, dynamic>?;
      if (deviceInfoMap == null) {
        throw Exception('deviceInfo is required');
      }
      final deviceInfo = DeviceInfoConfig.fromMap(deviceInfoMap);
      await _configManager.updateDeviceInfo(deviceInfo);
      return {'success': true};
    });
  }

  /// 合并两端的 deleteTime：取较大者决定 deleted 状态
  static (DateTime?, int) _mergeDeleteTime(
    DateTime? localDT,
    int localD,
    DateTime? remoteDT,
    int remoteD,
  ) {
    if (localDT == null && remoteDT == null) return (null, 0);
    if (localDT == null) return (remoteDT, remoteD);
    if (remoteDT == null) return (localDT, localD);
    return localDT.isAfter(remoteDT) ? (localDT, localD) : (remoteDT, remoteD);
  }
}
