import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:wenzagent/wenzagent.dart';

void main() {
  late Database db;
  late _DirectCompressionMetaStore store;
  late ContextCompressor compressor;
  const empId = 'test-emp';

  setUp(() {
    db = sqlite3.openInMemory();
    // 建表
    db.execute('''
      CREATE TABLE IF NOT EXISTS context_compression_meta (
        employee_id   TEXT NOT NULL,
        device_id     TEXT NOT NULL,
        prune_start_id   TEXT NOT NULL DEFAULT '',
        last_compression_time INTEGER NOT NULL DEFAULT 0,
        messages_since_compression INTEGER NOT NULL DEFAULT 0,
        update_time  INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (employee_id, device_id)
      )
    ''');
    // 创建 store（注入内存 DB）
    store = _DirectCompressionMetaStore(db);

    compressor = ContextCompressor(
      config: const ContextCompressionConfig(
        maxContextTokens: 32000,
        compressionTargetRatio: 0.7,
        reservedOutputTokens: 4096,
        recentTurnsKeep: 1,
        cooldownMessageCount: 10,
      ),
      // store 不是 CompressionMetaStore 类型，不注入
      // compressor 测试不依赖 store（用 mock 方式）
      deviceId: 'test-device',
    );
  });

  tearDown(() {
    db.dispose();
  });

  // ═══════════════════════════════════════════════════
  // 辅助方法
  // ═══════════════════════════════════════════════════

  ChatMessage _userMsg(String empId, String id, String content, {int seq = 0}) {
    return ChatMessage(
      id: id, employeeId: empId, role: MessageRole.user,
      type: 'text', content: content, createdAt: DateTime.now(), seq: seq,
    );
  }

  ChatMessage _asstMsg(String empId, String id, String content, {int seq = 0}) {
    return ChatMessage(
      id: id, employeeId: empId, role: MessageRole.assistant,
      type: 'text', content: content, createdAt: DateTime.now(), seq: seq,
    );
  }

  ChatMessage _toolMsg(String empId, String id, String content,
      {int seq = 0, String? toolCallId}) {
    return ChatMessage(
      id: id, employeeId: empId, role: MessageRole.tool,
      type: 'functionResult', content: content, createdAt: DateTime.now(),
      seq: seq, toolCallId: toolCallId ?? 'tc-$id',
    );
  }

  ChatMessage _asstToolCallMsg(String empId, String id, String content,
      {int seq = 0, required List<ToolCall> toolCalls}) {
    return ChatMessage(
      id: id, employeeId: empId, role: MessageRole.assistant,
      type: 'functionCall', content: content, createdAt: DateTime.now(),
      seq: seq, toolCalls: toolCalls,
    );
  }

  SessionHistory _makeSession({
    String pruneStartId = '',
    int messagesSinceCompression = 10,
  }) {
    return SessionHistory(
      employeeId: empId,
      pruneStartId: pruneStartId,
      messagesSinceCompression: messagesSinceCompression,
    );
  }

  // ═══════════════════════════════════════════════════
  // 1. CompressionMetaEntity / Store（UUID 版本）
  // ═══════════════════════════════════════════════════

  group('CompressionMetaStore (UUID)', () {
    test('getMeta 不存在时返回 null', () {
      expect(store.getMeta(empId, 'dev-1'), isNull);
    });

    test('saveMeta + getMeta 基本 CRUD', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final meta = CompressionMetaEntity(
        employeeId: empId, deviceId: 'dev-1',
        pruneStartId: 'msg-uuid-001',
        lastCompressionTime: now, messagesSinceCompression: 0,
        updateTime: now,
      );
      store.saveMeta(meta);
      final loaded = store.getMeta(empId, 'dev-1')!;
      expect(loaded.pruneStartId, 'msg-uuid-001');
      expect(loaded.isCompressed, isTrue);
    });

    test('saveMeta 更新已有记录', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      store.saveMeta(CompressionMetaEntity(
        employeeId: empId, deviceId: 'dev-1',
        pruneStartId: 'msg-uuid-001',
        lastCompressionTime: now, messagesSinceCompression: 0,
        updateTime: now,
      ));
      store.saveMeta(CompressionMetaEntity(
        employeeId: empId, deviceId: 'dev-1',
        pruneStartId: 'msg-uuid-005',
        lastCompressionTime: now, messagesSinceCompression: 0,
        updateTime: now,
      ));
      final loaded = store.getMeta(empId, 'dev-1')!;
      expect(loaded.pruneStartId, 'msg-uuid-005');
    });

    test('incrementCoolDown / resetCoolDown', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      store.saveMeta(CompressionMetaEntity(
        employeeId: empId, deviceId: 'dev-1',
        pruneStartId: 'msg-uuid-001',
        lastCompressionTime: now, messagesSinceCompression: 0,
        updateTime: now,
      ));
      store.incrementCoolDown(empId, 'dev-1');
      store.incrementCoolDown(empId, 'dev-1');
      expect(store.getMeta(empId, 'dev-1')!.messagesSinceCompression, 2);

      store.resetCoolDown(empId, 'dev-1');
      expect(store.getMeta(empId, 'dev-1')!.messagesSinceCompression, 0);
    });

    test('deleteMeta', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      store.saveMeta(CompressionMetaEntity(
        employeeId: empId, deviceId: 'dev-1',
        pruneStartId: 'msg-uuid-001',
        lastCompressionTime: now, messagesSinceCompression: 0,
        updateTime: now,
      ));
      store.deleteMeta(empId, 'dev-1');
      expect(store.getMeta(empId, 'dev-1'), isNull);
    });

    test('不同 employee 隔离', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      store.saveMeta(CompressionMetaEntity(
        employeeId: empId, deviceId: 'dev-1',
        pruneStartId: 'msg-A',
        lastCompressionTime: now, messagesSinceCompression: 0,
        updateTime: now,
      ));
      store.saveMeta(CompressionMetaEntity(
        employeeId: 'other-emp', deviceId: 'dev-1',
        pruneStartId: 'msg-B',
        lastCompressionTime: now, messagesSinceCompression: 0,
        updateTime: now,
      ));
      expect(store.getMeta(empId, 'dev-1')!.pruneStartId, 'msg-A');
      expect(store.getMeta('other-emp', 'dev-1')!.pruneStartId, 'msg-B');
    });

    test('pruneStartId 为空表示未压缩', () {
      final meta = CompressionMetaEntity(
        employeeId: empId, deviceId: 'dev-1',
        pruneStartId: '',
        lastCompressionTime: 0, messagesSinceCompression: 0,
        updateTime: 0,
      );
      expect(meta.isCompressed, isFalse);
    });
  });

  // ═══════════════════════════════════════════════════
  // 2. shouldCompress
  // ═══════════════════════════════════════════════════

  group('shouldCompress', () {
    test('token 未超阈值 → false', () {
      final session = _makeSession();
      expect(compressor.shouldCompress(totalTokens: 10000, session: session), isFalse);
    });

    test('token 超阈值且冷却期已过 → true', () {
      final session = _makeSession(messagesSinceCompression: 15);
      expect(compressor.shouldCompress(totalTokens: 40000, session: session), isTrue);
    });

    test('token 超阈值但冷却期未过 → false', () {
      final session = _makeSession(messagesSinceCompression: 3);
      expect(compressor.shouldCompress(totalTokens: 40000, session: session), isFalse);
    });

    test('压缩未启用 → false', () {
      final disabledCompressor = ContextCompressor(
        config: const ContextCompressionConfig(maxContextTokens: 0),
      );
      final session = _makeSession(messagesSinceCompression: 100);
      expect(disabledCompressor.shouldCompress(totalTokens: 100000, session: session), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════
  // 3. buildCompressedMessages（UUID 版本）
  // ═══════════════════════════════════════════════════

  group('buildCompressedMessages (UUID)', () {
    test('pruneStartId 为空 → 全量返回', () {
      final msgs = [
        _userMsg(empId, 'u1', '你好'),
        _asstMsg(empId, 'a1', '你好！'),
      ];
      final session = _makeSession(pruneStartId: '');
      final result = compressor.buildCompressedMessages(
        employeeId: empId, allMessages: msgs, session: session,
      );
      // 2 条原始消息（无 system prompt）
      expect(result.length, 2);
    });

    test('pruneStartId 有值 → 旧消息丢弃 + 提示词 + 新消息原文', () {
      final msgs = [
        _userMsg(empId, 'u1', '第1条'),
        _asstMsg(empId, 'a1', '回复1'),
        _userMsg(empId, 'u2', '第2条'),
        _asstMsg(empId, 'a2', '回复2'),
        _userMsg(empId, 'u3', '第3条'),
        _asstMsg(empId, 'a3', '回复3'),
      ];
      // 从 u2 开始保留
      final session = _makeSession(pruneStartId: 'u2');
      final result = compressor.buildCompressedMessages(
        employeeId: empId, allMessages: msgs, session: session,
      );

      // 应包含：提示词 + u2 + a2 + u3 + a3 = 5 条
      expect(result.length, 5);
      // 第1条是提示词
      expect(result[0].role, MessageRole.system);
      expect(result[0].content, contains('省略 2 条消息'));
      // 第2条是 u2
      expect(result[1].id, 'u2');
      expect(result[1].content, '第2条');
      // 最后一条是 a3
      expect(result.last.id, 'a3');
    });

    test('system prompt 在提示词之前', () {
      final msgs = [
        _userMsg(empId, 'u1', '你好'),
        _asstMsg(empId, 'a1', '你好！'),
        _userMsg(empId, 'u2', '再见'),
      ];
      final session = _makeSession(pruneStartId: 'u2');
      final result = compressor.buildCompressedMessages(
        employeeId: empId, allMessages: msgs, session: session,
        systemPrompt: '你是助手',
      );

      expect(result[0].content, '你是助手');
      expect(result[1].content, contains('省略'));
      expect(result[2].id, 'u2');
    });

    test('所有消息在保留区内 → 无提示词', () {
      final msgs = [
        _userMsg(empId, 'u1', '你好'),
        _asstMsg(empId, 'a1', '你好！'),
      ];
      final session = _makeSession(pruneStartId: 'u1');
      final result = compressor.buildCompressedMessages(
        employeeId: empId, allMessages: msgs, session: session,
      );
      // u1 + a1 = 2 条，无提示词
      expect(result.length, 2);
      expect(result[0].id, 'u1');
    });

    test('pruneStartId 不在消息列表中 → 全量返回', () {
      final msgs = [
        _userMsg(empId, 'u1', '你好'),
        _asstMsg(empId, 'a1', '你好！'),
      ];
      final session = _makeSession(pruneStartId: 'nonexistent-id');
      final result = compressor.buildCompressedMessages(
        employeeId: empId, allMessages: msgs, session: session,
      );
      expect(result.length, 2);
    });
  });

  // ═══════════════════════════════════════════════════
  // 4. groupIntoTurns
  // ═══════════════════════════════════════════════════

  group('groupIntoTurns', () {
    test('按 user 消息分组', () {
      final msgs = [
        _userMsg(empId, 'u1', '你好'),
        _asstMsg(empId, 'a1', '你好！'),
        _userMsg(empId, 'u2', '再见'),
        _asstMsg(empId, 'a2', '再见！'),
      ];
      final turns = ContextCompressor.groupIntoTurns(msgs);
      expect(turns.length, 2);
      expect(turns[0].messages.length, 2); // u1 + a1
      expect(turns[1].messages.length, 2); // u2 + a2
    });

    test('空列表 → 空轮次', () {
      expect(ContextCompressor.groupIntoTurns([]).length, 0);
    });

    test('多轮对话含 tool calls 正确分组', () {
      final msgs = [
        _userMsg(empId, 'u1', '查文件'),
        _asstToolCallMsg(empId, 'a1', '', seq: 0, toolCalls: [
          ToolCall(id: 'tc1', name: 'file_read', arguments: {}),
        ]),
        _toolMsg(empId, 't1', '文件内容...', toolCallId: 'tc1'),
        _asstMsg(empId, 'a2', '这是文件内容'),
        _userMsg(empId, 'u2', '修改代码'),
        _asstMsg(empId, 'a3', '已修改'),
      ];
      final turns = ContextCompressor.groupIntoTurns(msgs);
      expect(turns.length, 2);
      expect(turns[0].messages.length, 4); // u1 + a1(tc) + t1 + a2
      expect(turns[1].messages.length, 2); // u2 + a3
    });
  });

  // ═══════════════════════════════════════════════════
  // 5. SessionHistory（UUID 版本）
  // ═══════════════════════════════════════════════════

  group('SessionHistory (UUID)', () {
    test('默认值', () {
      final session = SessionHistory(employeeId: empId);
      expect(session.pruneStartId, '');
      expect(session.messagesSinceCompression, 0);
    });

    test('toMap / fromMap 序列化', () {
      final session = SessionHistory(
        employeeId: empId,
        pruneStartId: 'msg-uuid-123',
        messagesSinceCompression: 5,
      );
      final map = session.toMap();
      expect(map['pruneStartId'], 'msg-uuid-123');
      expect(map['messagesSinceCompression'], 5);

      final restored = SessionHistory.fromMap(map);
      expect(restored.pruneStartId, 'msg-uuid-123');
      expect(restored.messagesSinceCompression, 5);
    });

    test('clear() 重置所有字段', () {
      final session = SessionHistory(
        employeeId: empId,
        pruneStartId: 'msg-uuid-123',
        messagesSinceCompression: 10,
      );
      session.clear();
      expect(session.pruneStartId, '');
      expect(session.messagesSinceCompression, 0);
    });
  });

  // ═══════════════════════════════════════════════════
  // 6. 集成测试（UUID 版本）
  // ═══════════════════════════════════════════════════

  group('集成 (UUID)', () {
    test('压缩状态持久化后可恢复', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      store.saveMeta(CompressionMetaEntity(
        employeeId: empId, deviceId: 'test-device',
        pruneStartId: 'msg-uuid-abc',
        lastCompressionTime: now, messagesSinceCompression: 7,
        updateTime: now,
      ));

      final meta = store.getMeta(empId, 'test-device')!;
      final session = SessionHistory(employeeId: empId);
      session.pruneStartId = meta.pruneStartId;
      session.messagesSinceCompression = meta.messagesSinceCompression;

      expect(session.pruneStartId, 'msg-uuid-abc');
      expect(session.messagesSinceCompression, 7);
    });

    test('清空会话时压缩元数据一并清除', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      store.saveMeta(CompressionMetaEntity(
        employeeId: empId, deviceId: 'test-device',
        pruneStartId: 'msg-uuid-xyz',
        lastCompressionTime: now, messagesSinceCompression: 0,
        updateTime: now,
      ));

      store.deleteMeta(empId, 'test-device');
      expect(store.getMeta(empId, 'test-device'), isNull);
    });
  });

  // ═══════════════════════════════════════════════════
  // 7. 端到端场景（UUID 版本）
  // ═══════════════════════════════════════════════════

  group('端到端场景 (UUID)', () {
    test('50 条消息模拟压缩全流程', () {
      final uuid = Uuid();
      final msgs = <ChatMessage>[];
      for (var i = 0; i < 50; i++) {
        msgs.add(_userMsg(empId, uuid.v4(), '用户消息 $i ' * 200));
        msgs.add(_asstMsg(empId, uuid.v4(), 'AI回复 $i ' * 300));
      }

      final session = _makeSession(messagesSinceCompression: 20);
      compressor.prepareCompression(
        employeeId: empId, allMessages: msgs, session: session,
      );

      // 压缩后 pruneStartId 不为空
      expect(session.pruneStartId.isNotEmpty, isTrue,
          reason: '压缩后 pruneStartId 应非空');
      expect(session.messagesSinceCompression, 0);

      // buildCompressedMessages 应正确过滤
      final result = compressor.buildCompressedMessages(
        employeeId: empId, allMessages: msgs, session: session,
      );

      // 应包含提示词 + 保留的消息
      expect(result.length, lessThan(msgs.length));
      expect(result.first.role, MessageRole.system);
      expect(result.first.content, contains('省略'));

      // 验证内存状态（compressor 未注入 store，不验证 DB）
      expect(session.pruneStartId.isNotEmpty, isTrue);
    });

    test('多次压缩：pruneStartId 递增', () {
      final uuid = Uuid();
      var msgs = <ChatMessage>[];
      for (var i = 0; i < 30; i++) {
        msgs.add(_userMsg(empId, uuid.v4(), '消息 $i ' * 500));
        msgs.add(_asstMsg(empId, uuid.v4(), '回复 $i ' * 600));
      }

      // 第一次压缩
      var session = _makeSession(messagesSinceCompression: 20);
      compressor.prepareCompression(
        employeeId: empId, allMessages: msgs, session: session,
      );
      final firstPruneId = session.pruneStartId;
      expect(firstPruneId.isNotEmpty, isTrue);

      // 模拟更多消息
      for (var i = 30; i < 60; i++) {
        msgs.add(_userMsg(empId, uuid.v4(), '消息 $i ' * 50));
        msgs.add(_asstMsg(empId, uuid.v4(), '回复 $i ' * 60));
      }
      session.messagesSinceCompression = 20;

      // 第二次压缩
      compressor.prepareCompression(
        employeeId: empId, allMessages: msgs, session: session,
      );
      // pruneStartId 应该指向更后面的消息
      expect(session.pruneStartId.isNotEmpty, isTrue,
          reason: '第二次压缩后 pruneStartId 应非空');
      // 新的 pruneStartId 应该在消息列表中排在第一次之后
      final firstIdx = msgs.indexWhere((m) => m.id == firstPruneId);
      final secondIdx = msgs.indexWhere((m) => m.id == session.pruneStartId);
      expect(secondIdx, greaterThan(firstIdx));
    });

    test('DB 原始消息完整保留', () {
      final uuid = Uuid();
      final msgs = <ChatMessage>[];
      for (var i = 0; i < 20; i++) {
        msgs.add(_userMsg(empId, uuid.v4(), '用户消息 $i'));
        msgs.add(_asstMsg(empId, uuid.v4(), 'AI回复 $i'));
      }

      final session = _makeSession(messagesSinceCompression: 20);
      compressor.prepareCompression(
        employeeId: empId, allMessages: msgs, session: session,
      );

      // 压缩后原始消息列表不变
      expect(msgs.length, 40);
      for (var i = 0; i < 40; i++) {
        expect(msgs[i].content, contains(i.isEven ? '用户消息' : 'AI回复'));
      }
    });
  });

  // ═══════════════════════════════════════════════════
  // 8. Config
  // ═══════════════════════════════════════════════════

  group('ContextCompressionConfig', () {
    test('默认值', () {
      const config = ContextCompressionConfig(maxContextTokens: 32000);
      expect(config.compressionTargetRatio, 0.7);
      expect(config.cooldownMessageCount, 10);
      expect(config.recentTurnsKeep, 3);
    });

    test('enabled 根据 maxContextTokens 判断', () {
      const enabled = ContextCompressionConfig(maxContextTokens: 32000);
      const disabled = ContextCompressionConfig(maxContextTokens: 0);
      expect(enabled.enabled, isTrue);
      expect(disabled.enabled, isFalse);
    });
  });
}

/// 内存版 CompressionMetaStore
///
/// 直接使用 sqlite3 内存数据库，绕过 DatabaseManager 的文件初始化。
/// 不依赖 DatabaseManager 的轻量级 Store
///
/// 直接操作 sqlite3 内存数据库，跳过 DatabaseManager 的初始化检查。
class _DirectCompressionMetaStore {
  final Database _db;
  _DirectCompressionMetaStore(this._db);

  CompressionMetaEntity? getMeta(String employeeId, String deviceId) {
    final result = _db.select(
      'SELECT * FROM context_compression_meta '
      'WHERE employee_id = ? AND device_id = ?',
      [employeeId, deviceId],
    );
    if (result.isEmpty) return null;
    return CompressionMetaEntity.fromMap(result.first);
  }

  void saveMeta(CompressionMetaEntity meta) {
    final now = DateTime.now().millisecondsSinceEpoch;
    meta.updateTime = now;
    _db.execute('''
      INSERT INTO context_compression_meta (
        employee_id, device_id, prune_start_id,
        last_compression_time,
        messages_since_compression, update_time
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(employee_id, device_id) DO UPDATE SET
        prune_start_id = excluded.prune_start_id,
        last_compression_time = excluded.last_compression_time,
        messages_since_compression = excluded.messages_since_compression,
        update_time = excluded.update_time
    ''', [
      meta.employeeId, meta.deviceId, meta.pruneStartId,
      meta.lastCompressionTime, meta.messagesSinceCompression, meta.updateTime,
    ]);
  }

  void incrementCoolDown(String employeeId, String deviceId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      UPDATE context_compression_meta SET
        messages_since_compression = messages_since_compression + 1,
        update_time = ?
      WHERE employee_id = ? AND device_id = ?
    ''', [now, employeeId, deviceId]);
  }

  void resetCoolDown(String employeeId, String deviceId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      UPDATE context_compression_meta SET
        messages_since_compression = 0,
        last_compression_time = ?,
        update_time = ?
      WHERE employee_id = ? AND device_id = ?
    ''', [now, now, employeeId, deviceId]);
  }

  void deleteMeta(String employeeId, String deviceId) {
    _db.execute(
      'DELETE FROM context_compression_meta '
      'WHERE employee_id = ? AND device_id = ?',
      [employeeId, deviceId],
    );
  }
}
