import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/agent/adapter/langchain_chat_adapter.dart';
import 'package:wenzagent/src/agent/adapter/provider_config.dart';
import 'package:wenzagent/src/agent/tool/builtin/builtin_tools.dart';
import 'package:wenzagent/src/agent/tool/builtin/schedule_task_tool.dart';
import 'package:wenzagent/src/agent/tool/tool_registry.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/scheduled_task_manager.dart';
import 'package:wenzagent/src/service/task_executor.dart';

/// 任务型定时任务测试
///
/// 测试 taskType=task 的定时任务：
/// 1. 创建任务时 taskType 为 "task"
/// 2. 触发时走 TaskExecutor（sub-agent）路径
/// 3. sub-agent 能正确执行工具并返回结果
/// 4. 结果通过 deliverResult 送达
void main() {
  late String apiKey;
  late String apiUrl;
  late String apiModel;
  late ProviderConfig providerConfig;
  late ScheduledTaskManager manager;

  setUpAll(() {
    apiKey = Platform.environment['OPENAI_API_KEY'] ?? '';
    apiUrl =
        Platform.environment['OPENAI_API_URL'] ?? 'https://api.openai.com/v1';
    apiModel =
        Platform.environment['OPENAI_API_MODEL'] ?? 'gpt-3.5-turbo';

    if (apiKey.isEmpty) {
      throw Exception('请设置环境变量 OPENAI_API_KEY');
    }

    print('=== 任务型定时任务测试配置 ===');
    print('API URL: $apiUrl');
    print('API Model: $apiModel');

    providerConfig = ProviderConfig(
      provider: LLMProvider.openai,
      apiKey: apiKey,
      baseUrl: apiUrl,
      model: apiModel,
    );
  });

  setUp(() async {
    await HiveManager.instance.initialize(
      storagePath:
          '${Directory.systemTemp.path}/wenzagent_task_test_${DateTime.now().millisecondsSinceEpoch}',
    );
    manager = ScheduledTaskManagerImpl();
  });

  tearDown(() async {
    if (manager.isRunning) await manager.stop();
    (manager as ScheduledTaskManagerImpl).dispose();
    await HiveManager.instance.close();
  });

  group('Entity: taskType 字段', () {
    test('taskType 默认为 reminder', () {
      final now = DateTime.now();
      final task = AiScheduledTaskEntity(
        uuid: 't1',
        name: '默认类型',
        scheduleExpression: 'PT1H',
        enabled: 1,
        createTime: now,
        updateTime: now,
      );
      expect(task.taskType, 'reminder');
    });

    test('taskType 可设置为 task', () {
      final now = DateTime.now();
      final task = AiScheduledTaskEntity(
        uuid: 't2',
        name: '任务型',
        scheduleExpression: 'PT1H',
        taskType: TaskType.task,
        enabled: 1,
        createTime: now,
        updateTime: now,
      );
      expect(task.taskType, 'task');
    });

    test('toMap / fromMap 保留 taskType', () {
      final now = DateTime.now();
      final task = AiScheduledTaskEntity(
        uuid: 't3',
        name: '序列化测试',
        scheduleExpression: '0 9 * * *',
        taskType: TaskType.task,
        enabled: 1,
        createTime: now,
        updateTime: now,
      );

      final map = task.toMap();
      expect(map['taskType'], 'task');

      final restored = AiScheduledTaskEntity.fromMap(map);
      expect(restored.taskType, 'task');
    });
  });

  group('ScheduleTaskTool: taskType 参数', () {
    test('create 传入 taskType=task', () async {
      final tool = ScheduleTaskTool();
      tool.onCreateTask = (data) async {
        expect(data['taskType'], 'task');
        return {
          'taskId': 'task-1',
          'name': data['name'],
          'taskType': data['taskType'],
          'schedule': data['schedule'],
          'nextExecutionAt': '2026-04-10T09:00:00',
        };
      };

      final result = await tool.execute({
        'action': 'create',
        'name': '每日日报',
        'schedule': '0 18 * * *',
        'message': '请整理今日工作内容并生成日报',
        'taskType': 'task',
      });

      expect(result.isError, isFalse);
      expect(result.content, contains('task'));
    });

    test('create 不传 taskType 默认为 reminder', () async {
      final tool = ScheduleTaskTool();
      String? receivedTaskType;
      tool.onCreateTask = (data) async {
        receivedTaskType = data['taskType'] as String?;
        return {
          'taskId': 'rem-1',
          'name': data['name'],
          'schedule': data['schedule'],
          'nextExecutionAt': '2026-04-10T09:00:00',
        };
      };

      await tool.execute({
        'action': 'create',
        'name': '喝水提醒',
        'schedule': 'PT30M',
        'message': '该喝水了！',
      });

      // tool 层不传 taskType 时，默认为 'reminder'
      expect(receivedTaskType, 'reminder');
    });
  });

  group('ScheduledTaskManager: 任务型任务执行', () {
    test(
        '创建 taskType=task 的任务并手动触发，'
        '应走 TaskExecutor 路径', () async {
      final impl = manager as ScheduledTaskManagerImpl;

      // 注入 TaskExecutor 配置
      impl.taskExecutor.getAgentConfig = (employeeId) async {
        return {
          'providerConfig': providerConfig.toMap(),
          'systemPrompt': '你是一个工作助手，请简洁回答。',
          'tools': BuiltinTools.readOnly(),
        };
      };

      String? deliveredContent;
      impl.taskExecutor.deliverResult = (employeeId, content) async {
        deliveredContent = content;
        print('📬 deliverResult 收到: '
            '${content.substring(0, content.length.clamp(0, 200))}');
      };

      // 注入 getAgent（_executeTask 内部目前不使用 getAgent）
      impl.getAgent = (employeeId) async => null;

      // 创建任务型任务
      final task = AiScheduledTaskEntity(
        uuid: const Uuid().v4(),
        employeeId: 'task-test-emp',
        name: '文件读取任务',
        scheduleType: ScheduleType.interval,
        scheduleExpression: 'PT1H',
        taskType: TaskType.task,
        taskConfig: jsonEncode({
          'action': 'sendMessage',
          'message': '请用一句话回答：1+1等于几？',
        }),
        enabled: 1,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );

      final created = await manager.createTask(task);
      expect(created.taskType, 'task');

      // 手动触发
      print('⏰ 触发任务型任务...');
      await manager.triggerTaskNow(created.uuid);

      // 验证执行结果
      final executed = await manager.getTask(created.uuid);
      expect(executed?.lastExecutionResult, 'success');

      // 验证 deliverResult 被调用
      expect(deliveredContent, isNotNull);
      print('✅ 任务型任务执行成功，结果已送达');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
        'taskType=task 的任务使用 file_read 工具读取文件', () async {
      final impl = manager as ScheduledTaskManagerImpl;

      final testFilePath = 'd:\\project\\GitHub\\wenzagent\\pubspec.yaml';

      impl.taskExecutor.getAgentConfig = (employeeId) async {
        return {
          'providerConfig': providerConfig.toMap(),
          'systemPrompt': '你是一个工作助手。请按指示使用工具完成任务。',
          'tools': BuiltinTools.readOnly(),
        };
      };

      String? deliveredContent;
      impl.taskExecutor.deliverResult = (employeeId, content) async {
        deliveredContent = content;
      };

      final task = AiScheduledTaskEntity(
        uuid: const Uuid().v4(),
        employeeId: 'task-tool-emp',
        name: '读取项目配置',
        scheduleType: ScheduleType.interval,
        scheduleExpression: 'P1D',
        taskType: TaskType.task,
        taskConfig: jsonEncode({
          'action': 'sendMessage',
          'message': '请使用 file_read 工具读取文件 $testFilePath，'
              '然后告诉我项目的名称（name 字段）是什么。',
        }),
        enabled: 1,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );

      final created = await manager.createTask(task);
      await manager.triggerTaskNow(created.uuid);

      expect(deliveredContent, isNotNull);
      // 结果中应包含项目名称
      expect(deliveredContent, contains('wenzagent'));
      print('✅ 任务型工具调用测试通过');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('对比：reminder vs task 执行路径', () {
    test('reminder 类不调用 TaskExecutor', () async {
      // reminder 类走 triggerSystemTask，不需要 TaskExecutor
      // 如果 getAgent 为 null，_executeReminder 会 fallback 到 sendMessage（也会失败）
      // 这里只验证 taskType 的分发逻辑

      final impl = manager as ScheduledTaskManagerImpl;

      // 不注入 TaskExecutor 配置
      // 创建 reminder 任务
      final task = AiScheduledTaskEntity(
        uuid: const Uuid().v4(),
        name: '纯 reminder 测试',
        scheduleExpression: 'PT1H',
        taskType: TaskType.reminder,
        taskConfig: jsonEncode({
          'action': 'sendMessage',
          'message': '该喝水了',
        }),
        enabled: 1,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );

      final created = await manager.createTask(task);
      expect(created.taskType, 'reminder');

      // 触发执行（getAgent 为 null，会失败，但不会走 TaskExecutor 路径）
      await manager.triggerTaskNow(created.uuid);

      final executed = await manager.getTask(created.uuid);
      // getAgent 为 null 所以失败，但证明没走 task 路径
      expect(executed?.lastExecutionResult, 'failed');
      print('✅ reminder 类确认不走 TaskExecutor 路径');
    });
  });
}
