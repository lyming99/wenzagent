/// 消息数据库诊断脚本
///
/// 查询小红的设备数据库，分析工具调用消息状态，
/// 定位"启动后大量工具调用消息显示正在执行中"的原因。
///
/// 用法: dart run tool/db_diagnostic.dart
library;

import 'dart:io';
import 'package:sqlite3/sqlite3.dart';

void main() {
  final dbPath =
      r'C:\Users\98000\Documents\96213fff-8452-4b27-b54f-b2c857c4a9ce\devices\wenzagent.db';

  if (!File(dbPath).existsSync()) {
    print('[ERROR] 数据库文件不存在: $dbPath');
    exit(1);
  }

  final fileSize = File(dbPath).lengthSync();
  print('=== 数据库诊断报告 ===');
  print('路径: $dbPath');
  print('大小: ${(fileSize / 1024 / 1024).toStringAsFixed(2)} MB\n');

  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);

  try {
    _checkSchemaVersion(db);
    _checkTableStats(db);
    _checkProcessingStatus(db);
    _checkStuckToolCalls(db);
    _checkEmployees(db);
    _checkSyncWatermark(db);
    _checkRecentMessages(db);
  } finally {
    db.dispose();
  }
}

/// 1. 检查数据库 schema 版本
void _checkSchemaVersion(Database db) {
  print('━━━ 1. Schema 版本 ━━━');
  final result = db.select('PRAGMA user_version');
  final version = result.first.values.first as int;
  print('当前版本: $version');
  print('期望版本: 5');
  print(version == 5 ? '[OK] 版本一致' : '[WARN] 版本不匹配!');

  // 检查 WAL 模式
  final journalMode = db.select('PRAGMA journal_mode');
  print('日志模式: ${journalMode.first.values.first}');
  print('');
}

/// 2. 检查各表统计
void _checkTableStats(Database db) {
  print('━━━ 2. 各表统计 ━━━');

  final tables = [
    'employees',
    'sessions',
    'messages',
    'skills',
    'device_configs',
    'scheduled_tasks',
    'sync_watermark',
  ];

  for (final table in tables) {
    try {
      final result = db.select('SELECT COUNT(*) as cnt FROM $table');
      final count = result.first['cnt'] as int;
      print('  $table: $count 条');
    } catch (e) {
      print('  $table: [ERROR] $e');
    }
  }
  print('');
}

/// 3. 检查消息处理状态分布
void _checkProcessingStatus(Database db) {
  print('━━━ 3. 消息处理状态分布（未删除） ━━━');

  final result = db.select('''
    SELECT processing_status, COUNT(*) as cnt
    FROM messages
    WHERE deleted = 0
    GROUP BY processing_status
    ORDER BY cnt DESC
  ''');

  for (final row in result) {
    final status = row['processing_status'] as String? ?? 'NULL';
    final count = row['cnt'] as int;
    final flag = (status == 'processing' || status == 'queued') ? ' <<<' : '';
    print('  $status: $count 条$flag');
  }
  print('');

  // 检查已删除消息的状态分布
  print('  已删除消息状态分布:');
  final deletedResult = db.select('''
    SELECT processing_status, COUNT(*) as cnt
    FROM messages
    WHERE deleted = 1
    GROUP BY processing_status
    ORDER BY cnt DESC
  ''');
  for (final row in deletedResult) {
    final status = row['processing_status'] as String? ?? 'NULL';
    final count = row['cnt'] as int;
    print('    $status: $count 条');
  }
  print('');
}

/// 4. 重点：检查卡住的工具调用消息
void _checkStuckToolCalls(Database db) {
  print('━━━ 4. 卡住的工具调用消息（processing/queued 状态） ━━━');

  // 查找 processing 状态的 functionCall 消息
  final processingCalls = db.select('''
    SELECT uuid, employee_id, role, type, tool_name, tool_calls,
           processing_status, processing_error,
           create_time, update_time, seq
    FROM messages
    WHERE deleted = 0
      AND processing_status IN ('processing', 'queued')
      AND type IN ('functionCall', 'functionResult')
    ORDER BY create_time ASC
  ''');

  final rows = processingCalls.toList();
  print('  共 ${rows.length} 条卡住的工具调用消息\n');

  if (rows.isEmpty) {
    print('  [OK] 没有卡住的工具调用消息');
    print('');
    return;
  }

  // 按 employee 分组统计
  final byEmployee = <String, int>{};
  for (final row in rows) {
    final eid = row['employee_id'] as String;
    byEmployee[eid] = (byEmployee[eid] ?? 0) + 1;
  }
  print('  按 employee 分组:');
  for (final entry in byEmployee.entries) {
    print('    ${entry.key}: ${entry.value} 条');
  }
  print('');

  // 按 type 分组统计
  final byType = <String, int>{};
  for (final row in rows) {
    final type = row['type'] as String? ?? 'text';
    byType[type] = (byType[type] ?? 0) + 1;
  }
  print('  按消息类型分组:');
  for (final entry in byType.entries) {
    print('    ${entry.key}: ${entry.value} 条');
  }
  print('');

  // 显示最近 20 条详情
  final showCount = rows.length > 20 ? 20 : rows.length;
  print('  最近 $showCount 条详情:');
  print('  ${'seq'.padRight(6)} | ${'employee_id'.padRight(20)} | ${'role'.padRight(9)} | ${'type'.padRight(14)} | ${'tool_name'.padRight(30)} | ${'status'.padRight(12)} | 创建时间');
  print('  ${'-' * 130}');

  for (final row in rows) {
    final seq = (row['seq'] as int?)?.toString().padRight(6) ?? 'NULL'.padRight(6);
    final eid = (row['employee_id'] as String).padRight(20);
    final role = (row['role'] as String? ?? '').padRight(9);
    final type = (row['type'] as String? ?? '').padRight(14);
    final toolName = (row['tool_name'] as String? ?? '(见tool_calls)').padRight(30);
    final status = (row['processing_status'] as String? ?? '').padRight(12);
    final createTime = _formatTime(row['create_time'] as int?);
    print('  $seq | $eid | $role | $type | $toolName | $status | $createTime');
  }
  print('');

  // 检查这些卡住消息的时间分布
  final now = DateTime.now().millisecondsSinceEpoch;
  var withinHour = 0;
  var withinDay = 0;
  var withinWeek = 0;
  var older = 0;

  for (final row in rows) {
    final ct = row['create_time'] as int? ?? 0;
    final diff = now - ct;
    if (diff < 3600000) {
      withinHour++;
    } else if (diff < 86400000) {
      withinDay++;
    } else if (diff < 604800000) {
      withinWeek++;
    } else {
      older++;
    }
  }

  print('  时间分布:');
  print('    1小时内: $withinHour 条');
  print('    1天内:   $withinDay 条');
  print('    1周内:   $withinWeek 条');
  print('    更早:    $older 条');
  print('');

  // 分析可能的原因
  print('━━━ 5. 问题分析 ━━━');
  if (rows.isNotEmpty) {
    final hasOldMessages = withinDay + withinWeek + older > 0;
    final hasManyCalls = rows.length > 10;

    if (hasOldMessages) {
      print('  [严重] 存在较旧的 processing/queued 状态工具调用消息');
      print('         说明这些消息的工具调用可能已经完成，但状态未更新');
      print('         可能原因:');
      print('         1. App 在工具执行过程中崩溃/被杀死，未能更新状态');
      print('         2. 消息同步时同步了中间状态（processing），但未同步最终状态');
      print('         3. 客户端同步 watermark 异常，未拉取到状态更新的消息');
    }

    if (hasManyCalls) {
      print('\n  [严重] 卡住的消息数量较多 (${rows.length} 条)');
      print('         可能导致 App 启动后大量消息显示"正在执行中"');
    }

    // 检查是否有对应的 functionResult 消息
    print('\n  检查是否有对应的 tool result 消息...');
    final processingUuids =
        rows.map((r) => "'${r['uuid'] as String}'").join(',');
    final toolCallsWithResult = db.select('''
      SELECT m1.uuid as call_uuid, m1.tool_name,
             COUNT(m2.uuid) as result_count
      FROM messages m1
      LEFT JOIN messages m2 ON m2.tool_call_id = m1.uuid AND m2.deleted = 0
      WHERE m1.uuid IN ($processingUuids)
      GROUP BY m1.uuid
    ''');

    var hasResultButStuck = 0;
    var noResult = 0;
    for (final row in toolCallsWithResult) {
      final rc = row['result_count'] as int;
      if (rc > 0) {
        hasResultButStuck++;
      } else {
        noResult++;
      }
    }

    if (hasResultButStuck > 0) {
      print('    [关键发现] $hasResultButStuck 条 processing 状态的 functionCall '
          '已有对应的 functionResult!');
      print('    说明工具已执行完毕，但 functionCall 消息状态未更新为 completed');
      print('    -> 这是导致"显示正在执行中"的直接原因');
    }
    if (noResult > 0) {
      print('    $noResult 条 processing 状态的 functionCall 没有对应的 functionResult');
      print('    这些可能是真正未完成的工具调用');
    }

    // 检查 seq 连续性
    print('\n  检查 seq 连续性（是否有 gap）...');
    final seqResult = db.select('''
      SELECT seq, LEAD(seq) OVER (ORDER BY seq) as next_seq
      FROM messages
      WHERE deleted = 0
      ORDER BY seq
    ''');
    var gaps = <String>[];
    var prevSeq = 0;
    for (final row in seqResult) {
      final seq = row['seq'] as int;
      if (prevSeq > 0 && seq > prevSeq + 1) {
        gaps.add('$prevSeq -> $seq (跳过 ${seq - prevSeq - 1})');
      }
      prevSeq = seq;
    }
    if (gaps.isEmpty) {
      print('    [OK] seq 连续无 gap');
    } else {
      print('    [WARN] 发现 ${gaps.length} 处 seq gap:');
      for (final g in gaps.take(10)) {
        print('      $g');
      }
    }
  } else {
    print('  [OK] 没有发现卡住的工具调用消息');
    print('  如果 App 端仍然显示"正在执行中"，可能是:');
    print('  1. 客户端本地缓存了旧状态');
    print('  2. UI 渲染层的状态管理问题');
  }
  print('');
}

/// 5. 检查员工/会话信息
void _checkEmployees(Database db) {
  print('━━━ 6. 员工/会话列表 ━━━');

  final result = db.select('''
    SELECT e.uuid, e.name, e.status, e.device_id, e.current_device_id,
           e.deleted, e.create_time,
           (SELECT COUNT(*) FROM messages m WHERE m.employee_id = e.uuid AND m.deleted = 0) as msg_count,
           (SELECT COUNT(*) FROM messages m WHERE m.employee_id = e.uuid
            AND m.deleted = 0 AND m.processing_status IN ('processing', 'queued')) as stuck_count
    FROM employees e
    ORDER BY e.update_time DESC
  ''');

  print('  ${'name'.padRight(15)} | ${'status'.padRight(8)} | ${'device_id'.padRight(12)} | 消息数 | 卡住数 | 创建时间');
  print('  ${'-' * 100}');

  for (final row in result) {
    final name = (row['name'] as String? ?? '').padRight(15);
    final status = (row['status'] as String? ?? '').padRight(8);
    final deviceId = (row['device_id'] as String? ?? '').padRight(12);
    final msgCount = row['msg_count'] as int;
    final stuckCount = row['stuck_count'] as int;
    final createTime = _formatTime(row['create_time'] as int?);
    final flag = stuckCount > 0 ? ' <<<' : '';
    print('  $name | $status | $deviceId | ${msgCount.toString().padLeft(5)} | ${stuckCount.toString().padLeft(5)} | $createTime$flag');
  }
  print('');
}

/// 6. 检查同步水位线
void _checkSyncWatermark(Database db) {
  print('━━━ 7. 同步水位线 ━━━');

  // 检查 clear_seq 是否有值
  final clearResult = db.select('''
    SELECT employee_id, last_seq, clear_seq, update_time
    FROM sync_watermark
    WHERE clear_seq IS NOT NULL
  ''');

  final clearRows = clearResult.toList();
  if (clearRows.isNotEmpty) {
    print('  [INFO] 发现 clear_seq 标记:');
    for (final row in clearRows) {
      final eid = row['employee_id'] as String;
      final lastSeq = row['last_seq'] as int;
      final clearSeq = row['clear_seq'] as int;
      print('    $eid: last_seq=$lastSeq, clear_seq=$clearSeq');
      print('    -> 客户端应删除 seq < $clearSeq 的消息');
    }
  } else {
    print('  [OK] 没有 clear_seq 标记');
  }

  // 各 employee 的 watermark vs 实际 max_seq
  final watermarkResult = db.select('''
    SELECT sw.employee_id, sw.last_seq, sw.update_time as wm_time,
           (SELECT MAX(m.seq) FROM messages m WHERE m.employee_id = sw.employee_id AND m.deleted = 0) as actual_max_seq
    FROM sync_watermark sw
    ORDER BY sw.employee_id
  ''');

  print('\n  水位线 vs 实际最大 seq:');
  print('  ${'employee_id'.padRight(25)} | ${'last_seq'.padRight(10)} | ${'actual_max'.padRight(10)} | 差值 | 更新时间');
  print('  ${'-' * 90}');

  for (final row in watermarkResult) {
    final eid = (row['employee_id'] as String).padRight(25);
    final lastSeq = (row['last_seq'] as int?) ?? 0;
    final actualMax = (row['actual_max_seq'] as int?) ?? 0;
    final diff = actualMax - lastSeq;
    final wmTime = _formatTime(row['wm_time'] as int?);
    final flag = diff > 20 ? ' <<<' : '';
    print('  $eid | ${lastSeq.toString().padRight(10)} | ${actualMax.toString().padRight(10)} | ${diff.toString().padLeft(4)} | $wmTime$flag');
  }
  print('');
}

/// 7. 检查最近的消息
void _checkRecentMessages(Database db) {
  print('━━━ 8. 最近 20 条消息 ━━━');

  final result = db.select('''
    SELECT uuid, employee_id, role, type, tool_name, processing_status,
           create_time, seq
    FROM messages
    WHERE deleted = 0
    ORDER BY create_time DESC
    LIMIT 20
  ''');

  print('  ${'seq'.padRight(6)} | ${'role'.padRight(9)} | ${'type'.padRight(14)} | ${'status'.padRight(12)} | ${'tool_name'.padRight(25)} | 创建时间');
  print('  ${'-' * 110}');

  for (final row in result) {
    final seq = (row['seq'] as int?)?.toString().padRight(6) ?? 'NULL'.padRight(6);
    final role = (row['role'] as String? ?? '').padRight(9);
    final type = (row['type'] as String? ?? '').padRight(14);
    final status = (row['processing_status'] as String? ?? 'none').padRight(12);
    final toolName = (row['tool_name'] as String? ?? '').padRight(25);
    final createTime = _formatTime(row['create_time'] as int?);
    print('  $seq | $role | $type | $status | $toolName | $createTime');
  }
  print('');

  // 最终建议
  print('━━━ 诊断总结 ━━━');
  print('');
  print('  如需修复"正在执行中"的消息，可以执行以下 SQL:');
  print('  UPDATE messages SET processing_status = \'none\'');
  print('  WHERE processing_status IN (\'processing\', \'queued\')');
  print('  AND deleted = 0');
  print('  AND type = \'functionCall\';');
  print('');
  print('  或更保守地，仅修复已有 result 的:');
  print('  UPDATE messages SET processing_status = \'completed\'');
  print('  WHERE processing_status IN (\'processing\', \'queued\')');
  print('  AND deleted = 0');
  print('  AND type = \'functionCall\'');
  print('  AND uuid IN (SELECT tool_call_id FROM messages WHERE deleted = 0 AND role = \'tool\');');
}

String _formatTime(int? millis) {
  if (millis == null || millis == 0) return 'N/A';
  final dt = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
}
