import 'package:sqlite3/sqlite3.dart';

/// 数据库迁移基类
///
/// 每个版本对应一个子类，实现 [version] 和 [onUpgrade]。
/// 迁移在事务内执行，无需手动管理事务。
abstract class Migration {
  /// 迁移目标版本号
  int get version;

  /// 执行升级 SQL
  ///
  /// [db] 数据库连接
  void onUpgrade(Database db);
}
