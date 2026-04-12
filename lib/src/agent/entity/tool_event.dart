import 'agent_event.dart';

/// 工具事件实体
///
/// 统一封装 Agent 执行工具调用时产生的事件，
/// 用于工具事件回调的类型安全传递。
sealed class ToolEvent {
  final String toolCallId;
  final String toolName;

  const ToolEvent({required this.toolCallId, required this.toolName});
}

/// 工具调用开始事件
class ToolCallStartEvent extends ToolEvent {
  final Map<String, dynamic> arguments;

  const ToolCallStartEvent({
    required super.toolCallId,
    required super.toolName,
    required this.arguments,
  });
}

/// 工具调用结果事件
class ToolCallResultEvent extends ToolEvent {
  final String result;
  final bool isError;
  final int? durationMs;
  final String? denyReason;

  const ToolCallResultEvent({
    required super.toolCallId,
    required super.toolName,
    required this.result,
    required this.isError,
    this.durationMs,
    this.denyReason,
  });
}

/// 工具事件到 Map 的转换工具方法
class ToolEventMapper {
  /// 从 Map 创建 ToolEvent
  static ToolEvent fromMap(Map<String, dynamic> map) {
    final type = AgentEventType.fromString(map['type'] as String);
    final data = map['data'] as Map<String, dynamic>;
    final toolCallId = data['toolCallId'] as String;
    final toolName = data['toolName'] as String;

    if (type == AgentEventType.toolCallStart) {
      return ToolCallStartEvent(
        toolCallId: toolCallId,
        toolName: toolName,
        arguments: data['arguments'] as Map<String, dynamic>? ?? {},
      );
    }

    return ToolCallResultEvent(
      toolCallId: toolCallId,
      toolName: toolName,
      result: data['result'] as String? ?? '',
      isError: data['isError'] as bool? ?? false,
      durationMs: data['durationMs'] as int?,
      denyReason: data['denyReason'] as String?,
    );
  }

  /// ToolEvent 转为 Map（兼容旧的回调格式）
  static Map<String, dynamic> toMap(ToolEvent event) {
    return switch (event) {
      ToolCallStartEvent(:final arguments) => {
          'type': AgentEventType.toolCallStart.value,
          'data': {
            'toolCallId': event.toolCallId,
            'toolName': event.toolName,
            'arguments': arguments,
          },
        },
      ToolCallResultEvent(
        :final result,
        :final isError,
        :final durationMs,
        :final denyReason,
      ) =>
        {
          'type': AgentEventType.toolCallResult.value,
          'data': {
            'toolCallId': event.toolCallId,
            'toolName': event.toolName,
            'result': result,
            'isError': isError,
            'durationMs': ?durationMs,
            'denyReason': ?denyReason,
          },
        },
    };
  }
}
