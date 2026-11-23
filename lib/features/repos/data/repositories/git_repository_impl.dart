import '../../../../core/error/app_exception.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/error/result.dart';
import '../../../../core/git/git_runner.dart';
import '../../../../core/hosting/git_provider.dart';
import '../../../accounts/data/datasources/account_local_data_source.dart';
import '../../../accounts/data/datasources/azure_devops_remote_data_source.dart';
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
  final AzureDevOpsRemoteDataSource? _azureApi;

  GitRepositoryImpl({
    required GitCliDataSource cli,
    required AccountLocalDataSource accounts,
    required GitHubRemoteDataSource github,
    AzureDevOpsRemoteDataSource? azure,
  })  : _cli = cli,
        _accounts = accounts,
        _githubApi = github,
        _azureApi = azure;

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
      provider: account.provider,
      organizations: account.organizations,
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
        final identity = await _identity(repo.accountId);
        try {
          await _cli.run(repo.path, action, identity);
        } on GitCommandException catch (e) {
          if (!action.isNetwork) rethrow;
          // Repo de otro servicio que la cuenta de la pestaña: explicarlo.
          final remote = await _remoteOf(repo.path);
          if (remote == null || remote.provider == identity.provider) rethrow;
          throw GitCommandException(
            'This repository is on ${remote.provider.label}, but this tab uses the '
            '${identity.provider.label} account "${identity.login}", so its token is not sent there.\n\n'
            'Open the repository from a ${remote.provider.label} account (back to accounts → '
            'that account → open the folder).\n\nGit said: ${e.message}',
          );
        }
      });

  Future<HostedRemote?> _remoteOf(String path) async {
    try {
      return parseHostedRemote(await _cli.remoteUrl(path));
    } on GitCommandException {
      return null; // sin remotos
    }
  }

  @override
  Future<Result<HostedRemote?>> loadHostedRemote(RepoHandle repo) =>
      _guard(() => _remoteOf(repo.path));

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

  /// Remoto del repo + cuenta de la pestaña, comprobando que son del mismo
  /// servicio (el token de GitHub no sirve en Azure DevOps, ni al revés).
  Future<({GitIdentity identity, HostedRemote remote})> _hosted(RepoHandle repo) async {
    final url = await _cli.remoteUrl(repo.path);
    final remote = parseHostedRemote(url);
    if (remote == null) {
      throw GitCommandException('The remote "$url" is not a GitHub or Azure DevOps repository.');
    }
    final identity = await _identity(repo.accountId);
    if (remote.provider != identity.provider) {
      throw GitCommandException(
        'This repository is on ${remote.provider.label}, but this tab uses the '
        '${identity.provider.label} account "${identity.login}".\n\n'
        'Open the repository from a ${remote.provider.label} account to work with its pull requests.',
      );
    }
    return (identity: identity, remote: remote);
  }

  AzureDevOpsRemoteDataSource get _azure =>
      _azureApi ?? (throw const ServerException('Azure DevOps support is not available.'));

  @override
  Future<Result<HostedRepoInfo>> hostedRepoInfo(RepoHandle repo) => _guard(() async {
        final h = await _hosted(repo);
        return h.remote.provider == GitProvider.azure
            ? _azure.fetchRepoInfo(h.identity.token, h.remote)
            : _githubApi.fetchRepoInfo(h.identity.token, h.remote.owner, h.remote.name);
      });

  @override
  Future<Result<List<PullRequest>>> listPullRequests(RepoHandle repo) => _guard(() async {
        final h = await _hosted(repo);
        final token = h.identity.token;
        if (h.remote.provider == GitProvider.azure) return _azure.fetchOpenPullRequests(token, h.remote);
        final (owner, name) = (h.remote.owner, h.remote.name);
        final pulls = await _githubApi.fetchOpenPullRequests(token, owner, name);
        return Future.wait(pulls.map((pr) async => pr.copyWith(
              ci: await _githubApi.fetchCiStatus(token, owner, name, pr.headSha),
            )));
      });

  @override
  Future<Result<PullRequestBundle>> loadPullRequest(RepoHandle repo, int number) => _guard(() async {
        final h = await _hosted(repo);
        if (h.remote.provider == GitProvider.azure) {
          // El diff se calcula aquí con git: se traen los commits de la PR.
          return _azure.fetchPullRequestBundle(h.identity.token, h.remote, number, localFiles: (base, head) async {
            await _cli.ensureCommits(repo.path, h.identity, [base, head], ['refs/pull/$number/merge']);
            return _cli.pullRequestFiles(repo.path, base, head);
          });
        }
        return _githubApi.fetchPullRequestBundle(h.identity.token, h.remote.owner, h.remote.name, number);
      });

  @override
  Future<Result<void>> pullRequestAction(RepoHandle repo, int number, PullRequestOp op) => _guard(() async {
        final h = await _hosted(repo);
        if (h.remote.provider == GitProvider.azure) {
          return _azure.pullRequestAction(h.identity.token, h.remote, number, op);
        }
        await _githubApi.pullRequestAction(h.identity.token, h.remote.owner, h.remote.name, number, op);
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
        final h = await _hosted(repo);
        if (h.remote.provider == GitProvider.azure) {
          return _azure.createPullRequest(h.identity.token, h.remote,
              title: title, head: head, base: base, body: body, draft: draft);
        }
        return _githubApi.createPullRequest(
          h.identity.token,
          h.remote.owner,
          h.remote.name,
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
        if (identity.provider == GitProvider.azure) {
          final lists = await Future.wait(identity.organizations.map((o) => _azure.fetchRepositories(identity.token, o)));
          return [for (final l in lists) ...l];
        }
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
