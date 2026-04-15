import 'dart:async';

import 'package:dio/dio.dart';

import '../agent_tool.dart';

/// Web 搜索工具
///
/// 使用 DuckDuckGo Lite 搜索引擎进行关键词搜索。
/// 无需 API key，解析 HTML 结果返回标题、URL、摘要。
class WebSearchTool extends AgentTool {
  /// 默认最大返回结果数
  static const int _defaultMaxResults = 5;

  /// 搜索超时时间（秒）
  static const int _searchTimeout = 15;

  @override
  String get name => 'web_search';

  @override
  String get description =>
      'Search the web using a search engine. Returns a list of results with '
      'title, URL, and summary for each match.\n\n'
      'Use this tool when you need to:\n'
      '- Look up documentation or APIs\n'
      '- Find solutions to programming problems\n'
      '- Search for current information\n'
      '- Research best practices or tutorials';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'Search keywords or question.',
          },
          'max_results': {
            'type': 'integer',
            'description':
                'Maximum number of results to return. Default: $_defaultMaxResults.',
          },
        },
        'required': ['query'],
      };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final query = arguments['query'] as String?;
    if (query == null || query.isEmpty) {
      return ToolResult.error('query is required');
    }

    final maxResults = arguments['max_results'] as int? ?? _defaultMaxResults;

    try {
      final results = await _searchDuckDuckGo(query, maxResults);

      if (results.isEmpty) {
        return ToolResult.success(
          'No search results found for: $query',
        );
      }

      final buffer = StringBuffer('Search results for "$query":\n\n');
      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        buffer.writeln('${i + 1}. **${r.title}**');
        buffer.writeln('   URL: ${r.url}');
        buffer.writeln('   ${r.snippet}');
        buffer.writeln();
      }

      return ToolResult.success(buffer.toString().trim());
    } on TimeoutException {
      return ToolResult.error('Search timed out after ${_searchTimeout}s');
    } catch (e) {
      return ToolResult.error('Search failed: $e');
    }
  }

  /// 通过 DuckDuckGo Lite 搜索
  Future<List<_SearchResult>> _searchDuckDuckGo(
    String query,
    int maxResults,
  ) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: _searchTimeout),
      receiveTimeout: const Duration(seconds: _searchTimeout),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml',
      },
      responseType: ResponseType.plain,
    ));

    final response = await dio.post<String>(
      'https://lite.duckduckgo.com/lite/',
      data: 'q=${Uri.encodeComponent(query)}&kl=wt-wt',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
      ),
    );

    final html = response.data ?? '';
    if (html.isEmpty) return [];

    return _parseDuckDuckGoResults(html, maxResults);
  }

  /// 解析 DuckDuckGo Lite HTML 结果
  List<_SearchResult> _parseDuckDuckGoResults(
    String html,
    int maxResults,
  ) {
    final results = <_SearchResult>[];

    // DuckDuckGo Lite 结果在 <a class="result-link"> 标签中
    final linkRegex = RegExp(
      r'<a[^>]*class="result-link"[^>]*href="([^"]*)"[^>]*>(.*?)</a>',
      caseSensitive: false,
      dotAll: true,
    );

    // 摘要在 <td class="result-snippet"> 中
    final snippetRegex = RegExp(
      r'<td[^>]*class="result-snippet"[^>]*>(.*?)</td>',
      caseSensitive: false,
      dotAll: true,
    );

    final links = linkRegex.allMatches(html).toList();
    final snippets = snippetRegex.allMatches(html).toList();

    final count = links.length < maxResults ? links.length : maxResults;

    for (var i = 0; i < count; i++) {
      final url = links[i].group(1) ?? '';
      var title = links[i].group(2) ?? '';
      title = _stripHtmlTags(title).trim();

      var snippet = '';
      if (i < snippets.length) {
        snippet = _stripHtmlTags(snippets[i].group(1) ?? '').trim();
      }

      if (url.isNotEmpty && title.isNotEmpty) {
        results.add(_SearchResult(
          title: title,
          url: url,
          snippet: snippet,
        ));
      }
    }

    return results;
  }

  /// 移除 HTML 标签
  String _stripHtmlTags(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .trim();
  }
}

/// 搜索结果
class _SearchResult {
  final String title;
  final String url;
  final String snippet;

  _SearchResult({
    required this.title,
    required this.url,
    required this.snippet,
  });
}
