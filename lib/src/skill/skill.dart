import '../agent/tool/agent_tool.dart';

/// 技能状态
enum SkillStatus {
  /// 未初始化
  uninitialized,

  /// 初始化中
  initializing,

  /// 已激活
  active,

  /// 错误
  error,

  /// 已销毁
  disposed,
}

/// 技能类型
enum SkillType {
  /// Type 1: MCP 标准协议
  mcp,

  /// Type 2: 文件夹配置
  folder,

  /// Type 3: 名称/描述/内容配置
  config,
}

/// 技能接口
///
/// 核心契约：每个 Skill 产出一组 [AgentTool]，
/// 注册到 ToolRegistry 后由 LLM function calling 驱动。
abstract class Skill {
  /// 技能唯一标识
  String get id;

  /// 技能名称
  String get name;

  /// 技能描述
  String get description;

  /// 技能类型
  SkillType get type;

  /// 当前状态
  SkillStatus get status;

  /// 产出的工具列表（注册到 ToolRegistry）
  List<AgentTool> get tools;

  /// 初始化（连接远程服务、加载配置等）
  Future<void> initialize();

  /// 激活（注册工具前调用）
  Future<void> activate();

  /// 停用（注销工具前调用）
  Future<void> deactivate();

  /// 销毁（释放所有资源）
  Future<void> dispose();

  /// 健康检查
  Future<bool> healthCheck();
}
