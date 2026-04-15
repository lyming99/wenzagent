import '../agent_tool.dart';

/// 待办管理工具
///
/// 支持跨轮次的待办列表管理。待办数据存储在内存中，
/// 在 Agent 存活期间跨轮次保持。
class TodoManageTool extends AgentTool {
  /// 待办数据存储回调（由 AgentImpl 注入）
  ///
  /// 返回当前 Agent 实例的待办列表。
  List<TodoItem> Function()? getTodoList;

  @override
  String get name => 'todo_manage';

  @override
  String get description =>
      'Manage a todo list that persists across conversation turns. '
      'Use this to track progress on multi-step tasks.\n\n'
      'Actions:\n'
      '- "add": Create a new todo item\n'
      '- "list": View all items (grouped by status)\n'
      '- "update": Change status or content of an item\n'
      '- "remove": Delete a specific item\n'
      '- "clear": Remove all completed items\n\n'
      'The todo list is maintained in memory for the duration of the agent session.';

  @override
  Map<String, dynamic> get inputJsonSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': ['add', 'list', 'update', 'remove', 'clear'],
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
                'Todo item ID. Required for "update" and "remove".',
          },
          'status': {
            'type': 'string',
            'enum': ['pending', 'in_progress', 'completed'],
            'description':
                'New status for the item. Used with "update" action.',
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

    if (getTodoList == null) {
      return ToolResult.error('Todo list is not available');
    }

    final todos = getTodoList!();

    switch (action) {
      case 'add':
        return _add(todos, arguments);
      case 'list':
        return _list(todos);
      case 'update':
        return _update(todos, arguments);
      case 'remove':
        return _remove(todos, arguments);
      case 'clear':
        return _clear(todos);
      default:
        return ToolResult.error(
          'Unknown action: $action. Use add, list, update, remove, or clear.',
        );
    }
  }

  ToolResult _add(List<TodoItem> todos, Map<String, dynamic> arguments) {
    final content = arguments['content'] as String?;
    if (content == null || content.isEmpty) {
      return ToolResult.error('content is required for add action');
    }

    final id = 'todo_${DateTime.now().millisecondsSinceEpoch}';
    final item = TodoItem(
      id: id,
      content: content,
      status: TodoStatus.pending,
      createdAt: DateTime.now(),
    );

    todos.add(item);

    return ToolResult.success(
      'Todo added: [$id] $content',
    );
  }

  ToolResult _list(List<TodoItem> todos) {
    if (todos.isEmpty) {
      return ToolResult.success('Todo list is empty.');
    }

    final pending =
        todos.where((t) => t.status == TodoStatus.pending).toList();
    final inProgress =
        todos.where((t) => t.status == TodoStatus.inProgress).toList();
    final completed =
        todos.where((t) => t.status == TodoStatus.completed).toList();

    final buffer = StringBuffer('## Todo List (${todos.length} items)\n\n');

    if (inProgress.isNotEmpty) {
      buffer.writeln('### In Progress');
      for (final t in inProgress) {
        buffer.writeln('  - [${t.id}] ${t.content}');
      }
      buffer.writeln();
    }

    if (pending.isNotEmpty) {
      buffer.writeln('### Pending');
      for (final t in pending) {
        buffer.writeln('  - [${t.id}] ${t.content}');
      }
      buffer.writeln();
    }

    if (completed.isNotEmpty) {
      buffer.writeln('### Completed (${completed.length})');
      for (final t in completed) {
        buffer.writeln('  - [${t.id}] ${t.content}');
      }
    }

    return ToolResult.success(buffer.toString().trim());
  }

  ToolResult _update(List<TodoItem> todos, Map<String, dynamic> arguments) {
    final id = arguments['id'] as String?;
    if (id == null || id.isEmpty) {
      return ToolResult.error('id is required for update action');
    }

    final item = todos.where((t) => t.id == id).firstOrNull;
    if (item == null) {
      return ToolResult.error('Todo item not found: $id');
    }

    final statusStr = arguments['status'] as String?;
    final content = arguments['content'] as String?;

    if (statusStr != null) {
      switch (statusStr) {
        case 'pending':
          item.status = TodoStatus.pending;
        case 'in_progress':
          item.status = TodoStatus.inProgress;
        case 'completed':
          item.status = TodoStatus.completed;
        default:
          return ToolResult.error(
            'Invalid status: $statusStr. Use pending, in_progress, or completed.',
          );
      }
    }

    if (content != null && content.isNotEmpty) {
      item.content = content;
    }

    return ToolResult.success(
      'Todo updated: [${item.id}] ${item.content} (${item.status.name})',
    );
  }

  ToolResult _remove(List<TodoItem> todos, Map<String, dynamic> arguments) {
    final id = arguments['id'] as String?;
    if (id == null || id.isEmpty) {
      return ToolResult.error('id is required for remove action');
    }

    final index = todos.indexWhere((t) => t.id == id);
    if (index < 0) {
      return ToolResult.error('Todo item not found: $id');
    }

    final removed = todos.removeAt(index);
    return ToolResult.success(
      'Todo removed: [${removed.id}] ${removed.content}',
    );
  }

  ToolResult _clear(List<TodoItem> todos) {
    final count = todos.where((t) => t.status == TodoStatus.completed).length;
    todos.removeWhere((t) => t.status == TodoStatus.completed);
    return ToolResult.success(
      'Cleared $count completed item(s). ${todos.length} item(s) remaining.',
    );
  }
}

/// 待办项状态
enum TodoStatus {
  pending,
  inProgress,
  completed;

  static TodoStatus fromString(String value) {
    return TodoStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => TodoStatus.pending,
    );
  }
}

/// 待办项
class TodoItem {
  String id;
  String content;
  TodoStatus status;
  DateTime createdAt;

  TodoItem({
    required this.id,
    required this.content,
    required this.status,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'content': content,
      'status': status.name,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}
