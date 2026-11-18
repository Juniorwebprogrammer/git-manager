import 'file_change.dart';

enum RefLabelKind { head, local, remote, tag }

/// Decoración de un commit en el grafo (rama, remota, tag, HEAD).
class RefLabel {
  final String name;
  final RefLabelKind kind;

  /// `true` si es la rama local en la que está HEAD.
  final bool isCurrent;

  const RefLabel(this.name, this.kind, {this.isCurrent = false});
}

class GitCommit {
  final String sha;
  final List<String> parents;
  final String authorName;
  final String authorEmail;
  final DateTime date;
  final List<RefLabel> refs;
  final String subject;

  const GitCommit({
    required this.sha,
    required this.parents,
    required this.authorName,
    required this.authorEmail,
    required this.date,
    required this.refs,
    required this.subject,
  });

  String get shortSha => sha.length > 7 ? sha.substring(0, 7) : sha;
  bool get isMerge => parents.length > 1;
}

class GitCommitDetail {
  final String sha;
  final List<String> parents;
  final String authorName;
  final String authorEmail;
  final DateTime authorDate;
  final String committerName;
  final DateTime commitDate;
  final String message;
  final List<FileChange> changes;

  const GitCommitDetail({
    required this.sha,
    required this.parents,
    required this.authorName,
    required this.authorEmail,
    required this.authorDate,
    required this.committerName,
    required this.commitDate,
    required this.message,
    required this.changes,
  });

  String get subject => message.split('\n').first;

  String get body {
    final idx = message.indexOf('\n');
    return idx == -1 ? '' : message.substring(idx + 1).trim();
  }
}
