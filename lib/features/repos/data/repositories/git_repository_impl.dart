import '../../../../core/error/app_exception.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/error/result.dart';
import '../../../../core/git/git_runner.dart';
import '../../../accounts/data/datasources/account_local_data_source.dart';
import '../../../accounts/data/datasources/github_remote_data_source.dart';
import '../../domain/entities/file_diff.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/entities/git_commit.dart';
import '../../domain/entities/file_change.dart';
import '../../domain/entities/pull_request.dart';
import '../../domain/entities/pull_request_detail.dart';
import '../../domain/entities/repo_extras.dart';
import '../../domain/entities/remote_repository.dart';
import '../../domain/entities/repo_snapshot.dart';
import '../../domain/repositories/git_repository.dart';
import '../datasources/git_cli_data_source.dart';
import '../datasources/workspace_local_data_source.dart';

class GitRepositoryImpl implements GitRepository {
  final GitCliDataSource _cli;
  final AccountLocalDataSource _accounts;
  final GitHubRemoteDataSource _githubApi;

  GitRepositoryImpl({
    required GitCliDataSource cli,
    required AccountLocalDataSource accounts,
    required GitHubRemoteDataSource github,
  })  : _cli = cli,
        _accounts = accounts,
        _githubApi = github;

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
  Future<Result<FileDiff>> loadDiff(RepoHandle repo, DiffTarget target, {bool ignoreWhitespace = false}) =>
      _guard(() => _cli.diff(repo.path, target, ignoreWhitespace: ignoreWhitespace));

  @override
  Future<Result<FileContent>> loadFileContent(RepoHandle repo, DiffTarget target) =>
      _guard(() => _cli.fileContent(repo.path, target));

  @override
  Future<Result<void>> run(RepoHandle repo, GitAction action) => _guard(() async {
        await _cli.run(repo.path, action, await _identity(repo.accountId));
      });

  @override
  Future<Result<({int commits, String author})>> loadRefUpdate(RepoHandle repo, String? from, String to) =>
      _guard(() => _cli.refUpdate(repo.path, from, to));

  @override
  Future<Result<UndoPlan?>> loadUndoPlan(RepoHandle repo) => _guard(() => _cli.undoPlan(repo.path));

  @override
  Future<Result<List<FileHistoryEntry>>> loadFileHistory(RepoHandle repo, String path) =>
      _guard(() => _cli.fileHistory(repo.path, path));

  @override
  Future<Result<List<BlameLine>>> loadBlame(RepoHandle repo, String path, {String? revision}) =>
      _guard(() => _cli.blame(repo.path, path, revision: revision));

  @override
  Future<Result<List<FileChange>>> loadComparison(RepoHandle repo, String base, String target) =>
      _guard(() => _cli.comparison(repo.path, base, target));

  @override
  Future<Result<SigningConfig>> loadSigningConfig(RepoHandle repo) => _guard(() => _cli.signingConfig(repo.path));

  @override
  Future<Result<String?>> loadCommitTemplate(RepoHandle repo) => _guard(() => _cli.commitTemplate(repo.path));

  @override
  Future<Result<List<GitCommit>>> loadCommitsForRebase(RepoHandle repo, String base) =>
      _guard(() => _cli.commitsForRebase(repo.path, base));

  Future<({GitIdentity identity, GitHubRepoInfo info})> _github(RepoHandle repo) async {
    final url = await _cli.remoteUrl(repo.path);
    final parsed = parseGitHubRemote(url);
    if (parsed == null) {
      throw GitCommandException('The remote "$url" is not a GitHub repository.');
    }
    final identity = await _identity(repo.accountId);
    final info = await _githubApi.fetchRepoInfo(identity.token, parsed.owner, parsed.name);
    return (identity: identity, info: info);
  }

  @override
  Future<Result<GitHubRepoInfo>> githubRepoInfo(RepoHandle repo) => _guard(() async => (await _github(repo)).info);

  @override
  Future<Result<List<PullRequest>>> listPullRequests(RepoHandle repo) => _guard(() async {
        final gh = await _github(repo);
        final token = gh.identity.token;
        final pulls = await _githubApi.fetchOpenPullRequests(token, gh.info.owner, gh.info.name);
        return Future.wait(pulls.map((pr) async => pr.copyWith(
              ci: await _githubApi.fetchCiStatus(token, gh.info.owner, gh.info.name, pr.headSha),
            )));
      });

  @override
  Future<Result<PullRequestBundle>> loadPullRequest(RepoHandle repo, int number) => _guard(() async {
        final gh = await _github(repo);
        return _githubApi.fetchPullRequestBundle(gh.identity.token, gh.info.owner, gh.info.name, number);
      });

  @override
  Future<Result<void>> pullRequestAction(RepoHandle repo, int number, PullRequestOp op) => _guard(() async {
        final gh = await _github(repo);
        await _githubApi.pullRequestAction(gh.identity.token, gh.info.owner, gh.info.name, number, op);
      });

  @override
  Future<Result<PullRequest>> createPullRequest(
    RepoHandle repo, {
    required String title,
    required String head,
    required String base,
    String body = '',
    bool draft = false,
  }) =>
      _guard(() async {
        final gh = await _github(repo);
        return _githubApi.createPullRequest(
          gh.identity.token,
          gh.info.owner,
          gh.info.name,
          title: title,
          head: head,
          base: base,
          body: body,
          draft: draft,
        );
      });

  @override
  Future<Result<List<RemoteRepository>>> listRemoteRepositories(String accountId) => _guard(() async {
        final identity = await _identity(accountId);
        return _githubApi.fetchRepositories(identity.token);
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
