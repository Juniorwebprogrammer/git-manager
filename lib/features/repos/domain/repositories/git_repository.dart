import '../../../../core/error/result.dart';
import '../entities/file_diff.dart';
import '../entities/git_action.dart';
import '../entities/git_commit.dart';
import '../entities/pull_request.dart';
import '../entities/remote_repository.dart';
import '../entities/repo_snapshot.dart';

/// Un repositorio local abierto por una cuenta concreta. Las operaciones
/// que crean commits o hablan con el remoto usan la identidad y el token
/// de [accountId].
typedef RepoHandle = ({String accountId, String path});

abstract interface class GitRepository {
  /// Comprueba que [path] está dentro de un repo y devuelve su raíz.
  Future<Result<String>> resolveRepoRoot(String path);

  Future<Result<RepoSnapshot>> loadSnapshot(RepoHandle repo);

  Future<Result<List<GitCommit>>> loadHistory(RepoHandle repo, {int limit = 500});

  Future<Result<GitCommitDetail>> loadCommitDetail(RepoHandle repo, String sha);

  Future<Result<FileDiff>> loadDiff(RepoHandle repo, DiffTarget target);

  Future<Result<FileContent>> loadFileContent(RepoHandle repo, DiffTarget target);

  Future<Result<void>> run(RepoHandle repo, GitAction action);

  /// Commits de `base..HEAD` (más antiguo primero, sin merges) para
  /// preparar un rebase interactivo.
  Future<Result<List<GitCommit>>> loadCommitsForRebase(RepoHandle repo, String base);

  /// Repo de GitHub al que apunta `origin` (falla si no es de github.com).
  Future<Result<GitHubRepoInfo>> githubRepoInfo(RepoHandle repo);

  /// Pull Requests abiertas del repo de `origin`, con su estado de CI.
  Future<Result<List<PullRequest>>> listPullRequests(RepoHandle repo);

  Future<Result<PullRequest>> createPullRequest(
    RepoHandle repo, {
    required String title,
    required String head,
    required String base,
    String body = '',
    bool draft = false,
  });

  /// Repos de GitHub a los que tiene acceso el token de la cuenta.
  Future<Result<List<RemoteRepository>>> listRemoteRepositories(String accountId);

  /// Clona [url] dentro de [parentDirectory] y devuelve la ruta creada.
  Future<Result<String>> clone(String accountId, String url, String parentDirectory);
}

abstract interface class WorkspaceRepository {
  /// Pestañas abiertas (rutas) y la activa, por cuenta.
  Future<({List<String> tabs, int activeIndex})> load(String accountId);

  Future<void> save(String accountId, List<String> tabs, int activeIndex);
}
