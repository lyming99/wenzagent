import 'dart:convert';
import 'dart:io';
import 'dart:async';

/// 文件上传结果
class FileUploadResult {
  final String fileId;
  final int fileSize;
  final String? sha256;

  FileUploadResult({
    required this.fileId,
    required this.fileSize,
    this.sha256,
  });
}

/// LAN 文件分块传输服务
///
/// 负责文件的分块上传和下载。
class LanChunkService {
  /// 分块大小（默认 1MB）
  final int chunkSize;

  LanChunkService({
    this.chunkSize = 1024 * 1024,
  });

  /// 上传文件
  ///
  /// [filePath] 本地文件路径
  /// [uploadUrl] 上传 URL
  /// [onProgress] 进度回调 (progress, sent, total)
  Future<FileUploadResult> uploadFile(
    String filePath,
    String uploadUrl,
    void Function(double progress, int sent, int total) onProgress,
  ) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileNotFoundException('File not found: $filePath');
    }

    final fileSize = await file.length();
    final fileName = file.uri.pathSegments.last;
    final stream = file.openRead();

    int sent = 0;

    // 使用 HttpClient 发送请求
    final client = HttpClient();
    try {
      final uri = Uri.parse(uploadUrl);
      final request = await client.postUrl(uri);

      request.headers.contentType = ContentType.binary;
      request.headers.set('x-file-name', utf8.encode(fileName).toString());
      request.headers.contentLength = fileSize;

      await for (final chunk in stream) {
        request.add(chunk);
        sent += chunk.length;
        onProgress(sent / fileSize, sent, fileSize);
      }

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        throw UploadException('Upload failed: ${response.statusCode}');
      }

      final result = jsonDecode(responseBody) as Map<String, dynamic>;
      final fileId = result['fileId'] as String;

      return FileUploadResult(
        fileId: fileId,
        fileSize: fileSize,
      );
    } finally {
      client.close();
    }
  }

  /// 下载文件
  ///
  /// [fileId] 文件ID
  /// [savePath] 保存路径
  /// [downloadUrl] 下载 URL
  /// [onProgress] 进度回调 (progress, received, total)
  Future<void> downloadFile(
    String fileId,
    String savePath,
    String downloadUrl,
    void Function(double progress, int received, int total) onProgress,
  ) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(downloadUrl);
      final request = await client.getUrl(uri);

      final response = await request.close();

      if (response.statusCode != 200) {
        throw DownloadException('Download failed: ${response.statusCode}');
      }

      final contentLength = response.contentLength;
      int received = 0;

      final file = File(savePath);
      final sink = file.openWrite();

      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress(
            contentLength > 0 ? received / contentLength : 0,
            received,
            contentLength,
          );
        }
        await sink.close();
      } catch (e) {
        await sink.close();
        await file.delete();
        rethrow;
      }
    } finally {
      client.close();
    }
  }
}

/// 文件未找到异常
class FileNotFoundException implements Exception {
  final String message;
  FileNotFoundException(this.message);

  @override
  String toString() => 'FileNotFoundException: $message';
}

/// 上传异常
class UploadException implements Exception {
  final String message;
  UploadException(this.message);

  @override
  String toString() => 'UploadException: $message';
}

/// 下载异常
class DownloadException implements Exception {
  final String message;
  DownloadException(this.message);

  @override
  String toString() => 'DownloadException: $message';
}
