import '../../../persistence/entities/todo_group_entity.dart';
import '../../../persistence/entities/todo_item_entity.dart';
import '../agent_tool.dart';

/// 待办管理工具
///
/// 支持跨轮次的待办列表管理，数据持久化到 SQLite，
/// 支持分组管理。所有操作通过异步回调由 AgentImpl 注入。
class TodoManageTool extends AgentTool {
  // ===== 异步回调（由 AgentImpl 注入） =====

  /// 获取活跃 todo 项（pending + in_progress）
  Future<List<TodoItemEntity>> Function(String employeeId)? getActiveTodos;

  /// 获取已完成的 todo 项
  Future<List<TodoItemEntity>> Function(String employeeId, {int limit})?
      getCompletedTodos;

  /// 保存 todo 项
  Future<void> Function(TodoItemEntity item)? saveTodo;

  /// 更新 todo 状态
  Future<void> Function(String id, String status)? updateTodoStatus;

  /// 更新 todo 内容
  Future<void> Function(String id, String? content)? updateTodoContent;

  /// 软删除 todo 项
  Future<void> Function(String id)? removeTodo;

  /// 批量删除已完成的项
  Future<void> Function(String employeeId)? clearCompletedTodos;

  /// 移动 todo 到分组
  Future<void> Function(String id, String? groupId)? moveTodoToGroup;

  /// 获取员工所有分组
  Future<List<TodoGroupEntity>> Function(String employeeId)? getGroups;

  /// 按名称查找分组
  Future<TodoGroupEntity?> Function(String employeeId, String name)?
      findGroupByName;

  /// 保存分组
  Future<void> Function(TodoGroupEntity group)? saveGroup;

  /// 软删除分组
  Future<void> Function(String id)? removeGroup;

  /// 重命名分组
  Future<void> Function(String id, String newName)? renameGroupFn;

  /// 广播事件
  void Function(String type, Map<String, dynamic> data)? broadcastEvent;

  /// 当前员工 ID（由 AgentImpl 注入）
  String? employeeId;

  @override
  String get name => 'todo_manage';

  @override
  String get description =>
      'Manage a persistent todo list with group support. '
      'Data persists across agent restarts.\n\n'
      'Actions:\n'
      '- "add": Create a new todo item (optional: group name)\n'
      '- "list": View items by scope (active/completed/all)\n'
      '- "update": Change status or content of an item\n'
      '- "remove": Delete a specific item\n'
      '- "clear": Remove all completed items\n'
      '- "create_group": Create a new group\n'
      '- "list_groups": View all groups\n'
      '- "rename_group": Rename a group\n'
      '- "delete_group": Delete a group (items move to ungrouped)\n'
      '- "move_to_group": Move a todo item to a group\n\n'
      'The todo list is persisted in the database.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': [
              'add',
              'list',
              'update',
              'remove',
              'clear',
              'create_group',
              'list_groups',
              'rename_group',
              'delete_group',
              'move_to_group',
            ],
            'description': 'Action to perform on the todo list.',
          },
          'content': {
            'type': 'string',
            'description':
                'Todo item content. Required for "add". Optional for "update" to change content.',
          },
          'id': {
            'type': 'string',
            'description':
                'Todo item ID. Required for "update", "remove", and "move_to_group".',
          },
          'status': {
            'type': 'string',
            'enum': ['pending', 'in_progress', 'completed'],
            'description':
                'New status for the item. Used with "update" action.',
          },
          'scope': {
            'type': 'string',
            'enum': ['active', 'completed', 'all'],
            'description':
                'Scope for "list" action. Default is "active".',
          },
          'group': {
            'type': 'string',
            'description':
                'Group name for "add" action. Creates the group if it does not exist.',
          },
          'group_id': {
            'type': 'string',
            'description':
                'Group ID for "rename_group", "delete_group", and "move_to_group" actions.',
          },
          'new_name': {
            'type': 'string',
            'description': 'New name for "rename_group" action.',
          },
          'name': {
            'type': 'string',
            'description': 'Group name for "create_group" action.',
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
      return ToolResult.error('Todo tool not initialized');
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
      case 'create_group':
        return _createGroup(arguments);
      case 'list_groups':
        return _listGroups();
      case 'rename_group':
        return _renameGroup(arguments);
      case 'delete_group':
        return _deleteGroup(arguments);
      case 'move_to_group':
        return _moveToGroup(arguments);
      default:
        return ToolResult.error(
          'Unknown action: $action. Use add, list, update, remove, clear, '
          'create_group, list_groups, rename_group, delete_group, or move_to_group.',
        );
    }
  }

  Future<ToolResult> _add(Map<String, dynamic> arguments) async {
    final content = arguments['content'] as String?;
    if (content == null || content.isEmpty) {
      return ToolResult.error('content is required for add action');
    }

    final now = DateTime.now();
    final id = 'todo_${now.millisecondsSinceEpoch}';

    // 处理分组
    String? groupId;
    final groupName = arguments['group'] as String?;
    if (groupName != null && groupName.isNotEmpty) {
      if (findGroupByName == null || saveGroup == null) {
        return ToolResult.error('Group operations not available');
      }
      var group = await findGroupByName!(employeeId!, groupName);
      if (group == null) {
        // 自动创建分组
        final groupIdStr = 'tg_${now.millisecondsSinceEpoch}';
        group = TodoGroupEntity(
          id: groupIdStr,
          employeeId: employeeId!,
          name: groupName,
          createTime: now,
          updateTime: now,
        );
        await saveGroup!(group);
        broadcastEvent?.call('todoGroupChanged', {
          'action': 'created',
          'groupId': groupIdStr,
          'name': groupName,
        });
      }
      groupId = group.id;
    }

    final item = TodoItemEntity(
      id: id,
      employeeId: employeeId!,
      groupId: groupId,
      content: content,
      status: 'pending',
      createTime: now,
      updateTime: now,
    );

    await saveTodo?.call(item);

    broadcastEvent?.call('todoChanged', {
      'action': 'added',
      'todoId': id,
      'content': content,
      'groupId': groupId,
    });

    final groupInfo = groupName != null ? ' (group: $groupName)' : '';
    return ToolResult.success('Todo added: [$id] $content$groupInfo');
  }

  Future<ToolResult> _list(Map<String, dynamic> arguments) async {
    if (getActiveTodos == null) {
      return ToolResult.error('Todo list is not available');
    }

    final scope = arguments['scope'] as String? ?? 'active';
    final eid = employeeId!;

    List<TodoItemEntity> activeItems = [];
    List<TodoItemEntity> completedItems = [];

    if (scope == 'active' || scope == 'all') {
      activeItems = await getActiveTodos!(eid);
    }
    if (scope == 'completed' || scope == 'all') {
      completedItems = await getCompletedTodos!(eid);
    }

    final allItems = [...activeItems, ...completedItems];
    if (allItems.isEmpty) {
      return ToolResult.success('Todo list is empty.');
    }

    // 获取所有分组用于显示名称
    final groups = await getGroups?.call(eid) ?? [];
    final groupMap = <String, String>{};
    for (final g in groups) {
      groupMap[g.id] = g.name;
    }

    // 按分组组织活跃项
    final grouped = <String?, List<TodoItemEntity>>{};
    final ungrouped = <TodoItemEntity>[];
    for (final item in activeItems) {
      if (item.groupId != null) {
        grouped.putIfAbsent(item.groupId, () => []).add(item);
      } else {
        ungrouped.add(item);
      }
    }

    final buffer = StringBuffer();
    buffer.writeln('## Todo List (${allItems.length} items)');

    // 按分组输出
    for (final entry in grouped.entries) {
      final gName = groupMap[entry.key] ?? 'Unknown Group';
      buffer.writeln();
      buffer.writeln('### $gName');
      for (final t in entry.value) {
        final statusIcon = t.status == 'in_progress' ? '...' : ' ';
        buffer.writeln('  - [${t.id}]${statusIcon}${t.content}');
      }
    }

    // 未分组的活跃项
    final inProgress =
        ungrouped.where((t) => t.status == 'in_progress').toList();
    final pending = ungrouped.where((t) => t.status == 'pending').toList();

    if (inProgress.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('### In Progress');
      for (final t in inProgress) {
        buffer.writeln('  - [${t.id}] ${t.content}');
      }
    }

    if (pending.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('### Pending');
      for (final t in pending) {
        buffer.writeln('  - [${t.id}] ${t.content}');
      }
    }

    if (completedItems.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('### Completed (${completedItems.length})');
      for (final t in completedItems) {
        buffer.writeln('  - [${t.id}] ${t.content}');
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
    final content = arguments['content'] as String?;

    if (statusStr == null && (content == null || content.isEmpty)) {
      return ToolResult.error(
          'At least one of status or content is required for update action');
    }

    if (statusStr != null) {
      if (!['pending', 'in_progress', 'completed'].contains(statusStr)) {
        return ToolResult.error(
          'Invalid status: $statusStr. Use pending, in_progress, or completed.',
        );
      }
      await updateTodoStatus?.call(id, statusStr);
    }

    if (content != null && content.isNotEmpty) {
      await updateTodoContent?.call(id, content);
    }

    broadcastEvent?.call('todoChanged', {
      'action': 'updated',
      'todoId': id,
      if (statusStr != null) 'status': statusStr,
    });

    return ToolResult.success(
      'Todo updated: [$id]${
        statusStr != null ? ' status=$statusStr' : ''
      }${content != null ? ' content=$content' : ''}',
    );
  }

  Future<ToolResult> _remove(Map<String, dynamic> arguments) async {
    final id = arguments['id'] as String?;
    if (id == null || id.isEmpty) {
      return ToolResult.error('id is required for remove action');
    }

    await removeTodo?.call(id);

    broadcastEvent?.call('todoChanged', {
      'action': 'removed',
      'todoId': id,
    });

    return ToolResult.success('Todo removed: [$id]');
  }

  Future<ToolResult> _clear() async {
    if (clearCompletedTodos == null) {
      return ToolResult.error('Todo operations not available');
    }
    await clearCompletedTodos!(employeeId!);

    broadcastEvent?.call('todoChanged', {
      'action': 'cleared',
    });

    return ToolResult.success('All completed items cleared.');
  }

  Future<ToolResult> _createGroup(Map<String, dynamic> arguments) async {
    final name = arguments['name'] as String?;
    if (name == null || name.isEmpty) {
      return ToolResult.error('name is required for create_group action');
    }

    if (saveGroup == null || findGroupByName == null) {
      return ToolResult.error('Group operations not available');
    }

    // 检查是否已存在同名分组
    final existing = await findGroupByName!(employeeId!, name);
    if (existing != null) {
      return ToolResult.error('Group already exists: $name');
    }

    final now = DateTime.now();
    final id = 'tg_${now.millisecondsSinceEpoch}';
    final group = TodoGroupEntity(
      id: id,
      employeeId: employeeId!,
      name: name,
      createTime: now,
      updateTime: now,
    );
    await saveGroup!(group);

    broadcastEvent?.call('todoGroupChanged', {
      'action': 'created',
      'groupId': id,
      'name': name,
    });

    return ToolResult.success('Group created: [$id] $name');
  }

  Future<ToolResult> _listGroups() async {
    if (getGroups == null) {
      return ToolResult.error('Group operations not available');
    }

    final groups = await getGroups!(employeeId!);
    if (groups.isEmpty) {
      return ToolResult.success('No groups found.');
    }

    final buffer = StringBuffer('## Groups (${groups.length})\n');
    for (final g in groups) {
      buffer.writeln('  - [${g.id}] ${g.name}');
    }
    return ToolResult.success(buffer.toString().trim());
  }

  Future<ToolResult> _renameGroup(Map<String, dynamic> arguments) async {
    final groupId = arguments['group_id'] as String?;
    final newName = arguments['new_name'] as String?;

    if (groupId == null || groupId.isEmpty) {
      return ToolResult.error('group_id is required for rename_group action');
    }
    if (newName == null || newName.isEmpty) {
      return ToolResult.error('new_name is required for rename_group action');
    }

    await renameGroupFn?.call(groupId, newName);

    broadcastEvent?.call('todoGroupChanged', {
      'action': 'renamed',
      'groupId': groupId,
      'newName': newName,
    });

    return ToolResult.success('Group renamed: [$groupId] -> $newName');
  }

  Future<ToolResult> _deleteGroup(Map<String, dynamic> arguments) async {
    final groupId = arguments['group_id'] as String?;
    if (groupId == null || groupId.isEmpty) {
      return ToolResult.error('group_id is required for delete_group action');
    }

    await removeGroup?.call(groupId);

    broadcastEvent?.call('todoGroupChanged', {
      'action': 'deleted',
      'groupId': groupId,
    });

    return ToolResult.success(
      'Group deleted: [$groupId]. Items moved to ungrouped.',
    );
  }

  Future<ToolResult> _moveToGroup(Map<String, dynamic> arguments) async {
    final todoId = arguments['id'] as String?;
    final groupId = arguments['group_id'] as String?;

    if (todoId == null || todoId.isEmpty) {
      return ToolResult.error('id is required for move_to_group action');
    }

    if (moveTodoToGroup == null) {
      return ToolResult.error('Todo operations not available');
    }

    // groupId 为 null 表示移出分组
    await moveTodoToGroup!(todoId, groupId);

    broadcastEvent?.call('todoChanged', {
      'action': 'moved',
      'todoId': todoId,
      'groupId': groupId,
    });

    if (groupId != null) {
      return ToolResult.success('Todo [$todoId] moved to group [$groupId]');
    }
    return ToolResult.success('Todo [$todoId] moved to ungrouped');
  }
}
