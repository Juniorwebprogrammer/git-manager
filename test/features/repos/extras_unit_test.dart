import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_manager/core/git/git_runner.dart';
import 'package:git_manager/core/system/signing_keys.dart';
import 'package:git_manager/core/system/system_launcher.dart';
import 'package:git_manager/features/repos/data/parsers/git_parsers.dart';
import 'package:git_manager/features/repos/domain/entities/repo_extras.dart';

void main() {
  group('SystemLauncher', () {
    SystemLauncher launcher(
      Set<String> installed, {
      String os = 'linux',
      Map<String, String> env = const {},
      List<LaunchCommand>? started,
    }) =>
        SystemLauncher(
          exists: (e) async => installed.contains(e),
          start: (c) async => started?.add(c),
          operatingSystem: os,
          environment: env,
          resolveLink: (_) async => '/usr/bin/ptyxis',
        );

    test('x-terminal-emulator uses the arguments of the real terminal (ptyxis)', () async {
      final cmd = await launcher({'x-terminal-emulator'}).terminalCommand('/repo');
      expect(cmd!.executable, 'x-terminal-emulator');
      expect(cmd.arguments, ['--new-window', '-d', '/repo']);
      expect(cmd.workingDirectory, '/repo');
    });

    test(r'$TERMINAL wins, then known terminals, else null', () async {
      expect((await launcher({'kitty', 'konsole'}, env: {'TERMINAL': 'kitty'}).terminalCommand('/r'))!.arguments,
          ['--directory', '/r']);
      expect((await launcher({'konsole'}).terminalCommand('/r'))!.arguments, ['--workdir', '/r']);
      expect(await launcher({}).terminalCommand('/r'), isNull);
    });

    test('Windows and macOS', () async {
      expect((await launcher({'wt'}, os: 'windows').terminalCommand(r'C:\r'))!.toString(), r'wt -d C:\r');
      expect((await launcher({}, os: 'windows').terminalCommand(r'C:\r'))!.executable, 'cmd.exe');
      expect((await launcher({}, os: 'macos').terminalCommand('/r'))!.toString(), 'open -a Terminal /r');
    });

    test('opens files in VS Code at a line', () async {
      final started = <LaunchCommand>[];
      final l = launcher({'code'}, started: started);
      expect(await l.openInEditor('/repo/lib/main.dart', line: 12), 'VS Code');
      expect(started.single.toString(), 'code -g /repo/lib/main.dart:12');
      expect(await l.openFolderInEditor('/repo'), isTrue);
      expect(await launcher({}).openFolderInEditor('/repo'), isFalse);
    });
  });

  test('conventional summary and commit template', () {
    expect(composeConventionalSummary(summary: ' add login '), 'add login');
    expect(composeConventionalSummary(type: 'feat', summary: 'add login'), 'feat: add login');
    expect(composeConventionalSummary(type: 'fix', scope: 'ui', breaking: true, summary: 'x'), 'fix(ui)!: x');
    expect(cleanCommitTemplate('# comment\nWhy:\n  # indented comment\nRefs:\n'), 'Why:\nRefs:');
  });

  test('parseBlamePorcelain groups commits and keeps summaries', () {
    const a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const z = '0000000000000000000000000000000000000000';
    const out = '$a 1 1 2\nauthor Ana\nauthor-time 1700000000\nsummary First\nfilename f\n\tline one\n'
        '$a 2 2\n\tline two\n'
        '$z 3 3 1\nauthor Not Committed Yet\nauthor-time 1800000000\nsummary Version of f from f\nfilename f\n\tnew\n';
    final lines = parseBlamePorcelain(out);
    expect(lines.map((l) => l.text), ['line one', 'line two', 'new']);
    expect(lines[1].author, 'Ana');
    expect(lines[1].summary, 'First');
    expect(lines[1].number, 2);
    expect(lines[2].isUncommitted, isTrue);
  });

  test('parseWorktrees skips the current folder', () {
    const out = 'worktree /home/me/app\nHEAD abc\nbranch refs/heads/main\n\n'
        'worktree /home/me/app-ui\nHEAD def\nbranch refs/heads/ui-rebase\n\n'
        'worktree /home/me/app-detached\nHEAD 123\ndetached\n';
    expect(parseWorktrees(out, '/home/me/app'), {'ui-rebase': '/home/me/app-ui'});
  });

  test('friendlyGitError explains worktree and config problems', () {
    expect(
      friendlyGitError("fatal: 'ui-rebase' is already used by worktree at '/home/me/app-ui'"),
      allOf(contains('already open in another folder'), contains('/home/me/app-ui'), contains('Remove worktree')),
    );
    expect(
      friendlyGitError("error: invalid value for 'gpg.format': ''\n"
          "fatal: bad config variable 'gpg.format' in file '/home/me/.gitconfig' at line 6"),
      allOf(contains('invalid value for "gpg.format"'), contains('line 6'), contains('openpgp')),
    );
    expect(friendlyGitError('fatal: something else'), 'fatal: something else');
  });

  group('SigningKeys global config check', () {
    late Directory tmp;
    late SigningKeys keys;
    late File global;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('gm_sign_');
      global = File('${tmp.path}/global.gitconfig');
      keys = SigningKeys(GitRunner(environment: {'GIT_CONFIG_GLOBAL': global.path}));
    });
    tearDown(() => tmp.delete(recursive: true));

    test('detects and fixes an empty gpg.format', () async {
      await global.writeAsString('[user]\n\tname = Me\n\tsigningKey = \n[gpg]\n\tformat = \n\tprogram = gpg\n');
      expect(await keys.globalConfigBroken(), isTrue);
      await keys.fixGlobalConfig();
      expect(await keys.globalConfigBroken(), isFalse);
      final text = await global.readAsString();
      expect(text, isNot(contains('format')));
      expect(text, isNot(contains('signingKey')));
      expect(text, contains('name = Me'));
      expect(text, contains('program = gpg'));
    });

    test('a valid or missing gpg.format is fine', () async {
      await global.writeAsString('[gpg]\n\tformat = ssh\n');
      expect(await keys.globalConfigBroken(), isFalse);
      await global.writeAsString('[user]\n\tname = Me\n');
      expect(await keys.globalConfigBroken(), isFalse);
    });
  });
}
