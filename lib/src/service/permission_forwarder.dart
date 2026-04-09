import '../agent/agent_state.dart';
import '../agent/tool/agent_tool.dart';
import '../agent/tool/permission_manager.dart';

/// 权限转发器
///
/// 将 sub-agent 的工具权限请求转发到主 agent 的 PermissionManager 处理。
/// 用于定时任务执行场景：sub-agent 需要执行工具时，权限请求通过主 agent
/// 通知用户，用户批准/拒绝后结果回传给 sub-agent。
class PermissionForwarder extends ToolPermissionManager {
  /// 权限请求回调
  ///
  /// 由 ScheduledTaskManager 注入，将请求通过主 agent 发送给用户。
  Future<PermissionDecision> Function(AgentPermissionRequest request)?
      onForwardPermissionRequest;

  @override
  Future<PermissionDecision> checkPermission(
    AgentTool tool,
    Map<String, dynamic> arguments,
  ) async {
    if (!tool.requiresPermission) {
      return PermissionDecision.allow;
    }

    // 检查"始终允许"缓存
    final pattern = tool.permissionType;
    if (allowedAlwaysPatterns.contains(pattern)) {
      return PermissionDecision.allow;
    }

    // 没有转发回调，默认拒绝
    if (onForwardPermissionRequest == null) {
      return PermissionDecision.deny;
    }

    // 构建权限请求并转发到主 agent
    final request = AgentPermissionRequest(
      requestId: 'subagent_perm_${DateTime.now().millisecondsSinceEpoch}_${tool.name}',
      type: 'tool_execution',
      description: '定时任务 sub-agent 请求执行工具 "${tool.name}"',
      functionName: tool.name,
      permissionPattern: pattern,
      permissionType: tool.permissionType,
      data: {
        'toolName': tool.name,
        'arguments': arguments,
        'requiresPermission': tool.requiresPermission,
        'source': 'scheduled_task',
      },
    );

    final decision = await onForwardPermissionRequest!(request);

    if (decision == PermissionDecision.allowAlways) {
      // 注意：sub-agent 是临时的，allowAlways 缓存意义不大
      // 但仍加入缓存以支持同一任务执行期间的重复请求
    }

    return decision;
  }
}
