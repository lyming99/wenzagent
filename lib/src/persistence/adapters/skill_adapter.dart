import 'package:hive/hive.dart';

import '../entities/skill_entity.dart';

/// AI员工技能实体适配器
class AiEmployeeSkillAdapter extends TypeAdapter<AiEmployeeSkillEntity> {
  @override
  final int typeId = 103;

  @override
  AiEmployeeSkillEntity read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AiEmployeeSkillEntity(
      uuid: fields[0] as String,
      employeeUuid: fields[1] as String,
      name: fields[2] as String,
      description: fields[3] as String?,
      skillType: fields[4] as String? ?? 'mcp',
      config: fields[5] as String?,
      enabled: fields[6] as int? ?? 1,
      sortOrder: fields[7] as int? ?? 0,
      deleted: fields[8] as int? ?? 0,
      createTime: fields[9] is DateTime
          ? fields[9] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(fields[9] as int? ?? 0),
      updateTime: fields[10] is DateTime
          ? fields[10] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(fields[10] as int? ?? 0),
    );
  }

  @override
  void write(BinaryWriter writer, AiEmployeeSkillEntity obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.uuid)
      ..writeByte(1)
      ..write(obj.employeeUuid)
      ..writeByte(2)
      ..write(obj.name)
      ..writeByte(3)
      ..write(obj.description)
      ..writeByte(4)
      ..write(obj.skillType)
      ..writeByte(5)
      ..write(obj.config)
      ..writeByte(6)
      ..write(obj.enabled)
      ..writeByte(7)
      ..write(obj.sortOrder)
      ..writeByte(8)
      ..write(obj.deleted)
      ..writeByte(9)
      ..write(obj.createTime.millisecondsSinceEpoch)
      ..writeByte(10)
      ..write(obj.updateTime.millisecondsSinceEpoch);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiEmployeeSkillAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
