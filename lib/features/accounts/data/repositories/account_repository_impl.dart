import '../../../../core/error/app_exception.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/error/result.dart';
import '../../domain/entities/git_account.dart';
import '../../domain/repositories/account_repository.dart';
import '../datasources/account_local_data_source.dart';
import '../datasources/git_config_data_source.dart';
import '../datasources/github_remote_data_source.dart';
import '../models/git_account_model.dart';

class AccountRepositoryImpl implements AccountRepository {
  final GitHubRemoteDataSource _remote;
  final AccountLocalDataSource _local;
  final GitConfigDataSource _gitConfig;

  const AccountRepositoryImpl({
    required GitHubRemoteDataSource remote,
    required AccountLocalDataSource local,
    required GitConfigDataSource gitConfig,
  }) : _remote = remote,
       _local = local,
       _gitConfig = gitConfig;

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
      final profile = await _remote.fetchAuthenticatedUser(stored.token);
      final refreshed = stored.copyWith(
        displayName: profile.name ?? '',
        email: profile.email ?? stored.email,
        avatarUrl: profile.avatarUrl,
      );

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

      final updated = accounts
          .map((a) => a.copyWith(isActive: a.id == accountId))
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
      final updated = accounts.where((a) => a.id != accountId).toList();
      await _local.writeAccounts(updated);
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
      };
}
