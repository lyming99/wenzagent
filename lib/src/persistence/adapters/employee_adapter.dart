import 'package:hive/hive.dart';

import '../entities/employee_entity.dart';

/// AI员工实体适配器
class AiEmployeeAdapter extends TypeAdapter<AiEmployeeEntity> {
  @override
  final int typeId = 100;

  @override
  AiEmployeeEntity read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AiEmployeeEntity(
      uuid: fields[0] as String,
      spaceId: fields[1] as String?,
      name: fields[2] as String,
      avatar: fields[3] as String?,
      role: fields[4] as String? ?? 'assistant',
      status: fields[5] as String? ?? 'active',
      description: fields[6] as String?,
      systemPrompt: fields[7] as String?,
      provider: fields[8] as String?,
      model: fields[9] as String?,
      apiKey: fields[10] as String?,
      apiBaseUrl: fields[11] as String?,
      modelConfig: fields[12] as String?,
      enableTools: fields[13] as int? ?? 1,
      enableMcp: fields[14] as int? ?? 0,
      mcpConfig: fields[15] as String?,
      autoApprove: fields[16] as int? ?? 0,
      sortOrder: fields[17] as int? ?? 0,
      isPinned: fields[18] as int? ?? 0,
      deleted: fields[19] as int? ?? 0,
      createTime: fields[20] is DateTime
          ? fields[20] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(fields[20] as int? ?? 0),
      updateTime: fields[21] is DateTime
          ? fields[21] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(fields[21] as int? ?? 0),
    );
  }

  @override
  void write(BinaryWriter writer, AiEmployeeEntity obj) {
    writer
      ..writeByte(22)
      ..writeByte(0)
      ..write(obj.uuid)
      ..writeByte(1)
      ..write(obj.spaceId)
      ..writeByte(2)
      ..write(obj.name)
      ..writeByte(3)
      ..write(obj.avatar)
      ..writeByte(4)
      ..write(obj.role)
      ..writeByte(5)
      ..write(obj.status)
      ..writeByte(6)
      ..write(obj.description)
      ..writeByte(7)
      ..write(obj.systemPrompt)
      ..writeByte(8)
      ..write(obj.provider)
      ..writeByte(9)
      ..write(obj.model)
      ..writeByte(10)
      ..write(obj.apiKey)
      ..writeByte(11)
      ..write(obj.apiBaseUrl)
      ..writeByte(12)
      ..write(obj.modelConfig)
      ..writeByte(13)
      ..write(obj.enableTools)
      ..writeByte(14)
      ..write(obj.enableMcp)
      ..writeByte(15)
      ..write(obj.mcpConfig)
      ..writeByte(16)
      ..write(obj.autoApprove)
      ..writeByte(17)
      ..write(obj.sortOrder)
      ..writeByte(18)
      ..write(obj.isPinned)
      ..writeByte(19)
      ..write(obj.deleted)
      ..writeByte(20)
      ..write(obj.createTime.millisecondsSinceEpoch)
      ..writeByte(21)
      ..write(obj.updateTime.millisecondsSinceEpoch);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiEmployeeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
