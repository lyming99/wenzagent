import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/persistence.dart';

int _testCounter = 0;

/// ProjectStore CRUD 测试
///
/// 使用真实 SQLite 数据库，覆盖项目和项目技能的所有公共 API。
void main() {
  late String testDbPath;
  late String deviceId;
  late ProjectStore store;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_project_store_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    await DatabaseManager.getInstance(deviceId).initialize(
      storagePath: testDbPath,
    );

    store = ProjectStore(deviceId: deviceId);
  });

  tearDown(() async {
    await DatabaseManager.getInstance(deviceId).close();
    DatabaseManager.removeInstance(deviceId);
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
    int deleted = 0,
    String? createBy,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return ProjectEntity(
      uuid: uuid ?? const Uuid().v4(),
      title: title,
      description: description,
      workPath: workPath,
      gitUrl: gitUrl,
      deleted: deleted,
      createBy: createBy,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  ProjectSkillEntity createProjectSkill({
    String? uuid,
    required String projectUuid,
    String title = '测试技能',
    String? description,
    String skillType = 'mcp',
    String? mcpConfig,
    String? fileConfig,
    int sortOrder = 0,
    int deleted = 0,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    final now = DateTime.now();
    return ProjectSkillEntity(
      uuid: uuid ?? const Uuid().v4(),
      projectUuid: projectUuid,
      title: title,
      description: description,
      skillType: skillType,
      mcpConfig: mcpConfig,
      fileConfig: fileConfig,
      sortOrder: sortOrder,
      deleted: deleted,
      createTime: createTime ?? now,
      updateTime: updateTime ?? now,
    );
  }

  // ═══════════════════════════════════════════════════
  // 一、项目 CRUD
  // ═══════════════════════════════════════════════════

  group('项目 CRUD', () {
    // ---------- 1. saveProject + findProject ----------

    test('saveProject 后 findProject 能查到', () async {
      final project = createProject(title: '我的项目');
      await store.saveProject(project);

      final found = await store.findProject(project.uuid);
      expect(found, isNotNull);
      expect(found!.uuid, equals(project.uuid));
      expect(found.title, equals('我的项目'));
    });

    test('findProject 不存在的 uuid 返回 null', () async {
      final found = await store.findProject('non-existent-uuid');
      expect(found, isNull);
    });

    // ---------- 2. findAllProjects ----------

    test('findAllProjects 返回所有未删除项目', () async {
      await store.saveProject(createProject(title: '项目A'));
      await store.saveProject(createProject(title: '项目B'));
      await store.saveProject(createProject(title: '项目C'));

      final all = await store.findAllProjects();
      expect(all.length, equals(3));
    });

    test('findAllProjects 不包含已删除项目', () async {
      final p1 = createProject(title: '正常项目');
      final p2 = createProject(title: '已删除项目', deleted: 1);
      await store.saveProject(p1);
      await store.saveProject(p2);

      final all = await store.findAllProjects();
      expect(all.length, equals(1));
      expect(all.first.title, equals('正常项目'));
    });

    // ---------- 3. searchProjects ----------

    test('searchProjects 按标题关键词搜索', () async {
      await store.saveProject(createProject(title: 'Flutter应用'));
      await store.saveProject(createProject(title: 'Dart服务'));
      await store.saveProject(createProject(title: 'Web前端'));

      final results = await store.searchProjects('Flutter');
      expect(results.length, equals(1));
      expect(results.first.title, equals('Flutter应用'));
    });

    test('searchProjects 按描述关键词搜索', () async {
      await store.saveProject(
        createProject(title: '项目A', description: '这是一个Flutter项目'),
      );
      await store.saveProject(
        createProject(title: '项目B', description: '这是一个Dart项目'),
      );

      final results = await store.searchProjects('Dart');
      expect(results.length, equals(1));
      expect(results.first.title, equals('项目B'));
    });

    test('searchProjects 空关键词返回所有', () async {
      await store.saveProject(createProject(title: 'A'));
      await store.saveProject(createProject(title: 'B'));

      final results = await store.searchProjects('');
      expect(results.length, equals(2));
    });

    // ---------- 4. saveProject 更新（INSERT OR REPLACE）----------

    test('saveProject 相同 uuid 覆盖更新', () async {
      final uuid = const Uuid().v4();
      final project = createProject(uuid: uuid, title: '原始标题');
      await store.saveProject(project);

      final updated = project.copyWith(
        title: '更新标题',
        description: '新增描述',
      );
      await store.saveProject(updated);

      final found = await store.findProject(uuid);
      expect(found, isNotNull);
      expect(found!.title, equals('更新标题'));
      expect(found.description, equals('新增描述'));
    });

    // ---------- 5. deleteProject 软删除 ----------

    test('deleteProject 软删除后 findProject 返回 null', () async {
      final project = createProject(title: '待删除项目');
      await store.saveProject(project);

      // 确认存在
      expect(await store.findProject(project.uuid), isNotNull);

      // 执行软删除
      await store.deleteProject(project.uuid);

      // findProject 不返回已删除项目
      expect(await store.findProject(project.uuid), isNull);
    });

    test('deleteProject 后 findAllProjects 不包含', () async {
      final p1 = createProject(title: '保留');
      final p2 = createProject(title: '删除');
      await store.saveProject(p1);
      await store.saveProject(p2);

      await store.deleteProject(p2.uuid);

      final all = await store.findAllProjects();
      expect(all.length, equals(1));
      expect(all.first.title, equals('保留'));
    });

    test('deleteProject 后 findProjectIncludingDeleted 仍能查到', () async {
      final project = createProject(title: '软删除测试');
      await store.saveProject(project);

      await store.deleteProject(project.uuid);

      final found =
          await store.findProjectIncludingDeleted(project.uuid);
      expect(found, isNotNull);
      expect(found!.deleted, equals(1));
    });

    // ---------- 6. 完整字段验证 ----------

    test('saveProject 所有字段正确持久化', () async {
      final now = DateTime(2024, 6, 15, 12, 0, 0);
      final project = ProjectEntity(
        uuid: 'proj-full-fields',
        userId: 100,
        spaceId: 'space-001',
        title: '完整字段项目',
        description: '项目描述',
        workPath: '/home/user/project',
        gitUrl: 'https://github.com/test/repo.git',
        deleted: 0,
        createBy: 'user-a',
        createTime: now,
        updateBy: 'user-b',
        updateTime: now,
      );

      await store.saveProject(project);

      final found = await store.findProject('proj-full-fields');
      expect(found, isNotNull);
      expect(found!.uuid, equals('proj-full-fields'));
      expect(found.userId, equals(100));
      expect(found.spaceId, equals('space-001'));
      expect(found.title, equals('完整字段项目'));
      expect(found.description, equals('项目描述'));
      expect(found.workPath, equals('/home/user/project'));
      expect(found.gitUrl, equals('https://github.com/test/repo.git'));
      expect(found.deleted, equals(0));
      expect(found.createBy, equals('user-a'));
      expect(found.updateBy, equals('user-b'));
    });
  });

  // ═══════════════════════════════════════════════════
  // 二、项目技能 CRUD
  // ═══════════════════════════════════════════════════

  group('项目技能 CRUD', () {
    late String projectUuid;

    setUp(() async {
      // 创建一个项目供技能关联
      final project = createProject(title: '技能测试项目');
      projectUuid = project.uuid;
      await store.saveProject(project);
    });

    // ---------- 1. saveSkill + findSkills ----------

    test('saveSkill 后 findSkills 能查到', () async {
      final skill = createProjectSkill(
        projectUuid: projectUuid,
        title: 'MCP技能',
        skillType: 'mcp',
      );
      await store.saveSkill(skill);

      final skills = await store.findSkills(projectUuid);
      expect(skills.length, equals(1));
      expect(skills.first.uuid, equals(skill.uuid));
      expect(skills.first.title, equals('MCP技能'));
      expect(skills.first.skillType, equals('mcp'));
    });

    test('findSkills 只返回指定项目的技能', () async {
      // 第二个项目
      final project2 = createProject(title: '项目2');
      await store.saveProject(project2);

      await store.saveSkill(createProjectSkill(
        projectUuid: projectUuid,
        title: '项目1技能',
      ));
      await store.saveSkill(createProjectSkill(
        projectUuid: project2.uuid,
        title: '项目2技能',
      ));

      final skills1 = await store.findSkills(projectUuid);
      expect(skills1.length, equals(1));
      expect(skills1.first.title, equals('项目1技能'));

      final skills2 = await store.findSkills(project2.uuid);
      expect(skills2.length, equals(1));
      expect(skills2.first.title, equals('项目2技能'));
    });

    test('findSkills 不返回已删除技能', () async {
      await store.saveSkill(createProjectSkill(
        projectUuid: projectUuid,
        title: '正常技能',
      ));
      await store.saveSkill(createProjectSkill(
        projectUuid: projectUuid,
        title: '已删除技能',
        deleted: 1,
      ));

      final skills = await store.findSkills(projectUuid);
      expect(skills.length, equals(1));
      expect(skills.first.title, equals('正常技能'));
    });

    test('findSkills 按 sortOrder 排序', () async {
      await store.saveSkill(createProjectSkill(
        projectUuid: projectUuid,
        title: '技能C',
        sortOrder: 3,
      ));
      await store.saveSkill(createProjectSkill(
        projectUuid: projectUuid,
        title: '技能A',
        sortOrder: 1,
      ));
      await store.saveSkill(createProjectSkill(
        projectUuid: projectUuid,
        title: '技能B',
        sortOrder: 2,
      ));

      final skills = await store.findSkills(projectUuid);
      expect(skills[0].title, equals('技能A'));
      expect(skills[1].title, equals('技能B'));
      expect(skills[2].title, equals('技能C'));
    });

    // ---------- 2. saveSkill 更新（INSERT OR REPLACE）----------

    test('saveSkill 相同 uuid 覆盖更新', () async {
      final uuid = const Uuid().v4();
      final skill = createProjectSkill(
        uuid: uuid,
        projectUuid: projectUuid,
        title: '原始技能',
      );
      await store.saveSkill(skill);

      final updated = skill.copyWith(
        title: '更新技能',
        description: '新增描述',
      );
      await store.saveSkill(updated);

      final skills = await store.findSkills(projectUuid);
      expect(skills.length, equals(1));
      expect(skills.first.title, equals('更新技能'));
      expect(skills.first.description, equals('新增描述'));
    });

    // ---------- 3. deleteSkill 软删除 ----------

    test('deleteSkill 软删除后 findSkills 不返回', () async {
      final skill = createProjectSkill(
        projectUuid: projectUuid,
        title: '待删除技能',
      );
      await store.saveSkill(skill);

      // 确认存在
      var skills = await store.findSkills(projectUuid);
      expect(skills.length, equals(1));

      // 执行软删除
      await store.deleteSkill(skill.uuid);

      // findSkills 不返回已删除
      skills = await store.findSkills(projectUuid);
      expect(skills, isEmpty);
    });

    test('deleteSkill 不影响其他技能', () async {
      final s1 = createProjectSkill(
        projectUuid: projectUuid,
        title: '保留技能',
      );
      final s2 = createProjectSkill(
        projectUuid: projectUuid,
        title: '删除技能',
      );
      await store.saveSkill(s1);
      await store.saveSkill(s2);

      await store.deleteSkill(s2.uuid);

      final skills = await store.findSkills(projectUuid);
      expect(skills.length, equals(1));
      expect(skills.first.title, equals('保留技能'));
    });

    // ---------- 4. 完整字段验证 ----------

    test('saveSkill 所有字段正确持久化', () async {
      final now = DateTime(2024, 6, 15, 12, 0, 0);
      final skill = ProjectSkillEntity(
        uuid: 'skill-full-fields',
        projectUuid: projectUuid,
        title: '完整技能',
        description: '技能描述',
        skillType: 'note',
        noteUuid: 'note-001',
        documentUuid: 'doc-001',
        mcpConfig: '{"server":"test"}',
        fileConfig: '{"path":"/tmp"}',
        sortOrder: 5,
        deleted: 0,
        createBy: 'user-a',
        createTime: now,
        updateBy: 'user-b',
        updateTime: now,
      );

      await store.saveSkill(skill);

      final skills = await store.findSkills(projectUuid);
      expect(skills.length, equals(1));
      final found = skills.first;
      expect(found.uuid, equals('skill-full-fields'));
      expect(found.projectUuid, equals(projectUuid));
      expect(found.title, equals('完整技能'));
      expect(found.description, equals('技能描述'));
      expect(found.skillType, equals('note'));
      expect(found.noteUuid, equals('note-001'));
      expect(found.documentUuid, equals('doc-001'));
      expect(found.mcpConfig, equals('{"server":"test"}'));
      expect(found.fileConfig, equals('{"path":"/tmp"}'));
      expect(found.sortOrder, equals(5));
      expect(found.deleted, equals(0));
      expect(found.createBy, equals('user-a'));
      expect(found.updateBy, equals('user-b'));
    });
  });

  // ═══════════════════════════════════════════════════
  // 三、ProjectEntity 序列化往返
  // ═══════════════════════════════════════════════════

  group('ProjectEntity 序列化往返', () {
    test('toMap/fromMap 所有字段一致', () {
      final now = DateTime(2024, 6, 15, 12, 0, 0);
      final project = ProjectEntity(
        uuid: 'proj-serial-123',
        userId: 42,
        spaceId: 'space-abc',
        title: '序列化测试',
        description: '描述信息',
        workPath: '/work/path',
        gitUrl: 'https://github.com/test.git',
        deleted: 0,
        createBy: 'creator',
        createTime: now,
        updateBy: 'updater',
        updateTime: now,
      );

      final map = project.toMap();
      final restored = ProjectEntity.fromMap(map);

      expect(restored.uuid, equals(project.uuid));
      expect(restored.userId, equals(project.userId));
      expect(restored.spaceId, equals(project.spaceId));
      expect(restored.title, equals(project.title));
      expect(restored.description, equals(project.description));
      expect(restored.workPath, equals(project.workPath));
      expect(restored.gitUrl, equals(project.gitUrl));
      expect(restored.deleted, equals(project.deleted));
      expect(restored.createBy, equals(project.createBy));
      expect(restored.updateBy, equals(project.updateBy));
      expect(
        restored.createTime.millisecondsSinceEpoch,
        equals(project.createTime.millisecondsSinceEpoch),
      );
      expect(
        restored.updateTime.millisecondsSinceEpoch,
        equals(project.updateTime.millisecondsSinceEpoch),
      );
    });

    test('null 字段往返保持 null', () {
      final now = DateTime.now();
      final project = ProjectEntity(
        uuid: 'proj-minimal',
        title: '最小项目',
        createTime: now,
        updateTime: now,
      );

      final map = project.toMap();
      final restored = ProjectEntity.fromMap(map);

      expect(restored.userId, isNull);
      expect(restored.spaceId, isNull);
      expect(restored.description, isNull);
      expect(restored.workPath, isNull);
      expect(restored.gitUrl, isNull);
      expect(restored.deleteBy, isNull);
      expect(restored.deleteTime, isNull);
      expect(restored.createBy, isNull);
      expect(restored.updateBy, isNull);
      expect(restored.deleted, equals(0));
    });

    test('copyWith 修改字段', () {
      final project = createProject(
        title: '原始',
        description: '原始描述',
      );

      final modified = project.copyWith(
        title: '修改标题',
        description: '修改描述',
        workPath: '/new/path',
      );

      expect(modified.title, equals('修改标题'));
      expect(modified.description, equals('修改描述'));
      expect(modified.workPath, equals('/new/path'));
      expect(modified.uuid, equals(project.uuid)); // 未修改
    });

    test('copyWith deleteTime 显式传 null', () {
      final project = createProject();
      final now = DateTime.now();
      final modified = project.copyWith(
        deleteTime: now,
        deleted: 1,
      );
      expect(modified.deleteTime, equals(now));
      expect(modified.deleted, equals(1));
    });
  });

  // ═══════════════════════════════════════════════════
  // 四、ProjectSkillEntity 序列化往返
  // ═══════════════════════════════════════════════════

  group('ProjectSkillEntity 序列化往返', () {
    test('toMap/fromMap 所有字段一致', () {
      final now = DateTime(2024, 6, 15, 12, 0, 0);
      final skill = ProjectSkillEntity(
        uuid: 'skill-serial-123',
        projectUuid: 'proj-001',
        title: '序列化技能',
        description: '技能描述',
        skillType: 'mcp',
        noteUuid: 'note-001',
        documentUuid: 'doc-001',
        mcpConfig: '{"key":"value"}',
        fileConfig: '{"path":"/tmp"}',
        sortOrder: 10,
        deleted: 0,
        createBy: 'creator',
        createTime: now,
        updateBy: 'updater',
        updateTime: now,
      );

      final map = skill.toMap();
      final restored = ProjectSkillEntity.fromMap(map);

      expect(restored.uuid, equals(skill.uuid));
      expect(restored.projectUuid, equals(skill.projectUuid));
      expect(restored.title, equals(skill.title));
      expect(restored.description, equals(skill.description));
      expect(restored.skillType, equals(skill.skillType));
      expect(restored.noteUuid, equals(skill.noteUuid));
      expect(restored.documentUuid, equals(skill.documentUuid));
      expect(restored.mcpConfig, equals(skill.mcpConfig));
      expect(restored.fileConfig, equals(skill.fileConfig));
      expect(restored.sortOrder, equals(skill.sortOrder));
      expect(restored.deleted, equals(skill.deleted));
      expect(restored.createBy, equals(skill.createBy));
      expect(restored.updateBy, equals(skill.updateBy));
    });

    test('null 字段往返保持 null', () {
      final now = DateTime.now();
      final skill = ProjectSkillEntity(
        uuid: 'skill-minimal',
        projectUuid: 'proj-001',
        title: '最小技能',
        createTime: now,
        updateTime: now,
      );

      final map = skill.toMap();
      final restored = ProjectSkillEntity.fromMap(map);

      expect(restored.description, isNull);
      expect(restored.noteUuid, isNull);
      expect(restored.documentUuid, isNull);
      expect(restored.mcpConfig, isNull);
      expect(restored.fileConfig, isNull);
      expect(restored.deleteBy, isNull);
      expect(restored.deleteTime, isNull);
      expect(restored.createBy, isNull);
      expect(restored.updateBy, isNull);
      expect(restored.skillType, equals('mcp')); // 默认值
      expect(restored.sortOrder, equals(0)); // 默认值
      expect(restored.deleted, equals(0)); // 默认值
    });

    test('copyWith 修改字段', () {
      final skill = createProjectSkill(
        projectUuid: 'proj-001',
        title: '原始',
        description: '原始描述',
      );

      final modified = skill.copyWith(
        title: '修改标题',
        description: '修改描述',
        skillType: 'note',
        sortOrder: 5,
      );

      expect(modified.title, equals('修改标题'));
      expect(modified.description, equals('修改描述'));
      expect(modified.skillType, equals('note'));
      expect(modified.sortOrder, equals(5));
      expect(modified.uuid, equals(skill.uuid)); // 未修改
      expect(modified.projectUuid, equals(skill.projectUuid)); // 未修改
    });
  });
}
