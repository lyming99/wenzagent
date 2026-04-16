import '../../../persistence/entities/todo_topic_entity.dart';
import '../../../persistence/entities/todo_task_item_entity.dart';
import '../agent_tool.dart';

/// 待办管理工具
///
/// 支持跨轮次的待办列表管理，数据持久化到 SQLite。
/// 待办任务由主题（Topic）和任务子项（TaskItem）组成。
/// 所有操作通过异步回调由 AgentImpl 注入。
class TodoManageTool extends AgentTool {
  // ===== 异步回调（由 AgentImpl 注入） =====

  // 主题操作
  Future<List<TodoTopicEntity>> Function(String employeeId)? getCurrentTopics;
  Future<List<TodoTopicEntity>> Function(String employeeId)? getPendingTopics;
  Future<List<TodoTopicEntity>> Function(String employeeId)? getAllTopics;
  Future<List<TodoTopicEntity>> Function(String employeeId, {int limit})?
      getCompletedTopics;
  Future<void> Function(TodoTopicEntity topic)? saveTopic;
  Future<void> Function(String id, {String? title, String? description})?
      updateTopicContent;
  Future<void> Function(String id)? removeTopic;
  Future<void> Function(String employeeId)? clearCompletedTopics;

  // 任务子项操作
  Future<List<TodoTaskItemEntity>> Function(String topicId)?
      getTaskItemsByTopic;
  Future<void> Function(TodoTaskItemEntity item)? saveTaskItem;
  Future<void> Function(String id, {String? title, String? content})?
      updateTaskItemContent;
  Future<void> Function(String id, String status)? updateTaskItemStatus;
  Future<void> Function(String id)? removeTaskItem;
  Future<void> Function(String topicId)? recalculateTopicStatus;

  /// 广播事件
  void Function(String type, Map<String, dynamic> data)? broadcastEvent;

  /// 当前员工 ID（由 AgentImpl 注入）
  String? employeeId;

  @override
  String get name => 'todo_manage';

  @override
  String get description =>
      '管理持久化的待办任务列表。'
      '数据跨 Agent 重启持久保存。\n\n'
      '待办任务由主题和任务子项组成：\n'
      '- 主题（Topic）：一个待办任务的主题/标题\n'
      '- 任务子项（TaskItem）：主题下的具体执行项，包含标题和内容（markdown）\n\n'
      '操作：\n'
      '- "add"：创建新待办主题（需要 title）\n'
      '- "add_task"：向主题添加任务子项（需要 topic_id 和 title）\n'
      '- "list"：按范围查看主题（current/pending/all）\n'
      '- "update"：修改主题标题或描述\n'
      '- "update_task"：修改任务子项（状态、标题、内容）\n'
      '- "remove"：删除主题（及其所有子项）\n'
      '- "remove_task"：删除任务子项\n'
      '- "clear"：清除所有已完成主题\n\n'
      'scope 说明：\n'
      '- "current"：当前正在进行的待办（有子项处于进行中状态）\n'
      '- "pending"：所有未完成的待办\n'
      '- "all"：全部待办（含已完成）\n\n'
      '待办列表持久化在数据库中。';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': [
              'add',
              'add_task',
              'list',
              'update',
              'update_task',
              'remove',
              'remove_task',
              'clear',
            ],
            'description': '要对待办列表执行的操作。',
          },
          // 主题操作参数
          'title': {
            'type': 'string',
            'description': '主题标题。"add" 时必需。',
          },
          'content': {
            'type': 'string',
            'description': '主题描述。"add" 时可选。',
          },
          'id': {
            'type': 'string',
            'description': '主题 ID。"update"、"remove" 时必需。',
          },
          'scope': {
            'type': 'string',
            'enum': ['current', 'pending', 'all'],
            'description': '列表显示范围。默认："current"。',
          },
          // 任务子项操作参数
          'topic_id': {
            'type': 'string',
            'description': '主题 ID。"add_task" 时必需。',
          },
          'task_id': {
            'type': 'string',
            'description': '任务子项 ID。"update_task"、"remove_task" 时必需。',
          },
          'task_title': {
            'type': 'string',
            'description': '任务子项标题。"add_task" 时必需。',
          },
          'task_content': {
            'type': 'string',
            'description': '任务子项内容（markdown）。"add_task"、"update_task" 时可选。',
          },
          'status': {
            'type': 'string',
            'enum': ['pending', 'in_progress', 'completed'],
            'description': '状态。"update_task" 时可选。',
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
      case 'add_task':
        return _addTask(arguments);
      case 'list':
        return _list(arguments);
      case 'update':
        return _update(arguments);
      case 'update_task':
        return _updateTask(arguments);
      case 'remove':
        return _remove(arguments);
      case 'remove_task':
        return _removeTask(arguments);
      case 'clear':
        return _clear();
      default:
        return ToolResult.error(
          'Unknown action: $action. Use add, add_task, list, update, update_task, '
          'remove, remove_task, or clear.',
        );
    }
  }

  // ===== 主题操作 =====

  Future<ToolResult> _add(Map<String, dynamic> arguments) async {
    final title = arguments['title'] as String?;
    if (title == null || title.isEmpty) {
      return ToolResult.error('title is required for add action');
    }

    final description = arguments['content'] as String? ?? '';
    final now = DateTime.now();
    final id = 'topic_${now.millisecondsSinceEpoch}';

    final topic = TodoTopicEntity(
      id: id,
      employeeId: employeeId!,
      title: title,
      description: description,
      status: 'pending',
      createTime: now,
      updateTime: now,
    );

    await saveTopic?.call(topic);

    broadcastEvent?.call('todoTopicChanged', {
      'action': 'added',
      'topicId': id,
      'title': title,
    });

    return ToolResult.success('Todo topic added: [$id] $title');
  }

  Future<ToolResult> _addTask(Map<String, dynamic> arguments) async {
    final topicId = arguments['topic_id'] as String?;
    if (topicId == null || topicId.isEmpty) {
      return ToolResult.error('topic_id is required for add_task action');
    }

    final taskTitle = arguments['task_title'] as String?;
    if (taskTitle == null || taskTitle.isEmpty) {
      return ToolResult.error('task_title is required for add_task action');
    }

    final taskContent = arguments['task_content'] as String? ?? '';
    final now = DateTime.now();
    final id = 'task_${now.millisecondsSinceEpoch}';

    final taskItem = TodoTaskItemEntity(
      id: id,
      employeeId: employeeId!,
      topicId: topicId,
      title: taskTitle,
      content: taskContent,
      status: 'pending',
      createTime: now,
      updateTime: now,
    );

    await saveTaskItem?.call(taskItem);
    await recalculateTopicStatus?.call(topicId);

    broadcastEvent?.call('todoTaskItemChanged', {
      'action': 'added',
      'taskId': id,
      'topicId': topicId,
      'title': taskTitle,
    });

    return ToolResult.success('Task added: [$id] $taskTitle (topic: $topicId)');
  }

  Future<ToolResult> _list(Map<String, dynamic> arguments) async {
    if (getCurrentTopics == null) {
      return ToolResult.error('Todo list is not available');
    }

    final scope = arguments['scope'] as String? ?? 'current';
    final eid = employeeId!;

    List<TodoTopicEntity> pendingTopics = [];
    List<TodoTopicEntity> completedTopics = [];

    if (scope == 'current') {
      pendingTopics = await getCurrentTopics!(eid);
    } else if (scope == 'pending') {
      pendingTopics = await getPendingTopics!(eid);
    } else if (scope == 'all') {
      pendingTopics = await getPendingTopics!(eid);
      completedTopics = await getCompletedTopics!(eid);
    }

    final allTopics = [...pendingTopics, ...completedTopics];
    if (allTopics.isEmpty) {
      return ToolResult.success('Todo list is empty.');
    }

    final buffer = StringBuffer();

    if (scope == 'current') {
      buffer.writeln('## Current Todos (${pendingTopics.length} topics)');
    } else if (scope == 'pending') {
      buffer.writeln('## Pending Todos (${pendingTopics.length} topics)');
    } else {
      buffer.writeln('## All Todos (${allTopics.length} topics)');
    }

    for (final topic in pendingTopics) {
      buffer.writeln();
      final statusIcon = topic.status == 'in_progress' ? '>>>' : '   ';
      buffer.writeln('$statusIcon **[${topic.id}] ${topic.title}**');
      if (topic.description.isNotEmpty) {
        buffer.writeln('   ${topic.description}');
      }

      // 获取子项
      final tasks = await getTaskItemsByTopic?.call(topic.id) ?? [];
      for (final task in tasks) {
        final icon = task.status == 'completed'
            ? '[x]'
            : task.status == 'in_progress'
                ? '[~]'
                : '[ ]';
        buffer.writeln('   $icon [${task.id}] ${task.title}');
        if (task.content.isNotEmpty) {
          buffer.writeln('      ${task.content}');
        }
      }
    }

    if (completedTopics.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('### Completed (${completedTopics.length})');
      for (final topic in completedTopics) {
        buffer.writeln('  - [${topic.id}] ${topic.title}');
      }
    }

    return ToolResult.success(buffer.toString().trim());
  }

  Future<ToolResult> _update(Map<String, dynamic> arguments) async {
    final id = arguments['id'] as String?;
    if (id == null || id.isEmpty) {
      return ToolResult.error('id is required for update action');
    }

    final title = arguments['title'] as String?;
    final content = arguments['content'] as String?;

    if ((title == null || title.isEmpty) && (content == null || content.isEmpty)) {
      return ToolResult.error(
          'At least one of title or content is required for update action');
    }

    await updateTopicContent?.call(id, title: title, description: content);

    broadcastEvent?.call('todoTopicChanged', {
      'action': 'updated',
      'topicId': id,
    });

    return ToolResult.success(
      'Todo topic updated: [$id]${title != null ? ' title=$title' : ''}'
      '${content != null ? ' description updated' : ''}',
    );
  }

  Future<ToolResult> _updateTask(Map<String, dynamic> arguments) async {
    final taskId = arguments['task_id'] as String?;
    if (taskId == null || taskId.isEmpty) {
      return ToolResult.error('task_id is required for update_task action');
    }

    final statusStr = arguments['status'] as String?;
    final title = arguments['task_title'] as String?;
    final content = arguments['task_content'] as String?;

    if (statusStr == null &&
        (title == null || title.isEmpty) &&
        (content == null || content.isEmpty)) {
      return ToolResult.error(
          'At least one of status, task_title, or task_content is required for update_task action');
    }

    // 获取 topicId 用于重新计算主题状态
    // 先更新内容
    if ((title != null && title.isNotEmpty) ||
        (content != null && content.isNotEmpty)) {
      await updateTaskItemContent?.call(taskId, title: title, content: content);
    }

    // 更新状态
    if (statusStr != null) {
      if (!['pending', 'in_progress', 'completed'].contains(statusStr)) {
        return ToolResult.error(
          'Invalid status: $statusStr. Use pending, in_progress, or completed.',
        );
      }
      await updateTaskItemStatus?.call(taskId, statusStr);
    }

    broadcastEvent?.call('todoTaskItemChanged', {
      'action': 'updated',
      'taskId': taskId,
      if (statusStr != null) 'status': statusStr,
    });

    return ToolResult.success(
      'Task updated: [$taskId]${statusStr != null ? ' status=$statusStr' : ''}'
      '${title != null ? ' title=$title' : ''}${content != null ? ' content updated' : ''}',
    );
  }

  Future<ToolResult> _remove(Map<String, dynamic> arguments) async {
    final id = arguments['id'] as String?;
    if (id == null || id.isEmpty) {
      return ToolResult.error('id is required for remove action');
    }

    await removeTopic?.call(id);

    broadcastEvent?.call('todoTopicChanged', {
      'action': 'removed',
      'topicId': id,
    });

    return ToolResult.success('Todo topic removed: [$id]');
  }

  Future<ToolResult> _removeTask(Map<String, dynamic> arguments) async {
    final taskId = arguments['task_id'] as String?;
    if (taskId == null || taskId.isEmpty) {
      return ToolResult.error('task_id is required for remove_task action');
    }

    await removeTaskItem?.call(taskId);

    broadcastEvent?.call('todoTaskItemChanged', {
      'action': 'removed',
      'taskId': taskId,
    });

    return ToolResult.success('Task removed: [$taskId]');
  }

  Future<ToolResult> _clear() async {
    if (clearCompletedTopics == null) {
      return ToolResult.error('Todo operations not available');
    }
    await clearCompletedTopics!(employeeId!);

    broadcastEvent?.call('todoTopicChanged', {
      'action': 'cleared',
    });

    return ToolResult.success('All completed topics cleared.');
  }
}
