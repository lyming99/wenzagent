import 'package:langchain_core/tools.dart';

import 'agent_tool.dart';

/// 工具注册器
///
/// 管理 Agent 可用的工具集合，支持动态注册和注销。
class ToolRegistry {
  final Map<String, AgentTool> _tools = {};

  /// 注册单个工具
  ///
  /// 如果已存在同名工具，抛出 [ArgumentError]。
  void registerTool(AgentTool tool) {
    if (_tools.containsKey(tool.name)) {
      throw ArgumentError('工具 "${tool.name}" 已注册，不能重复注册');
    }
    _tools[tool.name] = tool;
  }

  /// 批量注册工具
  void registerTools(List<AgentTool> tools) {
    for (final tool in tools) {
      registerTool(tool);
    }
  }

  /// 注销工具
  void unregisterTool(String name) {
    _tools.remove(name);
  }

  /// 根据名称查找工具
  AgentTool? getTool(String name) {
    return _tools[name];
  }

  /// 获取所有已注册工具
  List<AgentTool> get tools => _tools.values.toList();

  /// 获取所有工具名称
  List<String> get toolNames => _tools.keys.toList();

  /// 注册或覆盖工具（技能热更新时使用）
  ///
  /// 如果已存在同名工具，直接替换；否则新增。
  void registerOrReplaceTool(AgentTool tool) {
    _tools[tool.name] = tool;
  }

  /// 是否包含指定工具
  bool contains(String name) => _tools.containsKey(name);

  /// 已注册工具数量
  int get length => _tools.length;

  /// 是否为空
  bool get isEmpty => _tools.isEmpty;

  /// 获取所有工具的 LangChain ToolSpec 列表
  ///
  /// 用于传递给各 LLM 提供商的 options.tools
  List<ToolSpec> get toolSpecs {
    return _tools.values.map((t) => t.toToolSpec()).toList();
  }

  /// 转换为 JSON 序列化列表（用于 RPC）
  List<Map<String, dynamic>> toMapList() {
    return _tools.values.map((t) => t.toMap()).toList();
  }

  /// 清空所有工具
  void clear() {
    _tools.clear();
  }
}
