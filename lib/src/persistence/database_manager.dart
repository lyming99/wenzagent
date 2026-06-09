import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite_async/sqlite_async.dart';

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
import 'migrations/v22_migration.dart';

/// 数据库管理器
///
/// 使用 sqlite_async 进行本地数据持久化，支持版本迁移。
/// 单例模式，提供数据库初始化、连接管理和数据清理功能。
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
///   Future<void> onUpgrade(SqliteWriteContext db) async {
///     await db.execute('ALTER TABLE employees ADD COLUMN new_field TEXT');
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

  SqliteDatabase? _db;
  bool _initialized = false;
  String? _dbPath;

  /// 缓存的数据库 schema 版本号
  int _cachedVersion = 0;

  /// 当前 schema 版本号
  static const int currentVersion = 22;

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
    V22Migration(),
  ];

  /// 获取数据库连接
  SqliteDatabase get db {
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

  /// 获取当前数据库文件的 schema 版本（缓存值）
  ///
  /// 版本在初始化时读取并缓存，如需重新读取请调用 [_readDatabaseVersion。
  int get databaseVersion => _cachedVersion;

  /// 初始化数据库
  ///
  /// [storagePath] 存储目录路径，如果为null则使用当前工作目录
  Future<void> initialize({String? storagePath}) async {
    if (_initialized) return;

    final dir = storagePath ?? Directory.current.path;
    final dbPath = p.join(dir, 'wenzagent.db');
    _dbPath = dbPath;
    _db = SqliteDatabase(path: dbPath);

    // 启用WAL模式提升并发性能
    await _db!.execute('PRAGMA journal_mode = WAL;');
    await _db!.execute('PRAGMA foreign_keys = ON;');

    // 读取当前版本并缓存
    await _readDatabaseVersion();

    // 执行版本迁移
    await _runMigrations();

    _initialized = true;
  }

  /// 从数据库读取当前 schema 版本号并缓存
  Future<void> _readDatabaseVersion() async {
    final result = await _db!.getOptional('PRAGMA user_version');
    _cachedVersion = result?['user_version'] as int? ?? 0;
  }

  /// 执行版本迁移
  ///
  /// 读取当前数据库版本，按顺序执行所有待运行的迁移。
  /// 每个迁移版本在独立事务中执行，确保原子性。
  Future<void> _runMigrations() async {
    final oldVersion = _cachedVersion;
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

      try {
        await _db!.writeTransaction((tx) async {
          await migration.onUpgrade(tx);
          await tx.execute('PRAGMA user_version = $version');
        });
        _cachedVersion = version;
        _log.info('迁移到版本 $version 完成');
      } catch (e) {
        _log.error('迁移到版本 $version 失败', e);
        rethrow;
      }
    }
  }

  /// 清空指定设备的数据
  ///
  /// [deviceId] 设备ID，如果为null则清空所有无设备绑定的数据
  Future<void> clearDevice(String? deviceId) async {
    await _db!.execute(
      'DELETE FROM employees WHERE device_id = ? OR current_device_id = ?',
      [deviceId, deviceId],
    );

    if (deviceId != null) {
      await _db!.execute(
        "DELETE FROM messages WHERE employee_id LIKE ? ESCAPE '\\'",
        ['$deviceId-%'],
      );
      await _db!.execute(
        "DELETE FROM skills WHERE employee_id LIKE ? ESCAPE '\\'",
        ['$deviceId-%'],
      );
      await _db!.execute('DELETE FROM sync_watermark WHERE device_id = ?', [
        deviceId,
      ]);
      await _db!.execute('DELETE FROM session_summary WHERE device_id = ?', [
        deviceId,
      ]);
      await _db!.execute(
        "DELETE FROM todo_task_items WHERE employee_id LIKE ? ESCAPE '\\'",
        ['$deviceId-%'],
      );
      await _db!.execute(
        "DELETE FROM todo_topics WHERE employee_id LIKE ? ESCAPE '\\'",
        ['$deviceId-%'],
      );
      await _db!.execute(
        "DELETE FROM file_operations WHERE employee_id LIKE ? ESCAPE '\\'",
        ['$deviceId-%'],
      );
    }
  }

  /// 关闭数据库连接
  Future<void> close() async {
    await _db?.close();
    _db = null;
    _initialized = false;
  }
}
