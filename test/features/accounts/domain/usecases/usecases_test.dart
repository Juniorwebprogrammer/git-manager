import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:git_manager/core/error/app_failure.dart';
import 'package:git_manager/core/error/result.dart';
import 'package:git_manager/features/accounts/domain/entities/git_account.dart';
import 'package:git_manager/features/accounts/domain/repositories/account_repository.dart';
import 'package:git_manager/features/accounts/domain/usecases/add_account_usecase.dart';
import 'package:git_manager/features/accounts/domain/usecases/connect_account_usecase.dart';
import 'package:git_manager/features/accounts/domain/usecases/get_accounts_usecase.dart';
import 'package:git_manager/features/accounts/domain/usecases/remove_account_usecase.dart';
import 'package:git_manager/features/accounts/domain/usecases/test_connection_usecase.dart';

class _MockAccountRepository extends Mock implements AccountRepository {}

const _account = GitAccount(
  id: '1',
  login: 'octocat',
  displayName: 'The Octocat',
  email: 'octocat@example.com',
  avatarUrl: '',
  profileUrl: '',
);

void main() {
  late _MockAccountRepository repository;

  setUp(() {
    repository = _MockAccountRepository();
  });

  test('GetAccountsUseCase delega en el repositorio', () async {
    when(() => repository.getAccounts()).thenAnswer((_) async => const Success([_account]));

    final result = await GetAccountsUseCase(repository).call();

    expect(result, isA<Success<List<GitAccount>>>());
    verify(() => repository.getAccounts()).called(1);
  });

  test('AddAccountUseCase recorta espacios del token antes de delegar', () async {
    when(() => repository.addAccount('a-token')).thenAnswer((_) async => const Success(_account));

    final result = await AddAccountUseCase(repository).call('  a-token  ');

    expect(result, isA<Success<GitAccount>>());
    verify(() => repository.addAccount('a-token')).called(1);
  });

  test('AddAccountUseCase propaga el fallo del repositorio', () async {
    when(() => repository.addAccount(any())).thenAnswer(
      (_) async => const Failure(InvalidTokenFailure()),
    );

    final result = await AddAccountUseCase(repository).call('bad-token');

    expect(result, isA<Failure<GitAccount>>());
  });

  test('ConnectAccountUseCase delega el id en el repositorio', () async {
    when(() => repository.connectAccount('1')).thenAnswer((_) async => const Success([_account]));

    await ConnectAccountUseCase(repository).call('1');

    verify(() => repository.connectAccount('1')).called(1);
  });

  test('RemoveAccountUseCase delega el id en el repositorio', () async {
    when(() => repository.removeAccount('1')).thenAnswer((_) async => const Success([]));

    await RemoveAccountUseCase(repository).call('1');

    verify(() => repository.removeAccount('1')).called(1);
  });

  test('TestConnectionUseCase delega el id en el repositorio', () async {
    when(() => repository.testConnection('1')).thenAnswer((_) async => const Success(_account));

    await TestConnectionUseCase(repository).call('1');

    verify(() => repository.testConnection('1')).called(1);
  });
}
