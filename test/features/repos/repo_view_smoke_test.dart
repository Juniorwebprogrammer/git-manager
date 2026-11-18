import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_manager/core/di/providers.dart';
import 'package:git_manager/core/error/result.dart';
import 'package:git_manager/core/git/git_runner.dart';
import 'package:git_manager/features/repos/data/datasources/git_cli_data_source.dart';
import 'package:git_manager/features/repos/domain/entities/file_diff.dart';
import 'package:git_manager/features/repos/domain/entities/git_action.dart';
import 'package:git_manager/features/repos/domain/entities/git_commit.dart';
import 'package:git_manager/features/repos/domain/entities/remote_repository.dart';
import 'package:git_manager/features/repos/domain/entities/repo_snapshot.dart';
import 'package:git_manager/features/repos/domain/repositories/git_repository.dart';
import 'package:git_manager/features/repos/presentation/pages/repo_view.dart';
import 'package:git_manager/features/repos/presentation/widgets/commit_detail_panel.dart';
import 'package:git_manager/features/repos/presentation/widgets/diff_viewer.dart';
import 'package:git_manager/features/repos/presentation/widgets/staging_panel.dart';

/// GitRepository real (git CLI) con una identidad fija, sin almacén seguro.
class _CliGitRepository implements GitRepository {
  final cli = const GitCliDataSource(GitRunner());
  static const identity = GitIdentity(login: 'u', token: 't', name: 'Smoke Test', email: 'smoke@example.com');

  /// El IO real se lanza en la zona raíz: dentro de la zona de tiempo
  /// falso de testWidgets los procesos nunca llegarían a completarse.
  Future<Result<T>> _wrap<T>(Future<T> Function() f) async => Success(await Zone.root.run(f));

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
      await tester.pump();
    }
  }

  testWidgets('a repo tab renders graph, staging, commit detail and diffs without layout errors', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [gitRepositoryProvider.overrideWithValue(git)],
      child: MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(body: RepoView(repo: (accountId: 'a', path: repo), active: false)),
      ),
    ));
    await settle(tester);

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
    expect(find.text('Unstaged changes'), findsOneWidget);
    await tester.tap(find.text('Split'));
    await settle(tester);
    await tester.tap(find.text('File'));
    await settle(tester);
    await tester.tap(find.byTooltip('Close (Esc)'));
    await settle(tester);

    // Detalle de un commit y su diff.
    await tester.tap(find.text('Add login screen'));
    await settle(tester);
    expect(find.byType(CommitDetailPanel), findsOneWidget);
    expect(find.text('1 file changed'), findsOneWidget);
    await tester.tap(find.text('login.dart'));
    await settle(tester);
    expect(find.textContaining('Commit '), findsWidgets);

    // Stage de un fichero desde el panel.
    await tester.tap(find.byTooltip('Close (Esc)'));
    await settle(tester);
    await tester.tap(find.text('// WIP'));
    await settle(tester);
    await tester.tap(find.text('Stage all'));
    await settle(tester);
    expect(find.text('Commit 2 files'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}
