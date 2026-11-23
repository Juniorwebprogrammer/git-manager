import '../../../../core/hosting/git_provider.dart';
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

  /// Comentarios en líneas concretas del diff (review comments).
  final List<ReviewComment> reviewComments;

  const PullRequestBundle({
    required this.detail,
    required this.timeline,
    required this.commits,
    required this.files,
    required this.checks,
    this.reviewComments = const [],
  });

  /// Hilos (comentario raíz + respuestas, por fecha) de un fichero.
  List<List<ReviewComment>> threadsFor(String path) {
    final roots = reviewComments.where((c) => c.path == path && c.inReplyTo == null).toList();
    return [
      for (final root in roots) [root, ...reviewComments.where((c) => c.inReplyTo == root.id)],
    ];
  }

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
  final GitProvider provider;

  /// La rama viene de un fork. null = deducirlo de la URL (GitHub).
  final bool? fork;

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
    this.provider = GitProvider.github,
    this.fork,
  });

  bool get isOpen => state == PullRequestState.open || state == PullRequestState.draft;
  bool get isFromFork => fork ?? (headRepoFullName.isEmpty || !url.contains('/$headRepoFullName/pull/'));

  PullRequestDetail copyWith({int? commitCount, int? additions, int? deletions, int? changedFiles}) =>
      PullRequestDetail(
        number: number,
        title: title,
        body: body,
        author: author,
        state: state,
        headRef: headRef,
        headSha: headSha,
        headRepoFullName: headRepoFullName,
        baseRef: baseRef,
        url: url,
        mergeable: mergeable,
        mergeableState: mergeableState,
        commitCount: commitCount ?? this.commitCount,
        additions: additions ?? this.additions,
        deletions: deletions ?? this.deletions,
        changedFiles: changedFiles ?? this.changedFiles,
        createdAt: createdAt,
        mergedBy: mergedBy,
        provider: provider,
        fork: fork,
      );

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
            text: provider == GitProvider.azure
                ? 'Blocked by branch policies (required reviewers, builds or linked work items are missing).'
                : 'Blocked by branch protection (required reviews or checks are missing).'
          ),
        'failed' => (canMerge: false, text: '${provider.label} could not compute the merge with $baseRef.'),
        'draft' => (canMerge: false, text: 'Draft: mark it as ready for review on ${provider.label} before merging.'),
        _ => (canMerge: mergeable ?? false, text: '${provider.label} is still checking whether it can be merged…'),
      };
}

class PullRequestEvent {
  final String author;
  final String body;
  final DateTime? date;

  /// null = comentario normal; si no, una review con ese resultado.
  final ReviewState? review;

  /// Para comentarios en el código: "lib/a.dart:12".
  final String? location;

  const PullRequestEvent({required this.author, required this.body, this.date, this.review, this.location});
}

enum DiffSide { left, right }

/// Comentario en una línea del diff de la PR.
class ReviewComment {
  final int id;
  final String author;
  final String body;
  final String path;

  /// Línea en el fichero (null = el código cambió y el comentario quedó
  /// "outdated").
  final int? line;

  /// left = versión base (líneas borradas), right = versión nueva.
  final DiffSide side;
  final DateTime? date;
  final int? inReplyTo;

  const ReviewComment({
    required this.id,
    required this.author,
    required this.body,
    required this.path,
    required this.line,
    required this.side,
    this.date,
    this.inReplyTo,
  });

  bool get isOutdated => line == null;
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

/// Comentario nuevo en una línea del diff.
class CommentOnLine extends PullRequestOp {
  final String path;
  final int line;
  final DiffSide side;
  final String body;

  /// Commit sobre el que se comenta (el último de la PR).
  final String commitSha;
  const CommentOnLine({
    required this.path,
    required this.line,
    required this.side,
    required this.body,
    required this.commitSha,
  });
}

/// Respuesta en un hilo de comentarios de código.
class ReplyToReviewComment extends PullRequestOp {
  final int commentId;
  final String body;
  const ReplyToReviewComment(this.commentId, this.body);
}
