# wenzagent 三种 Skill 系统完整设计方案

## 一、设计总览

### 1.1 核心原则

**所有 Skill 统一产出 `AgentTool`，注册到现有 `ToolRegistry`，由 LLM function calling 驱动。**

不对 `LangChainChatAdapter`、`AgentTool`、`ToolRegistry`、`ToolPermissionManager` 做任何结构性修改。Skill 系统作为一个独立模块，通过 `AgentImpl.initialize()` 集成。

### 1.2 三种 Skill 类型

| 类型 | 入口 | prompt 来源 | 执行方式 | 适用场景 |
|------|------|-------------|----------|----------|
| Type 1: MCP Skill | `AiEmployeeSkillEntity.config` (JSON) | 无 prompt，LLM 直接调用 | MCP 协议 → 远程服务器 | 外部工具集成：GitHub、数据库、API |
| Type 2: Folder Skill | `SKILL.md` 或 `skill.yaml` (文件系统) | prompt 文件，execute 时读取 | prompt 模板 + 参数 → LLM invokeOnce | 复杂 prompt 技能：代码审查、数据分析 |
| Type 3: Config Skill | `AiEmployeeSkillEntity.config` (JSON) | prompt 模板存储在 config 字段 | prompt 模板 + 参数 → LLM invokeOnce | 轻量自定义技能：翻译、摘要、格式化 |

### 1.3 Prompt 动态加载核心机制

```
注册时（发给 LLM 的 tools 参数）：
  只有 name + description + inputJsonSchema
  ⚠️ prompt 内容永远不会出现在 tools 定义中

执行时（LLM 选择工具后才触发）：
  Type 1: MCP 客户端调用远程服务器，无 prompt
  Type 2: 读取 prompt 文件 → 注入参数 → invokeOnce() → 返回结果
  Type 3: 读取 config 中的 prompt → 注入参数 → invokeOnce() → 返回结果
```

### 1.4 架构总图

```
┌──────────────────────────────────────────────────────────────┐
│                     AgentImpl                                │
│                                                              │
│  initialize()                                                 │
│    ├── _toolRegistry.registerTools(BuiltinTools.all())       │
│    ├── _chatAdapter.setToolRegistry(_toolRegistry)            │
│    └── _initSkillSystem()  ← 新增                            │
│         ├── SkillContext 创建                                 │
│         ├── SkillManager 创建                                 │
│         ├── 从 Hive 加载 Type 1 / Type 3 技能                │
│         └── 扫描文件夹加载 Type 2 技能                        │
│                                                              │
│  运行时 API（新增）                                           │
│    ├── addSkill(Skill)                                       │
│    ├── removeSkill(String skillId)                           │
│    └── reloadSkill(String skillId)                           │
├──────────────────────────────────────────────────────────────┤
│                    SkillManager                               │
│                                                              │
│  loadSkill(Skill)                                             │
│    ├── skill.initialize()                                    │
│    ├── skill.activate()                                      │
│    ├── for tool in skill.tools:                              │
│    │     _toolRegistry.registerTool(tool)  ← 注册到现有注册器 │
│    └── emit SkillEvent                                       │
│                                                              │
│  unloadSkill(String skillId)                                 │
│    ├── for tool in skill.tools:                              │
│    │     _toolRegistry.unregisterTool(tool.name)              │
│    ├── skill.deactivate()                                    │
│    └── skill.dispose()                                       │
├──────────────────────────────────────────────────────────────┤
│                    Skill 实现                                 │
│                                                              │
│  McpSkill          FolderSkill          ConfigSkill          │
│  (Type 1)          (Type 2)             (Type 3)             │
│    │                  │                    │                  │
│    ▼                  ▼                    ▼                  │
│  _McpToolAdapter   _FolderToolAdapter   _ConfigToolAdapter  │
│  extends AgentTool  extends AgentTool   extends AgentTool   │
│                                                              │
│  三者统一实现 AgentTool 接口                                  │
│  → toToolSpec() 只返回 name + description + inputJsonSchema  │
│  → execute(arguments) 在 LLM 选择工具时才触发                 │
├──────────────────────────────────────────────────────────────┤
│                    现有系统（不修改）                          │
│                                                              │
│  ToolRegistry        ToolPermissionManager                    │
│  LangChainChatAdapter (streamMessage / invokeOnce)           │
│  CancellableToolExecutor                                      │
│  AiEmployeeSkillEntity / SkillStore / SkillManagerImpl        │
└──────────────────────────────────────────────────────────────┘
```

## 二、新增文件清单

```
lib/src/skill/
├── skill.dart                        # Skill 接口 + 枚举
├── skill_context.dart                # SkillContext 共享上下文
├── skill_manager.dart                # SkillManager 统一管理
├── mcp/
│   ├── mcp_skill.dart                # Type 1 实现
│   └── mcp_tool_adapter.dart         # MCP → AgentTool 适配器
├── folder/
│   ├── folder_skill.dart             # Type 2 实现
│   ├── skill_md_parser.dart          # SKILL.md / skill.yaml 解析器
│   └── folder_tool_adapter.dart      # Folder → AgentTool 适配器
└── config/
    ├── config_skill.dart             # Type 3 实现
    └── config_tool_adapter.dart      # Config → AgentTool 适配器

修改文件：
├── lib/src/agent/impl/agent_impl.dart       # initialize 增加 Skill 加载
├── lib/src/agent/tool/tool_registry.dart    # 新增 registerOrReplaceTool
├── lib/wenzagent.dart                       # 新增 skill 模块导出
```

## 三、新增依赖

```yaml
# pubspec.yaml 新增
dependencies:
  yaml: ^3.1.2   # SKILL.md frontmatter 解析（Type 2 需要）
```

## 四、核心接口定义

### 4.1 Skill 接口

```dart
// lib/src/skill/skill.dart

/// 技能状态
enum SkillStatus {
  uninitialized,
  initializing,
  active,
  error,
  disposed,
}

/// 技能类型
enum SkillType {
  mcp,    // Type 1: MCP 标准协议
  folder, // Type 2: 文件夹配置
  config, // Type 3: 名称/描述/内容配置
}

/// 技能接口
///
/// 核心契约：每个 Skill 产出一组 [AgentTool]，
/// 注册到 ToolRegistry 后由 LLM function calling 驱动。
abstract class Skill {
  String get id;
  String get name;
  String get description;
  SkillType get type;
  SkillStatus get status;

  /// 产出的工具列表（注册到 ToolRegistry）
  List<AgentTool> get tools;

  /// 生命周期
  Future<void> initialize();
  Future<void> activate();
  Future<void> deactivate();
  Future<void> dispose();
  Future<bool> healthCheck();
}
```

### 4.2 SkillContext

```dart
// lib/src/skill/skill_context.dart

/// 技能上下文 —— 提供技能运行所需的共享资源
///
/// 通过 [invokeLlm] 将 Type 2/Type 3 的 prompt 交给 LLM 处理。
/// 该回调来自 LangChainChatAdapter.invokeOnce()。
class SkillContext {
  final ToolRegistry toolRegistry;
  final String employeeId;

  /// 一次性 LLM 调用（不保留对话历史）
  /// Type 2/Type 3 的工具执行时使用
  final Future<String> Function(String prompt) invokeLlm;

  /// 日志
  final void Function(String level, String message) logger;

  SkillContext({
    required this.toolRegistry,
    required this.employeeId,
    required this.invokeLlm,
    required this.logger,
  });
}
```

### 4.3 SkillManager

```dart
// lib/src/skill/skill_manager.dart

/// 技能变更事件
class SkillEvent {
  final String skillId;
  final String type;       // 'added' | 'removed' | 'reloaded' | 'error'
  final dynamic data;

  SkillEvent({required this.skillId, required this.type, this.data});
}

/// 技能管理器
///
/// 统一管理三种 Skill 的加载、激活、卸载。
/// 核心职责：将 Skill 产出的 AgentTool 注册/注销到 ToolRegistry。
class SkillManager {
  final SkillContext _context;
  final Map<String, Skill> _skills = {};
  final _eventController = StreamController<SkillEvent>.broadcast();

  SkillManager(this._context);

  /// 加载并激活技能
  Future<void> loadSkill(Skill skill) async {
    try {
      await skill.initialize();
      await skill.activate();

      for (final tool in skill.tools) {
        if (_context.toolRegistry.contains(tool.name)) {
          _context.toolRegistry.registerOrReplaceTool(tool);
        } else {
          _context.toolRegistry.registerTool(tool);
        }
      }

      _skills[skill.id] = skill;
      _eventController.add(SkillEvent(
        skillId: skill.id,
        type: 'added',
        data: {'name': skill.name, 'toolCount': skill.tools.length},
      ));
    } catch (e) {
      _context.logger('error', '技能加载失败: ${skill.name}, $e');
      _eventController.add(SkillEvent(
        skillId: skill.id, type: 'error', data: {'error': e.toString()},
      ));
      rethrow;
    }
  }

  /// 卸载技能
  Future<void> unloadSkill(String skillId) async {
    final skill = _skills.remove(skillId);
    if (skill == null) return;

    for (final tool in skill.tools) {
      _context.toolRegistry.unregisterTool(tool.name);
    }
    await skill.deactivate();
    await skill.dispose();

    _eventController.add(SkillEvent(
      skillId: skillId, type: 'removed',
    ));
  }

  /// 重新加载技能
  Future<void> reloadSkill(String skillId) async {
    final skill = _skills[skillId];
    if (skill == null) return;

    // 注销旧工具
    for (final tool in skill.tools) {
      _context.toolRegistry.unregisterTool(tool.name);
    }
    await skill.deactivate();
    await skill.dispose();

    // 重新初始化
    await skill.initialize();
    await skill.activate();

    for (final tool in skill.tools) {
      _context.toolRegistry.registerOrReplaceTool(tool);
    }

    _eventController.add(SkillEvent(skillId: skillId, type: 'reloaded'));
  }

  List<Skill> get skills => _skills.values.toList();
  Skill? getSkill(String id) => _skills[id];
  Stream<SkillEvent> get onEvent => _eventController.stream;

  void dispose() {
    for (final skill in _skills.values) {
      skill.dispose();
    }
    _skills.clear();
    _eventController.close();
  }
}
```

## 五、Type 1：MCP Skill 实现

### 5.1 执行原理

```
技能加载：
  AiEmployeeSkillEntity.config → JSON 解析 → McpServerConfig
  → 创建 McpClient → connect() → listTools()
  → 每个 MCP 工具包装为 _McpToolAdapter

工具执行（LLM 选择工具后）：
  _McpToolAdapter.execute(arguments)
  → McpClient.callTool(toolName, arguments)
  → MCP 服务器执行
  → 返回结果

LLM 调用次数：1 次（主循环，无二次调用）
```

### 5.2 McpClient 接口

```dart
// lib/src/skill/mcp/mcp_client.dart

/// MCP 工具定义（从服务器获取）
class McpToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
}

/// MCP 工具调用结果
class McpToolCallResult {
  final String content;
  final bool isError;
  McpToolCallResult({required this.content, this.isError = false});
}

/// MCP 客户端接口
abstract class McpClient {
  Future<void> connect();
  Future<void> disconnect();
  Future<List<McpToolDefinition>> listTools();
  Future<McpToolCallResult> callTool(String name, Map<String, dynamic> arguments);
  Future<bool> ping();
}
```

### 5.3 McpSkill

```dart
// lib/src/skill/mcp/mcp_skill.dart

class McpSkill implements Skill {
  final String _id;
  final String _name;
  final String _description;
  final McpServerConfig _serverConfig;

  SkillStatus _status = SkillStatus.uninitialized;
  List<AgentTool> _tools = [];
  McpClient? _client;

  McpSkill({
    required String id,
    required String name,
    required String description,
    required McpServerConfig serverConfig,
  })  : _id = id, _name = name, _description = description,
        _serverConfig = serverConfig;

  @override String get id => _id;
  @override String get name => _name;
  @override String get description => _description;
  @override SkillType get type => SkillType.mcp;
  @override SkillStatus get status => _status;
  @override List<AgentTool> get tools => _tools;

  @override
  Future<void> initialize() async {
    _status = SkillStatus.initializing;
    try {
      _client = McpClientFactory.create(_serverConfig);
      await _client!.connect();
      final mcpTools = await _client!.listTools();
      _tools = mcpTools.map((t) => _McpToolAdapter(
        client: _client!, definition: t,
      )).toList();
      _status = SkillStatus.active;
    } catch (e) {
      _status = SkillStatus.error;
      rethrow;
    }
  }

  @override Future<void> activate() async {}
  @override Future<void> deactivate() async => await _client?.disconnect();
  @override Future<void> dispose() async {
    await _client?.disconnect();
    _client = null;
    _tools.clear();
    _status = SkillStatus.disposed;
  }
  @override Future<bool> healthCheck() async {
    if (_client == null) return false;
    try { return await _client!.ping(); } catch (_) { return false; }
  }

  /// 从 AiEmployeeSkillEntity 创建
  static McpSkill fromEntity(AiEmployeeSkillEntity entity) {
    final configs = McpServerConfig.parseList(entity.config);
    return McpSkill(
      id: entity.uuid,
      name: entity.name,
      description: entity.description ?? '',
      serverConfig: configs.first,
    );
  }
}
```

### 5.4 McpToolAdapter

```dart
// lib/src/skill/mcp/mcp_tool_adapter.dart

class _McpToolAdapter extends AgentTool {
  final McpClient client;
  final McpToolDefinition definition;

  _McpToolAdapter({required this.client, required this.definition});

  @override
  String get name => 'mcp_${definition.name}';

  @override
  String get description => definition.description;

  @override
  Map<String, dynamic> get inputJsonSchema => definition.inputSchema;

  @override
  bool get requiresPermission => true;

  @override
  String get permissionType => 'mcp';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    try {
      final result = await client.callTool(definition.name, arguments);
      return result.isError
          ? ToolResult.error(result.content)
          : ToolResult.success(result.content);
    } catch (e) {
      return ToolResult.error('MCP 工具执行失败: $e');
    }
  }
}
```

### 5.5 AiEmployeeSkillEntity.config 格式

```json
[
  {
    "name": "filesystem",
    "transportType": "stdio",
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/dir"],
    "env": {}
  }
]
```

## 六、Type 2：Folder Skill 实现

### 6.1 执行原理

```
技能加载：
  扫描 skills/ 目录 → 找到 SKILL.md 或 skill.yaml
  → 解析 frontmatter → 得到工具定义列表
  → 创建 _FolderToolAdapter（记录 promptFile 路径，不读取内容）

工具注册（发给 LLM）：
  toToolSpec() → 只有 name + description + inputJsonSchema
  ⚠️ prompt 模板不进入 tools 参数

工具执行（LLM 选择工具后）：
  _FolderToolAdapter.execute(arguments)
  → _resolvePrompt(arguments)       ← 此时才读磁盘
    → 优先级 1: prompt/xxx.md       ← 独立 prompt 文件
    → 优先级 2: SKILL.md 正文       ← frontmatter 之后的 Markdown
    → 优先级 3: toolDef.description ← 兜底
  → 注入参数 {{变量}} → 实际值
  → 注入资源文件 resources/xxx（可选）
  → invokeOnce(完整prompt)          ← 内部 LLM 调用
  → 返回 ToolResult

LLM 调用次数：2 次（主循环 1 次 + invokeOnce 内部 1 次）
```

### 6.2 文件夹结构

```
skills/folder/code_review/
├── SKILL.md                    # 入口（Claude 兼容）
├── prompt/                     # 独立 prompt 模板（可选）
│   ├── review_security.md
│   └── review_performance.md
└── resources/                  # 参考资源（可选）
    └── security_checklist.md
```

### 6.3 SKILL.md 格式（Claude 兼容）

```markdown
---
name: code_review
description: 代码审查技能，支持安全和性能两个维度
version: 1.0.0
tags: [code, review, security]
tools:
  - name: review_security
    description: 审查代码安全问题
    prompt_file: review_security.md
    resource_file: security_checklist.md
    requires_permission: false
    parameters:
      type: object
      properties:
        code:
          type: string
          description: 待审查的代码
        language:
          type: string
          description: 编程语言
          default: dart
      required: [code]
  - name: review_performance
    description: 审查代码性能问题
    prompt_file: review_performance.md
    requires_permission: false
    parameters:
      type: object
      properties:
        code:
          type: string
          description: 待审查的代码
      required: [code]
---

# 代码审查技能

## 通用审查规则（当工具未指定 prompt_file 时使用）

1. 检查代码逻辑是否正确
2. 检查异常处理是否完善
3. 检查命名规范

以上规则适用于所有审查类型。
```

### 6.4 skill.yaml 格式（向后兼容）

```yaml
name: code_review
description: 代码审查技能
version: 1.0.0
tools:
  - name: review_security
    description: 审查代码安全问题
    prompt: review_security.md
    resource: security_checklist.md
    parameters:
      type: object
      properties:
        code: { type: string }
      required: [code]
```

### 6.5 纯 Markdown 格式（最简）

```markdown
# 代码摘要

请对以下代码生成简洁摘要：

{{code}}
```

无 frontmatter 时自动推断：
- `name` = 目录名
- `description` = 第一段标题或正文开头
- `tools` = 自动生成一个默认工具，`name = 目录名`，`parameters = { content: string }`

### 6.6 SkillMdParser

```dart
// lib/src/skill/folder/skill_md_parser.dart

/// 解析结果
class SkillMdDocument {
  final Map<String, dynamic> frontmatter;
  final String body;
  SkillMdDocument({required this.frontmatter, required this.body});
}

class SkillMdParser {
  /// 解析文件内容，自动判断格式
  static SkillMdDocument parse(String content) {
    final trimmed = content.trim();

    // 有 frontmatter
    if (trimmed.startsWith('---')) {
      final endIndex = trimmed.indexOf('\n---', 3);
      if (endIndex != -1) {
        final yamlStr = trimmed.substring(3, endIndex).trim();
        final frontmatter = loadYaml(yamlStr) as Map<String, dynamic>;
        final body = trimmed.substring(endIndex + 4).trim();
        return SkillMdDocument(frontmatter: frontmatter, body: body);
      }
    }

    // 纯 Markdown（无 frontmatter）
    return SkillMdDocument(
      frontmatter: {'_raw': true},  // 标记为纯 Markdown
      body: trimmed,
    );
  }
}
```

### 6.7 FolderSkill

```dart
// lib/src/skill/folder/folder_skill.dart

class FolderSkill implements Skill {
  final String _path;
  final String _id;
  late final FolderSkillConfig _config;
  List<AgentTool> _tools = [];
  SkillStatus _status = SkillStatus.uninitialized;
  SkillContext? _context;

  FolderSkill({required String path, required String id})
      : _path = path, _id = id;

  @override String get id => _id;
  @override String get name => _config.name;
  @override String get description => _config.description;
  @override SkillType get type => SkillType.folder;
  @override SkillStatus get status => _status;
  @override List<AgentTool> get tools => _tools;

  void setContext(SkillContext context) => _context = context;

  @override
  Future<void> initialize() async {
    _status = SkillStatus.initializing;
    try {
      _config = await _loadConfig();
      _tools = _config.tools.map((toolDef) => _FolderToolAdapter(
        skillPath: _path,
        toolDef: toolDef,
        promptBody: _config.promptBody,
        invokeLlm: _context!.invokeLlm,
      )).toList();
      _status = SkillStatus.active;
    } catch (e) {
      _status = SkillStatus.error;
      rethrow;
    }
  }

  /// 加载配置 —— 兼容三种入口格式
  Future<FolderSkillConfig> _loadConfig() async {
    final skillMd = File('$_path/SKILL.md');
    final skillYaml = File('$_path/skill.yaml');

    if (await skillMd.exists()) {
      final content = await skillMd.readAsString();
      final doc = SkillMdParser.parse(content);
      return FolderSkillConfig.fromDocument(doc, _path);
    }
    if (await skillYaml.exists()) {
      final content = await skillYaml.readAsString();
      final doc = SkillMdParser.parse(content);
      return FolderSkillConfig.fromDocument(doc, _path);
    }

    throw FileSystemException('缺少入口文件（SKILL.md 或 skill.yaml）', _path);
  }

  @override Future<void> activate() async {}
  @override Future<void> deactivate() async {}
  @override Future<void> dispose() async {
    _tools.clear();
    _status = SkillStatus.disposed;
  }
  @override Future<bool> healthCheck() async =>
      await File('$_path/SKILL.md').exists()
      || await File('$_path/skill.yaml').exists();
}
```

### 6.8 FolderToolAdapter

```dart
// lib/src/skill/folder/folder_tool_adapter.dart

class _FolderToolAdapter extends AgentTool {
  final String _skillPath;
  final FolderToolDef _toolDef;
  final String _promptBody;   // SKILL.md 正文
  final Future<String> Function(String) _invokeLlm;

  // 缓存
  String? _cachedPrompt;
  DateTime? _cachedAt;
  static const _cacheTtlSeconds = 30;

  _FolderToolAdapter({
    required String skillPath,
    required FolderToolDef toolDef,
    required String promptBody,
    required Future<String> Function(String) invokeLlm,
  })  : _skillPath = skillPath,
        _toolDef = toolDef,
        _promptBody = promptBody,
        _invokeLlm = invokeLlm;

  @override String get name => _toolDef.name;
  @override String get description => _toolDef.description;
  @override Map<String, dynamic> get inputJsonSchema => _toolDef.parameters;
  @override bool get requiresPermission => _toolDef.requiresPermission;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    try {
      final prompt = await _resolvePrompt(arguments);
      final result = await _invokeLlm(prompt);
      return ToolResult.success(result);
    } catch (e) {
      return ToolResult.error('技能执行失败: $e');
    }
  }

  Future<String> _resolvePrompt(Map<String, dynamic> arguments) async {
    String prompt;

    // 优先级 1：独立 prompt 文件
    if (_toolDef.promptFile != null) {
      prompt = await _loadCachedFile('$_skillPath/prompt/${_toolDef.promptFile}');
    }
    // 优先级 2：SKILL.md 正文
    else if (_promptBody.isNotEmpty) {
      prompt = _promptBody;
    }
    // 优先级 3：兜底描述
    else {
      prompt = _toolDef.description;
    }

    // 注入参数
    for (final entry in arguments.entries) {
      prompt = prompt.replaceAll('{{${entry.key}}}', entry.value.toString());
    }

    // 注入资源文件
    if (_toolDef.resourceFile != null) {
      final resource = await _loadCachedFile(
        '$_skillPath/resources/${_toolDef.resourceFile}',
      );
      if (resource.isNotEmpty) {
        prompt = '$prompt\n\n---\n参考资料:\n$resource';
      }
    }

    return prompt;
  }

  Future<String> _loadCachedFile(String path) async {
    // 检查缓存
    if (_cachedPrompt != null && _cachedAt != null) {
      if (DateTime.now().difference(_cachedAt!).inSeconds < _cacheTtlSeconds) {
        return _cachedPrompt!;
      }
    }
    final file = File(path);
    if (!await file.exists()) return '';
    _cachedPrompt = await file.readAsString();
    _cachedAt = DateTime.now();
    return _cachedPrompt!;
  }
}
```

### 6.9 AiEmployeeSkillEntity 存储格式

```
skillType: "folder"
config: "skills/folder/code_review"    ← 文件夹路径字符串
```

## 七、Type 3：Config Skill 实现

### 7.1 执行原理

```
技能加载：
  AiEmployeeSkillEntity.config → JSON 解析
  → 提取 prompt 模板 + parameters
  → 创建 _ConfigToolAdapter

工具执行（LLM 选择工具后）：
  _ConfigToolAdapter.execute(arguments)
  → prompt 模板 + 参数注入 {{变量}}
  → invokeOnce(完整prompt)
  → 返回 ToolResult

最轻量：一个数据库配置 = 一个工具，无需文件系统
```

### 7.2 ConfigSkill

```dart
// lib/src/skill/config/config_skill.dart

class ConfigSkill implements Skill {
  final String _id;
  final String _name;
  final String _description;
  final String _promptTemplate;
  final Map<String, dynamic> _parameters;
  final bool _requiresPermission;

  SkillStatus _status = SkillStatus.uninitialized;
  late _ConfigToolAdapter _tool;
  SkillContext? _context;

  ConfigSkill({
    required String id,
    required String name,
    required String description,
    required String promptTemplate,
    Map<String, dynamic> parameters = const {},
    bool requiresPermission = false,
  })  : _id = id, _name = name, _description = description,
        _promptTemplate = promptTemplate, _parameters = parameters,
        _requiresPermission = requiresPermission;

  @override String get id => _id;
  @override String get name => _name;
  @override String get description => _description;
  @override SkillType get type => SkillType.config;
  @override SkillStatus get status => _status;
  @override List<AgentTool> get tools => [_tool];

  void setContext(SkillContext context) => _context = context;

  @override
  Future<void> initialize() async {
    _status = SkillStatus.initializing;
    _tool = _ConfigToolAdapter(
      name: 'cfg_${_id.substring(0, 8)}',
      description: _description,
      inputSchema: _parameters,
      promptTemplate: _promptTemplate,
      requiresPermission: _requiresPermission,
      invokeLlm: _context!.invokeLlm,
    );
    _status = SkillStatus.active;
  }

  @override Future<void> activate() async {}
  @override Future<void> deactivate() async {}
  @override Future<void> dispose() async => _status = SkillStatus.disposed;
  @override Future<bool> healthCheck() async => _status == SkillStatus.active;

  /// 从 AiEmployeeSkillEntity 创建
  static ConfigSkill fromEntity(AiEmployeeSkillEntity entity) {
    final configMap = entity.config != null
        ? jsonDecode(entity.config!) as Map<String, dynamic>
        : <String, dynamic>{};

    return ConfigSkill(
      id: entity.uuid,
      name: entity.name,
      description: entity.description ?? '',
      promptTemplate: configMap['prompt'] as String? ?? '',
      parameters: Map<String, dynamic>.from(configMap['parameters'] ?? {}),
      requiresPermission: configMap['requires_permission'] as bool? ?? false,
    );
  }
}
```

### 7.3 ConfigToolAdapter

```dart
// lib/src/skill/config/config_tool_adapter.dart

class _ConfigToolAdapter extends AgentTool {
  final String _promptTemplate;
  final Future<String> Function(String) _invokeLlm;

  _ConfigToolAdapter({
    required super.name,
    required super.description,
    required super.inputSchema,
    required super.requiresPermission,
    required String promptTemplate,
    required Future<String> Function(String) invokeLlm,
  })  : _promptTemplate = promptTemplate,
        _invokeLlm = invokeLlm;

  @override
  String get permissionType => 'config_skill';

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    try {
      var prompt = _promptTemplate;
      for (final entry in arguments.entries) {
        prompt = prompt.replaceAll('{{${entry.key}}}', entry.value.toString());
      }
      final result = await _invokeLlm(prompt);
      return ToolResult.success(result);
    } catch (e) {
      return ToolResult.error('配置技能执行失败: $e');
    }
  }
}
```

### 7.4 AiEmployeeSkillEntity.config 格式

```json
{
  "prompt": "你是一位专业翻译。请将以下内容翻译为{{target_lang}}：\n\n{{content}}",
  "parameters": {
    "type": "object",
    "properties": {
      "source_lang": { "type": "string", "default": "auto" },
      "target_lang": { "type": "string" },
      "content": { "type": "string" }
    },
    "required": ["target_lang", "content"]
  },
  "requires_permission": false
}
```

## 八、AgentImpl 集成

### 8.1 ToolRegistry 小改

```dart
// lib/src/agent/tool/tool_registry.dart 新增方法

/// 注册或覆盖工具（技能热更新时使用）
void registerOrReplaceTool(AgentTool tool) {
  _tools[tool.name] = tool;
}
```

### 8.2 AgentImpl 改动

```dart
// lib/src/agent/impl/agent_impl.dart 新增

class AgentImpl implements IAgent {
  // 新增字段
  SkillManager? _skillManager;
  bool _enableSkills = false;

  /// 是否启用技能系统
  bool get isSkillEnabled => _enableSkills;

  /// 获取技能管理器
  SkillManager? get skillManager => _skillManager;

  @override
  Future<void> initialize({
    String? employeeId,
    bool enableBuiltinTools = true,
    bool enableSkills = false,           // 新增参数，默认关闭
  }) async {
    // ... 现有初始化代码（不动） ...

    // 注册内置工具
    if (enableBuiltinTools) {
      _toolRegistry.registerTools(BuiltinTools.all());
    }

    // 初始化技能系统
    if (enableSkills) {
      await _initSkillSystem(employeeId ?? this.employeeId);
    }

    // ... 后续代码（不动） ...
  }

  Future<void> _initSkillSystem(String employeeId) async {
    final context = SkillContext(
      toolRegistry: _toolRegistry,
      employeeId: employeeId,
      invokeLlm: (prompt) => _chatAdapter.invokeOnce(prompt),
      logger: (level, msg) => print('[Skill][$level] $msg'),
    );

    _skillManager = SkillManager(context);

    // 从 Hive 加载 Type 1 (mcp) 和 Type 3 (config) 技能
    await _loadPersistedSkills(employeeId);

    // 扫描文件夹加载 Type 2 (folder) 技能
    await _scanFolderSkills(context);

    _enableSkills = true;
  }

  /// 从数据库加载技能
  Future<void> _loadPersistedSkills(String employeeId) async {
    final store = SkillStore();
    final entities = await store.findByEmployeeWithDeviceId(null, employeeId);

    for (final entity in entities) {
      if (entity.enabled != 1) continue;

      Skill? skill;
      switch (entity.skillType) {
        case 'mcp':
          skill = McpSkill.fromEntity(entity);
          break;
        case 'config':
          skill = ConfigSkill.fromEntity(entity);
          break;
        case 'folder':
          final folderPath = entity.config;
          if (folderPath != null) {
            final s = FolderSkill(path: folderPath, id: entity.uuid);
            s.setContext(SkillContext(
              toolRegistry: _toolRegistry,
              employeeId: employeeId,
              invokeLlm: (prompt) => _chatAdapter.invokeOnce(prompt),
              logger: (level, msg) => print('[Skill][$level] $msg'),
            ));
            skill = s;
          }
          break;
      }

      if (skill != null) {
        try { await _skillManager!.loadSkill(skill); }
        catch (e) { print('[Skill] 加载失败: ${entity.name}, $e'); }
      }
    }
  }

  /// 扫描文件夹技能
  Future<void> _scanFolderSkills(SkillContext context) async {
    final skillsDir = Directory('skills/folder');
    if (!await skillsDir.exists()) return;

    await for (final entity in skillsDir.list()) {
      if (entity is! Directory) continue;
      final skill = FolderSkill(path: entity.path, id: entity.path);
      skill.setContext(context);
      try { await _skillManager!.loadSkill(skill); }
      catch (e) { print('[Skill] 文件夹加载失败: ${entity.path}, $e'); }
    }
  }

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

  @override
  Future<void> dispose() async {
    await _skillManager?.dispose();
    // ... 现有 dispose 代码（不动） ...
  }
}
```

### 8.3 AgentFactory 改动

```dart
// lib/src/service/agent_factory.dart

// getOrCreateAgent 中 initialize 调用增加参数：
await agent.initialize(
  employeeId: employeeId,
  enableSkills: true,  // 新增
);
```

### 8.4 导出

```dart
// lib/wenzagent.dart 新增
export 'src/skill/skill.dart';
export 'src/skill/skill_context.dart';
export 'src/skill/skill_manager.dart';
export 'src/skill/mcp/mcp_skill.dart';
export 'src/skill/mcp/mcp_client.dart';
export 'src/skill/folder/folder_skill.dart';
export 'src/skill/folder/skill_md_parser.dart';
export 'src/skill/config/config_skill.dart';
```

## 九、LLM 完整调用时序

### 9.1 Type 1：MCP Skill（1 次 LLM 调用）

```
用户: "查询北京天气"
  │
  ├─[LangChainChatAdapter.streamMessage]
  │   构建 options.tools（含 mcp_get_weather 的 name/description/schema）
  │   │
  │   ├─ LLM 调用 → 选择 mcp_get_weather({location:"北京"})
  │   │
  │   ├─[_McpToolAdapter.execute]
  │   │   McpClient.callTool("get_weather", {"location":"北京"})
  │   │   → MCP 服务器执行 → 返回 "晴 25°C"
  │   │
  │   ├─ ToolResult("晴 25°C") 加入 messages
  │   │
  │   └─ LLM 调用 → "北京今天天气晴朗，温度 25°C"
  │
  └─ 返回给用户
```

### 9.2 Type 2：Folder Skill（2 次 LLM 调用）

```
用户: "帮我审查这段代码的安全性"
  │
  ├─[LangChainChatAdapter.streamMessage]
  │   构建 options.tools（含 review_security 的 name/description/schema）
  │   ⚠️ prompt 模板不在 tools 中
  │   │
  │   ├─ LLM 调用 ① → 选择 review_security({code:"..."})
  │   │
  │   ├─[_FolderToolAdapter.execute]
  │   │   ├─ 读取 skills/.../prompt/review_security.md  ← 此时才读磁盘
  │   │   ├─ 注入参数：{{code}} → 实际代码
  │   │   ├─ 注入资源：resources/security_checklist.md   ← 此时才读磁盘
  │   │   ├─ invokeOnce(完整 prompt)
  │   │   │   └─ LLM 调用 ②（内部，不保留历史）
  │   │   │       → 返回审查意见文本
  │   │   │
  │   │   └─ ToolResult(审查意见) 返回
  │   │
  │   ├─ ToolResult(审查意见) 加入 messages
  │   │
  │   └─ LLM 调用 ③ → "代码审查结果如下：..."
  │
  └─ 返回给用户
```

### 9.3 Type 3：Config Skill（2 次 LLM 调用）

```
用户: "把这段话翻译成英文"
  │
  ├─[LangChainChatAdapter.streamMessage]
  │   构建 options.tools（含 cfg_xxx 的 name/description/schema）
  │   │
  │   ├─ LLM 调用 ① → 选择 cfg_xxx({content:"...", target_lang:"英文"})
  │   │
  │   ├─[_ConfigToolAdapter.execute]
  │   │   ├─ 从 config 字段获取 prompt 模板
  │   │   ├─ 注入参数：{{content}} → 实际文本, {{target_lang}} → 英文
  │   │   ├─ invokeOnce(完整 prompt)
  │   │   │   └─ LLM 调用 ②（内部）
  │   │   │       → 返回翻译结果
  │   │   └─ ToolResult(翻译结果) 返回
  │   │
  │   ├─ ToolResult(翻译结果) 加入 messages
  │   │
  │   └─ LLM 调用 ③ → "翻译结果如下：..."
  │
  └─ 返回给用户
```

## 十、Token 消耗分析

### 10.1 注册时（每次对话都发送）

```
工具定义只包含 name + description + inputJsonSchema

示例：
{
  "name": "review_security",
  "description": "审查代码安全问题",
  "parameters": { "type": "object", "properties": {"code": {"type": "string"}}, "required": ["code"] }
}

≈ 50-100 tokens / 工具（不含 prompt 模板）
```

### 10.2 执行时（仅被选中的工具）

```
prompt 模板仅在 execute() 时读取和发送
未被 LLM 选择的工具，其 prompt 永远不会被加载

示例：一个 2000 字的 prompt 模板
  → 如果 LLM 没选这个工具：0 tokens
  → 如果 LLM 选了：2000 tokens（invokeOnce 内部）
```

### 10.3 对比

```
假设有 20 个 Folder Skill，每个 prompt 平均 1500 tokens

方案 A（prompt 放入工具定义）：
  注册时：20 × 1500 = 30,000 tokens（每次对话都发）

方案 B（prompt 动态加载，本方案）：
  注册时：20 × 80  = 1,600 tokens
  执行时：1 × 1500 = 1,500 tokens（仅被选中的工具）

节省：30,000 - 1,600 = 28,400 tokens/对话
```

## 十一、AiEmployeeSkillEntity.config 字段规范

```
┌──────────────┬──────────────────────────────────────────────┐
│ skillType    │ config 字段格式                               │
├──────────────┼──────────────────────────────────────────────┤
│ "mcp"        │ McpServerConfig 列表的 JSON 字符串            │
│              │ （复用现有 McpServerConfig.parseList）        │
│              │ 示例：'[{"name":"fs","transportType":"stdio", │
│              │   "command":"npx","args":[...]}]'            │
├──────────────┼──────────────────────────────────────────────┤
│ "folder"     │ 文件夹路径字符串                               │
│              │ 示例："skills/folder/code_review"             │
├──────────────┼──────────────────────────────────────────────┤
│ "config"     │ JSON 对象字符串                               │
│              │ {"prompt":"...模板...","parameters":{...},    │
│              │  "requires_permission":false}                 │
└──────────────┴──────────────────────────────────────────────┘
```

## 十二、实施路线图

### 阶段一：基础框架（第 1-2 周）

**目标**：搭建 Skill 接口和管理器，Type 3 Config Skill 可用

1. 新建 `lib/src/skill/` 目录
2. 实现 `skill.dart`（Skill 接口 + 枚举）
3. 实现 `skill_context.dart`
4. 实现 `skill_manager.dart`
5. 实现 `config/config_skill.dart` + `config_tool_adapter.dart`
6. 修改 `tool_registry.dart`（新增 registerOrReplaceTool）
7. 修改 `agent_impl.dart`（initialize 增加 Skill 加载）
8. 编写 Config Skill 单元测试

**验收标准**：通过数据库创建 Config Skill，Agent 能正确调用并返回结果

### 阶段二：Folder Skill（第 3-4 周）

**目标**：Type 2 Folder Skill 可用，兼容 SKILL.md 和 skill.yaml

1. 新增 `yaml` 依赖
2. 实现 `folder/skill_md_parser.dart`
3. 实现 `folder/folder_skill.dart` + `folder_tool_adapter.dart`
4. 编写 Folder Skill 单元测试
5. 创建 3 个示例技能（翻译、代码审查、摘要）

**验收标准**：
- SKILL.md 能正确解析 frontmatter 和正文
- skill.yaml 向后兼容
- 纯 Markdown 自动推断
- prompt 动态加载（execute 时才读文件）
- 热更新（reloadSkill 后读取新文件）

### 阶段三：MCP Skill（第 5-7 周）

**目标**：Type 1 MCP Skill 可用

1. 实现 `mcp/mcp_client.dart`（接口）
2. 实现 `mcp/mcp_stdio_client.dart`（stdio 传输）
3. 实现 `mcp/mcp_sse_client.dart`（SSE 传输）
4. 实现 `mcp/mcp_skill.dart` + `mcp_tool_adapter.dart`
5. 编写 MCP Skill 集成测试

**验收标准**：
- 能连接标准 MCP 服务器
- listTools 正确获取工具列表
- callTool 正确调用并返回结果
- 连接断开自动重连

### 阶段四：优化完善（第 8 周）

1. prompt 缓存策略优化
2. 错误隔离（单个技能失败不影响其他）
3. 技能健康检查定时任务
4. 监控指标（调用次数、成功率、耗时）
5. 完善文档

## 十三、现有代码改动汇总

```
修改的文件（3个）：
├── lib/src/agent/tool/tool_registry.dart
│   └── 新增 registerOrReplaceTool() 方法（3行）
├── lib/src/agent/impl/agent_impl.dart
│   └── 新增 _skillManager 字段、_initSkillSystem()、
│       addSkill()、removeSkill()、reloadSkill()（~80行）
└── lib/wenzagent.dart
    └── 新增 skill 模块导出（~10行）

新增的文件（11个）：
├── lib/src/skill/skill.dart
├── lib/src/skill/skill_context.dart
├── lib/src/skill/skill_manager.dart
├── lib/src/skill/mcp/mcp_client.dart
├── lib/src/skill/mcp/mcp_skill.dart
├── lib/src/skill/mcp/mcp_tool_adapter.dart
├── lib/src/skill/folder/skill_md_parser.dart
├── lib/src/skill/folder/folder_skill.dart
├── lib/src/skill/folder/folder_tool_adapter.dart
├── lib/src/skill/config/config_skill.dart
└── lib/src/skill/config/config_tool_adapter.dart

不变的文件（核心系统完全不动）：
├── lib/src/agent/tool/agent_tool.dart           ✓ 不变
├── lib/src/agent/adapter/langchain_chat_adapter.dart  ✓ 不变
├── lib/src/agent/adapter/chat_model_factory.dart ✓ 不变
├── lib/src/agent/tool/permission_manager.dart   ✓ 不变
├── lib/src/agent/tool/cancellable_tool_executor.dart ✓ 不变
├── lib/src/agent/tool/tool_registry.dart（仅新增方法）✓ 基本不变
├── lib/src/persistence/entities/skill_entity.dart  ✓ 不变
├── lib/src/service/skill_manager.dart           ✓ 不变（SkillManagerImpl 继续负责 CRUD）
└── lib/src/persistence/stores/skill_store.dart   ✓ 不变
```

## 十四、SkillManagerImpl（现有）与 SkillManager（新增）的职责划分

```
SkillManagerImpl（现有，不动）         SkillManager（新增）
┌─────────────────────────┐     ┌─────────────────────────┐
│ 数据库 CRUD              │     │ 运行时生命周期管理       │
│ ├── createSkill()       │     │ ├── loadSkill()         │
│ ├── getSkills()         │     │ ├── unloadSkill()       │
│ ├── updateSkill()       │     │ ├── reloadSkill()       │
│ └── deleteSkill()       │     │ └── healthCheck()       │
│                         │     │                         │
│ 职责：持久化             │     │ 职责：工具注册/注销      │
│ 存储：Hive              │     │ 注册：ToolRegistry      │
└─────────────────────────┘     │ 来源：数据库 + 文件系统  │
                                └─────────────────────────┘
                                         │
                              AgentImpl._initSkillSystem()
                                ├── SkillManagerImpl.getSkills() → 读取实体
                                ├── McpSkill.fromEntity() → 创建 Skill
                                ├── ConfigSkill.fromEntity() → 创建 Skill
                                ├── FolderSkill(path) → 扫描文件夹创建 Skill
                                └── SkillManager.loadSkill() → 注册工具
```
