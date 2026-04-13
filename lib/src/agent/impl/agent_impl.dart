import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';
import 'package:wenzagent/wenzagent.dart';

/// Agent 主体实现类（纯 Dart）
///
/// 实现 [IAgent] 接口，组装所有内部组件：
/// - [IChatAdapter]: 对话适配器（流式消息、持久化）
/// - [MessageProcessor]: 消息处理调度器
/// - [ToolRegistry]: 工具注册器
/// - [ToolPermissionManager]: 权限管理器
///
/// 设计原则：
/// - 纯 Dart，不依赖 Flutter
/// - Completer-based 加锁保证多客户端一致性
/// - 引用计数管理生命周期
class AgentImpl implements IAgent {
  @override
  final String employeeId;

  /// 所属设备ID（用于数据库隔离）
  final String deviceId;

  // ===== 内部组件 =====

  /// 对话适配器
  final IChatAdapter _chatAdapter;

  /// 消息处理调度器（延迟初始化）
  MessageProcessor? _processor;

  /// 工具注册器
  final ToolRegistry _toolRegistry = ToolRegistry();

  /// 获取工具注册器（供内部模块注入回调使用）
  ToolRegistry get toolRegistry => _toolRegistry;

  /// 权限管理器
  final ToolPermissionManager _permissionManager = ToolPermissionManager();

  /// 获取权限管理器（供 AgentFactory 注入配置使用）
  ToolPermissionManager get permissionManager => _permissionManager;

  /// 待处理的权限请求 Completer
  final Map<String, Completer<PermissionDecision>> _pendingPermissions = {};

  /// 待处理的权限请求信息
  final Map<String, AgentPermissionRequest> _pendingPermissionRequests = {};

  /// 技能管理器
  SkillLifecycleManager? _skillManager;

  /// 是否已启用技能系统
  bool _enableSkills = false;

  /// 消息接收状态跟踪
  /// 当消息被设备接收后，记录接收时间和消息的更新时间
  /// 当消息状态更新时，清除接收状态，让设备可以重新接收
  final Map<String, Map<String, DateTime>> _messageReceiveStatus = {};

  /// 消息已读状态跟踪
  /// 当某个设备上的用户查看了消息后，记录已读状态
  final Map<String, Map<String, DateTime>> _messageReadStatus = {};

  /// 正在调用中的工具 callId 集合
  /// toolCallStart 时加入，toolCallResult 时移除
  final Set<String> _callingToolIds = {};

  // ===== 内部状态 =====

  /// 当前 Agent 状态
  AgentStatus _status = AgentStatus.idle;

  /// 引用计数
  int _refCount = 0;

  /// 最后活跃时间
  DateTime _lastActiveTime = DateTime.now();

  /// 异步操作锁
  Completer<void>? _lockCompleter;

  AgentImpl({required this.employeeId, required this.deviceId, required IChatAdapter chatAdapter})
    : _chatAdapter = chatAdapter;

  // ===== IAgent: 基础信息 =====

  @override
  AgentStatus get status => _status;

  @override
  bool get isAlive => _status != AgentStatus.disposed;

  @override
  int get refCount => _refCount;

  @override
  DateTime get lastActiveTime => _lastActiveTime;

  @override
  bool get isSending =>
      _status == AgentStatus.processing || _status == AgentStatus.streaming;

  @override
  bool get isStreaming => _chatAdapter.isStreaming;

  @override
  String? get currentProcessingMessageId =>
      _processor?.currentProcessingMessageId;

  @override
  List<String> get queuedMessageIds => _processor?.queuedMessageIds ?? [];

  @override
  int get queueLength => _processor?.queueLength ?? 0;

  // ===== IAgent: 生命周期 =====

  /// 延迟加载锁（防止重复 warmup）
  ///
  /// warmup 期间 sendMessage 通过此 Completer 排队等待。
  Completer<void>? _warmupCompleter;

  @override
  Future<void> initialize({
    String? employeeId,
    bool enableBuiltinTools = true,
    bool enableSkills = true,
  }) async {
    final eid = employeeId ?? this.employeeId;

    // 初始化适配器：恢复 session 配置 + 加载最近 10 条消息（快速）
    await _chatAdapter.initSession(employeeId: eid, recentLimit: 10);

    // 注册内置工具（可选）
    if (enableBuiltinTools) {
      _toolRegistry.registerTools(BuiltinTools.all());
    }

    // 技能系统由 warmup 后台加载，不在 initialize 中阻塞

    // 设置工具注册器和权限管理器到适配器
    _chatAdapter.setToolRegistry(_toolRegistry);
    _chatAdapter.setPermissionManager(_permissionManager);

    // 设置权限回调：通过事件流广播权限请求
    _permissionManager.onPermissionRequest = (request) async {
      final completer = Completer<PermissionDecision>();
      _pendingPermissions[request.requestId] = completer;
      _pendingPermissionRequests[request.requestId] = request;

      // 设置处理器状态为等待权限
      _processor?.setPermissionBlocked(request.requestId);

      // 广播权限请求事件
      _eventController.add(
        AgentEvent(
          type: AgentEventType.toolPermissionRequest,
          data: request.toMap(),
          employeeId: employeeId,
        ),
      );

      try {
        return await completer.future;
      } finally {
        _pendingPermissions.remove(request.requestId);
        _pendingPermissionRequests.remove(request.requestId);
        // 恢复处理状态
        _processor?.setPermissionBlocked(null);
      }
    };

    // 设置工具事件回调：通过事件流广播 + 维护工具调用状态
    _chatAdapter.setToolEventCallback((toolEvent) {
      switch (toolEvent) {
        case ToolCallStartEvent():
          _callingToolIds.add(toolEvent.toolCallId);
        case ToolCallResultEvent():
          _callingToolIds.remove(toolEvent.toolCallId);
      }
      final map = ToolEventMapper.toMap(toolEvent);
      _eventController.add(
        AgentEvent.fromMap({...map, 'employeeId': employeeId}),
      );
    });

    // 初始化消息处理调度器
    // 创建打断判断器
    final interruptJudge = InterruptJudge((prompt) async {
      return await _chatAdapter.invokeOnce(prompt);
    });

    _processor = MessageProcessor(
      streamMessage: (messageId, message, {cancellationToken}) {
        return _chatAdapter
            .streamMessage(message, cancellationToken: cancellationToken)
            .map(
              (r) => StreamResponse(
                content: r.content,
                error: r.error,
                isDone: r.isDone,
                type: r.type,
                data: r.data,
              ),
            );
      },
      stopStreaming: () => _chatAdapter.stopStreaming(),
      interruptJudge: interruptJudge,
    );

    // 监听处理器状态变更
    _processor!.onStateChanged = (processorStatus) {
      _syncProcessorStatus(processorStatus);
    };

    // 消息完成前回调：等待持久化队列中所有消息任务落盘，
    // 确保 Client 增量拉取时消息已写入数据库、seq 已分配。
    // （修复 async* generator 被取消导致 post-loop 持久化代码不执行的问题）
    _processor!.onBeforeMessageCompleted = () async {
      if (_chatAdapter case final PersistentChatAdapter adapter) {
        final pq = adapter.persistenceQueue;
        if (pq.isProcessing || pq.queueLength > 0) {
          print('[AgentImpl] onBeforeMessageCompleted: 等待持久化队列完成...');
          await pq.waitForAll(timeout: const Duration(seconds: 10));
        }
      }
    };

    // 监听消息处理状态变更
    _processor!.onMessageStatusChanged = (messageId, msgStatus, {error}) async {
      // 附带消息完整数据，供通知中心构建预览卡片
      Map<String, dynamic> extraData = {};
      final tracked = _processor!.allTrackedMessages
          .where((m) => m.messageId == messageId)
          .firstOrNull;
      if (tracked != null) {
        final msgMap = tracked.messageData;
        extraData['role'] = msgMap['role'] ?? 'user';
        extraData['type'] = msgMap['type'] ?? 'text';
        extraData['content'] = msgMap['content'];
        if (msgMap['metadata'] != null) {
          extraData['metadata'] = msgMap['metadata'];
        }
      }
      _broadcasterBroadcastMessageStatusChange(
        messageId: messageId,
        status: msgStatus,
        error: error,
        extraData: extraData,
      );
    };

    _touch();
    _setStatus(AgentStatus.idle);
  }

  @override
  Future<void> warmup() async {
    // 双重锁：防止并发重复加载
    if (_warmupCompleter != null) return _warmupCompleter!.future;

    _warmupCompleter = Completer<void>();
    try {
      // 1. 加载全部历史消息（替换 initialize 中的最近 10 条）
      await _chatAdapter.loadRemainingMessages();

      // 2. 初始化技能系统（MCP / 持久化技能 / 文件夹技能）
      await _initSkillSystem(employeeId);
    } catch (e) {
      print('[AgentImpl] warmup 失败: $e');
    } finally {
      _warmupCompleter!.complete();
      _warmupCompleter = null;
    }
  }

  @override
  Future<void> dispose() async {
    if (_status == AgentStatus.disposed) return;

    _setStatus(AgentStatus.disposed);

    // 取消所有待处理的权限请求
    for (final completer in _pendingPermissions.values) {
      if (!completer.isCompleted) {
        completer.complete(PermissionDecision.deny);
      }
    }
    _pendingPermissions.clear();
    _pendingPermissionRequests.clear();

    _processor?.dispose();
    _processor = null;

    await _skillManager?.dispose();
    _skillManager = null;

    await _chatAdapter.dispose();
    await _stateController.close();
    await _eventController.close();

    _callingToolIds.clear();
  }

  // ===== IAgent: 引用计数 =====

  @override
  void attach() {
    _refCount++;
    _touch();
  }

  @override
  void detach() {
    if (_refCount > 0) _refCount--;
    _touch();
  }

  // ===== Skill 系统 =====

  /// 是否启用技能系统
  bool get isSkillEnabled => _enableSkills;

  /// 获取技能管理器
  SkillLifecycleManager? get skillManager => _skillManager;

  /// 运行时动态添加技能
  Future<void> addSkill(Skill skill) async {
    if (_skillManager == null) return;
    await _skillManager!.loadSkill(skill);
  }

  /// 运行时移除技能
  Future<void> removeSkill(String skillId) async {
    await _skillManager?.unloadSkill(skillId);
  }

  /// 运行时重新加载技能
  Future<void> reloadSkill(String skillId) async {
    await _skillManager?.reloadSkill(skillId);
  }

  /// 初始化技能系统
  Future<void> _initSkillSystem(String employeeId) async {
    print('[Skill] ========== 开始初始化技能系统, employeeId=$employeeId ==========');

    final context = SkillContext(
      toolRegistry: _toolRegistry,
      employeeId: employeeId,
      invokeLlm: (prompt) => _chatAdapter.invokeOnce(prompt),
      logger: (level, msg) => print('[Skill][$level] $msg'),
    );

    _skillManager = SkillLifecycleManager(context);

    // 从数据库加载 Type 1 (mcp) 和 Type 3 (config) 技能
    await _loadPersistedSkills(employeeId);

    // 扫描文件夹加载 Type 2 (folder) 技能
    await _scanFolderSkills(context);

    _enableSkills = true;
    print('[Skill] ========== 技能系统初始化完成 ==========');
  }

  /// 从数据库加载持久化技能
  Future<void> _loadPersistedSkills(String employeeId) async {
    final store = SkillStore(deviceId: deviceId);
    print('[Skill] 开始加载持久化技能, employeeId=$employeeId');

    final entities = await store.findByEmployeeWithDeviceId(null, employeeId);
    print('[Skill] 数据库查询完成, 共 ${entities.length} 条技能记录');

    int loaded = 0;
    int skipped = 0;
    int failed = 0;

    for (final entity in entities) {
      print(
        '[Skill] 处理技能: uuid=${entity.uuid}, name=${entity.name}, '
        'type=${entity.skillType}, enabled=${entity.enabled}, '
        'config=${entity.config?.substring(0, entity.config!.length > 80 ? 80 : entity.config!.length)}',
      );

      if (entity.enabled != 1) {
        print('[Skill] 跳过已禁用技能: ${entity.name}');
        skipped++;
        continue;
      }

      Skill? skill;
      switch (entity.skillType) {
        case 'mcp':
          try {
            skill = McpSkill.fromEntity(entity);
            print('[Skill] MCP 技能实体创建成功: ${entity.name}');
          } catch (e) {
            print('[Skill] MCP 技能实体创建失败: ${entity.name}, $e');
          }
          break;
        case 'config':
          try {
            skill = ConfigSkill.fromEntity(entity);
            print('[Skill] Config 技能实体创建成功: ${entity.name}');
          } catch (e) {
            print('[Skill] Config 技能实体创建失败: ${entity.name}, $e');
          }
          break;
        case 'folder':
          String? folderPath;
          try {
            final configMap =
                jsonDecode(entity.config!) as Map<String, dynamic>;
            folderPath = configMap['folder_path'] as String?;
          } catch (_) {
            folderPath = entity.config;
          }
          if (folderPath != null && folderPath.isNotEmpty) {
            final s = FolderSkill(
              path: folderPath,
              id: entity.uuid,
              name: entity.name,
            );
            s.setContext(
              SkillContext(
                toolRegistry: _toolRegistry,
                employeeId: employeeId,
                invokeLlm: (prompt) => _chatAdapter.invokeOnce(prompt),
                logger: (level, msg) => print('[Skill][$level] $msg'),
              ),
            );
            skill = s;
            print('[Skill] Folder 技能实体创建成功: ${entity.name}, path=$folderPath');
          } else {
            print('[Skill] Folder 技能跳过(无路径): ${entity.name}');
          }
          break;
        default:
          print('[Skill] 未知技能类型: ${entity.skillType}, name=${entity.name}');
          break;
      }

      if (skill != null) {
        try {
          await _skillManager!.loadSkill(skill);
          print('[Skill] 技能加载并激活成功: ${entity.name}');
          loaded++;
        } catch (e, st) {
          print('[Skill] 技能加载失败: ${entity.name}, error=$e\n$st');
          failed++;
        }
      }
    }

    print('[Skill] 持久化技能加载完成: 成功=$loaded, 跳过=$skipped, 失败=$failed');
  }

  /// 扫描文件夹技能
  Future<void> _scanFolderSkills(SkillContext context) async {
    final skillsDir = Directory('skills${Platform.pathSeparator}folder');
    if (!await skillsDir.exists()) return;

    await for (final entity in skillsDir.list()) {
      if (entity is! Directory) continue;
      final skill = FolderSkill(path: entity.path, id: entity.path);
      skill.setContext(context);
      try {
        await _skillManager!.loadSkill(skill);
      } catch (e) {
        print('[Skill] 文件夹加载失败: ${entity.path}, $e');
      }
    }
  }

  // ===== IAgent: 对话操作 =====

  @override
  Future<String> sendMessage(MessageInput input) async {
    _touch();

    // 等待 warmup 完成：确保全部历史消息已加载，LLM 有完整上下文
    if (_warmupCompleter != null) {
      await _warmupCompleter!.future;
    }

    print(
      '[AgentImpl] sendMessage: ${input.content.substring(0, input.content.length.clamp(0, 50))}',
    );

    return await _withLock(() async {
      // 🔑 关键修复：优先使用 MessageInput.id，避免被 metadata.id 覆盖
      // 这是客户端提供的"真实"消息ID，必须在整个传输链中保持一致
      final clientProvidedId = input.id;

      // 转换为 Map 以便内部处理
      final messageData = input.toMap();

      // 🔑 关键：如果客户端提供了ID，强制使用它，覆盖metadata中的id
      if (clientProvidedId != null && clientProvidedId.isNotEmpty) {
        messageData['id'] = clientProvidedId;
        print('[AgentImpl] 使用客户端提供的消息ID: $clientProvidedId (强制覆盖metadata)');
      } else {
        // 客户端没有提供ID，检查messageData中是否有ID（可能来自metadata）
        final existingId = messageData['id'] as String?;
        if (existingId == null || existingId.isEmpty) {
          // 没有任何ID，生成一个新的
          final newMessageId = const Uuid().v4();
          messageData['id'] = newMessageId;
          print('[AgentImpl] 生成新消息ID: $newMessageId');
        } else {
          print('[AgentImpl] 使用metadata中的消息ID: $existingId');
        }
      }

      final finalMessageId = messageData['id'] as String;
      messageData['role'] = 'user';
      messageData['type'] = messageData['type'] as String? ?? 'text';
      messageData['createdAt'] = DateTime.now().toIso8601String();

      print('[AgentImpl] 提交消息到处理器，最终消息ID: $finalMessageId');
      // 提交到处理器
      await _processor?.submitMessage(finalMessageId, messageData);

      return finalMessageId;
    });
  }

  @override
  Future<String> sendMessageFromMap(Map<String, dynamic> messageData) {
    return sendMessage(MessageInput.fromMap(messageData));
  }

  @override
  Future<void> interrupt() async {
    _touch();
    await _processor?.interruptCurrentTask();
    _callingToolIds.clear();
    _setStatus(AgentStatus.idle);
  }

  // ===== IAgent: 会话管理 =====

  @override
  Future<List<AgentMessage>> getSessionMessages() async {
    return _chatAdapter.getSessionMessages(employeeId);
  }

  @override
  Future<List<AgentMessage>> getSessionMessagesByUserCount({
    int userMessageLimit = 20,
  }) async {
    // 1. 获取所有消息
    final allMessages = await _chatAdapter.getSessionMessages(employeeId);

    if (allMessages.isEmpty) {
      return [];
    }

    // 2. 按时间倒序排列（最新的在前）
    allMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // 3. 统计用户消息，达到限制时停止
    int userMessageCount = 0;
    final selectedMessages = <AgentMessage>[];

    for (final message in allMessages) {
      selectedMessages.add(message);

      // 统计用户消息
      if (message.role == 'user') {
        userMessageCount++;

        // 达到限制时停止
        if (userMessageCount >= userMessageLimit) {
          break;
        }
      }
    }

    // 4. 按时间正序排列返回
    selectedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return selectedMessages;
  }

  @override
  Future<List<AgentMessage>> getSessionMessagesPaged({
    int pageSize = 20,
    int offset = 0,
  }) async {
    // 1. 获取所有消息
    final allMessages = await _chatAdapter.getSessionMessages(employeeId);

    if (allMessages.isEmpty) {
      return [];
    }

    // 2. 按时间倒序排列（最新的在前）
    allMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // 3. 分页获取
    final pagedMessages = allMessages.skip(offset).take(pageSize).toList();

    // 4. 按时间正序排列返回
    pagedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return pagedMessages;
  }

  @override
  Future<List<AgentMessage>> getUnreceivedMessages({
    required String receiverDeviceId,
    int offset = 0,
    int limit = 20,
  }) async {
    // 1. 获取所有消息
    final allMessages = await _chatAdapter.getSessionMessages(employeeId);

    if (allMessages.isEmpty) {
      return [];
    }

    // 2. 过滤出该设备未接收的消息
    final unreceivedMessages = <AgentMessage>[];

    for (final message in allMessages) {
      final messageUpdateTime = _getMessageUpdateTime(message);

      // 检查该设备是否已接收此消息
      final receiveStatus = _messageReceiveStatus[message.id];
      if (receiveStatus == null) {
        // 消息未被任何设备接收过，属于未接收消息
        unreceivedMessages.add(message);
        continue;
      }

      final deviceReceiveTime = receiveStatus[receiverDeviceId];
      if (deviceReceiveTime == null) {
        // 该设备未接收过此消息，属于未接收消息
        unreceivedMessages.add(message);
        continue;
      }

      // 检查消息是否已更新（updateTime比接收时间更新）
      if (messageUpdateTime.isAfter(deviceReceiveTime)) {
        // 消息已更新，需要重新接收
        unreceivedMessages.add(message);
      }
    }

    // 3. 按时间正序排列
    unreceivedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // 4. 分页
    final pagedMessages = unreceivedMessages.skip(offset).take(limit).toList();

    print(
      '[AgentImpl] 查询设备 $receiverDeviceId 的未接收消息，共 ${unreceivedMessages.length} 条，返回第 ${offset + 1}-${offset + pagedMessages.length} 条',
    );
    return pagedMessages;
  }

  @override
  Future<void> markMessagesAsReceived({
    required String receiverDeviceId,
    required List<MessageReceiveInfo> messageReceiveList,
  }) async {
    // 记录消息接收状态
    for (final info in messageReceiveList) {
      // 获取或创建消息的接收状态Map
      _messageReceiveStatus[info.messageId] ??= {};

      // 记录该设备的接收时间
      _messageReceiveStatus[info.messageId]![receiverDeviceId] =
          info.updateTime;
    }

    print(
      '[AgentImpl] 已标记设备 $receiverDeviceId 接收 ${messageReceiveList.length} 条消息',
    );
  }

  @override
  Future<List<AgentMessage>> getMessagesAfterSeq({
    required String employeeId,
    int lastSeq = 0,
    int limit = 20,
  }) async {
    final store = MessageStore(deviceId: deviceId);
    final chatMessages = await store.getMessagesAfterSeq(employeeId, lastSeq, limit: limit);

    final messages = chatMessages.map((cm) {
      final map = cm.toJson();
      // 将 seq 和 deleted 注入 metadata，供客户端增量同步使用
      final metadata = Map<String, dynamic>.from(
        (map['metadata'] as Map<String, dynamic>?) ?? {},
      );
      if (cm.seq > 0) metadata['seq'] = cm.seq;
      if (cm.deleted) metadata['deleted'] = 1;
      if (cm.updatedAt != null) {
        metadata['updateTime'] = cm.updatedAt!.toIso8601String();
      }
      map['metadata'] = metadata.isNotEmpty ? metadata : null;
      return AgentMessage.fromMap(map);
    }).toList();

    print(
      '[AgentImpl] getMessagesAfterSeq: employeeId=$employeeId, lastSeq=$lastSeq, 返回 ${messages.length} 条',
    );
    return messages;
  }

  @override
  Future<int> getMaxSeq({required String employeeId}) async {
    final store = SyncWatermarkStore(deviceId: deviceId);
    return store.getLastSeq(employeeId);
  }

  @override
  Future<int> getMinSeq({required String employeeId}) async {
    final store = SyncWatermarkStore(deviceId: deviceId);
    return store.getClearSeq(employeeId) ?? 0;
  }

  @override
  Future<void> markMessagesAsRead({
    required String readerDeviceId,
    required String employeeId,
    List<String>? messageIds,
  }) async {
    _touch();

    // 如果未指定消息ID列表，则标记该员工的所有消息为已读
    final ids = messageIds;
    if (ids != null && ids.isNotEmpty) {
      for (final messageId in ids) {
        _messageReadStatus[messageId] ??= {};
        _messageReadStatus[messageId]![readerDeviceId] = DateTime.now();
      }
      print('[AgentImpl] 已标记设备 $readerDeviceId 对 ${ids.length} 条消息的已读状态');
    } else {
      // 获取所有消息并标记已读
      final allMessages = await _chatAdapter.getSessionMessages(employeeId);
      for (final message in allMessages) {
        _messageReadStatus[message.id] ??= {};
        _messageReadStatus[message.id]![readerDeviceId] = DateTime.now();
      }
      print('[AgentImpl] 已标记设备 $readerDeviceId 对员工 $employeeId 所有消息的已读状态');
    }

    // 广播已读状态变更事件
    _eventController.add(
      AgentEvent(
        type: AgentEventType.messageReadStatusChanged,
        data: {
          'employeeId': employeeId,
          'readerDeviceId': readerDeviceId,
          'messageIds': ids,
        },
        employeeId: employeeId,
      ),
    );
  }

  @override
  Future<MessagesReadStatusResult> getMessagesReadStatus({
    required String deviceId,
    required String employeeId,
  }) async {
    // 获取该员工的所有消息
    final allMessages = await _chatAdapter.getSessionMessages(employeeId);

    final readStatus = <String, bool>{};
    for (final message in allMessages) {
      final messageReadMap = _messageReadStatus[message.id];
      readStatus[message.id] =
          messageReadMap != null && messageReadMap.containsKey(deviceId);
    }

    return MessagesReadStatusResult(
      employeeId: employeeId,
      deviceId: deviceId,
      readStatus: readStatus,
    );
  }

  /// 获取消息的更新时间
  DateTime _getMessageUpdateTime(AgentMessage message) {
    // 优先使用metadata中的updateTime（始终为ISO8601字符串）
    final updateTime = message.metadata?['updateTime'];
    if (updateTime is String) {
      return DateTime.parse(updateTime);
    }

    // 其次使用createdAt
    return message.createdAt;
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessagesAsMap() async {
    final messages = await getSessionMessages();
    return messages.map((m) => m.toMap()).toList();
  }

  @override
  Future<void> revokeMessage(String messageId) async {
    _touch();

    // 如果正在处理的是要删除的消息，先打断
    if (_processor?.currentProcessingMessageId == messageId) {
      print('[AgentImpl] 正在处理的消息被删除，打断处理: $messageId');
      await _processor?.interruptCurrentTask();
    } else {
      // 否则只从队列中撤回
      await _processor?.revokeMessage(messageId);
    }

    // 从内存中删除消息
    _chatAdapter.removeMessageFromMemory(messageId);
  }

  @override
  AgentPermissionRequest? getPendingPermissionRequest() {
    // 返回第一个待处理的权限请求
    if (_pendingPermissionRequests.isEmpty) return null;
    return _pendingPermissionRequests.values.first;
  }

  @override
  Future<void> clearCurrentSession() async {
    _touch();
    await _withLock(() async {
      // 如果有正在处理的消息，先打断
      if (_processor?.currentProcessingMessageId != null) {
        print('[AgentImpl] 清空会话，打断正在处理的消息');
        await _processor?.interruptCurrentTask();
      }

      await _chatAdapter.clearCurrentSession();
    });

    // 广播会话清空事件，通知所有客户端
    _eventController.add(
      AgentEvent(
        type: AgentEventType.sessionCleared,
        data: {'employeeId': employeeId},
        employeeId: employeeId,
      ),
    );
  }

  @override
  Future<void> removeMessageFromMemory(String messageId) async {
    _touch();
    await _withLock(() async {
      _chatAdapter.removeMessageFromMemory(messageId);
    });
  }

  // ===== IAgent: 上下文管理 =====

  @override
  Future<void> setContext(Map<String, dynamic> contextData) async {
    _touch();
    _chatAdapter.setContext(contextData);
  }

  @override
  Future<void> clearContext() async {
    _touch();
    _chatAdapter.clearContext();
  }

  @override
  Map<String, dynamic>? getCurrentContext() {
    return _chatAdapter.currentContext;
  }

  // ===== IAgent: 模型管理 =====

  @override
  Future<void> setProvider(ProviderConfig providerConfig) async {
    _touch();
    await _withLock(() async {
      if (_chatAdapter case final PersistentChatAdapter adapter) {
        await adapter.saveProviderConfig(providerConfig);
      } else {
        await _chatAdapter.updateProvider(providerConfig.toMap());
      }
    });
  }

  @override
  ProviderConfig? getProviderConfig() {
    final configMap = _chatAdapter.getProviderConfig();
    return configMap != null ? ProviderConfig.fromMap(configMap) : null;
  }

  // ===== IAgent: 技能管理 =====

  @override
  Future<void> setSkills(List<Map<String, dynamic>> skillMaps) async {
    _touch();
    await _withLock(() async {
      final store = SkillStore(deviceId: deviceId);

      // 1. 软删除当前员工的所有技能
      final existingSkills = await store.findByEmployeeWithDeviceId(
        null,
        employeeId,
      );
      for (final skill in existingSkills) {
        await store.delete(null, skill.uuid);
      }

      // 2. 保存新的技能列表
      final entities = skillMaps
          .map((m) => AiEmployeeSkillEntity.fromMap(m))
          .toList();
      for (final entity in entities) {
        await store.save(entity);
      }

      // 3. 卸载当前运行时技能
      if (_skillManager != null) {
        final currentSkills = _skillManager!.skills.toList();
        for (final skill in currentSkills) {
          await _skillManager!.unloadSkill(skill.id);
        }
      }

      // 4. 从持久化重新加载技能到运行时
      await _loadPersistedSkills(employeeId);
    });
  }

  @override
  List<Map<String, dynamic>> getSkillsConfig() {
    // 返回当前员工的完整技能实体列表（同步方法，从缓存或本地数据库读取）
    // 注意：此处仅返回运行时已加载的技能信息，用于快速响应
    // 完整列表可通过 getSkillsConfigAsync() 异步获取
    if (_skillManager == null) return [];
    return _skillManager!.skills
        .map(
          (s) => {
            'id': s.id,
            'name': s.name,
            'description': s.description,
            'type': s.type.name,
          },
        )
        .toList();
  }

  // ===== IAgent: MCP 管理 =====

  @override
  Future<void> setMcpConfigs(List<Map<String, dynamic>> mcpConfigMaps) async {
    _touch();
    await _withLock(() async {
      final employeeStore = EmployeeStore(deviceId: deviceId);
      final skillStore = SkillStore(deviceId: deviceId);

      // 1. 更新员工实体的 MCP 配置
      final configs = mcpConfigMaps
          .map((m) => McpServerConfig.fromMap(m))
          .toList();

      // 从数据库加载当前员工实体
      final employees = await employeeStore.findAll(null);
      final employee = employees.where((e) => e.uuid == employeeId).firstOrNull;
      if (employee != null) {
        final updated = employee.setMcpConfigs(configs);
        await employeeStore.save(updated);
      }

      // 2. 同步 MCP 技能实体到 SkillStore
      // 先删除旧的 MCP 类型技能
      final existingSkills = await skillStore.findByEmployeeWithDeviceId(
        null,
        employeeId,
      );
      for (final skill in existingSkills) {
        if (skill.skillType == 'mcp') {
          await skillStore.delete(null, skill.uuid);
        }
      }
      // 为每个 MCP 配置创建技能实体
      for (final config in configs) {
        final entity = AiEmployeeSkillEntity(
          uuid: 'mcp_${config.name}_${const Uuid().v4()}',
          employeeId: employeeId,
          name: config.name,
          description: config.description,
          skillType: 'mcp',
          config: jsonEncode(config.toMap()),
          enabled: 1,
          createTime: DateTime.now(),
          updateTime: DateTime.now(),
        );
        await skillStore.save(entity);
      }

      // 3. 卸载旧的 MCP 技能并重新加载
      if (_skillManager != null) {
        final currentSkills = _skillManager!.skills.toList();
        for (final skill in currentSkills) {
          if (skill is McpSkill) {
            await _skillManager!.unloadSkill(skill.id);
          }
        }
      }

      // 4. 重新加载所有持久化技能（仅 MCP 类型）
      final allSkills = await skillStore.findByEmployeeWithDeviceId(
        null,
        employeeId,
      );
      for (final entity in allSkills) {
        if (entity.skillType != 'mcp' || entity.enabled != 1) continue;
        try {
          final skill = McpSkill.fromEntity(entity);
          await _skillManager?.loadSkill(skill);
        } catch (e) {
          print('[AgentImpl] 重新加载 MCP 技能失败: ${entity.name}, $e');
        }
      }
    });
  }

  @override
  List<Map<String, dynamic>> getMcpConfigs() {
    // 从运行时已加载的 MCP 技能中提取配置
    if (_skillManager == null) return [];
    return _skillManager!.skills
        .whereType<McpSkill>()
        .map((s) => s.serverConfig.toMap())
        .toList();
  }

  // ===== IAgent: 项目管理 =====

  @override
  Future<void> setProject(ProjectData? projectData) async {
    _touch();
    await _chatAdapter.updateProjectContext(projectData?.toMap());
  }

  @override
  String? getCurrentProjectUuid() {
    final context = _chatAdapter.currentContext;
    return context?['projectUuid'] as String?;
  }

  // ===== IAgent: 工具管理 =====

  @override
  void registerTool(AgentTool tool) {
    _toolRegistry.registerTool(tool);
  }

  @override
  void registerTools(List<AgentTool> tools) {
    _toolRegistry.registerTools(tools);
  }

  @override
  void unregisterTool(String name) {
    _toolRegistry.unregisterTool(name);
  }

  @override
  List<Map<String, dynamic>> getRegisteredTools() {
    return _toolRegistry.toMapList();
  }

  // ===== IAgent: 权限管理 =====

  @override
  Future<void> respondToPermission(
    String requestId,
    PermissionDecision decision, {
    PermissionApprovalScope scope = PermissionApprovalScope.once,
  }) async {
    final completer = _pendingPermissions[requestId];
    final request = _pendingPermissionRequests[requestId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(decision);

      // 处理持久化授权（scope > once 时将规则写入权限配置）
      if ((decision == PermissionDecision.allow ||
              decision == PermissionDecision.allowAlways) &&
          scope != PermissionApprovalScope.once &&
          request != null) {
        _persistApproval(request, scope);
      }
      // 兼容旧的 allowAlways 调用（无 scope 参数时等同 all）
      if (decision == PermissionDecision.allowAlways && request != null) {
        _persistApproval(request, PermissionApprovalScope.all);
      }

      // 广播权限响应事件
      _eventController.add(
        AgentEvent(
          type: AgentEventType.toolPermissionResponse,
          data: {
            'requestId': requestId,
            'decision': decision.name,
            'scope': scope.name,
          },
          employeeId: employeeId,
        ),
      );
    }
  }

  /// 根据审批范围持久化授权规则到权限配置
  void _persistApproval(
    AgentPermissionRequest request,
    PermissionApprovalScope scope,
  ) {
    final toolName = request.permissionType ?? request.functionName;
    final argKey = request.permissionArgKey;
    final argValue = request.permissionArgValue;
    final now = DateTime.now();

    if (scope == PermissionApprovalScope.once) return; // 不持久化

    final PermissionRule rule = switch (scope) {
      PermissionApprovalScope.exact => PermissionRule(
        tool: toolName,
        arg: argKey,
        pattern: argValue ?? '',
        mode: PermissionMatchMode.exact,
        createTime: now,
      ),
      PermissionApprovalScope.pattern => PermissionRule(
        tool: toolName,
        arg: argKey,
        pattern:
            request.suggestedPattern ??
            (argValue != null ? PermissionRule.derivePattern(argValue) : '.*'),
        mode: PermissionMatchMode.regex,
        createTime: now,
      ),
      PermissionApprovalScope.all => PermissionRule(
        tool: toolName,
        pattern: '*',
        mode: PermissionMatchMode.all,
        createTime: now,
      ),
      PermissionApprovalScope.once => PermissionRule(
        tool: toolName,
        pattern: '',
        mode: PermissionMatchMode.exact,
        createTime: now,
      ),
    };

    _permissionManager.addApproval(rule);
    print('[AgentImpl] 权限规则已添加: $rule');
  }

  // ===== IAgent: 状态查询 =====

  @override
  List<String> getCallingToolIds() {
    return List.unmodifiable(_callingToolIds);
  }

  @override
  AgentStateSnapshot getStateSnapshot() {
    return AgentStateSnapshot(
      status: _status,
      currentProcessingMessageId: _processor?.currentProcessingMessageId,
      queuedMessageIds: _processor?.queuedMessageIds ?? [],
      isStreaming: _chatAdapter.isStreaming,
      queueLength: _processor?.queueLength ?? 0,
    );
  }

  final _stateController = StreamController<AgentStateSnapshot>.broadcast();
  final _eventController = StreamController<AgentEvent>.broadcast();

  @override
  Stream<AgentStateSnapshot> get onStateChanged => _stateController.stream;

  @override
  Stream<AgentEvent> get onEvent => _eventController.stream;

  // ===== 内部方法 =====

  /// 同步处理器状态到 Agent 状态
  void _syncProcessorStatus(AgentStatus processorStatus) {
    switch (processorStatus) {
      case AgentStatus.idle:
        _setStatus(AgentStatus.idle);
        break;
      case AgentStatus.processing:
      case AgentStatus.streaming:
        _setStatus(processorStatus);
        break;
      case AgentStatus.waitingPermission:
        _setStatus(AgentStatus.waitingPermission);
        break;
      case AgentStatus.disposed:
        break;
    }
  }

  /// 设置状态并广播
  void _setStatus(AgentStatus newStatus) {
    if (_status == newStatus) return;
    _status = newStatus;

    final snapshot = getStateSnapshot();
    _stateController.add(snapshot);
    _eventController.add(
      AgentEvent(
        type: AgentEventType.agentStatusChanged,
        data: snapshot.toMap(),
        employeeId: employeeId,
      ),
    );
  }

  /// 更新最后活跃时间
  void _touch() {
    _lastActiveTime = DateTime.now();
  }

  /// 异步操作加锁
  Future<T> _withLock<T>(Future<T> Function() operation) async {
    while (_lockCompleter != null) {
      await _lockCompleter!.future;
    }

    _lockCompleter = Completer<void>();
    try {
      return await operation();
    } finally {
      final completer = _lockCompleter;
      _lockCompleter = null;
      completer?.complete();
    }
  }

  /// 注入一条 assistant 消息（不触发 LLM）
  ///
  /// 用于定时任务等场景：sub-agent 生成内容后，直接注入到主 agent 会话中。
  /// 消息会被写入 adapter session（内存）和持久化存储（SQLite），
  /// 并通过事件流广播 messageStatusChanged，让 UI 能正常收到。
  Future<void> injectAssistantMessage({
    required String messageId,
    required String content,
  }) async {
    if (_status == AgentStatus.disposed) return;

    // 1. 写入 adapter session + 持久化（等待持久化完成后再广播）
    //    【修复】确保消息已落盘、seq 已分配，避免客户端增量拉取时消息尚未持久化。
    if (_chatAdapter is PersistentChatAdapter) {
      await _chatAdapter.injectAssistantMessage(messageId, content, 'default');
    }

    // 2. 广播 completed 事件（UI 监听此事件渲染消息）
    _broadcasterBroadcastMessageStatusChange(
      messageId: messageId,
      status: AgentMessageStatus.completed,
      extraData: {'role': 'assistant', 'type': 'text', 'content': content},
    );

    _touch();
  }

  /// 触发定时任务（注入 system 消息 + 触发 LLM 处理）
  ///
  /// 1. 将任务内容以 system 消息注入到会话（role=system，持久化）
  /// 2. 发送一条 user 消息触发 LLM 处理（走完整的 streamMessage 流程）
  /// 3. 用户不会看到 system 消息和触发消息，只看到 LLM 的自然回复
  Future<String?> triggerSystemTask({
    required String taskContent,
    String? taskName,
  }) async {
    if (_status == AgentStatus.disposed) return null;
    _touch();

    // 1. 注入 system 消息（role=system，写入 session + 持久化）
    final systemMsgId = const Uuid().v4();
    final systemContent = taskName != null
        ? '【定时任务：$taskName】\n$taskContent'
        : '【定时任务触发】\n$taskContent';

    if (_chatAdapter is PersistentChatAdapter) {
      _chatAdapter.injectSystemMessage(
        systemMsgId,
        systemContent,
        'default',
      );
    }

    // 2. 发送 user 消息触发 LLM 处理（metadata 标记 trigger=scheduled_task，
    //    queued 状态会被 device_client 过滤，用户不可见）
    final userMsgId = const Uuid().v4();

    return await _withLock(() async {
      final messageData = {
        'id': userMsgId,
        'role': 'system',
        'type': 'text',
        'content': taskContent,
        'createdAt': DateTime.now().toIso8601String(),
        'metadata': {
          'trigger': 'scheduled_task',
          'scheduledSystemMessageId': systemMsgId,
        },
      };
      await _processor?.submitMessage(userMsgId, messageData);
      return userMsgId;
    });
  }

  /// 注入一条提醒类助手消息（不调用 LLM API）
  ///
  /// 用于定时提醒场景：提醒内容在创建时已预渲染，
  /// 触发时直接写入会话并广播给设备，用户看到的是一条助手消息。
  Future<String?> injectReminderMessage({
    required String content,
    String? taskName,
    String? taskId,
  }) async {
    if (_status == AgentStatus.disposed) return null;
    _touch();

    final msgId = const Uuid().v4();
    final now = DateTime.now();

    // 【修复】等待持久化完成后再广播，确保消息已落盘、seq 已分配
    if (_chatAdapter is PersistentChatAdapter) {
      await _chatAdapter.injectAssistantMessage(
        msgId,
        content,
        'system',
      );
    }

    // 广播消息状态变更（completed），与正常助手消息完成流程一致
    _broadcasterBroadcastMessageStatusChange(
      messageId: msgId,
      status: AgentMessageStatus.completed,
      extraData: {
        'role': 'assistant',
        'content': content,
        'createdAt': now.toIso8601String(),
        'metadata': {
          'trigger': 'scheduled_reminder',
          'taskName': taskName,
          'taskId': taskId,
        },
      },
    );

    // 强制广播 agentStatusChanged(idle)，触发前端刷新消息列表
    // 与正常助手消息完成后的状态变更流程一致
    // 注入消息时 Agent 本身就是 idle，_setStatus 的 guard 会阻止重复广播，
    // 所以直接通过 controller 推送，绕过 guard
    if (!_stateController.isClosed && !_eventController.isClosed) {
      final snapshot = getStateSnapshot();
      _stateController.add(snapshot);
      _eventController.add(
        AgentEvent(
          type: AgentEventType.agentStatusChanged,
          data: snapshot.toMap(),
          employeeId: employeeId,
        ),
      );
    }

    return msgId;
  }

  /// 广播消息状态变更
  void _broadcasterBroadcastMessageStatusChange({
    required String messageId,
    required AgentMessageStatus status,
    String? error,
    Map<String, dynamic> extraData = const {},
  }) {
    if (_status == AgentStatus.disposed) return;
    _eventController.add(
      AgentEvent(
        type: AgentEventType.messageStatusChanged,
        data: {
          'messageId': messageId,
          'status': status.name,
          'error': ?error,
          ...extraData,
        },
        employeeId: employeeId,
      ),
    );
  }
}