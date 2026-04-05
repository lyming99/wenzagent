import '../hive_manager.dart';
import '../entities/session_entity.dart';

/// 会话数据存储
class SessionStore {
  final HiveManager _hiveManager;

  SessionStore({HiveManager? hiveManager})
      : _hiveManager = hiveManager ?? HiveManager.instance;

  /// 查找所有会话
  Future<List<AiEmployeeSessionEntity>> findAll(
    String? spaceId, {
    String? employeeUuid,
    bool includeArchived = false,
  }) async {
    final box = _hiveManager.sessionBox;
    final prefix = spaceId != null ? ':$spaceId:' : '::';

    var sessions = box.values.where((s) {
      final key = _hiveManager.buildSessionKey(s.spaceId, s.uuid);
      if (!key.contains(prefix)) return false;
      if (s.deleted == 1) return false;
      if (!includeArchived && s.isArchived == 1) return false;
      if (employeeUuid != null && s.employeeUuid != employeeUuid) {
        return false;
      }
      return true;
    }).toList();

    // 按置顶和更新时间排序
    sessions.sort((a, b) {
      if (a.isPinned != b.isPinned) {
        return b.isPinned.compareTo(a.isPinned);
      }
      return b.updateTime.compareTo(a.updateTime);
    });

    return sessions;
  }

  /// 查找单个会话
  Future<AiEmployeeSessionEntity?> find(String? spaceId, String uuid) async {
    final box = _hiveManager.sessionBox;
    final key = _hiveManager.buildSessionKey(spaceId, uuid);
    return box.get(key);
  }

  /// 保存会话
  Future<void> save(AiEmployeeSessionEntity entity) async {
    final box = _hiveManager.sessionBox;
    final key = _hiveManager.buildSessionKey(entity.spaceId, entity.uuid);
    await box.put(key, entity);

    // 更新员工会话索引
    await _updateEmployeeSessionsIndex(entity);
  }

  /// 更新员工会话索引
  Future<void> _updateEmployeeSessionsIndex(AiEmployeeSessionEntity entity) async {
    final indexBox = _hiveManager.employeeSessionsBox;
    final indexKey = _hiveManager.buildEmployeeSessionsKey(
      entity.spaceId,
      entity.employeeUuid,
    );

    List<dynamic> sessionUuids = indexBox.get(indexKey) ?? [];
    if (!sessionUuids.contains(entity.uuid)) {
      sessionUuids = [...sessionUuids, entity.uuid];
      await indexBox.put(indexKey, sessionUuids);
    }
  }

  /// 删除会话（软删除）
  Future<void> delete(String? spaceId, String uuid) async {
    final box = _hiveManager.sessionBox;
    final key = _hiveManager.buildSessionKey(spaceId, uuid);
    final entity = box.get(key);
    if (entity != null) {
      await box.put(key, entity.copyWith(deleted: 1));
    }
  }

  /// 硬删除会话
  Future<void> hardDelete(String? spaceId, String uuid) async {
    final box = _hiveManager.sessionBox;
    final key = _hiveManager.buildSessionKey(spaceId, uuid);
    await box.delete(key);

    // 清理会话消息索引
    final msgIndexBox = _hiveManager.sessionMessagesBox;
    final msgIndexKey = _hiveManager.buildSessionMessagesKey(spaceId, uuid);
    await msgIndexBox.delete(msgIndexKey);
  }

  /// 获取员工的会话UUID列表
  Future<List<String>> getSessionUuidsByEmployee(
    String? spaceId,
    String employeeUuid,
  ) async {
    final indexBox = _hiveManager.employeeSessionsBox;
    final indexKey = _hiveManager.buildEmployeeSessionsKey(
      spaceId,
      employeeUuid,
    );
    final sessionUuids = indexBox.get(indexKey) ?? [];
    return sessionUuids.cast<String>();
  }

  /// 获取会话数量
  Future<int> count(String? spaceId, {String? employeeUuid}) async {
    final sessions = await findAll(spaceId, employeeUuid: employeeUuid);
    return sessions.length;
  }
}
