import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_manager/core/git/git_runner.dart';
import 'package:git_manager/features/repos/data/datasources/git_cli_data_source.dart';
import 'package:git_manager/features/repos/domain/entities/file_change.dart';
import 'package:git_manager/features/repos/domain/entities/file_diff.dart';
import 'package:git_manager/features/repos/domain/entities/git_action.dart';
import 'package:git_manager/features/repos/domain/entities/git_commit.dart';
import 'package:git_manager/features/repos/domain/entities/repo_snapshot.dart';
import 'package:git_manager/features/repos/domain/graph/commit_graph.dart';

/// Tests de integración contra el binario git real, en un repo temporal.
void main() {
  late Directory tmp;
  late String repo;
  const runner = GitRunner();
  const cli = GitCliDataSource(runner);
  const identity = GitIdentity(login: 'tester', token: 't0k3n', name: 'Test User', email: 'test@example.com');

  Future<void> write(String name, String content) => File('$repo/$name').writeAsString(content);
  Future<void> act(GitAction a) => cli.run(repo, a, identity);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gm_test_');
    repo = (await Directory('${tmp.path}/repo').create()).path;
    await runner.run(['init', '-q', '-b', 'main'], workingDirectory: repo);
    await write('a.txt', 'one\ntwo\nthree\n');
    await act(const StageAllAction());
    await act(const CommitAction('first commit'));
  });

  tearDown(() => tmp.delete(recursive: true));

  test('commits use the account identity, not the global one', () async {
    final history = await cli.history(repo, limit: 10);
    expect(history, hasLength(1));
    expect(history.single.authorName, 'Test User');
    expect(history.single.authorEmail, 'test@example.com');
    expect(history.single.subject, 'first commit');
    expect(history.single.refs.first.name, 'main');
    expect(history.single.refs.first.isCurrent, isTrue);
  });

  test('status, stage, unstage, diff and discard', () async {
    await write('a.txt', 'one\n2\nthree\n');
    await write('new.txt', 'hello\n');

    var snap = await cli.snapshot(repo);
    expect(snap.currentBranch, 'main');
    expect(snap.unstaged.map((c) => c.path), containsAll(['a.txt', 'new.txt']));
    expect(snap.unstaged.firstWhere((c) => c.path == 'new.txt').type, ChangeType.untracked);

    final diff = await cli.diff(repo, const DiffTarget(source: DiffSource.unstaged, path: 'a.txt'));
    expect(diff.additions, 1);
    expect(diff.deletions, 1);
    expect(diff.hunks.single.lines.firstWhere((l) => l.type == DiffLineType.added).text, '2');

    final untracked = await cli.diff(
        repo, const DiffTarget(source: DiffSource.unstaged, path: 'new.txt', untracked: true));
    expect(untracked.additions, 1);

    await act(const StageAction(['a.txt']));
    snap = await cli.snapshot(repo);
    expect(snap.staged.single.path, 'a.txt');

    await act(const UnstageAction(['a.txt']));
    snap = await cli.snapshot(repo);
    expect(snap.staged, isEmpty);

    await act(DiscardAction(snap.unstaged));
    snap = await cli.snapshot(repo);
    expect(snap.hasChanges, isFalse);
  });

  test('branches, merge, graph and commit detail', () async {
    await act(const CreateBranchAction('feature'));
    await write('b.txt', 'b\n');
    await act(const StageAllAction());
    await act(const CommitAction('feature work'));
    await act(const CheckoutAction('main'));
    await write('c.txt', 'c\n');
    await act(const StageAllAction());
    await act(const CommitAction('main work'));
    await act(const MergeAction('feature'));
    await act(const CreateTagAction('v1.0', 'HEAD'));

    final snap = await cli.snapshot(repo);
    expect(snap.localBranches.map((r) => r.name), containsAll(['main', 'feature']));
    expect(snap.tags.single.name, 'v1.0');
    expect(snap.currentRef?.isHead, isTrue);

    final history = await cli.history(repo, limit: 50);
    expect(history, hasLength(4));
    expect(history.first.isMerge, isTrue);
    expect(history.first.refs.map((r) => r.kind), containsAll([RefLabelKind.local, RefLabelKind.tag]));

    final graph = buildCommitGraph(history);
    expect(graph.first.lane, 0);
    // El merge abre un segundo carril para la rama feature.
    expect(graph.map((r) => r.width).reduce((a, b) => a > b ? a : b), 2);

    final detail = await cli.commitDetail(repo, history[1].sha);
    expect(detail.changes, isNotEmpty);

    final root = history.last;
    final rootDetail = await cli.commitDetail(repo, root.sha);
    expect(rootDetail.changes.single.path, 'a.txt');
    final rootDiff = await cli.diff(
        repo, DiffTarget(source: DiffSource.commit, path: 'a.txt', commitSha: root.sha));
    expect(rootDiff.additions, 3);

    final content = await cli.fileContent(
        repo, DiffTarget(source: DiffSource.commit, path: 'a.txt', commitSha: root.sha));
    expect(content.text, 'one\ntwo\nthree\n');
  });

  test('stash and pop', () async {
    await write('a.txt', 'changed\n');
    await act(const StashAction(message: 'wip'));
    var snap = await cli.snapshot(repo);
    expect(snap.hasChanges, isFalse);
    expect(snap.stashes.single.message, contains('wip'));

    await act(const StashPopAction());
    snap = await cli.snapshot(repo);
    expect(snap.hasChanges, isTrue);
    expect(snap.stashes, isEmpty);
  });

  test('push to a remote and track ahead/behind', () async {
    final remote = '${tmp.path}/remote.git';
    await runner.run(['init', '-q', '--bare', remote], workingDirectory: tmp.path);
    await runner.run(['remote', 'add', 'origin', remote], workingDirectory: repo);

    await act(const PushAction());
    var snap = await cli.snapshot(repo);
    expect(snap.currentRef?.upstream, 'origin/main');
    expect(snap.remoteBranches.single.name, 'origin/main');

    await write('a.txt', 'more\n');
    await act(const StageAllAction());
    await act(const CommitAction('ahead'));
    snap = await cli.snapshot(repo);
    expect(snap.currentRef?.ahead, 1);

    await act(const PushAction());
    await act(const FetchAction());
    snap = await cli.snapshot(repo);
    expect(snap.currentRef?.ahead, 0);

    final cloned = await cli.clone(remote, tmp.path, identity);
    expect(await Directory('$cloned/.git').exists(), isTrue);
  });

  test('merge conflict is detected and can be aborted', () async {
    await act(const CreateBranchAction('other'));
    await write('a.txt', 'other side\n');
    await act(const StageAllAction());
    await act(const CommitAction('other'));
    await act(const CheckoutAction('main'));
    await write('a.txt', 'main side\n');
    await act(const StageAllAction());
    await act(const CommitAction('main'));

    await expectLater(act(const MergeAction('other')), throwsA(anything));
    var snap = await cli.snapshot(repo);
    expect(snap.pendingOperation, PendingOperation.merge);
    expect(snap.hasConflicts, isTrue);

    final diff = await cli.diff(repo, const DiffTarget(source: DiffSource.unstaged, path: 'a.txt'));
    expect(diff.hunks.single.lines.any((l) => l.text.startsWith('<<<<<<<')), isTrue);

    await act(const AbortOperationAction());
    snap = await cli.snapshot(repo);
    expect(snap.pendingOperation, PendingOperation.none);
    expect(snap.hasChanges, isFalse);
  });
}
