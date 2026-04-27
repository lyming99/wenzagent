import 'dart:convert';

/// 远程文件读取结果
class FileReadResult {
  /// 文件内容（Base64 编码）
  final String contentBase64;

  /// 文件总大小（字节）
  final int fileSize;

  /// 读取起始偏移（字节）
  final int offset;

  /// 读取长度（字节）
  final int length;

  /// 内容是否被截断（因超过 maxBytes）
  final bool truncated;

  /// 错误信息
  final String? error;

  const FileReadResult({
    required this.contentBase64,
    required this.fileSize,
    this.offset = 0,
    this.length = 0,
    this.truncated = false,
    this.error,
  });

  factory FileReadResult.fromMap(Map<String, dynamic> map) {
    return FileReadResult(
      contentBase64: map['contentBase64'] as String? ?? '',
      fileSize: map['fileSize'] as int? ?? 0,
      offset: map['offset'] as int? ?? 0,
      length: map['length'] as int? ?? 0,
      truncated: map['truncated'] as bool? ?? false,
      error: map['error'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
    'contentBase64': contentBase64,
    'fileSize': fileSize,
    'offset': offset,
    'length': length,
    'truncated': truncated,
    if (error != null) 'error': error,
  };

  /// 解码 Base64 内容为原始字节
  List<int> decodeContent() => base64Decode(contentBase64);

  /// 解码 Base64 内容为字符串
  String decodeAsString() => utf8.decode(decodeContent());
}
