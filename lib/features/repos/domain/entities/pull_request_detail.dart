import 'file_change.dart';
import 'pull_request.dart';

enum PullRequestState { open, draft, merged, closed }

enum MergeMethod { merge, squash, rebase }

enum ReviewEvent { approve, requestChanges, comment }

enum ReviewState { approved, changesRequested, commented, dismissed, pending }

/// Todo lo que muestra la vista de una Pull Request.
class PullRequestBundle {
  final PullRequestDetail detail;

  /// Comentarios y reviews, de más antiguo a más reciente.
  final List<PullRequestEvent> timeline;
  final List<PullRequestCommit> commits;
  final List<PullRequestFile> files;
  final List<PullRequestCheck> checks;

  const PullRequestBundle({
    required this.detail,
    required this.timeline,
    required this.commits,
    required this.files,
    required this.checks,
  });

  CiStatus get ci {
    if (checks.isEmpty) return CiStatus.none;
    if (checks.any((c) => c.status == CiStatus.failure)) return CiStatus.failure;
    if (checks.any((c) => c.status == CiStatus.pending)) return CiStatus.pending;
    return CiStatus.success;
  }
}

class PullRequestDetail {
  final int number;
  final String title;
  final String body;
  final String author;
  final PullRequestState state;
  final String headRef;
  final String headSha;
  final String headRepoFullName;
  final String baseRef;
  final String url;

  /// null = GitHub aún lo está calculando.
  final bool? mergeable;

  /// clean, dirty, blocked, behind, unstable, draft, unknown…
  final String mergeableState;
  final int commitCount;
  final int additions;
  final int deletions;
  final int changedFiles;
  final DateTime? createdAt;
  final String? mergedBy;

  const PullRequestDetail({
    required this.number,
    required this.title,
    required this.body,
    required this.author,
    required this.state,
    required this.headRef,
    required this.headSha,
    required this.headRepoFullName,
    required this.baseRef,
    required this.url,
    this.mergeable,
    this.mergeableState = 'unknown',
    this.commitCount = 0,
    this.additions = 0,
    this.deletions = 0,
    this.changedFiles = 0,
    this.createdAt,
    this.mergedBy,
  });

  bool get isOpen => state == PullRequestState.open || state == PullRequestState.draft;
  bool get isFromFork => headRepoFullName.isEmpty || !url.contains('/$headRepoFullName/pull/');

  /// Explicación legible de `mergeable_state`.
  ({bool canMerge, String text}) get mergeability => switch (mergeableState) {
        'clean' => (canMerge: true, text: 'Ready to merge: no conflicts with $baseRef.'),
        'has_hooks' => (canMerge: true, text: 'Ready to merge.'),
        'unstable' => (canMerge: true, text: 'Can be merged, but some checks are failing or still running.'),
        'behind' => (canMerge: true, text: 'Can be merged, but $headRef is behind $baseRef.'),
        'dirty' => (
            canMerge: false,
            text: 'Conflicts with $baseRef. Check it out, merge or rebase $baseRef into it, resolve and push.'
          ),
        'blocked' => (
            canMerge: false,
            text: 'Blocked by branch protection (required reviews or checks are missing).'
          ),
        'draft' => (canMerge: false, text: 'Draft: mark it as ready for review on GitHub before merging.'),
        _ => (canMerge: mergeable ?? false, text: 'GitHub is still checking whether it can be merged…'),
      };
}

class PullRequestEvent {
  final String author;
  final String body;
  final DateTime? date;

  /// null = comentario normal; si no, una review con ese resultado.
  final ReviewState? review;

  const PullRequestEvent({required this.author, required this.body, this.date, this.review});
}

class PullRequestCommit {
  final String sha;
  final String message;
  final String author;
  final DateTime? date;

  const PullRequestCommit({required this.sha, required this.message, required this.author, this.date});

  String get subject => message.split('\n').first;
}

class PullRequestFile {
  final String path;
  final String? oldPath;
  final ChangeType type;
  final int additions;
  final int deletions;

  /// Diff unificado del fichero (null en binarios o diffs enormes).
  final String? patch;

  const PullRequestFile({
    required this.path,
    required this.type,
    this.oldPath,
    this.additions = 0,
    this.deletions = 0,
    this.patch,
  });
}

class PullRequestCheck {
  final String name;
  final CiStatus status;

  /// success, failure, skipped… (o el estado si no ha terminado).
  final String detail;
  final String? url;

  const PullRequestCheck({required this.name, required this.status, required this.detail, this.url});
}

/// Operaciones sobre una Pull Request.
sealed class PullRequestOp {
  const PullRequestOp();
}

class CommentOnPullRequest extends PullRequestOp {
  final String body;
  const CommentOnPullRequest(this.body);
}

class ReviewPullRequest extends PullRequestOp {
  final ReviewEvent event;
  final String body;
  const ReviewPullRequest(this.event, [this.body = '']);
}

class MergePullRequest extends PullRequestOp {
  final MergeMethod method;
  final String? title;
  final String? message;

  /// Borrar la rama de la PR al terminar (solo si es del mismo repo).
  final bool deleteBranch;
  const MergePullRequest(this.method, {this.title, this.message, this.deleteBranch = false});
}

class SetPullRequestOpen extends PullRequestOp {
  final bool open;
  const SetPullRequestOpen(this.open);
}

class EditPullRequest extends PullRequestOp {
  final String title;
  final String body;
  const EditPullRequest(this.title, this.body);
}
