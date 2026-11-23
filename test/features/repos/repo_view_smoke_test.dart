import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_manager/core/di/providers.dart';
import 'package:git_manager/core/error/app_exception.dart';
import 'package:git_manager/core/error/app_failure.dart';
import 'package:git_manager/core/error/result.dart';
import 'package:git_manager/core/git/git_runner.dart';
import 'package:git_manager/core/hosting/git_provider.dart';
import 'package:git_manager/features/repos/data/datasources/git_cli_data_source.dart';
import 'package:git_manager/features/repos/domain/entities/file_diff.dart';
import 'package:git_manager/features/repos/domain/entities/git_action.dart';
import 'package:git_manager/features/repos/domain/entities/git_commit.dart';
import 'package:git_manager/features/repos/domain/entities/file_change.dart';
import 'package:git_manager/features/repos/domain/entities/pull_request.dart';
import 'package:git_manager/features/repos/domain/entities/pull_request_detail.dart';
import 'package:git_manager/features/repos/domain/entities/repo_extras.dart';
import 'package:git_manager/features/repos/domain/entities/remote_repository.dart';
import 'package:git_manager/features/repos/domain/entities/repo_snapshot.dart';
import 'package:git_manager/features/repos/domain/repositories/git_repository.dart';
import 'package:git_manager/core/settings/app_settings.dart';
import 'package:git_manager/core/theme/app_theme.dart';
import 'package:git_manager/features/accounts/domain/entities/git_account.dart';
import 'package:git_manager/features/accounts/domain/repositories/account_repository.dart';
import 'package:git_manager/features/repos/presentation/pages/workspace_page.dart';
import 'package:mocktail/mocktail.dart';
import 'package:git_manager/features/repos/presentation/widgets/ref_sidebar.dart';
import 'package:git_manager/features/repos/presentation/widgets/pull_request_view.dart';
import 'package:git_manager/features/repos/presentation/widgets/file_history_view.dart';
import 'package:git_manager/features/repos/presentation/widgets/compare_panel.dart';
import 'package:git_manager/features/repos/presentation/widgets/blame_view.dart';
import 'package:git_manager/features/repos/presentation/widgets/code_view_style.dart';
import 'package:git_manager/features/repos/presentation/state/repo_notifier.dart';
import 'package:git_manager/core/system/system_launcher.dart';
import 'package:git_manager/features/repos/presentation/widgets/commit_detail_panel.dart';
import 'package:git_manager/features/repos/presentation/widgets/conflict_editor.dart';
import 'package:git_manager/features/repos/presentation/widgets/commit_graph_view.dart';
import 'package:git_manager/features/repos/presentation/widgets/diff_viewer.dart';
import 'package:git_manager/features/repos/presentation/widgets/staging_panel.dart';

/// GitRepository real (git CLI) con una identidad fija, sin almacén seguro.
class _CliGitRepository implements GitRepository {
  final cli = const GitCliDataSource(GitRunner());
  static const identity = GitIdentity(login: 'u', token: 't', name: 'Smoke Test', email: 'smoke@example.com');

  /// El IO real se lanza en la zona raíz: dentro de la zona de tiempo
  /// falso de testWidgets los procesos nunca llegarían a completarse.
  Future<Result<T>> _wrap<T>(Future<T> Function() f) => Zone.root.run(() async {
        // Los errores no pueden cruzar zonas: se capturan aquí, como el repo real.
        try {
          return Success<T>(await f());
        } on AppException catch (e) {
          return Failure<T>(GitCommandFailure(e.message));
        }
      });

  @override
  Future<Result<String>> resolveRepoRoot(String path) => _wrap(() => cli.resolveRoot(path));
  @override
  Future<Result<RepoSnapshot>> loadSnapshot(RepoHandle repo) => _wrap(() => cli.snapshot(repo.path));
  @override
  Future<Result<List<GitCommit>>> loadHistory(RepoHandle repo, {int limit = 500}) =>
      _wrap(() => cli.history(repo.path, limit: limit));
  @override
  Future<Result<GitCommitDetail>> loadCommitDetail(RepoHandle repo, String sha) =>
      _wrap(() => cli.commitDetail(repo.path, sha));
  @override
  Future<Result<FileDiff>> loadDiff(RepoHandle repo, DiffTarget target, {bool ignoreWhitespace = false}) =>
      _wrap(() => cli.diff(repo.path, target, ignoreWhitespace: ignoreWhitespace));
  @override
  Future<Result<FileContent>> loadFileContent(RepoHandle repo, DiffTarget target) =>
      _wrap(() => cli.fileContent(repo.path, target));
  @override
  Future<Result<void>> run(RepoHandle repo, GitAction action) => _wrap(() => cli.run(repo.path, action, identity));
  @override
  Future<Result<HostedRemote?>> loadHostedRemote(RepoHandle repo) => _wrap(() async {
        final out = await const GitRunner().tryRun(['remote', 'get-url', 'origin'], workingDirectory: repo.path);
        return out.ok ? parseHostedRemote(out.stdout) : null;
      });
  @override
  Future<Result<({int commits, String author})>> loadRefUpdate(RepoHandle repo, String? from, String to) =>
      _wrap(() => cli.refUpdate(repo.path, from, to));
  @override
  Future<Result<UndoPlan?>> loadUndoPlan(RepoHandle repo) => _wrap(() => cli.undoPlan(repo.path));
  @override
  Future<Result<List<FileHistoryEntry>>> loadFileHistory(RepoHandle repo, String path) =>
      _wrap(() => cli.fileHistory(repo.path, path));
  @override
  Future<Result<List<BlameLine>>> loadBlame(RepoHandle repo, String path, {String? revision}) =>
      _wrap(() => cli.blame(repo.path, path, revision: revision));
  @override
  Future<Result<List<FileChange>>> loadComparison(RepoHandle repo, String base, String target) =>
      _wrap(() => cli.comparison(repo.path, base, target));
  @override
  Future<Result<SigningConfig>> loadSigningConfig(RepoHandle repo) => _wrap(() => cli.signingConfig(repo.path));
  @override
  Future<Result<String?>> loadCommitTemplate(RepoHandle repo) => _wrap(() => cli.commitTemplate(repo.path));
  @override
  Future<Result<List<GitCommit>>> loadCommitsForRebase(RepoHandle repo, String base) =>
      _wrap(() => cli.commitsForRebase(repo.path, base));
  @override
  Future<Result<HostedRepoInfo>> hostedRepoInfo(RepoHandle repo) async =>
      Success(HostedRepoInfo(owner: 'octo', name: 'demo', provider: service));

  /// Servicio de las PRs simuladas (GitHub o Azure DevOps).
  GitProvider service = GitProvider.github;

  @override
  Future<Result<List<PullRequest>>> listPullRequests(RepoHandle repo) async => Success([
        PullRequest(
          number: 12,
          title: 'Add a much better login screen with validation',
          author: 'octo',
          headRef: 'feature/login',
          headSha: 'abc',
          headRepoFullName: 'octo/demo',
          baseRef: 'main',
          url: 'https://github.com/octo/demo/pull/12',
          ci: CiStatus.success,
          provider: service,
        ),
        PullRequest(
          number: 7,
          title: 'WIP: dark mode',
          author: 'someone',
          headRef: 'dark',
          headSha: 'def',
          headRepoFullName: 'someone/demo',
          baseRef: 'main',
          url: 'https://github.com/octo/demo/pull/7',
          draft: true,
          ci: CiStatus.failure,
          provider: service,
        ),
      ]);
  final prOps = <PullRequestOp>[];

  @override
  Future<Result<PullRequestBundle>> loadPullRequest(RepoHandle repo, int number) async => Success(PullRequestBundle(
        detail: PullRequestDetail(
          number: number,
          title: 'Add a much better login screen with validation',
          body: '## Why\nUsers could not log in.\n\n- validates the email\n- [x] tests\n\n```dart\nfinal ok = true;\n```',
          author: 'octo',
          state: PullRequestState.open,
          headRef: 'feature/login',
          headSha: 'abc',
          headRepoFullName: 'octo/demo',
          baseRef: 'main',
          url: 'https://github.com/octo/demo/pull/$number',
          mergeable: true,
          mergeableState: 'clean',
          commitCount: 1,
          additions: 4,
          changedFiles: 1,
          provider: service,
        ),
        timeline: [
          PullRequestEvent(author: 'eve', body: 'Please add a test', review: ReviewState.changesRequested, date: DateTime(2026, 11, 19, 10)),
          PullRequestEvent(author: 'bob', body: 'Looks good to me', date: DateTime(2026, 11, 19, 11)),
        ],
        commits: const [PullRequestCommit(sha: 'abcdef1234567', message: 'Add login screen', author: 'octo')],
        files: const [
          PullRequestFile(
            path: 'login.dart',
            type: ChangeType.added,
            additions: 4,
            patch: '@@ -0,0 +1,4 @@\n+class Login {\n+  // TODO\n+  final int retries = 3;\n+}',
          ),
        ],
        checks: const [
          PullRequestCheck(name: 'build', status: CiStatus.success, detail: 'success', url: 'https://ci/1'),
          PullRequestCheck(name: 'tests', status: CiStatus.pending, detail: 'in_progress'),
        ],
        reviewComments: [
          ReviewComment(id: 1, author: 'eve', body: 'Why three retries?', path: 'login.dart', line: 3,
              side: DiffSide.right, date: DateTime(2026, 11, 19, 9)),
          ReviewComment(id: 2, author: 'octo', body: 'Matches the backend limit', path: 'login.dart', line: 3,
              side: DiffSide.right, date: DateTime(2026, 11, 19, 9, 30), inReplyTo: 1),
          ReviewComment(id: 3, author: 'bob', body: 'Rename this class', path: 'login.dart', line: null,
              side: DiffSide.right, date: DateTime(2026, 11, 18)),
        ],
      ));

  @override
  Future<Result<void>> pullRequestAction(RepoHandle repo, int number, PullRequestOp op) async {
    prOps.add(op);
    return const Success(null);
  }

  @override
  Future<Result<PullRequest>> createPullRequest(
    RepoHandle repo, {
    required String title,
    required String head,
    required String base,
    String body = '',
    bool draft = false,
  }) async =>
      Success(PullRequest(
        number: 99,
        title: title,
        author: 'octo',
        headRef: head,
        headSha: '',
        headRepoFullName: 'octo/demo',
        baseRef: base,
        url: 'https://github.com/octo/demo/pull/99',
      ));

  @override
  Future<Result<List<RemoteRepository>>> listRemoteRepositories(String accountId) async => const Success([]);
  @override
  Future<Result<String>> clone(String accountId, String url, String parentDirectory) =>
      _wrap(() => cli.clone(url, parentDirectory, identity));
}

class _MockAccountRepository extends Mock implements AccountRepository {}

class _MemorySettingsStore implements SettingsStore {
  @override
  Future<Map<String, Object?>> load() async => const {};
  @override
  Future<void> save(Map<String, Object> values) async {}
}

class _FixedWorkspace implements WorkspaceRepository {
  final List<String> tabs;
  _FixedWorkspace(this.tabs);
  @override
  Future<({List<String> tabs, int activeIndex})> load(String accountId) async => (tabs: tabs, activeIndex: 0);
  @override
  Future<void> save(String accountId, List<String> tabs, int activeIndex) async {}
}

const _account = GitAccount(
  id: 'a',
  login: 'octocat',
  displayName: 'Octo Cat',
  email: 'octo@example.com',
  avatarUrl: '',
  profileUrl: '',
);

final launched = <LaunchCommand>[];

void main() {
  late Directory tmp;
  late String repo;
  const runner = GitRunner();
  final git = _CliGitRepository();

  setUp(() async {
    launched.clear();
    tmp = await Directory.systemTemp.createTemp('gm_smoke_');
    repo = (await Directory('${tmp.path}/demo').create()).path;
    final h = (accountId: 'a', path: repo);
    await runner.run(['init', '-q', '-b', 'main'], workingDirectory: repo);
    await File('$repo/main.dart').writeAsString('void main() {\n  print("hello");\n}\n');
    await git.run(h, const StageAllAction());
    await git.run(h, const CommitAction('Initial commit'));
    await git.run(h, const CreateBranchAction('feature/login'));
    await File('$repo/login.dart').writeAsString('class Login {\n  // TODO\n  final int retries = 3;\n}\n');
    await git.run(h, const StageAllAction());
    await git.run(h, const CommitAction('Add login screen'));
    await git.run(h, const CheckoutAction('main'));
    await File('$repo/main.dart').writeAsString('void main() {\n  print("hello world");\n}\n');
    await git.run(h, const StageAllAction());
    await git.run(h, const CommitAction('Improve greeting'));
    await git.run(h, const MergeAction('feature/login'));
    await git.run(h, const CreateTagAction('v1.0.0', 'HEAD'));
    // Cambios locales sin commitear.
    await File('$repo/main.dart').writeAsString('void main() {\n  print("hi");\n}\n');
    await File('$repo/notes.md').writeAsString('# Notes\n');
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    // Cada await sobre IO real necesita un ciclo runAsync + pump.
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      // Avanzar también el reloj falso: si no, las animaciones de entrada de
      // menús y diálogos se quedan en opacidad 0 y no se pintan (ni se
      // detectan sus overflows).
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> pumpWorkspace(WidgetTester tester, Size size, {List<dynamic> overrides = const []}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final accounts = _MockAccountRepository();
    when(() => accounts.getAccounts()).thenAnswer((_) async => const Success([_account]));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gitRepositoryProvider.overrideWithValue(git),
          accountRepositoryProvider.overrideWithValue(accounts),
          workspaceRepositoryProvider.overrideWithValue(_FixedWorkspace([repo])),
        // Nunca abrir terminales/editores de verdad desde los tests.
        systemLauncherProvider.overrideWithValue(SystemLauncher(
          exists: (e) async => e == 'code' || e == 'x-terminal-emulator' || e == 'notify-send',
          start: (c) async => launched.add(c),
          operatingSystem: 'linux',
          environment: const {},
          resolveLink: (_) async => '/usr/bin/ptyxis',
        )),
        settingsStoreProvider.overrideWithValue(_MemorySettingsStore()),
        ...overrides.cast(),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const WorkspacePage(accountId: 'a'),
        ),
      ),
    );
    await settle(tester);
  }

  for (final size in const [Size(1500, 900), Size(1280, 720), Size(1024, 680), Size(900, 600)]) {
    testWidgets('workspace at ${size.width.toInt()}x${size.height.toInt()}: graph, staging, '
        'commit detail and diffs render without layout errors', (tester) async {
      await pumpWorkspace(tester, size);

      // Los botones de la toolbar (de Pull a Folder) van centrados.
      final toolsLeft = tester.getTopLeft(find.byKey(const ValueKey('toolbar-first'))).dx;
      final toolsRight = tester.getTopRight(find.byKey(const ValueKey('toolbar-last'))).dx;
      expect(((toolsLeft + toolsRight) / 2 - size.width / 2).abs(), lessThan(4), reason: 'toolbar not centered');

      // Grafo con commits, refs y WIP.
      expect(find.text('Improve greeting'), findsOneWidget);
      expect(find.text('Add login screen'), findsOneWidget);
      expect(find.text('// WIP'), findsOneWidget);
      expect(find.byType(StagingPanel), findsOneWidget);
      expect(find.text('notes.md'), findsOneWidget);

      // Diff de un cambio local, en las tres vistas.
      await tester.tap(find.text('main.dart').first);
      await settle(tester);
      expect(find.byType(DiffViewer), findsOneWidget);
      await tester.tap(find.byTooltip('Side-by-side diff'));
      await settle(tester);
      await tester.tap(find.byTooltip('Whole file'));
      await settle(tester);
      await tester.tap(find.byTooltip('Close (Esc)'));
      await settle(tester);

      // Detalle de un commit y su diff.
      await tester.tap(find.text('Add login screen'));
      await settle(tester);
      expect(find.byType(CommitDetailPanel), findsOneWidget);
      await tester.tap(find.text('login.dart'));
      await settle(tester);
      await tester.tap(find.byTooltip('Close (Esc)'));
      await settle(tester);

      // Stage de todo desde el panel.
      await tester.tap(find.text('// WIP'));
      await settle(tester);
      await tester.tap(find.byTooltip('Stage all changes'));
      await settle(tester);
      expect(find.text('Commit 2 files'), findsOneWidget);

      // Menú contextual de una rama (textos largos tipo "Rebase main onto …").
      await tester.tapAt(tester.getCenter(find.text('feature/login').first), buttons: kSecondaryButton);
      await settle(tester);
      // Terminar la animación de entrada: con opacidad 0 no se pinta y el
      // overflow no llegaría a detectarse.
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('Rebase main onto feature/login'), findsOneWidget);
      expect(find.textContaining('Squash feature/login into main'), findsOneWidget);
      expect(find.textContaining('Interactive rebase main onto feature/login'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      // Diálogo de abrir/clonar.
      await tester.tap(find.byTooltip('Open or clone a repository (Ctrl+T)'));
      await settle(tester);
      await tester.tap(find.text('Clone from GitHub'));
      await settle(tester);
      await tester.tapAt(const Offset(4, 4)); // cerrar el diálogo
      await settle(tester);

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('undo and redo the last merge from the toolbar', (tester) async {
    await pumpWorkspace(tester, const Size(1440, 860));
    Future<String> headSubject() async =>
        (await tester.runAsync(() => runner.run(['log', '-1', '--format=%s'], workingDirectory: repo)))!.trim();

    expect(find.byTooltip('Undo merge of feature/login'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('toolbar-first')));
    await settle(tester);
    expect(await headSubject(), 'Improve greeting');
    expect(find.text('Undone: merge of feature/login'), findsOneWidget);

    expect(find.byTooltip('Redo merge of feature/login'), findsOneWidget);
    await tester.tap(find.byTooltip('Redo merge of feature/login'));
    await settle(tester);
    expect(await headSubject(), "Merge branch 'feature/login'");
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(1280, 720), Size(900, 600)]) {
    testWidgets('blame and file history at ${size.width.toInt()}px', (tester) async {
      await pumpWorkspace(tester, size);
      await tester.tap(find.text('main.dart').first);
      await settle(tester);

      await tester.tap(find.byTooltip('Blame'));
      await settle(tester);
      expect(find.byType(BlameView), findsOneWidget);
      expect(find.text('Not committed yet'), findsOneWidget); // la línea 2 cambiada en el WIP
      expect(find.textContaining('Initial commit'), findsWidgets);

      await tester.tap(find.byTooltip('File history'));
      await settle(tester);
      expect(find.byType(FileHistoryView), findsOneWidget);
      expect(find.text('Improve greeting'), findsOneWidget);
      await tester.tap(find.text('Initial commit'));
      await settle(tester);
      expect(find.byType(DiffViewer), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape); // cierra el diff
      await settle(tester);
      expect(find.byType(DiffViewer), findsNothing);
      expect(find.byType(FileHistoryView), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape); // cierra el historial
      await settle(tester);
      expect(find.byType(FileHistoryView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('ctrl+click two commits to compare them', (tester) async {
    await pumpWorkspace(tester, const Size(1280, 720));
    await tester.tap(find.text('Add login screen'));
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('Initial commit'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);

    expect(find.byType(ComparePanel), findsOneWidget);
    expect(find.text('1 file changed'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(ComparePanel), matching: find.text('login.dart')));
    await settle(tester);
    expect(find.byType(DiffViewer), findsOneWidget);
    expect(find.textContaining('→'), findsWidgets);

    await tester.tap(find.byTooltip('Close comparison'));
    await settle(tester);
    expect(find.byType(ComparePanel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('conventional commit type and scope build the summary', (tester) async {
    await pumpWorkspace(tester, const Size(1280, 720));
    await tester.tap(find.byTooltip('Stage all changes'));
    await settle(tester);

    await tester.tap(find.text('type'));
    await settle(tester);
    await tester.tap(find.text('feat').last);
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'scope (optional)'), 'ui');
    await tester.enterText(find.widgetWithText(TextField, 'Summary (required)'), 'say hi');
    await settle(tester);
    expect(find.text('feat(ui): say hi'), findsOneWidget);

    await tester.tap(find.text('Commit 2 files'));
    await settle(tester);
    final subject = await tester.runAsync(() => runner.run(['log', '-1', '--format=%s'], workingDirectory: repo));
    expect(subject!.trim(), 'feat(ui): say hi');
    expect(tester.takeException(), isNull);
  });

  testWidgets('signing settings dialog fits a small window', (tester) async {
    await pumpWorkspace(tester, const Size(900, 600));
    await tester.tap(find.byTooltip('Signing settings…'));
    await settle(tester);
    expect(find.text('Commit signing'), findsOneWidget);
    expect(find.text('SSH key'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('terminal and VS Code buttons launch the right commands', (tester) async {
    await pumpWorkspace(tester, const Size(1280, 720));
    await tester.tap(find.byTooltip('Open a terminal here'));
    await settle(tester);
    await tester.tap(find.byTooltip('Open the repository in VS Code'));
    await settle(tester);
    expect(launched.map((c) => c.toString()), [
      'x-terminal-emulator --new-window -d $repo',
      'code $repo',
    ]);
  });

  testWidgets('settings: theme, font size and toggles are stored', (tester) async {
    await pumpWorkspace(tester, const Size(1280, 720));
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    await tester.tap(find.text('Light'));
    await settle(tester);
    await tester.tap(find.text('Wrap long lines'));
    await settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(WorkspacePage)));
    expect(container.read(appSettingsProvider).themeMode, ThemeMode.light);
    expect(container.read(appSettingsProvider).wrapLines, isFalse);
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('diff toggles: ignore whitespace disables partial staging, no-wrap scrolls', (tester) async {
    await pumpWorkspace(tester, const Size(1280, 720));
    await tester.tap(find.text('main.dart').first);
    await settle(tester);
    expect(find.text('Stage hunk'), findsOneWidget);

    await tester.tap(find.byTooltip('Ignore whitespace changes'));
    await settle(tester);
    expect(find.textContaining('staging by hunk or line is disabled'), findsOneWidget);
    expect(find.text('Stage hunk'), findsNothing);

    await tester.tap(find.byTooltip('Long lines wrap — click to scroll horizontally'));
    await settle(tester);
    expect(find.byType(HorizontalCodeScroll), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(1280, 720), Size(900, 600)]) {
    testWidgets('command palette at ${size.width.toInt()}px: search and run with the keyboard', (tester) async {
      await pumpWorkspace(tester, size);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(find.textContaining('Type a command'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'blame main');
      await settle(tester);
      expect(find.text('Blame: main.dart'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byType(BlameView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  group('notifications', () {
    setUp(() async {
      final bare = '${tmp.path}/origin.git';
      await runner.run(['init', '-q', '--bare', '-b', 'main', bare], workingDirectory: tmp.path);
      await runner.run(['remote', 'add', 'origin', bare], workingDirectory: repo);
    });

    testWidgets('a finished fetch shows a system notification', (tester) async {
      await pumpWorkspace(tester, const Size(1280, 720),
          overrides: [notificationThresholdProvider.overrideWithValue(Duration.zero)]);
      await tester.tap(find.byTooltip('Fetch all remotes'));
      await settle(tester);
      expect(
        launched.map((c) => c.toString()),
        contains('notify-send --app-name=Git Manager --icon=git Fetch finished demo (main)'),
      );
    });
  });

  group('auto-fetch', () {
    late String teammate;
    const ana = GitIdentity(login: 'ana', token: 't', name: 'Ana', email: 'ana@example.com');

    setUp(() async {
      final bare = '${tmp.path}/origin.git';
      await runner.run(['init', '-q', '--bare', '-b', 'main', bare], workingDirectory: tmp.path);
      await runner.run(['remote', 'add', 'origin', bare], workingDirectory: repo);
      await runner.run(['push', '-q', '-u', 'origin', 'main'], workingDirectory: repo);
      final parent = await Directory('${tmp.path}/ana').create();
      teammate = await git.cli.clone(bare, parent.path, ana);
    });

    Future<void> anaPushes() async {
      final cli = git.cli;
      await cli.run(teammate, const CreateBranchAction('feature/payments'), ana);
      await File('$teammate/pay.dart').writeAsString('// pay\n');
      await cli.run(teammate, const StageAllAction(), ana);
      await cli.run(teammate, const CommitAction('Add payments'), ana);
      await cli.run(teammate, const PushAction(), ana);
      await cli.run(teammate, const CheckoutAction('main'), ana);
      await File('$teammate/README.md').writeAsString('hello\n');
      await cli.run(teammate, const StageAllAction(), ana);
      await cli.run(teammate, const CommitAction('Add readme'), ana);
      await cli.run(teammate, const PushAction(), ana);
    }

    testWidgets("a teammate's push shows up in the graph by itself", (tester) async {
      await pumpWorkspace(tester, const Size(1280, 720));
      // Primer tick: fetch inicial (no hay nada nuevo todavía).
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
      await settle(tester);
      expect(find.textContaining('Fetched'), findsOneWidget);
      expect(find.text('Add payments'), findsNothing);

      await tester.runAsync(anaPushes);

      // Pasan 5 minutos: el auto-fetch se dispara solo.
      await tester.pump(const Duration(minutes: 5, seconds: 6));
      for (var i = 0; i < 4; i++) {
        await settle(tester);
      }

      expect(find.text('Add payments'), findsOneWidget); // en el árbol
      expect(find.text('Add readme'), findsOneWidget);
      expect(find.textContaining('new branch origin/feature/payments by Ana'), findsOneWidget); // aviso
      expect(find.textContaining('origin/main: 1 new commit by Ana'), findsOneWidget);
      expect(find.text('new'), findsOneWidget); // marca en la barra lateral
      expect(find.byTooltip('1 new commit since you last looked'), findsOneWidget);
      expect(find.text('1'), findsWidgets); // ↓1 en Pull

      // Regresión: un refresco posterior no debe borrar las marcas de novedad
      // (refresh() pisaba el estado que cambiaba mientras esperaba a git).
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
      expect(find.text('new'), findsOneWidget);
      expect(find.byTooltip('1 new commit since you last looked'), findsOneWidget);

      // "Show" salta al commit nuevo.
      await tester.tap(find.text('Show'));
      await settle(tester);
      expect(find.byType(CommitDetailPanel), findsOneWidget);

      // Con la ventana en segundo plano, también notificación del sistema.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.runAsync(() async {
        await File('$teammate/README.md').writeAsString('hello again\n');
        await git.cli.run(teammate, const StageAllAction(), ana);
        await git.cli.run(teammate, const CommitAction('Update readme'), ana);
        await git.cli.run(teammate, const PushAction(), ana);
      });
      final container = ProviderScope.containerOf(tester.element(find.byType(WorkspacePage)));
      unawaited(container.read(repoNotifierProvider((accountId: 'a', path: repo)).notifier).backgroundFetch());
      for (var i = 0; i < 3; i++) {
        await settle(tester);
      }
      expect(
        launched.map((c) => c.toString()),
        contains('notify-send --app-name=Git Manager --icon=git New changes in demo origin/main: 1 new commit by Ana'),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('auto-fetch can be turned off in Settings', (tester) async {
      await pumpWorkspace(tester, const Size(1280, 720));
      await tester.tap(find.byTooltip('Settings'));
      await settle(tester);
      expect(find.text('Every 5 min'), findsOneWidget);
      await tester.tap(find.text('Every 5 min'));
      await settle(tester);
      await tester.tap(find.text('Off').last);
      await settle(tester);
      await tester.tap(find.text('Done'));
      await settle(tester);

      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
      expect(find.text('Not fetched yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('worktrees', () {
    late String wt;
    setUp(() async {
      wt = '${tmp.path}/login-wt';
      await runner.run(['worktree', 'add', '-q', wt, 'feature/login'], workingDirectory: repo);
    });

    testWidgets('branch in another worktree is marked and explained', (tester) async {
      await pumpWorkspace(tester, const Size(1280, 720));
      expect(find.byIcon(Icons.folder_copy_outlined), findsOneWidget);

      final tile = find.descendant(of: find.byType(RefSidebar), matching: find.text('feature/login'));
      await tester.tap(tile);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(tile);
      await settle(tester);
      expect(find.textContaining('is open in another folder'), findsOneWidget);

      await tester.tap(find.text('Remove worktree…'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await settle(tester);
      expect(find.byIcon(Icons.folder_copy_outlined), findsNothing);
      expect(await tester.runAsync(() => Directory(wt).exists()), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('hovering a "+N" ref chip lists every ref and checks one out on click', (tester) async {
    await pumpWorkspace(tester, const Size(1280, 720));
    // El commit de merge tiene "main" (actual) y el tag "v1.0.0".
    final chip = find.descendant(of: find.byType(CommitGraphView), matching: find.text('main'));
    expect(chip, findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'v1.0.0'), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(chip));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.widgetWithText(MenuItemButton, 'v1.0.0'), findsOneWidget);
    expect(find.textContaining('2 refs on this commit'), findsOneWidget);

    await tester.tap(find.widgetWithText(MenuItemButton, 'v1.0.0'));
    await settle(tester);
    expect(find.textContaining('detached @'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stage a single line, then the rest of the hunk, from the diff', (tester) async {
    await pumpWorkspace(tester, const Size(1280, 720));
    await tester.tap(find.text('main.dart').first);
    await settle(tester);

    // Seleccionar solo la línea añadida y hacer stage de ella.
    await tester.tap(find.descendant(of: find.byType(DiffViewer), matching: find.text('+')));
    await settle(tester);
    expect(find.text('1 line selected'), findsOneWidget);
    await tester.tap(find.text('Stage 1 line'));
    await settle(tester);

    final index = await tester.runAsync(() => runner.run(['show', ':main.dart'], workingDirectory: repo));
    expect(index, contains('print("hello world");'));
    expect(index, contains('print("hi");'));
    final inPanel = find.descendant(of: find.byType(StagingPanel), matching: find.text('main.dart'));
    expect(inPanel, findsNWidgets(2)); // staged a medias: aparece en las dos listas

    // El resto (la línea borrada) con "Stage hunk": el fichero queda entero en stage.
    await tester.tap(find.text('Stage hunk'));
    await settle(tester);
    expect(inPanel, findsOneWidget);
    expect(find.byType(DiffViewer), findsNothing); // ya no hay cambios sin stage
    expect(find.text('Commit 1 file'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('interactive rebase from the commit menu drops a commit', (tester) async {
    await pumpWorkspace(tester, const Size(1024, 680));
    await tester.tapAt(tester.getCenter(find.text('Initial commit')), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.textContaining('Interactive rebase main from here'));
    await settle(tester);

    expect(find.text('Interactive rebase'), findsOneWidget);
    expect(find.text('Add login screen'), findsWidgets);
    final row = find.ancestor(of: find.text('Add login screen').last, matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: row, matching: find.byType(DropdownButton<RebaseStepAction>)));
    await settle(tester);
    await tester.tap(find.text('drop').last);
    await settle(tester);
    await tester.tap(find.text('Start rebase'));
    await settle(tester);

    final log = await tester.runAsync(() => runner.run(['log', '--format=%s', 'main'], workingDirectory: repo));
    expect(log!.trim().split('\n'), ['Improve greeting', 'Initial commit']);
    expect(tester.takeException(), isNull);
  });

  group('Azure Repos pull requests', () {
    setUp(() async {
      git.prOps.clear();
      git.service = GitProvider.azure;
      await runner.run(['remote', 'add', 'origin', 'https://dev.azure.com/contoso/Store/_git/demo'],
          workingDirectory: repo);
    });
    tearDown(() => git.service = GitProvider.github);

    testWidgets('list, view and complete a PR with Azure DevOps wording', (tester) async {
      await pumpWorkspace(tester, const Size(1280, 720));
      expect(find.text('PULL REQUESTS'), findsOneWidget);
      expect(find.textContaining('not in the app yet'), findsNothing);

      await tester.tapAt(tester.getCenter(find.textContaining('Add a much better login screen')),
          buttons: kSecondaryButton);
      await settle(tester);
      expect(find.text('Open on Azure DevOps'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      await tester.tap(find.textContaining('Add a much better login screen'));
      await settle(tester);
      expect(find.byType(PullRequestView), findsOneWidget);
      expect(find.byTooltip('Open on Azure DevOps'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Merge'));
      await settle(tester);
      expect(find.textContaining('Azure DevOps completes the pull request'), findsOneWidget);
      expect(find.textContaining('on Azure DevOps after merging'), findsOneWidget);
      await tester.tap(find.text('Squash and merge'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm squash and merge'));
      await settle(tester);
      final merge = git.prOps.whereType<MergePullRequest>().single;
      expect((merge.method, merge.deleteBranch), (MergeMethod.squash, true));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the PR button and the palette create Azure pull requests', (tester) async {
      await pumpWorkspace(tester, const Size(1024, 680));
      await tester.tap(find.byTooltip('Create pull request').first);
      await settle(tester);
      expect(find.textContaining('is not on Azure DevOps yet'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'pull request');
      await settle(tester);
      expect(find.text('Create pull request…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('GitHub pull requests', () {
    setUp(() async {
      git.prOps.clear();
      final bare = '${tmp.path}/origin.git';
      await runner.run(['init', '-q', '--bare', '-b', 'main', bare], workingDirectory: tmp.path);
      await runner.run(['remote', 'add', 'origin', bare], workingDirectory: repo);
    });

    testWidgets('lists open PRs with CI and creates a new one', (tester) async {
      await pumpWorkspace(tester, const Size(1280, 720));
      expect(find.text('PULL REQUESTS'), findsOneWidget);
      expect(find.textContaining('Add a much better login screen'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsWidgets);
      expect(find.text('draft'), findsOneWidget);

      await tester.tapAt(tester.getCenter(find.textContaining('Add a much better login screen')),
          buttons: kSecondaryButton);
      await settle(tester);
      expect(find.text('Checkout PR #12'), findsOneWidget);
      expect(find.text('View pull request'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      await tester.tap(find.byTooltip('Create pull request').first);
      await settle(tester);
      expect(find.text('Create pull request'), findsWidgets);
      // La rama no está en GitHub: desmarcar "push first" (no hay red en el test).
      await tester.tap(find.textContaining('is not on GitHub yet'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Create pull request'));
      await settle(tester);
      expect(find.text('Pull request #99 created'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final size in const [Size(1280, 720), Size(900, 600)]) {
      testWidgets('manage a PR inside the app at ${size.width.toInt()}px', (tester) async {
        await pumpWorkspace(tester, size);
        await tester.tap(find.textContaining('Add a much better login screen'));
        await settle(tester);

        // Cabecera y conversación.
        expect(find.byType(PullRequestView), findsOneWidget);
        expect(find.textContaining('#12  Add a much better login screen'), findsOneWidget);
        expect(find.textContaining('Ready to merge'), findsOneWidget);
        final conversation =
            find.descendant(of: find.byKey(const ValueKey('pr-conversation')), matching: find.byType(Scrollable)).first;
        Future<void> scrollTo(Finder f) => tester.scrollUntilVisible(f, 120, scrollable: conversation, maxScrolls: 30);
        await scrollTo(find.text('Users could not log in.')); // markdown del cuerpo
        await scrollTo(find.text('Please add a test'));
        expect(find.textContaining('requested changes'), findsOneWidget);

        // Comentar.
        await tester.enterText(find.widgetWithText(TextField, 'Leave a comment (Markdown) · Ctrl+Enter to send'), 'Thanks!');
        await tester.tap(find.widgetWithText(FilledButton, 'Comment'));
        await settle(tester);
        expect((git.prOps.last as CommentOnPullRequest).body, 'Thanks!');

        // Ficheros con su diff, y checks.
        await tester.tap(find.byTooltip('Files changed'));
        await settle(tester);
        expect(find.byType(PatchView), findsOneWidget);
        expect(find.textContaining('retries'), findsWidgets);
        await tester.tap(find.byTooltip('Checks'));
        await settle(tester);
        expect(find.text('build'), findsOneWidget);
        expect(find.text('in_progress'), findsOneWidget);

        // Comentarios en líneas del diff: hilo existente, respuesta y comentario nuevo.
        await tester.tap(find.byTooltip('Files changed'));
        await settle(tester);
        expect(find.text('Why three retries?'), findsOneWidget);
        expect(find.text('Matches the backend limit'), findsOneWidget);
        expect(find.textContaining('1 outdated comment thread'), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('Click to comment on this line').first);
        await settle(tester);
        await tester.tap(find.byTooltip('Click to comment on this line').first);
        await settle(tester);
        await tester.enterText(find.widgetWithText(TextField, 'Comment on line 1 · Ctrl+Enter to send'), 'Make this a const');
        await settle(tester);
        await tester.ensureVisible(find.widgetWithText(FilledButton, 'Add comment'));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Add comment'));
        await settle(tester);
        final comment = git.prOps.last as CommentOnLine;
        expect((comment.path, comment.line, comment.side, comment.commitSha, comment.body),
            ('login.dart', 1, DiffSide.right, 'abc', 'Make this a const'));
        // Esperar a que se vaya el aviso flotante (en ventanas bajas tapa el hilo).
        await tester.pump(const Duration(seconds: 3));
        await settle(tester);

        await tester.ensureVisible(find.widgetWithText(TextButton, 'Reply').first);
        await settle(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Reply').first);
        await settle(tester);
        await tester.enterText(find.widgetWithText(TextField, 'Reply… · Ctrl+Enter to send'), 'Thanks, makes sense');
        await settle(tester);
        await tester.ensureVisible(find.widgetWithText(FilledButton, 'Add comment'));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Add comment'));
        await settle(tester);
        final reply = git.prOps.last as ReplyToReviewComment;
        expect((reply.commentId, reply.body), (1, 'Thanks, makes sense'));
        await tester.tap(find.byTooltip('Conversation'));
        await settle(tester);
        expect(find.textContaining('commented on login.dart:3'), findsNothing); // los hilos vienen de la API real

        // Review: aprobar.
        await tester.tap(find.widgetWithText(FilledButton, 'Review'));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Submit review'));
        await settle(tester);
        expect((git.prOps.last as ReviewPullRequest).event, ReviewEvent.approve);

        // Merge con squash y borrado de rama (+ fetch local).
        await tester.tap(find.widgetWithText(FilledButton, 'Merge'));
        await settle(tester);
        await tester.tap(find.text('Squash and merge'));
        await settle(tester);
        await tester.tap(find.text('Confirm squash and merge'));
        await settle(tester);
        final merge = git.prOps.last as MergePullRequest;
        expect(merge.method, MergeMethod.squash);
        expect(merge.title, 'Add a much better login screen with validation (#12)');
        expect(merge.deleteBranch, isTrue);

        // Esc cierra la vista.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        expect(find.byType(PullRequestView), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('rebase conflict', () {
    setUp(() async {
      final h = (accountId: 'a', path: repo);
      await git.run(h, const StageAllAction());
      await git.run(h, const CommitAction('wip on main'));
      await git.run(h, const CreateBranchAction('topic', startPoint: 'v1.0.0'));
      await File('$repo/main.dart').writeAsString('void main() {\n  print("topic");\n}\n');
      await git.run(h, const StageAllAction());
      await git.run(h, const CommitAction('topic change'));
      final result = await git.run(h, const RebaseAction('main'));
      expect(result, isA<Failure<void>>(), reason: 'the rebase should stop on a conflict');
    });

    testWidgets('banner shows progress, Continue finishes it', (tester) async {
      await pumpWorkspace(tester, const Size(1024, 680));

      expect(find.textContaining('Rebasing topic'), findsOneWidget);
      expect(find.textContaining('step 1/1'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('Abort'), findsOneWidget);
      final continueButton = find.widgetWithText(FilledButton, 'Continue');
      expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);

      // Resolver el conflicto y marcarlo como resuelto desde la UI.
      await tester.runAsync(() => File('$repo/main.dart').writeAsString('void main() {\n  print("both");\n}\n'));
      await tester.tap(find.byTooltip('Stage file').first);
      await settle(tester);
      expect(tester.widget<FilledButton>(continueButton).onPressed, isNotNull);

      await tester.tap(continueButton);
      await settle(tester);
      expect(find.textContaining('Rebasing topic'), findsNothing);
      expect(find.text('topic change'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('conflict editor fits a small window', (tester) async {
      await pumpWorkspace(tester, const Size(900, 600));
      await tester.tap(find.descendant(of: find.byType(StagingPanel), matching: find.text('main.dart')));
      await settle(tester);
      expect(find.byType(ConflictEditor), findsOneWidget);
      await tester.tap(find.text('Use current'));
      await settle(tester);
      expect(find.textContaining('using current'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('conflict editor: use incoming, mark resolved, continue', (tester) async {
      await pumpWorkspace(tester, const Size(1280, 720));
      await tester.tap(find.descendant(of: find.byType(StagingPanel), matching: find.text('main.dart')));
      await settle(tester);

      expect(find.byType(ConflictEditor), findsOneWidget);
      expect(find.textContaining('0 of 1 conflict'), findsOneWidget);
      expect(find.text('Use incoming'), findsOneWidget);
      await tester.tap(find.text('Use incoming'));
      await settle(tester);
      expect(find.textContaining('1 of 1 conflict'), findsOneWidget);
      await tester.tap(find.text('Mark resolved'));
      await settle(tester);

      final continueButton = find.widgetWithText(FilledButton, 'Continue');
      expect(tester.widget<FilledButton>(continueButton).onPressed, isNotNull);
      await tester.tap(continueButton);
      await settle(tester);
      expect(find.textContaining('Rebasing topic'), findsNothing);
      final text = await tester.runAsync(() => File('$repo/main.dart').readAsString());
      expect(text, contains('print("topic")'));
      expect(tester.takeException(), isNull);
    });
  });
}
