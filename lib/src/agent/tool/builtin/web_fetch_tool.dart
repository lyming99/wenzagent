import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../agent_tool.dart';

/// Web 获取工具
///
/// 发送 HTTP 请求获取网页或 API 内容。
/// 支持 HTML 纯文本提取、JSON 格式化、响应截断。
/// 内置 SSRF 防护（禁止访问内网 IP）。
class WebFetchTool extends AgentTool {
  /// 默认超时时间（秒）
  static const int _defaultTimeout = 15;

  /// 默认最大响应字节数
  static const int _defaultMaxBytes = 50 * 1024; // 50KB

  @override
  String get name => 'web_fetch';

  @override
  String get description =>
      'Fetch content from a URL via HTTP GET or POST request. '
      'Returns processed content: HTML pages are converted to plain text, '
      'JSON responses are formatted, and other content is returned as-is.\n\n'
      'Use this tool when you need to:\n'
      '- Read documentation or web pages\n'
      '- Fetch API responses\n'
      '- Access online resources\n\n'
      'Only HTTP and HTTPS protocols are allowed. '
      'Internal/private network addresses are blocked for security.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description': 'The URL to fetch (HTTP or HTTPS only).',
          },
          'method': {
            'type': 'string',
            'enum': ['GET', 'POST'],
            'description': 'HTTP method. Default: GET.',
          },
          'headers': {
            'type': 'object',
            'description': 'Custom HTTP headers as key-value pairs.',
          },
          'body': {
            'type': 'string',
            'description': 'Request body for POST requests.',
          },
          'timeout': {
            'type': 'integer',
            'description':
                'Timeout in seconds. Default: $_defaultTimeout.',
          },
          'max_bytes': {
            'type': 'integer',
            'description':
                'Maximum response size in bytes. Default: ${_defaultMaxBytes ~/ 1024}KB.',
          },
        },
        'required': ['url'],
      };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final url = arguments['url'] as String?;
    if (url == null || url.isEmpty) {
      return ToolResult.error('url is required');
    }

    // 协议校验
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return ToolResult.error('Invalid URL: $url');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return ToolResult.error(
        'Only HTTP and HTTPS protocols are allowed. Got: ${uri.scheme}',
      );
    }

    // SSRF 防护
    final ssrfError = _checkSsrf(uri);
    if (ssrfError != null) {
      return ToolResult.error(ssrfError);
    }

    final method =
        (arguments['method'] as String? ?? 'GET').toUpperCase();
    final headers = arguments['headers'] as Map<String, dynamic>?;
    final body = arguments['body'] as String?;
    final timeout = arguments['timeout'] as int? ?? _defaultTimeout;
    final maxBytes = arguments['max_bytes'] as int? ?? _defaultMaxBytes;

    try {
      final dio = Dio(BaseOptions(
        connectTimeout: Duration(seconds: timeout),
        receiveTimeout: Duration(seconds: timeout),
        headers: {
          'User-Agent': 'Mozilla/5.0 (compatible; WenzAgent/1.0)',
          if (headers != null) ...headers,
        },
        responseType: ResponseType.plain,
      ));

      final response = await dio.request<String>(
        url,
        data: body,
        options: Options(method: method),
      );

      final content = response.data ?? '';
      if (content.isEmpty) {
        return ToolResult.success('Empty response from $url');
      }

      // 处理响应内容
      final processed = _processResponse(content, response.headers);
      var result = processed;

      // 截断
      if (result.length > maxBytes) {
        result =
            '${result.substring(0, maxBytes)}\n\n[Response truncated, total ${content.length} characters]';
      }

      return ToolResult.success(result);
    } on DioException catch (e) {
      final msg = _formatDioError(e);
      return ToolResult.error('Request failed: $msg');
    } on TimeoutException {
      return ToolResult.error(
        'Request timed out after ${timeout}s',
      );
    } catch (e) {
      return ToolResult.error('Request failed: $e');
    }
  }

  /// SSRF 防护：检查是否为内网 IP
  String? _checkSsrf(Uri uri) {
    final host = uri.host.toLowerCase();

    // localhost
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return 'Access to localhost is not allowed';
    }

    // 10.0.0.0/8
    if (host.startsWith('10.') && _isIpAddress(host)) {
      return 'Access to private network addresses is not allowed';
    }

    // 172.16.0.0/12
    if (_is172Private(host)) {
      return 'Access to private network addresses is not allowed';
    }

    // 192.168.0.0/16
    if (host.startsWith('192.168.') && _isIpAddress(host)) {
      return 'Access to private network addresses is not allowed';
    }

    return null;
  }

  /// 检查字符串是否为有效的 IP 地址格式
  bool _isIpAddress(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      final n = int.tryParse(p);
      return n != null && n >= 0 && n <= 255;
    });
  }

  /// 检查 172.16-31.x.x 范围
  bool _is172Private(String host) {
    if (!host.startsWith('172.')) return false;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 16 && second <= 31;
  }

  /// 处理响应内容
  String _processResponse(String content, Headers headers) {
    final contentType =
        headers.value('content-type')?.toLowerCase() ?? '';

    if (contentType.contains('application/json')) {
      return _formatJson(content);
    }

    if (contentType.contains('text/html')) {
      return _extractHtmlText(content);
    }

    // 其他类型直接返回
    return content;
  }

  /// 格式化 JSON
  String _formatJson(String content) {
    try {
      final decoded = jsonDecode(content);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (e) {
      // 解析失败，返回原始内容
      return content;
    }
  }

  /// 提取 HTML 纯文本
  String _extractHtmlText(String html) {
    var text = html;

    // 移除 script 标签及内容
    text = text.replaceAll(
      RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false),
      '',
    );

    // 移除 style 标签及内容
    text = text.replaceAll(
      RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false),
      '',
    );

    // 移除 nav 标签及内容
    text = text.replaceAll(
      RegExp(r'<nav[^>]*>[\s\S]*?</nav>', caseSensitive: false),
      '',
    );

    // 移除 head 标签及内容
    text = text.replaceAll(
      RegExp(r'<head[^>]*>[\s\S]*?</head>', caseSensitive: false),
      '',
    );

    // 移除所有 HTML 标签
    text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');

    // 解码 HTML 实体
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');

    // 合并空白
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n\s*\n+'), '\n\n');

    return text.trim();
  }

  /// 格式化 DioException 错误信息
  String _formatDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return 'Connection timeout';
      case DioExceptionType.sendTimeout:
        return 'Send timeout';
      case DioExceptionType.receiveTimeout:
        return 'Receive timeout';
      case DioExceptionType.badResponse:
        final statusCode = e.response?.statusCode;
        return 'HTTP $statusCode';
      case DioExceptionType.cancel:
        return 'Request cancelled';
      case DioExceptionType.connectionError:
        return 'Connection error: ${e.message ?? "unknown"}';
      default:
        return e.message ?? 'Unknown error';
    }
  }
}
