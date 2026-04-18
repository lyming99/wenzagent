import 'dart:io';

void main() {
  final file = File('lib/src/device/impl/device_message_handler.dart');
  final content = file.readAsStringSync();
  final lines = content.split('\n');
  
  // Find line with 'agentSessionCleared:'
  int targetIdx = -1;
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].trim() == 'case LanMessageType.agentSessionCleared:') {
      targetIdx = i;
      break;
    }
  }
  
  if (targetIdx == -1) {
    print('ERROR: target line not found');
    return;
  }
  
  final newLines = [
    '      case LanMessageType.agentSessionCleared:',
    '      case LanMessageType.agentConfirmChanged:',
    '      case LanMessageType.agentTodoChanged:',
    '      case LanMessageType.agentSpecChanged:',
    '      case LanMessageType.agentConfigChanged:',
    '        _handleAgentEvent(msg);',
  ];
  
  // Replace lines targetIdx to targetIdx+1 (agentSessionCleared + _handleAgentEvent)
  final before = lines.sublist(0, targetIdx);
  final after = lines.sublist(targetIdx + 2); // skip old 2 lines
  final result = [...before, ...newLines, ...after];
  
  file.writeAsStringSync(result.join('\n'));
  print('Done. Replaced 2 lines at ${targetIdx + 1} with ${newLines.length} lines');
}
