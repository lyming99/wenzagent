import 'dart:convert';

/// MCP重试配置
class McpRetryConfig {
  /// 最大重试次数
  final int maxRetries;

  /// 重试延迟（毫秒）
  final int retryDelay;

  /// 是否使用指数退避
  final bool exponentialBackoff;

  const McpRetryConfig({
    this.maxRetries = 3,
    this.retryDelay = 1000,
    this.exponentialBackoff = true,
  });

  /// 从Map创建
  factory McpRetryConfig.fromMap(Map<String, dynamic> map) {
    return McpRetryConfig(
      maxRetries: map['maxRetries'] as int? ?? 3,
      retryDelay: map['retryDelay'] as int? ?? 1000,
      exponentialBackoff: map['exponentialBackoff'] as bool? ?? true,
    );
  }

  /// 转换为Map
  Map<String, dynamic> toMap() {
    return {
      'maxRetries': maxRetries,
      'retryDelay': retryDelay,
      'exponentialBackoff': exponentialBackoff,
    };
  }

  /// 复制并修改
  McpRetryConfig copyWith({
    int? maxRetries,
    int? retryDelay,
    bool? exponentialBackoff,
  }) {
    return McpRetryConfig(
      maxRetries: maxRetries ?? this.maxRetries,
      retryDelay: retryDelay ?? this.retryDelay,
      exponentialBackoff: exponentialBackoff ?? this.exponentialBackoff,
    );
  }

  @override
  String toString() {
    return 'McpRetryConfig(maxRetries: $maxRetries, retryDelay: $retryDelay, exponentialBackoff: $exponentialBackoff)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is McpRetryConfig &&
        other.maxRetries == maxRetries &&
        other.retryDelay == retryDelay &&
        other.exponentialBackoff == exponentialBackoff;
  }

  @override
  int get hashCode => Object.hash(maxRetries, retryDelay, exponentialBackoff);
}

/// MCP服务器配置
///
/// 支持标准MCP协议格式，包括stdio、SSE、HTTP传输类型
class McpServerConfig {
  /// 服务名称（唯一标识）
  final String name;

  /// 显示名称
  final String? displayName;

  /// 描述
  final String? description;

  /// 传输类型: 'stdio' | 'sse' | 'http'
  final String transportType;

  /// 启动命令（stdio类型）
  final String? command;

  /// 命令参数
  final List<String>? args;

  /// 环境变量
  final Map<String, String>? env;

  /// 服务URL（sse/http类型）
  final String? url;

  /// HTTP头（sse类型）
  final Map<String, String>? headers;

  /// 是否启用
  final bool enabled;

  /// 是否自动启动
  final bool autoStart;

  /// 超时时间（毫秒）
  final int? timeout;

  /// 重试配置
  final McpRetryConfig? retryConfig;

  const McpServerConfig({
    required this.name,
    this.displayName,
    this.description,
    required this.transportType,
    this.command,
    this.args,
    this.env,
    this.url,
    this.headers,
    this.enabled = true,
    this.autoStart = true,
    this.timeout,
    this.retryConfig,
  });

  /// 从Map创建
  factory McpServerConfig.fromMap(Map<String, dynamic> map) {
    return McpServerConfig(
      name: map['name'] as String? ?? '',
      displayName: map['displayName'] as String?,
      description: map['description'] as String?,
      transportType: map['transportType'] as String? ?? 'stdio',
      command: map['command'] as String?,
      args: (map['args'] as List?)?.map((e) => e.toString()).toList(),
      env: (map['env'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(k, v.toString()),
      ),
      url: map['url'] as String?,
      headers: (map['headers'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(k, v.toString()),
      ),
      enabled: map['enabled'] as bool? ?? true,
      autoStart: map['autoStart'] as bool? ?? true,
      timeout: map['timeout'] as int?,
      retryConfig: map['retryConfig'] != null
          ? McpRetryConfig.fromMap(map['retryConfig'] as Map<String, dynamic>)
          : null,
    );
  }

  /// 转换为Map
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      if (displayName != null) 'displayName': displayName,
      if (description != null) 'description': description,
      'transportType': transportType,
      if (command != null) 'command': command,
      if (args != null) 'args': args,
      if (env != null) 'env': env,
      if (url != null) 'url': url,
      if (headers != null) 'headers': headers,
      'enabled': enabled,
      'autoStart': autoStart,
      if (timeout != null) 'timeout': timeout,
      if (retryConfig != null) 'retryConfig': retryConfig!.toMap(),
    };
  }

  /// 复制并修改
  McpServerConfig copyWith({
    String? name,
    String? displayName,
    String? description,
    String? transportType,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    String? url,
    Map<String, String>? headers,
    bool? enabled,
    bool? autoStart,
    int? timeout,
    McpRetryConfig? retryConfig,
  }) {
    return McpServerConfig(
      name: name ?? this.name,
      displayName: displayName ?? this.displayName,
      description: description ?? this.description,
      transportType: transportType ?? this.transportType,
      command: command ?? this.command,
      args: args ?? this.args,
      env: env ?? this.env,
      url: url ?? this.url,
      headers: headers ?? this.headers,
      enabled: enabled ?? this.enabled,
      autoStart: autoStart ?? this.autoStart,
      timeout: timeout ?? this.timeout,
      retryConfig: retryConfig ?? this.retryConfig,
    );
  }

  /// 创建stdio类型的配置
  factory McpServerConfig.stdio({
    required String name,
    String? displayName,
    String? description,
    required String command,
    List<String>? args,
    Map<String, String>? env,
    bool enabled = true,
    bool autoStart = true,
    int? timeout,
    McpRetryConfig? retryConfig,
  }) {
    return McpServerConfig(
      name: name,
      displayName: displayName,
      description: description,
      transportType: 'stdio',
      command: command,
      args: args,
      env: env,
      enabled: enabled,
      autoStart: autoStart,
      timeout: timeout,
      retryConfig: retryConfig,
    );
  }

  /// 创建SSE类型的配置
  factory McpServerConfig.sse({
    required String name,
    String? displayName,
    String? description,
    required String url,
    Map<String, String>? headers,
    bool enabled = true,
    bool autoStart = true,
    int? timeout,
    McpRetryConfig? retryConfig,
  }) {
    return McpServerConfig(
      name: name,
      displayName: displayName,
      description: description,
      transportType: 'sse',
      url: url,
      headers: headers,
      enabled: enabled,
      autoStart: autoStart,
      timeout: timeout,
      retryConfig: retryConfig,
    );
  }

  /// 创建HTTP类型的配置
  factory McpServerConfig.http({
    required String name,
    String? displayName,
    String? description,
    required String url,
    Map<String, String>? headers,
    bool enabled = true,
    bool autoStart = true,
    int? timeout,
    McpRetryConfig? retryConfig,
  }) {
    return McpServerConfig(
      name: name,
      displayName: displayName,
      description: description,
      transportType: 'http',
      url: url,
      headers: headers,
      enabled: enabled,
      autoStart: autoStart,
      timeout: timeout,
      retryConfig: retryConfig,
    );
  }

  /// 从JSON字符串解析配置列表
  ///
  /// 支持两种格式：
  /// - 新格式：List<McpServerConfig>
  /// - 旧格式：Map<String, dynamic>（自动转换为List）
  static List<McpServerConfig> parseList(String? jsonString) {
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }

    try {
      final decoded = _decodeJson(jsonString);
      if (decoded == null) return [];

      // 新格式：List
      if (decoded is List) {
        return decoded
            .map((e) => McpServerConfig.fromMap(e as Map<String, dynamic>))
            .toList();
      }

      // 旧格式：Map - 转换为List
      if (decoded is Map<String, dynamic>) {
        return _convertLegacyMap(decoded);
      }

      return [];
    } catch (e) {
      return [];
    }
  }

  /// 将配置列表转换为JSON字符串
  static String toJsonString(List<McpServerConfig> configs) {
    final list = configs.map((c) => c.toMap()).toList();
    return _encodeJson(list);
  }

  /// 转换旧格式Map为新格式List
  ///
  /// 旧格式示例：
  /// ```json
  /// {
  ///   "serverName": {
  ///     "command": "npx",
  ///     "args": ["-y", "@modelcontextprotocol/server-filesystem"],
  ///     "env": {}
  ///   }
  /// }
  /// ```
  static List<McpServerConfig> _convertLegacyMap(Map<String, dynamic> legacy) {
    final result = <McpServerConfig>[];

    for (final entry in legacy.entries) {
      final serverName = entry.key;
      final value = entry.value;

      if (value is Map<String, dynamic>) {
        // 从旧格式转换
        result.add(
          McpServerConfig.fromMap({
            'name': serverName,
            'transportType': 'stdio',
            ...value,
          }),
        );
      }
    }

    return result;
  }

  static dynamic _decodeJson(String jsonString) {
    return jsonDecode(jsonString);
  }

  static String _encodeJson(dynamic value) {
    return jsonEncode(value);
  }

  @override
  String toString() {
    return 'McpServerConfig(name: $name, transportType: $transportType, enabled: $enabled)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is McpServerConfig &&
        other.name == name &&
        other.transportType == transportType &&
        other.command == command &&
        other.enabled == enabled;
  }

  @override
  int get hashCode => Object.hash(name, transportType, command, enabled);
}
