import 'package:sqlite3/sqlite3.dart';

import '../../utils/logger.dart';
import '../database_manager.dart';
import '../entities/session_summary_entity.dart';
import '../schemas/session_summary_schema.dart';

/// 会话摘要 Store
///
/// 管理未读计数和最新消息快照，作为唯一的权威数据源。
/// 所有操作通过 UPSERT 原子 SQL 实现，O(1) 复杂度。
class SessionSummaryStore {
  static final _log = Logger('SessionSummaryStore');

  final DatabaseManager _dbManager;

  SessionSummaryStore({String? deviceId, DatabaseManager? dbManager})
      : _dbManager = dbManager ?? DatabaseManager.getInstance(deviceId ?? '');

  Database get _db {
    if (!_dbManager.isInitialized) {
      throw StateError(
        '$runtimeType: DatabaseManager 未初始化，请先调用 initialize()。',
      );
    }
    return _dbManager.db;
  }

  /// 确保 session_summary 表存在（用于测试环境直接调用）
  void ensureTable() {
    SessionSummarySchema.create(_db);
    SessionSummarySchema.ensurePendingColumns(_db);
  }

  // ═══════════════════════════════════════════════════
  // 查询方法（全部 O(1)）
  // ═══════════════════════════════════════════════════

  /// 获取单个会话未读数（PK 查找）
  int getUnreadCount(String employeeId, {String deviceId = ''}) {
    final result = _db.select(
      'SELECT COALESCE(unread_count, 0) as cnt '
      'FROM session_summary WHERE employee_id = ? AND device_id = ?',
      [employeeId, deviceId],
    );
    if (result.isEmpty) return 0;
    return result.first['cnt'] as int;
  }

  /// 全局未读总数（单次 SUM 聚合）
  int getTotalUnreadCount({String deviceId = ''}) {
    String sql;
    List<Object?> params;
    if (deviceId.isNotEmpty) {
      sql = 'SELECT COALESCE(SUM(unread_count), 0) as total '
          'FROM session_summary WHERE device_id = ? AND unread_count > 0';
      params = [deviceId];
    } else {
      sql = 'SELECT COALESCE(SUM(unread_count), 0) as total '
          'FROM session_summary WHERE unread_count > 0';
      params = [];
    }
    final result = _db.select(sql, params);
    if (result.isEmpty) return 0;
    return result.first['total'] as int;
  }

  /// 获取最新消息快照（不查 messages 表）
  SessionSummaryEntity? getSummary(String employeeId, {String deviceId = ''}) {
    final result = _db.select(
      'SELECT * FROM session_summary WHERE employee_id = ? AND device_id = ?',
      [employeeId, deviceId],
    );
    if (result.isEmpty) return null;
    return SessionSummaryEntity.fromMap(result.first);
  }

  /// 批量获取所有摘要（会话列表一次性加载，ORDER BY last_msg_time DESC）
  List<SessionSummaryEntity> getAllSummaries({String deviceId = ''}) {
    String sql;
    List<Object?> params;
    if (deviceId.isNotEmpty) {
      sql = 'SELECT * FROM session_summary WHERE device_id = ? ORDER BY last_msg_time DESC';
      params = [deviceId];
    } else {
      sql = 'SELECT * FROM session_summary ORDER BY last_msg_time DESC';
      params = [];
    }
    return _db.select(sql, params).map((row) => SessionSummaryEntity.fromMap(row)).toList();
  }

  /// 获取有未读消息的员工 ID 列表
  List<String> getUnreadEmployeeIds({String deviceId = ''}) {
    String sql;
    List<Object?> params;
    if (deviceId.isNotEmpty) {
      sql = 'SELECT employee_id FROM session_summary WHERE device_id = ? AND unread_count > 0';
      params = [deviceId];
    } else {
      sql = 'SELECT employee_id FROM session_summary WHERE unread_count > 0';
      params = [];
    }
    return _db.select(sql, params).map((row) => row['employee_id'] as String).toList();
  }

  // ═══════════════════════════════════════════════════
  // 写入方法（原子 SQL）
  // ═══════════════════════════════════════════════════

  /// 新消息写入时更新摘要（单条 UPSERT）
  void onMessageAdded({
    required String employeeId,
    required String deviceId,
    required String role,
    required bool isRead,
    required String messageId,
    required int createTime,
    int seq = 0,
    String? content,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final delta = (role == 'assistant' && !isRead) ? 1 : 0;
    final truncatedContent = (content != null && content.length > 200)
        ? content.substring(0, 200)
        : content;

    _db.execute('''
      INSERT INTO session_summary (
        employee_id, device_id, unread_count,
        last_msg_id, last_msg_role, last_msg_content,
        last_msg_time, last_msg_seq, update_time
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(employee_id, device_id) DO UPDATE SET
        unread_count = unread_count + ?,
        last_msg_id   = CASE WHEN ? > COALESCE(session_summary.last_msg_time, 0)
                             THEN ? ELSE session_summary.last_msg_id END,
        last_msg_role = CASE WHEN ? > COALESCE(session_summary.last_msg_time, 0)
                             THEN ? ELSE session_summary.last_msg_role END,
        last_msg_content = CASE WHEN ? > COALESCE(session_summary.last_msg_time, 0)
                                THEN ? ELSE session_summary.last_msg_content END,
        last_msg_time = MAX(COALESCE(session_summary.last_msg_time, 0), ?),
        last_msg_seq  = CASE WHEN ? > COALESCE(session_summary.last_msg_time, 0)
                             THEN ? ELSE session_summary.last_msg_seq END,
        update_time   = ?
    ''', [
      employeeId, deviceId, delta,
      messageId, role, truncatedContent, createTime, seq, now,
      delta,
      createTime, messageId,
      createTime, role,
      createTime, truncatedContent,
      createTime,
      createTime, seq,
      now,
    ]);
  }

  /// 批量更新摘要（用于批量消息写入优化，减少 DB 调用次数）
  void onMessagesAdded(List<Map<String, dynamic>> messages) {
    if (messages.isEmpty) return;
    _db.execute('BEGIN');
    try {
      for (final msg in messages) {
        onMessageAdded(
          employeeId: msg['employeeId'] as String,
          deviceId: msg['deviceId'] as String? ?? '',
          role: msg['role'] as String,
          isRead: msg['isRead'] as bool? ?? false,
          messageId: msg['messageId'] as String,
          createTime: msg['createTime'] as int,
          seq: msg['seq'] as int? ?? 0,
          content: msg['content'] as String?,
        );
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 直接减少未读计数（用于 markAsReadBySeqInDb 的修复）
  ///
  /// 当 MessageStore 已经将消息标记为已读后，不能再查询 messages 表获取 delta，
  /// 因为 is_read 已被更新为 1。此时需要调用方传入已知的 affected 数量。
  void decrementUnreadCount(String employeeId, int delta, {String deviceId = ''}) {
    if (delta <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      UPDATE session_summary SET
        unread_count = MAX(unread_count - ?, 0),
        update_time = ?
      WHERE employee_id = ? AND device_id = ?
    ''', [delta, now, employeeId, deviceId]);
  }

  /// 标记已读（单次 UPDATE，O(1)）
  void markAsRead(String employeeId, {String deviceId = ''}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      INSERT INTO session_summary (employee_id, device_id, unread_count, update_time)
        VALUES (?, ?, 0, ?)
      ON CONFLICT(employee_id, device_id) DO UPDATE SET
        unread_count = 0, update_time = excluded.update_time
    ''', [employeeId, deviceId, now]);
  }

  /// 基于 seq 批量标记已读（按实际标记数量减少 unread_count）
  void markAsReadBySeq(String employeeId, int readSeq, {String deviceId = ''}) {
    // 注意：此方法在 MessageStore.markAsReadBySeq 之后调用，
    // 此时 messages 表的 is_read 已被更新为 1，所以 delta 会是 0。
    // 修复方案：使用 MessageStoreServiceImpl 中的 decrementUnreadCount 代替。
    // 此方法保留用于其他调用场景（如直接调用而非通过 markAsReadBySeqInDb）。
    final countResult = _db.select(
      'SELECT COUNT(*) as cnt FROM messages '
      'WHERE employee_id = ? AND device_id = ? AND role = ? AND is_read = 0 AND deleted = 0 AND seq <= ?',
      [employeeId, deviceId, 'assistant', readSeq],
    );
    final delta = countResult.first['cnt'] as int;
    if (delta == 0) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      UPDATE session_summary SET
        unread_count = MAX(unread_count - ?, 0),
        update_time = ?
      WHERE employee_id = ? AND device_id = ?
    ''', [delta, now, employeeId, deviceId]);
  }

  /// 全局标记已读
  void markAllAsRead({String deviceId = ''}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    String sql;
    List<Object?> params;
    if (deviceId.isNotEmpty) {
      sql = 'UPDATE session_summary SET unread_count = 0, update_time = ? WHERE device_id = ?';
      params = [now, deviceId];
    } else {
      sql = 'UPDATE session_summary SET unread_count = 0, update_time = ?';
      params = [now];
    }
    _db.execute(sql, params);
  }

  /// 软删除消息时更新摘要
  void onMessageSoftDeleted({
    required String employeeId,
    required String deviceId,
    required bool wasUnread,
    required bool wasLatest,
    String? previousMsgId,
    String? previousMsgRole,
    String? previousMsgContent,
    int? previousMsgTime,
    int? previousMsgSeq,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;

    if (wasUnread) {
      // 未读消息被删除：减少未读计数（最小为 0）
      _db.execute('''
        UPDATE session_summary SET
          unread_count = MAX(unread_count - 1, 0),
          update_time = ?
        WHERE employee_id = ? AND device_id = ?
      ''', [now, employeeId, deviceId]);
    }

    if (wasLatest && previousMsgId != null) {
      // 最新消息被删除：回退到前一条消息
      final truncatedContent = (previousMsgContent != null && previousMsgContent.length > 200)
          ? previousMsgContent.substring(0, 200)
          : previousMsgContent;
      _db.execute('''
        UPDATE session_summary SET
          last_msg_id = ?,
          last_msg_role = ?,
          last_msg_content = ?,
          last_msg_time = ?,
          last_msg_seq = ?,
          update_time = ?
        WHERE employee_id = ? AND device_id = ?
          AND last_msg_id = ?
      ''', [
        previousMsgId, previousMsgRole, truncatedContent,
        previousMsgTime, previousMsgSeq, now,
        employeeId, deviceId,
        // 匹配原来的 last_msg_id（防止并发更新导致回退到错误消息）
      ]);
    }
  }

  /// 清空会话摘要
  void deleteSummary(String employeeId, {String deviceId = ''}) {
    _db.execute(
      'DELETE FROM session_summary WHERE employee_id = ? AND device_id = ?',
      [employeeId, deviceId],
    );
  }

  // ═══════════════════════════════════════════════════
  // Pending 请求管理
  // ═══════════════════════════════════════════════════

  /// 设置待处理的权限请求
  void setPendingPermission(
    String employeeId,
    String deviceId,
    String permissionJson,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      _db.execute('''
        UPDATE session_summary SET
          pending_permission = ?,
          pending_permission_time = ?,
          update_time = ?
        WHERE employee_id = ? AND device_id = ?
      ''', [permissionJson, now, now, employeeId, deviceId]);
    } catch (e) {
      _log.warn('setPendingPermission failed, trying ensurePendingColumns: $e');
      SessionSummarySchema.ensurePendingColumns(_db);
      _db.execute('''
        UPDATE session_summary SET
          pending_permission = ?,
          pending_permission_time = ?,
          update_time = ?
        WHERE employee_id = ? AND device_id = ?
      ''', [permissionJson, now, now, employeeId, deviceId]);
    }
  }

  /// 清除待处理的权限请求
  void clearPendingPermission(String employeeId, String deviceId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      _db.execute('''
        UPDATE session_summary SET
          pending_permission = NULL,
          pending_permission_time = NULL,
          update_time = ?
        WHERE employee_id = ? AND device_id = ?
      ''', [now, employeeId, deviceId]);
    } catch (e) {
      _log.warn('clearPendingPermission failed, trying ensurePendingColumns: $e');
      SessionSummarySchema.ensurePendingColumns(_db);
      _db.execute('''
        UPDATE session_summary SET
          pending_permission = NULL,
          pending_permission_time = NULL,
          update_time = ?
        WHERE employee_id = ? AND device_id = ?
      ''', [now, employeeId, deviceId]);
    }
  }

  /// 设置待处理的确认请求
  void setPendingConfirm(
    String employeeId,
    String deviceId,
    String confirmJson,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      _db.execute('''
        UPDATE session_summary SET
          pending_confirm = ?,
          pending_confirm_time = ?,
          update_time = ?
        WHERE employee_id = ? AND device_id = ?
      ''', [confirmJson, now, now, employeeId, deviceId]);
    } catch (e) {
      _log.warn('setPendingConfirm failed, trying ensurePendingColumns: $e');
      SessionSummarySchema.ensurePendingColumns(_db);
      _db.execute('''
        UPDATE session_summary SET
          pending_confirm = ?,
          pending_confirm_time = ?,
          update_time = ?
        WHERE employee_id = ? AND device_id = ?
      ''', [confirmJson, now, now, employeeId, deviceId]);
    }
  }

  /// 清除待处理的确认请求
  void clearPendingConfirm(String employeeId, String deviceId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      _db.execute('''
        UPDATE session_summary SET
          pending_confirm = NULL,
          pending_confirm_time = NULL,
          update_time = ?
        WHERE employee_id = ? AND device_id = ?
      ''', [now, employeeId, deviceId]);
    } catch (e) {
      _log.warn('clearPendingConfirm failed, trying ensurePendingColumns: $e');
      SessionSummarySchema.ensurePendingColumns(_db);
      _db.execute('''
        UPDATE session_summary SET
          pending_confirm = NULL,
          pending_confirm_time = NULL,
          update_time = ?
        WHERE employee_id = ? AND device_id = ?
      ''', [now, employeeId, deviceId]);
    }
  }

  /// 获取所有有 pending 请求的摘要（权限或确认）
  List<SessionSummaryEntity> getPendingSummaries({String? deviceId}) {
    String sql;
    List<Object?> params;
    if (deviceId != null && deviceId.isNotEmpty) {
      sql = 'SELECT * FROM session_summary WHERE device_id = ? '
          'AND (pending_permission IS NOT NULL OR pending_confirm IS NOT NULL) '
          'ORDER BY update_time DESC';
      params = [deviceId];
    } else {
      sql = 'SELECT * FROM session_summary '
          'WHERE pending_permission IS NOT NULL OR pending_confirm IS NOT NULL '
          'ORDER BY update_time DESC';
      params = [];
    }
    return _db.select(sql, params).map((row) => SessionSummaryEntity.fromMap(row)).toList();
  }

  /// 从远程数据合并本地摘要（仅当远程数据更新时覆盖最新消息字段）
  ///
  /// 合并策略：
  /// - 最新消息字段（last_msg_*）：仅当远程 lastMsgTime 更新时才覆盖
  /// - 未读数：取本地和远程的最大值，避免因同步时序丢失未读
  /// - pending 字段：优先取非空值，两端都有则取时间较新的
  void upsertFromRemote(SessionSummaryEntity remote) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final remoteMsgTime = remote.lastMsgTime ?? 0;
    _db.execute('''
      INSERT INTO session_summary (
        employee_id, device_id, unread_count,
        last_msg_id, last_msg_role, last_msg_content,
        last_msg_time, last_msg_seq, update_time,
        pending_permission, pending_confirm,
        pending_permission_time, pending_confirm_time
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(employee_id, device_id) DO UPDATE SET
        unread_count = MAX(COALESCE(session_summary.unread_count, 0), ?),
        last_msg_id = CASE WHEN ? > COALESCE(session_summary.last_msg_time, 0)
                           THEN ? ELSE session_summary.last_msg_id END,
        last_msg_role = CASE WHEN ? > COALESCE(session_summary.last_msg_time, 0)
                             THEN ? ELSE session_summary.last_msg_role END,
        last_msg_content = CASE WHEN ? > COALESCE(session_summary.last_msg_time, 0)
                                THEN ? ELSE session_summary.last_msg_content END,
        last_msg_time = MAX(COALESCE(session_summary.last_msg_time, 0), ?),
        last_msg_seq = CASE WHEN ? > COALESCE(session_summary.last_msg_time, 0)
                            THEN ? ELSE session_summary.last_msg_seq END,
        pending_permission = CASE
          WHEN COALESCE(excluded.pending_permission, '') != '' AND COALESCE(session_summary.pending_permission, '') = ''
            THEN excluded.pending_permission
          WHEN COALESCE(session_summary.pending_permission, '') != '' AND COALESCE(excluded.pending_permission, '') = ''
            THEN session_summary.pending_permission
          WHEN COALESCE(excluded.pending_permission_time, 0) > COALESCE(session_summary.pending_permission_time, 0)
            THEN excluded.pending_permission
          ELSE session_summary.pending_permission
        END,
        pending_permission_time = CASE
          WHEN COALESCE(excluded.pending_permission, '') != '' AND COALESCE(session_summary.pending_permission, '') = ''
            THEN excluded.pending_permission_time
          WHEN COALESCE(session_summary.pending_permission, '') != '' AND COALESCE(excluded.pending_permission, '') = ''
            THEN session_summary.pending_permission_time
          WHEN COALESCE(excluded.pending_permission_time, 0) > COALESCE(session_summary.pending_permission_time, 0)
            THEN excluded.pending_permission_time
          ELSE session_summary.pending_permission_time
        END,
        pending_confirm = CASE
          WHEN COALESCE(excluded.pending_confirm, '') != '' AND COALESCE(session_summary.pending_confirm, '') = ''
            THEN excluded.pending_confirm
          WHEN COALESCE(session_summary.pending_confirm, '') != '' AND COALESCE(excluded.pending_confirm, '') = ''
            THEN session_summary.pending_confirm
          WHEN COALESCE(excluded.pending_confirm_time, 0) > COALESCE(session_summary.pending_confirm_time, 0)
            THEN excluded.pending_confirm
          ELSE session_summary.pending_confirm
        END,
        pending_confirm_time = CASE
          WHEN COALESCE(excluded.pending_confirm, '') != '' AND COALESCE(session_summary.pending_confirm, '') = ''
            THEN excluded.pending_confirm_time
          WHEN COALESCE(session_summary.pending_confirm, '') != '' AND COALESCE(excluded.pending_confirm, '') = ''
            THEN session_summary.pending_confirm_time
          WHEN COALESCE(excluded.pending_confirm_time, 0) > COALESCE(session_summary.pending_confirm_time, 0)
            THEN excluded.pending_confirm_time
          ELSE session_summary.pending_confirm_time
        END,
        update_time = ?
    ''', [
      remote.employeeId, remote.deviceId, remote.unreadCount,
      remote.lastMsgId, remote.lastMsgRole, remote.lastMsgContent,
      remoteMsgTime, remote.lastMsgSeq, now,
      remote.pendingPermission, remote.pendingConfirm,
      remote.pendingPermissionTime, remote.pendingConfirmTime,
      remote.unreadCount,
      remoteMsgTime, remote.lastMsgId,
      remoteMsgTime, remote.lastMsgRole,
      remoteMsgTime, remote.lastMsgContent,
      remoteMsgTime,
      remoteMsgTime, remote.lastMsgSeq,
      now,
    ]);
  }

  /// 从 messages 表重建单个摘要（修复/初始化用）
  void rebuildSummary(String employeeId, {String deviceId = ''}) {
    _rebuildSummaries(
      whereClause: 'employee_id = ? AND device_id = ?',
      whereParams: [employeeId, deviceId],
    );
  }

  /// 批量重建所有摘要（迁移后全量修复）
  void rebuildAllSummaries({String deviceId = ''}) {
    if (deviceId.isNotEmpty) {
      _rebuildSummaries(
        whereClause: 'device_id = ?',
        whereParams: [deviceId],
      );
    } else {
      _rebuildSummaries(whereClause: '1=1', whereParams: []);
    }
  }

  /// 重建摘要的通用实现
  ///
  /// 使用单条聚合 SQL 从 messages 表计算未读数和最新消息，
  /// 然后通过 UPSERT 写入 session_summary。
  void _rebuildSummaries({
    required String whereClause,
    required List<Object?> whereParams,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 先获取需要重建的 (employee_id, device_id) 列表
    final sessions = _db.select(
      'SELECT DISTINCT employee_id, device_id FROM messages WHERE $whereClause AND deleted = 0',
      whereParams,
    );

    if (sessions.isEmpty) return;

    _db.execute('BEGIN');
    try {
      for (final session in sessions) {
        final eid = session['employee_id'] as String;
        final did = session['device_id'] as String? ?? '';

        // 聚合未读数
        final unreadResult = _db.select(
          'SELECT COUNT(*) as cnt FROM messages '
          'WHERE employee_id = ? AND device_id = ? AND role = ? AND is_read = 0 AND deleted = 0',
          [eid, did, 'assistant'],
        );
        final unreadCount = unreadResult.first['cnt'] as int;

        // 获取最新消息
        final latestResult = _db.select(
          'SELECT uuid, role, content, create_time, seq FROM messages '
          'WHERE employee_id = ? AND device_id = ? AND deleted = 0 '
          'ORDER BY create_time DESC LIMIT 1',
          [eid, did],
        );

        if (latestResult.isEmpty) continue;
        final latest = latestResult.first;
        final content = latest['content'] as String?;
        final truncatedContent = (content != null && content.length > 200)
            ? content.substring(0, 200)
            : content;

        _db.execute('''
          INSERT INTO session_summary (
            employee_id, device_id, unread_count,
            last_msg_id, last_msg_role, last_msg_content,
            last_msg_time, last_msg_seq, update_time
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(employee_id, device_id) DO UPDATE SET
            unread_count = ?,
            last_msg_id = ?,
            last_msg_role = ?,
            last_msg_content = ?,
            last_msg_time = ?,
            last_msg_seq = ?,
            pending_permission = session_summary.pending_permission,
            pending_confirm = session_summary.pending_confirm,
            pending_permission_time = session_summary.pending_permission_time,
            pending_confirm_time = session_summary.pending_confirm_time,
            update_time = ?
        ''', [
          eid, did, unreadCount,
          latest['uuid'], latest['role'], truncatedContent,
          latest['create_time'], latest['seq'], now,
          unreadCount,
          latest['uuid'], latest['role'], truncatedContent,
          latest['create_time'], latest['seq'], now,
        ]);
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      _log.error('rebuildSummaries failed', e);
      rethrow;
    }
  }
}
