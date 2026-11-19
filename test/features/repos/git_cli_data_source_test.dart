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
import 'package:git_manager/core/error/app_exception.dart';
import 'package:git_manager/features/repos/domain/conflicts/conflict_parser.dart';
import 'package:git_manager/features/repos/domain/patch/patch_builder.dart';

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
    await runner.run(['init', '-q', '--bare', '-b', 'main', remote], workingDirectory: tmp.path);
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

  group('rebase', () {
    Future<void> commitFile(String name, String content, String message) async {
      await write(name, content);
      await act(const StageAllAction());
      await act(CommitAction(message));
    }

    Future<List<String>> subjects() async => (await cli.history(repo, limit: 50)).map((c) => c.subject).toList();

    setUp(() async {
      await act(const CreateBranchAction('feature'));
      await commitFile('f.txt', 'feature\n', 'feature work');
      await act(const CheckoutAction('main'));
      await commitFile('m.txt', 'main\n', 'main work');
    });

    test('rebases the current branch onto another (linear history)', () async {
      await act(const CheckoutAction('feature'));
      await act(const RebaseAction('main'));

      final history = await cli.history(repo, limit: 50);
      final feature = history.firstWhere((c) => c.subject == 'feature work');
      final main = history.firstWhere((c) => c.subject == 'main work');
      expect(feature.parents, [main.sha]);
      expect((await cli.snapshot(repo)).currentBranch, 'feature');
    });

    test('rebases another branch onto the current one and checks it out', () async {
      await act(const RebaseAction('main', branch: 'feature'));
      final snap = await cli.snapshot(repo);
      expect(snap.currentBranch, 'feature');
      expect(await subjects(), ['feature work', 'main work', 'first commit']);
    });

    test('autostashes local changes', () async {
      await act(const CheckoutAction('feature'));
      await write('a.txt', 'dirty\n');
      await act(const RebaseAction('main'));
      expect((await cli.snapshot(repo)).unstaged.single.path, 'a.txt');
    });

    test('conflict: reports progress, then continue finishes it', () async {
      await commitFile('f.txt', 'main version\n', 'main touches f');
      await act(const CheckoutAction('feature'));

      await expectLater(act(const RebaseAction('main')), throwsA(anything));
      var snap = await cli.snapshot(repo);
      expect(snap.pendingOperation, PendingOperation.rebase);
      expect(snap.rebase?.branch, 'feature');
      expect(snap.rebase?.step, 1);
      expect(snap.rebase?.total, 1);
      expect(snap.hasConflicts, isTrue);

      await write('f.txt', 'resolved\n');
      await act(const StageAction(['f.txt']));
      await act(const ContinueOperationAction());

      snap = await cli.snapshot(repo);
      expect(snap.pendingOperation, PendingOperation.none);
      expect(snap.currentBranch, 'feature');
      expect(await subjects(), ['feature work', 'main touches f', 'main work', 'first commit']);
    });

    test('conflict: abort restores the branch', () async {
      await commitFile('f.txt', 'main version\n', 'main touches f');
      await act(const CheckoutAction('feature'));
      final before = (await cli.snapshot(repo)).headSha;

      await expectLater(act(const RebaseAction('main')), throwsA(anything));
      await act(const AbortOperationAction());

      final snap = await cli.snapshot(repo);
      expect(snap.pendingOperation, PendingOperation.none);
      expect(snap.currentBranch, 'feature');
      expect(snap.headSha, before);
    });

    test('pull --rebase keeps history linear', () async {
      final remote = '${tmp.path}/remote.git';
      await runner.run(['init', '-q', '--bare', '-b', 'main', remote], workingDirectory: tmp.path);
      await runner.run(['remote', 'add', 'origin', remote], workingDirectory: repo);
      await act(const PushAction());

      final parent = await Directory('${tmp.path}/other').create();
      final other = await cli.clone(remote, parent.path, identity);
      await File('$other/remote.txt').writeAsString('r\n');
      await cli.run(other, const StageAllAction(), identity);
      await cli.run(other, const CommitAction('remote work'), identity);
      await cli.run(other, const PushAction(), identity);

      await commitFile('local.txt', 'l\n', 'local work');
      await act(const PullAction(rebase: true));

      final history = await cli.history(repo, limit: 50);
      expect(history.where((c) => c.isMerge), isEmpty);
      final local = history.firstWhere((c) => c.subject == 'local work');
      final remoteWork = history.firstWhere((c) => c.subject == 'remote work');
      expect(local.parents, [remoteWork.sha]);
    });
  });

  group('partial staging, merge modes, conflicts, interactive rebase, PR checkout', () {
    Future<void> commitFile(String name, String content, String message) async {
      await write(name, content);
      await act(const StageAllAction());
      await act(CommitAction(message));
    }

    Future<String> indexVersion(String file) => runner.run(['show', ':$file'], workingDirectory: repo);
    Future<String> readFile(String file) => File('$repo/$file').readAsString();
    Future<FileDiff> unstagedDiff(String f) => cli.diff(repo, DiffTarget(source: DiffSource.unstaged, path: f));
    Future<FileDiff> stagedDiff(String f) => cli.diff(repo, DiffTarget(source: DiffSource.staged, path: f));
    String lines(List<String> l) => '${l.join('\n')}\n';

    test('stage and unstage a single hunk', () async {
      final original = List.generate(12, (i) => 'line ${i + 1}');
      await commitFile('h.txt', lines(original), 'twelve lines');
      final changed = [...original]
        ..[1] = 'LINE 2'
        ..[10] = 'LINE 11';
      await write('h.txt', lines(changed));

      final diff = await unstagedDiff('h.txt');
      expect(diff.hunks, hasLength(2));
      await act(ApplyPatchAction(
          buildPartialPatch(path: 'h.txt', hunk: diff.hunks.first, reverse: false)!, PatchTarget.stage));

      expect((await stagedDiff('h.txt')).hunks, hasLength(1));
      expect(await indexVersion('h.txt'), contains('LINE 2'));
      expect(await indexVersion('h.txt'), isNot(contains('LINE 11')));
      expect((await unstagedDiff('h.txt')).hunks.single.lines.any((l) => l.text == 'LINE 11'), isTrue);

      final staged = await stagedDiff('h.txt');
      await act(ApplyPatchAction(
          buildPartialPatch(path: 'h.txt', hunk: staged.hunks.single, reverse: true)!, PatchTarget.unstage));
      expect((await stagedDiff('h.txt')).hunks, isEmpty);
      expect(await readFile('h.txt'), lines(changed)); // el fichero no se toca
    });

    test('stage selected lines only', () async {
      await commitFile('l.txt', lines(['1', '2', '3', '4', '5', '6', '7']), 'seven');
      await write('l.txt', lines(['1', '2', '3', 'a', 'b', 'c', '6', '7']));

      final hunk = (await unstagedDiff('l.txt')).hunks.single;
      final minus4 = hunk.lines.indexWhere((l) => l.type == DiffLineType.removed && l.text == '4');
      final plusB = hunk.lines.indexWhere((l) => l.type == DiffLineType.added && l.text == 'b');
      await act(ApplyPatchAction(
        buildPartialPatch(path: 'l.txt', hunk: hunk, selected: {minus4, plusB}, reverse: false)!,
        PatchTarget.stage,
      ));
      expect(await indexVersion('l.txt'), lines(['1', '2', '3', '5', 'b', '6', '7']));
    });

    test('discard selected lines from the working tree', () async {
      await commitFile('d.txt', lines(['1', '2', '3', '4']), 'four');
      await write('d.txt', lines(['1', 'X', 'Y', '4']));

      final hunk = (await unstagedDiff('d.txt')).hunks.single;
      final minus2 = hunk.lines.indexWhere((l) => l.type == DiffLineType.removed && l.text == '2');
      final plusX = hunk.lines.indexWhere((l) => l.type == DiffLineType.added && l.text == 'X');
      await act(ApplyPatchAction(
        buildPartialPatch(path: 'd.txt', hunk: hunk, selected: {minus2, plusX}, reverse: true)!,
        PatchTarget.discard,
      ));
      expect(await readFile('d.txt'), lines(['1', '2', 'Y', '4']));
    });

    test('merge --no-ff always creates a merge commit; squash makes one commit', () async {
      await act(const CreateBranchAction('ff'));
      await commitFile('ff.txt', 'x\n', 'ff work');
      await act(const CheckoutAction('main'));
      await act(const MergeAction('ff', mode: MergeMode.noFastForward));
      var head = (await cli.history(repo, limit: 5)).first;
      expect(head.parents, hasLength(2));

      await act(const CreateBranchAction('sq'));
      await commitFile('s1.txt', '1\n', 'sq one');
      await commitFile('s2.txt', '2\n', 'sq two');
      await act(const CheckoutAction('main'));
      await act(const SquashMergeAction('sq', 'Squashed sq'));
      head = (await cli.history(repo, limit: 10)).firstWhere((c) => c.refs.any((r) => r.name == 'main'));
      expect(head.subject, 'Squashed sq');
      expect(head.parents, hasLength(1));
      expect(await File('$repo/s2.txt').exists(), isTrue);
    });

    test('resolve a conflict with the parsed file, then finish the merge', () async {
      await act(const CreateBranchAction('other'));
      await commitFile('c.txt', 'theirs\n', 'other');
      await act(const CheckoutAction('main'));
      await commitFile('c.txt', 'mine\n', 'main');
      await expectLater(act(const MergeAction('other')), throwsA(anything));

      final content = await cli.fileContent(
          repo, const DiffTarget(source: DiffSource.unstaged, path: 'c.txt', conflicted: true));
      final parsed = parseConflicts(content.text);
      expect(parsed.conflicts.single.ours, ['mine']);
      await act(ResolveConflictAction('c.txt', parsed.render([ConflictChoice.theirs])));

      var snap = await cli.snapshot(repo);
      expect(snap.hasConflicts, isFalse);
      await act(const ContinueOperationAction());
      snap = await cli.snapshot(repo);
      expect(snap.pendingOperation, PendingOperation.none);
      expect(await readFile('c.txt'), 'theirs\n');
    });

    test('interactive rebase: reorder, reword, squash and drop', () async {
      final base = (await cli.snapshot(repo)).headSha!;
      await commitFile('1.txt', '1\n', 'one');
      await commitFile('2.txt', '2\n', 'two');
      await commitFile('3.txt', '3\n', 'three');
      await commitFile('4.txt', '4\n', 'four');

      final commits = await cli.commitsForRebase(repo, base);
      expect(commits.map((c) => c.subject), ['one', 'two', 'three', 'four']);
      RebaseStep step(int i, [RebaseStepAction a = RebaseStepAction.pick, String? msg]) =>
          RebaseStep(sha: commits[i].sha, subject: commits[i].subject, action: a, message: msg);

      await act(InteractiveRebaseAction(base, [
        step(2), // three primero
        step(0, RebaseStepAction.reword, "one (it's renamed)"),
        step(3, RebaseStepAction.fixup), // four se une a one, sin su mensaje
        step(1, RebaseStepAction.drop),
      ]));

      final after = await cli.commitsForRebase(repo, base);
      expect(after.map((c) => c.subject), ['three', "one (it's renamed)"]);
      expect(await File('$repo/4.txt').exists(), isTrue);
      expect(await File('$repo/2.txt').exists(), isFalse);
      expect(after.first.authorName, 'Test User');
      expect((await cli.snapshot(repo)).pendingOperation, PendingOperation.none);
    });

    test('interactive rebase refuses to squash the first commit', () async {
      final base = (await cli.snapshot(repo)).headSha!;
      await commitFile('1.txt', '1\n', 'one');
      final c = (await cli.commitsForRebase(repo, base)).single;
      await expectLater(
        act(InteractiveRebaseAction(base, [RebaseStep(sha: c.sha, subject: c.subject, action: RebaseStepAction.squash)])),
        throwsA(isA<GitCommandException>()),
      );
    });

    test('checks out pull requests from the same repo and from forks', () async {
      final remote = '${tmp.path}/remote.git';
      await runner.run(['init', '-q', '--bare', '-b', 'main', remote], workingDirectory: tmp.path);
      await runner.run(['remote', 'add', 'origin', remote], workingDirectory: repo);
      await act(const PushAction());

      // Otra persona sube una rama, y GitHub expone las PR de forks en refs/pull/N/head.
      final parent = await Directory('${tmp.path}/other').create();
      final other = await cli.clone(remote, parent.path, identity);
      await File('$other/pr.txt').writeAsString('pr\n');
      await cli.run(other, const CreateBranchAction('feature/pr'), identity);
      await cli.run(other, const StageAllAction(), identity);
      await cli.run(other, const CommitAction('pr work'), identity);
      await cli.run(other, const PushAction(), identity);
      await runner.run(['push', 'origin', 'HEAD:refs/pull/7/head'], workingDirectory: other);

      await act(const CheckoutPullRequestAction(number: 3, headRef: 'feature/pr', sameRepo: true));
      var snap = await cli.snapshot(repo);
      expect(snap.currentBranch, 'feature/pr');
      expect(snap.currentRef?.upstream, 'origin/feature/pr');

      await act(const CheckoutAction('main'));
      await act(const CheckoutPullRequestAction(number: 7, headRef: 'whatever', sameRepo: false));
      snap = await cli.snapshot(repo);
      expect(snap.currentBranch, 'pr/7');
      expect(await File('$repo/pr.txt').exists(), isTrue);

      expect(await cli.remoteUrl(repo), remote);
    });
  });
}
