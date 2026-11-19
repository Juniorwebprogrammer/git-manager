/// Repo de GitHub al que apunta el remoto `origin` de un repo local.
class GitHubRepoInfo {
  final String owner;
  final String name;
  final String defaultBranch;

  const GitHubRepoInfo({required this.owner, required this.name, this.defaultBranch = 'main'});

  String get fullName => '$owner/$name';
}

enum CiStatus { none, pending, success, failure }

class PullRequest {
  final int number;
  final String title;
  final String author;
  final String headRef;
  final String headSha;

  /// `owner/repo` donde vive la rama; distinto del repo base si es un fork.
  final String headRepoFullName;
  final String baseRef;
  final String url;
  final bool draft;
  final DateTime? updatedAt;
  final CiStatus ci;

  const PullRequest({
    required this.number,
    required this.title,
    required this.author,
    required this.headRef,
    required this.headSha,
    required this.headRepoFullName,
    required this.baseRef,
    required this.url,
    this.draft = false,
    this.updatedAt,
    this.ci = CiStatus.none,
  });

  /// La rama vive en otro repo (fork): el enlace de la PR es del repo base.
  bool get isFromFork => headRepoFullName.isEmpty || !url.contains('/$headRepoFullName/pull/');

  PullRequest copyWith({CiStatus? ci}) => PullRequest(
        number: number,
        title: title,
        author: author,
        headRef: headRef,
        headSha: headSha,
        headRepoFullName: headRepoFullName,
        baseRef: baseRef,
        url: url,
        draft: draft,
        updatedAt: updatedAt,
        ci: ci ?? this.ci,
      );
}

/// `https://github.com/owner/repo(.git)` o `git@github.com:owner/repo(.git)`
/// → (owner, repo). null si no es de github.com.
({String owner, String name})? parseGitHubRemote(String url) {
  final trimmed = url.trim();
  final match = RegExp(r'^(?:https?://(?:[^@/]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)'
          r'([^/]+)/([^/]+?)(?:\.git)?/?$')
      .firstMatch(trimmed);
  if (match == null) return null;
  return (owner: match.group(1)!, name: match.group(2)!);
}
