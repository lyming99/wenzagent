import '../agent_tool.dart';
import 'bg_command_tool.dart';
import 'code_symbols_tool.dart';
import 'command_execute_tool.dart';
import 'content_search_tool.dart';
import 'directory_create_tool.dart';
import 'env_info_tool.dart';
import 'file_delete_tool.dart';
import 'file_info_tool.dart';
import 'file_list_tool.dart';
import 'file_patch_tool.dart';
import 'file_read_tool.dart';
import 'file_search_tool.dart';
import 'file_write_tool.dart';
import 'git_operations_tool.dart';
import 'schedule_task_tool.dart';
import 'spawn_sub_agent_tool.dart';
import 'todo_manage_tool.dart';
import 'web_fetch_tool.dart';
import 'web_search_tool.dart';

/// 内置工具集合
///
/// 提供所有内置工具的工厂方法。
class BuiltinTools {
  BuiltinTools._();

  /// 获取所有内置工具
  static List<AgentTool> all() {
    return [
      FileReadTool(),
      FileWriteTool(),
      FileListTool(),
      FileSearchTool(),
      ContentSearchTool(),
      CommandExecuteTool(),
      BgCommandTool(),
      GitOperationsTool(),
      FileInfoTool(),
      FileDeleteTool(),
      DirectoryCreateTool(),
      ScheduleTaskTool(),
      SpawnSubAgentTool(),
      WebFetchTool(),
      WebSearchTool(),
      EnvInfoTool(),
      FilePatchTool(),
      CodeSymbolsTool(),
      TodoManageTool(),
    ];
  }

  /// 仅获取只读工具（不需要权限的工具）
  static List<AgentTool> readOnly() {
    return [
      FileReadTool(),
      FileListTool(),
      FileSearchTool(),
      ContentSearchTool(),
      FileInfoTool(),
      EnvInfoTool(),
      WebSearchTool(),
    ];
  }

  /// 仅获取文件相关工具
  static List<AgentTool> fileTools() {
    return [
      FileReadTool(),
      FileWriteTool(),
      FileListTool(),
      FileSearchTool(),
      ContentSearchTool(),
      FileInfoTool(),
      FileDeleteTool(),
      DirectoryCreateTool(),
      FilePatchTool(),
    ];
  }
}
