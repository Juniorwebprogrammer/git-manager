enum ChangeType { added, modified, deleted, renamed, copied, typeChanged, untracked, conflicted }

class FileChange {
  final String path;

  /// Ruta anterior en renombrados/copias.
  final String? oldPath;
  final ChangeType type;

  const FileChange({required this.path, required this.type, this.oldPath});

  String get letter => switch (type) {
        ChangeType.added => 'A',
        ChangeType.modified => 'M',
        ChangeType.deleted => 'D',
        ChangeType.renamed => 'R',
        ChangeType.copied => 'C',
        ChangeType.typeChanged => 'T',
        ChangeType.untracked => 'U',
        ChangeType.conflicted => '!',
      };

  String get fileName {
    final i = path.lastIndexOf('/');
    return i == -1 ? path : path.substring(i + 1);
  }

  String get directory {
    final i = path.lastIndexOf('/');
    return i == -1 ? '' : path.substring(0, i);
  }

  @override
  bool operator ==(Object other) =>
      other is FileChange && other.path == path && other.oldPath == oldPath && other.type == type;

  @override
  int get hashCode => Object.hash(path, oldPath, type);
}

ChangeType changeTypeFromLetter(String letter) => switch (letter) {
      'A' => ChangeType.added,
      'D' => ChangeType.deleted,
      'R' => ChangeType.renamed,
      'C' => ChangeType.copied,
      'T' => ChangeType.typeChanged,
      'U' => ChangeType.conflicted,
      '?' => ChangeType.untracked,
      _ => ChangeType.modified,
    };
