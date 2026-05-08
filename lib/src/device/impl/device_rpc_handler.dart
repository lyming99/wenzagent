import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../agent/agent_state.dart';
import '../../agent/entity/entity.dart';
import '../../agent/rpc/agent_rpc_config.dart';
import '../../entity/host_rpc_request.dart';
import '../../host/host_rpc_methods.dart';
import '../../persistence/persistence.dart';
import '../../rpc/remote_call_server.dart';
import '../../service/service.dart';
import '../../utils/logger.dart';
import '../app_context.dart';
import 'data_sync_manager.dart';
import 'device_agent_manager.dart';
import 'device_config_manager.dart';
import 'file_transfer_token_manager.dart';
import '../../lan/impl/lan_host_service_impl.dart';
import '../../rpc/rpc_protocol.dart';
import 'device_connection_manager.dart';

/// RPC 方法注册器
///
/// 负责将所有 Agent 和 Host RPC 方法注册到 [RemoteCallServer]。
class DeviceRpcHandler {
  static final _log = Logger('DeviceRpcHandler');

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

  /// 从 [AppContext] 获取实例，不存在则回退到独立创建
  static DeviceRpcHandler getInstance(String deviceId) {
    final ctx = AppContext.get(deviceId);
    if (ctx != null) return ctx.rpcHandler;
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
    _log.debug('R_registerAgentMethods');
    // Agent 对话操作
    rpcServer.register(AgentRpcConfig.methodSendMessage, (params) async {
      final request = SendMessageRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);

      _log.debug('RPC sendMessage 接收到消息数据: ${request.messageData}');
      _log.debug('消息ID: ${request.messageData['id']}');

      final input = MessageInput.fromMap(request.messageData);
      _log.debug('MessageInput.id: ${input.id}');

      final messageId = await agent.sendMessage(input);
      _log.debug('Agent返回的消息ID: $messageId');

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
      _log.debug('RPC getMaxSeq');
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

    // 清除清空水位线标记
    rpcServer.register(AgentRpcConfig.methodClearClearSeq, (params) async {
      final request = ClearClearSeqRequest.fromMap(params);
      final watermarkStore = SyncWatermarkStore(deviceId: _deviceId);
      watermarkStore.clearClearSeq(request.employeeId, deviceId: _deviceId);
      return {'success': true};
    });

    // 标记消息为已读
    rpcServer.register(AgentRpcConfig.methodMarkMessagesAsRead, (params) async {
      final request = MarkMessagesAsReadRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.markMessagesAsRead(
        deviceId: request.readerDeviceId,
        employeeId: request.employeeId,
        messageIds: request.messageIds,
      );
      return {'success': true};
    });

    // 标记所有消息为已读
    rpcServer.register(AgentRpcConfig.methodMarkAllMessagesAsRead, (params) async {
      final request = MarkAllMessagesAsReadRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);

      // 1. Agent 内存记录已读状态 + 广播事件
      await agent.markMessagesAsRead(
        deviceId: request.readerDeviceId,
        employeeId: request.employeeId,
      );

      // 2. 更新本地 DB（messages + session_summary）
      final targetDeviceId = request.fromDeviceId ?? _deviceId;
      _messageStoreService.markAsReadInDb(targetDeviceId, request.employeeId);

      return {'success': true};
    });

    // 基于 seq 批量标记消息为已读
    rpcServer.register(AgentRpcConfig.methodMarkMessagesAsReadBySeq, (params) async {
      final request = MarkMessagesAsReadBySeqRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);

      // 1. Agent 内存记录已读状态 + 广播事件
      await agent.markMessagesAsReadBySeq(
        readerDeviceId: request.readerDeviceId,
        employeeId: request.employeeId,
        readSeq: request.readSeq,
      );

      // 2. 更新本地 DB（messages + session_summary）
      _messageStoreService.markAsReadBySeqInDb(_deviceId, request.employeeId, request.readSeq);

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

    // 获取会话摘要（未读计数 + 最新消息）
    rpcServer.register(AgentRpcConfig.methodGetSessionSummary, (params) async {
      final request = GetSessionSummaryRequest.fromMap(params);
      final summaryStore = SessionSummaryStore(deviceId: _deviceId);
      final summary = summaryStore.getSummary(request.employeeId, deviceId: _deviceId);
      return summary?.toMap() ?? {};
    });

    rpcServer.register(AgentRpcConfig.methodGetState, (params) async {
      final request = GetStateRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      return agent.getStateSnapshot().toMap();
    });

    rpcServer.register(AgentRpcConfig.methodGetTokenUsage, (params) async {
      final request = GetTokenUsageRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      // 优先内存，降级 Store
      final sessionUsage = await agent.getSessionTokenUsageAsync();
      return {
        'sessionUsage': sessionUsage.toMap(),
      };
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
          _log.info('methodSetProvider: Employee provider synced: provider=$newProvider, model=$newModel');
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

      final scope = request.scope != null
          ? PermissionApprovalScope.fromString(request.scope!)
          : PermissionApprovalScope.once;

      await agent.respondToPermission(
        request.requestId,
        decision,
        scope: scope,
        customPattern: request.customPattern,
      );
      return {};
    });

    // 确认管理方法
    rpcServer.register(AgentRpcConfig.methodGetPendingConfirm, (params) async {
      final request = GetPendingConfirmRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final confirmRequest = agent.getPendingConfirmRequest();
      return {'request': confirmRequest?.toMap()};
    });

    rpcServer.register(AgentRpcConfig.methodRespondConfirm, (params) async {
      final request = RespondConfirmRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.respondToConfirm(request.requestId, request.selectedOption);
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
      _log.debug('agentSetProject RPC: employeeId=${request.employeeId}, projectData=${request.projectData}');
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final projectData = request.projectData != null
          ? ProjectData.fromMap(request.projectData!)
          : null;
      _log.debug('agentSetProject: parsed projectUuid=${projectData?.projectUuid}, projectName=${projectData?.projectName}');
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
        _log.info('agentSetProject: Employee project synced: uuid=${employee.projectUuid} -> $projectUuid, name=${projectData?.projectName}');
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
      final path = params['path'] as String;
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
      final path = params['path'] as String;
      final dir = Directory(path);
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
          } catch (e) {
            _log.debug('listDirectory: stat failed for entry: $e');
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
      final path = params['path'] as String;
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
      final path = params['path'] as String;
      try {
        await Directory(path).create(recursive: true);
        return {'success': true};
      } catch (e) {
        return {'success': false, 'error': e.toString()};
      }
    });

    rpcServer.register(AgentRpcConfig.methodDeleteFile, (params) async {
      final path = params['path'] as String;
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
      final oldPath = params['oldPath'] as String;
      final newPath = params['newPath'] as String;
      try {
        final entity = File(oldPath);
        if (await entity.exists()) {
          await entity.rename(newPath);
          return {'success': true};
        }
        final dir = Directory(oldPath);
        if (await dir.exists()) {
          await dir.rename(newPath);
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

    // Todo Topic 管理
    rpcServer.register(AgentRpcConfig.methodGetCurrentTopics, (params) async {
      final request = GetCurrentTopicsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final topics = await agent.getCurrentTopics();
      return {'topics': topics};
    });

    rpcServer.register(AgentRpcConfig.methodGetPendingTopics, (params) async {
      final request = GetPendingTopicsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final topics = await agent.getPendingTopics();
      return {'topics': topics};
    });

    rpcServer.register(AgentRpcConfig.methodGetAllTopics, (params) async {
      final request = GetAllTopicsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final topics = await agent.getAllTopics();
      return {'topics': topics};
    });

    rpcServer.register(AgentRpcConfig.methodGetCompletedTopics, (params) async {
      final request = GetCompletedTopicsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final topics = await agent.getCompletedTopics(limit: request.limit);
      return {'topics': topics};
    });

    rpcServer.register(AgentRpcConfig.methodGetTodoStats, (params) async {
      final request = GetTodoStatsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      return await agent.getTodoStats();
    });

    // Todo 写操作
    rpcServer.register(AgentRpcConfig.methodUpdateTopicContent, (params) async {
      final request = UpdateTopicContentRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.updateTopicContent(request.topicId, title: request.title, description: request.description);
      return {'success': true};
    });

    rpcServer.register(AgentRpcConfig.methodDeleteTopic, (params) async {
      final request = DeleteTopicRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.deleteTopic(request.topicId);
      return {'success': true};
    });

    rpcServer.register(AgentRpcConfig.methodUpdateTopicStatus, (params) async {
      final request = UpdateTopicStatusRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.updateTopicStatus(request.topicId, request.status);
      return {'success': true};
    });

    rpcServer.register(AgentRpcConfig.methodReorderTopics, (params) async {
      final request = ReorderTopicsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.reorderTopics(request.topicIds);
      return {'success': true};
    });

    rpcServer.register(AgentRpcConfig.methodClearCompletedTopics, (params) async {
      final request = ClearCompletedTopicsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.clearCompletedTopics();
      return {'success': true};
    });

    // Todo TaskItem 管理
    rpcServer.register(AgentRpcConfig.methodGetTaskItemsByTopic, (params) async {
      final request = GetTaskItemsByTopicRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final tasks = await agent.getTaskItemsByTopic(request.topicId);
      return {'tasks': tasks};
    });

    rpcServer.register(AgentRpcConfig.methodUpdateTaskItemStatus, (params) async {
      final request = UpdateTaskItemStatusRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.updateTaskItemStatus(request.taskId, request.status);
      return {'success': true};
    });

    rpcServer.register(AgentRpcConfig.methodUpdateTaskItemContent, (params) async {
      final request = UpdateTaskItemContentRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.updateTaskItemContent(request.taskId, title: request.title, content: request.content);
      return {'success': true};
    });

    rpcServer.register(AgentRpcConfig.methodDeleteTaskItem, (params) async {
      final request = DeleteTaskItemRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.deleteTaskItem(request.taskId);
      return {'success': true};
    });

    rpcServer.register(AgentRpcConfig.methodReorderTaskItems, (params) async {
      final request = ReorderTaskItemsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.reorderTaskItems(request.taskItemIds);
      return {'success': true};
    });

    // Spec 管理
    rpcServer.register(AgentRpcConfig.methodGetActiveSpecs, (params) async {
      final request = GetActiveSpecsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final specs = await agent.getActiveSpecs();
      return {'specs': specs};
    });

    rpcServer.register(AgentRpcConfig.methodGetCompletedSpecs, (params) async {
      final request = GetCompletedSpecsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final specs = await agent.getCompletedSpecs(limit: request.limit);
      return {'specs': specs};
    });

    rpcServer.register(AgentRpcConfig.methodGetSpecStats, (params) async {
      final request = GetSpecStatsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      return await agent.getSpecStats();
    });

    // Spec 写操作
    rpcServer.register(AgentRpcConfig.methodUpdateSpecStatus, (params) async {
      final request = UpdateSpecStatusRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.updateSpecStatus(request.specId, request.status);
      return {'success': true};
    });

    rpcServer.register(AgentRpcConfig.methodUpdateSpecContent, (params) async {
      final request = UpdateSpecContentRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.updateSpecContent(request.specId, request.content);
      return {'success': true};
    });

    rpcServer.register(AgentRpcConfig.methodDeleteSpec, (params) async {
      final request = DeleteSpecRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.deleteSpec(request.specId);
      return {'success': true};
    });

    rpcServer.register(AgentRpcConfig.methodClearCompletedSpecs, (params) async {
      final request = ClearCompletedSpecsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.clearCompletedSpecs();
      return {'success': true};
    });

    rpcServer.register(AgentRpcConfig.methodReorderSpecs, (params) async {
      final request = ReorderSpecsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.reorderSpecs(request.specIds);
      return {'success': true};
    });

    // ===== 远程文件读写 =====

    rpcServer.register(AgentRpcConfig.methodReadFile, (params) async {
      final request = ReadFileRequest.fromMap(params);
      final path = request.path;

      try {
        final file = File(path);
        if (!await file.exists()) {
          return {'success': false, 'error': '文件不存在: $path'};
        }

        final stat = await file.stat();
        final fileSize = stat.size;

        final offset = request.offset;
        final limit = request.limit;

        // 分块读取模式：指定了 offset 或 limit 时，按范围读取，不限制大小
        if (offset != null || limit != null) {
          final start = offset?.clamp(0, fileSize) ?? 0;
          final readLen = limit ?? (fileSize - start);
          final end = (start + readLen).clamp(start, fileSize);

          // 使用 RandomAccessFile 按范围读取，避免加载整个文件到内存
          final raf = await file.open();
          try {
            await raf.setPosition(start);
            final bytes = await raf.read(end - start);
            final contentBase64 = base64Encode(bytes);
            return {
              'success': true,
              'contentBase64': contentBase64,
              'fileSize': fileSize,
              'offset': start,
              'length': bytes.length,
              'truncated': (start + bytes.length) < fileSize,
            };
          } finally {
            await raf.close();
          }
        }

        // 整体读取模式：受 maxBytes 限制（默认 200KB）
        final maxBytes = request.maxBytes ?? 200 * 1024;
        if (fileSize > maxBytes) {
          return {
            'success': false,
            'error': '文件过大: ${_formatFileSize(fileSize)}，超过限制: ${_formatFileSize(maxBytes)}',
            'fileSize': fileSize,
          };
        }

        final bytes = await file.readAsBytes();
        final contentBase64 = base64Encode(bytes);

        return {
          'success': true,
          'contentBase64': contentBase64,
          'fileSize': fileSize,
          'offset': 0,
          'length': bytes.length,
          'truncated': false,
        };
      } catch (e) {
        return {'success': false, 'error': '读取文件失败: $e'};
      }
    });

    rpcServer.register(AgentRpcConfig.methodWriteFile, (params) async {
      final request = WriteFileRequest.fromMap(params);
      final path = request.path;

      try {
        final bytes = base64Decode(request.contentBase64);

        // 确保父目录存在
        final file = File(path);
        final parentDir = file.parent;
        if (!await parentDir.exists()) {
          await parentDir.create(recursive: true);
        }

        final sink = file.openWrite(mode: request.append ? FileMode.append : FileMode.write);
        sink.add(bytes);
        await sink.close();

        return {
          'success': true,
          'bytesWritten': bytes.length,
        };
      } catch (e) {
        return {'success': false, 'error': '写入文件失败: $e'};
      }
    });

    rpcServer.register(AgentRpcConfig.methodDownloadFile, (params) async {
      final request = DownloadFileRequest.fromMap(params);
      final path = request.path;

      try {
        final file = File(path);
        if (!await file.exists()) {
          return {'success': false, 'error': '文件不存在: $path'};
        }

        final stat = await file.stat();
        final fileName = path.split(Platform.pathSeparator).last;

        // 生成临时 Token
        final transferToken = FileTransferTokenManager.generateDownloadToken(
          deviceId: _deviceId,
          filePath: path,
        );

        // 构建 URL（使用 Host IP 和端口）
        // 附加本机 HTTP 服务地址，供调用方拼接完整下载 URL
        return {
          'success': true,
          'token': transferToken.token,
          'expiresIn': 300,
          'fileSize': stat.size,
          'fileName': fileName,
          'hostIp': LanHostServiceImpl.instance.localIp ?? '',
          'hostPort': LanHostServiceImpl.instance.port,
        };
      } catch (e) {
        return {'success': false, 'error': '生成下载链接失败: $e'};
      }
    });

    rpcServer.register(AgentRpcConfig.methodUploadFile, (params) async {
      final request = UploadFileRequest.fromMap(params);
      final path = request.path;

      try {
        // 生成临时 Token
        final transferToken = FileTransferTokenManager.generateUploadToken(
          deviceId: _deviceId,
          filePath: path,
          overwrite: request.overwrite,
        );

        // 附加本机 HTTP 服务地址，供调用方拼接完整上传 URL
        return {
          'success': true,
          'token': transferToken.token,
          'expiresIn': 300,
          'hostIp': LanHostServiceImpl.instance.localIp ?? '',
          'hostPort': LanHostServiceImpl.instance.port,
        };
      } catch (e) {
        return {'success': false, 'error': '生成上传链接失败: $e'};
      }
    });

    // 文件操作追踪
    rpcServer.register(AgentRpcConfig.methodGetFileOperations, (params) async {
      final request = GetFileOperationsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final operations = await agent.getFileOperations(limit: request.limit, offset: request.offset);
      return {'operations': operations};
    });

    rpcServer.register(AgentRpcConfig.methodGetFileOperationsByMessage, (params) async {
      final request = GetFileOperationsByMessageRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      final operations = await agent.getFileOperationsByMessage(request.messageId);
      return {'operations': operations};
    });

    rpcServer.register(AgentRpcConfig.methodClearFileOperations, (params) async {
      final request = ClearFileOperationsRequest.fromMap(params);
      final agent = await _agentManager.ensureLocalAgentForRpc(request.employeeId);
      await agent.clearFileOperations();
      return {'success': true};
    });

    // ===== 流式文件读取（二进制 WebSocket 传输） =====

    rpcServer.registerStream(
      AgentRpcConfig.methodReadFileStream,
      (params) async* {
        final path = params['path'] as String;
        final chunkSize = params['chunkSize'] as int? ?? 64 * 1024;
        final requestId = params['_requestId'] as String? ?? '';
        final toDeviceId = params['_fromDeviceId'] as String? ?? '';
        // ignore: avoid_print
        print('[RPC-HANDLER] methodReadFileStream: path=$path, requestId=$requestId, toDeviceId=$toDeviceId, _deviceId=$_deviceId');

        final file = File(path);
        if (!await file.exists()) {
          throw Exception('文件不存在: $path');
        }

        final fileSize = await file.length();

        // 获取已连接的 LanClient（通过 DeviceConnectionManager 单例）
        final connMgr = DeviceConnectionManager.getInstance(_deviceId);
        final lanClient = connMgr.lanClient;
        // ignore: avoid_print
        print('[RPC-HANDLER] lanClient=${lanClient != null ? "exists" : "null"}, isConnected=${lanClient?.isConnected}');
        if (lanClient == null || !lanClient.isConnected) {
          throw Exception('LanClient 未连接，无法发送二进制数据');
        }

        final raf = await file.open();

        try {
          int offset = 0;
          while (offset < fileSize) {
            await raf.setPosition(offset);
            final remaining = fileSize - offset;
            final readLen = remaining < chunkSize ? remaining : chunkSize;
            final bytes = await raf.read(readLen);
            final isLast = (offset + bytes.length) >= fileSize;

            // 构造二进制帧并发送
            final frame = _buildBinaryFrame(
              toDeviceId: toDeviceId,
              requestId: requestId,
              payload: bytes,
              isLast: isLast,
            );
            // ignore: avoid_print
            print('[RPC-HANDLER] sending binary frame: to=$toDeviceId, req=$requestId, len=${bytes.length}, last=$isLast');
            lanClient.sendBinaryMessage(frame);

            offset += bytes.length;

            // yield 空事件表示已通过二进制通道发送了一个 chunk
            yield RpcStreamEvent.chunk('');
          }
        } finally {
          await raf.close();
        }

        yield RpcStreamEvent.done({
          'fileSize': fileSize,
          'fileName': path.split(Platform.pathSeparator).last,
        });
      },
    );
  }

  /// 格式化文件大小
  static String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  void _registerHostMethods(RemoteCallServer rpcServer) {
    // 员工管理方法
    rpcServer.register(HostRpcConfig.methodGetEmployees, (params) async {
      final request = GetEmployeesRequest.fromMap(params);
      final includeDeleted = params['includeDeleted'] as bool? ?? false;
      final employees = await _employeeManager.getEmployees(
        keyword: request.keyword,
        status: request.status,
        includeDeleted: includeDeleted,
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
          final mergeResult = StoreMergeUtil.mergeDeleteState(
            localDeleteTime: existing.deletedTime,
            localDeleted: existing.deleted,
            remoteDeleteTime: employee.deletedTime,
            remoteDeleted: employee.deleted,
            localUpdateTime: existing.updateTime,
            remoteUpdateTime: employee.updateTime,
          );
          final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
              existing.updateTime, employee.updateTime);
          final shouldUpdateDelete =
              mergeResult.mergedDeleteTime != existing.deletedTime ||
                  mergeResult.mergedDeleted != existing.deleted;

          if (shouldUpdateData || shouldUpdateDelete) {
            final base = shouldUpdateData ? employee : existing;
            await _employeeManager.updateEmployee(base.copyWith(
              deleted: mergeResult.mergedDeleted,
              deletedTime: mergeResult.mergedDeleteTime,
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
          // 合并：deleteTime 独立比较，数据按 updateTime 合并
          final mergeResult = StoreMergeUtil.mergeDeleteState(
            localDeleteTime: existing.deleteTime,
            localDeleted: existing.deleted,
            remoteDeleteTime: session.deleteTime,
            remoteDeleted: session.deleted,
            localUpdateTime: existing.updateTime,
            remoteUpdateTime: session.updateTime,
          );
          final shouldUpdateData = StoreMergeUtil.shouldUpdateData(
              existing.updateTime, session.updateTime);
          final shouldUpdateDelete =
              mergeResult.mergedDeleteTime != existing.deleteTime ||
                  mergeResult.mergedDeleted != existing.deleted;

          if (shouldUpdateData || shouldUpdateDelete) {
            final base = shouldUpdateData ? session : existing;
            await _sessionManager.save(base.copyWith(
              deleted: mergeResult.mergedDeleted,
              deleteTime: mergeResult.mergedDeleteTime,
            ));
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
      // 消息携带各自的 deviceId，按设备分组写入
      final byDevice = <String, List<ChatMessage>>{};
      for (final msg in messages) {
        final did = msg.deviceId ?? '';
        (byDevice[did] ??= []).add(msg);
      }
      for (final entry in byDevice.entries) {
        await _messageStoreService.addMessages(entry.key, entry.value);
      }
      return {'count': messages.length};
    });

    // 获取所有会话摘要（仅返回本机 deviceId 的数据）
    rpcServer.register(HostRpcConfig.methodGetSessionSummaries, (params) async {
      final summaryStore = SessionSummaryStore(deviceId: _deviceId);
      final summaries = summaryStore.getAllSummaries(deviceId: _deviceId);
      return {'summaries': summaries.map((s) => s.toMap()).toList()};
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

  /// 构造二进制帧
  ///
  /// 帧格式：
  /// [0]    0x01 版本
  /// [1]    0x02 binaryChunk
  /// [2..5] toDeviceId 长度 (uint32 BE)
  /// [6..M] toDeviceId (UTF-8)
  /// [M+1..M+4] requestId 长度 (uint32 BE)
  /// [M+5..N] requestId (UTF-8)
  /// [N+1]  flags (bit0=lastChunk)
  /// [N+2..] 原始二进制数据
  static Uint8List _buildBinaryFrame({
    required String toDeviceId,
    required String requestId,
    required Uint8List payload,
    required bool isLast,
  }) {
    final toDeviceIdBytes = utf8.encode(toDeviceId);
    final requestIdBytes = utf8.encode(requestId);

    final builder = BytesBuilder();

    // version
    builder.addByte(0x01);
    // type
    builder.addByte(0x02);

    // toDeviceId
    final toDeviceIdLenData = ByteData(4)
      ..setUint32(0, toDeviceIdBytes.length);
    builder.add(toDeviceIdLenData.buffer.asUint8List());
    builder.add(toDeviceIdBytes);

    // requestId
    final requestIdLenData = ByteData(4)
      ..setUint32(0, requestIdBytes.length);
    builder.add(requestIdLenData.buffer.asUint8List());
    builder.add(requestIdBytes);

    // flags
    builder.addByte(isLast ? 0x01 : 0x00);

    // payload
    builder.add(payload);

    return builder.takeBytes();
  }
}
