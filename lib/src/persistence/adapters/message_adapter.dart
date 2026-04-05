import 'package:hive/hive.dart';

import '../entities/message_entity.dart';

/// AI员工消息实体适配器
class AiEmployeeMessageAdapter extends TypeAdapter<AiEmployeeMessageEntity> {
  @override
  final int typeId = 102;

  @override
  AiEmployeeMessageEntity read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AiEmployeeMessageEntity(
      uuid: fields[0] as String,
      employeeId: fields[1] as String,
      role: fields[2] as String? ?? 'user',
      type: fields[3] as String? ?? 'text',
      content: fields[4] as String?,
      toolCallId: fields[5] as String?,
      toolName: fields[6] as String?,
      toolArguments: fields[7] as String?,
      toolResult: fields[8] as String?,
      toolCalls: fields[9] as String?,
      processingStatus: fields[10] as String? ?? 'none',
      processingError: fields[11] as String?,
      inputTokens: fields[12] as int?,
      outputTokens: fields[13] as int?,
      isRead: fields[14] as int? ?? 0,
      deleted: fields[15] as int? ?? 0,
      createTime: fields[16] is DateTime
          ? fields[16] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(fields[16] as int? ?? 0),
      updateTime: fields[17] is DateTime
          ? fields[17] as DateTime
          : DateTime.fromMillisecondsSinceEpoch(fields[17] as int? ?? 0),
    );
  }

  @override
  void write(BinaryWriter writer, AiEmployeeMessageEntity obj) {
    writer
      ..writeByte(18)
      ..writeByte(0)
      ..write(obj.uuid)
      ..writeByte(1)
      ..write(obj.employeeId)
      ..writeByte(2)
      ..write(obj.role)
      ..writeByte(3)
      ..write(obj.type)
      ..writeByte(4)
      ..write(obj.content)
      ..writeByte(5)
      ..write(obj.toolCallId)
      ..writeByte(6)
      ..write(obj.toolName)
      ..writeByte(7)
      ..write(obj.toolArguments)
      ..writeByte(8)
      ..write(obj.toolResult)
      ..writeByte(9)
      ..write(obj.toolCalls)
      ..writeByte(10)
      ..write(obj.processingStatus)
      ..writeByte(11)
      ..write(obj.processingError)
      ..writeByte(12)
      ..write(obj.inputTokens)
      ..writeByte(13)
      ..write(obj.outputTokens)
      ..writeByte(14)
      ..write(obj.isRead)
      ..writeByte(15)
      ..write(obj.deleted)
      ..writeByte(16)
      ..write(obj.createTime.millisecondsSinceEpoch)
      ..writeByte(17)
      ..write(obj.updateTime.millisecondsSinceEpoch);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiEmployeeMessageAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
