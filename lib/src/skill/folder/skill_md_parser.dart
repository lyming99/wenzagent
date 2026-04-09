import 'package:yaml/yaml.dart';

/// SKILL.md 解析结果
class SkillMdDocument {
  /// frontmatter 数据
  final Map<String, dynamic> frontmatter;

  /// 正文内容（frontmatter 之后的部分）
  final String body;

  SkillMdDocument({required this.frontmatter, required this.body});

  /// 是否为纯 Markdown（无 frontmatter）
  bool get isRawMarkdown => frontmatter['_raw'] == true;
}

/// SKILL.md / skill.yaml 解析器
///
/// 支持三种格式：
/// 1. 带 frontmatter 的 SKILL.md（Claude 兼容）
/// 2. skill.yaml（向后兼容）
/// 3. 纯 Markdown（最简，自动推断工具定义）
class SkillMdParser {
  /// 解析文件内容，自动判断格式
  static SkillMdDocument parse(String content) {
    final trimmed = content.trim();

    // 有 frontmatter（以 --- 开头）
    if (trimmed.startsWith('---')) {
      final endIndex = trimmed.indexOf('\n---', 3);
      if (endIndex != -1) {
        final yamlStr = trimmed.substring(3, endIndex).trim();
        final yamlDoc = loadYaml(yamlStr);
        final frontmatter = _yamlToMap(yamlDoc);
        final body = trimmed.substring(endIndex + 4).trim();
        return SkillMdDocument(frontmatter: frontmatter, body: body);
      }
    }

    // 纯 Markdown（无 frontmatter）
    return SkillMdDocument(
      frontmatter: {'_raw': true},
      body: trimmed,
    );
  }

  /// 将 YamlMap 转为 Map<String, dynamic>
  static Map<String, dynamic> _yamlToMap(dynamic yaml) {
    if (yaml is YamlMap) {
      return yaml.map((key, value) => MapEntry(key.toString(), _yamlToDart(value)));
    }
    if (yaml is Map) {
      return yaml.map((key, value) => MapEntry(key.toString(), _yamlToDart(value)));
    }
    return {};
  }

  /// 递归转换 YamlNode 为 Dart 原生类型
  static dynamic _yamlToDart(dynamic value) {
    if (value is YamlMap) {
      return value.map((k, v) => MapEntry(k.toString(), _yamlToDart(v)));
    }
    if (value is YamlList) {
      return value.map(_yamlToDart).toList();
    }
    return value;
  }
}
