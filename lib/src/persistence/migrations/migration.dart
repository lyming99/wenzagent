import 'package:sqlite_async/sqlite_async.dart';

/// 数据库迁移基类
///
/// 每个版本对应一个子类，实现 [version] 和 [onUpgrade]。
/// 迁移在事务内执行，无需手动管理事务。
abstract class Migration {
  /// 迁移目标版本号
  int get version;

  /// 执行升级 SQL
  ///
  /// [db] 当前迁移事务上下文
  Future<void> onUpgrade(SqliteWriteContext db);
}
