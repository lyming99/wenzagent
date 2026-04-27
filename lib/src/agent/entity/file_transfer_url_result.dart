/// 远程文件下载 URL 结果
class FileDownloadUrlResult {
  /// 下载 URL
  final String url;

  /// 临时 Token（一次性，5分钟过期）
  final String token;

  /// Token 过期时间（秒）
  final int expiresIn;

  /// 文件大小（字节）
  final int fileSize;

  /// 文件名
  final String fileName;

  /// 错误信息
  final String? error;

  const FileDownloadUrlResult({
    required this.url,
    required this.token,
    this.expiresIn = 300,
    this.fileSize = 0,
    this.fileName = '',
    this.error,
  });

  factory FileDownloadUrlResult.fromMap(Map<String, dynamic> map) {
    return FileDownloadUrlResult(
      url: map['url'] as String? ?? '',
      token: map['token'] as String? ?? '',
      expiresIn: map['expiresIn'] as int? ?? 300,
      fileSize: map['fileSize'] as int? ?? 0,
      fileName: map['fileName'] as String? ?? '',
      error: map['error'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
    'url': url,
    'token': token,
    'expiresIn': expiresIn,
    'fileSize': fileSize,
    'fileName': fileName,
    if (error != null) 'error': error,
  };
}

/// 远程文件上传 URL 结果
class FileUploadUrlResult {
  /// 上传 URL
  final String url;

  /// 临时 Token（一次性，5分钟过期）
  final String token;

  /// Token 过期时间（秒）
  final int expiresIn;

  /// 错误信息
  final String? error;

  const FileUploadUrlResult({
    required this.url,
    required this.token,
    this.expiresIn = 300,
    this.error,
  });

  factory FileUploadUrlResult.fromMap(Map<String, dynamic> map) {
    return FileUploadUrlResult(
      url: map['url'] as String? ?? '',
      token: map['token'] as String? ?? '',
      expiresIn: map['expiresIn'] as int? ?? 300,
      error: map['error'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
    'url': url,
    'token': token,
    'expiresIn': expiresIn,
    if (error != null) 'error': error,
  };
}
