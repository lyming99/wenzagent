import '../../../persistence/entities/spec_item_entity.dart';
import '../agent_tool.dart';

/// 规格管理工具
///
/// 支持跨轮次的规格说明管理，数据持久化到 SQLite。
/// 类似笔记的规格书，支持增删改查，不使用分组。
/// 所有操作通过异步回调由 AgentImpl 注入。
class SpecManageTool extends AgentTool {
  // ===== 异步回调（由 AgentImpl 注入） =====

  /// 获取活跃 spec 项（draft + pending + in_progress）
  Future<List<SpecItemEntity>> Function(String employeeId)? getActiveSpecs;

  /// 获取已完成的 spec 项
  Future<List<SpecItemEntity>> Function(String employeeId, {int limit})?
      getCompletedSpecs;

  /// 保存 spec 项
  Future<void> Function(SpecItemEntity item)? saveSpec;

  /// 更新 spec 状态
  Future<void> Function(String id, String status)? updateSpecStatus;

  /// 更新 spec 内容
  Future<void> Function(String id, {String? title, String? content})?
      updateSpecContent;

  /// 软删除 spec 项
  Future<void> Function(String id)? removeSpec;

  /// 批量删除已完成的项
  Future<void> Function(String employeeId)? clearCompletedSpecs;

  /// 广播事件
  void Function(String type, Map<String, dynamic> data)? broadcastEvent;

  /// 当前员工 ID（由 AgentImpl 注入）
  String? employeeId;

  @override
  String get name => 'spec_manage';

  @override
  String get description =>
      '管理持久化的规格说明文档，类似笔记的规格书。'
      '数据跨 Agent 重启持久保存。\n\n'
      '操作：\n'
      '- "add"：创建新规格项（需要 title；可选：content、priority、tags）\n'
      '- "list"：按范围查看项目（active/completed/all）\n'
      '- "update"：修改项目状态、标题或内容\n'
      '- "remove"：删除指定项目\n'
      '- "clear"：清除所有已完成项\n\n'
      '规格说明持久化在数据库中。';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': ['add', 'list', 'update', 'remove', 'clear'],
            'description': '要对规格列表执行的操作。',
          },
          'title': {
            'type': 'string',
            'description':
                '规格项标题。"add" 时必需，"update" 时可选用于修改标题。',
          },
          'content': {
            'type': 'string',
            'description':
                '规格项内容/描述。"add" 和 "update" 时可选。',
          },
          'id': {
            'type': 'string',
            'description':
                '规格项 ID。"update" 和 "remove" 时必需。',
          },
          'status': {
            'type': 'string',
            'enum': ['draft', 'pending', 'in_progress', 'completed'],
            'description': '项目的新状态。用于 "update" 操作。',
          },
          'priority': {
            'type': 'string',
            'enum': ['low', 'medium', 'high'],
            'description': '"add" 操作的优先级。默认："medium"。',
          },
          'tags': {
            'type': 'string',
            'description': '"add" 操作的标签，逗号分隔。',
          },
          'scope': {
            'type': 'string',
            'enum': ['active', 'completed', 'all'],
            'description': '列表显示范围。默认："active"。',
          },
        },
        'required': ['action'],
      };

  @override
  bool get requiresPermission => false;

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final action = arguments['action'] as String?;
    if (action == null || action.isEmpty) {
      return ToolResult.error('action is required');
    }

    if (employeeId == null) {
      return ToolResult.error('Spec tool not initialized');
    }

    switch (action) {
      case 'add':
        return _add(arguments);
      case 'list':
        return _list(arguments);
      case 'update':
        return _update(arguments);
      case 'remove':
        return _remove(arguments);
      case 'clear':
        return _clear();
      default:
        return ToolResult.error(
          'Unknown action: $action. Use add, list, update, remove, or clear.',
        );
    }
  }

  Future<ToolResult> _add(Map<String, dynamic> arguments) async {
    final title = arguments['title'] as String?;
    if (title == null || title.isEmpty) {
      return ToolResult.error('title is required for add action');
    }

    final content = arguments['content'] as String? ?? '';
    final priority = arguments['priority'] as String? ?? 'medium';
    final tags = arguments['tags'] as String? ?? '';
    final now = DateTime.now();
    final id = 'spec_${now.millisecondsSinceEpoch}';

    final item = SpecItemEntity(
      id: id,
      employeeId: employeeId!,
      title: title,
      content: content,
      status: 'pending',
      priority: priority,
      tags: tags,
      createTime: now,
      updateTime: now,
    );

    await saveSpec?.call(item);

    broadcastEvent?.call('specChanged', {
      'action': 'added',
      'specId': id,
      'title': title,
    });

    return ToolResult.success('Spec added: [$id] $title');
  }

  Future<ToolResult> _list(Map<String, dynamic> arguments) async {
    if (getActiveSpecs == null) {
      return ToolResult.error('Spec list is not available');
    }

    final scope = arguments['scope'] as String? ?? 'active';
    final eid = employeeId!;

    List<SpecItemEntity> activeItems = [];
    List<SpecItemEntity> completedItems = [];

    if (scope == 'active' || scope == 'all') {
      activeItems = await getActiveSpecs!(eid);
    }
    if (scope == 'completed' || scope == 'all') {
      completedItems = await getCompletedSpecs!(eid);
    }

    final allItems = [...activeItems, ...completedItems];
    if (allItems.isEmpty) {
      return ToolResult.success('Spec list is empty.');
    }

    final buffer = StringBuffer();
    buffer.writeln('## Spec List (${allItems.length} items)');

    // 按状态分组输出
    final inProgress =
        activeItems.where((s) => s.status == 'in_progress').toList();
    final pending = activeItems.where((s) => s.status == 'pending').toList();
    final draft = activeItems.where((s) => s.status == 'draft').toList();

    if (inProgress.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('### In Progress');
      for (final s in inProgress) {
        final priorityTag =
            s.priority != 'medium' ? ' [${s.priority}]' : '';
        buffer.writeln('  - [${s.id}] ${s.title}$priorityTag');
      }
    }

    if (pending.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('### Pending');
      for (final s in pending) {
        final priorityTag =
            s.priority != 'medium' ? ' [${s.priority}]' : '';
        buffer.writeln('  - [${s.id}] ${s.title}$priorityTag');
      }
    }

    if (draft.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('### Draft');
      for (final s in draft) {
        final priorityTag =
            s.priority != 'medium' ? ' [${s.priority}]' : '';
        buffer.writeln('  - [${s.id}] ${s.title}$priorityTag');
      }
    }

    if (completedItems.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('### Completed (${completedItems.length})');
      for (final s in completedItems) {
        buffer.writeln('  - [${s.id}] ${s.title}');
      }
    }

    return ToolResult.success(buffer.toString().trim());
  }

  Future<ToolResult> _update(Map<String, dynamic> arguments) async {
    final id = arguments['id'] as String?;
    if (id == null || id.isEmpty) {
      return ToolResult.error('id is required for update action');
    }

    final statusStr = arguments['status'] as String?;
    final title = arguments['title'] as String?;
    final content = arguments['content'] as String?;

    if (statusStr == null &&
        (title == null || title.isEmpty) &&
        (content == null || content.isEmpty)) {
      return ToolResult.error(
          'At least one of status, title, or content is required for update action');
    }

    if (statusStr != null) {
      if (!['draft', 'pending', 'in_progress', 'completed']
          .contains(statusStr)) {
        return ToolResult.error(
          'Invalid status: $statusStr. Use draft, pending, in_progress, or completed.',
        );
      }
      await updateSpecStatus?.call(id, statusStr);
    }

    if ((title != null && title.isNotEmpty) ||
        (content != null && content.isNotEmpty)) {
      await updateSpecContent?.call(id, title: title, content: content);
    }

    broadcastEvent?.call('specChanged', {
      'action': 'updated',
      'specId': id,
      if (statusStr != null) 'status': statusStr,
    });

    return ToolResult.success(
      'Spec updated: [$id]${statusStr != null ? ' status=$statusStr' : ''}'
      '${title != null ? ' title=$title' : ''}${content != null ? ' content updated' : ''}',
    );
  }

  Future<ToolResult> _remove(Map<String, dynamic> arguments) async {
    final id = arguments['id'] as String?;
    if (id == null || id.isEmpty) {
      return ToolResult.error('id is required for remove action');
    }

    await removeSpec?.call(id);

    broadcastEvent?.call('specChanged', {
      'action': 'removed',
      'specId': id,
    });

    return ToolResult.success('Spec removed: [$id]');
  }

  Future<ToolResult> _clear() async {
    if (clearCompletedSpecs == null) {
      return ToolResult.error('Spec operations not available');
    }
    await clearCompletedSpecs!(employeeId!);

    broadcastEvent?.call('specChanged', {
      'action': 'cleared',
    });

    return ToolResult.success('All completed spec items cleared.');
  }
}
