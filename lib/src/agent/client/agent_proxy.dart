import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../agent_state.dart';
import '../entity/entity.dart';
import '../i_agent.dart';
import '../rpc/agent_rpc_util.dart';
import '../tool/agent_tool.dart';
import '../tracker/token_usage_tracker.dart';
import '../../persistence/persistence.dart';
import '../../utils/logger.dart';

part 'agent_proxy_remote_ops.dart';

/// RPC 调用回调类型
typedef RpcCall =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

/// Agent Proxy（纯 Dart）
///
/// 统一本地和远程调用入口，对上层透明。
///
/// 两种工作模式：
/// - 本地模式：直接调用 [IAgent] 实例
/// - 远程模式：通过 RPC 回调调用远程 Agent
class AgentProxy {
  static final _log = Logger('AgentProxy');

  /// 员工UUID
  final String employeeId;

  /// 设备ID
  final String deviceId;

  /// 是否为本地模式
  final bool isLocalMode;

  /// 本地 Agent 实例（本地模式使用）
  final IAgent? _localAgent;

  /// RPC 工具类（远程模式使用）
  AgentRpcUtil? _rpcUtil;

  /// 远程操作封装
  _RemoteOps? _remoteOps;

  /// 远程状态缓存
  final _RemoteStateCache _remoteCache = _RemoteStateCache();

  /// 更新远程缓存中的配置数据（供 CachedAgentProxy 事件处理调用）
  void updateRemoteCache({
    Map<String, dynamic>? providerConfig,
    String? projectUuid,
    Map<String, dynamic>? contextData,
  }) {
    if (providerConfig != null) {
      _remoteCache.providerConfig = providerConfig;
    } else if (providerConfig == null && _remoteCache.providerConfig != null) {
      // null 表示清除（仅在调用方显式传 null 时清除）
    }
    if (projectUuid != null) {
      _remoteCache.projectUuid = projectUuid;
    }
    if (contextData != null) {
      _remoteCache.contextData = contextData;
    }
  }

  /// 清除远程缓存中的指定配置项
  void clearRemoteCacheConfig(String configType) {
    switch (configType) {
      case 'provider':
        _remoteCache.providerConfig = null;
      case 'project':
        _remoteCache.projectUuid = null;
      case 'context':
        _remoteCache.contextData = null;
    }
  }

  /// 状态变更通知
  final StreamController<AgentStateSnapshot> _stateController =
      StreamController<AgentStateSnapshot>.broadcast();

  /// 事件通知（用于缓存层监听原始事件）
  final StreamController<AgentEvent> _eventController =
      StreamController<AgentEvent>.broadcast();

  /// 远程事件流订阅取消器
  StreamSubscription<AgentEvent>? _remoteEventSubscription;

  /// 待确认消息队列（存储已发送但未被查询确认的完整消息内容）
  final List<PendingMessage> _pendingMessageQueue = [];

  /// 创建本地模式 Proxy
  AgentProxy.local({
    required this.employeeId,
    required this.deviceId,
    required IAgent localAgent,
  }) : isLocalMode = true,
       _localAgent = localAgent;

  /// 创建远程模式 Proxy
  AgentProxy.remote({
    required this.employeeId,
    required this.deviceId,
    required RpcCall rpcCall,
    Stream<AgentEvent>? remoteEventStream,
  }) : isLocalMode = false,
       _localAgent = null {
    _rpcUtil = AgentRpcUtil(rpcCall);
    _remoteOps = _RemoteOps(
      rpcUtil: _rpcUtil!,
      employeeId: employeeId,
      remoteCache: _remoteCache,
      removeConfirmedMessages: _removeConfirmedMessages,
      eventController: _eventController,
      stateController: _stateController,
    );
    if (remoteEventStream != null) {
      _subscribeRemoteEvents(remoteEventStream);
    }
  }

  /// 状态变更流
  Stream<AgentStateSnapshot> get onStateChanged {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.onStateChanged;
    }
    return _stateController.stream;
  }

  /// 事件流（暴露原始事件，供CachedAgentProxy监听）
  Stream<AgentEvent> get onEvent {
    if (isLocalMode && _localAgent != null) {
      // 本地模式：直接返回 Agent 的事件流
      return _localAgent.onEvent;
    }
    return _eventController.stream;
  }

  /// 当前状态
  AgentStatus get status {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.status;
    }
    return _remoteCache.status;
  }

  /// 是否存活
  bool get isAlive {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.isAlive;
    }
    return _remoteCache.status != AgentStatus.disposed;
  }

  // ===== 对话操作 =====

  /// 发送消息
  Future<String> sendMessage(MessageInput input) async {
    _log.debug('sendMessage isLocalMode: $isLocalMode');

    // 关键：在客户端生成UUID，确保远程和本地ID一致
    final messageId = input.id ?? const Uuid().v4();
    _log.debug('消息ID: $messageId (${input.id != null ? "客户端提供" : "客户端生成"})');

    // 创建带有ID的input副本
    final inputWithId = input.id != null ? input : input.copyWith(id: messageId);
    _log.debug('inputWithId.id: ${inputWithId.id}');

    // 如果是客户端生成的ID，验证UUID格式
    // 如果是用户提供ID，不验证（允许自定义格式）
    if (input.id == null && !_isValidUUID(messageId)) {
      _log.warn('生成的消息ID不是有效的UUID格式: $messageId');
      // 但不抛出异常，继续使用
    }

    if (isLocalMode && _localAgent != null) {
      _log.info('调用本地Agent sendMessage');
      final returnedId = await _localAgent.sendMessage(inputWithId);

      // 验证本地Agent没有修改ID
      if (returnedId != messageId) {
        _log.error('严重错误：本地Agent修改了消息ID！期望: $messageId, 实际: $returnedId');
        // 记录错误但继续使用客户端生成的ID
      }

      // 将完整消息数据添加到待确认队列（使用客户端生成的messageId）
      final pendingMessage = _createPendingMessage(inputWithId, messageId);
      _pendingMessageQueue.add(pendingMessage);

      // 返回客户端生成的messageId，而不是Agent返回的ID
      return messageId;
    }

    _log.info('调用RPC sendMessage');
    // 将 MessageInput 转换为 Map 以便 RPC 传输
    final messageData = inputWithId.toMap();
    _log.debug('发送的消息数据: $messageData');
    _log.debug('消息数据中的ID: ${messageData['id']}');

    final request = SendMessageRequest(
      employeeId: employeeId,
      messageData: messageData,
    );
    final result = await _rpcUtil!.sendMessage(request);

    // 使用客户端生成的ID，而不是远程返回的ID
    // 远程服务器应该使用客户端提供的ID
    final returnedId = result['messageId'] as String? ?? '';
    _log.debug('远程返回的消息ID: $returnedId');

    if (returnedId.isNotEmpty && returnedId != messageId) {
      _log.error('严重错误：远程Agent修改了消息ID！期望: $messageId, 实际: $returnedId');
    }

    // 将完整消息数据添加到待确认队列
    final pendingMessage = _createPendingMessage(inputWithId, messageId);
    _pendingMessageQueue.add(pendingMessage);

    _log.debug('返回消息ID: $messageId');
    return messageId;
  }

  /// 验证UUID格式
  bool _isValidUUID(String uuid) {
    final uuidRegExp = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    return uuidRegExp.hasMatch(uuid);
  }

  /// 中断当前处理
  Future<void> interrupt() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.interrupt();
    }
    final request = InterruptRequest(employeeId: employeeId);
    await _rpcUtil!.interrupt(request);
  }

  /// 撤回消息
  Future<void> revokeMessage(String messageId) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.revokeMessage(messageId);
    }
    final request = RevokeMessageRequest(
      employeeId: employeeId,
      messageId: messageId,
    );
    await _rpcUtil!.revokeMessage(request);
  }

  /// 从内存中删除消息
  ///
  /// 仅适用于本地模式，从 Agent 的内存中删除消息
  Future<void> removeMessageFromMemory(String messageId) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.removeMessageFromMemory(messageId);
    }
    // 远程模式不支持此操作
    _log.warn('removeMessageFromMemory: 远程模式不支持此操作');
  }

  /// 获取当前权限请求（如果有，同步版本仅适用于本地模式）
  AgentPermissionRequest? getPendingPermissionRequest() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getPendingPermissionRequest();
    }
    return null;
  }

  /// 获取当前权限请求(异步版本,支持远程 RPC)
  Future<AgentPermissionRequest?> getPendingPermissionRequestAsync() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getPendingPermissionRequest();
    }
    final request = GetPendingPermissionRequest(employeeId: employeeId);
    final result = await _rpcUtil!.getPendingPermission(request);
    final requestData = result['request'] as Map<String, dynamic>?;
    if (requestData == null) return null;
    return AgentPermissionRequest.fromMap(requestData);
  }

  // ===== 确认管理 =====

  /// 获取当前确认请求（同步版本仅适用于本地模式）
  AgentConfirmRequest? getPendingConfirmRequest() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getPendingConfirmRequest();
    }
    return null;
  }

  /// 获取当前确认请求（异步版本，支持远程 RPC）
  Future<AgentConfirmRequest?> getPendingConfirmRequestAsync() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getPendingConfirmRequest();
    }
    final request = GetPendingConfirmRequest(employeeId: employeeId);
    final result = await _rpcUtil!.getPendingConfirm(request);
    final requestData = result['request'] as Map<String, dynamic>?;
    if (requestData == null) return null;
    return AgentConfirmRequest.fromMap(requestData);
  }

  /// 响应确认请求
  Future<void> respondToConfirm(String requestId, String selectedOption) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.respondToConfirm(requestId, selectedOption);
    }
    final request = RespondConfirmRequest(
      employeeId: employeeId,
      requestId: requestId,
      selectedOption: selectedOption,
    );
    await _rpcUtil!.respondConfirm(request);
  }

  // ===== 会话消息 =====

  /// 获取会话消息
  ///
  /// 返回当前 Agent 的会话消息列表
  Future<List<AgentMessage>> getSessionMessages() async {
    if (isLocalMode && _localAgent != null) {
      final messages = await _localAgent.getSessionMessages();
      // 根据返回的消息ID，从消息队列中移除
      _removeConfirmedMessages(messages.map((m) => m.toMap()).toList());
      return messages;
    }
    return _remoteOps!.getSessionMessages();
  }

  /// 根据用户消息计数获取会话消息
  ///
  /// 统计用户发送的消息数（role='user'），达到 [userMessageLimit] 条时停止，
  /// 返回该时间段内的所有消息（包括user和assistant）
  Future<List<AgentMessage>> getSessionMessagesByUserCount({
    int userMessageLimit = 20,
  }) async {
    if (isLocalMode && _localAgent != null) {
      final messages = await _localAgent.getSessionMessagesByUserCount(
        userMessageLimit: userMessageLimit,
      );
      // 根据返回的消息ID，从消息队列中移除
      _removeConfirmedMessages(messages.map((m) => m.toMap()).toList());
      return messages;
    }
    return _remoteOps!.getSessionMessagesByUserCount(
      userMessageLimit: userMessageLimit,
    );
  }

  /// 分页获取会话消息
  ///
  /// [pageSize] 每页数量，默认20条
  /// [offset] 偏移量，默认0
  Future<List<AgentMessage>> getSessionMessagesPaged({
    int pageSize = 20,
    int offset = 0,
  }) async {
    if (isLocalMode && _localAgent != null) {
      final messages = await _localAgent.getSessionMessagesPaged(
        pageSize: pageSize,
        offset: offset,
      );
      // 根据返回的消息ID，从消息队列中移除
      _removeConfirmedMessages(messages.map((m) => m.toMap()).toList());
      return messages;
    }
    return _remoteOps!.getSessionMessagesPaged(
      pageSize: pageSize,
      offset: offset,
    );
  }

  /// 获取未接收消息
  ///
  /// 查询指定设备的未接收消息（本机deviceId，而非proxy的deviceId）
  ///
  /// [receiverDeviceId] 接收设备的ID（本机设备ID）
  /// [offset] 偏移量（跳过的消息数），用于分页，默认0
  /// [limit] 每批数量限制，用于分页，默认20条
  Future<List<AgentMessage>> getUnreceivedMessages({
    required String receiverDeviceId,
    int offset = 0,
    int limit = 20,
  }) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getUnreceivedMessages(
        receiverDeviceId: receiverDeviceId,
        offset: offset,
        limit: limit,
      );
    }
    return _remoteOps!.getUnreceivedMessages(
      receiverDeviceId: receiverDeviceId,
      offset: offset,
      limit: limit,
    );
  }

  /// 标记消息为已接收
  ///
  /// 更新消息接收状态到服务端，后续查询不会返回已接收消息（除非状态更新）
  ///
  /// [receiverDeviceId] 接收设备的ID（本机设备ID）
  /// [messageReceiveList] 消息接收列表（包含消息ID和更新时间）
  Future<void> markMessagesAsReceived({
    required String receiverDeviceId,
    required List<MessageReceiveInfo> messageReceiveList,
  }) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.markMessagesAsReceived(
        receiverDeviceId: receiverDeviceId,
        messageReceiveList: messageReceiveList,
      );
    }
    return _remoteOps!.markMessagesAsReceived(
      receiverDeviceId: receiverDeviceId,
      messageReceiveList: messageReceiveList,
    );
  }

  /// 增量拉取消息（基于 LSN）
  ///
  /// 客户端通过 lastSeq 获取 seq > lastSeq 的消息
  Future<List<AgentMessage>> getMessagesAfterSeq({
    int lastSeq = 0,
    int limit = 20,
  }) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getMessagesAfterSeq(
        employeeId: employeeId,
        lastSeq: lastSeq,
        limit: limit,
      );
    }
    return _remoteOps!.getMessagesAfterSeq(
      lastSeq: lastSeq,
      limit: limit,
    );
  }

  /// 获取会话的最大 seq
  Future<int> getMaxSeq() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getMaxSeq(employeeId: employeeId);
    }
    return _remoteOps!.getMaxSeq();
  }

  /// 获取会话的最小 seq
  ///
  /// 用于客户端判断远程最早保留消息的位置，本地 seq < minSeq 的消息可安全删除
  Future<int> getMinSeq() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getMinSeq(employeeId: employeeId);
    }
    return _remoteOps!.getMinSeq();
  }

  /// 获取清空水位线
  ///
  /// 查询服务端是否设置了 clearSeq，如果 > 0，
  /// 客户端应删除本地 seq < clearSeq 的所有消息。
  Future<int> getClearSeq() async {
    if (isLocalMode && _localAgent != null) {
      // 本地模式：从 SyncWatermarkStore 读取
      return 0; // 本地模式不需要此机制，清空事件通过内存事件直接传递
    }
    return _remoteOps!.getClearSeq();
  }

  /// 标记消息为已读
  ///
  /// 当用户打开会话查看消息时，通知 Agent 消息已读
  Future<void> markMessagesAsRead({
    required String readerDeviceId,
    List<String>? messageIds,
  }) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.markMessagesAsRead(
        deviceId: readerDeviceId,
        employeeId: employeeId,
        messageIds: messageIds,
      );
    }
    return _remoteOps!.markMessagesAsRead(
      readerDeviceId: readerDeviceId,
      messageIds: messageIds,
    );
  }

  /// 标记所有消息为已读
  Future<void> markAllMessagesAsRead(String deviceId) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.markMessagesAsRead(
        deviceId: deviceId,
        employeeId: employeeId,
      );
    }
    return _remoteOps!.markAllMessagesAsRead(
      readerDeviceId: deviceId,
      fromDeviceId: deviceId,
    );
  }

  /// 基于 seq 批量标记消息为已读
  Future<void> markMessagesAsReadBySeq({
    required String readerDeviceId,
    required int readSeq,
  }) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.markMessagesAsReadBySeq(
        readerDeviceId: readerDeviceId,
        employeeId: employeeId,
        readSeq: readSeq,
      );
    }
    return _remoteOps!.markMessagesAsReadBySeq(
      readerDeviceId: readerDeviceId,
      readSeq: readSeq,
    );
  }

  /// 查询消息已读状态
  ///
  /// 设备重新打开时从 Agent 查询哪些消息已读
  Future<MessagesReadStatusResult> getMessagesReadStatus({
    required String deviceId,
  }) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getMessagesReadStatus(
        deviceId: deviceId,
        employeeId: employeeId,
      );
    }
    return _remoteOps!.getMessagesReadStatus(deviceId: deviceId);
  }

  /// 获取会话摘要（未读计数 + 最新消息）
  Future<Map<String, dynamic>?> getSessionSummary() async {
    if (isLocalMode && _localAgent != null) {
      final summaryStore = SessionSummaryStore(deviceId: deviceId);
      final summary = summaryStore.getSummary(employeeId, deviceId: deviceId);
      return summary?.toMap();
    }
    return _remoteOps!.getSessionSummary();
  }

  /// 清空当前会话
  Future<void> clearCurrentSession() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.clearCurrentSession();
    }
    return _remoteOps!.clearCurrentSession();
  }

  // ===== 上下文管理 =====

  Future<void> setContext(Map<String, dynamic> contextData) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.setContext(contextData);
    }
    final request = SetContextRequest(
      employeeId: employeeId,
      contextData: contextData,
    );
    await _rpcUtil!.setContext(request);
  }

  Map<String, dynamic>? getCurrentContext() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getCurrentContext();
    }
    return _remoteCache.contextData;
  }

  // ===== 模型管理 =====

  Future<void> setProvider(ProviderConfig providerConfig) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.setProvider(providerConfig);
    }
    final request = SetProviderRequest(
      employeeId: employeeId,
      providerConfig: providerConfig.toMap(),
    );
    await _rpcUtil!.setProvider(request);
    _remoteCache.providerConfig = providerConfig.toMap();
  }

  ProviderConfig? getProviderConfig() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getProviderConfig();
    }
    final configMap = _remoteCache.providerConfig;
    return configMap != null ? ProviderConfig.fromMap(configMap) : null;
  }

  /// 获取提供者配置（异步版本，支持远程 RPC）
  Future<ProviderConfig?> getProviderConfigAsync() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getProviderConfig();
    }
    return _remoteOps!.getProviderConfigAsync();
  }

  // ===== 技能管理 =====

  /// 设置技能配置
  Future<void> setSkills(List<Map<String, dynamic>> skillMaps) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.setSkills(skillMaps);
    }
    final request = SetSkillsRequest(
      employeeId: employeeId,
      skills: skillMaps,
    );
    await _rpcUtil!.setSkills(request);
    _remoteCache.skillsConfig = skillMaps;
  }

  /// 获取技能配置
  List<Map<String, dynamic>> getSkillsConfig() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getSkillsConfig();
    }
    return _remoteCache.skillsConfig ?? [];
  }

  /// 获取技能配置（异步版本，支持远程 RPC）
  Future<List<Map<String, dynamic>>> getSkillsConfigAsync() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getSkillsConfig();
    }
    return _remoteOps!.getSkillsConfigAsync();
  }

  // ===== MCP 管理 =====

  /// 设置 MCP 服务器配置
  Future<void> setMcpConfigs(List<Map<String, dynamic>> mcpConfigMaps) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.setMcpConfigs(mcpConfigMaps);
    }
    final request = SetMcpConfigsRequest(
      employeeId: employeeId,
      mcpConfigs: mcpConfigMaps,
    );
    await _rpcUtil!.setMcpConfigs(request);
    _remoteCache.mcpConfigs = mcpConfigMaps;
  }

  /// 获取 MCP 服务器配置
  List<Map<String, dynamic>> getMcpConfigs() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getMcpConfigs();
    }
    return _remoteCache.mcpConfigs ?? [];
  }

  /// 获取 MCP 服务器配置（异步版本，支持远程 RPC）
  Future<List<Map<String, dynamic>>> getMcpConfigsAsync() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getMcpConfigs();
    }
    return _remoteOps!.getMcpConfigsAsync();
  }

  // ===== 项目管理 =====

  Future<void> setProject(ProjectData? projectData) async {
    _log.info('setProject called: employeeId=$employeeId, projectUuid=${projectData?.projectUuid}, projectName=${projectData?.projectName}, isLocalMode=$isLocalMode');
    if (isLocalMode && _localAgent != null) {
      return _localAgent.setProject(projectData);
    }
    final request = SetProjectRequest(
      employeeId: employeeId,
      projectData: projectData?.toMap(),
    );
    await _rpcUtil!.setProject(request);
    _remoteCache.projectUuid = projectData?.projectUuid;
    _log.info('setProject completed: cached projectUuid=${_remoteCache.projectUuid}');
  }

  String? getCurrentProjectUuid() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getCurrentProjectUuid();
    }
    return _remoteCache.projectUuid;
  }

  /// 获取当前项目UUID（异步版本，支持远程 RPC）
  Future<String?> getCurrentProjectUuidAsync() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getCurrentProjectUuid();
    }
    return _remoteOps!.getCurrentProjectUuidAsync();
  }

  /// 检查路径是否存在于目标设备上（异步版本，支持远程 RPC）
  ///
  /// [path] 文件系统绝对路径
  Future<PathExistsResult> checkPathExists(String path) async {
    if (isLocalMode) {
      final dir = await Directory(path).exists();
      final file = !dir ? await File(path).exists() : false;
      return PathExistsResult(exists: dir || file, isDirectory: dir);
    }
    return _remoteOps!.checkPathExists(path);
  }

  /// 列出目录内容
  ///
  /// [path] 目录路径
  Future<DirectoryListingResult> listDirectory(String path) async {
    if (isLocalMode) {
      final dir = Directory(path);
      if (!await dir.exists()) {
        return DirectoryListingResult(items: [], error: '目录不存在');
      }
      final items = <DirectoryItem>[];
      try {
        await for (final entity in dir.list(recursive: false, followLinks: false)) {
          try {
            final stat = await entity.stat();
            final entityPath = entity.path;
            final entityName = entityPath.split(Platform.pathSeparator).last;
            if (entityName.isEmpty) continue;
            items.add(DirectoryItem(
              name: entityName,
              path: entityPath,
              isDirectory: entity is Directory,
              size: stat.size,
              modified: stat.modified.toIso8601String(),
            ));
          } catch (e) {
            _log.debug('failed to stat directory entry, skipping: $e');
            continue;
          }
        }
        // 排序：文件夹在前，文件在后，按名称排序
        items.sort((a, b) {
          if (a.isDirectory && !b.isDirectory) return -1;
          if (!a.isDirectory && b.isDirectory) return 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
        return DirectoryListingResult(items: items);
      } catch (e) {
        return DirectoryListingResult(items: [], error: e.toString());
      }
    }
    return _remoteOps!.listDirectory(path);
  }

  /// 获取文件/目录信息
  ///
  /// [path] 文件路径
  Future<FileInfoResult> getFileInfo(String path) async {
    if (isLocalMode) {
      final file = File(path);
      if (await file.exists()) {
        final stat = await file.stat();
        final name = path.split(Platform.pathSeparator).last;
        return FileInfoResult(
          exists: true,
          name: name,
          path: path,
          isDirectory: false,
          size: stat.size,
          modified: stat.modified.toIso8601String(),
        );
      }
      final dir = Directory(path);
      if (await dir.exists()) {
        final stat = await dir.stat();
        final name = path.split(Platform.pathSeparator).last;
        return FileInfoResult(
          exists: true,
          name: name,
          path: path,
          isDirectory: true,
          size: stat.size,
          modified: stat.modified.toIso8601String(),
        );
      }
      return const FileInfoResult(exists: false);
    }
    return _remoteOps!.getFileInfo(path);
  }

  /// 创建目录
  ///
  /// [path] 目录路径
  Future<FileOpResult> createDirectory(String path) async {
    if (isLocalMode) {
      try {
        await Directory(path).create(recursive: true);
        return const FileOpResult(success: true);
      } catch (e) {
        return FileOpResult(success: false, error: e.toString());
      }
    }
    return _remoteOps!.createDirectory(path);
  }

  /// 删除文件/目录
  ///
  /// [path] 文件/目录路径
  Future<FileOpResult> deleteFile(String path) async {
    if (isLocalMode) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          return const FileOpResult(success: true);
        }
        final dir = Directory(path);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
          return const FileOpResult(success: true);
        }
        return const FileOpResult(success: false, error: '路径不存在');
      } catch (e) {
        return FileOpResult(success: false, error: e.toString());
      }
    }
    return _remoteOps!.deleteFile(path);
  }

  /// 重命名/移动文件
  Future<FileOpResult> renameFile(String oldPath, String newPath) async {
    if (isLocalMode) {
      try {
        final entity = File(oldPath);
        if (await entity.exists()) {
          await entity.rename(newPath);
          return const FileOpResult(success: true);
        }
        final dir = Directory(oldPath);
        if (await dir.exists()) {
          await dir.rename(newPath);
          return const FileOpResult(success: true);
        }
        return const FileOpResult(success: false, error: '路径不存在');
      } catch (e) {
        return FileOpResult(success: false, error: e.toString());
      }
    }
    return _remoteOps!.renameFile(oldPath, newPath);
  }

  // ===== 工具管理 =====

  void registerTool(AgentTool tool) {
    if (isLocalMode && _localAgent != null) {
      _localAgent.registerTool(tool);
    }
  }

  void registerTools(List<AgentTool> tools) {
    if (isLocalMode && _localAgent != null) {
      _localAgent.registerTools(tools);
    }
  }

  void unregisterTool(String name) {
    if (isLocalMode && _localAgent != null) {
      _localAgent.unregisterTool(name);
    }
  }

  List<Map<String, dynamic>> getRegisteredTools() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getRegisteredTools();
    }
    return [];
  }

  // ===== 权限管理 =====

  Future<void> respondToPermission(
    String requestId,
    PermissionDecision decision, {
    PermissionApprovalScope scope = PermissionApprovalScope.once,
    String? customPattern,
  }) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.respondToPermission(requestId, decision,
          scope: scope, customPattern: customPattern);
    }
    final request = RespondPermissionRequest(
      employeeId: employeeId,
      requestId: requestId,
      decision: decision.name,
      scope: scope.name,
      customPattern: customPattern,
    );
    await _rpcUtil!.respondPermission(request);
  }

  // ===== 状态查询 =====

  AgentStateSnapshot getStateSnapshot() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getStateSnapshot();
    }
    return _remoteCache.snapshot ?? AgentStateSnapshot.idle();
  }

  /// 获取当前状态快照（异步版本，支持远程 RPC）
  Future<AgentStateSnapshot> getStateSnapshotAsync() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getStateSnapshot();
    }
    return _remoteOps!.getStateSnapshotAsync();
  }

  /// 获取正在调用的工具 callId 列表
  List<String> getCallingToolIds() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getCallingToolIds();
    }
    return [];
  }

  /// 获取正在调用的工具 callId 列表（异步版本，支持远程 RPC）
  Future<List<String>> getCallingToolIdsAsync() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getCallingToolIds();
    }
    final request = GetCallingToolIdsRequest(employeeId: employeeId);
    final result = await _rpcUtil!.getCallingToolIds(request);
    return (result['callingToolIds'] as List?)?.cast<String>() ?? [];
  }

  // ===== Todo 管理 =====

  /// 获取当前待办主题
  Future<List<Map<String, dynamic>>> getCurrentTopics() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.getCurrentTopics();
    }
    return _remoteOps!.getCurrentTopics();
  }

  /// 获取未完成待办主题
  Future<List<Map<String, dynamic>>> getPendingTopics() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.getPendingTopics();
    }
    return _remoteOps!.getPendingTopics();
  }

  /// 获取所有待办主题
  Future<List<Map<String, dynamic>>> getAllTopics() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.getAllTopics();
    }
    return _remoteOps!.getAllTopics();
  }

  /// 获取已完成主题
  Future<List<Map<String, dynamic>>> getCompletedTopics({int limit = 50}) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.getCompletedTopics(limit: limit);
    }
    return _remoteOps!.getCompletedTopics(limit: limit);
  }

  /// 获取待办统计信息
  Future<Map<String, dynamic>> getTodoStats() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.getTodoStats();
    }
    return _remoteOps!.getTodoStats();
  }

  // ===== Todo 写操作 =====

  /// 更新主题内容
  Future<void> updateTopicContent(String topicId, {String? title, String? description}) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.updateTopicContent(topicId, title: title, description: description);
    }
    return _remoteOps!.updateTopicContent(topicId, title: title, description: description);
  }

  /// 删除主题
  Future<void> deleteTopic(String topicId) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.deleteTopic(topicId);
    }
    return _remoteOps!.deleteTopic(topicId);
  }

  /// 更新主题状态
  Future<void> updateTopicStatus(String topicId, String status) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.updateTopicStatus(topicId, status);
    }
    return _remoteOps!.updateTopicStatus(topicId, status);
  }

  /// 批量更新主题排序
  Future<void> reorderTopics(List<String> topicIds) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.reorderTopics(topicIds);
    }
    return _remoteOps!.reorderTopics(topicIds);
  }

  /// 清除已完成主题
  Future<void> clearCompletedTopics() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.clearCompletedTopics();
    }
    return _remoteOps!.clearCompletedTopics();
  }

  /// 获取主题下的任务子项
  Future<List<Map<String, dynamic>>> getTaskItemsByTopic(String topicId) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.getTaskItemsByTopic(topicId);
    }
    return _remoteOps!.getTaskItemsByTopic(topicId);
  }

  /// 更新任务子项状态
  Future<void> updateTaskItemStatus(String taskId, String status) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.updateTaskItemStatus(taskId, status);
    }
    return _remoteOps!.updateTaskItemStatus(taskId, status);
  }

  /// 更新任务子项内容
  Future<void> updateTaskItemContent(String taskId, {String? title, String? content}) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.updateTaskItemContent(taskId, title: title, content: content);
    }
    return _remoteOps!.updateTaskItemContent(taskId, title: title, content: content);
  }

  /// 删除任务子项
  Future<void> deleteTaskItem(String taskId) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.deleteTaskItem(taskId);
    }
    return _remoteOps!.deleteTaskItem(taskId);
  }

  /// 批量更新任务子项排序
  Future<void> reorderTaskItems(List<String> taskItemIds) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.reorderTaskItems(taskItemIds);
    }
    return _remoteOps!.reorderTaskItems(taskItemIds);
  }

  // ===== Spec 管理 =====

  /// 获取活跃 spec 项
  Future<List<Map<String, dynamic>>> getActiveSpecs() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.getActiveSpecs();
    }
    return _remoteOps!.getActiveSpecs();
  }

  /// 获取已完成 spec 项
  Future<List<Map<String, dynamic>>> getCompletedSpecs({int limit = 50}) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.getCompletedSpecs(limit: limit);
    }
    return _remoteOps!.getCompletedSpecs(limit: limit);
  }

  /// 获取 spec 统计信息
  Future<Map<String, dynamic>> getSpecStats() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.getSpecStats();
    }
    return _remoteOps!.getSpecStats();
  }

  // ===== Spec 写操作 =====

  /// 更新 spec 状态
  Future<void> updateSpecStatus(String specId, String status) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.updateSpecStatus(specId, status);
    }
    return _remoteOps!.updateSpecStatus(specId, status);
  }

  /// 更新 spec 内容
  Future<void> updateSpecContent(String specId, String content) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.updateSpecContent(specId, content);
    }
    return _remoteOps!.updateSpecContent(specId, content);
  }

  /// 删除 spec 项
  Future<void> deleteSpec(String specId) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.deleteSpec(specId);
    }
    return _remoteOps!.deleteSpec(specId);
  }

  /// 清除所有已完成 spec
  Future<void> clearCompletedSpecs() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.clearCompletedSpecs();
    }
    return _remoteOps!.clearCompletedSpecs();
  }

  /// 批量更新 spec 排序
  Future<void> reorderSpecs(List<String> specIds) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent!.reorderSpecs(specIds);
    }
    return _remoteOps!.reorderSpecs(specIds);
  }

  // ===== 文件操作追踪 =====

  /// 获取文件操作记录
  Future<List<Map<String, dynamic>>> getFileOperations({
    int limit = 100,
    int offset = 0,
  }) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getFileOperations(limit: limit, offset: offset);
    }
    return _remoteOps!.getFileOperations(limit: limit, offset: offset);
  }

  /// 获取指定消息关联的文件操作记录
  Future<List<Map<String, dynamic>>> getFileOperationsByMessage(
      String messageId) async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getFileOperationsByMessage(messageId);
    }
    return _remoteOps!.getFileOperationsByMessage(messageId);
  }

  /// 清除文件操作记录
  Future<void> clearFileOperations() async {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.clearFileOperations();
    }
    return _remoteOps!.clearFileOperations();
  }

  // ===== Token 用量统计 =====
  TokenUsageRecord getSessionTokenUsage() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getSessionTokenUsage();
    }
    // 远程模式暂不支持，返回空记录
    return const TokenUsageRecord();
  }

  TokenUsageRecord? getMessageTokenUsage(String messageId) {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getMessageTokenUsage(messageId);
    }
    // 远程模式暂不支持
    return null;
  }

  Future<TokenUsageRecord> getSessionTokenUsageAsync() {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getSessionTokenUsageAsync();
    }
    return _remoteOps!.getSessionTokenUsageAsync();
  }

  Future<TokenUsageRecord?> getMessageTokenUsageAsync(String messageId) {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.getMessageTokenUsageAsync(messageId);
    }
    return _remoteOps!.getMessageTokenUsageAsync(messageId);
  }

  bool get isSending {
    if (isLocalMode && _localAgent != null) {
      return _localAgent.isSending;
    }
    return _remoteCache.status == AgentStatus.processing ||
        _remoteCache.status == AgentStatus.streaming;
  }

  /// 待确认消息队列长度
  int get pendingMessageQueueLength => _pendingMessageQueue.length;

  /// 待确认消息列表（只读副本，包含完整消息内容）
  List<PendingMessage> get pendingMessages =>
      List.unmodifiable(_pendingMessageQueue);

  /// 待确认消息ID列表（只读副本）
  List<String> get pendingMessageIds =>
      _pendingMessageQueue.map((msg) => msg.id).toList();

  // ===== 引用计数 =====

  void attach() {
    if (isLocalMode && _localAgent != null) {
      _localAgent.attach();
    }
  }

  void detach() {
    if (isLocalMode && _localAgent != null) {
      _localAgent.detach();
    }
  }

  // ===== 内部方法 =====

  /// 订阅远程事件流
  void _subscribeRemoteEvents(Stream<AgentEvent> stream) {
    _remoteEventSubscription?.cancel();
    _remoteEventSubscription = _remoteOps!.subscribeRemoteEvents(stream);
  }

  /// 释放资源
  Future<void> dispose() async {
    await _remoteEventSubscription?.cancel();
    await _stateController.close();
    await _eventController.close();
  }

  // ===== 私有方法 =====

  /// 创建待确认消息
  PendingMessage _createPendingMessage(MessageInput input, String messageId) {
    return PendingMessage(
      id: messageId,
      role: input.role ?? 'user',
      type: input.type,
      content: input.content,
      createdAt: input.createdAt ?? DateTime.now(),
      toolCallId: input.toolCallId,
      toolName: input.toolName,
      toolArguments: input.toolArguments,
      toolResult: input.toolResult,
      metadata: input.metadata,
      sentAt: DateTime.now(),
      pendingStatus: PendingMessageStatus.pending,
      deviceId: deviceId,
      employeeId: employeeId,
    );
  }

  /// 从待确认队列中移除已确认的消息
  ///
  /// 当查询消息列表时，如果返回的消息在队列中，说明已被持久化，可以从队列中移除
  void _removeConfirmedMessages(List<Map<String, dynamic>> messages) {
    if (_pendingMessageQueue.isEmpty) return;

    // 提取返回消息中的所有ID
    final confirmedIds = <String>{};
    for (final message in messages) {
      final id = message['id'] as String?;
      if (id != null && id.isNotEmpty) {
        confirmedIds.add(id);
      }
    }

    // 从队列中移除已确认的消息（根据消息ID）
    _pendingMessageQueue.removeWhere((msg) => confirmedIds.contains(msg.id));
  }
}

/// 远程状态缓存
class _RemoteStateCache {
  AgentStatus status = AgentStatus.idle;
  AgentStateSnapshot? snapshot;
  Map<String, dynamic>? contextData;
  Map<String, dynamic>? providerConfig;
  String? projectUuid;
  List<Map<String, dynamic>>? skillsConfig;
  List<Map<String, dynamic>>? mcpConfigs;

  void clear() {
    status = AgentStatus.idle;
    snapshot = null;
    contextData = null;
    providerConfig = null;
    projectUuid = null;
    skillsConfig = null;
    mcpConfigs = null;
  }
}
