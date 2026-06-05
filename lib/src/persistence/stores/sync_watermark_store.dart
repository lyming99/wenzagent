import 'package:sqlite_async/sqlite_async.dart';

import '../database_manager.dart';
import '../entities/sync_watermark_entity.dart';

/// 同步水位线数据存储
class SyncWatermarkStore {
  final DatabaseManager _dbManager;

  SyncWatermarkStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  SqliteDatabase get _db {
    if (!_dbManager.isInitialized) {
      throw StateError(
        '$runtimeType: DatabaseManager 未初始化，请先调用 initialize()。',
      );
    }
    return _dbManager.db;
  }

  /// 校验 deviceId 有效性，无效时抛出异常
  ///
  /// 设计约束：所有涉及水位线写入的操作必须传入有效的 deviceId，
  /// 禁止 null、空字符串、'default'，以便通过日志快速定位问题。
  void _validateDeviceId(String? deviceId, String caller) {
    if (deviceId == null || deviceId.isEmpty || deviceId == 'default') {
      throw StateError(
        '[SyncWatermarkStore] deviceId 无效 (value="$deviceId"), '
        '调用来源: $caller。'
        'deviceId 不允许为 null、空字符串或 "default"，必须传入真实设备标识。',
      );
    }
  }

  /// 获取指定 employee + device 的水位线
  Future<SyncWatermarkEntity?> getWatermark(String employeeId, {String deviceId = ''}) async {
    final resultSet = await _db.getAll(
      'SELECT * FROM sync_watermark WHERE employee_id = ? AND device_id = ?',
      [employeeId, deviceId],
    );
    for (final row in resultSet) {
      return SyncWatermarkEntity.fromMap({
        'employeeId': row['employee_id'] as String,
        'deviceId': row['device_id'] as String? ?? '',
        'lastSeq': row['last_seq'] as int,
        'clearSeq': row['clear_seq'] as int?,
        'updateTime': row['update_time'] as int,
      });
    }
    return null;
  }

  /// 获取指定 employee + device 的 last_seq，不存在返回 0
  Future<int> getLastSeq(String employeeId, {String deviceId = ''}) async {
    final watermark = await getWatermark(employeeId, deviceId: deviceId);
    return watermark?.lastSeq ?? 0;
  }

  /// 更新或插入水位线
  Future<void> upsert(SyncWatermarkEntity entity) async {
    await _db.execute('''
      INSERT OR REPLACE INTO sync_watermark (employee_id, device_id, last_seq, clear_seq, update_time)
        VALUES (?, ?, ?, ?, ?)
    ''', [
      entity.employeeId,
      entity.deviceId,
      entity.lastSeq,
      entity.clearSeq,
      entity.updateTime.millisecondsSinceEpoch,
    ]);
  }

  /// 更新指定 employee + device 的 last_seq
  ///
  /// 使用 MAX 语义：只在 lastSeq 大于当前值时才更新，
  /// 防止推送和拉取并发时水位线回退。
  Future<void> updateLastSeq(String employeeId, int lastSeq, {String deviceId = ''}) async {
    _validateDeviceId(deviceId, 'updateLastSeq');
    await _db.execute('''
      INSERT INTO sync_watermark (employee_id, device_id, last_seq, update_time)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(employee_id, device_id) DO UPDATE SET
          last_seq = MAX(last_seq, excluded.last_seq),
          update_time = excluded.update_time
    ''', [
      employeeId,
      deviceId,
      lastSeq,
      DateTime.now().millisecondsSinceEpoch,
    ]);
  }

  /// 强制重置指定 employee + device 的 last_seq
  ///
  /// 与 updateLastSeq 不同，此方法直接设置 last_seq 值。
  /// 用于清空会话后需要将水位线设置为 maxSeq 的场景。
  ///
  /// [enforceMax] 为 true 时（默认），使用 MAX 语义防止水位线回退；
  /// 为 false 时直接设置值（仅用于需要真正归零的特殊场景）。
  Future<void> resetLastSeq(String employeeId, int lastSeq,
      {String deviceId = '', bool enforceMax = true}) async {
    if (enforceMax) {
      // MAX 语义：只增不减，防止清空会话等场景意外降低水位线
      await _db.execute('''
        INSERT INTO sync_watermark (employee_id, device_id, last_seq, update_time)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(employee_id, device_id) DO UPDATE SET
            last_seq = MAX(last_seq, excluded.last_seq),
            update_time = excluded.update_time
      ''', [
        employeeId,
        deviceId,
        lastSeq,
        DateTime.now().millisecondsSinceEpoch,
      ]);
    } else {
      // 直接设置值，不受 MAX 语义限制（仅用于特殊场景）
      await _db.execute('''
        INSERT INTO sync_watermark (employee_id, device_id, last_seq, update_time)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(employee_id, device_id) DO UPDATE SET
            last_seq = excluded.last_seq,
            update_time = excluded.update_time
      ''', [
        employeeId,
        deviceId,
        lastSeq,
        DateTime.now().millisecondsSinceEpoch,
      ]);
    }
  }

  /// 获取清空水位线，不存在或已清除返回 null
  Future<int?> getClearSeq(String employeeId, {String deviceId = ''}) async {
    final watermark = await getWatermark(employeeId, deviceId: deviceId);
    return watermark?.clearSeq;
  }

  /// 设置清空水位线
  ///
  /// 客户端同步时检测到此值，应删除本地所有 seq < clearSeq 的消息。
  /// 如果已有 clear_seq，只在新值更大时才更新（防止回退）。
  ///
  /// INSERT 分支使用子查询保留已有 last_seq，避免首次插入时将 last_seq 硬编码为 0
  /// 导致后续增量同步从 0 开始全量拉取。
  Future<void> setClearSeq(String employeeId, int clearSeq, {String deviceId = ''}) async {
    await _db.execute('''
      INSERT INTO sync_watermark (employee_id, device_id, last_seq, clear_seq, update_time)
        VALUES (?, ?,
          COALESCE((SELECT last_seq FROM sync_watermark WHERE employee_id = ? AND device_id = ?), 0),
          ?, ?)
        ON CONFLICT(employee_id, device_id) DO UPDATE SET
          clear_seq = MAX(COALESCE(clear_seq, 0), excluded.clear_seq),
          update_time = excluded.update_time
    ''', [
      employeeId,
      deviceId,
      employeeId,
      deviceId,
      clearSeq,
      DateTime.now().millisecondsSinceEpoch,
    ]);
  }

  /// 清除清空水位线标记
  ///
  /// 客户端处理完清空操作后调用，将 clear_seq 重置为 NULL。
  Future<void> clearClearSeq(String employeeId, {String deviceId = ''}) async {
    await _db.execute('''
      UPDATE sync_watermark SET clear_seq = NULL, update_time = ?
        WHERE employee_id = ? AND device_id = ?
    ''', [
      DateTime.now().millisecondsSinceEpoch,
      employeeId,
      deviceId,
    ]);
  }
}
