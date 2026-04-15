import 'dart:io';

import '../agent_tool.dart';

/// 代码符号工具
///
/// 解析代码文件中的类、函数、变量、import 等符号定义。
/// 基于正则匹配，支持 Dart、Python、JavaScript/TypeScript。
class CodeSymbolsTool extends AgentTool {
  @override
  String get name => 'code_symbols';

  @override
  String get description =>
      'Parse code symbols (classes, functions, methods, variables, imports) '
      'from a source file. Supports Dart, Python, JavaScript, and TypeScript.\n\n'
      'Returns symbol name, type, line number range, and signature.\n\n'
      'Use this tool to:\n'
      '- Understand file structure before editing\n'
      '- Find specific function or class definitions\n'
      '- Get an overview of a file without reading it entirely';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Absolute path to the source file.',
          },
          'symbol_type': {
            'type': 'string',
            'enum': ['class', 'function', 'method', 'variable', 'import', 'all'],
            'description':
                'Filter by symbol type. Default: "all".',
          },
          'name_pattern': {
            'type': 'string',
            'description':
                'Regex pattern to filter symbol names. Only matching symbols are returned.',
          },
        },
        'required': ['path'],
      };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final path = arguments['path'] as String?;
    if (path == null || path.isEmpty) {
      return ToolResult.error('path is required');
    }

    final symbolType = arguments['symbol_type'] as String? ?? 'all';
    final namePattern = arguments['name_pattern'] as String?;

    final file = File(path);
    if (!await file.exists()) {
      return ToolResult.error('File not found: $path');
    }

    String content;
    try {
      content = await file.readAsString();
    } catch (e) {
      return ToolResult.error('Failed to read file: $e');
    }

    if (content.isEmpty) {
      return ToolResult.success('File is empty: $path');
    }

    // 检测语言
    final language = _detectLanguage(path);
    final symbols = _parseSymbols(content, language);

    // 过滤
    var filtered = symbols.where((s) {
      if (symbolType != 'all' && s.type != symbolType) return false;
      if (namePattern != null && namePattern.isNotEmpty) {
        try {
          return RegExp(namePattern).hasMatch(s.name);
        } catch (e) {
          return true; // 无效正则，跳过过滤
        }
      }
      return true;
    }).toList();

    if (filtered.isEmpty) {
      return ToolResult.success(
        'No symbols found matching filters in $path\n'
        'Total symbols in file: ${symbols.length}',
      );
    }

    // 格式化输出
    final buffer = StringBuffer('## Symbols in ${path.split(Platform.pathSeparator).last}\n');
    buffer.writeln('Language: $language | Total: ${symbols.length} | Filtered: ${filtered.length}\n');

    for (final s in filtered) {
      buffer.writeln('  [${s.type}] ${s.name} (line ${s.lineStart}-${s.lineEnd ?? "?"})');
      if (s.signature != null && s.signature!.isNotEmpty) {
        buffer.writeln('    ${s.signature}');
      }
    }

    return ToolResult.success(buffer.toString().trim());
  }

  /// 检测编程语言
  String _detectLanguage(String path) {
    if (path.endsWith('.dart')) return 'dart';
    if (path.endsWith('.py')) return 'python';
    if (path.endsWith('.js')) return 'javascript';
    if (path.endsWith('.ts')) return 'typescript';
    if (path.endsWith('.tsx')) return 'typescript';
    if (path.endsWith('.jsx')) return 'javascript';
    if (path.endsWith('.java')) return 'java';
    if (path.endsWith('.go')) return 'go';
    if (path.endsWith('.rs')) return 'rust';
    if (path.endsWith('.kt')) return 'kotlin';
    if (path.endsWith('.swift')) return 'swift';
    return 'unknown';
  }

  /// 解析符号
  List<_Symbol> _parseSymbols(String content, String language) {
    final lines = content.split('\n');

    switch (language) {
      case 'dart':
        return _parseDartSymbols(content, lines);
      case 'python':
        return _parsePythonSymbols(content, lines);
      case 'javascript':
      case 'typescript':
        return _parseJsTsSymbols(content, lines);
      default:
        return _parseGenericSymbols(content, lines);
    }
  }

  /// 解析 Dart 符号
  List<_Symbol> _parseDartSymbols(String content, List<String> lines) {
    final symbols = <_Symbol>[];

    // Import
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('import ') || line.startsWith('export ')) {
        symbols.add(_Symbol(
          name: line.replaceAll(RegExp(r';.*$'), ''),
          type: 'import',
          lineStart: i + 1,
          lineEnd: i + 1,
          signature: line,
        ));
      }
    }

    // Class
    final classRegex = RegExp(
      r'^(?:abstract\s+)?class\s+(\w+)(?:\s+extends\s+\w+)?(?:\s+with\s+[\w,\s]+)?(?:\s+implements\s+[\w,\s]+)?(?:\s*\{)?$',
      multiLine: true,
    );
    for (final match in classRegex.allMatches(content)) {
      final name = match.group(1)!;
      final offset = match.start;
      final line = _getLineNumber(content, offset);
      final endLine = _findBlockEnd(lines, line - 1);
      symbols.add(_Symbol(
        name: name,
        type: 'class',
        lineStart: line,
        lineEnd: endLine,
        signature: lines[line - 1].trim(),
      ));
    }

    // Enum
    final enumRegex = RegExp(r'^enum\s+(\w+)\s*\{?$', multiLine: true);
    for (final match in enumRegex.allMatches(content)) {
      final name = match.group(1)!;
      final offset = match.start;
      final line = _getLineNumber(content, offset);
      final endLine = _findBlockEnd(lines, line - 1);
      symbols.add(_Symbol(
        name: name,
        type: 'class',
        lineStart: line,
        lineEnd: endLine,
        signature: lines[line - 1].trim(),
      ));
    }

    // Top-level functions and methods
    final funcRegex = RegExp(
      r'^(?:static\s+)?(?:async\s+)?(?:[\w<>\[\]?]+\s+)+(\w+)\s*\([^)]*\)\s*(?:async\s*)?(?:\{|\=>)',
      multiLine: true,
    );
    for (final match in funcRegex.allMatches(content)) {
      final name = match.group(1)!;
      final offset = match.start;
      final line = _getLineNumber(content, offset);
      final lineText = lines[line - 1].trim();

      // 区分 method 和 function
      final indent = lines[line - 1].length - lines[line - 1].trimLeft().length;
      final type = indent > 2 ? 'method' : 'function';

      final endLine = _findBlockEnd(lines, line - 1);

      symbols.add(_Symbol(
        name: name,
        type: type,
        lineStart: line,
        lineEnd: endLine,
        signature: lineText.length > 100
            ? '${lineText.substring(0, 100)}...'
            : lineText,
      ));
    }

    // Top-level variables
    final varRegex = RegExp(
      r'^(?:final\s+|const\s+|late\s+)?(?:static\s+)?(?:[\w<>\[\]?]+\s+)(\w+)\s*=',
      multiLine: true,
    );
    for (final match in varRegex.allMatches(content)) {
      final name = match.group(1)!;
      final offset = match.start;
      final line = _getLineNumber(content, offset);
      final indent = lines[line - 1].length - lines[line - 1].trimLeft().length;
      final type = indent > 2 ? 'variable' : 'variable';

      symbols.add(_Symbol(
        name: name,
        type: type,
        lineStart: line,
        lineEnd: line,
        signature: lines[line - 1].trim(),
      ));
    }

    return symbols;
  }

  /// 解析 Python 符号
  List<_Symbol> _parsePythonSymbols(String content, List<String> lines) {
    final symbols = <_Symbol>[];

    // Import
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('import ') || line.startsWith('from ')) {
        symbols.add(_Symbol(
          name: line,
          type: 'import',
          lineStart: i + 1,
          lineEnd: i + 1,
          signature: line,
        ));
      }
    }

    // Class
    final classRegex = RegExp(r'^class\s+(\w+)', multiLine: true);
    for (final match in classRegex.allMatches(content)) {
      final name = match.group(1)!;
      final line = _getLineNumber(content, match.start);
      final endLine = _findPythonBlockEnd(lines, line - 1);
      symbols.add(_Symbol(
        name: name,
        type: 'class',
        lineStart: line,
        lineEnd: endLine,
        signature: lines[line - 1].trim(),
      ));
    }

    // Function (def)
    final funcRegex = RegExp(r'^(async\s+)?def\s+(\w+)\s*\(', multiLine: true);
    for (final match in funcRegex.allMatches(content)) {
      final name = match.group(2)!;
      final line = _getLineNumber(content, match.start);
      final indent = lines[line - 1].length - lines[line - 1].trimLeft().length;
      final type = indent > 0 ? 'method' : 'function';
      final endLine = _findPythonBlockEnd(lines, line - 1);

      symbols.add(_Symbol(
        name: name,
        type: type,
        lineStart: line,
        lineEnd: endLine,
        signature: lines[line - 1].trim(),
      ));
    }

    // Variables (top-level assignments)
    final varRegex = RegExp(r'^(\w+)\s*=\s*', multiLine: true);
    for (final match in varRegex.allMatches(content)) {
      final name = match.group(1)!;
      final line = _getLineNumber(content, match.start);
      final indent = lines[line - 1].length - lines[line - 1].trimLeft().length;
      if (indent == 0) {
        symbols.add(_Symbol(
          name: name,
          type: 'variable',
          lineStart: line,
          lineEnd: line,
          signature: lines[line - 1].trim(),
        ));
      }
    }

    return symbols;
  }

  /// 解析 JavaScript/TypeScript 符号
  List<_Symbol> _parseJsTsSymbols(String content, List<String> lines) {
    final symbols = <_Symbol>[];

    // Import
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('import ') || line.startsWith('require(')) {
        symbols.add(_Symbol(
          name: line.length > 80 ? '${line.substring(0, 80)}...' : line,
          type: 'import',
          lineStart: i + 1,
          lineEnd: i + 1,
          signature: line,
        ));
      }
    }

    // Class
    final classRegex = RegExp(
      r'^(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+(\w+)',
      multiLine: true,
    );
    for (final match in classRegex.allMatches(content)) {
      final name = match.group(1)!;
      final line = _getLineNumber(content, match.start);
      final endLine = _findBlockEnd(lines, line - 1);
      symbols.add(_Symbol(
        name: name,
        type: 'class',
        lineStart: line,
        lineEnd: endLine,
        signature: lines[line - 1].trim(),
      ));
    }

    // Function
    final funcRegex = RegExp(
      r'^(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*\(',
      multiLine: true,
    );
    for (final match in funcRegex.allMatches(content)) {
      final name = match.group(1)!;
      final line = _getLineNumber(content, match.start);
      final endLine = _findBlockEnd(lines, line - 1);
      symbols.add(_Symbol(
        name: name,
        type: 'function',
        lineStart: line,
        lineEnd: endLine,
        signature: lines[line - 1].trim(),
      ));
    }

    // Arrow functions / const functions
    final arrowFuncRegex = RegExp(
      r'^(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?(?:\([^)]*\)|[\w]+)\s*=>',
      multiLine: true,
    );
    for (final match in arrowFuncRegex.allMatches(content)) {
      final name = match.group(1)!;
      final line = _getLineNumber(content, match.start);
      symbols.add(_Symbol(
        name: name,
        type: 'function',
        lineStart: line,
        lineEnd: line,
        signature: lines[line - 1].trim(),
      ));
    }

    // Variables
    final varRegex = RegExp(
      r'^(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?!\s*(?:async\s+)?(?:\([^)]*\)|[\w]+)\s*=>)',
      multiLine: true,
    );
    for (final match in varRegex.allMatches(content)) {
      final name = match.group(1)!;
      final line = _getLineNumber(content, match.start);
      symbols.add(_Symbol(
        name: name,
        type: 'variable',
        lineStart: line,
        lineEnd: line,
        signature: lines[line - 1].trim(),
      ));
    }

    return symbols;
  }

  /// 通用符号解析（其他语言）
  List<_Symbol> _parseGenericSymbols(String content, List<String> lines) {
    final symbols = <_Symbol>[];

    // 基本统计
    symbols.add(_Symbol(
      name: '${lines.length} lines',
      type: 'variable',
      lineStart: 1,
      lineEnd: lines.length,
      signature: null,
    ));

    // 尝试通用 import/class/function 匹配
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('import ') || line.startsWith('#include ') || line.startsWith('use ')) {
        symbols.add(_Symbol(
          name: line,
          type: 'import',
          lineStart: i + 1,
          lineEnd: i + 1,
          signature: line,
        ));
      }
    }

    final classRegex = RegExp(r'\bclass\s+(\w+)');
    for (final match in classRegex.allMatches(content)) {
      final name = match.group(1)!;
      final line = _getLineNumber(content, match.start);
      symbols.add(_Symbol(
        name: name,
        type: 'class',
        lineStart: line,
        lineEnd: null,
        signature: lines[line - 1].trim(),
      ));
    }

    final funcRegex = RegExp(r'\bfunction\s+(\w+)\s*\(|\bdef\s+(\w+)\s*\(');
    for (final match in funcRegex.allMatches(content)) {
      final name = match.group(1) ?? match.group(2);
      if (name == null) continue;
      final line = _getLineNumber(content, match.start);
      symbols.add(_Symbol(
        name: name,
        type: 'function',
        lineStart: line,
        lineEnd: null,
        signature: lines[line - 1].trim(),
      ));
    }

    return symbols;
  }

  /// 获取行号（从 offset）
  int _getLineNumber(String content, int offset) {
    var line = 1;
    for (var i = 0; i < offset && i < content.length; i++) {
      if (content[i] == '\n') line++;
    }
    return line;
  }

  /// 查找 Dart/JS 块结束行（基于大括号匹配）
  int? _findBlockEnd(List<String> lines, int startLine) {
    var braceCount = 0;
    var foundOpen = false;

    for (var i = startLine; i < lines.length; i++) {
      for (final ch in lines[i].split('')) {
        if (ch == '{') {
          braceCount++;
          foundOpen = true;
        } else if (ch == '}') {
          braceCount--;
        }
      }
      if (foundOpen && braceCount <= 0) {
        return i + 1;
      }
    }

    return null;
  }

  /// 查找 Python 块结束行（基于缩进）
  int? _findPythonBlockEnd(List<String> lines, int startLine) {
    if (startLine >= lines.length) return null;

    final startIndent =
        lines[startLine].length - lines[startLine].trimLeft().length;

    for (var i = startLine + 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) continue; // 跳过空行
      final currentIndent = line.length - line.trimLeft().length;
      if (currentIndent <= startIndent) {
        return i; // 不包含这一行
      }
    }

    return lines.length;
  }
}

/// 代码符号
class _Symbol {
  final String name;
  final String type;
  final int lineStart;
  final int? lineEnd;
  final String? signature;

  _Symbol({
    required this.name,
    required this.type,
    required this.lineStart,
    required this.lineEnd,
    required this.signature,
  });
}
