import '../agent_tool.dart';
import 'bg_command_tool.dart';
import 'confirm_tool.dart';
import 'end_tool.dart';
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
import 'file_write_tool.dart';
import 'git_operations_tool.dart';
import 'schedule_task_tool.dart';
import 'spawn_sub_agent_tool.dart';
import 'todo_manage_tool.dart';
import 'spec_manage_tool.dart';
import 'web_fetch_tool.dart';
import 'web_search_tool.dart';

/// 内置工具集合
///
/// 提供所有内置工具的工厂方法，以及规划/执行工具分类。
class BuiltinTools {
  BuiltinTools._();

  /// 主 Agent（规划器）可见的工具名称。
  ///
  /// 这些工具仅用于任务分析、规划和委派，不包含任何文件/命令执行工具。
  static const Set<String> plannerToolNames = {
    'todo_manage', // 待办管理
    'spec_manage', // 规格管理
    'spawn_sub_agent', // 委派子 Agent 执行
    'schedule_task', // 定时任务
    'confirm', // 确认请求
    'end', // 主动结束对话循环
  };

  /// 子 Agent（执行器）可用的工具名称。
  ///
  /// 包含所有文件操作、命令执行、搜索等实际执行工具。
  static const Set<String> executorToolNames = {
    'end',
    'confirm',
    'file_read',
    'file_write',
    'file_list',
    'content_search',
    'file_info',
    'file_delete',
    'file_patch',
    'directory_create',
    'command_execute',
    'bg_command',
    'git_operations',
    'code_symbols',
    'env_info',
    'web_fetch',
    'web_search_prime',
  };

  /// 获取所有内置工具
  static List<AgentTool> all() {
    return [
      EndTool(),
      ConfirmTool(),
      FileReadTool(),
      FileWriteTool(),
      FileListTool(),
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
      SpecManageTool(),
    ];
  }

  /// 仅获取只读工具（不需要权限的工具）
  static List<AgentTool> readOnly() {
    return [
      EndTool(),
      FileReadTool(),
      FileListTool(),
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
      ContentSearchTool(),
      FileInfoTool(),
      FileDeleteTool(),
      DirectoryCreateTool(),
      FilePatchTool(),
    ];
  }
}
