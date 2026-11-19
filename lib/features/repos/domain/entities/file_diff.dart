enum DiffSource { unstaged, staged, commit }

/// Qué fichero, y en qué "versión", queremos ver en el visor de diffs.
class DiffTarget {
  final DiffSource source;
  final String path;
  final String? oldPath;

  /// Solo para [DiffSource.commit].
  final String? commitSha;
  final String? parentSha;

  /// Fichero sin seguimiento (no hay versión previa en git).
  final bool untracked;

  /// El fichero ya no existe en esta versión (borrado).
  final bool deleted;

  /// Fichero con conflictos de merge/rebase sin resolver.
  final bool conflicted;

  /// Texto para la cabecera del visor (p. ej. "main ↔ feature" al comparar).
  final String? title;

  const DiffTarget({
    required this.source,
    required this.path,
    this.oldPath,
    this.commitSha,
    this.parentSha,
    this.untracked = false,
    this.deleted = false,
    this.conflicted = false,
    this.title,
  });

  /// Se puede hacer stage/unstage/descartar por trozos o por líneas.
  bool get supportsPartialStaging =>
      source != DiffSource.commit && !untracked && !conflicted && !deleted && oldPath == null;

  @override
  bool operator ==(Object other) =>
      other is DiffTarget &&
      other.source == source &&
      other.path == path &&
      other.oldPath == oldPath &&
      other.commitSha == commitSha;

  @override
  int get hashCode => Object.hash(source, path, oldPath, commitSha);
}

enum DiffLineType { context, added, removed, meta }

class DiffLine {
  final DiffLineType type;
  final String text;
  final int? oldNumber;
  final int? newNumber;

  const DiffLine(this.type, this.text, {this.oldNumber, this.newNumber});
}

class DiffHunk {
  final String header;
  final List<DiffLine> lines;

  /// Línea de inicio en el lado antiguo / nuevo (`@@ -oldStart +newStart @@`).
  final int oldStart;
  final int newStart;

  const DiffHunk(this.header, this.lines, {this.oldStart = 0, this.newStart = 0});

  bool get hasChanges => lines.any((l) => l.type == DiffLineType.added || l.type == DiffLineType.removed);
}

class FileDiff {
  final String path;
  final bool isBinary;
  final List<DiffHunk> hunks;
  final bool truncated;

  const FileDiff({
    required this.path,
    this.isBinary = false,
    this.hunks = const [],
    this.truncated = false,
  });

  int get additions =>
      hunks.fold(0, (n, h) => n + h.lines.where((l) => l.type == DiffLineType.added).length);

  int get deletions =>
      hunks.fold(0, (n, h) => n + h.lines.where((l) => l.type == DiffLineType.removed).length);
}

/// Contenido completo de un fichero en una versión concreta.
class FileContent {
  final String path;
  final String text;
  final bool isBinary;
  final bool truncated;

  const FileContent({
    required this.path,
    required this.text,
    this.isBinary = false,
    this.truncated = false,
  });
}
