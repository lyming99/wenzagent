import 'dart:convert';

import '../hive_manager.dart';
import '../entities/session_entity.dart';

/// 会话数据存储
///
/// 使用employeeId作为主键：一个员工只有一个会话。
/// 使用 LazyBox 实现异步读取，避免主线程阻塞。
class SessionStore {
  final HiveManager _hiveManager;

  SessionStore({HiveManager? hiveManager})
    : _hiveManager = hiveManager ?? HiveManager.instance;

  /// 构建Session key（使用employeeId作为主键）
  String _buildKey(String employeeId) {
    return 'wenz_sess:$employeeId';
  }

  /// 解码JSON字符串为实体
  AiEmployeeSessionEntity? _decodeEntity(dynamic jsonString) {
    if (jsonString == null) return null;
    if (jsonString is String && jsonString.isNotEmpty) {
      return AiEmployeeSessionEntity.fromMap(
        jsonDecode(jsonString) as Map<String, dynamic>,
      );
    }
    return null;
  }

  /// 获取Session（主键查找）
  Future<AiEmployeeSessionEntity?> find(String employeeId) async {
    final box = _hiveManager.sessionBox;
    final key = _buildKey(employeeId);
    return _decodeEntity(await box.get(key));
  }

  /// 获取或创建Session
  /// 只需要employeeId
  /// 如果会话处于已删除状态，自动复活（清除 deleted 和 deleteTime）
  Future<AiEmployeeSessionEntity> getOrCreate(String employeeId) async {
    var session = await find(employeeId);
    if (session != null) {
      if (session.deleted == 1) {
        session = session.copyWith(
          deleted: 0,
          deleteTime: null,
          updateTime: DateTime.now(),
        );
        await save(session);
      }
      return session;
    }

    final now = DateTime.now();
    session = AiEmployeeSessionEntity(
      employeeId: employeeId,
      createTime: now,
      updateTime: now,
    );

    await save(session);
    return session;
  }

  /// 保存Session
  Future<void> save(AiEmployeeSessionEntity session) async {
    final box = _hiveManager.sessionBox;
    final key = _buildKey(session.employeeId);
    await box.put(key, jsonEncode(session.toMap()));
  }

  /// 获取所有Session（会话列表）
  Future<List<AiEmployeeSessionEntity>> findAll({
    bool includeArchived = false,
    bool includeDeleted = false,
  }) async {
    final box = _hiveManager.sessionBox;

    var sessions = <AiEmployeeSessionEntity>[];
    for (final key in box.keys) {
      final entity = _decodeEntity(await box.get(key));
      if (entity == null) continue;
      if (!includeDeleted && entity.isEffectivelyDeleted()) continue;
      if (!includeArchived && entity.isArchived == 1) continue;
      sessions.add(entity);
    }

    // 按置顶和更新时间排序
    sessions.sort((a, b) {
      if (a.isPinned != b.isPinned) {
        return b.isPinned.compareTo(a.isPinned);
      }
      return b.updateTime.compareTo(a.updateTime);
    });

    return sessions;
  }

  /// 删除Session（软删除，记录 deleteTime）
  Future<void> delete(String employeeId) async {
    final session = await find(employeeId);
    if (session != null) {
      final now = DateTime.now();
      await save(session.copyWith(
        deleted: 1,
        deleteTime: now,
        updateTime: now,
      ));
    }
  }

  /// 硬删除Session
  Future<void> hardDelete(String employeeId) async {
    final box = _hiveManager.sessionBox;
    final key = _buildKey(employeeId);
    await box.delete(key);
  }

  /// 获取会话数量
  Future<int> count() async {
    final sessions = await findAll();
    return sessions.length;
  }
}
