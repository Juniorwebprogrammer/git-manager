import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_manager/features/repos/presentation/widgets/command_palette.dart';
import 'package:git_manager/features/repos/domain/entities/git_action.dart';
import 'package:git_manager/features/repos/domain/entities/file_diff.dart';
import 'package:git_manager/features/repos/data/datasources/git_cli_data_source.dart';
import 'package:git_manager/core/settings/app_settings.dart';
import 'package:flutter/material.dart';
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

  group('notifications', () {
    SystemLauncher l(String os, {bool notifySend = true, List<LaunchCommand>? started}) => SystemLauncher(
          exists: (e) async => notifySend && e == 'notify-send',
          start: (c) async => started?.add(c),
          operatingSystem: os,
          environment: const {},
        );

    test('Linux uses notify-send, or reports that there is none', () async {
      final started = <LaunchCommand>[];
      expect(await l('linux', started: started).notify('Push finished', 'app (main)'), isTrue);
      expect(started.single.arguments, ['--app-name=Git Manager', '--icon=git', 'Push finished', 'app (main)']);
      expect(await l('linux', notifySend: false).notify('a', 'b'), isFalse);
    });

    test('macOS and Windows escape quotes', () async {
      final mac = (await l('macos').notificationCommand('Say "hi"', 'b'))!;
      expect(mac.arguments.last, 'display notification "b" with title "Say \\"hi\\""');
      final win = (await l('windows').notificationCommand("It's done", 'b'))!;
      expect(win.arguments.last, contains("'It''s done'"));
    });
  });

  test('palette fuzzy score', () {
    expect(paletteScore('fetch', 'Fetch all remotes Repo'), 0);
    expect(paletteScore('chk feat', 'Checkout feature/login Branches'), isNotNull);
    expect(paletteScore('rebase main', 'Rebase dev onto main Branches'), 0);
    expect(paletteScore('xyz', 'Fetch all remotes'), isNull);
    expect(paletteScore('feat', 'Checkout feature/login')!, lessThan(paletteScore('ftr', 'Checkout feature/login')!));
  });

  test('settings survive a save/load round trip and clamp the font size', () {
    const s = AppSettings(themeMode: ThemeMode.light, diffFontSize: 15, wrapLines: false, ignoreWhitespace: true);
    final back = AppSettings.fromMap(s.toMap());
    expect(back.themeMode, ThemeMode.light);
    expect(back.diffFontSize, 15);
    expect(back.wrapLines, isFalse);
    expect(back.ignoreWhitespace, isTrue);
    expect(s.copyWith(diffFontSize: 99).diffFontSize, AppSettings.maxFontSize);
    expect(AppSettings.fromMap(const {}).themeMode, ThemeMode.system);
  });

  test('diff -w hides whitespace-only changes', () async {
    final tmp = await Directory.systemTemp.createTemp('gm_ws_');
    addTearDown(() => tmp.delete(recursive: true));
    const runner = GitRunner();
    const cli = GitCliDataSource(runner);
    const id = GitIdentity(login: 'u', token: 't', name: 'U', email: 'u@e.com');
    await runner.run(['init', '-q', '-b', 'main'], workingDirectory: tmp.path);
    await File('${tmp.path}/a.txt').writeAsString('if (x) {\n  y();\n}\n');
    await cli.run(tmp.path, const StageAllAction(), id);
    await cli.run(tmp.path, const CommitAction('one'), id);
    await File('${tmp.path}/a.txt').writeAsString('if (x) {\n      y();\n}\n'); // solo indentación

    const t = DiffTarget(source: DiffSource.unstaged, path: 'a.txt');
    expect((await cli.diff(tmp.path, t)).hunks, hasLength(1));
    expect((await cli.diff(tmp.path, t, ignoreWhitespace: true)).hunks, isEmpty);
  });
}
