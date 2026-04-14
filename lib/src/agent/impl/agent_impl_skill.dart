part of 'agent_impl.dart';

/// 技能相关方法 mixin
mixin _AgentImplSkill on _AgentImplBase {
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
    _AgentImplBase._log.info('开始初始化技能系统, employeeId=$employeeId');

    final context = SkillContext(
      toolRegistry: _toolRegistry,
      employeeId: employeeId,
      invokeLlm: (prompt) => _chatAdapter.invokeOnce(prompt),
      logger: (level, msg) => _AgentImplBase._log.debug('[$level] $msg'),
    );

    _skillManager = SkillLifecycleManager(context);

    // 从数据库加载 Type 1 (mcp) 和 Type 3 (config) 技能
    await _loadPersistedSkills(employeeId);

    // 扫描文件夹加载 Type 2 (folder) 技能
    await _scanFolderSkills(context);

    _enableSkills = true;
    _AgentImplBase._log.info('技能系统初始化完成');
  }

  /// 从数据库加载持久化技能
  Future<void> _loadPersistedSkills(String employeeId) async {
    final store = SkillStore(deviceId: deviceId);
    _AgentImplBase._log.debug('开始加载持久化技能, employeeId=$employeeId');

    final entities = await store.findByEmployeeWithDeviceId(deviceId, employeeId);
    _AgentImplBase._log.debug('数据库查询完成, 共 ${entities.length} 条技能记录');

    int loaded = 0;
    int skipped = 0;
    int failed = 0;

    for (final entity in entities) {
      _AgentImplBase._log.debug(
        '处理技能: uuid=${entity.uuid}, name=${entity.name}, '
        'type=${entity.skillType}, enabled=${entity.enabled}, '
        'config=${entity.config?.substring(0, entity.config!.length > 80 ? 80 : entity.config!.length)}',
      );

      if (entity.enabled != 1) {
        _AgentImplBase._log.debug('跳过已禁用技能: ${entity.name}');
        skipped++;
        continue;
      }

      Skill? skill;
      switch (entity.skillType) {
        case 'mcp':
          try {
            skill = McpSkill.fromEntity(entity);
            _AgentImplBase._log.info('MCP 技能实体创建成功: ${entity.name}');
          } catch (e) {
            _AgentImplBase._log.error('MCP 技能实体创建失败: ${entity.name}', e);
          }
          break;
        case 'config':
          try {
            skill = ConfigSkill.fromEntity(entity);
            _AgentImplBase._log.info('Config 技能实体创建成功: ${entity.name}');
          } catch (e) {
            _AgentImplBase._log.error('Config 技能实体创建失败: ${entity.name}', e);
          }
          break;
        case 'folder':
          String? folderPath;
          try {
            final configMap =
                jsonDecode(entity.config!) as Map<String, dynamic>;
            folderPath = configMap['folder_path'] as String?;
          } catch (e) {
            _AgentImplBase._log.debug('failed to parse folder skill config as JSON, using raw config: $e');
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
                logger: (level, msg) => _AgentImplBase._log.debug('[$level] $msg'),
              ),
            );
            skill = s;
            _AgentImplBase._log.info('Folder 技能实体创建成功: ${entity.name}, path=$folderPath');
          } else {
            _AgentImplBase._log.debug('Folder 技能跳过(无路径): ${entity.name}');
          }
          break;
        default:
          _AgentImplBase._log.warn('未知技能类型: ${entity.skillType}, name=${entity.name}');
          break;
      }

      if (skill != null) {
        try {
          await _skillManager!.loadSkill(skill);
          _AgentImplBase._log.info('技能加载并激活成功: ${entity.name}');
          loaded++;
        } catch (e, st) {
          _AgentImplBase._log.error('技能加载失败: ${entity.name}', e, st);
          failed++;
        }
      }
    }

    _AgentImplBase._log.info('持久化技能加载完成: 成功=$loaded, 跳过=$skipped, 失败=$failed');
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
        _AgentImplBase._log.error('文件夹加载失败: ${entity.path}', e);
      }
    }
  }

  // ===== IAgent: 技能管理 =====

  @override
  Future<void> setSkills(List<Map<String, dynamic>> skillMaps) async {
    _touch();
    await _withLock(() async {
      final store = SkillStore(deviceId: deviceId);

      // 1. 软删除当前员工的所有技能
      final existingSkills = await store.findByEmployeeWithDeviceId(
        deviceId,
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
        await store.saveWithDeviceId(deviceId, entity);
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
        deviceId,
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
        await skillStore.saveWithDeviceId(deviceId, entity);
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
        deviceId,
        employeeId,
      );
      for (final entity in allSkills) {
        if (entity.skillType != 'mcp' || entity.enabled != 1) continue;
        try {
          final skill = McpSkill.fromEntity(entity);
          await _skillManager?.loadSkill(skill);
        } catch (e) {
          _AgentImplBase._log.error('重新加载 MCP 技能失败: ${entity.name}', e);
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
    _AgentImplBase._log.debug('权限规则已添加: $rule');
  }
}
