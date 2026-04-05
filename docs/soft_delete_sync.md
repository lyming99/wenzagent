# 软删除同步功能说明

## 概述

员工同步现在完整支持**软删除（Soft Delete）**的同步与合并，使用 `deletedTime` 字段来判断删除操作的先后顺序。

## 新增字段

### AiEmployeeEntity 新增 `deletedTime` 字段

```dart
/// 是否已删除
int deleted;

/// 删除时间（软删除时使用）
DateTime? deletedTime;
```

**位置**: [employee_entity.dart](file:///d:/project/GitHub/wenzagent/lib/src/persistence/entities/employee_entity.dart#L77-L79)

## 软删除逻辑

### 1. 软删除时设置 deletedTime

当调用 `deleteEmployee()` 时，会自动设置：
- `deleted = 1`
- `deletedTime = DateTime.now()`

**位置**: [employee_store.dart](file:///d:/project/GitHub/wenzagent/lib/src/persistence/stores/employee_store.dart#L60-L75)

```dart
Future<void> delete(String? spaceId, String uuid) async {
  final box = _hiveManager.employeeBox;
  final key = _hiveManager.buildEmployeeKey(spaceId, uuid);
  final entity = box.get(key);
  if (entity != null) {
    // 软删除时设置 deleted=1 和 deletedTime
    await box.put(
      key,
      entity.copyWith(
        deleted: 1,
        deletedTime: DateTime.now(),
      ),
    );
  }
}
```

### 2. 同步时的软删除合并策略

**位置**: [device_client_impl.dart](file:///d:/project/GitHub/wenzagent/lib/src/device/impl/device_client_impl.dart#L856-L919)

```dart
if (existing == null) {
  // 本地不存在 → 创建（包括已删除的员工）
  await _employeeManager.createEmployee(employee);
} else {
  // 优先比较 deletedTime（如果任一员工被删除）
  if (employee.deleted == 1 || existing.deleted == 1) {
    // 至少一方被删除，比较 deletedTime
    final remoteDeletedTime = employee.deletedTime;
    final localDeletedTime = existing.deletedTime;
    
    if (remoteDeletedTime != null && localDeletedTime != null) {
      // 双方都有 deletedTime，比较哪个更新
      if (remoteDeletedTime.isAfter(localDeletedTime)) {
        // 远程删除更新 → 同步删除状态
        await _employeeManager.updateEmployee(
          employee.copyWith(updateTime: DateTime.now()),
        );
      }
      // 否则保留本地的删除状态
    } else if (remoteDeletedTime != null) {
      // 远程已删除，本地未删除 → 标记删除
      await _employeeManager.updateEmployee(
        employee.copyWith(updateTime: DateTime.now()),
      );
    }
    // 如果只有本地删除了，保留本地状态
  } else {
    // 都未删除，正常比较 updateTime
    if (employee.updateTime.isAfter(existing.updateTime)) {
      await _employeeManager.updateEmployee(employee);
    }
  }
}
```

## 合并策略详解

### 场景 1: 远程删除，本地未删除

```
远程: deleted=1, deletedTime=2026-04-06 10:00
本地: deleted=0, deletedTime=null

结果: 本地标记为删除（同步远程的删除状态）
```

### 场景 2: 本地删除，远程未删除

```
远程: deleted=0, deletedTime=null
本地: deleted=1, deletedTime=2026-04-06 10:00

结果: 保留本地删除状态（不恢复）
```

### 场景 3: 双方都删除，远程删除时间更新

```
远程: deleted=1, deletedTime=2026-04-06 11:00
本地: deleted=1, deletedTime=2026-04-06 10:00

结果: 更新为远程的删除状态（deletedTime 更新）
```

### 场景 4: 双方都删除，本地删除时间更新

```
远程: deleted=1, deletedTime=2026-04-06 09:00
本地: deleted=1, deletedTime=2026-04-06 10:00

结果: 保留本地删除状态（本地删除时间更新）
```

### 场景 5: 都未删除

```
远程: deleted=0, updateTime=2026-04-06 11:00
本地: deleted=0, updateTime=2026-04-06 10:00

结果: 正常比较 updateTime，更新为远程版本
```

## 测试覆盖

### 测试文件

[employee_sync_test.dart](file:///d:/project/GitHub/wenzagent/example/employee_sync_test.dart)

### 测试场景 9: 软删除同步

```dart
/// 测试软删除同步
Future<void> _testSoftDeleteSync() async {
  // 场景 1: 设备 A 删除员工，同步到设备 B
  print('  场景 1: 设备A删除员工，同步到设备B');
  
  // 创建员工并同步
  // 删除员工
  // 再次同步验证删除状态传播
  
  // 场景 2: deletedTime 比较逻辑
  print('  场景 2: deletedTime 比较逻辑');
  
  // 验证 deletedTime 的时间比较正确性
}
```

## 数据序列化

### toMap()

```dart
Map<String, dynamic> toMap() {
  return {
    // ... 其他字段
    'deleted': deleted,
    'deletedTime': deletedTime?.millisecondsSinceEpoch,  // 可为 null
    'createTime': createTime.millisecondsSinceEpoch,
    'updateTime': updateTime.millisecondsSinceEpoch,
  };
}
```

### fromMap()

```dart
factory AiEmployeeEntity.fromMap(Map<String, dynamic> map) {
  return AiEmployeeEntity(
    // ... 其他字段
    deleted: map['deleted'] as int? ?? 0,
    deletedTime: map['deletedTime'] != null
        ? (map['deletedTime'] is DateTime
            ? map['deletedTime'] as DateTime
            : DateTime.fromMillisecondsSinceEpoch(map['deletedTime'] as int))
        : null,
    // ...
  );
}
```

## copyWith() 方法

```dart
AiEmployeeEntity copyWith({
  // ... 其他参数
  int? deleted,
  DateTime? deletedTime,  // 新增
  DateTime? createTime,
  DateTime? updateTime,
}) {
  return AiEmployeeEntity(
    // ...
    deleted: deleted ?? this.deleted,
    deletedTime: deletedTime ?? this.deletedTime,  // 新增
    // ...
  );
}
```

## 注意事项

1. **deletedTime 是可选字段**
   - 未删除的员工 `deletedTime` 为 `null`
   - 只有执行软删除操作时才会设置

2. **优先级规则**
   - 删除状态的同步优先级 **高于** 普通更新
   - 只有当至少一方被删除时，才比较 `deletedTime`
   - 双方都未删除时，才比较 `updateTime`

3. **不可逆操作**
   - 一旦某设备删除了员工，另一设备即使有更新也不会恢复
   - 除非另一设备的 `deletedTime` 更新（重新删除）

4. **已删除员工的查询**
   - `getEmployees()` 会过滤掉 `deleted=1` 的员工
   - 需要使用其他方法查询已删除员工（如直接访问数据库）

## 兼容性

- ✅ 向后兼容：旧数据 `deletedTime` 为 `null`，不影响功能
- ✅ 序列化兼容：支持 `DateTime` 和 `int` 两种格式
- ✅ 同步兼容：正确处理 `null` 值比较

## 相关文件

| 文件 | 修改内容 |
|------|---------|
| [employee_entity.dart](file:///d:/project/GitHub/wenzagent/lib/src/persistence/entities/employee_entity.dart) | 添加 `deletedTime` 字段及序列化 |
| [employee_store.dart](file:///d:/project/GitHub/wenzagent/lib/src/persistence/stores/employee_store.dart) | 软删除时设置 `deletedTime` |
| [device_client_impl.dart](file:///d:/project/GitHub/wenzagent/lib/src/device/impl/device_client_impl.dart) | 同步逻辑支持 `deletedTime` 比较 |
| [employee_sync_test.dart](file:///d:/project/GitHub/wenzagent/example/employee_sync_test.dart) | 添加软删除同步测试 |
