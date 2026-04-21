/// Shell 命令拆分器
///
/// 将复合命令（含 & / && / || / ; / | 等操作符）拆分为子命令列表，
/// 用于权限系统的逐条命令匹配判定。
///
/// 设计参考 Python shlex，采用状态机模型处理引号和转义。
///
/// 示例：
///   'cd /tmp && rm -rf /'
///   → ['cd /tmp', 'rm -rf /']
///
///   'echo "hello && world" | grep hello'
///   → ['echo hello && world', 'grep hello']
library;

/// Shell 命令词法分析器
///
/// 将命令字符串拆分为 token 列表，支持：
/// - 单引号保护（'xxx'，内部所有字符为字面量）
/// - 双引号保护（"xxx"）
/// - 反斜杠转义（\x）
/// - 操作符识别（& && || ; | > >> < 2>）
class ShellTokenizer {
  /// 双字符操作符集合
  static const _twoCharOperators = {'&&', '||', '>>', '2>'};

  /// 单字符操作符集合
  static const _oneCharOperators = {'&', ';', '|', '>', '<'};

  /// 操作符起始字符
  static const _operatorStarts = {'&', '|', ';', '>', '<', '2'};

  /// 单独 & 不是操作符（已被双字符 && 优先消费）
  /// 此标记仅在双字符匹配失败时使用
  static const _singleAmpersandIsOperator = true;

  /// 将命令字符串拆分为 token 列表
  ///
  /// 引号内的内容作为一个整体 token（引号本身被去除），
  /// 操作符作为独立 token 输出。
  ///
  /// ```dart
  /// ShellTokenizer.tokenize('cd /tmp && rm -rf /')
  /// // → ['cd', '/tmp', '&&', 'rm', '-rf', '/']
  ///
  /// ShellTokenizer.tokenize('echo "hello world" | grep hello')
  /// // → ['echo', 'hello world', '|', 'grep', 'hello']
  /// ```
  static List<String> tokenize(String input) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    var inSingleQuote = false;
    var inDoubleQuote = false;
    var escaped = false;

    void flushBuffer() {
      if (buffer.isNotEmpty) {
        tokens.add(buffer.toString());
        buffer.clear();
      }
    }

    final chars = input.codeUnits;
    for (var i = 0; i < chars.length; i++) {
      final ch = String.fromCharCode(chars[i]);

      // --- 转义处理 ---
      if (escaped) {
        buffer.write(ch);
        escaped = false;
        continue;
      }
      if (ch == '\\' && !inSingleQuote) {
        escaped = true;
        continue;
      }

      // --- 引号处理 ---
      if (ch == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
        continue; // 引号本身不入 buffer
      }
      if (ch == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
        continue;
      }

      // --- 引号内：所有字符为字面量 ---
      if (inSingleQuote || inDoubleQuote) {
        buffer.write(ch);
        continue;
      }

      // --- 引号外：操作符识别 ---
      if (_operatorStarts.contains(ch)) {
        flushBuffer();

        // 检查双字符操作符
        final nextCh = i + 1 < chars.length
            ? String.fromCharCode(chars[i + 1])
            : '';
        final twoChar = '$ch$nextCh';

        if (_twoCharOperators.contains(twoChar)) {
          tokens.add(twoChar);
          i++; // 跳过下一个字符
        } else if (_oneCharOperators.contains(ch)) {
          tokens.add(ch);
        } else {
          // '2' 单独出现不是操作符，作为普通字符
          // '&' 已在 _oneCharOperators 中处理，不会走到这里
          buffer.write(ch);
        }
        continue;
      }

      // --- 空白分割 ---
      if (ch == ' ' || ch == '\t') {
        flushBuffer();
        continue;
      }

      // --- 普通字符 ---
      buffer.write(ch);
    }

    // 处理末尾残留的转义反斜杠
    if (escaped) {
      buffer.write('\\');
    }
    flushBuffer();

    return tokens;
  }
}

/// Shell 命令分隔符类型
enum ShellSeparator {
  /// 后台执行（& 后台运行前一条，同时执行下一条）
  amp('&'),

  /// 逻辑与（前一条成功才执行下一条）
  and('&&'),

  /// 逻辑或（前一条失败才执行下一条）
  or('||'),

  /// 顺序执行（无论前一条是否成功）
  semi(';'),

  /// 管道（前一条的输出作为下一条的输入）
  pipe('|');

  final String symbol;
  const ShellSeparator(this.symbol);

  static bool isSeparator(String token) {
    return values.any((s) => s.symbol == token);
  }
}

/// 复合命令拆分器
///
/// 将 token 列表或命令字符串按 shell 分隔符拆分为子命令。
/// 分隔符：& / && / || / ; / |
///
/// 拆分后的子命令可用于权限系统的逐条匹配。
class CommandSplitter {
  /// 从 token 列表拆分为子命令 token 组
  ///
  /// ```dart
  /// CommandSplitter.splitTokenList(['cd', '/tmp', '&&', 'rm', '-rf', '/'])
  /// // → [['cd', '/tmp'], ['rm', '-rf', '/']]
  /// ```
  static List<List<String>> splitTokenList(List<String> tokens) {
    final result = <List<String>>[];
    var current = <String>[];

    for (final token in tokens) {
      if (ShellSeparator.isSeparator(token)) {
        if (current.isNotEmpty) {
          result.add(List.of(current));
          current = [];
        }
      } else {
        current.add(token);
      }
    }
    if (current.isNotEmpty) {
      result.add(current);
    }

    return result;
  }

  /// 将命令字符串拆分为子命令字符串列表
  ///
  /// ```dart
  /// CommandSplitter.split('cd /tmp && rm -rf /')
  /// // → ['cd /tmp', 'rm -rf /']
  /// ```
  static List<String> split(String command) {
    if (command.isEmpty) return [];

    final tokens = ShellTokenizer.tokenize(command);
    return splitTokenList(tokens)
        .map((t) => t.join(' '))
        .where((cmd) => cmd.trim().isNotEmpty)
        .toList();
  }

  /// 提取每个子命令的命令名（第一个 token）
  ///
  /// ```dart
  /// CommandSplitter.extractCommandNames('cd /tmp && rm -rf /')
  /// // → ['cd', 'rm']
  /// ```
  static List<String> extractCommandNames(String command) {
    if (command.isEmpty) return [];

    final tokens = ShellTokenizer.tokenize(command);
    return splitTokenList(tokens)
        .where((tokens) => tokens.isNotEmpty)
        .map((tokens) => tokens.first)
        .toList();
  }

  /// 判断命令是否为复合命令（包含分隔符）
  static bool isCompound(String command) {
    if (command.isEmpty) return false;

    final tokens = ShellTokenizer.tokenize(command);
    return tokens.any(ShellSeparator.isSeparator);
  }
}
