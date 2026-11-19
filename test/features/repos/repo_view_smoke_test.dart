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
import 'package:git_manager/features/repos/domain/entities/remote_repository.dart';
import 'package:git_manager/features/repos/domain/entities/repo_snapshot.dart';
import 'package:git_manager/features/repos/domain/repositories/git_repository.dart';
import 'package:git_manager/core/theme/app_theme.dart';
import 'package:git_manager/features/accounts/domain/entities/git_account.dart';
import 'package:git_manager/features/accounts/domain/repositories/account_repository.dart';
import 'package:git_manager/features/repos/presentation/pages/workspace_page.dart';
import 'package:mocktail/mocktail.dart';
import 'package:git_manager/features/repos/presentation/widgets/commit_detail_panel.dart';
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
  });
}
