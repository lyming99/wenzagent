import 'dart:async';

import '../agent_state.dart';
import 'agent_tool.dart';
import 'permission_rule.dart';

/// 权限请求处理回调
///
/// 当工具需要权限确认时调用，返回用户的权限决策。
typedef PermissionRequestHandler =
    Future<PermissionDecision> Function(AgentPermissionRequest request);

/// 工具权限管理器
///
/// 负责在工具执行前进行权限检查，集成规则引擎与用户确认流程。
///
/// 决策链：
/// 1. 工具不需要权限 → 直接 allow
/// 2. 黑名单命中 → 直接 deny（安全策略阻止）
/// 3. 白名单命中 → 直接 allow
/// 4. allowAlways 缓存命中 → 直接 allow
/// 5. 调用 [onPermissionRequest] 回调等待用户决策
class ToolPermissionManager {
  /// 已记住的"始终允许"权限类型集合（向后兼容）
  final Set<String> _allowedAlwaysPatterns = {};

  /// 权限配置（白名单/黑名单规则）
  PermissionConfig? _config;

  /// 权限请求处理回调（由 AgentImpl 设置）
  PermissionRequestHandler? onPermissionRequest;

  /// 配置变更回调（规则被添加/移除时触发，由 AgentFactory 注入用于持久化）
  void Function(PermissionConfig newConfig)? onConfigChanged;

  /// 最近一次拒绝的原因（null 表示非黑名单拒绝，即用户拒绝）
  String? lastDenyMessage;

  /// 获取当前权限配置
  PermissionConfig? get config => _config;

  /// 注入权限配置（从 [AiEmployeeEntity.permissionConfig] 解析）
  void configure(PermissionConfig config) {
    _config = config;
    // 先清空缓存，再从新配置重建（防止删除规则后旧缓存残留）
    _allowedAlwaysPatterns.clear();
    for (final rule in config.whitelist) {
      if (rule.mode == PermissionMatchMode.all) {
        _allowedAlwaysPatterns.add(rule.tool);
      }
    }
  }

  /// 获取当前配置的 JSON 字符串（用于持久化）
  String? get configJson => _config?.toJsonString();

  /// 检查工具执行权限
  ///
  /// 返回权限决策结果。流程：
  /// 1. 不需要权限 → allow
  /// 2. 黑名单命中 → deny（[lastDenyMessage] 会设置拒绝原因）
  /// 3. 白名单命中 → allow
  /// 4. allowAlways 缓存 → allow
  /// 5. 调用 [onPermissionRequest] 等待用户决策
  Future<PermissionDecision> checkPermission(
    AgentTool tool,
    Map<String, dynamic> arguments,
  ) async {
    lastDenyMessage = null;
    // return PermissionDecision.allow;

    // 不需要权限的工具直接放行
    if (!tool.requiresPermission) {
      return PermissionDecision.allow;
    }

    final toolName = tool.permissionType;

    // 规则引擎判定（仅当配置存在时）
    if (_config != null) {
      final verdict = _config!.evaluate(toolName, arguments);

      if (verdict == PermissionVerdict.deny) {
        final argValue = tool.permissionArgKey != null
            ? arguments[tool.permissionArgKey] as String?
            : null;
        lastDenyMessage =
            '权限被拒绝: 安全策略阻止了工具 "${tool.name}" 的执行'
            '${argValue != null ? ' (参数: $argValue)' : ''}';
        return PermissionDecision.deny;
      }

      if (verdict == PermissionVerdict.allow) {
        return PermissionDecision.allow;
      }

      // verdict == ask → 继续走用户确认流程
    }

    // 检查"始终允许"缓存
    if (_allowedAlwaysPatterns.contains(toolName)) {
      return PermissionDecision.allow;
    }

    // 没有权限请求处理器，默认拒绝
    if (onPermissionRequest == null) {
      return PermissionDecision.deny;
    }

    // 构建权限请求（包含参数信息用于 UI 展示 4 个选项）
    final argKey = tool.permissionArgKey;
    final argValue = argKey != null ? arguments[argKey] as String? : null;
    final suggestedPattern = argValue != null
        ? PermissionRule.derivePattern(argValue, permissionType: toolName)
        : null;

    final request = AgentPermissionRequest(
      requestId:
          'perm_${DateTime.now().millisecondsSinceEpoch}_${tool.name}',
      type: 'tool_execution',
      description: '工具 "${tool.name}" 请求执行权限',
      functionName: tool.name,
      permissionPattern: toolName,
      permissionType: toolName,
      permissionArgKey: argKey,
      permissionArgValue: argValue,
      suggestedPattern: suggestedPattern,
      data: {
        'toolName': tool.name,
        'arguments': arguments,
        'requiresPermission': tool.requiresPermission,
      },
    );

    // 等待用户决策
    final decision = await onPermissionRequest!(request);

    // 如果用户选择"始终允许"，加入缓存
    if (decision == PermissionDecision.allowAlways) {
      _allowedAlwaysPatterns.add(toolName);
    }

    return decision;
  }

  /// 添加授权规则（用户确认后将规则持久化到配置）
  ///
  /// 根据 [scope] 创建对应类型的规则并加入白名单。
  void addApproval(PermissionRule rule) {
    _config ??= PermissionConfig.empty();
    _config = _config!.addWhitelistRule(rule);

    // 仅 all 模式加入 always 缓存
    if (rule.mode == PermissionMatchMode.all) {
      _allowedAlwaysPatterns.add(rule.tool);
    }

    // 通知配置变更
    onConfigChanged?.call(_config!);
  }

  /// 移除授权规则
  void removeApproval(PermissionRule rule) {
    if (_config == null) return;

    final inWhitelist = _config!.whitelist.contains(rule);
    final inBlacklist = _config!.blacklist.contains(rule);

    if (inWhitelist) {
      _config = _config!.removeWhitelistRule(rule);
      // 从缓存中移除该工具（无论 mode，确保一致性）
      _allowedAlwaysPatterns.remove(rule.tool);
      // 安全兜底：从当前白名单重建缓存，防止残留
      _rebuildAllowedAlwaysCache();
    } else if (inBlacklist) {
      _config = _config!.removeBlacklistRule(rule);
    }

    onConfigChanged?.call(_config!);
  }

  /// 清除"始终允许"缓存
  void clearAllowedAlways() {
    _allowedAlwaysPatterns.clear();
  }

  /// 获取当前"始终允许"的权限模式列表
  Set<String> get allowedAlwaysPatterns =>
      Set.unmodifiable(_allowedAlwaysPatterns);

  /// 从当前白名单重建 _allowedAlwaysPatterns 缓存
  ///
  /// 确保缓存与 _config.whitelist 中 all 模式规则完全一致。
  void _rebuildAllowedAlwaysCache() {
    _allowedAlwaysPatterns.clear();
    if (_config == null) return;
    for (final rule in _config!.whitelist) {
      if (rule.mode == PermissionMatchMode.all) {
        _allowedAlwaysPatterns.add(rule.tool);
      }
    }
  }
}
