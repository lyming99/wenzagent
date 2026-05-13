/// Skill 同步问题验证测试
///
/// 验证 skill 文件夹同步和 agent 加载 skill 时存在的潜在问题：
///   P1. 元数据先于文件同步完成，Agent 加载时文件不存在
///   P2. 跨设备同步时 folder_path 包含源设备绝对路径
///   P3. _unpackZip 存在 Zip Slip 路径穿越安全漏洞
///   P4. DataSyncManager 手动拼接 JSON 更新 config 有 bug
///   P5. _scanFolderSkills 与 _loadPersistedSkills 可能导致重复加载
///   P6. 本地复制相对路径计算不健壮
///   P7. 元数据保存与文件同步非原子操作
///   P8. 远端临时 ZIP 文件未清理
///   P9. ZIP 打包全量内存，大文件 OOM 风险
///   P10. FolderToolAdapter 缓存机制有设计缺陷
///   P11. 删除 skill 未清理文件
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

// ═══════════════════════════════════════════════════════════════
// 模拟 _unpackZip（来自 device_client.dart:1109-1130）
// ═══════════════════════════════════════════════════════════════

Future<void> unpackZipOriginal(String zipPath, String targetDir) async {
  final target = Directory(targetDir);
  if (await target.exists()) {
    await target.delete(recursive: true);
  }
  await target.create(recursive: true);

  final zipBytes = await File(zipPath).readAsBytes();
  final archive = ZipDecoder().decodeBytes(zipBytes);

  for (final file in archive) {
    final filePath =
        p.join(targetDir, file.name.replaceAll('/', Platform.pathSeparator));
    if (file.isFile) {
      final outFile = File(filePath);
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(file.content as List<int>);
    } else {
      await Directory(filePath).create(recursive: true);
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// 模拟 _packDirectoryToZip（来自 device_rpc_handler.dart:1490-1510）
// ═══════════════════════════════════════════════════════════════

Future<void> packDirectoryToZip(String dirPath, String zipPath) async {
  final archive = Archive();
  final dir = Directory(dirPath);

  await for (final entity in dir.list(recursive: true)) {
    if (entity is File) {
      final relative = entity.path
          .substring(dir.path.length + 1)
          .replaceAll('\\', '/');
      final bytes = await entity.readAsBytes();
      final file = ArchiveFile(relative, bytes.length, bytes);
      archive.addFile(file);
    }
  }

  final zipData = ZipEncoder().encode(archive);
  await File(zipPath).writeAsBytes(zipData!);
}

// ═══════════════════════════════════════════════════════════════
// 模拟 _extractFolderName（来自 controller.dart:529-531）
// ═══════════════════════════════════════════════════════════════

String extractFolderName(String path) {
  return path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;
}

// ═══════════════════════════════════════════════════════════════
// 模拟 DataSyncManager 更新 config（来自 data_sync_manager.dart:1084）
// ═══════════════════════════════════════════════════════════════

String buildConfigOriginal(String localPath) {
  return '{"folder_path": "${localPath.replaceAll('\\', '\\\\')}"}';
}

String buildConfigFixed(String localPath) {
  return jsonEncode({'folder_path': localPath});
}

// ═══════════════════════════════════════════════════════════════
// 模拟本地复制逻辑（来自 controller.dart:580-590）
// ═══════════════════════════════════════════════════════════════

Future<void> copyFolderOriginal(String sourceFolderPath, String localFolderPath) async {
  final sourceDir = Directory(sourceFolderPath);
  final localDir = Directory(localFolderPath);

  if (await sourceDir.exists()) {
    if (!await localDir.exists()) {
      await localDir.create(recursive: true);
    }

    await for (final entity in sourceDir.list(recursive: true)) {
      if (entity is File) {
        final relativePath = entity.path.substring(sourceDir.path.length + 1);
        final targetPath =
            '$localFolderPath${Platform.pathSeparator}$relativePath';
        await File(targetPath).parent.create(recursive: true);
        await entity.copy(targetPath);
      }
    }
  }
}

Future<void> copyFolderFixed(String sourceFolderPath, String localFolderPath) async {
  final sourceDir = Directory(sourceFolderPath);
  final localDir = Directory(localFolderPath);

  if (await sourceDir.exists()) {
    if (!await localDir.exists()) {
      await localDir.create(recursive: true);
    }

    await for (final entity in sourceDir.list(recursive: true)) {
      if (entity is File) {
        // 使用 p.relative 代替手动 substring
        final relativePath = p.relative(entity.path, from: sourceDir.path);
        final targetPath = p.join(localFolderPath, relativePath);
        await File(targetPath).parent.create(recursive: true);
        await entity.copy(targetPath);
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// 测试辅助方法
// ═══════════════════════════════════════════════════════════════

/// 创建测试用 skill 文件夹
Future<String> createTestSkillDir(String name, {List<String>? extraFiles}) async {
  final base = await Directory.systemTemp.createTemp('skill_test_$name');
  final dir = p.join(base.path, name);
  await Directory(dir).create(recursive: true);

  // 创建 SKILL.md
  await File(p.join(dir, 'SKILL.md')).writeAsString('# $name\nTest skill description.');

  // 创建 prompt 目录
  final promptDir = p.join(dir, 'prompt');
  await Directory(promptDir).create(recursive: true);
  await File(p.join(promptDir, 'translate.md')).writeAsString('Translate: {{input}}');

  // 创建 resources 目录
  final resDir = p.join(dir, 'resources');
  await Directory(resDir).create(recursive: true);
  await File(p.join(resDir, 'dict.csv')).writeAsString('hello,你好\nworld,世界');

  // 额外文件
  if (extraFiles != null) {
    for (final entry in extraFiles) {
      final sep = entry.indexOf('|');
      final filePath = sep > 0 ? entry.substring(0, sep) : entry;
      final content = sep > 0 ? entry.substring(sep + 1) : 'extra content';
      final fullPath = p.join(dir, filePath);
      await File(fullPath).parent.create(recursive: true);
      await File(fullPath).writeAsString(content);
    }
  }

  return dir;
}

/// 创建包含恶意路径穿越的 ZIP 文件
Future<String> createZipSlipArchive(String targetZipPath) async {
  final archive = Archive();

  // 正常文件
  archive.addFile(ArchiveFile('SKILL.md', 20, 'normal skill file'.codeUnits));

  // 恶意路径穿越文件
  final maliciousPath = '../../../etc/malicious.txt';
  archive.addFile(
      ArchiveFile(maliciousPath, 13, 'MALICIOUS_DATA'.codeUnits));

  final zipData = ZipEncoder().encode(archive);
  await File(targetZipPath).writeAsBytes(zipData!);
  return targetZipPath;
}

/// 创建包含绝对路径的 ZIP 文件（Windows Unix 均可穿越）
Future<String> createAbsoluteZipSlipArchive(String targetZipPath) async {
  final archive = Archive();

  // Unix 绝对路径
  archive.addFile(ArchiveFile('/etc/passwd', 14, 'root:x:0:0:'.codeUnits));

  final zipData = ZipEncoder().encode(archive);
  await File(targetZipPath).writeAsBytes(zipData!);
  return targetZipPath;
}

// ═══════════════════════════════════════════════════════════════
// 测试主体
// ═══════════════════════════════════════════════════════════════

void main() {
  group('P1. 元数据先于文件同步完成', () {
    test('模拟 Agent 加载 folder skill 时文件不存在', () async {
      // 模拟场景：元数据已保存到 DB，但文件还没同步完成
      final skillsDir = await Directory.systemTemp.createTemp('p1_skills_');
      final folderPath = p.join(skillsDir.path, 'translator');

      // 元数据中记录的路径
      final configJson = jsonEncode({'folder_path': folderPath});

      // 此时文件夹还不存在
      expect(await Directory(folderPath).exists(), isFalse,
          reason: '文件夹尚未同步，不应存在');

      // 解析 config 中的 folder_path
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      final resolvedPath = config['folder_path'] as String;

      // Agent 尝试读取 SKILL.md
      final skillMd = File(p.join(resolvedPath, 'SKILL.md'));
      expect(await skillMd.exists(), isFalse,
          reason: 'SKILL.md 不存在，Agent 加载应失败');

      // 清理
      await skillsDir.delete(recursive: true);
    });

    test('文件同步完成后 Agent 可正常加载', () async {
      final skillsDir = await Directory.systemTemp.createTemp('p1_skills_ok_');
      final folderPath = p.join(skillsDir.path, 'translator');
      await Directory(folderPath).create(recursive: true);
      await File(p.join(folderPath, 'SKILL.md'))
          .writeAsString('# Translator\nTranslate skill.');

      final configJson = jsonEncode({'folder_path': folderPath});
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      final resolvedPath = config['folder_path'] as String;

      final skillMd = File(p.join(resolvedPath, 'SKILL.md'));
      expect(await skillMd.exists(), isTrue);
      expect(await skillMd.readAsString(), contains('Translator'));

      await skillsDir.delete(recursive: true);
    });
  });

  group('P2. 跨设备 folder_path 绝对路径不兼容', () {
    test('设备 A 的绝对路径在设备 B 上不存在', () async {
      // 设备 A 的路径
      const deviceAPath = r'D:\data\skills\folder\translator';

      // 模拟设备 B 收到元数据
      final config = jsonEncode({'folder_path': deviceAPath});

      // 设备 B 解析路径
      final configMap = jsonDecode(config) as Map<String, dynamic>;
      final folderPath = configMap['folder_path'] as String;

      // 在设备 B 上检查（当前机器）
      // 如果当前不是设备 A，路径自然不存在
      final exists = await Directory(folderPath).exists();

      // 这个测试验证的是：绝对路径在不同设备上不可移植
      // 期望行为：应该使用 skillsDir/{folderName} 规范路径
      final folderName = extractFolderName(deviceAPath);
      expect(folderName, equals('translator'),
          reason: '应能从绝对路径提取 folderName');

      // 如果路径不存在，应该触发文件同步
      if (!exists) {
        // 模拟 DataSyncManager 的检测逻辑
        expect(exists, isFalse,
            reason: '绝对路径在另一台设备上应不存在，触发同步');
      }
    });

    test('不同操作系统的路径分隔符不兼容', () async {
      // Windows 路径
      const winPath = r'D:\data\skills\folder\translator';
      // macOS/Linux 路径
      const unixPath = '/home/user/data/skills/folder/translator';

      // 两个路径提取的 folderName 应该一致
      expect(extractFolderName(winPath), equals('translator'));
      expect(extractFolderName(unixPath), equals('translator'));

      // 但路径本身不兼容
      expect(winPath.contains('\\'), isTrue);
      expect(unixPath.contains('/'), isTrue);
    });
  });

  group('P3. Zip Slip 路径穿越安全漏洞', () {
    test('恶意 ZIP 包含 ../ 路径穿越，原始 _unpackZip 会写入目标目录外', () async {
      final targetDir = await Directory.systemTemp.createTemp('p3_zipslip_');
      final zipPath = p.join(targetDir.path, 'malicious.zip');

      await createZipSlipArchive(zipPath);

      // 验证 ZIP 中确实包含恶意路径
      final zipBytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(zipBytes);
      final names = archive.map((f) => f.name).toList();
      expect(names.any((n) => n.contains('..')), isTrue,
          reason: 'ZIP 中应包含路径穿越条目');

      // 创建解压目标目录
      final unpackDir = p.join(targetDir.path, 'unpack');
      await Directory(unpackDir).create(recursive: true);

      // 原始 _unpackZip 会将恶意文件写到目标目录外
      // 验证：恶意文件路径会逃逸
      for (final file in archive) {
        if (file.isFile) {
          final resolvedPath = p.join(unpackDir,
              file.name.replaceAll('/', Platform.pathSeparator));
          final normalized = p.normalize(resolvedPath);
          final normalizedTarget = p.normalize(unpackDir);

          // 检查路径是否在目标目录内
          final isWithin = normalized.startsWith('$normalizedTarget${Platform.pathSeparator}');
          if (file.name.contains('..')) {
            expect(isWithin, isFalse,
                reason: '路径 "${file.name}" 解析后 "$normalized" 应逃逸出 "$normalizedTarget"');
          }
        }
      }

      await targetDir.delete(recursive: true);
    });

    test('修复后的 unpackZip 应拒绝路径穿越', () async {
      final targetDir = await Directory.systemTemp.createTemp('p3_safe_');
      final zipPath = p.join(targetDir.path, 'malicious.zip');

      await createZipSlipArchive(zipPath);

      final unpackDir = p.join(targetDir.path, 'unpack');
      await Directory(unpackDir).create(recursive: true);

      // 修复后的解压逻辑
      final zipBytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(zipBytes);

      int rejectedCount = 0;
      for (final file in archive) {
        final filePath =
            p.join(unpackDir, file.name.replaceAll('/', Platform.pathSeparator));
        final normalizedPath = p.normalize(filePath);
        final normalizedTarget = p.normalize(unpackDir);

        // 安全检查：路径必须在目标目录内
        if (!normalizedPath.startsWith('$normalizedTarget${Platform.pathSeparator}') &&
            normalizedPath != normalizedTarget) {
          rejectedCount++;
          continue; // 跳过恶意路径
        }

        if (file.isFile) {
          final outFile = File(normalizedPath);
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        }
      }

      expect(rejectedCount, greaterThan(0),
          reason: '应拒绝路径穿越条目');

      // 正常文件应被解压
      final skillMd = File(p.join(unpackDir, 'SKILL.md'));
      expect(await skillMd.exists(), isTrue);

      await targetDir.delete(recursive: true);
    });
  });

  group('P4. DataSyncManager 手动拼接 JSON 更新 config', () {
    test('原始拼接：Windows 路径转义正确', () {
      const winPath = r'D:\data\skills\folder\translator';
      final config = buildConfigOriginal(winPath);
      // 应该能正确解析
      final parsed = jsonDecode(config) as Map<String, dynamic>;
      expect(parsed['folder_path'], equals(winPath));
    });

    test('原始拼接：路径包含双引号导致 JSON 无效', () {
      // 极端但可能的路径
      const pathWithQuote = r'D:\data\skills"test\translator';
      final config = buildConfigOriginal(pathWithQuote);
      // 手动拼接的 JSON 中双引号未转义，解析会失败
      expect(() => jsonDecode(config), throwsA(isA<FormatException>()),
          reason: '路径中的双引号导致 JSON 无效');
    });

    test('原始拼接：丢失原始 config 中的其他字段', () {
      const winPath = r'D:\data\skills\folder\translator';
      // 原始 config 可能有其他字段
      const originalConfig = '{"folder_path": "/old/path", "custom_param": "value123"}';
      final originalMap = jsonDecode(originalConfig) as Map<String, dynamic>;

      // 原始方法只生成 folder_path，丢失了 custom_param
      final newConfig = buildConfigOriginal(winPath);
      final newMap = jsonDecode(newConfig) as Map<String, dynamic>;

      expect(newMap.containsKey('custom_param'), isFalse,
          reason: '原始方法丢失了其他字段');
    });

    test('修复后：jsonEncode 正确处理特殊字符', () {
      const pathWithQuote = r'D:\data\skills"test\translator';
      final config = buildConfigFixed(pathWithQuote);
      final parsed = jsonDecode(config) as Map<String, dynamic>;
      expect(parsed['folder_path'], equals(pathWithQuote));
    });

    test('修复后：可保留原始 config 中的其他字段', () {
      const winPath = r'D:\data\skills\folder\translator';
      const originalConfig = '{"folder_path": "/old/path", "custom_param": "value123"}';
      final originalMap = jsonDecode(originalConfig) as Map<String, dynamic>;

      // 修复方法：合并而非替换
      final newConfig = jsonEncode({
        ...originalMap,
        'folder_path': winPath,
      });
      final newMap = jsonDecode(newConfig) as Map<String, dynamic>;

      expect(newMap['folder_path'], equals(winPath));
      expect(newMap['custom_param'], equals('value123'));
    });
  });

  group('P5. Folder Skill 重复加载检测', () {
    test('DB 加载和目录扫描可能加载同一个 skill', () async {
      final skillsDir = await Directory.systemTemp.createTemp('p5_skills_');
      final translatorDir = p.join(skillsDir.path, 'translator');
      await Directory(translatorDir).create(recursive: true);
      await File(p.join(translatorDir, 'SKILL.md'))
          .writeAsString('# Translator');

      // 模拟 _loadPersistedSkills 加载的 skill
      final persistedSkills = <String, String>{};
      persistedSkills['skill-uuid-001'] = translatorDir;

      // 模拟 _scanFolderSkills 扫描到的目录
      final scannedDirs = <String>[];
      await for (final entity in Directory(skillsDir.path).list()) {
        if (entity is Directory) {
          final hasSkillMd = await File(
                  p.join(entity.path, 'SKILL.md'))
              .exists();
          if (hasSkillMd) {
            scannedDirs.add(entity.path);
          }
        }
      }

      // 两者都发现了 translator
      expect(persistedSkills.values, contains(translatorDir));
      expect(scannedDirs, contains(translatorDir));

      // 如果不去重，会注册两次
      final allPaths = [...persistedSkills.values, ...scannedDirs];
      final translatorCount =
          allPaths.where((p) => p.contains('translator')).length;
      expect(translatorCount, equals(2),
          reason: '同一个 skill 被发现两次，需要去重逻辑');

      await skillsDir.delete(recursive: true);
    });
  });

  group('P6. 本地复制相对路径计算', () {
    test('原始 substring：路径不以分隔符结尾时正常工作', () async {
      final sourceDir = await Directory.systemTemp.createTemp('p6_src_');
      final targetDir = await Directory.systemTemp.createTemp('p6_dst_');

      // 创建源文件
      final subDir = p.join(sourceDir.path, 'sub');
      await Directory(subDir).create(recursive: true);
      await File(p.join(subDir, 'file.txt')).writeAsString('hello');

      // 原始方法
      final sourceFile = File(p.join(subDir, 'file.txt'));
      final relativePath =
          sourceFile.path.substring(sourceDir.path.length + 1);
      final targetPath = p.join(targetDir.path, relativePath);

      expect(relativePath, equals('sub${Platform.pathSeparator}file.txt'));
      expect(p.join(targetDir.path, relativePath), equals(targetPath));

      await sourceDir.delete(recursive: true);
      await targetDir.delete(recursive: true);
    });

    test('原始 substring：路径以分隔符结尾时相对路径错误', () async {
      final sourceDir = await Directory.systemTemp.createTemp('p6_src_sep_');

      // 创建源文件
      await File(p.join(sourceDir.path, 'file.txt')).writeAsString('hello');

      // 模拟路径以分隔符结尾的情况
      final sourcePathWithSep = '${sourceDir.path}${Platform.pathSeparator}';
      final sourceFile = File(p.join(sourceDir.path, 'file.txt'));

      // 原始方法用带分隔符的路径计算
      final relativePath =
          sourceFile.path.substring(sourcePathWithSep.length + 1);
      // 由于 sourcePathWithSep 已以分隔符结尾，+1 会导致偏移错误
      // "C:\...\file.txt".substring(len("C:\...\") + 1)
      // 结果会少一个字符
      expect(relativePath, isNot(equals('file.txt')),
          reason: '路径以分隔符结尾时，substring 计算偏移错误');

      await sourceDir.delete(recursive: true);
    });

    test('修复后 p.relative 正确处理各种情况', () async {
      final sourceDir = await Directory.systemTemp.createTemp('p6_fix_');
      final subDir = p.join(sourceDir.path, 'sub');
      await Directory(subDir).create(recursive: true);
      await File(p.join(subDir, 'file.txt')).writeAsString('hello');

      final sourceFile = File(p.join(subDir, 'file.txt'));

      // 修复方法：使用 p.relative
      final relativePath = p.relative(sourceFile.path, from: sourceDir.path);
      expect(relativePath,
          equals('sub${Platform.pathSeparator}file.txt'));

      // 即使源路径以分隔符结尾也能正确处理
      final sourcePathWithSep = '${sourceDir.path}${Platform.pathSeparator}';
      final relativePath2 = p.relative(sourceFile.path, from: sourcePathWithSep);
      // p.relative 应该能正确处理
      expect(relativePath2.contains('file.txt'), isTrue);

      await sourceDir.delete(recursive: true);
    });
  });

  group('P7. 元数据保存与文件同步非原子操作', () {
    test('模拟广播先于文件同步的场景', () async {
      final skillsDir = await Directory.systemTemp.createTemp('p7_atomic_');
      final folderPath = p.join(skillsDir.path, 'translator');

      // 步骤 1：保存元数据（folder_path 指向尚不存在的路径）
      final config = jsonEncode({'folder_path': folderPath});
      final savedMetadata = {'name': 'translator', 'config': config};
      expect(savedMetadata['config'], isNotNull);

      // 步骤 2：广播元数据（此时文件尚未同步）
      final broadcastData = Map<String, dynamic>.from(savedMetadata);
      expect(broadcastData['config'], isNotNull);

      // 接收方收到元数据，检查文件
      final receivedConfig =
          jsonDecode(broadcastData['config'] as String) as Map<String, dynamic>;
      final receivedPath = receivedConfig['folder_path'] as String;
      expect(await Directory(receivedPath).exists(), isFalse,
          reason: '接收方收到元数据时，文件尚未同步');

      // 步骤 3：文件同步（异步，可能失败）
      try {
        await Directory(folderPath).create(recursive: true);
        await File(p.join(folderPath, 'SKILL.md'))
            .writeAsString('# Translator');
      } catch (e) {
        // 文件同步失败，但元数据已广播
        // 接收方会持有一个指向不存在目录的 skill
      }

      // 如果同步成功
      expect(await Directory(folderPath).exists(), isTrue);

      await skillsDir.delete(recursive: true);
    });
  });

  group('P8. 远端临时 ZIP 文件未清理', () {
    test('打包后临时 ZIP 文件残留', () async {
      final skillDir = await createTestSkillDir('tmp_test');
      final tempZipDir = await Directory.systemTemp.createTemp('p8_pack_');
      final zipPath =
          p.join(tempZipDir.path, 'skill-${const Uuid().v4().substring(0, 8)}.zip');

      // 模拟打包
      await packDirectoryToZip(skillDir, zipPath);

      // ZIP 文件存在
      expect(await File(zipPath).exists(), isTrue);
      final zipSize = await File(zipPath).length();
      expect(zipSize, greaterThan(0));

      // 模拟下载完成后，远端没有清理机制
      // ZIP 文件仍然存在
      expect(await File(zipPath).exists(), isTrue,
          reason: '远端临时 ZIP 文件未被清理');

      // 清理
      await tempZipDir.delete(recursive: true);
      final skillBase =
          Directory(skillDir).parent;
      await skillBase.delete(recursive: true);
    });
  });

  group('P9. ZIP 打包全量内存', () {
    test('大文件打包时内存占用与文件大小成正比', () async {
      final skillDir = await createTestSkillDir('bigskill', extraFiles: [
        'resources/large.bin|${'X' * 500000}',
      ]);

      final tempZipDir = await Directory.systemTemp.createTemp('p9_big_');
      final zipPath = p.join(tempZipDir.path, 'bigskill.zip');

      // 打包
      await packDirectoryToZip(skillDir, zipPath);

      final zipSize = await File(zipPath).length();
      // 大文件被压缩后仍应有一定大小
      expect(zipSize, greaterThan(1000),
          reason: '500KB 数据压缩后应大于 1KB');

      // 验证解压后文件内容正确
      final unpackDir = p.join(tempZipDir.path, 'unpacked');
      await unpackZipOriginal(zipPath, unpackDir);

      final bigFile = File(p.join(unpackDir, 'resources', 'large.bin'));
      expect(await bigFile.exists(), isTrue);
      expect((await bigFile.readAsString()).length, equals(500000));

      await tempZipDir.delete(recursive: true);
      final skillBase = Directory(skillDir).parent;
      await skillBase.delete(recursive: true);
    });
  });

  group('P11. _extractFolderName 边界情况', () {
    test('正常路径提取', () {
      expect(extractFolderName(r'D:\data\skills\translator'), equals('translator'));
      expect(extractFolderName('/home/user/skills/translator'), equals('translator'));
      expect(extractFolderName('translator'), equals('translator'));
    });

    test('路径以分隔符结尾', () {
      expect(extractFolderName(r'D:\data\skills\translator\'), equals('translator'));
      expect(extractFolderName('/home/user/skills/translator/'), equals('translator'));
    });

    test('根目录路径提取可能不符合预期', () {
      // 路径为 D:\skills\ 时，应返回 skills 而非空
      expect(extractFolderName(r'D:\skills\'), equals('skills'),
          reason: '根目录路径返回最后一级目录名');
    });

    test('使用 p.basename 更健壮', () {
      // p.basename 的行为
      expect(p.basename(r'D:\data\skills\translator'), equals('translator'));
      expect(p.basename('/home/user/skills/translator'), equals('translator'));
      expect(p.basename(r'D:\data\skills\translator\'), equals('translator'));
      expect(p.basename('translator'), equals('translator'));
    });
  });

  group('P11b. 删除 skill 未清理文件', () {
    test('删除 skill 元数据后文件仍残留', () async {
      final skillsDir = await Directory.systemTemp.createTemp('p11_del_');
      final folderPath = p.join(skillsDir.path, 'translator');
      await Directory(folderPath).create(recursive: true);
      await File(p.join(folderPath, 'SKILL.md')).writeAsString('# Translator');
      await File(p.join(folderPath, 'data.bin')).writeAsString('x' * 10000);

      // 模拟删除 skill 元数据（软删除）
      final config = jsonEncode({'folder_path': folderPath});
      final skillMetadata = {
        'uuid': 'skill-001',
        'name': 'translator',
        'config': config,
        'deleted': 1,
      };

      // 元数据标记为已删除
      expect(skillMetadata['deleted'], equals(1));

      // 但文件仍然存在
      expect(await Directory(folderPath).exists(), isTrue);
      expect(await File(p.join(folderPath, 'SKILL.md')).exists(), isTrue);
      expect(await File(p.join(folderPath, 'data.bin')).exists(), isTrue);

      // 文件占用的空间未被释放
      final fileSize = await File(p.join(folderPath, 'data.bin')).length();
      expect(fileSize, equals(10000),
          reason: '文件仍残留，空间未释放');

      await skillsDir.delete(recursive: true);
    });
  });

  group('端到端：完整同步流程验证', () {
    test('打包 → 传输 → 解压 → 验证文件完整性', () async {
      // 1. 创建源 skill 文件夹
      final skillDir = await createTestSkillDir('e2e_translator', extraFiles: [
        'resources/extra.txt|extra content',
        'prompt/advanced.md|Advanced: {{text}}',
      ]);

      // 2. 打包为 ZIP
      final tempDir = await Directory.systemTemp.createTemp('e2e_sync_');
      final zipPath = p.join(tempDir.path, 'e2e_translator.zip');
      await packDirectoryToZip(skillDir, zipPath);

      expect(await File(zipPath).exists(), isTrue);

      // 3. 解压到目标目录（模拟远端设备）
      final targetSkillsDir = p.join(tempDir.path, 'skills', 'folder');
      await Directory(targetSkillsDir).create(recursive: true);
      await unpackZipOriginal(zipPath, p.join(targetSkillsDir, 'e2e_translator'));

      // 4. 验证文件结构
      final targetDir = p.join(targetSkillsDir, 'e2e_translator');

      // SKILL.md
      final skillMd = File(p.join(targetDir, 'SKILL.md'));
      expect(await skillMd.exists(), isTrue, reason: 'SKILL.md 应存在');
      expect(await skillMd.readAsString(), contains('e2e_translator'));

      // prompt/translate.md
      final translateMd = File(p.join(targetDir, 'prompt', 'translate.md'));
      expect(await translateMd.exists(), isTrue);
      expect(await translateMd.readAsString(), contains('{{input}}'));

      // prompt/advanced.md
      final advancedMd = File(p.join(targetDir, 'prompt', 'advanced.md'));
      expect(await advancedMd.exists(), isTrue);
      expect(await advancedMd.readAsString(), contains('Advanced'));

      // resources/dict.csv
      final dictCsv = File(p.join(targetDir, 'resources', 'dict.csv'));
      expect(await dictCsv.exists(), isTrue);
      expect(await dictCsv.readAsString(), contains('hello,你好'));

      // resources/extra.txt
      final extraTxt = File(p.join(targetDir, 'resources', 'extra.txt'));
      expect(await extraTxt.exists(), isTrue);
      expect(await extraTxt.readAsString(), equals('extra content'));

      // 5. 清理
      await tempDir.delete(recursive: true);
      final skillBase = Directory(skillDir).parent;
      await skillBase.delete(recursive: true);
    });

    test('空文件夹打包解压后保持空目录结构', () async {
      final emptyDir = await Directory.systemTemp.createTemp('e2e_empty_');
      final skillDir = p.join(emptyDir.path, 'empty_skill');
      await Directory(skillDir).create(recursive: true);
      await File(p.join(skillDir, 'SKILL.md')).writeAsString('# Empty');

      // 只有一个文件的简单 skill
      final tempDir = await Directory.systemTemp.createTemp('e2e_empty_zip_');
      final zipPath = p.join(tempDir.path, 'empty.zip');
      await packDirectoryToZip(skillDir, zipPath);

      final targetDir = p.join(tempDir.path, 'unpacked', 'empty_skill');
      await unpackZipOriginal(zipPath, targetDir);

      final skillMd = File(p.join(targetDir, 'SKILL.md'));
      expect(await skillMd.exists(), isTrue);

      await tempDir.delete(recursive: true);
      await emptyDir.delete(recursive: true);
    });

    test('中文文件名和内容正确传输', () async {
      final skillDir = await createTestSkillDir('中文技能', extraFiles: [
        'resources/说明.txt|这是中文说明文件',
      ]);

      final tempDir = await Directory.systemTemp.createTemp('e2e_cn_');
      final zipPath = p.join(tempDir.path, 'cn.zip');
      await packDirectoryToZip(skillDir, zipPath);

      final targetDir = p.join(tempDir.path, 'unpacked', '中文技能');
      await unpackZipOriginal(zipPath, targetDir);

      final skillMd = File(p.join(targetDir, 'SKILL.md'));
      expect(await skillMd.exists(), isTrue);
      expect(await skillMd.readAsString(), contains('中文技能'));

      final readme = File(p.join(targetDir, 'resources', '说明.txt'));
      expect(await readme.exists(), isTrue);
      expect(await readme.readAsString(), equals('这是中文说明文件'));

      await tempDir.delete(recursive: true);
      final skillBase = Directory(skillDir).parent;
      await skillBase.delete(recursive: true);
    });
  });

  group('路径规范化测试', () {
    test('不同来源的路径应规范化为统一的 skillsDir/{name} 格式', () async {
      final skillsDir = await Directory.systemTemp.createTemp('path_norm_');

      // 模拟各种来源路径
      final sourcePaths = [
        p.join('D:', 'data', 'skills', 'translator'),
        p.join('C:', 'Users', 'dev', 'skills', 'translator'),
        p.join(skillsDir.path, 'translator'), // 已在 skillsDir 中
      ];

      for (final sourcePath in sourcePaths) {
        // 规范化：提取 folderName，拼接到 skillsDir
        final folderName = p.basename(sourcePath);
        final normalizedPath = p.join(skillsDir.path, folderName);

        expect(folderName, equals('translator'));
        expect(normalizedPath, equals(p.join(skillsDir.path, 'translator')));
      }

      await skillsDir.delete(recursive: true);
    });
  });
}
