import '../../domain/entities/file_change.dart';
import '../../domain/entities/file_diff.dart';
import '../../domain/entities/git_commit.dart';
import '../../domain/entities/repo_snapshot.dart';

/// Formato de `git log` que entiende [parseLog]. Requiere `--decorate=full`.
const logFormat = '%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1e';

/// Formato de `git for-each-ref` que entiende [parseRefs].
const refFormat =
    '%(HEAD)%1f%(refname)%1f%(objectname)%1f%(*objectname)%1f%(upstream:short)%1f%(upstream:track,nobracket)';

/// Formato de `git show -s` que entiende [parseCommitHeader].
const commitDetailFormat = '%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ct%x1f%B';

DateTime _epoch(String seconds) =>
    DateTime.fromMillisecondsSinceEpoch((int.tryParse(seconds) ?? 0) * 1000);

List<GitCommit> parseLog(String output) {
  final commits = <GitCommit>[];
  for (var record in output.split('\x1e')) {
    record = record.replaceFirst(RegExp(r'^\s+'), '');
    if (record.isEmpty) continue;
    final f = record.split('\x1f');
    if (f.length < 7) continue;
    commits.add(GitCommit(
      sha: f[0],
      parents: f[1].isEmpty ? const [] : f[1].split(' '),
      authorName: f[2],
      authorEmail: f[3],
      date: _epoch(f[4]),
      refs: parseDecorations(f[5]),
      subject: f.sublist(6).join('\x1f').trimRight(),
    ));
  }
  return commits;
}

/// Interpreta `%D` con `--decorate=full`, p. ej.
/// `HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1`.
List<RefLabel> parseDecorations(String raw) {
  if (raw.trim().isEmpty) return const [];
  final labels = <RefLabel>[];
  for (var part in raw.split(', ')) {
    part = part.trim();
    var current = false;
    if (part.startsWith('HEAD -> ')) {
      current = true;
      part = part.substring(8);
    } else if (part == 'HEAD') {
      labels.add(const RefLabel('HEAD', RefLabelKind.head, isCurrent: true));
      continue;
    }
    if (part.startsWith('tag: ')) part = part.substring(5);

    if (part.startsWith('refs/heads/')) {
      labels.add(RefLabel(part.substring(11), RefLabelKind.local, isCurrent: current));
    } else if (part.startsWith('refs/remotes/')) {
      final name = part.substring(13);
      if (name.endsWith('/HEAD')) continue;
      labels.add(RefLabel(name, RefLabelKind.remote));
    } else if (part.startsWith('refs/tags/')) {
      labels.add(RefLabel(part.substring(10), RefLabelKind.tag));
    }
  }
  // La rama actual primero, luego locales, remotas y tags.
  labels.sort((a, b) {
    if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
    return a.kind.index.compareTo(b.kind.index);
  });
  return labels;
}

List<GitRef> parseRefs(String output) {
  final refs = <GitRef>[];
  for (final line in output.split('\n')) {
    if (line.trim().isEmpty) continue;
    final f = line.split('\x1f');
    if (f.length < 6) continue;
    final fullName = f[1];
    final RefKind kind;
    final String name;
    if (fullName.startsWith('refs/heads/')) {
      kind = RefKind.local;
      name = fullName.substring(11);
    } else if (fullName.startsWith('refs/remotes/')) {
      name = fullName.substring(13);
      if (name.endsWith('/HEAD')) continue;
      kind = RefKind.remote;
    } else if (fullName.startsWith('refs/tags/')) {
      kind = RefKind.tag;
      name = fullName.substring(10);
    } else {
      continue;
    }

    var ahead = 0, behind = 0;
    final track = f[5];
    final aheadMatch = RegExp(r'ahead (\d+)').firstMatch(track);
    final behindMatch = RegExp(r'behind (\d+)').firstMatch(track);
    if (aheadMatch != null) ahead = int.parse(aheadMatch.group(1)!);
    if (behindMatch != null) behind = int.parse(behindMatch.group(1)!);

    refs.add(GitRef(
      name: name,
      fullName: fullName,
      kind: kind,
      sha: f[3].isNotEmpty ? f[3] : f[2],
      upstream: f[4].isEmpty ? null : f[4],
      ahead: ahead,
      behind: behind,
      upstreamGone: track.contains('gone'),
      isHead: f[0] == '*',
    ));
  }
  return refs;
}

/// `git status --porcelain=v1 -z --untracked-files=all`.
({List<FileChange> staged, List<FileChange> unstaged}) parseStatus(String output) {
  final staged = <FileChange>[];
  final unstaged = <FileChange>[];
  final entries = output.split('\x00');
  const conflictCodes = {'DD', 'AU', 'UD', 'UA', 'DU', 'AA', 'UU'};

  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    if (entry.length < 4) continue;
    final x = entry[0];
    final y = entry[1];
    final path = entry.substring(3);
    String? oldPath;
    if (x == 'R' || x == 'C' || y == 'R' || y == 'C') {
      oldPath = i + 1 < entries.length ? entries[++i] : null;
    }

    if (x == '?' && y == '?') {
      unstaged.add(FileChange(path: path, type: ChangeType.untracked));
      continue;
    }
    if (x == '!') continue;
    if (conflictCodes.contains('$x$y')) {
      unstaged.add(FileChange(path: path, type: ChangeType.conflicted));
      continue;
    }
    if (x != ' ') {
      staged.add(FileChange(path: path, oldPath: oldPath, type: changeTypeFromLetter(x)));
    }
    if (y != ' ') {
      unstaged.add(FileChange(
        path: path,
        oldPath: y == 'R' ? oldPath : null,
        type: changeTypeFromLetter(y),
      ));
    }
  }
  return (staged: staged, unstaged: unstaged);
}

/// `git diff-tree --name-status -z` / `git diff --name-status -z`.
List<FileChange> parseNameStatus(String output) {
  final changes = <FileChange>[];
  final tokens = output.split('\x00');
  var i = 0;
  while (i < tokens.length) {
    final status = tokens[i].trim();
    if (status.isEmpty) {
      i++;
      continue;
    }
    final letter = status[0];
    if (letter == 'R' || letter == 'C') {
      if (i + 2 >= tokens.length) break;
      changes.add(FileChange(
        path: tokens[i + 2],
        oldPath: tokens[i + 1],
        type: changeTypeFromLetter(letter),
      ));
      i += 3;
    } else {
      if (i + 1 >= tokens.length) break;
      changes.add(FileChange(path: tokens[i + 1], type: changeTypeFromLetter(letter)));
      i += 2;
    }
  }
  return changes;
}

List<GitStash> parseStashes(String output) => [
      for (final line in output.split('\n'))
        if (line.contains('\x1f'))
          GitStash(line.split('\x1f')[0], line.split('\x1f').sublist(1).join(' ')),
    ];

GitCommitDetail parseCommitHeader(String output, List<FileChange> changes) {
  final f = output.split('\x1f');
  return GitCommitDetail(
    sha: f[0].trim(),
    parents: f[1].isEmpty ? const [] : f[1].split(' '),
    authorName: f[2],
    authorEmail: f[3],
    authorDate: _epoch(f[4]),
    committerName: f[5],
    commitDate: _epoch(f[6]),
    message: f.sublist(7).join('\x1f').trim(),
    changes: changes,
  );
}

final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$');

/// Parsea un diff unificado de un solo fichero.
FileDiff parseUnifiedDiff(String path, String output, {int maxLines = 20000}) {
  if (RegExp(r'^Binary files .* differ$', multiLine: true).hasMatch(output) ||
      output.contains('\nGIT binary patch')) {
    return FileDiff(path: path, isBinary: true);
  }

  final hunks = <DiffHunk>[];
  String? header;
  var lines = <DiffLine>[];
  var oldNo = 0, newNo = 0, total = 0;
  var oldStart = 0, newStart = 0;
  var truncated = false;

  void flush() {
    if (header != null) hunks.add(DiffHunk(header, lines, oldStart: oldStart, newStart: newStart));
  }

  for (final raw in output.split('\n')) {
    final match = _hunkHeader.firstMatch(raw);
    if (match != null) {
      flush();
      header = raw;
      lines = <DiffLine>[];
      oldNo = oldStart = int.parse(match.group(1)!);
      newNo = newStart = int.parse(match.group(2)!);
      continue;
    }
    if (header == null) continue; // cabecera diff --git / index / --- / +++
    if (total >= maxLines) {
      truncated = true;
      break;
    }
    if (raw.startsWith('+')) {
      lines.add(DiffLine(DiffLineType.added, raw.substring(1), newNumber: newNo++));
    } else if (raw.startsWith('-')) {
      lines.add(DiffLine(DiffLineType.removed, raw.substring(1), oldNumber: oldNo++));
    } else if (raw.startsWith(' ')) {
      lines.add(DiffLine(DiffLineType.context, raw.substring(1),
          oldNumber: oldNo++, newNumber: newNo++));
    } else if (raw.startsWith('\\')) {
      lines.add(DiffLine(DiffLineType.meta, raw));
    } else {
      continue;
    }
    total++;
  }
  flush();
  return FileDiff(path: path, hunks: hunks, truncated: truncated);
}

/// Diff sintético de "todo añadido" para ficheros sin seguimiento.
FileDiff allAddedDiff(String path, String content, {int maxLines = 20000}) {
  var lines = content.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  final truncated = lines.length > maxLines;
  if (truncated) lines = lines.sublist(0, maxLines);
  return FileDiff(
    path: path,
    truncated: truncated,
    hunks: [
      if (lines.isNotEmpty)
        DiffHunk('@@ -0,0 +1,${lines.length} @@ (new file)', [
          for (var i = 0; i < lines.length; i++)
            DiffLine(DiffLineType.added, lines[i], newNumber: i + 1),
        ]),
    ],
  );
}
