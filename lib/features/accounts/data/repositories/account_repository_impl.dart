import '../../../../core/error/app_exception.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/error/result.dart';
import '../../domain/entities/git_account.dart';
import '../../domain/repositories/account_repository.dart';
import '../../../../core/hosting/git_provider.dart';
import '../datasources/account_local_data_source.dart';
import '../datasources/azure_devops_remote_data_source.dart';
import '../datasources/git_config_data_source.dart';
import '../datasources/git_credentials_data_source.dart';
import '../datasources/github_remote_data_source.dart';
import '../models/git_account_model.dart';

class AccountRepositoryImpl implements AccountRepository {
  final GitHubRemoteDataSource _remote;
  final AccountLocalDataSource _local;
  final GitConfigDataSource _gitConfig;
  final GitCredentialsDataSource _gitCredentials;
  final AzureDevOpsRemoteDataSource? _azure;

  const AccountRepositoryImpl({
    required GitHubRemoteDataSource remote,
    required AccountLocalDataSource local,
    required GitConfigDataSource gitConfig,
    required GitCredentialsDataSource gitCredentials,
    AzureDevOpsRemoteDataSource? azure,
  }) : _remote = remote,
       _local = local,
       _gitConfig = gitConfig,
       _gitCredentials = gitCredentials,
       _azure = azure;

  AzureDevOpsRemoteDataSource get _azureApi =>
      _azure ?? (throw const StorageException('Azure DevOps support is not available.'));

  /// Organizaciones visibles con el token, más [extra] si se indicó.
  Future<List<String>> _azureOrganizations(String token, AzureProfile profile, {String? extra}) async {
    final listed = await _azureApi.fetchOrganizations(token, profile.id);
    if (extra != null) {
      await _azureApi.checkOrganization(token, extra);
      if (!listed.contains(extra)) return [...listed, extra]..sort();
    }
    return listed;
  }

  @override
  Future<Result<GitAccount>> addAzureAccount(String token, {String? organization}) async {
    try {
      final profile = await _azureApi.fetchProfile(token);
      final organizations = await _azureOrganizations(token, profile, extra: organization);
      if (organizations.isEmpty) {
        return const Failure(AccountSetupFailure(
          'This token cannot list your organizations (it is probably limited to one). '
          'Type the organization name, as in dev.azure.com/<organization>.',
        ));
      }

      final existing = await _local.readAccounts();
      if (existing.any((a) => a.id == profile.id)) {
        return Failure(AccountAlreadyExistsFailure(profile.email.isEmpty ? profile.displayName : profile.email));
      }

      final model = GitAccountModel(
        id: profile.id,
        login: profile.email.isNotEmpty ? profile.email : profile.displayName,
        displayName: profile.displayName,
        email: profile.email,
        avatarUrl: '',
        profileUrl: 'https://dev.azure.com/${Uri.encodeComponent(organizations.first)}',
        token: token,
        provider: GitProvider.azure,
        organizations: organizations,
      );
      await _local.writeAccounts([...existing, model]);
      return Success(model.toEntity());
    } on AppException catch (e) {
      return Failure(_mapException(e));
    } catch (e) {
      return Failure(UnknownFailure(e.toString()));
    }
  }

  @override
  Future<Result<List<GitAccount>>> getAccounts() async {
    try {
      final accounts = await _local.readAccounts();
      return Success(accounts.map((a) => a.toEntity()).toList());
    } on AppException catch (e) {
      return Failure(_mapException(e));
    } catch (e) {
      return Failure(UnknownFailure(e.toString()));
    }
  }

  @override
  Future<Result<GitAccount>> addAccount(String token) async {
    try {
      final profile = await _remote.fetchAuthenticatedUser(token);
      final existing = await _local.readAccounts();

      if (existing.any((a) => a.id == profile.id)) {
        return Failure(AccountAlreadyExistsFailure(profile.login));
      }

      final model = GitAccountModel(
        id: profile.id,
        login: profile.login,
        displayName: profile.name ?? '',
        email: profile.email ?? '',
        avatarUrl: profile.avatarUrl,
        profileUrl: profile.profileUrl,
        token: token,
        isActive: false,
      );

      await _local.writeAccounts([...existing, model]);
      return Success(model.toEntity());
    } on AppException catch (e) {
      return Failure(_mapException(e));
    } catch (e) {
      return Failure(UnknownFailure(e.toString()));
    }
  }

  @override
  Future<Result<GitAccount>> testConnection(String accountId) async {
    try {
      final accounts = await _local.readAccounts();
      final index = accounts.indexWhere((a) => a.id == accountId);
      if (index == -1) return const Failure(AccountNotFoundFailure());

      final stored = accounts[index];
      final GitAccountModel refreshed;
      if (stored.provider == GitProvider.azure) {
        final profile = await _azureApi.fetchProfile(stored.token);
        final listed = await _azureApi.fetchOrganizations(stored.token, profile.id);
        refreshed = stored.copyWith(
          displayName: profile.displayName,
          email: profile.email.isEmpty ? stored.email : profile.email,
          organizations: {...stored.organizations, ...listed}.toList()..sort(),
        );
      } else {
        final profile = await _remote.fetchAuthenticatedUser(stored.token);
        refreshed = stored.copyWith(
          displayName: profile.name ?? '',
          email: profile.email ?? stored.email,
          avatarUrl: profile.avatarUrl,
        );
      }

      final updatedList = [...accounts];
      updatedList[index] = refreshed;
      await _local.writeAccounts(updatedList);
      return Success(refreshed.toEntity());
    } on AppException catch (e) {
      return Failure(_mapException(e));
    } catch (e) {
      return Failure(UnknownFailure(e.toString()));
    }
  }

  @override
  Future<Result<List<GitAccount>>> connectAccount(String accountId) async {
    try {
      final accounts = await _local.readAccounts();
      final target = accounts.where((a) => a.id == accountId).firstOrNull;
      if (target == null) return const Failure(AccountNotFoundFailure());

      await _gitConfig.setGlobalIdentity(
        name: target.displayName.isNotEmpty ? target.displayName : target.login,
        email: target.email,
      );
      if (target.provider == GitProvider.azure) {
        await _gitCredentials.setAzureCredentials(token: target.token, organizations: target.organizations);
      } else {
        await _gitCredentials.setActiveCredential(
          login: target.login,
          token: target.token,
        );
      }

      // Una cuenta activa por proveedor: GitHub y Azure DevOps conviven.
      final updated = accounts
          .map((a) => a.provider == target.provider ? a.copyWith(isActive: a.id == accountId) : a)
          .toList();
      await _local.writeAccounts(updated);
      return Success(updated.map((a) => a.toEntity()).toList());
    } on AppException catch (e) {
      return Failure(_mapException(e));
    } catch (e) {
      return Failure(UnknownFailure(e.toString()));
    }
  }

  @override
  Future<Result<List<GitAccount>>> removeAccount(String accountId) async {
    try {
      final accounts = await _local.readAccounts();
      final removed = accounts.where((a) => a.id == accountId).firstOrNull;
      final updated = accounts.where((a) => a.id != accountId).toList();
      await _local.writeAccounts(updated);

      if (removed != null && removed.isActive) {
        if (removed.provider == GitProvider.azure) {
          await _gitCredentials.clearActiveCredential(
            hosts: GitProvider.azure.httpsHosts(removed.organizations),
          );
        } else {
          await _gitCredentials.clearActiveCredential();
        }
      }

      return Success(updated.map((a) => a.toEntity()).toList());
    } on AppException catch (e) {
      return Failure(_mapException(e));
    } catch (e) {
      return Failure(UnknownFailure(e.toString()));
    }
  }

  AppFailure _mapException(AppException e) => switch (e) {
        InvalidTokenException() => const InvalidTokenFailure(),
        AccountNotFoundException() => const AccountNotFoundFailure(),
        ServerException(:final message) => NetworkFailure(message),
        StorageException(:final message) => StorageFailure(message),
        GitConfigException(:final message) => GitConfigFailure(message),
        GitCommandException(:final message) => GitCommandFailure(message),
      };
}
