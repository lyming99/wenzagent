import 'dart:async';
import 'dart:convert';

import '../persistence/persistence.dart';
import 'employee_manager.dart';
import 'skill_manager.dart';

/// 员工配置变更类型
enum EmployeeConfigChangeType {
  basicInfo,
  provider,
  permission,
  mcp,
  mcpEnabled,
}

/// 员工配置变更事件
class EmployeeConfigChangeEvent {
  final EmployeeConfigChangeType type;
  final String employeeUuid;
  final dynamic data;

  EmployeeConfigChangeEvent({
    required this.type,
    required this.employeeUuid,
    this.data,
  });
}

/// 员工配置服务接口
///
/// 负责员工完整配置的获取和更新，包括：
/// - 基础信息（名称、头像、描述、系统提示词）
/// - Provider配置（AI提供商、模型、API密钥等）
/// - 权限配置
/// - MCP配置（支持多MCP服务）
abstract class EmployeeConfigService {
  /// 获取员工完整配置（包含基础信息、技能、权限、MCP）
  Future<EmployeeConfig> getEmployeeConfig(String employeeUuid);

  /// 更新员工基础信息
  Future<void> updateEmployeeBasicInfo(
    String employeeUuid, {
    String? name,
    String? avatar,
    String? description,
    String? systemPrompt,
  });

  /// 更新员工Provider配置
  Future<void> updateEmployeeProvider(
    String employeeUuid, {
    required String provider,
    String? model,
    String? apiKey,
    String? apiBaseUrl,
    Map<String, dynamic>? modelConfig,
  });

  /// 更新员工权限配置
  Future<void> updateEmployeePermission(
    String employeeUuid,
    Map<String, dynamic> permissionConfig,
  );

  /// 更新MCP配置列表
  Future<void> updateEmployeeMcpConfigs(
    String employeeUuid,
    List<McpServerConfig> configs,
  );

  /// 添加单个MCP服务器配置
  Future<void> addMcpServerConfig(
    String employeeUuid,
    McpServerConfig config,
  );

  /// 移除MCP服务器配置
  Future<void> removeMcpServerConfig(
    String employeeUuid,
    String serverName,
  );

  /// 更新单个MCP服务器配置
  Future<void> updateMcpServerConfig(
    String employeeUuid,
    McpServerConfig config,
  );

  /// 设置MCP总开关
  Future<void> setMcpEnabled(String employeeUuid, bool enabled);

  /// 配置变更通知流
  Stream<EmployeeConfigChangeEvent> get onConfigChanged;
}

/// 员工配置服务实现
class EmployeeConfigServiceImpl implements EmployeeConfigService {
  final EmployeeManager _employeeManager;
  final SkillManager _skillManager;
  final _changeController =
      StreamController<EmployeeConfigChangeEvent>.broadcast();

  EmployeeConfigServiceImpl({
    required EmployeeManager employeeManager,
    required SkillManager skillManager,
  })  : _employeeManager = employeeManager,
        _skillManager = skillManager;

  @override
  Future<EmployeeConfig> getEmployeeConfig(String employeeUuid) async {
    final employee = await _employeeManager.getEmployee(employeeUuid);
    if (employee == null) {
      throw StateError('Employee not found: $employeeUuid');
    }

    final skills = await _skillManager.getSkills(employeeUuid);

    Map<String, dynamic>? permissionConfig;
    if (employee.permissionConfig != null) {
      try {
        permissionConfig =
            jsonDecode(employee.permissionConfig!) as Map<String, dynamic>;
      } catch (_) {}
    }

    // 使用新的MCP配置解析方法
    final mcpConfigs = employee.getMcpConfigs();

    return EmployeeConfig(
      employee: employee,
      skills: skills,
      permissionConfig: permissionConfig,
      mcpConfigs: mcpConfigs,
    );
  }

  @override
  Future<void> updateEmployeeBasicInfo(
    String employeeUuid, {
    String? name,
    String? avatar,
    String? description,
    String? systemPrompt,
  }) async {
    final employee = await _employeeManager.getEmployee(employeeUuid);
    if (employee == null) {
      throw StateError('Employee not found: $employeeUuid');
    }
    final updated = employee.copyWith(
      name: name,
      avatar: avatar,
      description: description,
      systemPrompt: systemPrompt,
    );
    await _employeeManager.updateEmployee(updated);
    _notifyChange(EmployeeConfigChangeType.basicInfo, employeeUuid);
  }

  @override
  Future<void> updateEmployeeProvider(
    String employeeUuid, {
    required String provider,
    String? model,
    String? apiKey,
    String? apiBaseUrl,
    Map<String, dynamic>? modelConfig,
  }) async {
    final employee = await _employeeManager.getEmployee(employeeUuid);
    if (employee == null) {
      throw StateError('Employee not found: $employeeUuid');
    }
    final updated = employee.copyWith(
      provider: provider,
      model: model,
      apiKey: apiKey,
      apiBaseUrl: apiBaseUrl,
      modelConfig: modelConfig != null ? jsonEncode(modelConfig) : null,
    );
    await _employeeManager.updateEmployee(updated);
    _notifyChange(EmployeeConfigChangeType.provider, employeeUuid);
  }

  @override
  Future<void> updateEmployeePermission(
    String employeeUuid,
    Map<String, dynamic> permissionConfig,
  ) async {
    final employee = await _employeeManager.getEmployee(employeeUuid);
    if (employee == null) {
      throw StateError('Employee not found: $employeeUuid');
    }
    final updated = employee.copyWith(
      permissionConfig: jsonEncode(permissionConfig),
    );
    await _employeeManager.updateEmployee(updated);
    _notifyChange(EmployeeConfigChangeType.permission, employeeUuid);
  }

  @override
  Future<void> updateEmployeeMcpConfigs(
    String employeeUuid,
    List<McpServerConfig> configs,
  ) async {
    final employee = await _employeeManager.getEmployee(employeeUuid);
    if (employee == null) {
      throw StateError('Employee not found: $employeeUuid');
    }
    final updated = employee.setMcpConfigs(configs);
    await _employeeManager.updateEmployee(updated);
    _notifyChange(EmployeeConfigChangeType.mcp, employeeUuid, data: configs);
  }

  @override
  Future<void> addMcpServerConfig(
    String employeeUuid,
    McpServerConfig config,
  ) async {
    final employeeConfig = await getEmployeeConfig(employeeUuid);
    final configs = List<McpServerConfig>.from(employeeConfig.mcpConfigs);

    // 检查是否已存在同名配置
    final existingIndex = configs.indexWhere((c) => c.name == config.name);
    if (existingIndex >= 0) {
      throw ArgumentError('MCP server config with name "${config.name}" already exists');
    }

    configs.add(config);
    await updateEmployeeMcpConfigs(employeeUuid, configs);
  }

  @override
  Future<void> removeMcpServerConfig(
    String employeeUuid,
    String serverName,
  ) async {
    final employeeConfig = await getEmployeeConfig(employeeUuid);
    final configs = List<McpServerConfig>.from(employeeConfig.mcpConfigs);
    configs.removeWhere((c) => c.name == serverName);
    await updateEmployeeMcpConfigs(employeeUuid, configs);
  }

  @override
  Future<void> updateMcpServerConfig(
    String employeeUuid,
    McpServerConfig config,
  ) async {
    final employeeConfig = await getEmployeeConfig(employeeUuid);
    final configs = List<McpServerConfig>.from(employeeConfig.mcpConfigs);
    final index = configs.indexWhere((c) => c.name == config.name);
    if (index < 0) {
      throw ArgumentError('MCP server config with name "${config.name}" not found');
    }
    configs[index] = config;
    await updateEmployeeMcpConfigs(employeeUuid, configs);
  }

  @override
  Future<void> setMcpEnabled(String employeeUuid, bool enabled) async {
    final employee = await _employeeManager.getEmployee(employeeUuid);
    if (employee == null) {
      throw StateError('Employee not found: $employeeUuid');
    }
    final updated = employee.copyWith(
      enableMcp: enabled ? 1 : 0,
    );
    await _employeeManager.updateEmployee(updated);
    _notifyChange(EmployeeConfigChangeType.mcpEnabled, employeeUuid, data: enabled);
  }

  @override
  Stream<EmployeeConfigChangeEvent> get onConfigChanged =>
      _changeController.stream;

  void _notifyChange(
    EmployeeConfigChangeType type,
    String employeeUuid, {
    dynamic data,
  }) {
    _changeController.add(EmployeeConfigChangeEvent(
      type: type,
      employeeUuid: employeeUuid,
      data: data,
    ));
  }

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}

/// 员工配置（完整配置信息）
class EmployeeConfig {
  final AiEmployeeEntity employee;
  final List<AiEmployeeSkillEntity> skills;
  final Map<String, dynamic>? permissionConfig;
  final List<McpServerConfig> mcpConfigs;

  EmployeeConfig({
    required this.employee,
    required this.skills,
    this.permissionConfig,
    this.mcpConfigs = const [],
  });
}
