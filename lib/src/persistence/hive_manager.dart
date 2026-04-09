import 'package:hive/hive.dart';

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
  static const String deviceConfigBoxName = 'device_config_box';
  static const String scheduledTaskBoxName = 'scheduled_task_box';

  /// 初始化Hive
  ///
  /// [storagePath] 存储路径，如果为null则使用默认路径
  Future<void> initialize({String? storagePath}) async {
    if (_initialized) return;

    // 如果提供了存储路径，初始化Hive
    if (storagePath != null) {
      Hive.init(storagePath);
    }

    // 打开Box
    await _openBoxes();

    _initialized = true;
  }

  /// 打开所有Box（容错：遇到旧二进制数据自动删除重建）
  Future<void> _openBoxes() async {
    await Future.wait([
      _openBoxSafe(employeeBoxName),
      _openBoxSafe(sessionBoxName),
      _openBoxSafe(messageBoxName),
      _openBoxSafe(skillBoxName),
      _openBoxSafe(sessionMessagesBoxName),
      _openBoxSafe(employeeSessionsBoxName),
      _openBoxSafe(deviceConfigBoxName),
      _openBoxSafe(scheduledTaskBoxName),
    ]);
  }

  /// 安全打开单个 Box，遇到旧二进制数据时删除旧文件重建
  Future<Box> _openBoxSafe(String name) async {
    try {
      return await Hive.openBox(name);
    } catch (e) {
      print('[HiveManager] 打开 $name 失败: $e, 删除旧数据重建...');
      try {
        if (Hive.isBoxOpen(name)) {
          await Hive.box(name).close();
        }
      } catch (_) {}
      try {
        await Hive.deleteBoxFromDisk(name);
      } catch (_) {}
      return await Hive.openBox(name);
    }
  }

  /// 获取员工Box
  Box get employeeBox => Hive.box(employeeBoxName);

  /// 获取会话Box
  Box get sessionBox => Hive.box(sessionBoxName);

  /// 获取消息Box（untyped，使用 jsonEncode/jsonDecode 读写 JSON 字符串）
  Box get messageBox => Hive.box(messageBoxName);

  /// 获取技能Box
  Box get skillBox => Hive.box(skillBoxName);

  /// 获取会话消息索引Box
  Box get sessionMessagesBox => Hive.box(sessionMessagesBoxName);

  /// 获取员工会话索引Box
  Box get employeeSessionsBox => Hive.box(employeeSessionsBoxName);

  /// 获取设备配置Box
  Box get deviceConfigBox => Hive.box(deviceConfigBoxName);

  /// 获取指定Box
  Box getBox(String name) => Hive.box(name);

  /// 构建员工key（wenz_ 前缀避免与旧二进制数据冲突）
  String buildEmployeeKey(String? deviceId, String uuid) {
    return 'wenz_emp:$deviceId:$uuid';
  }

  /// 构建会话key（wenz_ 前缀避免与旧二进制数据冲突）
  String buildSessionKey(String? deviceId, String uuid) {
    return 'wenz_sess:$deviceId:$uuid';
  }

  /// 构建消息key（wenz_ 前缀避免与旧二进制数据冲突）
  String buildMessageKey(String? deviceId, String uuid) {
    return 'wenz_msg:$deviceId:$uuid';
  }

  /// 构建技能key（wenz_ 前缀避免与旧二进制数据冲突）
  String buildSkillKey(String? deviceId, String uuid) {
    return 'wenz_skill:$deviceId:$uuid';
  }

  /// 构建会话消息索引key（wenz_ 前缀避免与旧二进制数据冲突）
  String buildSessionMessagesKey(String? deviceId, String employeeId) {
    return 'wenz_sessmsgs:$deviceId:$employeeId';
  }

  /// 构建员工会话索引key（wenz_ 前缀避免与旧二进制数据冲突）
  String buildEmployeeSessionsKey(String? deviceId, String employeeId) {
    return 'wenz_empsess:$deviceId:$employeeId';
  }

  /// 构建设备配置key（wenz_ 前缀避免与旧二进制数据冲突）
  String buildDeviceConfigKey(String deviceId) {
    return 'wenz_devconf:$deviceId';
  }

  /// 清空指定设备的数据
  Future<void> clearDevice(String? deviceId) async {
    final prefix = deviceId != null ? ':$deviceId:' : '::';

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
