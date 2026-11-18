import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../git/git_runner.dart';

import '../../features/accounts/data/datasources/account_local_data_source.dart';
import '../../features/accounts/data/datasources/git_config_data_source.dart';
import '../../features/accounts/data/datasources/git_credentials_data_source.dart';
import '../../features/accounts/data/datasources/github_remote_data_source.dart';
import '../../features/accounts/data/repositories/account_repository_impl.dart';
import '../../features/accounts/domain/repositories/account_repository.dart';
import '../../features/accounts/domain/usecases/add_account_usecase.dart';
import '../../features/accounts/domain/usecases/connect_account_usecase.dart';
import '../../features/accounts/domain/usecases/get_accounts_usecase.dart';
import '../../features/accounts/domain/usecases/remove_account_usecase.dart';
import '../../features/accounts/domain/usecases/test_connection_usecase.dart';
import '../../features/repos/data/datasources/git_cli_data_source.dart';
import '../../features/repos/data/datasources/workspace_local_data_source.dart';
import '../../features/repos/data/repositories/git_repository_impl.dart';
import '../../features/repos/domain/repositories/git_repository.dart';

final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage();
});

final gitHubRemoteDataSourceProvider = Provider<GitHubRemoteDataSource>((ref) {
  return GitHubRemoteDataSource(ref.watch(httpClientProvider));
});

final accountLocalDataSourceProvider = Provider<AccountLocalDataSource>((ref) {
  return AccountLocalDataSource(ref.watch(secureStorageProvider));
});

final gitConfigDataSourceProvider = Provider<GitConfigDataSource>((ref) {
  return const GitConfigDataSource();
});

final gitCredentialsDataSourceProvider = Provider<GitCredentialsDataSource>((ref) {
  return const GitCredentialsDataSource();
});

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  return AccountRepositoryImpl(
    remote: ref.watch(gitHubRemoteDataSourceProvider),
    local: ref.watch(accountLocalDataSourceProvider),
    gitConfig: ref.watch(gitConfigDataSourceProvider),
    gitCredentials: ref.watch(gitCredentialsDataSourceProvider),
  );
});

final getAccountsUseCaseProvider = Provider<GetAccountsUseCase>((ref) {
  return GetAccountsUseCase(ref.watch(accountRepositoryProvider));
});

final addAccountUseCaseProvider = Provider<AddAccountUseCase>((ref) {
  return AddAccountUseCase(ref.watch(accountRepositoryProvider));
});

final connectAccountUseCaseProvider = Provider<ConnectAccountUseCase>((ref) {
  return ConnectAccountUseCase(ref.watch(accountRepositoryProvider));
});

final removeAccountUseCaseProvider = Provider<RemoveAccountUseCase>((ref) {
  return RemoveAccountUseCase(ref.watch(accountRepositoryProvider));
});

final testConnectionUseCaseProvider = Provider<TestConnectionUseCase>((ref) {
  return TestConnectionUseCase(ref.watch(accountRepositoryProvider));
});

// ------------------------------------------------------------ repos / git

final gitRunnerProvider = Provider<GitRunner>((ref) => const GitRunner());

final gitCliDataSourceProvider = Provider<GitCliDataSource>((ref) {
  return GitCliDataSource(ref.watch(gitRunnerProvider));
});

final gitRepositoryProvider = Provider<GitRepository>((ref) {
  return GitRepositoryImpl(
    cli: ref.watch(gitCliDataSourceProvider),
    accounts: ref.watch(accountLocalDataSourceProvider),
    github: ref.watch(gitHubRemoteDataSourceProvider),
  );
});

final workspaceRepositoryProvider = Provider<WorkspaceRepository>((ref) {
  return WorkspaceRepositoryImpl(WorkspaceLocalDataSource(ref.watch(secureStorageProvider)));
});
