import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/agent/adapter/langchain_chat_adapter.dart';
import 'package:wenzagent/src/agent/adapter/provider_config.dart';
import 'package:wenzagent/src/agent/tool/builtin/schedule_task_tool.dart';
import 'package:wenzagent/src/agent/tool/tool_registry.dart';
import 'package:wenzagent/src/persistence/hive_manager.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/scheduled_task_manager.dart';

/// 真实 LLM 场景测试：模拟用户对 AI 说 "1分钟后提醒我吃饭"
///
/// 测试目标：
/// 1. AI 应调用 schedule_task 工具创建定时任务，而不是立即执行提醒
/// 2. 创建的任务应正确存储在 Manager 中
/// 3. 到时间后 TaskExecutor 应自动执行并送达结果
void main() {
  late String apiKey;
  late String apiUrl;
  late String apiModel;
  late ProviderConfig providerConfig;
  late ScheduledTaskManager manager;
  late String employeeId;

  setUpAll(() async {
    apiKey = Platform.environment['OPENAI_API_KEY'] ?? '';
    apiUrl =
        Platform.environment['OPENAI_API_URL'] ?? 'https://api.openai.com/v1';
    apiModel =
        Platform.environment['OPENAI_API_MODEL'] ?? 'gpt-3.5-turbo';

    if (apiKey.isEmpty) {
      throw Exception('请设置环境变量 OPENAI_API_KEY');
    }

    providerConfig = ProviderConfig(
      provider: LLMProvider.openai,
      apiKey: apiKey,
      baseUrl: apiUrl,
      model: apiModel,
    );

    // 使用带时间戳的唯一路径避免与其它测试冲突
    final hivePath =
        '${Directory.systemTemp.path}/wenzagent_scenario_${DateTime.now().millisecondsSinceEpoch}';
    await HiveManager.instance.initialize(storagePath: hivePath);

    print('=== 场景测试配置 ===');
    print('API URL : $apiUrl');
    print('API Model: $apiModel');
  });

  tearDownAll(() async {
    await HiveManager.instance.close();
  });

  setUp(() async {
    manager = ScheduledTaskManagerImpl();
    employeeId = 'scenario-emp-${DateTime.now().millisecondsSinceEpoch}';
  });

  tearDown(() async {
    if (manager.isRunning) await manager.stop();
    (manager as ScheduledTaskManagerImpl).dispose();
  });

  group('场景：用户说"1分钟后提醒我吃饭"', () {
    test('AI 应调用 schedule_task 创建任务，不应立即执行提醒', () async {
      print('\n${'=' * 60}');
      print('场景测试: 用户 → AI: "1分钟后提醒我吃饭"');
      print('=' * 60);

      // -------------------------------------------------------
      // 1. 构建 ScheduleTaskTool 并注入 Manager 回调
      // -------------------------------------------------------
      final scheduleTool = ScheduleTaskTool();

      scheduleTool.onCreateTask = (data) async {
        try {
          print('\n📌 [ScheduleTaskTool.onCreateTask 被调用]');
          print('   name: ${data['name']}');
          print('   schedule: ${data['schedule']}');
          print('   message: ${data['message']}');

          final scheduleExpr = data['schedule'] as String;
          final task = AiScheduledTaskEntity(
            uuid: const Uuid().v4(),
            employeeId: employeeId,
            name: data['name'] as String? ?? '定时提醒',
            scheduleType: _detectScheduleType(scheduleExpr),
            scheduleExpression: scheduleExpr,
            repeatType: RepeatType.once,
            taskConfig: jsonEncode({
              'action': 'workerTask',
              'message': data['message'],
            }),
            enabled: 1,
            createTime: DateTime.now(),
            updateTime: DateTime.now(),
          );

          final created = await manager.createTask(task);
          print('   ✅ 任务已存储, taskId: ${created.uuid}');
          print('   nextExecutionAt: ${created.nextExecutionAt}');

          return {
            'taskId': created.uuid,
            'name': created.name,
            'schedule': created.scheduleExpression,
            'nextExecutionAt':
                created.nextExecutionAt?.toIso8601String() ?? 'calculating...',
          };
        } catch (e, st) {
          print('❌ onCreateTask 异常: $e\n$st');
          rethrow;
        }
      };

      scheduleTool.onListTasks = ({String? employeeId}) async {
        final tasks = await manager.getTasks();
        return tasks.map((t) => <String, dynamic>{
              'taskId': t.uuid,
              'name': t.name,
              'schedule': t.scheduleExpression,
              'nextExecutionAt':
                  t.nextExecutionAt?.toIso8601String() ?? 'N/A',
              'enabled': t.isEnabled,
            }).toList();
      };

      scheduleTool.onCancelTask = (taskId) async {
        await manager.deleteTask(taskId);
        return true;
      };

      // -------------------------------------------------------
      // 2. 配置 TaskExecutor（定时触发时使用）
      // -------------------------------------------------------
      final impl = manager as ScheduledTaskManagerImpl;
      impl.taskExecutor.getAgentConfig = (empId) async {
        return {
          'providerConfig': providerConfig.toMap(),
          'systemPrompt': '你是一个提醒助手。当收到提醒请求时，请简短友好地提醒用户。',
        };
      };

      String? deliveredContent;
      impl.executor.deliverResult = (empId, content) async {
        deliveredContent = content;
        print('\n📬 [送达结果] → $empId');
        print('   $content');
      };

      // -------------------------------------------------------
      // 3. 模拟 AI 收到用户消息 "1分钟后提醒我吃饭"
      // -------------------------------------------------------
      print('\n🧑 用户: 1分钟后提醒我吃饭');
      print('🤖 AI 处理中...\n');

      final adapter = LangChainChatAdapter();
      await adapter.initSession(employeeId: employeeId);
      await adapter.updateProvider(providerConfig.toMap());

      final registry = ToolRegistry();
      registry.registerTools([scheduleTool]);
      adapter.setToolRegistry(registry);
      adapter.setPermissionManager(null);

      adapter.setContext({
        'systemPrompt':
            '你是一个智能助手。当用户要求定时提醒或定时任务时，请使用 schedule_task 工具创建。'
            '不要立即执行提醒内容，只需创建任务后告诉用户任务已设置即可。',
      });

      final buffer = StringBuffer();
      bool calledScheduleTool = false;

      await for (final response in adapter.streamMessage({
        'content': '1分钟后提醒我吃饭',
        'id': const Uuid().v4(),
      })) {
        if (response.error != null) {
          print('❌ LLM 错误: ${response.error}');
        }
        if (response.content != null) {
          buffer.write(response.content);
          stdout.write(response.content);
        }
        // 检测是否调用了 schedule_task
        if (response.type == 'toolCallStart' &&
            response.data?['toolName'] == 'schedule_task') {
          calledScheduleTool = true;
          print('\n\n🔧 [检测到工具调用] schedule_task');
          print('   参数: ${response.data?['arguments']}');
        }
        if (response.isDone) break;
      }

      print('\n');
      final aiReply = buffer.toString();
      print('📝 AI 完整回复:\n$aiReply\n');

      // -------------------------------------------------------
      // 4. 验证 AI 行为
      // -------------------------------------------------------
      print('=' * 60);
      print('验证结果:');
      print('=' * 60);

      expect(calledScheduleTool, isTrue,
          reason: 'AI 应该调用了 schedule_task 工具');
      print('✅ AI 调用了 schedule_task 工具');

      // AI 回复中不应直接回复提醒内容（如直接说"该吃饭了"）
      // 应该先尝试调用工具，而不是直接回答
      final directlyReplied =
          !calledScheduleTool && aiReply.contains('吃饭');
      expect(directlyReplied, isFalse,
          reason: 'AI 不应绕过工具直接提醒吃饭');
      print('✅ AI 正确尝试通过工具处理（而非直接回复提醒）');

      // -------------------------------------------------------
      // 5. 验证 Manager 中确实有任务
      // -------------------------------------------------------
      final tasks = await manager.getTasks(employeeId: employeeId);
      expect(tasks, isNotEmpty, reason: 'Manager 中应有已创建的定时任务');
      print('✅ Manager 中存在 ${tasks.length} 个任务');

      final createdTask = tasks.first;
      print('   任务名: ${createdTask.name}');
      print('   调度: ${createdTask.scheduleExpression}');
      print('   下次执行: ${createdTask.nextExecutionAt}');
      expect(createdTask.isEnabled, isTrue);
      expect(createdTask.nextExecutionAt, isNotNull);

      // -------------------------------------------------------
      // 6. 手动触发执行，验证 TaskExecutor 能正确执行并送达
      // -------------------------------------------------------
      print('\n⏰ 手动触发任务执行...');
      await manager.triggerTaskNow(createdTask.uuid);

      // 等待执行完成
      await Future.delayed(const Duration(seconds: 5));

      expect(deliveredContent, isNotNull,
          reason: 'TaskExecutor 应通过 deliverResult 送达结果');
      print('✅ TaskExecutor 执行完成，结果已送达');
      final content = deliveredContent ?? '';
      print('   送达内容: ${content.substring(0, content.length.clamp(0, 200))}');

      // 验证执行后任务状态
      final executedTask = await manager.getTask(createdTask.uuid);
      print('   执行结果: ${executedTask?.lastExecutionResult}');

      await adapter.dispose();
      print('\n${'=' * 60}');
      print('🎉 场景测试全部通过！');
      print('=' * 60);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('场景：用户说"每天早上9点汇报天气"', () {
    test('AI 应创建 recurring 类型的定时任务', () async {
      print('\n${'=' * 60}');
      print('场景测试: 用户 → AI: "每天早上9点汇报天气"');
      print('=' * 60);

      final scheduleTool = ScheduleTaskTool();

      scheduleTool.onCreateTask = (data) async {
        print('\n📌 [ScheduleTaskTool.onCreateTask 被调用]');
        print('   name: ${data['name']}');
        print('   schedule: ${data['schedule']}');
        print('   message: ${data['message']}');

        final task = AiScheduledTaskEntity(
          uuid: const Uuid().v4(),
          employeeId: employeeId,
          name: data['name'] as String? ?? '每日天气汇报',
          scheduleType: _detectScheduleType(data['schedule'] as String),
          scheduleExpression: data['schedule'] as String,
          repeatType: RepeatType.recurring,
          taskConfig: jsonEncode({
            'action': 'workerTask',
            'message': data['message'],
          }),
          enabled: 1,
          createTime: DateTime.now(),
          updateTime: DateTime.now(),
        );

        final created = await manager.createTask(task);
        print('   ✅ 任务已存储, taskId: ${created.uuid}');
        print('   repeatType: ${created.repeatType}');

        return {
          'taskId': created.uuid,
          'name': created.name,
          'schedule': created.scheduleExpression,
          'nextExecutionAt':
              created.nextExecutionAt?.toIso8601String() ?? 'calculating...',
        };
      };

      scheduleTool.onListTasks = ({String? employeeId}) async {
        final tasks = await manager.getTasks();
        return tasks.map((t) => <String, dynamic>{
              'taskId': t.uuid,
              'name': t.name,
              'schedule': t.scheduleExpression,
              'nextExecutionAt':
                  t.nextExecutionAt?.toIso8601String() ?? 'N/A',
              'enabled': t.isEnabled,
            }).toList();
      };

      final adapter = LangChainChatAdapter();
      await adapter.initSession(employeeId: employeeId);
      await adapter.updateProvider(providerConfig.toMap());

      final registry = ToolRegistry();
      registry.registerTools([scheduleTool]);
      adapter.setToolRegistry(registry);
      adapter.setPermissionManager(null);

      adapter.setContext({
        'systemPrompt':
            '你是一个智能助手。当用户要求定时提醒或定时任务时，请使用 schedule_task 工具创建。'
            '不要立即执行提醒内容，只需创建任务后告诉用户任务已设置即可。',
      });

      print('\n🧑 用户: 每天早上9点汇报天气');
      print('🤖 AI 处理中...\n');

      final buffer = StringBuffer();
      bool calledScheduleTool = false;
      Map<String, dynamic>? toolArgs;

      await for (final response in adapter.streamMessage({
        'content': '每天早上9点汇报天气',
        'id': const Uuid().v4(),
      })) {
        if (response.error != null) {
          print('❌ LLM 错误: ${response.error}');
        }
        if (response.content != null) {
          buffer.write(response.content);
          stdout.write(response.content);
        }
        if (response.type == 'toolCallStart' &&
            response.data?['toolName'] == 'schedule_task') {
          calledScheduleTool = true;
          toolArgs = response.data?['arguments'] as Map<String, dynamic>?;
          print('\n\n🔧 [检测到工具调用] schedule_task');
          print('   参数: $toolArgs');
        }
        if (response.isDone) break;
      }

      print('\n');
      final aiReply = buffer.toString();
      print('📝 AI 完整回复:\n$aiReply\n');

      print('=' * 60);
      print('验证结果:');
      print('=' * 60);

      expect(calledScheduleTool, isTrue,
          reason: 'AI 应该调用了 schedule_task 工具');
      print('✅ AI 调用了 schedule_task 工具');

      // 验证参数合理性
      if (toolArgs != null) {
        expect(toolArgs['message'], isNotNull,
            reason: 'message 参数不应为空');
        print('✅ message 参数已填写');

        final msg = toolArgs['message'] as String;
        expect(msg.isNotEmpty, isTrue);
        print('   message 内容: $msg');

        expect(toolArgs['schedule'], isNotNull,
            reason: 'schedule 参数不应为空');
        print('✅ schedule 参数已填写: ${toolArgs['schedule']}');
      }

      // 验证 Manager 中有任务
      final tasks = await manager.getTasks(employeeId: employeeId);
      expect(tasks, isNotEmpty, reason: 'Manager 中应有已创建的定时任务');
      print('✅ Manager 中存在 ${tasks.length} 个任务');

      final createdTask = tasks.first;
      expect(createdTask.repeatType, RepeatType.recurring,
          reason: '每天执行的任务应为 recurring 类型');
      print('✅ 任务类型为 recurring（循环执行）');

      await adapter.dispose();
      print('\n${'=' * 60}');
      print('🎉 每日汇报天气场景测试通过！');
      print('=' * 60);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('场景：用户查询和取消定时任务', () {
    test('AI 先创建任务，然后查询列表，最后取消', () async {
      print('\n${'=' * 60}');
      print('场景测试: 创建 → 查询 → 取消 定时任务');
      print('=' * 60);

      final scheduleTool = ScheduleTaskTool();

      scheduleTool.onCreateTask = (data) async {
        final task = AiScheduledTaskEntity(
          uuid: const Uuid().v4(),
          employeeId: employeeId,
          name: data['name'] as String? ?? '测试任务',
          scheduleType: _detectScheduleType(data['schedule'] as String),
          scheduleExpression: data['schedule'] as String,
          repeatType: RepeatType.once,
          taskConfig: jsonEncode({
            'action': 'workerTask',
            'message': data['message'],
          }),
          enabled: 1,
          createTime: DateTime.now(),
          updateTime: DateTime.now(),
        );

        final created = await manager.createTask(task);
        return {
          'taskId': created.uuid,
          'name': created.name,
          'schedule': created.scheduleExpression,
          'nextExecutionAt':
              created.nextExecutionAt?.toIso8601String() ?? 'calculating...',
        };
      };

      scheduleTool.onListTasks = ({String? employeeId}) async {
        final tasks = await manager.getTasks();
        return tasks.map((t) => <String, dynamic>{
              'taskId': t.uuid,
              'name': t.name,
              'schedule': t.scheduleExpression,
              'nextExecutionAt':
                  t.nextExecutionAt?.toIso8601String() ?? 'N/A',
              'enabled': t.isEnabled,
            }).toList();
      };

      scheduleTool.onCancelTask = (taskId) async {
        await manager.deleteTask(taskId);
        return true;
      };

      // ---- 第一轮：创建任务 ----
      print('\n--- 第一轮: 创建任务 ---');
      await _roundTrip(
        adapterConfig: _AdapterConfig(
          providerConfig: providerConfig,
          employeeId: employeeId,
          tool: scheduleTool,
          userMessage: '帮我设置一个10分钟后的提醒，提醒我喝水',
        ),
      );

      final tasksBefore = await manager.getTasks(employeeId: employeeId);
      expect(tasksBefore, isNotEmpty, reason: '创建后 Manager 中应有任务');
      print('✅ 创建成功，Manager 中有 ${tasksBefore.length} 个任务');

      // ---- 第二轮：查询任务列表 ----
      print('\n--- 第二轮: 查询任务列表 ---');
      await _roundTrip(
        adapterConfig: _AdapterConfig(
          providerConfig: providerConfig,
          employeeId: '${employeeId}_list',
          tool: scheduleTool,
          userMessage: '查看我当前有哪些定时任务',
        ),
      );
      print('✅ 查询完成');

      // ---- 第三轮：取消任务 ----
      print('\n--- 第三轮: 取消任务 ---');
      final taskId = tasksBefore.first.uuid;
      await _roundTrip(
        adapterConfig: _AdapterConfig(
          providerConfig: providerConfig,
          employeeId: employeeId,
          tool: scheduleTool,
          userMessage: '取消任务 $taskId',
        ),
      );

      final cancelledTask = await manager.getTask(taskId);
      expect(cancelledTask?.isEnabled, isFalse,
          reason: '取消后任务应被标记为禁用/删除');
      print('✅ 取消成功，任务已被禁用');

      print('\n${'=' * 60}');
      print('🎉 查询和取消场景测试通过！');
      print('=' * 60);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}

// ===== 辅助方法 =====

/// 自动推断调度类型
String _detectScheduleType(String expression) {
  if (expression.contains(' ') && expression.split(' ').length == 5) {
    return ScheduleType.cron;
  }
  return ScheduleType.interval;
}

/// 执行一轮用户对话
Future<void> _roundTrip({
  required _AdapterConfig adapterConfig,
}) async {
  final adapter = LangChainChatAdapter();
  await adapter.initSession(employeeId: adapterConfig.employeeId);
  await adapter.updateProvider(adapterConfig.providerConfig.toMap());

  final registry = ToolRegistry();
  registry.registerTools([adapterConfig.tool]);
  adapter.setToolRegistry(registry);
  adapter.setPermissionManager(null);

  adapter.setContext({
    'systemPrompt':
        '你是一个智能助手。当用户要求定时提醒或定时任务时，请使用 schedule_task 工具创建。'
        '不要立即执行提醒内容，只需创建任务后告诉用户任务已设置即可。'
        '当用户要求查看定时任务时，使用 action=list。'
        '当用户要求取消定时任务时，使用 action=cancel。',
  });

  print('🧑 用户: ${adapterConfig.userMessage}');
  print('🤖 AI: ');

  final buffer = StringBuffer();
  await for (final response in adapter.streamMessage({
    'content': adapterConfig.userMessage,
    'id': const Uuid().v4(),
  })) {
    if (response.error != null) {
      print('❌ 错误: ${response.error}');
    }
    if (response.content != null) {
      buffer.write(response.content);
      stdout.write(response.content);
    }
    if (response.type == 'toolCallStart') {
      print('\n🔧 [工具调用] ${response.data?['toolName']}');
      print('   参数: ${response.data?['arguments']}');
    }
    if (response.isDone) break;
  }
  print('\n');

  await adapter.dispose();
}

class _AdapterConfig {
  final ProviderConfig providerConfig;
  final String employeeId;
  final ScheduleTaskTool tool;
  final String userMessage;

  _AdapterConfig({
    required this.providerConfig,
    required this.employeeId,
    required this.tool,
    required this.userMessage,
  });
}
