/// 项目同步相关功能综合单元测试
///
/// 测试范围：
/// 1. StoreMergeUtil - 软删除合并 + 数据更新判断
/// 2. SyncWatermarkEntity - 水位线实体序列化/反序列化
/// 3. SpecItemEntity - Spec 项实体序列化/反序列化 + copyWith
/// 4. TodoTopicEntity / TodoTaskItemEntity - Todo 实体序列化/反序列化
/// 5. ProjectEntity / ProjectModuleEntity / ProjectSkillEntity / ProjectIssueEntity - 项目实体序列化
/// 6. SessionSummaryEntity - 会话摘要实体序列化
/// 7. RPC 同步请求实体 - GetMinSeqRequest / GetClearSeqRequest / ClearClearSeqRequest / UpdateSyncWatermarkRequest
/// 8. SpecStore upsertFromRemote merge 逻辑
/// 9. TodoStore upsertTopicFromRemote / upsertTaskItemFromRemote merge 逻辑
/// 10. ProjectStore upsertFromRemote / upsertModuleFromRemote / upsertSkillFromRemote / upsertIssueFromRemote merge 逻辑
/// 11. SyncWatermarkStore 水位线读写 + MAX 语义 + clearSeq 生命周期
/// 12. SessionSummaryStore upsertFromRemote merge 逻辑
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:wenzagent/src/persistence/database_manager.dart';
import 'package:wenzagent/src/persistence/entities/entities.dart';
import 'package:wenzagent/src/persistence/entities/project_entity.dart';
import 'package:wenzagent/src/persistence/entities/project_issue_entity.dart';
import 'package:wenzagent/src/persistence/entities/project_module_entity.dart';
import 'package:wenzagent/src/persistence/entities/project_skill_entity.dart';
import 'package:wenzagent/src/persistence/entities/session_summary_entity.dart';
import 'package:wenzagent/src/persistence/entities/spec_item_entity.dart';
import 'package:wenzagent/src/persistence/entities/sync_watermark_entity.dart';
import 'package:wenzagent/src/persistence/entities/todo_task_item_entity.dart';
import 'package:wenzagent/src/persistence/entities/todo_topic_entity.dart';
import 'package:wenzagent/src/persistence/store_merge_util.dart';
import 'package:wenzagent/src/persistence/stores/project_store.dart';
import 'package:wenzagent/src/persistence/stores/session_summary_store.dart';
import 'package:wenzagent/src/persistence/stores/spec_store.dart';
import 'package:wenzagent/src/persistence/stores/sync_watermark_store.dart';
import 'package:wenzagent/src/persistence/stores/todo_store.dart';
import 'package:wenzagent/src/agent/entity/rpc_request_sync.dart';

int _testCounter = 0;

void main() {
  // ═══════════════════════════════════════════════════════════════
  // 1. StoreMergeUtil 测试
  // ═══════════════════════════════════════════════════════════════
  group('StoreMergeUtil.mergeDeleteState', () {
    test('双方都无 deleteTime → 未删除', () {
      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: null,
        localDeleted: 0,
        remoteDeleteTime: null,
        remoteDeleted: 0,
      );
      expect(result.mergedDeleted, equals(0));
      expect(result.mergedDeleteTime, isNull);
    });

    test('本地 null，远程有 deleteTime → 采用远程', () {
      final dt = DateTime(2024, 6, 1);
      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: null,
        localDeleted: 0,
        remoteDeleteTime: dt,
        remoteDeleted: 1,
      );
      expect(result.mergedDeleted, equals(1));
      expect(result.mergedDeleteTime, dt);
    });

    test('远程 null，本地有 deleteTime → 采用本地', () {
      final dt = DateTime(2024, 6, 1);
      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: dt,
        localDeleted: 1,
        remoteDeleteTime: null,
        remoteDeleted: 0,
      );
      expect(result.mergedDeleted, equals(1));
      expect(result.mergedDeleteTime, dt);
    });

    test('双方都有 deleteTime，本地更新 → 取本地', () {
      final localDt = DateTime(2024, 6, 2);
      final remoteDt = DateTime(2024, 6, 1);
      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: localDt,
        localDeleted: 1,
        remoteDeleteTime: remoteDt,
        remoteDeleted: 1,
      );
      expect(result.mergedDeleted, equals(1));
      expect(result.mergedDeleteTime, localDt);
    });

    test('双方都有 deleteTime，远程更新 → 取远程', () {
      final localDt = DateTime(2024, 6, 1);
      final remoteDt = DateTime(2024, 6, 2);
      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: localDt,
        localDeleted: 1,
        remoteDeleteTime: remoteDt,
        remoteDeleted: 1,
      );
      expect(result.mergedDeleted, equals(1));
      expect(result.mergedDeleteTime, remoteDt);
    });

    test('远程复活（deleted=0, deleteTime=null）且 updateTime 更新 → 允许复活', () {
      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: DateTime(2024, 6, 1),
        localDeleted: 1,
        remoteDeleteTime: null,
        remoteDeleted: 0,
        localUpdateTime: DateTime(2024, 6, 1),
        remoteUpdateTime: DateTime(2024, 6, 2),
      );
      expect(result.mergedDeleted, equals(0));
      expect(result.mergedDeleteTime, isNull);
    });

    test('远程复活但 updateTime 更旧 → 保持本地删除', () {
      final localDt = DateTime(2024, 6, 2);
      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: localDt,
        localDeleted: 1,
        remoteDeleteTime: null,
        remoteDeleted: 0,
        localUpdateTime: DateTime(2024, 6, 2),
        remoteUpdateTime: DateTime(2024, 6, 1),
      );
      expect(result.mergedDeleted, equals(1));
      expect(result.mergedDeleteTime, localDt);
    });

    test('本地复活且 updateTime 更新 → 保持本地复活', () {
      final remoteDt = DateTime(2024, 6, 1);
      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: null,
        localDeleted: 0,
        remoteDeleteTime: remoteDt,
        remoteDeleted: 1,
        localUpdateTime: DateTime(2024, 6, 2),
        remoteUpdateTime: DateTime(2024, 6, 1),
      );
      expect(result.mergedDeleted, equals(0));
      expect(result.mergedDeleteTime, isNull);
    });

    test('updateTime 相等不满足复活条件 → 走原有逻辑', () {
      final localDt = DateTime(2024, 6, 1);
      final ts = DateTime(2024, 6, 2);
      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: localDt,
        localDeleted: 1,
        remoteDeleteTime: null,
        remoteDeleted: 0,
        localUpdateTime: ts,
        remoteUpdateTime: ts,
      );
      // isAfter 不满足，走原有逻辑：单侧有 deleteTime → 采用有 deleteTime 的一方
      expect(result.mergedDeleted, equals(1));
      expect(result.mergedDeleteTime, localDt);
    });

    test('不传 updateTime → 走原有逻辑', () {
      final localDt = DateTime(2024, 6, 1);
      final result = StoreMergeUtil.mergeDeleteState(
        localDeleteTime: localDt,
        localDeleted: 1,
        remoteDeleteTime: null,
        remoteDeleted: 0,
      );
      expect(result.mergedDeleted, equals(1));
      expect(result.mergedDeleteTime, localDt);
    });
  });

  group('StoreMergeUtil.shouldUpdateData', () {
    test('远程 updateTime 更新 → 需要更新', () {
      expect(
        StoreMergeUtil.shouldUpdateData(
          DateTime(2024, 6, 1),
          DateTime(2024, 6, 2),
        ),
        isTrue,
      );
    });

    test('远程 updateTime 更旧 → 不需要更新', () {
      expect(
        StoreMergeUtil.shouldUpdateData(
          DateTime(2024, 6, 2),
          DateTime(2024, 6, 1),
        ),
        isFalse,
      );
    });

    test('updateTime 相等 → 不需要更新', () {
      final ts = DateTime(2024, 6, 1);
      expect(StoreMergeUtil.shouldUpdateData(ts, ts), isFalse);
    });

    test('localUpdateTime 为 null → 需要更新', () {
      expect(
        StoreMergeUtil.shouldUpdateData(null, DateTime(2024, 6, 1)),
        isTrue,
      );
    });

    test('remoteUpdateTime 为 null → 需要更新', () {
      expect(
        StoreMergeUtil.shouldUpdateData(DateTime(2024, 6, 1), null),
        isTrue,
      );
    });

    test('双方都为 null → 需要更新', () {
      expect(StoreMergeUtil.shouldUpdateData(null, null), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 2. SyncWatermarkEntity 序列化测试
  // ═══════════════════════════════════════════════════════════════
  group('SyncWatermarkEntity', () {
    test('toMap → fromMap 往返一致', () {
      final now = DateTime(2025, 6, 15, 10, 30, 0);
      final entity = SyncWatermarkEntity(
        employeeId: 'emp-001',
        deviceId: 'dev-001',
        lastSeq: 42,
        clearSeq: 10,
        updateTime: now,
      );
      final map = entity.toMap();
      final restored = SyncWatermarkEntity.fromMap(map);

      expect(restored.employeeId, equals('emp-001'));
      expect(restored.deviceId, equals('dev-001'));
      expect(restored.lastSeq, equals(42));
      expect(restored.clearSeq, equals(10));
      expect(
        restored.updateTime.millisecondsSinceEpoch,
        equals(now.millisecondsSinceEpoch),
      );
    });

    test('clearSeq 为 null 时序列化正确', () {
      final entity = SyncWatermarkEntity(
        employeeId: 'emp-002',
        lastSeq: 0,
        updateTime: DateTime.now(),
      );
      final map = entity.toMap();
      expect(map['clearSeq'], isNull);

      final restored = SyncWatermarkEntity.fromMap(map);
      expect(restored.clearSeq, isNull);
    });

    test('fromMap 缺失字段使用默认值', () {
      final restored = SyncWatermarkEntity.fromMap({
        'employeeId': 'emp-003',
      });
      expect(restored.deviceId, equals(''));
      expect(restored.lastSeq, equals(0));
      expect(restored.clearSeq, isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 3. SpecItemEntity 序列化 + copyWith 测试
  // ═══════════════════════════════════════════════════════════════
  group('SpecItemEntity', () {
    final now = DateTime(2025, 6, 15);

    SpecItemEntity createSpec({
      String id = 'spec-001',
      String employeeId = 'emp-001',
      String title = 'Test Spec',
      String content = 'Content',
      String status = 'pending',
      String priority = 'medium',
      String tags = 'tag1,tag2',
      int sortOrder = 0,
      int deleted = 0,
    }) {
      return SpecItemEntity(
        id: id,
        employeeId: employeeId,
        title: title,
        content: content,
        status: status,
        priority: priority,
        tags: tags,
        sortOrder: sortOrder,
        deleted: deleted,
        createTime: now,
        updateTime: now,
      );
    }

    test('toMap → fromMap 往返一致', () {
      final spec = createSpec();
      final map = spec.toMap();
      final restored = SpecItemEntity.fromMap(map);

      expect(restored.id, equals(spec.id));
      expect(restored.employeeId, equals(spec.employeeId));
      expect(restored.title, equals(spec.title));
      expect(restored.content, equals(spec.content));
      expect(restored.status, equals(spec.status));
      expect(restored.priority, equals(spec.priority));
      expect(restored.tags, equals(spec.tags));
      expect(restored.sortOrder, equals(spec.sortOrder));
      expect(restored.deleted, equals(spec.deleted));
    });

    test('copyWith 部分字段更新', () {
      final spec = createSpec();
      final updated = spec.copyWith(
        title: 'Updated Title',
        status: 'in_progress',
        deleted: 1,
      );

      expect(updated.title, equals('Updated Title'));
      expect(updated.status, equals('in_progress'));
      expect(updated.deleted, equals(1));
      // 未修改字段保持不变
      expect(updated.id, equals(spec.id));
      expect(updated.content, equals(spec.content));
    });

    test('fromMap 缺失字段使用默认值', () {
      final restored = SpecItemEntity.fromMap({
        'id': 'spec-002',
        'employeeId': 'emp-002',
        'title': 'Minimal Spec',
        'createTime': now.millisecondsSinceEpoch,
        'updateTime': now.millisecondsSinceEpoch,
      });
      expect(restored.content, equals(''));
      expect(restored.status, equals('pending'));
      expect(restored.priority, equals('medium'));
      expect(restored.tags, equals(''));
      expect(restored.sortOrder, equals(0));
      expect(restored.deleted, equals(0));
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 4. TodoTopicEntity / TodoTaskItemEntity 序列化测试
  // ═══════════════════════════════════════════════════════════════
  group('TodoTopicEntity', () {
    final now = DateTime(2025, 6, 15);

    test('toMap → fromMap 往返一致', () {
      final topic = TodoTopicEntity(
        id: 'topic-001',
        employeeId: 'emp-001',
        title: 'Test Topic',
        description: 'Description',
        status: 'in_progress',
        sortOrder: 1,
        deleted: 0,
        createTime: now,
        updateTime: now,
        completedAt: now,
      );
      final map = topic.toMap();
      final restored = TodoTopicEntity.fromMap(map);

      expect(restored.id, equals('topic-001'));
      expect(restored.employeeId, equals('emp-001'));
      expect(restored.title, equals('Test Topic'));
      expect(restored.description, equals('Description'));
      expect(restored.status, equals('in_progress'));
      expect(restored.sortOrder, equals(1));
      expect(restored.deleted, equals(0));
      expect(restored.completedAt, isNotNull);
    });

    test('completedAt 为 null 时序列化正确', () {
      final topic = TodoTopicEntity(
        id: 'topic-002',
        employeeId: 'emp-001',
        title: 'No Completion',
        createTime: now,
        updateTime: now,
      );
      final map = topic.toMap();
      expect(map['completedAt'], isNull);

      final restored = TodoTopicEntity.fromMap(map);
      expect(restored.completedAt, isNull);
    });

    test('copyWith 部分字段更新', () {
      final topic = TodoTopicEntity(
        id: 'topic-003',
        employeeId: 'emp-001',
        title: 'Original',
        createTime: now,
        updateTime: now,
      );
      final updated = topic.copyWith(
        title: 'Updated',
        status: 'completed',
        completedAt: () => now,
      );
      expect(updated.title, equals('Updated'));
      expect(updated.status, equals('completed'));
      expect(updated.completedAt, isNotNull);
      expect(updated.id, equals('topic-003'));
    });
  });

  group('TodoTaskItemEntity', () {
    final now = DateTime(2025, 6, 15);

    test('toMap → fromMap 往返一致', () {
      final item = TodoTaskItemEntity(
        id: 'task-001',
        employeeId: 'emp-001',
        topicId: 'topic-001',
        title: 'Test Task',
        content: 'Task Content',
        status: 'pending',
        sortOrder: 2,
        deleted: 0,
        createTime: now,
        updateTime: now,
        completedAt: now,
      );
      final map = item.toMap();
      final restored = TodoTaskItemEntity.fromMap(map);

      expect(restored.id, equals('task-001'));
      expect(restored.employeeId, equals('emp-001'));
      expect(restored.topicId, equals('topic-001'));
      expect(restored.title, equals('Test Task'));
      expect(restored.content, equals('Task Content'));
      expect(restored.status, equals('pending'));
      expect(restored.completedAt, isNotNull);
    });

    test('copyWith 部分字段更新', () {
      final item = TodoTaskItemEntity(
        id: 'task-002',
        employeeId: 'emp-001',
        topicId: 'topic-001',
        title: 'Original Task',
        createTime: now,
        updateTime: now,
      );
      final updated = item.copyWith(
        title: 'Updated Task',
        status: 'in_progress',
      );
      expect(updated.title, equals('Updated Task'));
      expect(updated.status, equals('in_progress'));
      expect(updated.topicId, equals('topic-001'));
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 5. Project 系列实体序列化测试
  // ═══════════════════════════════════════════════════════════════
  group('ProjectEntity', () {
    final now = DateTime(2025, 6, 15);

    test('toMap → fromMap 往返一致', () {
      final project = ProjectEntity(
        uuid: 'proj-001',
        title: 'Test Project',
        description: 'A test project',
        workPath: '/tmp/work',
        gitUrl: 'https://github.com/test/repo.git',
        deleted: 0,
        createTime: now,
        updateTime: now,
      );
      final map = project.toMap();
      final restored = ProjectEntity.fromMap(map);

      expect(restored.uuid, equals('proj-001'));
      expect(restored.title, equals('Test Project'));
      expect(restored.description, equals('A test project'));
      expect(restored.workPath, equals('/tmp/work'));
      expect(restored.gitUrl, equals('https://github.com/test/repo.git'));
      expect(restored.deleted, equals(0));
      expect(restored.deleteTime, isNull);
    });

    test('copyWith deleteTime sentinel 行为', () {
      final dt = DateTime(2024, 1, 1);
      final project = ProjectEntity(
        uuid: 'proj-002',
        title: 'Test',
        deleted: 1,
        deleteTime: dt,
        createTime: now,
        updateTime: now,
      );

      // 不传 deleteTime → 保留原值
      final kept = project.copyWith(deleted: 0);
      expect(kept.deleteTime, isNotNull);
      expect(kept.deleteTime, dt);

      // 显式传 null → 清除
      final cleared = project.copyWith(deleted: 0, deleteTime: null);
      expect(cleared.deleteTime, isNull);
    });
  });

  group('ProjectModuleEntity', () {
    final now = DateTime(2025, 6, 15);

    test('toMap → fromMap 往返一致', () {
      final module = ProjectModuleEntity(
        uuid: 'mod-001',
        projectUuid: 'proj-001',
        title: 'Module A',
        description: 'Module description',
        sortOrder: 1,
        createTime: now,
        updateTime: now,
      );
      final map = module.toMap();
      final restored = ProjectModuleEntity.fromMap(map);

      expect(restored.uuid, equals('mod-001'));
      expect(restored.projectUuid, equals('proj-001'));
      expect(restored.title, equals('Module A'));
      expect(restored.sortOrder, equals(1));
    });
  });

  group('ProjectSkillEntity', () {
    final now = DateTime(2025, 6, 15);

    test('toMap → fromMap 往返一致', () {
      final skill = ProjectSkillEntity(
        uuid: 'pskill-001',
        projectUuid: 'proj-001',
        title: 'Project Skill',
        skillType: 'mcp',
        mcpConfig: '{"command": "test"}',
        createTime: now,
        updateTime: now,
      );
      final map = skill.toMap();
      final restored = ProjectSkillEntity.fromMap(map);

      expect(restored.uuid, equals('pskill-001'));
      expect(restored.skillType, equals('mcp'));
      expect(restored.mcpConfig, equals('{"command": "test"}'));
    });
  });

  group('ProjectIssueEntity', () {
    final now = DateTime(2025, 6, 15);

    test('toMap → fromMap 往返一致', () {
      final issue = ProjectIssueEntity(
        uuid: 'issue-001',
        projectUuid: 'proj-001',
        title: 'Bug fix',
        status: 'open',
        priority: 'high',
        assignee: 'user-001',
        createTime: now,
        updateTime: now,
      );
      final map = issue.toMap();
      final restored = ProjectIssueEntity.fromMap(map);

      expect(restored.uuid, equals('issue-001'));
      expect(restored.status, equals('open'));
      expect(restored.priority, equals('high'));
      expect(restored.assignee, equals('user-001'));
      expect(restored.isOpen, isTrue);
      expect(restored.isInProgress, isFalse);
      expect(restored.isClosed, isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 6. SessionSummaryEntity 序列化测试
  // ═══════════════════════════════════════════════════════════════
  group('SessionSummaryEntity', () {
    test('toMap → fromMap 往返一致', () {
      final summary = SessionSummaryEntity(
        employeeId: 'emp-001',
        deviceId: 'dev-001',
        unreadCount: 5,
        lastMsgId: 'msg-001',
        lastMsgRole: 'assistant',
        lastMsgContent: 'Hello world',
        lastMsgTime: 1718438400000,
        lastMsgSeq: 42,
        pendingPermission: '{"type":"file_read"}',
        pendingPermissionTime: 1718438400000,
        updateTime: 1718438400000,
      );
      final map = summary.toMap();
      final restored = SessionSummaryEntity.fromMap(map);

      expect(restored.employeeId, equals('emp-001'));
      expect(restored.deviceId, equals('dev-001'));
      expect(restored.unreadCount, equals(5));
      expect(restored.lastMsgId, equals('msg-001'));
      expect(restored.lastMsgRole, equals('assistant'));
      expect(restored.lastMsgContent, equals('Hello world'));
      expect(restored.lastMsgTime, equals(1718438400000));
      expect(restored.lastMsgSeq, equals(42));
      expect(restored.hasLatestMessage, isTrue);
      expect(restored.hasPendingPermission, isTrue);
      expect(restored.hasPendingConfirm, isFalse);
      expect(restored.hasPendingRequest, isTrue);
    });

    test('空摘要的默认值', () {
      final summary = SessionSummaryEntity(
        employeeId: 'emp-002',
        deviceId: 'dev-002',
        updateTime: 0,
      );
      expect(summary.unreadCount, equals(0));
      expect(summary.hasLatestMessage, isFalse);
      expect(summary.hasPendingRequest, isFalse);
      expect(summary.previewText, equals(''));
    });

    test('previewText 超过 100 字符截断', () {
      final longContent = 'A' * 150;
      final summary = SessionSummaryEntity(
        employeeId: 'emp-003',
        deviceId: 'dev-001',
        lastMsgContent: longContent,
        updateTime: 0,
      );
      expect(summary.previewText.length, equals(103)); // 100 + '...'
      expect(summary.previewText.endsWith('...'), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 7. RPC 同步请求实体测试
  // ═══════════════════════════════════════════════════════════════
  group('RPC 同步请求实体', () {
    test('GetMinSeqRequest toMap/fromMap', () {
      final req = GetMinSeqRequest(employeeId: 'emp-001');
      final map = req.toMap();
      final restored = GetMinSeqRequest.fromMap(map);
      expect(restored.employeeId, equals('emp-001'));
    });

    test('GetClearSeqRequest toMap/fromMap', () {
      final req = GetClearSeqRequest(employeeId: 'emp-002');
      final map = req.toMap();
      final restored = GetClearSeqRequest.fromMap(map);
      expect(restored.employeeId, equals('emp-002'));
    });

    test('ClearClearSeqRequest toMap/fromMap', () {
      final req = ClearClearSeqRequest(employeeId: 'emp-003');
      final map = req.toMap();
      final restored = ClearClearSeqRequest.fromMap(map);
      expect(restored.employeeId, equals('emp-003'));
    });

    test('UpdateSyncWatermarkRequest toMap/fromMap', () {
      final req = UpdateSyncWatermarkRequest(
        employeeId: 'emp-004',
        lastSeq: 100,
      );
      final map = req.toMap();
      final restored = UpdateSyncWatermarkRequest.fromMap(map);
      expect(restored.employeeId, equals('emp-004'));
      expect(restored.lastSeq, equals(100));
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 8-12. 需要 Database 的 Store 测试
  // ═══════════════════════════════════════════════════════════════
  late String testDbPath;
  late String deviceId;
  late DatabaseManager dbManager;

  setUp(() async {
    _testCounter++;
    testDbPath =
        '${Directory.systemTemp.path}/wenzagent_sync_comprehensive_test_$_testCounter';
    await Directory(testDbPath).create(recursive: true);

    deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';

    dbManager = DatabaseManager.getInstance(deviceId);
    await dbManager.initialize(storagePath: testDbPath);
  });

  tearDown(() async {
    await dbManager.close();
    DatabaseManager.removeInstance(deviceId);
    try {
      await Directory(testDbPath).delete(recursive: true);
    } catch (_) {}
  });

  // ─────────────────────────────────────────────────────
  // 8. SpecStore upsertFromRemote merge 逻辑
  // ─────────────────────────────────────────────────────
  group('SpecStore upsertFromRemote', () {
    late SpecStore store;
    const employeeId = 'emp-sync-spec';

    setUp(() {
      store = SpecStore(deviceId: deviceId);
    });

    SpecItemEntity createSpec({
      String id = 'spec-sync-001',
      String title = 'Test Spec',
      String content = 'Content',
      String status = 'pending',
      int deleted = 0,
      DateTime? updateTime,
    }) {
      return SpecItemEntity(
        id: id,
        employeeId: employeeId,
        title: title,
        content: content,
        status: status,
        deleted: deleted,
        createTime: DateTime(2025, 1, 1),
        updateTime: updateTime ?? DateTime(2025, 6, 1),
      );
    }

    test('本地不存在 → 直接插入', () {
      final remote = createSpec();
      final changed = store.upsertFromRemote(remote);

      expect(changed, isTrue);
      final found = store.findByIdIncludingDeleted(remote.id);
      expect(found, isNotNull);
      expect(found!.title, equals('Test Spec'));
    });

    test('本地已存在且远程更新 → 更新数据', () {
      // 先保存本地版本
      store.save(createSpec(title: 'Local Title'));

      // 远程版本 updateTime 更新
      final remote = createSpec(
        title: 'Remote Title',
        updateTime: DateTime(2025, 6, 2),
      );
      final changed = store.upsertFromRemote(remote);

      expect(changed, isTrue);
      final found = store.findByIdIncludingDeleted(remote.id);
      expect(found!.title, equals('Remote Title'));
    });

    test('本地已存在且远程更旧 → 不更新数据', () {
      store.save(createSpec(
        title: 'Local Title',
        updateTime: DateTime(2025, 6, 5),
      ));

      final remote = createSpec(
        title: 'Old Remote Title',
        updateTime: DateTime(2025, 6, 1),
      );
      final changed = store.upsertFromRemote(remote);

      expect(changed, isFalse);
      final found = store.findByIdIncludingDeleted(remote.id);
      expect(found!.title, equals('Local Title'));
    });

    test('软删除合并 - 远程删除 → 本地也标记删除', () {
      store.save(createSpec(deleted: 0));

      final remote = createSpec(deleted: 1);
      final changed = store.upsertFromRemote(remote);

      expect(changed, isTrue);
      final found = store.findByIdIncludingDeleted(remote.id);
      expect(found!.deleted, equals(1));
    });

    test('软删除合并 - 本地已删除 → 保持删除', () {
      store.save(createSpec(deleted: 1));

      final remote = createSpec(deleted: 0);
      final changed = store.upsertFromRemote(remote);

      expect(changed, isFalse);
      final found = store.findByIdIncludingDeleted(remote.id);
      expect(found!.deleted, equals(1));
    });

    test('upsertAllFromRemote 批量操作', () {
      final items = List.generate(
        5,
        (i) => createSpec(
          id: 'spec-batch-$i',
          title: 'Batch Spec $i',
        ),
      );
      final count = store.upsertAllFromRemote(items);
      expect(count, equals(5));
    });

    test('upsertAllFromRemote 重复调用只更新变化项', () {
      final items = List.generate(
        3,
        (i) => createSpec(
          id: 'spec-dup-$i',
          title: 'Dup Spec $i',
        ),
      );

      // 第一次：全部新增
      expect(store.upsertAllFromRemote(items), equals(3));

      // 第二次：相同数据，无变化
      expect(store.upsertAllFromRemote(items), equals(0));
    });
  });

  // ─────────────────────────────────────────────────────
  // 9. TodoStore upsertTopicFromRemote / upsertTaskItemFromRemote
  // ─────────────────────────────────────────────────────
  group('TodoStore upsertFromRemote', () {
    late TodoStore store;
    const employeeId = 'emp-sync-todo';

    setUp(() {
      store = TodoStore(deviceId: deviceId);
    });

    test('upsertTopicFromRemote 本地不存在 → 插入', () {
      final remote = TodoTopicEntity(
        id: 'topic-sync-001',
        employeeId: employeeId,
        title: 'Remote Topic',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 1),
      );
      final changed = store.upsertTopicFromRemote(remote);

      expect(changed, isTrue);
      final found = store.findTopicByIdIncludingDeleted(remote.id);
      expect(found, isNotNull);
      expect(found!.title, equals('Remote Topic'));
    });

    test('upsertTopicFromRemote 远程更新 → 更新数据', () {
      store.saveTopic(TodoTopicEntity(
        id: 'topic-sync-002',
        employeeId: employeeId,
        title: 'Local Topic',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 1),
      ));

      final remote = TodoTopicEntity(
        id: 'topic-sync-002',
        employeeId: employeeId,
        title: 'Updated Remote Topic',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 2),
      );
      final changed = store.upsertTopicFromRemote(remote);

      expect(changed, isTrue);
      expect(
        store.findTopicByIdIncludingDeleted(remote.id)!.title,
        equals('Updated Remote Topic'),
      );
    });

    test('upsertTopicFromRemote 远程更旧 → 不更新', () {
      store.saveTopic(TodoTopicEntity(
        id: 'topic-sync-003',
        employeeId: employeeId,
        title: 'Newer Local',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 5),
      ));

      final remote = TodoTopicEntity(
        id: 'topic-sync-003',
        employeeId: employeeId,
        title: 'Older Remote',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 1),
      );
      expect(store.upsertTopicFromRemote(remote), isFalse);
    });

    test('upsertTopicFromRemote 软删除合并', () {
      store.saveTopic(TodoTopicEntity(
        id: 'topic-sync-004',
        employeeId: employeeId,
        title: 'Active Topic',
        deleted: 0,
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 1),
      ));

      final remote = TodoTopicEntity(
        id: 'topic-sync-004',
        employeeId: employeeId,
        title: 'Deleted Remote',
        deleted: 1,
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 2),
      );
      final changed = store.upsertTopicFromRemote(remote);

      expect(changed, isTrue);
      expect(
        store.findTopicByIdIncludingDeleted(remote.id)!.deleted,
        equals(1),
      );
    });

    test('upsertTaskItemFromRemote 本地不存在 → 插入', () {
      // 先创建 topic
      store.saveTopic(TodoTopicEntity(
        id: 'topic-for-task',
        employeeId: employeeId,
        title: 'Parent Topic',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 1, 1),
      ));

      final remote = TodoTaskItemEntity(
        id: 'task-sync-001',
        employeeId: employeeId,
        topicId: 'topic-for-task',
        title: 'Remote Task',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 1),
      );
      final changed = store.upsertTaskItemFromRemote(remote);

      expect(changed, isTrue);
      final found = store.findTaskItemByIdIncludingDeleted(remote.id);
      expect(found, isNotNull);
      expect(found!.title, equals('Remote Task'));
    });

    test('upsertTaskItemFromRemote 远程更新 → 更新', () {
      store.saveTopic(TodoTopicEntity(
        id: 'topic-for-task2',
        employeeId: employeeId,
        title: 'Parent',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 1, 1),
      ));
      store.saveTaskItem(TodoTaskItemEntity(
        id: 'task-sync-002',
        employeeId: employeeId,
        topicId: 'topic-for-task2',
        title: 'Local Task',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 1),
      ));

      final remote = TodoTaskItemEntity(
        id: 'task-sync-002',
        employeeId: employeeId,
        topicId: 'topic-for-task2',
        title: 'Updated Task',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 2),
      );
      expect(store.upsertTaskItemFromRemote(remote), isTrue);
      expect(
        store.findTaskItemByIdIncludingDeleted(remote.id)!.title,
        equals('Updated Task'),
      );
    });

    test('upsertAllTopicsFromRemote + upsertAllTaskItemsFromRemote 批量', () {
      final topics = List.generate(
        3,
        (i) => TodoTopicEntity(
          id: 'topic-batch-$i',
          employeeId: employeeId,
          title: 'Batch Topic $i',
          createTime: DateTime(2025, 1, 1),
          updateTime: DateTime(2025, 6, 1),
        ),
      );
      expect(store.upsertAllTopicsFromRemote(topics), equals(3));

      final tasks = List.generate(
        5,
        (i) => TodoTaskItemEntity(
          id: 'task-batch-$i',
          employeeId: employeeId,
          topicId: 'topic-batch-${i % 3}',
          title: 'Batch Task $i',
          createTime: DateTime(2025, 1, 1),
          updateTime: DateTime(2025, 6, 1),
        ),
      );
      expect(store.upsertAllTaskItemsFromRemote(tasks), equals(5));
    });
  });

  // ─────────────────────────────────────────────────────
  // 10. ProjectStore upsertFromRemote 系列
  // ─────────────────────────────────────────────────────
  group('ProjectStore upsertFromRemote', () {
    late ProjectStore store;

    setUp(() {
      store = ProjectStore(deviceId: deviceId);
    });

    test('upsertFromRemote 本地不存在且未删除 → 插入', () {
      final remote = ProjectEntity(
        uuid: 'proj-sync-001',
        title: 'Remote Project',
        workPath: '/tmp/work',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 1),
      );
      expect(store.upsertFromRemote(remote), isTrue);
    });

    test('upsertFromRemote 本地不存在且已删除 → 不插入', () {
      final remote = ProjectEntity(
        uuid: 'proj-sync-deleted',
        title: 'Deleted Project',
        deleted: 1,
        deleteTime: DateTime(2025, 6, 1),
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 1),
      );
      expect(store.upsertFromRemote(remote), isFalse);
    });

    test('upsertFromRemote 远程更新 → 更新数据', () async {
      // 先保存本地
      await store.saveProject(ProjectEntity(
        uuid: 'proj-sync-002',
        title: 'Local Project',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 1),
      ));

      final remote = ProjectEntity(
        uuid: 'proj-sync-002',
        title: 'Updated Remote Project',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 2),
      );
      expect(store.upsertFromRemote(remote), isTrue);
    });

    test('upsertFromRemote 远程更旧 → 不更新', () async {
      await store.saveProject(ProjectEntity(
        uuid: 'proj-sync-003',
        title: 'Newer Local',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 5),
      ));

      final remote = ProjectEntity(
        uuid: 'proj-sync-003',
        title: 'Older Remote',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 1),
      );
      expect(store.upsertFromRemote(remote), isFalse);
    });

    test('upsertModuleFromRemote 本地不存在且未删除 → 插入', () async {
      // 先创建父项目
      await store.saveProject(ProjectEntity(
        uuid: 'proj-for-mod',
        title: 'Parent',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 1, 1),
      ));

      final remote = ProjectModuleEntity(
        uuid: 'mod-sync-001',
        projectUuid: 'proj-for-mod',
        title: 'Remote Module',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 1),
      );
      expect(store.upsertModuleFromRemote(remote), isTrue);
    });

    test('upsertSkillFromRemote 本地不存在且已删除 → 不插入', () {
      final remote = ProjectSkillEntity(
        uuid: 'pskill-sync-del',
        projectUuid: 'proj-any',
        title: 'Deleted Skill',
        deleted: 1,
        deleteTime: DateTime(2025, 6, 1),
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 1),
      );
      expect(store.upsertSkillFromRemote(remote), isFalse);
    });

    test('upsertIssueFromRemote 远程更新 → 更新', () async {
      await store.saveProject(ProjectEntity(
        uuid: 'proj-for-issue',
        title: 'Parent',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 1, 1),
      ));
      await store.saveIssue(ProjectIssueEntity(
        uuid: 'issue-sync-001',
        projectUuid: 'proj-for-issue',
        title: 'Local Issue',
        status: 'open',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 1),
      ));

      final remote = ProjectIssueEntity(
        uuid: 'issue-sync-001',
        projectUuid: 'proj-for-issue',
        title: 'Updated Issue',
        status: 'closed',
        createTime: DateTime(2025, 1, 1),
        updateTime: DateTime(2025, 6, 2),
      );
      expect(store.upsertIssueFromRemote(remote), isTrue);
    });
  });

  // ─────────────────────────────────────────────────────
  // 11. SyncWatermarkStore 水位线测试
  // ─────────────────────────────────────────────────────
  group('SyncWatermarkStore', () {
    late SyncWatermarkStore store;
    const employeeId = 'emp-sync-wm';

    setUp(() {
      store = SyncWatermarkStore(deviceId: deviceId);
    });

    test('不存在时 getWatermark 返回 null', () {
      expect(store.getWatermark(employeeId), isNull);
    });

    test('不存在时 getLastSeq 返回 0', () {
      expect(store.getLastSeq(employeeId), equals(0));
    });

    test('upsert + getWatermark 往返', () {
      store.upsert(SyncWatermarkEntity(
        employeeId: employeeId,
        lastSeq: 100,
        clearSeq: 50,
        updateTime: DateTime(2025, 6, 15),
      ));

      final wm = store.getWatermark(employeeId);
      expect(wm, isNotNull);
      expect(wm!.lastSeq, equals(100));
      expect(wm.clearSeq, equals(50));
    });

    test('updateLastSeq MAX 语义 - 更大值更新', () {
      store.updateLastSeq(employeeId, 10, deviceId: deviceId);
      store.updateLastSeq(employeeId, 20, deviceId: deviceId);
      expect(store.getLastSeq(employeeId, deviceId: deviceId), equals(20));
    });

    test('updateLastSeq MAX 语义 - 更小值不回退', () {
      store.updateLastSeq(employeeId, 100, deviceId: deviceId);
      store.updateLastSeq(employeeId, 50, deviceId: deviceId);
      expect(store.getLastSeq(employeeId, deviceId: deviceId), equals(100));
    });

    test('resetLastSeq enforceMax=false 可以降低', () {
      store.updateLastSeq(employeeId, 100, deviceId: deviceId);
      store.resetLastSeq(employeeId, 0, deviceId: deviceId, enforceMax: false);
      expect(store.getLastSeq(employeeId, deviceId: deviceId), equals(0));
    });

    test('resetLastSeq 默认 enforceMax=true 不降低', () {
      store.updateLastSeq(employeeId, 100, deviceId: deviceId);
      store.resetLastSeq(employeeId, 0, deviceId: deviceId);
      expect(store.getLastSeq(employeeId, deviceId: deviceId), equals(100));
    });

    test('clearSeq 生命周期: set → get → clear → null', () {
      expect(store.getClearSeq(employeeId, deviceId: deviceId), isNull);

      store.setClearSeq(employeeId, 100, deviceId: deviceId);
      expect(store.getClearSeq(employeeId, deviceId: deviceId), equals(100));

      store.clearClearSeq(employeeId, deviceId: deviceId);
      expect(store.getClearSeq(employeeId, deviceId: deviceId), isNull);
    });

    test('setClearSeq MAX 语义', () {
      store.setClearSeq(employeeId, 50, deviceId: deviceId);
      store.setClearSeq(employeeId, 100, deviceId: deviceId);
      expect(store.getClearSeq(employeeId, deviceId: deviceId), equals(100));

      store.setClearSeq(employeeId, 30, deviceId: deviceId);
      expect(store.getClearSeq(employeeId, deviceId: deviceId), equals(100));
    });

    test('deviceId 隔离', () {
      store.updateLastSeq(employeeId, 100, deviceId: 'devA');
      store.updateLastSeq(employeeId, 200, deviceId: 'devB');

      expect(store.getLastSeq(employeeId, deviceId: 'devA'), equals(100));
      expect(store.getLastSeq(employeeId, deviceId: 'devB'), equals(200));
      expect(store.getLastSeq(employeeId, deviceId: deviceId), equals(0));
    });

    test('清空会话后重置水位线完整流程', () {
      // 1. 正常同步
      store.updateLastSeq(employeeId, 200, deviceId: deviceId);
      // 2. 清空会话
      store.setClearSeq(employeeId, 200, deviceId: deviceId);
      store.resetLastSeq(employeeId, 200, deviceId: deviceId);
      // 3. 处理完清空
      store.clearClearSeq(employeeId, deviceId: deviceId);
      // 4. 新消息继续
      store.updateLastSeq(employeeId, 210, deviceId: deviceId);
      store.updateLastSeq(employeeId, 220, deviceId: deviceId);

      expect(store.getLastSeq(employeeId, deviceId: deviceId), equals(220));
      expect(store.getClearSeq(employeeId, deviceId: deviceId), isNull);
    });
  });

  // ─────────────────────────────────────────────────────
  // 12. SessionSummaryStore upsertFromRemote
  // ─────────────────────────────────────────────────────
  group('SessionSummaryStore upsertFromRemote', () {
    late SessionSummaryStore store;
    const employeeId = 'emp-sync-summary';

    setUp(() {
      store = SessionSummaryStore(deviceId: deviceId);
    });

    test('首次 upsertFromRemote 插入新记录', () {
      final remote = SessionSummaryEntity(
        employeeId: employeeId,
        deviceId: 'dev-remote',
        unreadCount: 3,
        lastMsgId: 'msg-001',
        lastMsgRole: 'assistant',
        lastMsgContent: 'Hello',
        lastMsgTime: 1718438400000,
        lastMsgSeq: 10,
        updateTime: 1718438400000,
      );

      store.upsertFromRemote(remote);

      // 查询验证（通过 getSummary）
      final summary = store.getSummary(employeeId, deviceId: 'dev-remote');
      expect(summary, isNotNull);
      expect(summary!.unreadCount, equals(3));
      expect(summary.lastMsgId, equals('msg-001'));
      expect(summary.lastMsgContent, equals('Hello'));
    });

    test('未读数取 MAX（不丢失）', () {
      // 先插入本地有 5 条未读
      store.upsertFromRemote(SessionSummaryEntity(
        employeeId: employeeId,
        deviceId: 'dev-max',
        unreadCount: 5,
        lastMsgTime: 100,
        updateTime: 100,
      ));

      // 远程同步来 2 条未读 → 应取 MAX = 5
      store.upsertFromRemote(SessionSummaryEntity(
        employeeId: employeeId,
        deviceId: 'dev-max',
        unreadCount: 2,
        lastMsgTime: 200,
        updateTime: 200,
      ));

      final summary = store.getSummary(employeeId, deviceId: 'dev-max');
      expect(summary!.unreadCount, equals(5));
    });

    test('最新消息字段：远程 lastMsgTime 更新时覆盖', () {
      store.upsertFromRemote(SessionSummaryEntity(
        employeeId: employeeId,
        deviceId: 'dev-msg',
        lastMsgId: 'msg-old',
        lastMsgContent: 'Old message',
        lastMsgTime: 100,
        updateTime: 100,
      ));

      store.upsertFromRemote(SessionSummaryEntity(
        employeeId: employeeId,
        deviceId: 'dev-msg',
        lastMsgId: 'msg-new',
        lastMsgContent: 'New message',
        lastMsgTime: 200,
        updateTime: 200,
      ));

      final summary = store.getSummary(employeeId, deviceId: 'dev-msg');
      expect(summary!.lastMsgId, equals('msg-new'));
      expect(summary.lastMsgContent, equals('New message'));
    });

    test('最新消息字段：远程 lastMsgTime 更旧时不覆盖', () {
      store.upsertFromRemote(SessionSummaryEntity(
        employeeId: employeeId,
        deviceId: 'dev-msg2',
        lastMsgId: 'msg-new',
        lastMsgContent: 'New message',
        lastMsgTime: 200,
        updateTime: 200,
      ));

      store.upsertFromRemote(SessionSummaryEntity(
        employeeId: employeeId,
        deviceId: 'dev-msg2',
        lastMsgId: 'msg-old',
        lastMsgContent: 'Old message',
        lastMsgTime: 100,
        updateTime: 100,
      ));

      final summary = store.getSummary(employeeId, deviceId: 'dev-msg2');
      expect(summary!.lastMsgId, equals('msg-new'));
      expect(summary.lastMsgContent, equals('New message'));
    });

    test('pendingPermission: 远程有值本地无 → 采用远程', () {
      store.upsertFromRemote(SessionSummaryEntity(
        employeeId: employeeId,
        deviceId: 'dev-perm',
        updateTime: 100,
      ));

      store.upsertFromRemote(SessionSummaryEntity(
        employeeId: employeeId,
        deviceId: 'dev-perm',
        pendingPermission: '{"type":"file_read"}',
        pendingPermissionTime: 200,
        updateTime: 200,
      ));

      final summary = store.getSummary(employeeId, deviceId: 'dev-perm');
      expect(summary!.hasPendingPermission, isTrue);
      expect(summary.pendingPermission, equals('{"type":"file_read"}'));
    });

    test('pendingPermission: 本地有值远程无 → 保持本地', () {
      store.upsertFromRemote(SessionSummaryEntity(
        employeeId: employeeId,
        deviceId: 'dev-perm2',
        pendingPermission: '{"type":"file_write"}',
        pendingPermissionTime: 200,
        updateTime: 200,
      ));

      store.upsertFromRemote(SessionSummaryEntity(
        employeeId: employeeId,
        deviceId: 'dev-perm2',
        updateTime: 300,
      ));

      final summary = store.getSummary(employeeId, deviceId: 'dev-perm2');
      expect(summary!.hasPendingPermission, isTrue);
      expect(summary.pendingPermission, equals('{"type":"file_write"}'));
    });
  });
}
