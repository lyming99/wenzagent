import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../utils/logger.dart';
import 'migrations/migration.dart';
import 'migrations/v1_migration.dart';
import 'migrations/v2_migration.dart';
import 'migrations/v3_migration.dart';
import 'migrations/v4_migration.dart';
import 'migrations/v5_migration.dart';
import 'migrations/v6_migration.dart';
import 'migrations/v7_migration.dart';
import 'migrations/v8_migration.dart';
import 'migrations/v9_migration.dart';
import 'migrations/v10_migration.dart';
import 'migrations/v11_migration.dart';
import 'migrations/v12_migration.dart';
import 'migrations/v13_migration.dart';
import 'migrations/v14_migration.dart';
import 'migrations/v15_migration.dart';
import 'migrations/v16_migration.dart';
import 'migrations/v17_migration.dart';
import 'migrations/v18_migration.dart';
import 'migrations/v19_migration.dart';
import 'migrations/v20_migration.dart';
import 'migrations/v21_migration.dart';

/// 数据库管理器
///
/// 使用 sqlite3 (纯 Dart FFI) 进行本地数据持久化，支持版本迁移。
/// 单例模式，提供数据库初始化、连接管理和数据清理功能。
///
/// ## UI 阻塞说明
///
/// sqlite3 为同步 API，单个 DB 操作通常在微秒~毫秒级完成。
/// 如需避免 UI 阻塞，调用方（如 Flutter App）可用 `Isolate.run()` 或
/// `compute()` 将 DB 调用放到后台线程。
///
/// ## 版本迁移
///
/// 当前 schema 版本由 [currentVersion] 定义。
/// 初始化时自动检测数据库版本，并按顺序执行所有待运行的迁移。
///
/// 新增迁移步骤：
/// 1. 在 `migrations/` 下新建文件，如 `v2_migration.dart`
/// 2. 继承 [Migration]，实现 [Migration.version] 和 [Migration.onUpgrade]
/// 3. 将 [currentVersion] +1
/// 4. 在 [_migrations] 列表中注册新迁移类
///
/// 示例：
/// ```dart
/// class V2Migration extends Migration {
///   @override
///   int get version => 2;
///
///   @override
///   void onUpgrade(Database db) {
///     db.execute('ALTER TABLE employees ADD COLUMN new_field TEXT');
///   }
/// }
/// ```
class DatabaseManager {
  static final _log = Logger('DatabaseManager');

  static final Map<String, DatabaseManager> _instances = {};

  /// 获取单例实例
  static DatabaseManager getInstance(String deviceId) {
    return _instances.putIfAbsent(deviceId, () => DatabaseManager._());
  }

  /// 移除指定设备的实例
  static void removeInstance(String deviceId) => _instances.remove(deviceId);

  DatabaseManager._();

  Database? _db;
  bool _initialized = false;
  String? _dbPath;

  /// 当前 schema 版本号
  static const int currentVersion = 21;

  /// 版本迁移注册表
  ///
  /// 按版本号从小到大排列，初始化时自动按顺序执行。
  static final List<Migration> _migrations = [
    V1Migration(),
    V2Migration(),
    V3Migration(),
    V4Migration(),
    V5Migration(),
    V6Migration(),
    V7Migration(),
    V8Migration(),
    V9Migration(),
    V10Migration(),
    V11Migration(),
    V12Migration(),
    V13Migration(),
    V14Migration(),
    V15Migration(),
    V16Migration(),
    V17Migration(),
    V18Migration(),
    V19Migration(),
    V20Migration(),
    V21Migration(),
  ];

  /// 获取数据库连接
  Database get db {
    if (_db == null) {
      throw StateError(
        'DatabaseManager 未初始化，请先调用 initialize()。'
        '当前实例可能尚未执行初始化流程。',
      );
    }
    return _db!;
  }

  /// 检查是否已初始化
  bool get isInitialized => _initialized;

  /// 获取当前数据库文件的 schema 版本
  int get databaseVersion {
    if (_db == null) return 0;
    final result = _db!.select('PRAGMA user_version');
    return result.first.values.first as int;
  }

  /// 初始化数据库
  ///
  /// [storagePath] 存储目录路径，如果为null则使用当前工作目录
  Future<void> initialize({String? storagePath}) async {
    if (_initialized) return;

    final dir = storagePath ?? Directory.current.path;
    final dbPath = p.join(dir, 'wenzagent.db');
    _dbPath = dbPath;
    _db = sqlite3.open(dbPath);

    // 启用WAL模式提升并发性能
    _db!.execute('PRAGMA journal_mode = WAL;');
    _db!.execute('PRAGMA foreign_keys = ON;');

    // 执行版本迁移
    _runMigrations();

    _initialized = true;
  }

  /// 执行版本迁移
  ///
  /// 读取当前数据库版本，按顺序执行所有待运行的迁移。
  /// 每个迁移版本在独立事务中执行，确保原子性。
  void _runMigrations() {
    final oldVersion = databaseVersion;
    _log.info('当前数据库版本: $oldVersion, 目标版本: $currentVersion');

    if (oldVersion >= currentVersion) return;

    final pending =
        _migrations
            .where((m) => m.version > oldVersion && m.version <= currentVersion)
            .toList()
          ..sort((a, b) => a.version.compareTo(b.version));

    for (final migration in pending) {
      final version = migration.version;
      _log.info('迁移到版本 $version ...');

      _db!.execute('BEGIN');
      try {
        migration.onUpgrade(_db!);
        _db!.execute('PRAGMA user_version = $version');
        _db!.execute('COMMIT');
        _log.info('迁移到版本 $version 完成');
      } catch (e) {
        _db!.execute('ROLLBACK');
        _log.error('迁移到版本 $version 失败', e);
        rethrow;
      }
    }
  }

  /// 清空指定设备的数据
  ///
  /// [deviceId] 设备ID，如果为null则清空所有无设备绑定的数据
  Future<void> clearDevice(String? deviceId) async {
    _db!.execute(
      'DELETE FROM employees WHERE device_id = ? OR current_device_id = ?',
      [deviceId, deviceId],
    );

    if (deviceId != null) {
      _db!.execute(
        "DELETE FROM messages WHERE employee_id LIKE ? ESCAPE '\\'",
        ['$deviceId-%'],
      );
      _db!.execute("DELETE FROM skills WHERE employee_id LIKE ? ESCAPE '\\'", [
        '$deviceId-%',
      ]);
      _db!.execute('DELETE FROM sync_watermark WHERE device_id = ?', [
        deviceId,
      ]);
      _db!.execute('DELETE FROM session_summary WHERE device_id = ?', [
        deviceId,
      ]);
      _db!.execute(
        "DELETE FROM todo_task_items WHERE employee_id LIKE ? ESCAPE '\\'",
        ['$deviceId-%'],
      );
      _db!.execute(
        "DELETE FROM todo_topics WHERE employee_id LIKE ? ESCAPE '\\'",
        ['$deviceId-%'],
      );
      _db!.execute(
        "DELETE FROM file_operations WHERE employee_id LIKE ? ESCAPE '\\'",
        ['$deviceId-%'],
      );
    }
  }

  /// 关闭数据库连接
  Future<void> close() async {
    _db?.dispose();
    _db = null;
    _initialized = false;
  }
}
