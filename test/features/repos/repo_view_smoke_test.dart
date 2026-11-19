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
import 'package:git_manager/features/repos/data/datasources/git_cli_data_source.dart';
import 'package:git_manager/features/repos/domain/entities/file_diff.dart';
import 'package:git_manager/features/repos/domain/entities/git_action.dart';
import 'package:git_manager/features/repos/domain/entities/git_commit.dart';
import 'package:git_manager/features/repos/domain/entities/pull_request.dart';
import 'package:git_manager/features/repos/domain/entities/remote_repository.dart';
import 'package:git_manager/features/repos/domain/entities/repo_snapshot.dart';
import 'package:git_manager/features/repos/domain/repositories/git_repository.dart';
import 'package:git_manager/core/theme/app_theme.dart';
import 'package:git_manager/features/accounts/domain/entities/git_account.dart';
import 'package:git_manager/features/accounts/domain/repositories/account_repository.dart';
import 'package:git_manager/features/repos/presentation/pages/workspace_page.dart';
import 'package:mocktail/mocktail.dart';
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
  Future<Result<FileDiff>> loadDiff(RepoHandle repo, DiffTarget target) => _wrap(() => cli.diff(repo.path, target));
  @override
  Future<Result<FileContent>> loadFileContent(RepoHandle repo, DiffTarget target) =>
      _wrap(() => cli.fileContent(repo.path, target));
  @override
  Future<Result<void>> run(RepoHandle repo, GitAction action) => _wrap(() => cli.run(repo.path, action, identity));
  @override
  Future<Result<List<GitCommit>>> loadCommitsForRebase(RepoHandle repo, String base) =>
      _wrap(() => cli.commitsForRebase(repo.path, base));
  @override
  Future<Result<GitHubRepoInfo>> githubRepoInfo(RepoHandle repo) async =>
      const Success(GitHubRepoInfo(owner: 'octo', name: 'demo'));
  @override
  Future<Result<List<PullRequest>>> listPullRequests(RepoHandle repo) async => const Success([
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
        ),
      ]);
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

void main() {
  late Directory tmp;
  late String repo;
  const runner = GitRunner();
  final git = _CliGitRepository();

  setUp(() async {
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

  Future<void> pumpWorkspace(WidgetTester tester, Size size) async {
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
      final toolsLeft = tester.getTopLeft(find.byTooltip('Pull (fast-forward or merge)')).dx;
      final toolsRight = tester.getTopRight(find.byTooltip('Open folder')).dx;
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

  group('GitHub pull requests', () {
    setUp(() => runner.run(['remote', 'add', 'origin', 'https://github.com/octo/demo.git'], workingDirectory: repo));

    testWidgets('lists open PRs with CI and creates a new one', (tester) async {
      await pumpWorkspace(tester, const Size(1280, 720));
      expect(find.text('PULL REQUESTS'), findsOneWidget);
      expect(find.textContaining('Add a much better login screen'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsWidgets);
      expect(find.text('draft'), findsOneWidget);

      await tester.tap(find.textContaining('Add a much better login screen'));
      await settle(tester);
      expect(find.text('Checkout PR #12'), findsOneWidget);
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
