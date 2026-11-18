import '../../../../core/error/app_exception.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/error/result.dart';
import '../../../../core/git/git_runner.dart';
import '../../../accounts/data/datasources/account_local_data_source.dart';
import '../../../accounts/data/datasources/github_remote_data_source.dart';
import '../../domain/entities/file_diff.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/entities/git_commit.dart';
import '../../domain/entities/remote_repository.dart';
import '../../domain/entities/repo_snapshot.dart';
import '../../domain/repositories/git_repository.dart';
import '../datasources/git_cli_data_source.dart';
import '../datasources/workspace_local_data_source.dart';

class GitRepositoryImpl implements GitRepository {
  final GitCliDataSource _cli;
  final AccountLocalDataSource _accounts;
  final GitHubRemoteDataSource _github;

  GitRepositoryImpl({
    required GitCliDataSource cli,
    required AccountLocalDataSource accounts,
    required GitHubRemoteDataSource github,
  })  : _cli = cli,
        _accounts = accounts,
        _github = github;

  /// El token vive solo aquí, en la capa de datos.
  Future<GitIdentity> _identity(String accountId) async {
    final accounts = await _accounts.readAccounts();
    final account = accounts.where((a) => a.id == accountId).firstOrNull;
    if (account == null) throw const AccountNotFoundException();
    return GitIdentity(
      login: account.login,
      token: account.token,
      name: account.displayName.isNotEmpty ? account.displayName : account.login,
      email: account.email,
    );
  }

  Future<Result<T>> _guard<T>(Future<T> Function() body) async {
    try {
      return Success(await body());
    } on AppException catch (e) {
      return Failure(switch (e) {
        InvalidTokenException() => const InvalidTokenFailure(),
        AccountNotFoundException() => const AccountNotFoundFailure(),
        ServerException(:final message) => NetworkFailure(message),
        StorageException(:final message) => StorageFailure(message),
        GitConfigException(:final message) => GitConfigFailure(message),
        GitCommandException(:final message) => GitCommandFailure(message),
      });
    } catch (e) {
      return Failure(UnknownFailure(e.toString()));
    }
  }

  @override
  Future<Result<String>> resolveRepoRoot(String path) => _guard(() => _cli.resolveRoot(path));

  @override
  Future<Result<RepoSnapshot>> loadSnapshot(RepoHandle repo) => _guard(() => _cli.snapshot(repo.path));

  @override
  Future<Result<List<GitCommit>>> loadHistory(RepoHandle repo, {int limit = 500}) =>
      _guard(() => _cli.history(repo.path, limit: limit));

  @override
  Future<Result<GitCommitDetail>> loadCommitDetail(RepoHandle repo, String sha) =>
      _guard(() => _cli.commitDetail(repo.path, sha));

  @override
  Future<Result<FileDiff>> loadDiff(RepoHandle repo, DiffTarget target) =>
      _guard(() => _cli.diff(repo.path, target));

  @override
  Future<Result<FileContent>> loadFileContent(RepoHandle repo, DiffTarget target) =>
      _guard(() => _cli.fileContent(repo.path, target));

  @override
  Future<Result<void>> run(RepoHandle repo, GitAction action) => _guard(() async {
        await _cli.run(repo.path, action, await _identity(repo.accountId));
      });

  @override
  Future<Result<List<RemoteRepository>>> listRemoteRepositories(String accountId) => _guard(() async {
        final identity = await _identity(accountId);
        return _github.fetchRepositories(identity.token);
      });

  @override
  Future<Result<String>> clone(String accountId, String url, String parentDirectory) =>
      _guard(() async => _cli.clone(url, parentDirectory, await _identity(accountId)));
}

class WorkspaceRepositoryImpl implements WorkspaceRepository {
  final WorkspaceLocalDataSource _local;

  const WorkspaceRepositoryImpl(this._local);

  @override
  Future<({List<String> tabs, int activeIndex})> load(String accountId) => _local.read(accountId);

  @override
  Future<void> save(String accountId, List<String> tabs, int activeIndex) =>
      _local.write(accountId, tabs, activeIndex);
}
