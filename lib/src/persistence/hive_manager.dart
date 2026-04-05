import 'package:hive/hive.dart';

import 'adapters/adapters.dart';
import 'entities/entities.dart';

/// Hive管理器
///
/// 负责Hive初始化、Box管理和数据清理
class HiveManager {
  static HiveManager? _instance;

  /// 获取单例实例
  static HiveManager get instance => _instance ??= HiveManager._();

  HiveManager._();

  bool _initialized = false;

  /// Box名称常量
  static const String employeeBoxName = 'employee_box';
  static const String sessionBoxName = 'session_box';
  static const String messageBoxName = 'message_box';
  static const String skillBoxName = 'skill_box';
  static const String sessionMessagesBoxName = 'session_messages';
  static const String employeeSessionsBoxName = 'employee_sessions';

  /// 初始化Hive
  ///
  /// [storagePath] 存储路径，如果为null则使用默认路径
  Future<void> initialize({String? storagePath}) async {
    if (_initialized) return;

    // 如果提供了存储路径，初始化Hive
    if (storagePath != null) {
      Hive.init(storagePath);
    }

    // 注册TypeAdapter
    _registerAdapters();

    // 打开Box
    await _openBoxes();

    _initialized = true;
  }

  /// 注册TypeAdapter
  void _registerAdapters() {
    if (!Hive.isAdapterRegistered(100)) {
      Hive.registerAdapter(AiEmployeeAdapter());
    }
    if (!Hive.isAdapterRegistered(101)) {
      Hive.registerAdapter(AiEmployeeSessionAdapter());
    }
    if (!Hive.isAdapterRegistered(102)) {
      Hive.registerAdapter(AiEmployeeMessageAdapter());
    }
    if (!Hive.isAdapterRegistered(103)) {
      Hive.registerAdapter(AiEmployeeSkillAdapter());
    }
  }

  /// 打开所有Box
  Future<void> _openBoxes() async {
    await Future.wait([
      Hive.openBox<AiEmployeeEntity>(employeeBoxName),
      Hive.openBox<AiEmployeeSessionEntity>(sessionBoxName),
      Hive.openBox<AiEmployeeMessageEntity>(messageBoxName),
      Hive.openBox<AiEmployeeSkillEntity>(skillBoxName),
      Hive.openBox<List<dynamic>>(sessionMessagesBoxName),
      Hive.openBox<List<dynamic>>(employeeSessionsBoxName),
    ]);
  }

  /// 获取员工Box
  Box<AiEmployeeEntity> get employeeBox =>
      Hive.box<AiEmployeeEntity>(employeeBoxName);

  /// 获取会话Box
  Box<AiEmployeeSessionEntity> get sessionBox =>
      Hive.box<AiEmployeeSessionEntity>(sessionBoxName);

  /// 获取消息Box
  Box<AiEmployeeMessageEntity> get messageBox =>
      Hive.box<AiEmployeeMessageEntity>(messageBoxName);

  /// 获取技能Box
  Box<AiEmployeeSkillEntity> get skillBox =>
      Hive.box<AiEmployeeSkillEntity>(skillBoxName);

  /// 获取会话消息索引Box
  Box<List<dynamic>> get sessionMessagesBox =>
      Hive.box<List<dynamic>>(sessionMessagesBoxName);

  /// 获取员工会话索引Box
  Box<List<dynamic>> get employeeSessionsBox =>
      Hive.box<List<dynamic>>(employeeSessionsBoxName);

  /// 获取指定Box
  Box<T> getBox<T>(String name) => Hive.box<T>(name);

  /// 构建员工key
  String buildEmployeeKey(String? spaceId, String uuid) {
    return 'emp:$spaceId:$uuid';
  }

  /// 构建会话key
  String buildSessionKey(String? spaceId, String uuid) {
    return 'sess:$spaceId:$uuid';
  }

  /// 构建消息key
  String buildMessageKey(String? spaceId, String uuid) {
    return 'msg:$spaceId:$uuid';
  }

  /// 构建技能key
  String buildSkillKey(String? spaceId, String uuid) {
    return 'skill:$spaceId:$uuid';
  }

  /// 构建会话消息索引key
  String buildSessionMessagesKey(String? spaceId, String employeeId) {
    return 'sessmsgs:$spaceId:$employeeId';
  }

  /// 构建员工会话索引key
  String buildEmployeeSessionsKey(String? spaceId, String employeeUuid) {
    return 'empsess:$spaceId:$employeeUuid';
  }

  /// 清空指定空间的数据
  Future<void> clearSpace(String? spaceId) async {
    final prefix = spaceId != null ? ':$spaceId:' : '::';

    // 清空员工数据
    final employeeKeys = employeeBox.keys
        .where((k) => k.toString().contains(prefix))
        .toList();
    for (final key in employeeKeys) {
      await employeeBox.delete(key);
    }

    // 清空会话数据
    final sessionKeys = sessionBox.keys
        .where((k) => k.toString().contains(prefix))
        .toList();
    for (final key in sessionKeys) {
      await sessionBox.delete(key);
    }

    // 清空消息数据
    final messageKeys = messageBox.keys
        .where((k) => k.toString().contains(prefix))
        .toList();
    for (final key in messageKeys) {
      await messageBox.delete(key);
    }

    // 清空技能数据
    final skillKeys = skillBox.keys
        .where((k) => k.toString().contains(prefix))
        .toList();
    for (final key in skillKeys) {
      await skillBox.delete(key);
    }

    // 清空索引数据
    final sessionMsgKeys = sessionMessagesBox.keys
        .where((k) => k.toString().contains(prefix))
        .toList();
    for (final key in sessionMsgKeys) {
      await sessionMessagesBox.delete(key);
    }

    final employeeSessKeys = employeeSessionsBox.keys
        .where((k) => k.toString().contains(prefix))
        .toList();
    for (final key in employeeSessKeys) {
      await employeeSessionsBox.delete(key);
    }
  }

  /// 关闭所有Box
  Future<void> close() async {
    await Hive.close();
    _initialized = false;
  }

  /// 检查是否已初始化
  bool get isInitialized => _initialized;
}
