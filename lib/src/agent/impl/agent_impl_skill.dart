part of 'agent_impl.dart';

/// 技能相关方法 mixin
mixin _AgentImplSkill on _AgentImplBase {
  // ===== Folder Skill 文件同步辅助方法 =====

  /// 计算动态路径: skillsDir + skill.name
  String _resolveFolderSkillPath(String skillName) {
    String skillsDirPath;
    try {
      final dc = DeviceClient.getInstance(deviceId);
      skillsDirPath = dc.skillsDir;
    } catch (_) {
      skillsDirPath = p.join('skills', 'folder');
    }
    return p.normalize(p.absolute(p.join(skillsDirPath, skillName)));
  }

  /// 确保 folder skill 本地数据存在（三级获取策略）
  ///
  /// 优先级：
  /// 1. 有 globalSkillId → 查 GlobalSkill → 本地有文件夹 → 直接复制
  /// 2. GlobalSkill 本地无数据 → 从 LAN 拉取 GlobalSkill → 再复制
  /// 3. globalSkillId 为空/GlobalSkill 已删除 → 降级从 LAN 拉取员工 skill
  ///
  /// 返回 true 表示数据已就绪，false 表示获取失败。
  Future<bool> _ensureFolderSkillData(AiEmployeeSkillEntity entity) async {
    final targetPath = _resolveFolderSkillPath(entity.name);

    // 本地已存在，直接返回
    if (await Directory(targetPath).exists()) {
      _AgentImplBase._log.debug('Folder Skill 本地已存在: ${entity.name} -> $targetPath');
      return true;
    }

    final dsm = DataSyncManager.getInstance(deviceId);

    // ===== 第一级：从 GlobalSkill 本地文件夹复制 =====
    if (entity.globalSkillId != null && entity.globalSkillId!.isNotEmpty) {
      final gsm = GlobalSkillManager.getInstance(deviceId);
      final globalSkill = await gsm.getSkill(entity.globalSkillId!);

      if (globalSkill != null && globalSkill.deleted == 0) {
        final globalPath = _resolveFolderSkillPath(globalSkill.name);

        if (await Directory(globalPath).exists()) {
          // GlobalSkill 本地有数据 → 直接复制
          _AgentImplBase._log.info('Folder Skill 从 GlobalSkill 本地复制: ${globalSkill.name} -> ${entity.name}');
          try {
            await _copyDirectory(globalPath, targetPath);
            _AgentImplBase._log.info('Folder Skill 复制成功: $targetPath');
            return true;
          } catch (e) {
            _AgentImplBase._log.error('Folder Skill 复制失败: ${entity.name}', e);
          }
        }

        // ===== 第二级：从局域网拉取 GlobalSkill 数据 =====
        _AgentImplBase._log.info('Folder Skill GlobalSkill 本地无数据, 从 LAN 拉取: ${globalSkill.name}');
        final syncedPath = await dsm.syncSingleFolderSkill(
          globalSkill.uuid,
          globalSkill.name,
          originName: entity.originName ?? globalSkill.name,
        );
        if (syncedPath != null) {
          // 如果 GlobalSkill name == 员工 skill name，路径相同，无需复制
          if (p.normalize(p.absolute(syncedPath)) == p.normalize(p.absolute(targetPath))) {
            _AgentImplBase._log.info('Folder Skill GlobalSkill LAN 同步路径与目标一致, 无需复制: $targetPath');
            return true;
          }
          // GlobalSkill 拉取成功 → 复制到员工 skill 路径
          try {
            await _copyDirectory(syncedPath, targetPath);
            _AgentImplBase._log.info('Folder Skill 从 GlobalSkill LAN 同步后复制成功: $targetPath');
            return true;
          } catch (e) {
            _AgentImplBase._log.error('Folder Skill 从 GlobalSkill 复制失败: ${entity.name}', e);
          }
        }
      } else {
        _AgentImplBase._log.info('Folder Skill GlobalSkill 不存在或已删除 (globalSkillId=${entity.globalSkillId}), 降级为员工 skill 同步');
      }
    }

    // ===== 第三级：降级为员工 skill 从局域网拉取 =====
    _AgentImplBase._log.info('Folder Skill 降级为员工 skill LAN 同步: ${entity.name}');
    final result = await dsm.syncSingleFolderSkill(entity.uuid, entity.name, originName: entity.originName);
    if (result != null) {
      _AgentImplBase._log.info('Folder Skill 员工 skill LAN 同步成功: ${entity.name} -> $result');
      return true;
    }

    _AgentImplBase._log.warn('Folder Skill 所有获取策略均失败: ${entity.name}');
    return false;
  }

  /// 递归复制目录
  Future<void> _copyDirectory(String source, String target) async {
    final sourceDir = Directory(source);
    final targetDir = Directory(target);
    if (await targetDir.exists()) {
      await targetDir.delete(recursive: true);
    }
    await targetDir.create(recursive: true);

    await for (final entity in sourceDir.list(recursive: true)) {
      final relativePath = p.relative(entity.path, from: source);
      final targetPath = p.join(target, relativePath);
      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
      } else if (entity is File) {
        await File(targetPath).parent.create(recursive: true);
        await entity.copy(targetPath);
      }
    }
  }
  /// 推送 folder skill 数据到目标设备
  ///
  /// 当员工在其他设备上时，通过 RPC 触发目标设备同步 folder skill 文件。
  /// 异步执行，不阻塞 setSkills 流程。
  Future<void> _pushFolderSkillToDevice(
    AiEmployeeSkillEntity entity,
    String targetDeviceId,
  ) async {
    try {
      final dc = DeviceClient.getInstance(deviceId);
      // 通过 RPC 通道触发目标设备的 DataSyncManager 同步
      // 目标设备收到后自行执行三级获取策略
      await dc.invokeFileRpc(
        toDeviceId: targetDeviceId,
        method: 'syncFolderSkillFiles',
        params: {
          'skillId': entity.uuid,
          'skillName': entity.name,
          'globalSkillId': entity.globalSkillId,
        },
      );
      _AgentImplBase._log.info('推送 Folder Skill 成功: ${entity.name} -> device=$targetDeviceId');
    } catch (e) {
      _AgentImplBase._log.error('推送 Folder Skill 失败: ${entity.name} -> device=$targetDeviceId', e);
    }
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
    _eventController.add(AgentEvent(
      type: AgentEventType.configChanged,
      data: {'configType': 'skills', 'action': 'added', 'skillId': skill.id},
      employeeId: employeeId,
    ));
  }

  /// 运行时移除技能
  Future<void> removeSkill(String skillId) async {
    await _skillManager?.unloadSkill(skillId);
    _eventController.add(AgentEvent(
      type: AgentEventType.configChanged,
      data: {'configType': 'skills', 'action': 'removed', 'skillId': skillId},
      employeeId: employeeId,
    ));
  }

  /// 运行时重新加载技能
  Future<void> reloadSkill(String skillId) async {
    await _skillManager?.reloadSkill(skillId);
    _eventController.add(AgentEvent(
      type: AgentEventType.configChanged,
      data: {'configType': 'skills', 'action': 'reloaded', 'skillId': skillId},
      employeeId: employeeId,
    ));
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

    final entities = await store.findByEmployee(employeeId);
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
          // 动态计算路径: skillsDir + skill.name
          final folderPath = _resolveFolderSkillPath(entity.name);
          _AgentImplBase._log.info('Folder 技能动态路径: ${entity.name} -> $folderPath, globalSkillId=${entity.globalSkillId}');

          if (!await Directory(folderPath).exists()) {
            _AgentImplBase._log.info('Folder 技能本地路径不存在, 执行三级获取策略: ${entity.name}');
            final success = await _ensureFolderSkillData(entity);
            if (!success) {
              _AgentImplBase._log.warn('Folder 技能数据获取失败, 跳过: ${entity.name}');
              skipped++;
              break;
            }
          }

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
    // 从 DeviceClient 获取可配置的 skillsDir（由 storagePath 推导）
    String skillsDirPath;
    try {
      final dc = DeviceClient.getInstance(deviceId);
      skillsDirPath = dc.skillsDir;
    } catch (_) {
      skillsDirPath = p.join('skills', 'folder');
    }
    // 规范化路径，避免 storagePath 以 './' 开头时拼接出 'D:\project\wenzagent./data\skills' 这样的非法路径
    skillsDirPath = p.normalize(p.absolute(skillsDirPath));
    _AgentImplBase._log.info('扫描 Folder Skill: skillsDirPath=$skillsDirPath');
    final skillsDir = Directory(skillsDirPath);
    if (!await skillsDir.exists()) {
      _AgentImplBase._log.info('扫描 Folder Skill: 目录不存在, path=${Directory(skillsDirPath).absolute.path}');
      return;
    }

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
    _AgentImplBase._log.info('setSkills: 收到 ${skillMaps.length} 个技能配置');
    for (int i = 0; i < skillMaps.length; i++) {
      final m = skillMaps[i];
      _AgentImplBase._log.debug(
        'setSkills[$i]: uuid=${m['uuid']}, name=${m['name']}, '
        'skillType=${m['skillType']}, globalSkillId=${m['globalSkillId']}, '
        'enabled=${m['enabled']}, deleted=${m['deleted']}',
      );
    }
    await _withLock(() async {
      final store = SkillStore(deviceId: deviceId);

      // 1. 软删除当前员工的所有技能（不按 deviceId 隔离）
      _AgentImplBase._log.debug('setSkills: 步骤1 - 软删除当前员工的所有技能, employeeId=$employeeId');
      final existingSkills = await store.findByEmployee(employeeId);
      _AgentImplBase._log.debug('setSkills: 找到 ${existingSkills.length} 个现有技能');
      for (final skill in existingSkills) {
        _AgentImplBase._log.debug('setSkills: 软删除 skill uuid=${skill.uuid}, name=${skill.name}');
        await store.delete(skill.uuid);
      }

      // 2. 保存新的技能列表（直接 save，不覆盖 deviceId）
      _AgentImplBase._log.debug('setSkills: 步骤2 - 保存 ${skillMaps.length} 个新技能');
      final entities = skillMaps
          .map((m) => AiEmployeeSkillEntity.fromMap(m))
          .toList();
      for (int i = 0; i < entities.length; i++) {
        final entity = entities[i];
        _AgentImplBase._log.debug(
          'setSkills: 保存 skill[$i]: uuid=${entity.uuid}, name=${entity.name}, '
          'skillType=${entity.skillType}, globalSkillId=${entity.globalSkillId}',
        );
        try {
          await store.save(entity);
          _AgentImplBase._log.debug('setSkills: skill[$i] 保存成功');
        } catch (e, st) {
          _AgentImplBase._log.error('setSkills: skill[$i] 保存失败: uuid=${entity.uuid}, name=${entity.name}', e, st);
          rethrow;
        }
      }

      // 3. 卸载当前运行时技能
      _AgentImplBase._log.debug('setSkills: 步骤3 - 卸载当前运行时技能');
      if (_skillManager != null) {
        final currentSkills = _skillManager!.skills.toList();
        _AgentImplBase._log.debug('setSkills: 当前运行时技能数=${currentSkills.length}');
        for (final skill in currentSkills) {
          _AgentImplBase._log.debug('setSkills: 卸载 skill: id=${skill.id}, name=${skill.name}');
          await _skillManager!.unloadSkill(skill.id);
        }
      }

      // 4. 对 folder 类型技能, 确保数据就绪
      //    本设备: 执行三级获取策略
      //    远端设备: 通过 RPC 触发目标设备同步
      final folderEntities = entities.where((e) => e.skillType == 'folder' && e.enabled == 1);
      if (folderEntities.isNotEmpty) {
        // 获取员工所在设备ID
        final employeeStore = EmployeeStore(deviceId: deviceId);
        final employees = await employeeStore.findAll(null);
        final employee = employees.where((e) => e.uuid == employeeId).firstOrNull;
        final targetDeviceId = employee?.currentDeviceId;

        for (final entity in folderEntities) {
          if (targetDeviceId != null && targetDeviceId != deviceId) {
            // 员工在其他设备上，异步触发目标设备同步
            _AgentImplBase._log.info(
              'setSkills: Folder 技能需推送到远端设备, '
              'skill=${entity.name}, targetDevice=$targetDeviceId',
            );
            _pushFolderSkillToDevice(entity, targetDeviceId);
          } else {
            // 员工在本设备上，执行三级获取策略（异步，不阻塞重新加载）
            final folderPath = _resolveFolderSkillPath(entity.name);
            if (!await Directory(folderPath).exists()) {
              _AgentImplBase._log.info('setSkills: Folder 技能本地路径不存在, 触发三级获取: ${entity.name}');
              _ensureFolderSkillData(entity);
            }
          }
        }
      }

      // 5. 从持久化重新加载技能到运行时
      _AgentImplBase._log.debug('setSkills: 步骤5 - 从持久化重新加载技能到运行时');
      await _loadPersistedSkills(employeeId);
      _AgentImplBase._log.info('setSkills: 完成');
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
      final existingSkills = await skillStore.findByEmployee(
        employeeId,
      );
      for (final skill in existingSkills) {
        if (skill.skillType == 'mcp') {
          await skillStore.delete(skill.uuid);
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
      final allSkills = await skillStore.findByEmployee(
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
    String? customPattern,
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
        _persistApproval(request, scope, customPattern: customPattern);
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
    PermissionApprovalScope scope, {
    String? customPattern,
  }) {
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
            customPattern ??
            request.suggestedPattern ??
            (argValue != null
                ? PermissionRule.derivePattern(argValue,
                    permissionType: request.permissionType)
                : '.*'),
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
