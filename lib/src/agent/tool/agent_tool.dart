import 'package:llm_dart/llm_dart.dart' as llm;

import '../../utils/logger.dart';

final _log = Logger('AgentTool');

/// 工具执行结果
class ToolResult {
  /// 返回给 LLM 的文本内容
  final String content;

  /// 是否为错误结果
  final bool isError;

  /// 额外元数据（不发给 LLM，用于事件广播等）
  final Map<String, dynamic>? metadata;

  const ToolResult({
    required this.content,
    this.isError = false,
    this.metadata,
  });

  /// 创建成功结果
  factory ToolResult.success(String content, {Map<String, dynamic>? metadata}) {
    return ToolResult(content: content, isError: false, metadata: metadata);
  }

  /// 创建错误结果
  factory ToolResult.error(String content, {Map<String, dynamic>? metadata}) {
    return ToolResult(content: content, isError: true, metadata: metadata);
  }

  Map<String, dynamic> toMap() {
    return {
      'content': content,
      'isError': isError,
      if (metadata != null) 'metadata': metadata,
    };
  }

  factory ToolResult.fromMap(Map<String, dynamic> map) {
    return ToolResult(
      content: map['content'] as String? ?? '',
      isError: map['isError'] as bool? ?? false,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Agent 工具基类
///
/// 所有工具必须继承此类并实现 [execute] 方法。
/// 通过 [toLlmDartTool] 转换为 llm_dart 的 Tool 传递给 LLM。
abstract class AgentTool {
  /// 工具唯一标识名称（如 file_read, command_execute）
  String get name;

  /// 工具描述，LLM 根据此描述决定何时使用
  String get description;

  /// 工具输入参数的 JSON Schema 定义
  Map<String, dynamic> get inputJsonSchema;

  /// 是否需要权限确认才能执行
  bool get requiresPermission => false;

  /// 权限类型分类标识（用于权限分组）
  String get permissionType => name;

  /// 权限检查时要匹配的参数 key（如 "path", "command"）
  ///
  /// 仅对需要权限的工具有意义。用于白名单/黑名单规则匹配具体参数值。
  /// 返回 null 表示不检查参数，仅匹配工具名/权限类型。
  String? get permissionArgKey => null;

  /// 执行工具
  ///
  /// [arguments] 为 LLM 传递的参数（已解析的 JSON Map）
  Future<ToolResult> execute(Map<String, dynamic> arguments);

  /// 取消工具执行
  ///
  /// 默认实现为空，子类可以重写此方法以支持取消长时间运行的操作。
  /// 例如：命令执行工具可以杀死正在运行的进程。
  void cancel() {
    // 默认空实现，子类可重写
  }

  /// 转换为 llm_dart Tool
  ///
  /// 将 [inputJsonSchema] 转换为 llm_dart 的 [ParametersSchema]。
  /// Anthropic provider 要求 schema.type 必须为 "object"。
  ///
  /// 防御性处理：即使 [inputJsonSchema] 为空或格式异常，
  /// 也会生成一个合法的空参数 schema（`{"type":"object","properties":{}}`），
  /// 避免 LLM API 报 "parameters is empty" 错误。
  llm.Tool toLlmDartTool() {
    // 防御性校验：工具名不能为空
    if (name.trim().isEmpty) {
      _log.warn('toLlmDartTool: 工具名为空 ($runtimeType), 使用 fallback 名称');
    }
    final toolName = name.trim().isEmpty ? 'unnamed_tool_${hashCode.toRadixString(36)}' : name;

    final schema = inputJsonSchema;

    // 防御性校验：schema 为空时记录警告
    if (schema.isEmpty) {
      _log.warn('toLlmDartTool: 工具 $toolName 的 inputJsonSchema 为空');
    }

    final propertiesRaw = schema['properties'] as Map<String, dynamic>? ?? {};
    final requiredList = (schema['required'] as List?)?.cast<String>() ?? [];

    final properties = <String, llm.ParameterProperty>{};
    for (final entry in propertiesRaw.entries) {
      final propSchema = entry.value;
      // 防御性校验：跳过非 Map 类型的属性定义
      if (propSchema is! Map<String, dynamic>) {
        _log.warn('toLlmDartTool: 工具 $toolName 的属性 "${entry.key}" 的 schema 不是 Map, 跳过');
        continue;
      }
      properties[entry.key] = _parseParameterProperty(propSchema);
    }

    // 确保 schemaType 有效（某些 API 要求必须为 "object"）
    final schemaType = schema['type'] as String?;
    if (schemaType == null || schemaType.trim().isEmpty) {
      _log.debug('toLlmDartTool: 工具 $toolName 的 schema.type 为空, 使用默认 "object"');
    }
    final effectiveSchemaType = (schemaType != null && schemaType.trim().isNotEmpty)
        ? schemaType
        : 'object';

    return llm.Tool.function(
      name: toolName,
      // 确保 description 不为 null，某些 API 不接受空 description
      description: description.isEmpty ? '$toolName tool' : description,
      parameters: llm.ParametersSchema(
        schemaType: effectiveSchemaType,
        properties: properties,
        required: requiredList,
      ),
    );
  }

  /// 解析 JSON Schema 属性为 llm_dart ParameterProperty
  static llm.ParameterProperty _parseParameterProperty(Map<String, dynamic> schema) {
    final typeStr = schema['type'] as String? ?? 'string';
    final description = schema['description'] as String? ?? '';
    final enumList = (schema['enum'] as List?)?.cast<String>();
    final itemsSchema = schema['items'] as Map<String, dynamic>?;
    final propertiesSchema = schema['properties'] as Map<String, dynamic>?;
    final requiredList = (schema['required'] as List?)?.cast<String>();

    llm.ParameterProperty? items;
    if (itemsSchema != null) {
      items = _parseParameterProperty(itemsSchema);
    }

    Map<String, llm.ParameterProperty>? properties;
    if (propertiesSchema != null) {
      properties = propertiesSchema.map(
        (key, value) => MapEntry(key, _parseParameterProperty(value as Map<String, dynamic>)),
      );
    }

    return llm.ParameterProperty(
      propertyType: typeStr,
      description: description,
      enumList: enumList,
      items: items,
      properties: properties,
      required: requiredList,
    );
  }

  /// 转换为 JSON Map（用于 RPC 序列化）
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'inputJsonSchema': inputJsonSchema,
      'requiresPermission': requiresPermission,
      'permissionType': permissionType,
      if (permissionArgKey != null) 'permissionArgKey': permissionArgKey,
    };
  }
}
