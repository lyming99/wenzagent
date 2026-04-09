import 'dart:async';
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
import 'package:wenzagent/src/scheduler/cron_expression.dart';
import 'package:wenzagent/src/scheduler/task_scheduler.dart';
import 'package:wenzagent/src/service/scheduled_task_manager.dart';
import 'package:wenzagent/src/service/task_executor.dart';

void main() {
  // ============================================================
  // CronExpression 单元测试
  // ============================================================
  group('CronExpression', () {
    test('解析标准 5 段表达式', () {
      final cron = CronExpression.parse('0 9 * * 1-5');
      expect(cron.minutes, {0});
      expect(cron.hours, {9});
      expect(cron.daysOfWeek, {1, 2, 3, 4, 5});
    });

    test('解析通配符 * * * * *', () {
      final cron = CronExpression.parse('* * * * *');
      expect(cron.minutes.length, 60); // 0-59
      expect(cron.hours.length, 24); // 0-23
    });

    test('解析步长 */15 * * * *', () {
      final cron = CronExpression.parse('*/15 * * * *');
      expect(cron.minutes, {0, 15, 30, 45});
    });

    test('解析枚举 0,30 * * * *', () {
      final cron = CronExpression.parse('0,30 * * * *');
      expect(cron.minutes, {0, 30});
    });

    test('计算下一个执行时间 — 工作日 9 点', () {
      final cron = CronExpression.parse('0 9 * * 1-5');
      // 周一 8:00 → 下一个是周一 9:00
      final monday8am = DateTime(2026, 4, 6, 8, 0); // 2026-04-06 是周一
      final next = cron.next(monday8am);
      expect(next, isNotNull);
      expect(next!.hour, 9);
      expect(next.minute, 0);
      expect(next.weekday, 1); // 周一
    });

    test('计算下一个执行时间 — 跳过到下一个工作日', () {
      final cron = CronExpression.parse('0 9 * * 1-5');
      // 周六 10:00 → 下一个是周一 9:00
      final saturday10am = DateTime(2026, 4, 11, 10, 0); // 周六
      final next = cron.next(saturday10am);
      expect(next, isNotNull);
      expect(next!.weekday, 1); // 周一
      expect(next.hour, 9);
    });

    test('每 30 分钟 — 下一个就在 30 分钟后', () {
      final cron = CronExpression.parse('*/30 * * * *');
      final now = DateTime(2026, 4, 9, 10, 15);
      final next = cron.next(now);
      expect(next, isNotNull);
      expect(next!.minute, anyOf(0, 30));
    });

    test('非法格式抛出 FormatException', () {
      expect(() => CronExpression.parse('0 9 * *'), throwsFormatException);
      expect(() => CronExpression.parse('60 9 * * *'), throwsFormatException);
      expect(() => CronExpression.parse('0 25 * * *'), throwsFormatException);
    });

    test('isValid 正确判断', () {
      expect(CronExpression.isValid('0 9 * * 1-5'), isTrue);
      expect(CronExpression.isValid('invalid'), isFalse);
      expect(CronExpression.isValid('0 9 * * * *'), isFalse);
    });
  });

  // ============================================================
  // IsoDuration 单元测试
  // ============================================================
  group('IsoDuration', () {
    test('解析 PT30M', () {
      final d = IsoDuration.parse('PT30M');
      expect(d.totalMinutes, 30);
    });

    test('解析 PT1H', () {
      final d = IsoDuration.parse('PT1H');
      expect(d.totalMinutes, 60);
    });

    test('解析 P1D', () {
      final d = IsoDuration.parse('P1D');
      expect(d.totalMinutes, 1440);
    });

    test('解析 PT1H30M', () {
      final d = IsoDuration.parse('PT1H30M');
      expect(d.totalMinutes, 90);
    });

    test('计算下一个执行时间', () {
      final d = IsoDuration.parse('PT1H');
      final base = DateTime(2026, 4, 9, 10, 0);
      final next = d.next(base);
      expect(next, DateTime(2026, 4, 9, 11, 0));
    });

    test('非法格式抛异常', () {
      expect(() => IsoDuration.parse(''), throwsFormatException);
      expect(() => IsoDuration.parse('invalid'), throwsFormatException);
    });

    test('isValid 正确判断', () {
      expect(IsoDuration.isValid('PT30M'), isTrue);
      expect(IsoDuration.isValid('P1D'), isTrue);
      expect(IsoDuration.isValid('invalid'), isFalse);
    });
  });

  // ============================================================
  // AiScheduledTaskEntity 测试
  // ============================================================
  group('AiScheduledTaskEntity', () {
    test('toMap / fromMap 序列化往返', () {
      final now = DateTime.now();
      final task = AiScheduledTaskEntity(
        uuid: 'test-uuid-1',
        employeeId: 'emp-1',
        name: '测试任务',
        scheduleType: ScheduleType.cron,
        scheduleExpression: '0 9 * * 1-5',
        repeatType: RepeatType.recurring,
        taskConfig: jsonEncode({'action': 'workerTask', 'message': 'hello'}),
        enabled: 1,
        createTime: now,
        updateTime: now,
      );

      final map = task.toMap();
      final restored = AiScheduledTaskEntity.fromMap(map);

      expect(restored.uuid, task.uuid);
      expect(restored.employeeId, task.employeeId);
      expect(restored.name, task.name);
      expect(restored.scheduleType, task.scheduleType);
      expect(restored.scheduleExpression, task.scheduleExpression);
      expect(restored.taskConfig, task.taskConfig);
      expect(restored.isEnabled, isTrue);
      expect(restored.isExpired, isFalse);
    });

    test('copyWith 正确工作', () {
      final now = DateTime.now();
      final task = AiScheduledTaskEntity(
        uuid: 'test-uuid-2',
        name: '原名称',
        scheduleType: ScheduleType.interval,
        scheduleExpression: 'PT1H',
        enabled: 1,
        createTime: now,
        updateTime: now,
      );

      final updated = task.copyWith(name: '新名称', enabled: 0);
      expect(updated.name, '新名称');
      expect(updated.enabled, 0);
      expect(updated.uuid, task.uuid); // uuid 不变
    });

    test('isEnabled 和 isExpired 判断', () {
      final now = DateTime.now();
      final enabled = AiScheduledTaskEntity(
        uuid: 't1',
        name: 'n',
        scheduleExpression: 'PT1H',
        enabled: 1,
        deleted: 0,
        createTime: now,
        updateTime: now,
      );
      final disabled = enabled.copyWith(enabled: 0);
      final deleted = enabled.copyWith(deleted: 1);
      final expired = enabled.copyWith(
        endAt: now.subtract(const Duration(days: 1)),
      );

      expect(enabled.isEnabled, isTrue);
      expect(disabled.isEnabled, isFalse);
      expect(deleted.isEnabled, isFalse);
      expect(expired.isExpired, isTrue);
    });
  });

  // ============================================================
  // TaskScheduler 单元测试
  // ============================================================
  group('TaskScheduler', () {
    late TaskScheduler scheduler;

    setUp(() {
      scheduler = TaskScheduler();
    });

    tearDown(() {
      scheduler.stop();
    });

    test('启动和停止', () {
      expect(scheduler.isRunning, isFalse);
      scheduler.start([]);
      expect(scheduler.isRunning, isTrue);
      scheduler.stop();
      expect(scheduler.isRunning, isFalse);
    });

    test('添加/移除/更新任务', () {
      scheduler.start([]);

      final now = DateTime.now();
      final task = AiScheduledTaskEntity(
        uuid: 'sched-1',
        name: '测试',
        scheduleType: ScheduleType.cron,
        scheduleExpression: '0 9 * * *',
        enabled: 1,
        createTime: now,
        updateTime: now,
        nextExecutionAt: DateTime(now.year + 1, 1, 1, 9, 0),
      );

      scheduler.addTask(task);
      expect(scheduler.scheduledCount, 1);

      scheduler.removeTask('sched-1');
      expect(scheduler.scheduledCount, 0);

      scheduler.addTask(task);
      expect(scheduler.scheduledCount, 1);
    });

    test('到期任务触发 onExecute 回调', () async {
      final executedTasks = <String>[];

      scheduler.onExecute = (task) async {
        executedTasks.add(task.uuid);
        return true;
      };

      final now = DateTime.now();
      // 创建一个 nextExecutionAt 在 1 秒前的任务（已到期）
      final task = AiScheduledTaskEntity(
        uuid: 'due-task',
        name: '到期任务',
        scheduleType: ScheduleType.interval,
        scheduleExpression: 'PT1H',
        repeatType: RepeatType.recurring,
        enabled: 1,
        createTime: now,
        updateTime: now,
        nextExecutionAt: now.subtract(const Duration(seconds: 1)),
      );

      scheduler.start([task]);

      // 等待 2 秒让 timer tick 触发
      await Future.delayed(const Duration(seconds: 2));

      expect(executedTasks, contains('due-task'));
    });

    test('disabled 任务不触发执行', () async {
      var executed = false;
      scheduler.onExecute = (_) async {
        executed = true;
        return true;
      };

      final now = DateTime.now();
      final task = AiScheduledTaskEntity(
        uuid: 'disabled-task',
        name: '禁用任务',
        scheduleType: ScheduleType.interval,
        scheduleExpression: 'PT1H',
        enabled: 0, // 禁用
        nextExecutionAt: now.subtract(const Duration(seconds: 1)),
        createTime: now,
        updateTime: now,
      );

      scheduler.start([task]);
      await Future.delayed(const Duration(seconds: 2));

      expect(executed, isFalse);
    });
  });

  // ============================================================
  // ScheduledTaskManager 集成测试（需要 Hive）
  // ============================================================
  group('ScheduledTaskManager', () {
    late ScheduledTaskManager manager;

    setUpAll(() async {
      await HiveManager.instance.initialize(
        storagePath: '${Directory.systemTemp.path}/wenzagent_test_hive',
      );
    });

    tearDownAll(() async {
      await HiveManager.instance.close();
    });

    setUp(() async {
      manager = ScheduledTaskManagerImpl();
    });

    tearDown(() async {
      if (manager.isRunning) {
        await manager.stop();
      }
      (manager as ScheduledTaskManagerImpl).dispose();
    });

    test('创建并查询任务', () async {
      final task = AiScheduledTaskEntity(
        uuid: const Uuid().v4(),
        employeeId: 'emp-test-1',
        name: '测试任务-创建',
        scheduleType: ScheduleType.cron,
        scheduleExpression: '0 9 * * 1-5',
        taskConfig: jsonEncode({
          'action': 'workerTask',
          'message': 'hello',
        }),
        enabled: 1,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );

      final created = await manager.createTask(task);
      expect(created.uuid, task.uuid);
      expect(created.nextExecutionAt, isNotNull,
          reason: '创建时应计算 nextExecutionAt');

      // 查询
      final found = await manager.getTask(created.uuid);
      expect(found, isNotNull);
      expect(found!.name, '测试任务-创建');

      // 按员工查询
      final empTasks = await manager.getTasks(employeeId: 'emp-test-1');
      expect(empTasks.length, 1);

      // 清理
      await manager.deleteTask(created.uuid);
    });

    test('更新任务', () async {
      final task = AiScheduledTaskEntity(
        uuid: const Uuid().v4(),
        employeeId: 'emp-test-2',
        name: '原名称',
        scheduleType: ScheduleType.interval,
        scheduleExpression: 'PT1H',
        enabled: 1,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );

      final created = await manager.createTask(task);
      final updated = await manager.updateTask(
        created.copyWith(name: '新名称'),
      );
      expect(updated.name, '新名称');

      await manager.deleteTask(created.uuid);
    });

    test('启用/禁用任务', () async {
      final task = AiScheduledTaskEntity(
        uuid: const Uuid().v4(),
        employeeId: 'emp-test-3',
        name: '启用禁用测试',
        scheduleType: ScheduleType.interval,
        scheduleExpression: 'PT1H',
        enabled: 1,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );

      final created = await manager.createTask(task);
      expect(created.isEnabled, isTrue);

      await manager.disableTask(created.uuid);
      final disabled = await manager.getTask(created.uuid);
      expect(disabled!.isEnabled, isFalse);

      await manager.enableTask(created.uuid);
      final enabled = await manager.getTask(created.uuid);
      expect(enabled!.isEnabled, isTrue);

      await manager.deleteTask(created.uuid);
    });

    test('删除任务', () async {
      final task = AiScheduledTaskEntity(
        uuid: const Uuid().v4(),
        name: '待删除',
        scheduleType: ScheduleType.interval,
        scheduleExpression: 'PT1H',
        enabled: 1,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );

      final created = await manager.createTask(task);
      await manager.deleteTask(created.uuid);

      final found = await manager.getTask(created.uuid);
      expect(found!.deleted, 1);
      expect(found.isEnabled, isFalse);
    });

    test('启动和停止调度器', () async {
      expect(manager.isRunning, isFalse);
      await manager.start();
      expect(manager.isRunning, isTrue);
      await manager.stop();
      expect(manager.isRunning, isFalse);
    });

    test('事件流发出创建/删除事件', () async {
      final events = <ScheduledTaskEvent>[];
      final sub = manager.onTaskEvent.listen(events.add);

      final task = AiScheduledTaskEntity(
        uuid: const Uuid().v4(),
        name: '事件测试',
        scheduleType: ScheduleType.interval,
        scheduleExpression: 'PT1H',
        enabled: 1,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      );

      final created = await manager.createTask(task);
      await manager.deleteTask(created.uuid);

      // 等事件传播
      await Future.delayed(const Duration(milliseconds: 100));

      expect(events.any((e) => e.type == ScheduledTaskEventType.created), isTrue);
      expect(events.any((e) => e.type == ScheduledTaskEventType.deleted), isTrue);

      await sub.cancel();
    });
  });

  // ============================================================
  // ScheduleTaskTool 测试
  // ============================================================
  group('ScheduleTaskTool', () {
    late ScheduleTaskTool tool;

    setUp(() {
      tool = ScheduleTaskTool();
    });

    test('基本属性', () {
      expect(tool.name, 'schedule_task');
      expect(tool.requiresPermission, isTrue);
      expect(tool.description, isNotEmpty);
      expect(tool.inputJsonSchema['required'], contains('action'));
    });

    test('create — 成功创建', () async {
      tool.onCreateTask = (data) async {
        return {
          'taskId': 'new-task-1',
          'name': data['name'],
          'schedule': data['schedule'],
          'nextExecutionAt': '2026-04-10T09:00:00',
        };
      };

      final result = await tool.execute({
        'action': 'create',
        'name': '每日汇报',
        'schedule': '0 9 * * *',
        'message': '请整理今日工作总结',
      });

      expect(result.isError, isFalse);
      expect(result.content, contains('new-task-1'));
      expect(result.content, contains('每日汇报'));
    });

    test('create — 缺少 message 报错', () async {
      final result = await tool.execute({
        'action': 'create',
        'schedule': '0 9 * * *',
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('message'));
    });

    test('create — 未注入回调报错', () async {
      tool.onCreateTask = null;
      final result = await tool.execute({
        'action': 'create',
        'message': 'hello',
        'schedule': 'PT1H',
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('not available'));
    });

    test('list — 返回任务列表', () async {
      tool.onListTasks = ({employeeId}) async {
        return [
          {
            'taskId': 't1',
            'name': 'Task 1',
            'schedule': '0 9 * * *',
            'nextExecutionAt': '2026-04-10T09:00:00',
            'enabled': true,
          },
        ];
      };

      final result = await tool.execute({'action': 'list'});
      expect(result.isError, isFalse);
      expect(result.content, contains('t1'));
      expect(result.content, contains('Task 1'));
    });

    test('list — 无任务', () async {
      tool.onListTasks = ({employeeId}) async => [];
      final result = await tool.execute({'action': 'list'});
      expect(result.isError, isFalse);
      expect(result.content, contains('No scheduled tasks'));
    });

    test('cancel — 成功取消', () async {
      tool.onCancelTask = (taskId) async => true;
      final result = await tool.execute({
        'action': 'cancel',
        'taskId': 't1',
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('cancelled'));
    });

    test('cancel — 缺少 taskId 报错', () async {
      final result = await tool.execute({'action': 'cancel'});
      expect(result.isError, isTrue);
      expect(result.content, contains('taskId'));
    });

    test('unknown action 报错', () async {
      final result = await tool.execute({'action': 'unknown'});
      expect(result.isError, isTrue);
      expect(result.content, contains('Unknown action'));
    });
  });

  // ============================================================
  // TaskExecutor + 真实 LLM 测试（需要环境变量）
  // ============================================================
  group('TaskExecutor (LLM)', () {
    late String apiKey;
    late String apiUrl;
    late String apiModel;
    late ProviderConfig providerConfig;

    setUpAll(() {
      apiKey = Platform.environment['OPENAI_API_KEY'] ?? '';
      apiUrl =
          Platform.environment['OPENAI_API_URL'] ?? 'https://api.openai.com/v1';
      apiModel =
          Platform.environment['OPENAI_API_MODEL'] ?? 'gpt-3.5-turbo';

      if (apiKey.isEmpty) {
        throw Exception('请设置环境变量 OPENAI_API_KEY');
      }

      print('=== TaskExecutor 测试配置 ===');
      print('API URL: $apiUrl');
      print('API Model: $apiModel');

      providerConfig = ProviderConfig(
        provider: LLMProvider.openai,
        apiKey: apiKey,
        baseUrl: apiUrl,
        model: apiModel,
      );
    });

    test('临时 Adapter 完成一次 LLM 调用（不写 Hive）', () async {
      print('\n=== 测试：临时 Adapter 执行任务 ===');

      final adapter = LangChainChatAdapter();
      await adapter.initSession(
        employeeId: '__test_${DateTime.now().millisecondsSinceEpoch}',
      );
      await adapter.updateProvider(providerConfig.toMap());

      // 注册只读工具，不设权限管理器
      final registry = ToolRegistry();
      registry.registerTools(BuiltinTools.readOnly());
      adapter.setToolRegistry(registry);
      adapter.setPermissionManager(null);

      final buffer = StringBuffer();
      await for (final response in adapter.streamMessage({
        'content': '请用一句话回答：1+1等于几？',
        'id': const Uuid().v4(),
      })) {
        if (response.error != null) {
          fail('LLM 调用失败: ${response.error}');
        }
        if (response.content != null) {
          buffer.write(response.content);
        }
        if (response.isDone) break;
      }

      final output = buffer.toString();
      print('LLM 回复: $output');
      expect(output, isNotEmpty);

      await adapter.dispose();
      print('✅ 临时 Adapter 测试通过');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('TaskExecutor 执行简单任务', () async {
      print('\n=== 测试：TaskExecutor 执行简单任务 ===');

      final executor = TaskExecutor();
      executor.getAgentConfig = (employeeId) async {
        return {
          'providerConfig': providerConfig.toMap(),
          'systemPrompt': '你是一个测试助手，请简洁回答。',
        };
      };

      // 记录送达结果
      String? deliveredContent;
      executor.deliverResult = (employeeId, content) async {
        deliveredContent = content;
        print('送达结果 → $employeeId: ${content.substring(0, content.length.clamp(0, 100))}');
      };

      final result = await executor.execute(
        employeeId: 'test-emp-1',
        taskPrompt: '请用一句话回答：今天是星期几？（回答"今天星期X"即可）',
        timeout: const Duration(seconds: 60),
      );

      print('执行结果: success=${result.success}, duration=${result.duration.inSeconds}s');
      print('输出: ${result.output?.substring(0, (result.output?.length ?? 0).clamp(0, 100))}');

      expect(result.success, isTrue);
      expect(result.output, isNotEmpty);
      expect(deliveredContent, isNotNull);
      expect(deliveredContent!, contains('定时任务执行结果'));

      print('✅ TaskExecutor 测试通过');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('TaskExecutor 执行带工具的任务（file_read）', () async {
      print('\n=== 测试：TaskExecutor 执行带工具的任务 ===');

      // 用项目中的 pubspec.yaml 作为测试文件（确定存在）
      final testFilePath = 'd:\\project\\GitHub\\wenzagent\\pubspec.yaml';

      final executor = TaskExecutor();
      executor.getAgentConfig = (employeeId) async {
        return {
          'providerConfig': providerConfig.toMap(),
          'systemPrompt': '你是一个工作汇报助手。请按照用户指示使用工具完成任务。',
          'tools': BuiltinTools.readOnly(), // 只读工具
        };
      };

      final result = await executor.execute(
        employeeId: 'test-emp-2',
        taskPrompt: '请使用 file_read 工具读取文件 $testFilePath，'
            '然后告诉我这个项目的名称（name 字段）是什么。',
        timeout: const Duration(minutes: 2),
      );

      print('执行结果: success=${result.success}, duration=${result.duration.inSeconds}s');
      if (result.output != null) {
        print('输出（前200字）: ${result.output!.substring(0, result.output!.length.clamp(0, 200))}');
      }

      expect(result.success, isTrue);
      // LLM 应该调用了 file_read 并获得了文件内容，能识别出项目名
      expect(result.output, contains('wenzagent'));

      print('✅ TaskExecutor 工具调用测试通过');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ============================================================
  // 端到端：ScheduleTaskTool + Manager + Executor + LLM
  // ============================================================
  group('端到端：定时任务完整流程', () {
    late String apiKey;
    late String apiUrl;
    late String apiModel;
    late ProviderConfig providerConfig;
    late ScheduledTaskManager manager;

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

      await HiveManager.instance.initialize(
        storagePath: '${Directory.systemTemp.path}/wenzagent_e2e_hive',
      );
    });

    tearDownAll(() async {
      await HiveManager.instance.close();
    });

    setUp(() async {
      manager = ScheduledTaskManagerImpl();
    });

    tearDown(() async {
      if (manager.isRunning) await manager.stop();
      (manager as ScheduledTaskManagerImpl).dispose();
    });

    test('通过 ScheduleTaskTool 创建任务 → Manager 存储 → triggerTaskNow 执行',
        () async {
      print('\n=== 端到端测试：创建 → 存储 → 触发执行 ===');

      // 1. 配置 TaskExecutor
      final impl = manager as ScheduledTaskManagerImpl;
      impl.executor.getAgentConfig = (employeeId) async {
        return {
          'providerConfig': providerConfig.toMap(),
          'systemPrompt': '你是一个工作助手，请简洁回答。',
        };
      };

      final deliveredResults = <String, String>{};
      impl.taskExecutor.deliverResult = (employeeId, content) async {
        deliveredResults[employeeId] = content;
        print('送达 → $employeeId: ${content.substring(0, content.length.clamp(0, 100))}');
      };

      // 2. 模拟 ScheduleTaskTool 创建任务
      final tool = ScheduleTaskTool();
      final employeeId = 'e2e-emp-${DateTime.now().millisecondsSinceEpoch}';

      tool.onCreateTask = (data) async {
        final task = AiScheduledTaskEntity(
          uuid: const Uuid().v4(),
          employeeId: employeeId,
          name: data['name'] as String,
          scheduleType: CronExpression.isValid(data['schedule'] as String)
              ? ScheduleType.cron
              : ScheduleType.interval,
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
        return {
          'taskId': created.uuid,
          'name': created.name,
          'schedule': created.scheduleExpression,
          'nextExecutionAt':
              created.nextExecutionAt?.toIso8601String() ?? 'calculating...',
        };
      };

      // 3. 调用工具的 create action
      final toolResult = await tool.execute({
        'action': 'create',
        'name': '测试定时汇报',
        'schedule': '0 9 * * *',
        'message': '请回答：今天是几月几号？一句话即可。',
      });

      print('工具返回: ${toolResult.content}');
      expect(toolResult.isError, isFalse);
      expect(toolResult.content, contains('Task ID:'));

      // 提取 taskId
      final taskIdLine =
          toolResult.content.split('\n').firstWhere((l) => l.contains('Task ID:'));
      final taskId = taskIdLine.split('Task ID:').last.trim();
      print('创建的任务 ID: $taskId');

      // 4. 验证任务已存储
      final stored = await manager.getTask(taskId);
      expect(stored, isNotNull);
      expect(stored!.name, '测试定时汇报');
      expect(stored.nextExecutionAt, isNotNull);

      // 5. 手动触发执行
      print('手动触发任务...');
      await manager.triggerTaskNow(taskId);

      // 6. 验证执行结果
      await Future.delayed(const Duration(seconds: 5));
      // triggerTaskNow 内部会调用 _executeViaWorker → executor.execute
      // 结果通过 deliverResult 送出

      if (deliveredResults.containsKey(employeeId)) {
        print('收到送达结果: ${deliveredResults[employeeId]!.substring(0, 100)}');
      }

      final executed = await manager.getTask(taskId);
      print(
          '执行后状态: lastResult=${executed?.lastExecutionResult}, failures=${executed?.consecutiveFailures}');
      expect(executed?.lastExecutionResult, isNotNull);

      print('✅ 端到端测试通过');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ============================================================
  // BuiltinTools 注册验证
  // ============================================================
  group('BuiltinTools 包含 ScheduleTaskTool', () {
    test('all() 包含 schedule_task', () {
      final tools = BuiltinTools.all();
      final names = tools.map((t) => t.name).toList();
      expect(names, contains('schedule_task'));
      // 现在应该是 10 个工具
      expect(tools.length, 10);
    });

    test('schedule_task 工具可正确生成 ToolSpec', () {
      final tools = BuiltinTools.all();
      final scheduleTool = tools.firstWhere((t) => t.name == 'schedule_task');
      final spec = scheduleTool.toToolSpec();
      expect(spec.name, 'schedule_task');
      expect(spec.description, isNotEmpty);
      expect(spec.inputJsonSchema['properties'], isA<Map>());
      expect(spec.inputJsonSchema['properties'], contains('action'));
      expect(spec.inputJsonSchema['properties'], contains('message'));
      expect(spec.inputJsonSchema['properties'], contains('schedule'));
    });
  });
}
