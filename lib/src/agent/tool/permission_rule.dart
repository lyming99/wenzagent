import 'dart:convert';

import '../../utils/logger.dart';
import 'command_splitter.dart';

/// 命令 pattern 推导粒度
enum CommandPatternGranularity {
  /// 命令前缀（如 git.*）
  prefix,

  /// 命令组合（如 git\s+commit.*）
  base,

  /// 精确匹配完整命令
  exact;
}

/// 规则匹配模式
enum PermissionMatchMode {
  /// 精确匹配参数值
  exact,

  /// 正则表达式匹配参数值
  regex,

  /// 匹配该权限类型全部（不检查参数）
  all;

  static PermissionMatchMode fromString(String value) {
    return PermissionMatchMode.values.firstWhere(
      (e) => e.name == value,
      orElse: () => PermissionMatchMode.exact,
    );
  }
}

/// 权限判定结果（规则引擎内部使用）
enum PermissionVerdict {
  /// 允许执行
  allow,

  /// 拒绝执行（黑名单命中）
  deny,

  /// 需要用户确认（未命中任何规则）
  ask;
}

/// 单条权限规则
class PermissionRule {
  static final _log = Logger('PermissionRule');

  /// 权限类型（对应 [AgentTool.permissionType]，如 "file_write", "command_execute"）
  final String tool;

  /// 要匹配的参数 key（如 "path", "command"）
  /// null 表示不检查参数，仅匹配工具名
  final String? arg;

  /// 匹配模式字符串
  final String pattern;

  /// 匹配方式
  final PermissionMatchMode mode;

  /// 规则创建时间
  final DateTime? createTime;

  const PermissionRule({
    required this.tool,
    this.arg,
    this.pattern = '',
    required this.mode,
    this.createTime,
  });

  /// 判断是否匹配给定的工具和参数
  bool matches(String toolName, Map<String, dynamic> arguments) {
    // all 模式仅匹配工具名
    if (mode == PermissionMatchMode.all) {
      return tool == toolName;
    }

    // exact / regex 模式：先匹配工具名
    if (tool != toolName) return false;

    // 没有指定参数 key → 工具名匹配即视为通过
    if (arg == null) return true;

    // 获取参数值
    final rawValue = arguments[arg];
    if (rawValue is! String) return false;

    switch (mode) {
      case PermissionMatchMode.exact:
        return rawValue == pattern;
      case PermissionMatchMode.regex:
        try {
          // 命令类型：拆分子命令逐条匹配（支持复合命令）
          if (tool == 'command_execute' &&
              CommandSplitter.isCompound(rawValue)) {
            for (final cmd in CommandSplitter.split(rawValue)) {
              if (RegExp(pattern, dotAll: true).hasMatch(cmd)) {
                return true;
              }
            }
            return false;
          }
          // 非命令类型 或 单条命令：整体匹配
          return RegExp(pattern, dotAll: true).hasMatch(rawValue);
        } catch (e) {
          _log.debug('regex match failed, using fallback: $e');
          return false;
        }
      case PermissionMatchMode.all:
        return true;
    }
  }

  /// 从参数值自动推导正则模式
  ///
  /// 路径类: /path/to/file.txt → /path/to/.*
  /// 命令类: git commit -m "msg" → git\s+commit.*（当 permissionType 为 command_execute 时）
  /// 其他: value → value.*
  static String derivePattern(String value, {String? permissionType}) {
    if (value.isEmpty) return '.*';

    // 命令类型：提取命令名+子命令作为前缀
    if (permissionType == 'command_execute') {
      return deriveCommandPattern(value,
          granularity: CommandPatternGranularity.base);
    }

    // 识别路径（包含 / 或 \）
    if (value.contains('/') || value.contains('\\')) {
      final lastSep = value.lastIndexOf('/') > value.lastIndexOf('\\')
          ? value.lastIndexOf('/')
          : value.lastIndexOf('\\');
      if (lastSep > 0) {
        final dir = value.substring(0, lastSep + 1);
        return '${RegExp.escape(dir)}.*';
      }
      return '.*';
    }

    // 非路径：取第一个词 + .*
    final parts = value.trim().split(RegExp(r'\s+'));
    if (parts.isNotEmpty) {
      return '${RegExp.escape(parts.first)}.*';
    }
    return '.*';
  }

  /// 从命令字符串推导不同粒度的正则模式
  ///
  /// [command] 完整命令字符串
  /// [granularity] 粒度级别
  ///
  /// 示例（以 `git commit -m "msg"` 为输入）:
  /// - [CommandPatternGranularity.prefix]: `git.*` → 匹配所有 git 命令
  /// - [CommandPatternGranularity.base]: `git\s+commit.*` → 匹配所有 git commit 变体
  /// - [CommandPatternGranularity.exact]: `git\ commit\ \-m\ "msg"` → 精确匹配
  static String deriveCommandPattern(String command,
      {required CommandPatternGranularity granularity}) {
    if (command.isEmpty) return '.*';

    // 复合命令：取第一个子命令推导
    var effectiveCommand = command;
    if (CommandSplitter.isCompound(command)) {
      final subCommands = CommandSplitter.split(command);
      if (subCommands.isNotEmpty) {
        effectiveCommand = subCommands.first;
      }
    }

    final parts = effectiveCommand.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '.*';

    switch (granularity) {
      case CommandPatternGranularity.prefix:
        // 命令前缀：git.* → 匹配所有 git 命令
        return '${RegExp.escape(parts.first)}.*';
      case CommandPatternGranularity.base:
        // 命令组合：git\s+commit.* → 匹配所有 git commit 变体
        if (parts.length >= 2) {
          return '${RegExp.escape(parts[0])}\\s+${RegExp.escape(parts[1])}.*';
        }
        return '${RegExp.escape(parts.first)}.*';
      case CommandPatternGranularity.exact:
        // 精确匹配：转义完整命令
        return RegExp.escape(command);
    }
  }

  Map<String, dynamic> toJson() => {
        'tool': tool,
        if (arg != null) 'arg': arg,
        'pattern': pattern,
        'mode': mode.name,
        if (createTime != null) 'createTime': createTime!.toIso8601String(),
      };

  factory PermissionRule.fromJson(Map<String, dynamic> map) {
    return PermissionRule(
      tool: map['tool'] as String,
      arg: map['arg'] as String?,
      pattern: map['pattern'] as String? ?? '',
      mode: PermissionMatchMode.fromString(map['mode'] as String? ?? 'exact'),
      createTime: map['createTime'] != null
          ? DateTime.tryParse(map['createTime'] as String)
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PermissionRule &&
          tool == other.tool &&
          arg == other.arg &&
          pattern == other.pattern &&
          mode == other.mode;

  @override
  int get hashCode => Object.hash(tool, arg, pattern, mode);

  @override
  String toString() =>
      'PermissionRule(tool: $tool, arg: $arg, pattern: $pattern, mode: ${mode.name})';
}

/// 权限配置
///
/// 存储在 [AiEmployeeEntity.permissionConfig] 中的 JSON 结构。
/// 包含白名单和黑名单两组规则，黑名单优先。
///
/// JSON 格式示例:
/// ```json
/// {
///   "whitelist": [
///     {"tool": "file_write", "arg": "path", "pattern": "/workspace/**", "mode": "regex"},
///     {"tool": "command_execute", "arg": "command", "pattern": "git.*", "mode": "regex"},
///     {"tool": "file_write", "mode": "all"}
///   ],
///   "blacklist": [
///     {"tool": "command_execute", "arg": "command", "pattern": "rm\\s+-rf.*", "mode": "regex"}
///   ]
/// }
/// ```
class PermissionConfig {
  static final _log = Logger('PermissionConfig');

  /// 白名单规则（命中则允许）
  final List<PermissionRule> whitelist;

  /// 黑名单规则（命中则拒绝）
  final List<PermissionRule> blacklist;

  const PermissionConfig({
    this.whitelist = const [],
    this.blacklist = const [],
  });

  /// 创建空配置
  factory PermissionConfig.empty() => const PermissionConfig();

  /// 从 JSON 字符串解析
  factory PermissionConfig.fromJsonString(String jsonStr) {
    if (jsonStr.isEmpty) return PermissionConfig.empty();
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      return PermissionConfig.fromMap(map);
    } catch (e) {
      _log.debug('failed to parse permission config JSON, using empty config: $e');
      return PermissionConfig.empty();
    }
  }

  /// 从 Map 解析
  factory PermissionConfig.fromMap(Map<String, dynamic> map) {
    return PermissionConfig(
      whitelist: (map['whitelist'] as List?)
              ?.map((e) => PermissionRule.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      blacklist: (map['blacklist'] as List?)
              ?.map((e) => PermissionRule.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  /// 转换为 Map
  Map<String, dynamic> toMap() => {
        'whitelist': whitelist.map((r) => r.toJson()).toList(),
        'blacklist': blacklist.map((r) => r.toJson()).toList(),
      };

  /// 序列化为 JSON 字符串
  String toJsonString() => jsonEncode(toMap());

  /// 检查黑名单是否命中
  bool matchesBlacklist(String toolName, Map<String, dynamic> arguments) {
    for (final rule in blacklist) {
      if (rule.matches(toolName, arguments)) return true;
    }
    return false;
  }

  /// 检查白名单是否命中
  bool matchesWhitelist(String toolName, Map<String, dynamic> arguments) {
    for (final rule in whitelist) {
      if (rule.matches(toolName, arguments)) return true;
    }
    return false;
  }

  /// 综合判定
  ///
  /// 决策顺序：黑名单 → 白名单 → ask
  ///
  /// 对于 command_execute 类型，支持复合命令逐条判定：
  /// - 任一子命令命中黑名单 → 整体 deny
  /// - 所有子命令命中白名单 → allow
  /// - 否则 → ask
  PermissionVerdict evaluate(
      String toolName, Map<String, dynamic> arguments) {
    // 非命令类型：走原有整体判定逻辑
    if (toolName != 'command_execute') {
      if (matchesBlacklist(toolName, arguments)) {
        return PermissionVerdict.deny;
      }
      if (matchesWhitelist(toolName, arguments)) {
        return PermissionVerdict.allow;
      }
      return PermissionVerdict.ask;
    }

    // 命令类型：检查是否为复合命令
    final rawCommand = arguments['command'] as String?;
    if (rawCommand == null || rawCommand.isEmpty) {
      return PermissionVerdict.ask;
    }

    // 单条命令：走原有逻辑
    if (!CommandSplitter.isCompound(rawCommand)) {
      if (matchesBlacklist(toolName, arguments)) {
        return PermissionVerdict.deny;
      }
      if (matchesWhitelist(toolName, arguments)) {
        return PermissionVerdict.allow;
      }
      return PermissionVerdict.ask;
    }

    // 复合命令：逐条判定
    final subCommands = CommandSplitter.split(rawCommand);
    if (subCommands.isEmpty) return PermissionVerdict.ask;

    var allWhitelisted = true;

    for (final cmd in subCommands) {
      final cmdArgs = {'command': cmd};

      // 任一子命令命中黑名单 → 整体拒绝
      if (matchesBlacklist(toolName, cmdArgs)) {
        return PermissionVerdict.deny;
      }

      // 任一子命令不在白名单 → 需要用户确认
      if (!matchesWhitelist(toolName, cmdArgs)) {
        allWhitelisted = false;
      }
    }

    // 所有子命令都在白名单 → 允许
    if (allWhitelisted) return PermissionVerdict.allow;

    return PermissionVerdict.ask;
  }

  /// 添加白名单规则（返回新实例，不可变）
  PermissionConfig addWhitelistRule(PermissionRule rule) {
    return PermissionConfig(
      whitelist: [...whitelist, rule],
      blacklist: blacklist,
    );
  }

  /// 移除白名单规则（返回新实例，不可变）
  PermissionConfig removeWhitelistRule(PermissionRule rule) {
    return PermissionConfig(
      whitelist: whitelist.where((r) => r != rule).toList(),
      blacklist: blacklist,
    );
  }

  /// 添加黑名单规则（返回新实例，不可变）
  PermissionConfig addBlacklistRule(PermissionRule rule) {
    return PermissionConfig(
      whitelist: whitelist,
      blacklist: [...blacklist, rule],
    );
  }

  /// 移除黑名单规则（返回新实例，不可变）
  PermissionConfig removeBlacklistRule(PermissionRule rule) {
    return PermissionConfig(
      whitelist: whitelist,
      blacklist: blacklist.where((r) => r != rule).toList(),
    );
  }
}
