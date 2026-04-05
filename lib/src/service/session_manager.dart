import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../persistence/persistence.dart';

/// 会话变更类型
enum SessionChangeType {
  created,
  updated,
  deleted,
  archived,
}

/// 会话变更事件
class SessionChangeEvent {
  final SessionChangeType type;
  final String sessionUuid;
  final AiEmployeeSessionEntity? session;

  SessionChangeEvent({
    required this.type,
    required this.sessionUuid,
    this.session,
  });
}

/// 会话管理器接口
abstract class SessionManager {
  /// 获取所有会话列表
  Future<List<AiEmployeeSessionEntity>> getAllSessions({
    String? employeeUuid,
    bool includeArchived = false,
  });

  /// 获取单个会话
  Future<AiEmployeeSessionEntity?> getSession(String uuid);

  /// 创建会话
  Future<AiEmployeeSessionEntity> createSession({
    required String employeeUuid,
    String? title,
    String? projectUuid,
    Map<String, dynamic>? providerConfig,
  });

  /// 更新会话
  Future<void> updateSession(AiEmployeeSessionEntity session);

  /// 删除会话（同时删除关联消息）
  Future<void> deleteSession(String uuid);

  /// 归档/取消归档会话
  Future<void> archiveSession(String uuid, bool archived);

  /// 更新会话Provider配置
  Future<void> updateSessionProviderConfig(
    String uuid,
    Map<String, dynamic> providerConfig,
  );

  /// 更新会话统计信息
  Future<void> updateSessionStats(
    String uuid, {
    int? inputTokens,
    int? outputTokens,
    int? messageCount,
  });

  /// 会话变更通知流
  Stream<SessionChangeEvent> get onSessionChanged;
}

/// 会话管理器实现
class SessionManagerImpl implements SessionManager {
  final SessionStore _sessionStore;
  final MessageStore _messageStore;
  final String? _spaceId;
  final _changeController = StreamController<SessionChangeEvent>.broadcast();

  SessionManagerImpl({
    SessionStore? sessionStore,
    MessageStore? messageStore,
    String? spaceId,
  })  : _sessionStore = sessionStore ?? SessionStore(),
        _messageStore = messageStore ?? MessageStore(),
        _spaceId = spaceId;

  @override
  Future<List<AiEmployeeSessionEntity>> getAllSessions({
    String? employeeUuid,
    bool includeArchived = false,
  }) async {
    return _sessionStore.findAll(_spaceId,
        employeeUuid: employeeUuid, includeArchived: includeArchived);
  }

  @override
  Future<AiEmployeeSessionEntity?> getSession(String uuid) async {
    return _sessionStore.find(_spaceId, uuid);
  }

  @override
  Future<AiEmployeeSessionEntity> createSession({
    required String employeeUuid,
    String? title,
    String? projectUuid,
    Map<String, dynamic>? providerConfig,
  }) async {
    final uuid = const Uuid().v4();
    final now = DateTime.now();

    final session = AiEmployeeSessionEntity(
      uuid: uuid,
      spaceId: _spaceId,
      employeeUuid: employeeUuid,
      title: title ?? '新对话',
      projectUuid: projectUuid,
      providerConfig:
          providerConfig != null ? jsonEncode(providerConfig) : null,
      createTime: now,
      updateTime: now,
    );

    await _sessionStore.save(session);
    _notifyChange(SessionChangeType.created, session);
    return session;
  }

  @override
  Future<void> updateSession(AiEmployeeSessionEntity session) async {
    final updated = session.copyWith(
      updateTime: DateTime.now(),
    );
    await _sessionStore.save(updated);
    _notifyChange(SessionChangeType.updated, updated);
  }

  @override
  Future<void> deleteSession(String uuid) async {
    // 删除会话的所有消息
    await _messageStore.deleteBySession(_spaceId, uuid);
    // 删除会话
    await _sessionStore.hardDelete(_spaceId, uuid);
    _notifyChange(SessionChangeType.deleted, uuid);
  }

  @override
  Future<void> archiveSession(String uuid, bool archived) async {
    final session = await getSession(uuid);
    if (session == null) return;

    final updated = session.copyWith(
      isArchived: archived ? 1 : 0,
      updateTime: DateTime.now(),
    );
    await _sessionStore.save(updated);
    _notifyChange(SessionChangeType.archived, updated);
  }

  @override
  Future<void> updateSessionProviderConfig(
    String uuid,
    Map<String, dynamic> providerConfig,
  ) async {
    final session = await getSession(uuid);
    if (session == null) return;

    final updated = session.copyWith(
      providerConfig: jsonEncode(providerConfig),
      updateTime: DateTime.now(),
    );
    await _sessionStore.save(updated);
    _notifyChange(SessionChangeType.updated, updated);
  }

  @override
  Future<void> updateSessionStats(
    String uuid, {
    int? inputTokens,
    int? outputTokens,
    int? messageCount,
  }) async {
    final session = await getSession(uuid);
    if (session == null) return;

    final updated = session.copyWith(
      inputTokens: inputTokens ?? session.inputTokens,
      outputTokens: outputTokens ?? session.outputTokens,
      messageCount: messageCount ?? session.messageCount,
      updateTime: DateTime.now(),
    );
    await _sessionStore.save(updated);
  }

  @override
  Stream<SessionChangeEvent> get onSessionChanged =>
      _changeController.stream;

  void _notifyChange(SessionChangeType type, dynamic sessionOrUuid) {
    if (sessionOrUuid is AiEmployeeSessionEntity) {
      _changeController.add(SessionChangeEvent(
        type: type,
        sessionUuid: sessionOrUuid.uuid,
        session: sessionOrUuid,
      ));
    } else if (sessionOrUuid is String) {
      _changeController.add(SessionChangeEvent(
        type: type,
        sessionUuid: sessionOrUuid,
      ));
    }
  }

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}
