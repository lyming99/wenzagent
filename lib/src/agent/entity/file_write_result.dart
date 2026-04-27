/// 远程文件写入结果
class FileWriteResult {
  final bool success;
  final int bytesWritten;
  final String? error;

  const FileWriteResult({
    required this.success,
    this.bytesWritten = 0,
    this.error,
  });

  factory FileWriteResult.fromMap(Map<String, dynamic> map) {
    return FileWriteResult(
      success: map['success'] as bool? ?? false,
      bytesWritten: map['bytesWritten'] as int? ?? 0,
      error: map['error'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
    'success': success,
    'bytesWritten': bytesWritten,
    if (error != null) 'error': error,
  };
}
