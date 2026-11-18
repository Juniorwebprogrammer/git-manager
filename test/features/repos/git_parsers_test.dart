import 'package:flutter_test/flutter_test.dart';
import 'package:git_manager/features/repos/data/parsers/git_parsers.dart';
import 'package:git_manager/features/repos/domain/entities/file_change.dart';
import 'package:git_manager/features/repos/domain/entities/file_diff.dart';
import 'package:git_manager/features/repos/domain/entities/git_commit.dart';
import 'package:git_manager/features/repos/domain/graph/commit_graph.dart';

GitCommit _c(String sha, List<String> parents) => GitCommit(
      sha: sha,
      parents: parents,
      authorName: '',
      authorEmail: '',
      date: DateTime(2026),
      refs: const [],
      subject: sha,
    );

void main() {
  test('parseDecorations classifies refs and puts the current branch first', () {
    final refs = parseDecorations(
        'refs/remotes/origin/main, HEAD -> refs/heads/main, tag: refs/tags/v1, refs/remotes/origin/HEAD');
    expect(refs.map((r) => r.name), ['main', 'origin/main', 'v1']);
    expect(refs.first.isCurrent, isTrue);
    expect(refs[1].kind, RefLabelKind.remote);
    expect(refs[2].kind, RefLabelKind.tag);
  });

  test('parseStatus handles renames, untracked and conflicts', () {
    final status = parseStatus('R  new.txt\x00old.txt\x00 M mod.txt\x00?? u.txt\x00UU c.txt\x00MM both.txt\x00');
    expect(status.staged.map((c) => c.path), ['new.txt', 'both.txt']);
    expect(status.staged.first.oldPath, 'old.txt');
    expect(status.unstaged.map((c) => c.type),
        [ChangeType.modified, ChangeType.untracked, ChangeType.conflicted, ChangeType.modified]);
  });

  test('parseNameStatus handles renames', () {
    final changes = parseNameStatus('M\x00a.txt\x00R087\x00old.txt\x00new.txt\x00D\x00gone.txt\x00');
    expect(changes.map((c) => c.path), ['a.txt', 'new.txt', 'gone.txt']);
    expect(changes[1].oldPath, 'old.txt');
    expect(changes[2].type, ChangeType.deleted);
  });

  test('parseUnifiedDiff numbers lines per side', () {
    const raw = 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@ fn\n a\n-b\n+B\n c\n';
    final diff = parseUnifiedDiff('x', raw);
    final lines = diff.hunks.single.lines;
    expect(lines.map((l) => l.type),
        [DiffLineType.context, DiffLineType.removed, DiffLineType.added, DiffLineType.context]);
    expect(lines[1].oldNumber, 2);
    expect(lines[2].newNumber, 2);
    expect(lines[3].oldNumber, 3);
    expect(lines[3].newNumber, 3);
  });

  test('parseUnifiedDiff detects binary files', () {
    expect(parseUnifiedDiff('x', 'Binary files a/x and b/x differ\n').isBinary, isTrue);
  });

  test('buildCommitGraph: branch + merge uses two lanes and converges', () {
    // M merges F into B; F and B both come from A.
    final rows = buildCommitGraph([
      _c('M', ['B', 'F']),
      _c('F', ['A']),
      _c('B', ['A']),
      _c('A', []),
    ]);
    expect(rows.map((r) => r.lane), [0, 1, 0, 0]);
    // A recibe dos líneas: la de B (carril 0) y la de F (carril 1).
    final intoA = rows[3].lines.where((l) => l.segment == GraphSegment.top).toList();
    expect(intoA.map((l) => l.fromLane).toSet(), {0, 1});
    // Tras A ya no queda ningún carril abierto.
    expect(rows[3].lines.where((l) => l.segment == GraphSegment.bottom), isEmpty);
  });

  test('buildCommitGraph: independent tips get their own lane', () {
    final rows = buildCommitGraph([
      _c('X', ['A']),
      _c('Y', ['A']),
      _c('A', []),
    ]);
    expect(rows[0].lane, 0);
    expect(rows[1].lane, 1);
    expect(rows[2].lane, 0);
  });
}
