import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';
import 'package:wenzagent/src/service/project_manager.dart';

int _testCounter = 0;

/// ProjectManager CRUD 测试
///
/// 使用真实 SQLite 数据库，覆盖 ProjectManager 的项目和技能增删改查，
/// 以及变更通知事件。
void main() {
  late String testDbPath;
  late String deviceId;
  late ProjectManager manager;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_project_manager_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    manager = ProjectManager.getInstance(deviceId);
  });

  tearDown(() async {
    (manager as ProjectManagerImpl).dispose();
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
    ProjectManager.removeInstance(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════
  // 辅助方法
  // ═══════════════════════════════════════════════════

  ProjectEntity createProject({
    String? uuid,
    String title = '测试项目',
    String? description,
    String? workPath,
    String? gitUrl,
  }) {
    final now = DateTime.now();
    return ProjectEntity(
      uuid: uuid ?? const Uuid().v4(),
      title: title,
      description: description,
      workPath: workPath,
      gitUrl: gitUrl,
      createTime: now,
      updateTime: now,
    );
  }

  ProjectSkillEntity createSkill({
    String? uuid,
    required String projectUuid,
    String title = '测试技能',
    String? description,
    String skillType = 'mcp',
    String? mcpConfig,
    int sortOrder = 0,
  }) {
    final now = DateTime.now();
    return ProjectSkillEntity(
      uuid: uuid ?? const Uuid().v4(),
      projectUuid: projectUuid,
      title: title,
      description: description,
      skillType: skillType,
      mcpConfig: mcpConfig,
      sortOrder: sortOrder,
      createTime: now,
      updateTime: now,
    );
  }

  // ═══════════════════════════════════════════════════
  // 一、项目 CRUD
  // ═══════════════════════════════════════════════════

  group('项目 CRUD', () {
    // ---------- 1. createProject ----------

    test('createProject 创建项目并返回带时间戳的实体', () async {
      final project = createProject(title: '新项目');

      final created = await manager.createProject(project);

      expect(created.uuid, equals(project.uuid));
      expect(created.title, equals('新项目'));
      expect(created.createTime, isNotNull);
      expect(created.updateTime, isNotNull);

      // 验证 getProject 能查到
      final found = await manager.getProject(project.uuid);
      expect(found, isNotNull);
      expect(found!.title, equals('新项目'));
    });

    test('createProject 后 getProject 能查到', () async {
      final project = createProject(
        title: '可查询项目',
        description: '项目描述',
        workPath: '/work/path',
      );
      await manager.createProject(project);

      final found = await manager.getProject(project.uuid);
      expect(found, isNotNull);
      expect(found!.title, equals('可查询项目'));
      expect(found.description, equals('项目描述'));
      expect(found.workPath, equals('/work/path'));
    });

    // ---------- 2. getAllProjects ----------

    test('getAllProjects 返回所有项目', () async {
      await manager.createProject(createProject(title: '项目A'));
      await manager.createProject(createProject(title: '项目B'));
      await manager.createProject(createProject(title: '项目C'));

      final all = await manager.getAllProjects();
      expect(all.length, equals(3));
    });

    test('getAllProjects 空数据库返回空列表', () async {
      final all = await manager.getAllProjects();
      expect(all, isEmpty);
    });

    // ---------- 3. searchProjects ----------

    test('searchProjects 按关键词搜索', () async {
      await manager.createProject(createProject(title: 'Flutter项目'));
      await manager.createProject(createProject(title: 'Dart服务'));

      final results = await manager.searchProjects('Flutter');
      expect(results.length, equals(1));
      expect(results.first.title, equals('Flutter项目'));
    });

    // ---------- 4. updateProject ----------

    test('updateProject 更新项目标题和描述', () async {
      final project = createProject(title: '原始标题');
      final created = await manager.createProject(project);

      final updated = created.copyWith(
        title: '更新标题',
        description: '新增描述',
      );
      await manager.updateProject(updated);

      final found = await manager.getProject(project.uuid);
      expect(found, isNotNull);
      expect(found!.title, equals('更新标题'));
      expect(found.description, equals('新增描述'));

      // updateTime 应被 manager 自动刷新
      expect(found.updateTime.isAfter(created.updateTime), isTrue);
    });

    // ---------- 5. deleteProject ----------

    test('deleteProject 软删除后 getProject 返回 null', () async {
      final project = createProject(title: '待删除');
      await manager.createProject(project);

      await manager.deleteProject(project.uuid);

      final found = await manager.getProject(project.uuid);
      expect(found, isNull);
    });

    test('deleteProject 后 getAllProjects 不包含', () async {
      final p1 = createProject(title: '保留');
      final p2 = createProject(title: '删除');
      await manager.createProject(p1);
      await manager.createProject(p2);

      await manager.deleteProject(p2.uuid);

      final all = await manager.getAllProjects();
      expect(all.length, equals(1));
      expect(all.first.title, equals('保留'));
    });

    // ---------- 6. saveProject（同步场景）----------

    test('saveProject 新项目可直接保存', () async {
      final project = createProject(title: '同步保存');

      await manager.saveProject(project);

      final found = await manager.getProject(project.uuid);
      expect(found, isNotNull);
      expect(found!.title, equals('同步保存'));
    });

    test('saveProject 已有项目可覆盖更新', () async {
      final project = createProject(title: '原始');
      await manager.createProject(project);

      final updated = project.copyWith(title: '修改');
      await manager.saveProject(updated);

      final found = await manager.getProject(project.uuid);
      expect(found, isNotNull);
      expect(found!.title, equals('修改'));
    });
  });

  // ═══════════════════════════════════════════════════
  // 二、项目技能 CRUD
  // ═══════════════════════════════════════════════════

  group('项目技能 CRUD', () {
    late String projectUuid;

    setUp(() async {
      final project = createProject(title: '技能测试项目');
      final created = await manager.createProject(project);
      projectUuid = created.uuid;
    });

    // ---------- 1. createSkill ----------

    test('createSkill 创建技能并返回带时间戳的实体', () async {
      final skill = createSkill(
        projectUuid: projectUuid,
        title: '新技能',
        skillType: 'mcp',
      );

      final created = await manager.createSkill(skill);

      expect(created.uuid, equals(skill.uuid));
      expect(created.title, equals('新技能'));
      expect(created.projectUuid, equals(projectUuid));
      expect(created.createTime, isNotNull);
      expect(created.updateTime, isNotNull);
    });

    test('createSkill 后 getSkills 能查到', () async {
      await manager.createSkill(createSkill(
        projectUuid: projectUuid,
        title: 'MCP技能',
        mcpConfig: '{"server":"test"}',
      ));

      final skills = await manager.getSkills(projectUuid);
      expect(skills.length, equals(1));
      expect(skills.first.title, equals('MCP技能'));
      expect(skills.first.mcpConfig, equals('{"server":"test"}'));
    });

    // ---------- 2. getSkills ----------

    test('getSkills 返回指定项目的所有技能', () async {
      await manager.createSkill(createSkill(
        projectUuid: projectUuid,
        title: '技能A',
      ));
      await manager.createSkill(createSkill(
        projectUuid: projectUuid,
        title: '技能B',
      ));

      final skills = await manager.getSkills(projectUuid);
      expect(skills.length, equals(2));
    });

    test('getSkills 不同项目互不干扰', () async {
      final project2 = createProject(title: '项目2');
      await manager.createProject(project2);

      await manager.createSkill(createSkill(
        projectUuid: projectUuid,
        title: '项目1技能',
      ));
      await manager.createSkill(createSkill(
        projectUuid: project2.uuid,
        title: '项目2技能',
      ));

      final skills1 = await manager.getSkills(projectUuid);
      expect(skills1.length, equals(1));
      expect(skills1.first.title, equals('项目1技能'));

      final skills2 = await manager.getSkills(project2.uuid);
      expect(skills2.length, equals(1));
      expect(skills2.first.title, equals('项目2技能'));
    });

    // ---------- 3. updateSkill ----------

    test('updateSkill 更新技能标题和描述', () async {
      final skill = createSkill(
        projectUuid: projectUuid,
        title: '原始技能',
      );
      final created = await manager.createSkill(skill);

      final updated = created.copyWith(
        title: '更新技能',
        description: '新增描述',
      );
      await manager.updateSkill(updated);

      final skills = await manager.getSkills(projectUuid);
      expect(skills.length, equals(1));
      expect(skills.first.title, equals('更新技能'));
      expect(skills.first.description, equals('新增描述'));

      // updateTime 应被 manager 自动刷新
      expect(
        skills.first.updateTime.isAfter(created.updateTime),
        isTrue,
      );
    });

    test('updateSkill 技能类型变更', () async {
      final skill = createSkill(
        projectUuid: projectUuid,
        title: '类型测试',
        skillType: 'mcp',
      );
      final created = await manager.createSkill(skill);

      await manager.updateSkill(created.copyWith(skillType: 'note'));

      final skills = await manager.getSkills(projectUuid);
      expect(skills.first.skillType, equals('note'));
    });

    // ---------- 4. deleteSkill ----------

    test('deleteSkill 软删除后 getSkills 不返回', () async {
      final skill = createSkill(
        projectUuid: projectUuid,
        title: '待删除技能',
      );
      await manager.createSkill(skill);

      // 确认存在
      var skills = await manager.getSkills(projectUuid);
      expect(skills.length, equals(1));

      // 执行删除
      await manager.deleteSkill(skill.uuid);

      // getSkills 不返回已删除
      skills = await manager.getSkills(projectUuid);
      expect(skills, isEmpty);
    });

    test('deleteSkill 不影响其他技能', () async {
      final s1 = createSkill(
        projectUuid: projectUuid,
        title: '保留技能',
      );
      final s2 = createSkill(
        projectUuid: projectUuid,
        title: '删除技能',
      );
      await manager.createSkill(s1);
      await manager.createSkill(s2);

      await manager.deleteSkill(s2.uuid);

      final skills = await manager.getSkills(projectUuid);
      expect(skills.length, equals(1));
      expect(skills.first.title, equals('保留技能'));
    });

    // ---------- 5. saveSkill（同步场景）----------

    test('saveSkill 直接保存技能', () async {
      final skill = createSkill(
        projectUuid: projectUuid,
        title: '直接保存',
      );
      await manager.saveSkill(skill);

      final skills = await manager.getSkills(projectUuid);
      expect(skills.length, equals(1));
      expect(skills.first.title, equals('直接保存'));
    });

    test('saveSkill 相同 uuid 覆盖更新', () async {
      final skill = createSkill(
        projectUuid: projectUuid,
        title: '原始',
      );
      await manager.saveSkill(skill);

      final updated = skill.copyWith(title: '覆盖');
      await manager.saveSkill(updated);

      final skills = await manager.getSkills(projectUuid);
      expect(skills.length, equals(1));
      expect(skills.first.title, equals('覆盖'));
    });
  });

  // ═══════════════════════════════════════════════════
  // 三、变更通知事件
  // ═══════════════════════════════════════════════════

  group('变更通知事件', () {
    test('createProject 触发 created 事件', () async {
      final events = <ProjectChangeEvent>[];
      manager.onProjectChanged.listen(events.add);

      final project = createProject(title: '事件测试');
      await manager.createProject(project);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events.length, equals(1));
      expect(events.first.type, equals(ProjectChangeType.created));
      expect(events.first.projectUuid, equals(project.uuid));
      expect(events.first.project, isNotNull);
      expect(events.first.project!.title, equals('事件测试'));
    });

    test('updateProject 触发 updated 事件', () async {
      final project = createProject(title: '更新事件');
      final created = await manager.createProject(project);

      final events = <ProjectChangeEvent>[];
      manager.onProjectChanged.listen(events.add);

      await manager.updateProject(created.copyWith(title: '已更新'));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events.length, equals(1));
      expect(events.first.type, equals(ProjectChangeType.updated));
    });

    test('deleteProject 触发 deleted 事件', () async {
      final project = createProject(title: '删除事件');
      await manager.createProject(project);

      final events = <ProjectChangeEvent>[];
      manager.onProjectChanged.listen(events.add);

      await manager.deleteProject(project.uuid);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events.length, equals(1));
      expect(events.first.type, equals(ProjectChangeType.deleted));
      // deleted 事件不携带 project 实体
      expect(events.first.project, isNull);
    });

    test('连续操作触发多个事件', () async {
      final events = <ProjectChangeEvent>[];
      manager.onProjectChanged.listen(events.add);

      final p1 = createProject(title: 'A');
      final p2 = createProject(title: 'B');
      await manager.createProject(p1);
      await manager.createProject(p2);
      await manager.deleteProject(p1.uuid);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events.length, equals(3));
      expect(events[0].type, equals(ProjectChangeType.created));
      expect(events[1].type, equals(ProjectChangeType.created));
      expect(events[2].type, equals(ProjectChangeType.deleted));
    });
  });

  // ═══════════════════════════════════════════════════
  // 四、完整 CRUD 流程
  // ═══════════════════════════════════════════════════

  group('完整 CRUD 流程', () {
    test('项目完整增删改查流程', () async {
      // 1. 创建
      final project = createProject(
        title: '完整测试项目',
        description: '初始描述',
        workPath: '/initial/path',
      );
      final created = await manager.createProject(project);
      expect(created.title, equals('完整测试项目'));

      // 2. 查询
      var found = await manager.getProject(project.uuid);
      expect(found, isNotNull);
      expect(found!.title, equals('完整测试项目'));

      // 3. 更新
      await manager.updateProject(created.copyWith(
        title: '更新后项目',
        description: '更新描述',
        workPath: '/updated/path',
      ));
      found = await manager.getProject(project.uuid);
      expect(found!.title, equals('更新后项目'));
      expect(found.description, equals('更新描述'));
      expect(found.workPath, equals('/updated/path'));

      // 4. 列表
      var all = await manager.getAllProjects();
      expect(all.length, equals(1));

      // 5. 删除
      await manager.deleteProject(project.uuid);
      found = await manager.getProject(project.uuid);
      expect(found, isNull);
      all = await manager.getAllProjects();
      expect(all, isEmpty);
    });

    test('技能完整增删改查流程', () async {
      // 先创建项目
      final project = createProject(title: '技能流程项目');
      await manager.createProject(project);

      // 1. 创建技能
      final skill = createSkill(
        projectUuid: project.uuid,
        title: '完整测试技能',
        skillType: 'mcp',
        mcpConfig: '{"server":"initial"}',
      );
      final createdSkill = await manager.createSkill(skill);
      expect(createdSkill.title, equals('完整测试技能'));

      // 2. 查询技能
      var skills = await manager.getSkills(project.uuid);
      expect(skills.length, equals(1));
      expect(skills.first.title, equals('完整测试技能'));

      // 3. 更新技能
      await manager.updateSkill(createdSkill.copyWith(
        title: '更新后技能',
        mcpConfig: '{"server":"updated"}',
      ));
      skills = await manager.getSkills(project.uuid);
      expect(skills.length, equals(1));
      expect(skills.first.title, equals('更新后技能'));
      expect(skills.first.mcpConfig, equals('{"server":"updated"}'));

      // 4. 删除技能
      await manager.deleteSkill(skill.uuid);
      skills = await manager.getSkills(project.uuid);
      expect(skills, isEmpty);
    });

    test('项目下多技能管理', () async {
      final project = createProject(title: '多技能项目');
      await manager.createProject(project);

      // 创建多个技能
      await manager.createSkill(createSkill(
        projectUuid: project.uuid,
        title: '技能A',
        skillType: 'mcp',
        sortOrder: 1,
      ));
      await manager.createSkill(createSkill(
        projectUuid: project.uuid,
        title: '技能B',
        skillType: 'note',
        sortOrder: 2,
      ));
      await manager.createSkill(createSkill(
        projectUuid: project.uuid,
        title: '技能C',
        skillType: 'file',
        sortOrder: 3,
      ));

      var skills = await manager.getSkills(project.uuid);
      expect(skills.length, equals(3));

      // 删除中间一个
      await manager.deleteSkill(skills[1].uuid);

      skills = await manager.getSkills(project.uuid);
      expect(skills.length, equals(2));
      expect(skills[0].title, equals('技能A'));
      expect(skills[1].title, equals('技能C'));

      // 删除项目后技能仍在（软删除项目不影响技能查询）
      await manager.deleteProject(project.uuid);
      // 项目已删除，但技能表数据仍在
      // getSkills 只按 projectUuid 查，不检查项目是否删除
      skills = await manager.getSkills(project.uuid);
      // 技能记录仍在（取决于实现是否级联）
      expect(skills.length, equals(2));
    });
  });
}
