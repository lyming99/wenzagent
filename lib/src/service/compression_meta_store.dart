import 'package:sqlite3/sqlite3.dart';

import '../utils/logger.dart';
import '../persistence/database_manager.dart';
import '../persistence/entities/compression_meta_entity.dart';

/// 上下文压缩元数据 Store
///
/// 管理会话级别的压缩状态（prune_start_id 消息 UUID、冷却计数）。
/// DB 只记录压缩位置，具体压缩在内存中完成。
class CompressionMetaStore {
  static final _log = Logger('CompressionMetaStore');

  DatabaseManager get _dbManager => __dbManager;
  final DatabaseManager __dbManager;

  CompressionMetaStore({String? deviceId, DatabaseManager? dbManager})
      : __dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  Database get _db => __dbManager.db;

  // ═══════════════════════════════════════════════════
  // 查询
  // ═══════════════════════════════════════════════════

  /// 获取压缩元数据（PK 查找）
  CompressionMetaEntity? getMeta(String employeeId, String deviceId) {
    final result = _db.select(
      'SELECT * FROM context_compression_meta '
      'WHERE employee_id = ? AND device_id = ?',
      [employeeId, deviceId],
    );
    if (result.isEmpty) return null;
    return CompressionMetaEntity.fromMap(result.first);
  }

  // ═══════════════════════════════════════════════════
  // 写入（原子 UPSERT）
  // ═══════════════════════════════════════════════════

  /// 保存压缩元数据（INSERT OR REPLACE）
  void saveMeta(CompressionMetaEntity meta) {
    final now = DateTime.now().millisecondsSinceEpoch;
    meta.updateTime = now;

    _db.execute('''
      INSERT INTO context_compression_meta (
        employee_id, device_id, prune_start_id,
        last_compression_time,
        messages_since_compression, update_time
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(employee_id, device_id) DO UPDATE SET
        prune_start_id = excluded.prune_start_id,
        last_compression_time = excluded.last_compression_time,
        messages_since_compression = excluded.messages_since_compression,
        update_time = excluded.update_time
    ''', [
      meta.employeeId,
      meta.deviceId,
      meta.pruneStartId,
      meta.lastCompressionTime,
      meta.messagesSinceCompression,
      meta.updateTime,
    ]);
  }

  /// 递增冷却计数（每条新消息后调用）
  void incrementCoolDown(String employeeId, String deviceId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      UPDATE context_compression_meta SET
        messages_since_compression = messages_since_compression + 1,
        update_time = ?
      WHERE employee_id = ? AND device_id = ?
    ''', [now, employeeId, deviceId]);
  }

  /// 重置冷却计数（压缩完成后调用）
  void resetCoolDown(String employeeId, String deviceId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      UPDATE context_compression_meta SET
        messages_since_compression = 0,
        last_compression_time = ?,
        update_time = ?
      WHERE employee_id = ? AND device_id = ?
    ''', [now, now, employeeId, deviceId]);
  }

  // ═══════════════════════════════════════════════════
  // 删除
  // ═══════════════════════════════════════════════════

  /// 删除压缩元数据（清空会话时调用）
  void deleteMeta(String employeeId, String deviceId) {
    _db.execute(
      'DELETE FROM context_compression_meta '
      'WHERE employee_id = ? AND device_id = ?',
      [employeeId, deviceId],
    );
  }
}
