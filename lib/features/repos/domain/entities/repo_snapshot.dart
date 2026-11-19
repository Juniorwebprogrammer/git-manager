import 'file_change.dart';

enum RefKind { local, remote, tag }

class GitRef {
  /// Nombre corto: `main`, `origin/main`, `v1.0`.
  final String name;
  final String fullName;
  final RefKind kind;
  final String sha;
  final String? upstream;
  final int ahead;
  final int behind;
  final bool upstreamGone;
  final bool isHead;

  const GitRef({
    required this.name,
    required this.fullName,
    required this.kind,
    required this.sha,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    this.upstreamGone = false,
    this.isHead = false,
  });

  /// `origin` en `origin/feature/x`.
  String? get remoteName {
    if (kind != RefKind.remote) return null;
    final i = name.indexOf('/');
    return i == -1 ? name : name.substring(0, i);
  }

  /// `feature/x` en `origin/feature/x`.
  String get nameWithoutRemote {
    if (kind != RefKind.remote) return name;
    final i = name.indexOf('/');
    return i == -1 ? name : name.substring(i + 1);
  }
}

class GitStash {
  /// `stash@{0}`
  final String ref;
  final String message;

  const GitStash(this.ref, this.message);
}

/// Operación a medio hacer que bloquea el flujo normal (tras un conflicto).
enum PendingOperation { none, merge, cherryPick, revert, rebase }

/// Progreso de un rebase en curso.
class RebaseProgress {
  /// Rama que se está rebasando (`feature`), si se conoce.
  final String? branch;

  /// SHA sobre el que se rebasa.
  final String? onto;
  final int step;
  final int total;

  const RebaseProgress({this.branch, this.onto, this.step = 0, this.total = 0});
}

/// Foto del estado del repositorio en un momento dado (todo menos el
/// historial, que se carga aparte porque es más pesado).
class RepoSnapshot {
  final String path;
  final String? currentBranch;
  final String? headSha;
  final List<GitRef> refs;
  final List<GitStash> stashes;
  final List<String> remotes;
  final List<FileChange> staged;
  final List<FileChange> unstaged;
  final PendingOperation pendingOperation;
  final RebaseProgress? rebase;

  const RepoSnapshot({
    required this.path,
    required this.currentBranch,
    required this.headSha,
    required this.refs,
    required this.stashes,
    required this.remotes,
    required this.staged,
    required this.unstaged,
    this.pendingOperation = PendingOperation.none,
    this.rebase,
  });

  bool get isDetached => currentBranch == null && headSha != null;
  bool get hasChanges => staged.isNotEmpty || unstaged.isNotEmpty;
  bool get hasConflicts => unstaged.any((c) => c.type == ChangeType.conflicted);

  GitRef? get currentRef => currentBranch == null
      ? null
      : refs.where((r) => r.kind == RefKind.local && r.name == currentBranch).firstOrNull;

  List<GitRef> get localBranches => refs.where((r) => r.kind == RefKind.local).toList();
  List<GitRef> get remoteBranches => refs.where((r) => r.kind == RefKind.remote).toList();
  List<GitRef> get tags => refs.where((r) => r.kind == RefKind.tag).toList();

  /// Firma barata para saber si el historial puede haber cambiado.
  String get refsSignature =>
      '$headSha|${refs.map((r) => '${r.fullName}=${r.sha}').join(',')}';
}
