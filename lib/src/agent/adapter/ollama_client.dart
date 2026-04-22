import 'dart:async';

import 'package:dio/dio.dart';

import '../../utils/logger.dart';

/// Ollama 模型基本信息
///
/// 对应 `GET /api/tags` 返回的模型列表项。
class OllamaModelInfo {
  /// 模型名称（含 tag），如 "llama3:latest"、"qwen2.5:7b"
  final String name;

  /// 模型内部标识（通常与 [name] 相同）
  final String model;

  /// 模型最后修改时间
  final DateTime? modifiedAt;

  /// 模型文件大小（字节）
  final int? size;

  /// 模型摘要（digest）
  final String? digest;

  const OllamaModelInfo({
    required this.name,
    required this.model,
    this.modifiedAt,
    this.size,
    this.digest,
  });

  /// 从 JSON Map 创建
  factory OllamaModelInfo.fromMap(Map<String, dynamic> map) {
    return OllamaModelInfo(
      name: map['name'] as String? ?? '',
      model: map['model'] as String? ?? '',
      modifiedAt: _parseDateTime(map['modified_at']),
      size: map['size'] as int?,
      digest: map['digest'] as String?,
    );
  }

  /// 转换为 Map
  Map<String, dynamic> toMap() => {
        'name': name,
        'model': model,
        'modifiedAt': modifiedAt?.toIso8601String(),
        'size': size,
        'digest': digest,
      };

  @override
  String toString() => 'OllamaModelInfo(name: $name, size: $size)';
}

/// Ollama 模型详细信息
///
/// 对应 `POST /api/show` 返回的模型详情。
class OllamaModelDetail {
  /// 模型全名（含 tag）
  final String name;

  /// 模型修改时间
  final DateTime? modifiedAt;

  /// 模型家族，如 "llama"、"qwen2"、"gemma"
  final String? family;

  /// 参数量级，如 "8B"、"70B"、"0.5B"
  final String? parameterSize;

  /// 量化级别，如 "Q4_0"、"Q8_0"、"F16"
  final String? quantizationLevel;

  /// 上下文窗口长度
  final int? contextLength;

  /// 模型系统提示词
  final String? system;

  /// 模型模板
  final String? template;

  /// 模型许可证
  final String? license;

  const OllamaModelDetail({
    required this.name,
    this.modifiedAt,
    this.family,
    this.parameterSize,
    this.quantizationLevel,
    this.contextLength,
    this.system,
    this.template,
    this.license,
  });

  /// 从 JSON Map 创建
  ///
  /// Ollama `/api/show` 返回格式：
  /// ```json
  /// {
  ///   "name": "llama3:latest",
  ///   "modified_at": "2024-01-01T00:00:00Z",
  ///   "details": {
  ///     "parent_model": "",
  ///     "format": "gguf",
  ///     "family": "llama",
  ///     "families": ["llama"],
  ///     "parameter_size": "8B",
  ///     "quantization_level": "Q4_0"
  ///   },
  ///   "model_info": {
  ///     "llama.context_length": 8192,
  ///     ...
  ///   }
  /// }
  /// ```
  factory OllamaModelDetail.fromMap(Map<String, dynamic> map) {
    final details = map['details'] as Map<String, dynamic>?;
    final modelInfo = map['model_info'] as Map<String, dynamic>?;

    // 从 model_info 中提取 context_length
    // 不同模型家族的 key 不同：llama.context_length, qwen2.context_length 等
    int? contextLength;
    if (modelInfo != null) {
      for (final key in modelInfo.keys) {
        if (key.endsWith('.context_length') || key.endsWith('.context_length ')) {
          contextLength = modelInfo[key] as int?;
          break;
        }
      }
    }

    return OllamaModelDetail(
      name: map['name'] as String? ?? '',
      modifiedAt: _parseDateTime(map['modified_at']),
      family: details?['family'] as String?,
      parameterSize: details?['parameter_size'] as String?,
      quantizationLevel: details?['quantization_level'] as String?,
      contextLength: contextLength,
      system: map['system'] as String?,
      template: map['template'] as String?,
      license: map['license'] as String?,
    );
  }

  /// 转换为 Map
  Map<String, dynamic> toMap() => {
        'name': name,
        'modifiedAt': modifiedAt?.toIso8601String(),
        'family': family,
        'parameterSize': parameterSize,
        'quantizationLevel': quantizationLevel,
        'contextLength': contextLength,
        'system': system,
        'template': template,
        'license': license,
      };

  /// 格式化显示名称，如 "llama3:latest (8B, Q4_0)"
  String get displayName {
    final parts = <String>[name];
    final detailParts = <String>[];
    if (parameterSize != null) detailParts.add(parameterSize!);
    if (quantizationLevel != null) detailParts.add(quantizationLevel!);
    if (detailParts.isNotEmpty) {
      parts.add('(${detailParts.join(', ')})');
    }
    return parts.join(' ');
  }

  @override
  String toString() =>
      'OllamaModelDetail(name: $name, family: $family, '
      'parameterSize: $parameterSize, quantizationLevel: $quantizationLevel, '
      'contextLength: $contextLength)';
}

/// Ollama 健康检查结果
class OllamaHealthResult {
  /// 服务是否可用
  final bool isHealthy;

  /// 错误信息（不可用时）
  final String? error;

  /// Ollama 版本号
  final String? version;

  /// 已安装模型数量
  final int modelCount;

  /// 响应耗时（毫秒）
  final int latencyMs;

  const OllamaHealthResult({
    required this.isHealthy,
    this.error,
    this.version,
    this.modelCount = 0,
    required this.latencyMs,
  });

  @override
  String toString() {
    if (isHealthy) {
      return '✅ Ollama 可用 ($latencyMs ms, $modelCount 个模型'
          '${version != null ? ', v$version' : ''})';
    }
    return '❌ Ollama 不可用 ($latencyMs ms): $error';
  }
}

/// Ollama REST API 客户端
///
/// 直接调用 Ollama 原生 REST API，提供模型发现、健康检查等功能。
/// 不依赖 llm_dart，使用 dio 进行 HTTP 请求。
///
/// 用法：
/// ```dart
/// final client = OllamaClient(); // 默认 http://localhost:11434
/// final healthy = await client.isHealthy();
/// if (healthy) {
///   final models = await client.listModels();
///   for (final m in models) {
///     print('${m.name} (${m.size} bytes)');
///   }
/// }
/// ```
class OllamaClient {
  static final _log = Logger('OllamaClient');

  /// 默认 Ollama 服务地址
  static const String defaultBaseUrl = 'http://localhost:11434';

  /// Ollama 服务基地址
  final String baseUrl;

  /// HTTP 客户端
  final Dio _dio;

  /// 请求超时时间
  final Duration timeout;

  /// 创建 OllamaClient
  ///
  /// [baseUrl] Ollama 服务地址，默认 `http://localhost:11434`
  /// [timeout] 请求超时时间，默认 10 秒
  OllamaClient({
    String? baseUrl,
    Duration? timeout,
  })  : baseUrl = baseUrl?.replaceAll(RegExp(r'/+$'), '') ?? defaultBaseUrl,
        timeout = timeout ?? const Duration(seconds: 10),
        _dio = Dio();

  /// 健康检查
  ///
  /// 通过 `GET /api/tags` 检测 Ollama 服务是否可用。
  /// 返回 `true` 表示服务正常。
  Future<bool> isHealthy() async {
    try {
      final response = await _dio.get(
        '$baseUrl/api/tags',
        options: Options(
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );
      return response.statusCode == 200;
    } catch (e) {
      _log.debug('Ollama health check failed: $e');
      return false;
    }
  }

  /// 详细健康检查
  ///
  /// 返回 [OllamaHealthResult]，包含服务状态、版本号、模型数量等信息。
  Future<OllamaHealthResult> healthCheck() async {
    final stopwatch = Stopwatch()..start();

    try {
      // 获取模型列表（同时验证服务可用性）
      final tagsResponse = await _dio.get(
        '$baseUrl/api/tags',
        options: Options(
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );
      stopwatch.stop();

      if (tagsResponse.statusCode != 200) {
        return OllamaHealthResult(
          isHealthy: false,
          error: 'HTTP ${tagsResponse.statusCode}',
          latencyMs: stopwatch.elapsedMilliseconds,
        );
      }

      final data = tagsResponse.data as Map<String, dynamic>;
      final models = (data['models'] as List?) ?? [];

      // 尝试获取版本号（从 /api/version，部分 Ollama 版本支持）
      String? version;
      try {
        final versionResponse = await _dio.get(
          '$baseUrl/api/version',
          options: Options(
            sendTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
          ),
        );
        version = versionResponse.data?['version'] as String?;
      } catch (_) {
        // 版本接口不可用，忽略
      }

      return OllamaHealthResult(
        isHealthy: true,
        version: version,
        modelCount: models.length,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on DioException catch (e) {
      stopwatch.stop();
      final error = formatDioError(e);
      return OllamaHealthResult(
        isHealthy: false,
        error: error,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } catch (e) {
      stopwatch.stop();
      return OllamaHealthResult(
        isHealthy: false,
        error: e.toString(),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  /// 列出已安装模型
  ///
  /// 调用 `GET /api/tags` 返回本地已安装的模型列表。
  Future<List<OllamaModelInfo>> listModels() async {
    try {
      final response = await _dio.get(
        '$baseUrl/api/tags',
        options: Options(
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );

      if (response.statusCode != 200) {
        _log.warn('listModels returned HTTP ${response.statusCode}');
        return [];
      }

      final data = response.data as Map<String, dynamic>;
      final modelsJson = data['models'] as List? ?? [];

      return modelsJson
          .map((m) => OllamaModelInfo.fromMap(m as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      _log.error('listModels failed: ${formatDioError(e)}');
      rethrow;
    } catch (e) {
      _log.error('listModels failed: $e');
      rethrow;
    }
  }

  /// 获取模型详细信息
  ///
  /// 调用 `POST /api/show` 返回指定模型的详细信息，包括参数量、量化级别、上下文长度等。
  ///
  /// [modelName] 模型名称，如 "llama3"、"qwen2.5:7b"
  Future<OllamaModelDetail?> showModel(String modelName) async {
    try {
      final response = await _dio.post(
        '$baseUrl/api/show',
        data: {'name': modelName},
        options: Options(
          sendTimeout: timeout,
          receiveTimeout: timeout,
          headers: {'Content-Type': 'application/json'},
        ),
      );

      if (response.statusCode != 200) {
        _log.warn('showModel returned HTTP ${response.statusCode}');
        return null;
      }

      return OllamaModelDetail.fromMap(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        _log.warn('Model not found: $modelName');
        return null;
      }
      _log.error('showModel failed: ${formatDioError(e)}');
      rethrow;
    } catch (e) {
      _log.error('showModel failed: $e');
      rethrow;
    }
  }

  /// 获取模型的上下文长度
  ///
  /// 优先从 [showModel] 获取，失败时返回 [defaultLength]（默认 4096）。
  Future<int> getModelContextLength(
    String modelName, {
    int defaultLength = 4096,
  }) async {
    try {
      final detail = await showModel(modelName);
      return detail?.contextLength ?? defaultLength;
    } catch (_) {
      return defaultLength;
    }
  }

  /// 格式化 DioException 为用户友好的错误信息
  ///
  /// 公开方法，供 [AiConnectionTester] 等外部类复用。
  static String formatDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionError:
        final msg = e.message?.toLowerCase() ?? '';
        if (msg.contains('refused') || msg.contains('connection refused')) {
          return 'Ollama 服务未启动，请先运行 `ollama serve`';
        }
        return '连接 Ollama 失败: ${e.message ?? "未知连接错误"}';
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接 Ollama 超时，请检查服务是否正常运行';
      case DioExceptionType.badResponse:
        final statusCode = e.response?.statusCode;
        if (statusCode == 404) {
          return '请求的模型不存在，请先运行 `ollama pull <model>` 拉取模型';
        }
        return 'Ollama 返回错误 (HTTP $statusCode): ${e.response?.statusMessage ?? '未知错误'}';
      case DioExceptionType.cancel:
        return '请求已取消';
      default:
        return '连接 Ollama 失败: ${e.message ?? e.type.toString()}';
    }
  }

  /// 释放资源
  void dispose() {
    _dio.close();
  }
}

/// 解析 Ollama 返回的时间字符串
///
/// Ollama 返回的时间格式可能为 ISO 8601 字符串或毫秒时间戳。
DateTime? _parseDateTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) {
    return DateTime.tryParse(value);
  }
  return null;
}
