import '../hive_manager.dart';
import '../entities/employee_entity.dart';

/// 员工数据存储
class EmployeeStore {
  final HiveManager _hiveManager;

  EmployeeStore({HiveManager? hiveManager})
      : _hiveManager = hiveManager ?? HiveManager.instance;

  /// 查找所有员工
  Future<List<AiEmployeeEntity>> findAll(
    String? spaceId, {
    String? keyword,
    String? status,
  }) async {
    final box = _hiveManager.employeeBox;
    final prefix = spaceId != null ? ':$spaceId:' : '::';

    var employees = box.values.where((e) {
      final key = _hiveManager.buildEmployeeKey(e.spaceId, e.uuid);
      if (!key.contains(prefix)) return false;
      if (e.deleted == 1) return false;
      if (status != null && e.status != status) return false;
      if (keyword != null &&
          keyword.isNotEmpty &&
          !e.name.toLowerCase().contains(keyword.toLowerCase()) &&
          !(e.description?.toLowerCase().contains(keyword.toLowerCase()) ??
              false)) {
        return false;
      }
      return true;
    }).toList();

    // 按置顶和排序序号排序
    employees.sort((a, b) {
      if (a.isPinned != b.isPinned) {
        return b.isPinned.compareTo(a.isPinned);
      }
      return a.sortOrder.compareTo(b.sortOrder);
    });

    return employees;
  }

  /// 查找单个员工
  Future<AiEmployeeEntity?> find(String? spaceId, String uuid) async {
    final box = _hiveManager.employeeBox;
    final key = _hiveManager.buildEmployeeKey(spaceId, uuid);
    return box.get(key);
  }

  /// 保存员工
  Future<void> save(AiEmployeeEntity entity) async {
    final box = _hiveManager.employeeBox;
    final key = _hiveManager.buildEmployeeKey(entity.spaceId, entity.uuid);
    await box.put(key, entity);
  }

  /// 删除员工（软删除）
  Future<void> delete(String? spaceId, String uuid) async {
    final box = _hiveManager.employeeBox;
    final key = _hiveManager.buildEmployeeKey(spaceId, uuid);
    final entity = box.get(key);
    if (entity != null) {
      await box.put(key, entity.copyWith(deleted: 1));
    }
  }

  /// 硬删除员工
  Future<void> hardDelete(String? spaceId, String uuid) async {
    final box = _hiveManager.employeeBox;
    final key = _hiveManager.buildEmployeeKey(spaceId, uuid);
    await box.delete(key);
  }

  /// 获取员工数量
  Future<int> count(String? spaceId, {String? status}) async {
    final employees = await findAll(spaceId, status: status);
    return employees.length;
  }

  /// 检查员工是否存在
  Future<bool> exists(String? spaceId, String uuid) async {
    final box = _hiveManager.employeeBox;
    final key = _hiveManager.buildEmployeeKey(spaceId, uuid);
    return box.containsKey(key);
  }
}
