import 'package:llm_dart/llm_dart.dart' as llm;

import '../../utils/logger.dart';
import '../adapter/provider_config.dart';
import 'agent_tool.dart';

/// Anthropic 工具名正则: 仅允许 a-zA-Z0-9_-，最长 64 字符
final _anthropicToolNameRegex = RegExp(r'^[a-zA-Z0-9_-]{1,64}$');

/// 工具注册器
///
/// 管理 Agent 可用的工具集合，支持动态注册和注销。
/// 支持通过 [setExposedToolNames] 控制哪些工具对 LLM 可见（用于主 Agent 只暴露规划工具）。
class ToolRegistry {
  static final _log = Logger('ToolRegistry');
  final Map<String, AgentTool> _tools = {};

  /// 对 LLM 可见的工具名称集合。
  ///
  /// 为 null 时所有工具都可见（向后兼容）。
  /// 设置后，[getLlmDartTools] 只返回此集合中的工具。
  /// [tools] getter 和 [getTool] 不受影响，子 Agent 仍可通过它们获取所有工具。
  Set<String>? _exposedToolNames;

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

  /// 获取所有工具的 llm_dart Tool 列表
  ///
  /// 用于传递给 llm_dart ChatCapability 的 chatStream 方法。
  /// [provider] 用于 Anthropic 工具名清洗。
  ///
  /// 如果通过 [setExposedToolNames] 设置了可见工具集合，
  /// 则只返回该集合中的工具；否则返回所有已注册工具。
  List<llm.Tool> getLlmDartTools(LLMProvider provider) {
    var exposedTools = _exposedToolNames != null
        ? _tools.values.where((t) => _exposedToolNames!.contains(t.name))
        : _tools.values;

    // end 工具始终对 LLM 可见，确保 AI 能主动结束工具调用循环
    if (!exposedTools.any((t) => t.name == 'end')) {
      final endTool = _tools['end'];
      if (endTool != null) {
        exposedTools = [...exposedTools, endTool];
      }
    }

    final result = <llm.Tool>[];
    for (final t in exposedTools) {
      // 防御性校验：跳过名称为空的工具
      if (t.name.trim().isEmpty) {
        _log.warn('getLlmDartTools: 跳过名称为空的工具 (${t.runtimeType})');
        continue;
      }

      // 防御性校验：检查 inputJsonSchema 是否为空或无效
      final schema = t.inputJsonSchema;
      if (schema.isEmpty) {
        _log.warn('getLlmDartTools: 工具 "${t.name}" 的 inputJsonSchema 为空 Map, '
            '将使用默认空参数 schema');
      } else if (schema['type'] == null && schema['properties'] == null) {
        _log.warn('getLlmDartTools: 工具 "${t.name}" 的 inputJsonSchema 缺少 '
            '"type" 和 "properties" 字段: $schema');
      }

      final tool = t.toLlmDartTool();
      // 校验转换后的工具是否有效
      if (tool.function.name.trim().isEmpty) {
        _log.warn('getLlmDartTools: 跳过转换后名称为空的工具 (${t.name})');
        continue;
      }

      // 校验 parameters 是否有效 (toLlmDartTool 始终生成非 null parameters)
      final params = tool.function.parameters;

      final llmTool = provider == LLMProvider.anthropic
          ? _sanitizeToolForAnthropic(tool)
          : tool;

      _log.debug('getLlmDartTools: 注册工具 "${llmTool.function.name}" '
          '(params type=${params.schemaType}, '
          'properties=${params.properties.length})');
      result.add(llmTool);
    }
    _log.info('getLlmDartTools: 共 ${result.length} 个有效工具 (provider=$provider)');
    return result;
  }

  /// 设置对 LLM 可见的工具名称集合。
  ///
  /// 设置后，[getLlmDartTools] 只返回该集合中的工具。
  /// 传入 null 重置为所有工具可见。
  /// [tools] getter 和 [getTool] 不受影响，仍返回所有已注册工具。
  void setExposedToolNames(Set<String>? names) {
    _exposedToolNames = names != null ? Set.unmodifiable(names) : null;
  }

  /// 清洗 Tool 以满足 Anthropic 工具名规范及 schema 完整性
  ///
  /// Anthropic 要求:
  /// - 工具名: `^[a-zA-Z0-9_-]{1,64}$`
  /// - input_schema 必须包含 type:"object"、properties（可空）、required
  ///
  /// 中转平台（如 OpenRouter/OneAPI）对 schema 完整性校验更严格，
  /// 缺少 required 字段可能报 "function name or parameters is empty" 错误。
  llm.Tool _sanitizeToolForAnthropic(llm.Tool tool) {
    final originalParams = tool.function.parameters;

    // 确保 schema 完整：递归修补嵌套属性
    final sanitizedParams = _ensureSchemaComplete(originalParams);

    // llm_dart 的 Tool 是 FunctionTool，需要检查名称
    final nameOk = _anthropicToolNameRegex.hasMatch(tool.function.name);
    if (nameOk && identical(sanitizedParams, originalParams)) {
      return tool;
    }

    // 对于需要清洗的工具名，需要重新构建 Tool
    final sanitized = tool.function.name
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final finalName = sanitized.isEmpty || sanitized.length > 64
        ? 'skill_${sanitized.isEmpty ? 'unnamed' : sanitized.substring(0, 64)}'
        : sanitized;

    // 重新构建 Tool（使用清洗后的名称和 schema）
    return llm.Tool.function(
      name: finalName,
      description: tool.function.description,
      parameters: sanitizedParams,
    );
  }

  /// 确保 ParametersSchema 的 JSON 输出完整，递归修补嵌套属性。
  ///
  /// 中转平台对 schema 完整性校验严格，嵌套 object 缺少 required 字段
  /// 可能导致 "function name or parameters is empty" 错误。
  /// 此方法递归遍历所有嵌套属性，确保每个 object 类型的 items/properties
  /// 都有合法的 required 字段。
  llm.ParametersSchema _ensureSchemaComplete(llm.ParametersSchema schema) {
    bool needsRebuild = false;
    final newProperties = <String, llm.ParameterProperty>{};

    for (final entry in schema.properties.entries) {
      final sanitized = _sanitizeProperty(entry.value);
      if (!identical(sanitized, entry.value)) {
        needsRebuild = true;
      }
      newProperties[entry.key] = sanitized;
    }

    if (!needsRebuild) {
      return schema;
    }

    return llm.ParametersSchema(
      schemaType: schema.schemaType,
      properties: newProperties,
      required: schema.required,
    );
  }

  /// 递归清洗单个属性，确保嵌套 object 的 required 字段存在
  llm.ParameterProperty _sanitizeProperty(llm.ParameterProperty prop) {
    bool needsRebuild = false;

    // 递归处理 items（数组元素类型）
    llm.ParameterProperty? sanitizedItems;
    if (prop.items != null) {
      sanitizedItems = _sanitizeProperty(prop.items!);
      if (!identical(sanitizedItems, prop.items)) {
        needsRebuild = true;
      }
    }

    // 递归处理嵌套 properties（对象属性）
    Map<String, llm.ParameterProperty>? sanitizedProperties;
    if (prop.properties != null) {
      sanitizedProperties = <String, llm.ParameterProperty>{};
      for (final entry in prop.properties!.entries) {
        final sanitized = _sanitizeProperty(entry.value);
        if (!identical(sanitized, entry.value)) {
          needsRebuild = true;
        }
        sanitizedProperties[entry.key] = sanitized;
      }
    }

    if (!needsRebuild) {
      return prop;
    }

    return llm.ParameterProperty(
      propertyType: prop.propertyType,
      description: prop.description,
      items: sanitizedItems ?? prop.items,
      enumList: prop.enumList,
      properties: sanitizedProperties ?? prop.properties,
      required: prop.required,
    );
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
