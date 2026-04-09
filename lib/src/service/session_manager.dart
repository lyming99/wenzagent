import 'dart:async';

import '../persistence/persistence.dart';

/// 会话变更类型
enum SessionChangeType { created, updated, deleted, archived }

/// 会话变更事件
class SessionChangeEvent {
  final SessionChangeType type;
  final String employeeId;
  final AiEmployeeSessionEntity? session;

  SessionChangeEvent({
    required this.type,
    required this.employeeId,
    this.session,
  });
}

/// 会话管理器接口
abstract class SessionManager {
  /// 获取或创建Session（只需要employeeId）
  Future<AiEmployeeSessionEntity> getOrCreateSession(String employeeId);

  /// 获取Session（主键查找）
  Future<AiEmployeeSessionEntity?> getSession(String employeeId);

  /// 获取所有Session列表（用于显示会话列表）
  Future<List<AiEmployeeSessionEntity>> getAllSessions({
    bool includeArchived = false,
  });

  /// 更新设备配置（通过session.config[deviceId]访问）
  Future<void> updateDeviceConfig(
    String employeeId,
    String deviceId, {
    String? projectUuid,
    String? providerConfig,
    String? systemPromptOverride,
  });

  /// 更新设备统计
  Future<void> updateDeviceStats(
    String employeeId,
    String deviceId, {
    int? inputTokens,
    int? outputTokens,
    int? messageCount,
  });

  /// 保存Session
  Future<void> save(AiEmployeeSessionEntity session);

  /// 删除Session
  Future<void> deleteSession(String employeeId);

  /// 归档/取消归档会话
  Future<void> archiveSession(String employeeId, bool archived);

  /// Session变更通知
  Stream<SessionChangeEvent> get onSessionChanged;
}

/// 会话管理器实现
class SessionManagerImpl implements SessionManager {
  final SessionStore _sessionStore;
  final _changeController = StreamController<SessionChangeEvent>.broadcast();

  SessionManagerImpl({SessionStore? sessionStore})
    : _sessionStore = sessionStore ?? SessionStore();

  @override
  Future<AiEmployeeSessionEntity> getOrCreateSession(
    String employeeId,
  ) async {
    final session = await _sessionStore.getOrCreate(employeeId);
    // 如果是复活（deleted 变为 0）也视为创建事件，通知列表刷新
    if (session.deleted == 0) {
      _notifyChange(SessionChangeType.created, session);
    }
    return session;
  }

  @override
  Future<AiEmployeeSessionEntity?> getSession(String employeeId) async {
    return _sessionStore.find(employeeId);
  }

  @override
  Future<List<AiEmployeeSessionEntity>> getAllSessions({
    bool includeArchived = false,
  }) async {
    return _sessionStore.findAll(includeArchived: includeArchived);
  }

  @override
  Future<void> updateDeviceConfig(
    String employeeId,
    String deviceId, {
    String? projectUuid,
    String? providerConfig,
    String? systemPromptOverride,
  }) async {
    final session = await getOrCreateSession(employeeId);
    final deviceConfig = session.getOrCreateConfig(deviceId);

    final updatedConfig = deviceConfig.copyWith(
      projectUuid: projectUuid ?? deviceConfig.projectUuid,
      providerConfig: providerConfig ?? deviceConfig.providerConfig,
      systemPromptOverride:
          systemPromptOverride ?? deviceConfig.systemPromptOverride,
      updateTime: DateTime.now(),
    );

    session.config[deviceId] = updatedConfig;
    await save(session.copyWith(updateTime: DateTime.now()));
  }

  @override
  Future<void> updateDeviceStats(
    String employeeId,
    String deviceId, {
    int? inputTokens,
    int? outputTokens,
    int? messageCount,
  }) async {
    final session = await getOrCreateSession(employeeId);
    final deviceConfig = session.getOrCreateConfig(deviceId);

    final updatedConfig = deviceConfig.copyWith(
      totalInputTokens: inputTokens ?? deviceConfig.totalInputTokens,
      totalOutputTokens: outputTokens ?? deviceConfig.totalOutputTokens,
      totalMessageCount: messageCount ?? deviceConfig.totalMessageCount,
      updateTime: DateTime.now(),
    );

    session.config[deviceId] = updatedConfig;
    await save(session.copyWith(updateTime: DateTime.now()));
  }

  @override
  Future<void> save(AiEmployeeSessionEntity session) async {
    await _sessionStore.save(session);
    _notifyChange(SessionChangeType.updated, session);
  }

  @override
  Future<void> deleteSession(String employeeId) async {
    // 使用软删除，保留记录以便同步时识别已删除状态，防止其他设备同步回写
    await _sessionStore.delete(employeeId);
    _notifyChange(SessionChangeType.deleted, employeeId);
  }

  @override
  Future<void> archiveSession(String employeeId, bool archived) async {
    final session = await getSession(employeeId);
    if (session == null) return;

    final updated = session.copyWith(
      isArchived: archived ? 1 : 0,
      updateTime: DateTime.now(),
    );
    await save(updated);
  }

  @override
  Stream<SessionChangeEvent> get onSessionChanged => _changeController.stream;

  void _notifyChange(SessionChangeType type, dynamic sessionOrEmployeeId) {
    if (sessionOrEmployeeId is AiEmployeeSessionEntity) {
      _changeController.add(
        SessionChangeEvent(
          type: type,
          employeeId: sessionOrEmployeeId.employeeId,
          session: sessionOrEmployeeId,
        ),
      );
    } else if (sessionOrEmployeeId is String) {
      _changeController.add(
        SessionChangeEvent(type: type, employeeId: sessionOrEmployeeId),
      );
    }
  }

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}
