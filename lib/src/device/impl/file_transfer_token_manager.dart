import 'dart:async';

import 'package:uuid/uuid.dart';

/// 文件传输 Token 信息
class FileTransferToken {
  final String token;
  final String deviceId;
  final String filePath;
  final String operation; // 'download' or 'upload'
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool overwrite; // 仅 upload 有效

  FileTransferToken({
    required this.token,
    required this.deviceId,
    required this.filePath,
    required this.operation,
    required this.createdAt,
    required this.expiresAt,
    this.overwrite = true,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// 文件传输 Token 管理器
///
/// 管理临时 Token 的生成、验证和过期清理。
/// Token 用于 HTTP 文件传输端点的鉴权，绑定设备路径，一次性使用。
class FileTransferTokenManager {
  static final _tokens = <String, FileTransferToken>{};
  static final _uuid = const Uuid();

  /// Token 有效期（默认 5 分钟）
  static const Duration _tokenTtl = Duration(minutes: 5);

  /// 清理定时器
  static Timer? _cleanupTimer;

  /// 生成下载 Token
  static FileTransferToken generateDownloadToken({
    required String deviceId,
    required String filePath,
  }) {
    _ensureCleanupTimer();
    final token = _uuid.v4();
    final now = DateTime.now();
    final transferToken = FileTransferToken(
      token: token,
      deviceId: deviceId,
      filePath: filePath,
      operation: 'download',
      createdAt: now,
      expiresAt: now.add(_tokenTtl),
    );
    _tokens[token] = transferToken;
    return transferToken;
  }

  /// 生成上传 Token
  static FileTransferToken generateUploadToken({
    required String deviceId,
    required String filePath,
    bool overwrite = true,
  }) {
    _ensureCleanupTimer();
    final token = _uuid.v4();
    final now = DateTime.now();
    final transferToken = FileTransferToken(
      token: token,
      deviceId: deviceId,
      filePath: filePath,
      operation: 'upload',
      createdAt: now,
      expiresAt: now.add(_tokenTtl),
      overwrite: overwrite,
    );
    _tokens[token] = transferToken;
    return transferToken;
  }

  /// 验证并消费 Token
  ///
  /// 返回 Token 信息，同时从存储中移除（一次性使用）。
  /// 如果 Token 不存在、已过期或操作不匹配，返回 null。
  static FileTransferToken? validateAndConsume(String token, String expectedOperation) {
    final transferToken = _tokens.remove(token);
    if (transferToken == null) return null;
    if (transferToken.isExpired) return null;
    if (transferToken.operation != expectedOperation) return null;
    return transferToken;
  }

  /// 仅验证 Token（不消费）
  static FileTransferToken? validate(String token, String expectedOperation) {
    final transferToken = _tokens[token];
    if (transferToken == null) return null;
    if (transferToken.isExpired) {
      _tokens.remove(token);
      return null;
    }
    if (transferToken.operation != expectedOperation) return null;
    return transferToken;
  }

  /// 启动过期清理定时器
  static void _ensureCleanupTimer() {
    _cleanupTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      _tokens.removeWhere((_, token) => token.isExpired);
    });
  }

  /// 清理所有 Token 和定时器
  static void dispose() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _tokens.clear();
  }
}
