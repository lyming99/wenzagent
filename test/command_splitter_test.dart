import 'package:test/test.dart';
import 'package:wenzagent/src/agent/tool/command_splitter.dart';
import 'package:wenzagent/src/agent/tool/permission_rule.dart';

void main() {
  // ===== ShellTokenizer =====

  group('ShellTokenizer', () {
    test('简单命令', () {
      expect(
        ShellTokenizer.tokenize('ls -la'),
        equals(['ls', '-la']),
      );
    });

    test('复合命令 &&', () {
      expect(
        ShellTokenizer.tokenize('cd /tmp && rm -rf /'),
        equals(['cd', '/tmp', '&&', 'rm', '-rf', '/']),
      );
    });

    test('单个 & 作为分隔符', () {
      expect(
        ShellTokenizer.tokenize('cd xxx & rm -rf *'),
        equals(['cd', 'xxx', '&', 'rm', '-rf', '*']),
      );
    });

    test('& 和 && 共存', () {
      expect(
        ShellTokenizer.tokenize('cd /tmp & ls && echo done'),
        equals(['cd', '/tmp', '&', 'ls', '&&', 'echo', 'done']),
      );
    });

    test('复合命令 ||', () {
      expect(
        ShellTokenizer.tokenize('npm install || yarn install'),
        equals(['npm', 'install', '||', 'yarn', 'install']),
      );
    });

    test('复合命令 ;', () {
      expect(
        ShellTokenizer.tokenize('echo hello ; echo world'),
        equals(['echo', 'hello', ';', 'echo', 'world']),
      );
    });

    test('管道 |', () {
      expect(
        ShellTokenizer.tokenize('cat file.txt | grep error | wc -l'),
        equals(['cat', 'file.txt', '|', 'grep', 'error', '|', 'wc', '-l']),
      );
    });

    test('三段复合', () {
      expect(
        ShellTokenizer.tokenize(
            'git add . && git commit -m "init" && git push'),
        equals([
          'git',
          'add',
          '.',
          '&&',
          'git',
          'commit',
          '-m',
          'init',
          '&&',
          'git',
          'push'
        ]),
      );
    });

    test('双引号保护', () {
      expect(
        ShellTokenizer.tokenize('echo "hello world"'),
        equals(['echo', 'hello world']),
      );
    });

    test('单引号保护', () {
      expect(
        ShellTokenizer.tokenize("echo 'hello world'"),
        equals(['echo', 'hello world']),
      );
    });

    test('引号内的操作符不是分隔符', () {
      expect(
        ShellTokenizer.tokenize('echo "a && b | c ; d" && ls'),
        equals(['echo', 'a && b | c ; d', '&&', 'ls']),
      );
    });

    test('反斜杠转义', () {
      expect(
        ShellTokenizer.tokenize(r'echo hello\ world'),
        equals(['echo', 'hello world']),
      );
    });

    test('重定向 >', () {
      expect(
        ShellTokenizer.tokenize('echo hello > output.txt'),
        equals(['echo', 'hello', '>', 'output.txt']),
      );
    });

    test('追加重定向 >>', () {
      expect(
        ShellTokenizer.tokenize('echo hello >> output.txt'),
        equals(['echo', 'hello', '>>', 'output.txt']),
      );
    });

    test('stderr 重定向 2>', () {
      expect(
        ShellTokenizer.tokenize('cmd 2> error.log'),
        equals(['cmd', '2>', 'error.log']),
      );
    });

    test('空字符串', () {
      expect(ShellTokenizer.tokenize(''), equals([]));
    });

    test('纯空白', () {
      expect(ShellTokenizer.tokenize('   '), equals([]));
    });

    test('多余空白', () {
      expect(
        ShellTokenizer.tokenize('  ls   -la  '),
        equals(['ls', '-la']),
      );
    });
  });

  // ===== CommandSplitter =====

  group('CommandSplitter', () {
    test('简单命令不拆分', () {
      expect(
        CommandSplitter.split('ls -la'),
        equals(['ls -la']),
      );
    });

    test('两段复合 &&', () {
      expect(
        CommandSplitter.split('cd /tmp && rm -rf /'),
        equals(['cd /tmp', 'rm -rf /']),
      );
    });

    test('三段复合', () {
      expect(
        CommandSplitter.split(
            'git add . && git commit -m "init" && git push'),
        equals(['git add .', 'git commit -m init', 'git push']),
      );
    });

    test('管道拆分', () {
      expect(
        CommandSplitter.split('cat file.txt | grep error | wc -l'),
        equals(['cat file.txt', 'grep error', 'wc -l']),
      );
    });

    test('混合分隔符', () {
      expect(
        CommandSplitter.split('cd /tmp ; ls -la && cat file | grep ok'),
        equals(['cd /tmp', 'ls -la', 'cat file', 'grep ok']),
      );
    });

    test('单个 & 拆分', () {
      expect(
        CommandSplitter.split('cd xxx & rm -rf *'),
        equals(['cd xxx', 'rm -rf *']),
      );
    });

    test('引号保护不拆分', () {
      expect(
        CommandSplitter.split('echo "hello && world" && ls'),
        equals(['echo hello && world', 'ls']),
      );
    });

    test('空字符串', () {
      expect(CommandSplitter.split(''), equals([]));
    });

    test('提取命令名', () {
      expect(
        CommandSplitter.extractCommandNames('cd /tmp && rm -rf / && ls'),
        equals(['cd', 'rm', 'ls']),
      );
    });

    test('isCompound - 复合命令', () {
      expect(CommandSplitter.isCompound('cd /tmp && rm -rf /'), isTrue);
      expect(CommandSplitter.isCompound('cat a | grep b'), isTrue);
      expect(CommandSplitter.isCompound('a ; b'), isTrue);
      expect(CommandSplitter.isCompound('cd xxx & rm -rf *'), isTrue);
    });

    test('isCompound - 单条命令', () {
      expect(CommandSplitter.isCompound('ls -la'), isFalse);
      expect(CommandSplitter.isCompound('git commit -m "msg"'), isFalse);
      expect(CommandSplitter.isCompound(''), isFalse);
    });

    test('isCompound - 引号内的操作符不算', () {
      expect(CommandSplitter.isCompound('echo "a && b"'), isFalse);
    });
  });

  // ===== 权限规则集成测试 =====

  group('PermissionRule 复合命令匹配', () {
    test('黑名单匹配复合命令中的子命令', () {
      final rule = PermissionRule(
        tool: 'command_execute',
        arg: 'command',
        pattern: r'rm\s+-rf.*',
        mode: PermissionMatchMode.regex,
      );

      // 单条命令匹配
      expect(rule.matches('command_execute', {'command': 'rm -rf /'}), isTrue);

      // 复合命令中包含 rm -rf
      expect(
        rule.matches(
            'command_execute', {'command': 'cd /tmp && rm -rf /'}),
        isTrue,
      );

      // 复合命令中不包含 rm -rf
      expect(
        rule.matches(
            'command_execute', {'command': 'cd /tmp && ls -la'}),
        isFalse,
      );
    });

    test('白名单匹配复合命令中的所有子命令', () {
      final rule = PermissionRule(
        tool: 'command_execute',
        arg: 'command',
        pattern: r'git.*',
        mode: PermissionMatchMode.regex,
      );

      // 所有子命令都是 git
      expect(
        rule.matches('command_execute',
            {'command': 'git add . && git commit -m "x"'}),
        isTrue,
      );

      // 只有部分是 git（但 matches 是单条规则，只检查是否命中任一子命令）
      expect(
        rule.matches('command_execute',
            {'command': 'git add . && ls -la'}),
        isTrue, // git add . 命中
      );
    });

    test('非命令类型不受影响', () {
      final rule = PermissionRule(
        tool: 'file_write',
        arg: 'path',
        pattern: r'/workspace/.*',
        mode: PermissionMatchMode.regex,
      );

      expect(
        rule.matches('file_write', {'path': '/workspace/test.dart'}),
        isTrue,
      );
    });
  });

  group('PermissionConfig 复合命令判定', () {
    test('黑名单命中任一子命令 → deny', () {
      final config = PermissionConfig(
        blacklist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'rm\s+-rf.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      expect(
        config.evaluate(
            'command_execute', {'command': 'cd /tmp && rm -rf /'}),
        equals(PermissionVerdict.deny),
      );
    });

    test('所有子命令在白名单 → allow', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'git.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      expect(
        config.evaluate('command_execute', {
          'command': 'git add . && git commit -m "x" && git push'
        }),
        equals(PermissionVerdict.allow),
      );
    });

    test('部分子命令不在白名单 → ask', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'git.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      expect(
        config.evaluate('command_execute',
            {'command': 'git add . && ls -la'}),
        equals(PermissionVerdict.ask),
      );
    });

    test('黑名单优先于白名单', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'git.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
        blacklist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'git\s+push.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      // git push 在黑名单中，即使 git.* 在白名单中也要拒绝
      expect(
        config.evaluate(
            'command_execute', {'command': 'git add . && git push'}),
        equals(PermissionVerdict.deny),
      );
    });

    test('单条命令不受影响', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'git.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      expect(
        config.evaluate('command_execute', {'command': 'git status'}),
        equals(PermissionVerdict.allow),
      );
    });

    test('非命令类型不受影响', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'file_write',
            arg: 'path',
            pattern: r'/workspace/.*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      expect(
        config.evaluate('file_write', {'path': '/workspace/test.dart'}),
        equals(PermissionVerdict.allow),
      );
    });

    test('管道中部分命令不在白名单 → ask', () {
      final config = PermissionConfig(
        whitelist: [
          PermissionRule(
            tool: 'command_execute',
            arg: 'command',
            pattern: r'(ls|cat|grep).*',
            mode: PermissionMatchMode.regex,
          ),
        ],
      );

      // wc 不在白名单
      expect(
        config.evaluate('command_execute',
            {'command': 'cat file | grep error | wc -l'}),
        equals(PermissionVerdict.ask),
      );
    });
  });
}
