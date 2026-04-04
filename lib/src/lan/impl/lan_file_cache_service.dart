import 'dart:io';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// 文件元数据
class FileMetadata {
  final String fileId;
  final String fileName;
  final int fileSize;
  final String sha256;
  final DateTime createdAt;
  final String filePath;

  FileMetadata({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.sha256,
    required this.createdAt,
    required this.filePath,
  });

  Map<String, dynamic> toMap() => {
        'fileId': fileId,
        'fileName': fileName,
        'fileSize': fileSize,
        'sha256': sha256,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// LAN 文件缓存服务
///
/// 负责文件的存储、读取和清理。
class LanFileCacheService {
  final _uuid = const Uuid();

  /// 缓存目录
  String? _cacheDir;

  /// 文件元数据缓存（fileId -> metadata）
  final Map<String, FileMetadata> _metadataCache = {};

  /// 缓存过期时间（默认 24 小时）
  final Duration cacheExpiry;

  LanFileCacheService({
    this.cacheExpiry = const Duration(hours: 24),
  });

  /// 确保缓存目录初始化
  Future<void> ensureInitialized({String? storageDir}) async {
    if (_cacheDir != null) return;

    if (storageDir != null) {
      _cacheDir = p.join(storageDir, 'lan_cache');
    } else {
      _cacheDir = p.join(Directory.systemTemp.path, 'wenzagent_lan_cache');
    }

    final dir = Directory(_cacheDir!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// 保存文件
  ///
  /// 返回文件ID
  Future<String> saveFile(List<int> data, String fileName) async {
    await ensureInitialized();

    final fileId = _uuid.v4();
    final hash = sha256.convert(data);
    final sha256Hash = hash.toString();
    final filePath = p.join(_cacheDir!, fileId);

    await File(filePath).writeAsBytes(data);

    final metadata = FileMetadata(
      fileId: fileId,
      fileName: fileName,
      fileSize: data.length,
      sha256: sha256Hash,
      createdAt: DateTime.now(),
      filePath: filePath,
    );

    _metadataCache[fileId] = metadata;

    return fileId;
  }

  /// 从流保存文件
  ///
  /// 返回 (fileId, fileSize)
  Future<(String, int)> saveFileFromStream(
    Stream<List<int>> stream,
    String fileName,
    int? contentLength,
  ) async {
    await ensureInitialized();

    final fileId = _uuid.v4();
    final filePath = p.join(_cacheDir!, fileId);
    final file = File(filePath);
    final sink = file.openWrite();

    final bytes = <int>[];
    int totalBytes = 0;

    try {
      await for (final chunk in stream) {
        sink.add(chunk);
        bytes.addAll(chunk);
        totalBytes += chunk.length;
      }
      await sink.close();
    } catch (e) {
      await sink.close();
      await file.delete();
      rethrow;
    }

    final hash = sha256.convert(bytes);
    final sha256Hash = hash.toString();
    final metadata = FileMetadata(
      fileId: fileId,
      fileName: fileName,
      fileSize: totalBytes,
      sha256: sha256Hash,
      createdAt: DateTime.now(),
      filePath: filePath,
    );

    _metadataCache[fileId] = metadata;

    return (fileId, totalBytes);
  }

  /// 获取文件数据
  Future<List<int>?> getFile(String fileId) async {
    final metadata = _metadataCache[fileId];
    if (metadata == null) return null;

    final file = File(metadata.filePath);
    if (!await file.exists()) return null;

    return await file.readAsBytes();
  }

  /// 获取文件流
  Stream<List<int>>? getFileStream(String fileId) {
    final metadata = _metadataCache[fileId];
    if (metadata == null) return null;

    final file = File(metadata.filePath);
    if (!file.existsSync()) return null;

    return file.openRead();
  }

  /// 获取文件元数据
  FileMetadata? getMetadata(String fileId) {
    return _metadataCache[fileId];
  }

  /// 删除文件
  Future<bool> deleteFile(String fileId) async {
    final metadata = _metadataCache.remove(fileId);
    if (metadata == null) return false;

    final file = File(metadata.filePath);
    if (await file.exists()) {
      await file.delete();
    }

    return true;
  }

  /// 清理过期缓存
  Future<int> cleanup() async {
    final now = DateTime.now();
    final toDelete = <String>[];

    for (final entry in _metadataCache.entries) {
      if (now.difference(entry.value.createdAt) > cacheExpiry) {
        toDelete.add(entry.key);
      }
    }

    for (final fileId in toDelete) {
      await deleteFile(fileId);
    }

    return toDelete.length;
  }

  /// 清空所有缓存
  Future<void> clearAll() async {
    final fileIds = _metadataCache.keys.toList();
    for (final fileId in fileIds) {
      await deleteFile(fileId);
    }
  }

  /// 获取缓存目录
  String? get cacheDir => _cacheDir;
}
