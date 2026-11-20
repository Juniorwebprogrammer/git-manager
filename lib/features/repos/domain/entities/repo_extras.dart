import 'file_change.dart';
import 'git_action.dart';
import 'git_commit.dart';

/// Qué haría "Undo" ahora mismo y cómo rehacerlo después.
class UndoPlan {
  /// "Undo commit 'Add login'", "Undo checkout of feature"…
  final String label;
  final GitAction undo;
  final String redoLabel;
  final GitAction redo;

  const UndoPlan({required this.label, required this.undo, required this.redoLabel, required this.redo});
}

/// Una línea de `git blame`.
class BlameLine {
  final int number;
  final String text;
  final String sha;
  final String author;
  final DateTime date;
  final String summary;

  const BlameLine({
    required this.number,
    required this.text,
    required this.sha,
    required this.author,
    required this.date,
    required this.summary,
  });

  /// Líneas cambiadas en el directorio de trabajo y aún sin commit.
  bool get isUncommitted => RegExp(r'^0+$').hasMatch(sha);
  String get shortSha => sha.length > 7 ? sha.substring(0, 7) : sha;
}

/// Un commit del historial de un fichero, con el nombre que tenía entonces
/// (el historial sigue los renombrados).
class FileHistoryEntry {
  final GitCommit commit;
  final String path;
  final ChangeType change;

  const FileHistoryEntry({required this.commit, required this.path, required this.change});
}

/// Configuración de firma de commits (GPG o SSH) que ve git en este repo.
class SigningConfig {
  final bool signByDefault;
  final SigningFormat format;
  final String key;

  const SigningConfig({this.signByDefault = false, this.format = SigningFormat.gpg, this.key = ''});

  bool get hasKey => key.isNotEmpty;
}

/// Tipos de Conventional Commits (https://www.conventionalcommits.org).
const conventionalTypes = <String, String>{
  'feat': 'A new feature',
  'fix': 'A bug fix',
  'docs': 'Documentation only',
  'style': 'Formatting, no code change',
  'refactor': 'Neither fixes a bug nor adds a feature',
  'perf': 'Performance improvement',
  'test': 'Adding or fixing tests',
  'build': 'Build system or dependencies',
  'ci': 'CI configuration',
  'chore': 'Other changes',
  'revert': 'Reverts a previous commit',
};

/// `type(scope)!: summary`; sin tipo, el resumen tal cual.
String composeConventionalSummary({String? type, String scope = '', bool breaking = false, required String summary}) {
  final text = summary.trim();
  if (type == null || type.isEmpty) return text;
  final scopePart = scope.trim().isEmpty ? '' : '(${scope.trim()})';
  return '$type$scopePart${breaking ? '!' : ''}: $text';
}

/// Plantilla de `commit.template` sin las líneas de comentario.
String cleanCommitTemplate(String raw) => raw
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('#'))
    .join('\n')
    .trim();

enum RemoteUpdateKind { newBranch, updated, deleted }

/// Algo que cambió en una rama remota al hacer fetch (p. ej. un compañero
/// hizo push).
class RemoteUpdate {
  /// `origin/feature-x`
  final String ref;
  final RemoteUpdateKind kind;

  /// Commits nuevos (en ramas nuevas o actualizadas).
  final int commits;

  /// Autor del último commit.
  final String author;

  /// SHA nuevo de la rama (vacío si se borró).
  final String sha;

  const RemoteUpdate({required this.ref, required this.kind, this.commits = 0, this.author = '', this.sha = ''});

  String get summary => switch (kind) {
        RemoteUpdateKind.newBranch => 'new branch $ref${author.isEmpty ? '' : ' by $author'}',
        RemoteUpdateKind.updated =>
          '$ref: $commits new commit${commits == 1 ? '' : 's'}${author.isEmpty ? '' : ' by $author'}',
        RemoteUpdateKind.deleted => '$ref was deleted',
      };
}
