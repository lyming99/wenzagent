import 'package:hive/hive.dart';

import '../entities/session_entity.dart';

/// AI员工会话实体适配器
class AiEmployeeSessionAdapter extends TypeAdapter<AiEmployeeSessionEntity> {
  @override
  final int typeId = 101;

  @override
  AiEmployeeSessionEntity read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AiEmployeeSessionEntity(
      uuid: fields[0] as String,
      spaceId: fields[1] as String?,
      employeeUuid: fields[2] as String,
      title: fields[3] as String? ?? '新对话',
      providerConfig: fields[4] as String?,
      projectUuid: fields[5] as String?,
      contextData: fields[6] as String?,
      inputTokens: fields[7] as int? ?? 0,
      outputTokens: fields[8] as int? ?? 0,
      messageCount: fields[9] as int? ?? 0,
      isArchived: fields[10] as int? ?? 0,
      isPinned: fields[11] as int? ?? 0,
      deleted: fields[12] as int? ?? 0,
      createTime: fields[13] is DateTime
          ? fields[13] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(fields[13] as int? ?? 0),
      updateTime: fields[14] is DateTime
          ? fields[14] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(fields[14] as int? ?? 0),
    );
  }

  @override
  void write(BinaryWriter writer, AiEmployeeSessionEntity obj) {
    writer
      ..writeByte(15)
      ..writeByte(0)
      ..write(obj.uuid)
      ..writeByte(1)
      ..write(obj.spaceId)
      ..writeByte(2)
      ..write(obj.employeeUuid)
      ..writeByte(3)
      ..write(obj.title)
      ..writeByte(4)
      ..write(obj.providerConfig)
      ..writeByte(5)
      ..write(obj.projectUuid)
      ..writeByte(6)
      ..write(obj.contextData)
      ..writeByte(7)
      ..write(obj.inputTokens)
      ..writeByte(8)
      ..write(obj.outputTokens)
      ..writeByte(9)
      ..write(obj.messageCount)
      ..writeByte(10)
      ..write(obj.isArchived)
      ..writeByte(11)
      ..write(obj.isPinned)
      ..writeByte(12)
      ..write(obj.deleted)
      ..writeByte(13)
      ..write(obj.createTime.millisecondsSinceEpoch)
      ..writeByte(14)
      ..write(obj.updateTime.millisecondsSinceEpoch);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiEmployeeSessionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
