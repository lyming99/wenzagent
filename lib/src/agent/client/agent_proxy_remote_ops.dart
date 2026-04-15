part of 'agent_proxy.dart';

/// 远程操作封装类
///
/// 将所有远程 RPC 消息查询操作和事件处理从 AgentProxy 中分离出来，
/// 通过 part 文件实现，可以访问 AgentProxy 的私有成员。
class _RemoteOps {
  final AgentRpcUtil _rpcUtil;
  final String _employeeId;
  final _RemoteStateCache _remoteCache;
  final void Function(List<Map<String, dynamic>>) _removeConfirmedMessages;
  final StreamController<AgentEvent> _eventController;
  final StreamController<AgentStateSnapshot> _stateController;

  _RemoteOps({
    required AgentRpcUtil rpcUtil,
    required String employeeId,
    required _RemoteStateCache remoteCache,
    required void Function(List<Map<String, dynamic>>) removeConfirmedMessages,
    required StreamController<AgentEvent> eventController,
    required StreamController<AgentStateSnapshot> stateController,
  })  : _rpcUtil = rpcUtil,
        _employeeId = employeeId,
        _remoteCache = remoteCache,
        _removeConfirmedMessages = removeConfirmedMessages,
        _eventController = eventController,
        _stateController = stateController;

  // ===== 会话消息查询 =====

  /// 获取会话消息
  ///
  /// 返回当前 Agent 的会话消息列表
  Future<List<AgentMessage>> getSessionMessages() async {
    final request = GetSessionMessagesRequest(employeeId: _employeeId);
    final result = await _rpcUtil.getSessionMessages(request);
    final messages =
        (result['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    // 根据返回的消息ID，从消息队列中移除
    _removeConfirmedMessages(messages);
    // 转换为 AgentMessage 列表
    return messages.map((m) => AgentMessage.fromMap(m)).toList();
  }

  /// 根据用户消息计数获取会话消息
  ///
  /// 统计用户发送的消息数（role='user'），达到 [userMessageLimit] 条时停止，
  /// 返回该时间段内的所有消息（包括user和assistant）
  Future<List<AgentMessage>> getSessionMessagesByUserCount({
    int userMessageLimit = 20,
  }) async {
    final request = GetSessionMessagesByUserCountRequest(
      employeeId: _employeeId,
      userMessageLimit: userMessageLimit,
    );
    final result = await _rpcUtil.getSessionMessagesByUserCount(request);
    final messages =
        (result['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    // 根据返回的消息ID，从消息队列中移除
    _removeConfirmedMessages(messages);
    // 转换为 AgentMessage 列表
    return messages.map((m) => AgentMessage.fromMap(m)).toList();
  }

  /// 分页获取会话消息
  ///
  /// [pageSize] 每页数量，默认20条
  /// [offset] 偏移量，默认0
  Future<List<AgentMessage>> getSessionMessagesPaged({
    int pageSize = 20,
    int offset = 0,
  }) async {
    final request = GetSessionMessagesPagedRequest(
      employeeId: _employeeId,
      pageSize: pageSize,
      offset: offset,
    );
    final result = await _rpcUtil.getSessionMessagesPaged(request);
    final messages =
        (result['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    // 根据返回的消息ID，从消息队列中移除
    _removeConfirmedMessages(messages);
    // 转换为 AgentMessage 列表
    return messages.map((m) => AgentMessage.fromMap(m)).toList();
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
    final request = GetUnreceivedMessagesRequest(
      employeeId: _employeeId,
      receiverDeviceId: receiverDeviceId,
      offset: offset,
      limit: limit,
    );
    final result = await _rpcUtil.getUnreceivedMessages(request);
    final messages =
        (result['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    // 转换为 AgentMessage 列表
    return messages.map((m) => AgentMessage.fromMap(m)).toList();
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
    final request = MarkMessagesAsReceivedRequest(
      employeeId: _employeeId,
      receiverDeviceId: receiverDeviceId,
      messageReceiveList: messageReceiveList,
    );
    await _rpcUtil.markMessagesAsReceived(request);
  }

  /// 增量拉取消息（基于 LSN）
  ///
  /// 客户端通过 lastSeq 获取 seq > lastSeq 的消息
  Future<List<AgentMessage>> getMessagesAfterSeq({
    int lastSeq = 0,
    int limit = 20,
  }) async {
    final request = GetMessagesAfterSeqRequest(
      employeeId: _employeeId,
      lastSeq: lastSeq,
      limit: limit,
    );
    final result = await _rpcUtil.getMessagesAfterSeq(request);
    final messages =
        (result['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return messages.map((m) => AgentMessage.fromMap(m)).toList();
  }

  /// 获取会话的最大 seq
  Future<int> getMaxSeq() async {
    final request = GetSessionMessagesRequest(employeeId: _employeeId);
    final result = await _rpcUtil.getMaxSeq(request);
    return result['maxSeq'] as int? ?? 0;
  }

  /// 获取会话的最小 seq
  ///
  /// 用于客户端判断远程最早保留消息的位置，本地 seq < minSeq 的消息可安全删除
  Future<int> getMinSeq() async {
    final request = GetMinSeqRequest(employeeId: _employeeId);
    final result = await _rpcUtil.getMinSeq(request);
    return result['minSeq'] as int? ?? 0;
  }

  /// 获取清空水位线
  ///
  /// 查询服务端是否设置了 clearSeq，如果 > 0，
  /// 客户端应删除本地 seq < clearSeq 的所有消息。
  Future<int> getClearSeq() async {
    final request = GetClearSeqRequest(employeeId: _employeeId);
    final result = await _rpcUtil.getClearSeq(request);
    return result['clearSeq'] as int? ?? 0;
  }

  /// 标记消息为已读
  ///
  /// 当用户打开会话查看消息时，通知 Agent 消息已读
  Future<void> markMessagesAsRead({
    required String readerDeviceId,
    List<String>? messageIds,
  }) async {
    final request = MarkMessagesAsReadRequest(
      employeeId: _employeeId,
      readerDeviceId: readerDeviceId,
      messageIds: messageIds,
    );
    await _rpcUtil.markMessagesAsRead(request);
  }

  /// 基于 seq 批量标记消息为已读
  Future<void> markMessagesAsReadBySeq({
    required String readerDeviceId,
    required int readSeq,
  }) async {
    final request = MarkMessagesAsReadBySeqRequest(
      employeeId: _employeeId,
      readerDeviceId: readerDeviceId,
      readSeq: readSeq,
    );
    await _rpcUtil.markMessagesAsReadBySeq(request);
  }

  /// 查询消息已读状态
  ///
  /// 设备重新打开时从 Agent 查询哪些消息已读
  Future<MessagesReadStatusResult> getMessagesReadStatus({
    required String deviceId,
  }) async {
    final request = GetMessagesReadStatusRequest(
      employeeId: _employeeId,
      deviceId: deviceId,
    );
    final result = await _rpcUtil.getMessagesReadStatus(request);
    return MessagesReadStatusResult.fromMap(result);
  }

  /// 获取会话摘要（未读计数 + 最新消息）
  Future<Map<String, dynamic>?> getSessionSummary() async {
    final request = GetSessionSummaryRequest(employeeId: _employeeId);
    final result = await _rpcUtil.getSessionSummary(request);
    if (result.isEmpty) return null;
    return result;
  }

  // ===== Todo 管理 =====

  /// 获取活跃 todo 项
  Future<List<Map<String, dynamic>>> getActiveTodos() async {
    final request = GetActiveTodosRequest(employeeId: _employeeId);
    final result = await _rpcUtil.getActiveTodos(request);
    return (result['todos'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// 获取已完成 todo 项
  Future<List<Map<String, dynamic>>> getCompletedTodos({int limit = 50}) async {
    final request = GetCompletedTodosRequest(
      employeeId: _employeeId,
      limit: limit,
    );
    final result = await _rpcUtil.getCompletedTodos(request);
    return (result['todos'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// 获取 todo 分组
  Future<List<Map<String, dynamic>>> getTodoGroups() async {
    final request = GetTodoGroupsRequest(employeeId: _employeeId);
    final result = await _rpcUtil.getTodoGroups(request);
    return (result['groups'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// 获取 todo 统计
  Future<Map<String, dynamic>> getTodoStats() async {
    final request = GetTodoStatsRequest(employeeId: _employeeId);
    return await _rpcUtil.getTodoStats(request);
  }

  // ===== Todo 写操作 =====

  /// 更新 todo 状态
  Future<void> updateTodoStatus(String todoId, String status) async {
    final request = UpdateTodoStatusRequest(
      employeeId: _employeeId,
      todoId: todoId,
      status: status,
    );
    await _rpcUtil.updateTodoStatus(request);
  }

  /// 更新 todo 内容
  Future<void> updateTodoContent(String todoId, String content) async {
    final request = UpdateTodoContentRequest(
      employeeId: _employeeId,
      todoId: todoId,
      content: content,
    );
    await _rpcUtil.updateTodoContent(request);
  }

  /// 删除 todo
  Future<void> deleteTodo(String todoId) async {
    final request = DeleteTodoRequest(
      employeeId: _employeeId,
      todoId: todoId,
    );
    await _rpcUtil.deleteTodo(request);
  }

  /// 清除已完成 todo
  Future<void> clearCompletedTodos() async {
    final request = ClearCompletedTodosRequest(employeeId: _employeeId);
    await _rpcUtil.clearCompletedTodos(request);
  }

  /// 移动 todo 到分组
  Future<void> moveTodoToGroup(String todoId, String? groupId) async {
    final request = MoveTodoToGroupRequest(
      employeeId: _employeeId,
      todoId: todoId,
      groupId: groupId,
    );
    await _rpcUtil.moveTodoToGroup(request);
  }

  /// 清空当前会话
  Future<void> clearCurrentSession() async {
    final request = ClearSessionRequest(employeeId: _employeeId);
    await _rpcUtil.clearSession(request);
  }

  // ===== 异步状态/配置查询 =====

  /// 获取当前状态快照（异步版本，支持远程 RPC）
  Future<AgentStateSnapshot> getStateSnapshotAsync() async {
    final request = GetStateRequest(employeeId: _employeeId);
    final result = await _rpcUtil.getState(request);
    return AgentStateSnapshot.fromMap(result);
  }

  /// 获取提供者配置（异步版本，支持远程 RPC）
  Future<ProviderConfig?> getProviderConfigAsync() async {
    final request = GetProviderRequest(employeeId: _employeeId);
    final result = await _rpcUtil.getProvider(request);
    final configMap = result['providerConfig'] as Map<String, dynamic>?;
    if (configMap != null) {
      _remoteCache.providerConfig = configMap;
      return ProviderConfig.fromMap(configMap);
    }
    return null;
  }

  /// 获取技能配置（异步版本，支持远程 RPC）
  Future<List<Map<String, dynamic>>> getSkillsConfigAsync() async {
    final request = AgentGetSkillsRequest(employeeId: _employeeId);
    final result = await _rpcUtil.getSkills(request);
    final skills =
        (result['skills'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    _remoteCache.skillsConfig = skills;
    return skills;
  }

  /// 获取 MCP 服务器配置（异步版本，支持远程 RPC）
  Future<List<Map<String, dynamic>>> getMcpConfigsAsync() async {
    final request = GetMcpConfigsRequest(employeeId: _employeeId);
    final result = await _rpcUtil.getMcpConfigs(request);
    final configs =
        (result['mcpConfigs'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    _remoteCache.mcpConfigs = configs;
    return configs;
  }

  /// 获取当前项目UUID（异步版本，支持远程 RPC）
  Future<String?> getCurrentProjectUuidAsync() async {
    final request = GetProjectUuidRequest(employeeId: _employeeId);
    final result = await _rpcUtil.getProjectUuid(request);
    final uuid = result['projectUuid'] as String?;
    _remoteCache.projectUuid = uuid;
    return uuid;
  }

  // ===== 文件操作 =====

  /// 检查路径是否存在于目标设备上（异步版本，支持远程 RPC）
  ///
  /// [path] 文件系统绝对路径
  Future<PathExistsResult> checkPathExists(String path) async {
    final request =
        CheckPathExistsRequest(employeeId: _employeeId, path: path);
    final result = await _rpcUtil.checkPathExists(request);
    return PathExistsResult.fromMap(result);
  }

  /// 列出目录内容
  ///
  /// [path] 目录路径
  Future<DirectoryListingResult> listDirectory(String path) async {
    final request =
        ListDirectoryRequest(employeeId: _employeeId, path: path);
    final result = await _rpcUtil.listDirectory(request);
    return DirectoryListingResult.fromMap(result);
  }

  /// 获取文件/目录信息
  ///
  /// [path] 文件路径
  Future<FileInfoResult> getFileInfo(String path) async {
    final request =
        GetFileInfoRequest(employeeId: _employeeId, path: path);
    final result = await _rpcUtil.getFileInfo(request);
    return FileInfoResult.fromMap(result);
  }

  /// 创建目录
  ///
  /// [path] 目录路径
  Future<FileOpResult> createDirectory(String path) async {
    final request =
        CreateDirectoryRequest(employeeId: _employeeId, path: path);
    final result = await _rpcUtil.createDirectory(request);
    return FileOpResult.fromMap(result);
  }

  /// 删除文件/目录
  ///
  /// [path] 文件/目录路径
  Future<FileOpResult> deleteFile(String path) async {
    final request =
        DeleteFileRequest(employeeId: _employeeId, path: path);
    final result = await _rpcUtil.deleteFile(request);
    return FileOpResult.fromMap(result);
  }

  /// 重命名/移动文件
  Future<FileOpResult> renameFile(String oldPath, String newPath) async {
    final request = RenameFileRequest(
      employeeId: _employeeId,
      oldPath: oldPath,
      newPath: newPath,
    );
    final result = await _rpcUtil.renameFile(request);
    return FileOpResult.fromMap(result);
  }

  // ===== 事件处理 =====

  /// 订阅远程事件流
  StreamSubscription<AgentEvent>? subscribeRemoteEvents(
    Stream<AgentEvent> stream,
  ) {
    return stream.listen(
      onRemoteEvent,
      onError: (error) {
        // 连接错误
      },
      onDone: () {
        // 连接关闭
      },
    );
  }

  /// 处理远程事件
  void onRemoteEvent(AgentEvent event) {
    final type = event.type;
    final data = event.data;
    final eventEmployeeUuid = event.employeeId;

    // 只处理与当前 Agent 相关的事件
    if (eventEmployeeUuid != null && eventEmployeeUuid != _employeeId) {
      return;
    }

    // 关键：广播原始事件，供CachedAgentProxy监听
    _eventController.add(event);

    switch (type) {
      case AgentEventType.agentStatusChanged:
        final snapshot = AgentStateSnapshot.fromMap(data);
        // 只在状态真正改变时才更新和广播
        if (_remoteCache.status != snapshot.status) {
          _remoteCache.snapshot = snapshot;
          _remoteCache.status = snapshot.status;
          _stateController.add(snapshot);
        }
        break;

      case AgentEventType.messageStatusChanged:
        // 消息状态变化事件，需要根据消息状态更新 Agent 状态
        final messageStatusStr = data['status'] as String?;
        if (messageStatusStr != null) {
          final messageStatus = AgentMessageStatus.fromString(messageStatusStr);

          // 只有在消息完成、失败、中断或撤回时才更新状态为 idle
          // 并且当前状态不是 idle 时才触发更新
          if ((messageStatus == AgentMessageStatus.completed ||
                  messageStatus == AgentMessageStatus.failed ||
                  messageStatus == AgentMessageStatus.interrupted ||
                  messageStatus == AgentMessageStatus.revoked) &&
              _remoteCache.status != AgentStatus.idle) {
            // 消息处理完成，状态应该变为 idle
            final idleSnapshot = AgentStateSnapshot(
              status: AgentStatus.idle,
              currentProcessingMessageId: null,
              queuedMessageIds: data['queuedMessageIds'] as List<String>? ?? [],
              isStreaming: false,
              queueLength: data['queueLength'] as int? ?? 0,
            );
            _remoteCache.snapshot = idleSnapshot;
            _remoteCache.status = AgentStatus.idle;
            _stateController.add(idleSnapshot);
          } else {
            // 消息正在排队或处理中，或者已经是 idle 状态
            // 保持当前状态，但可能需要更新其他信息
            if (_remoteCache.snapshot != null) {
              _stateController.add(_remoteCache.snapshot!);
            }
          }
        }
        break;

      default:
        break;
    }
  }
}
