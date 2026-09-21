import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:git_manager/core/error/app_exception.dart';
import 'package:git_manager/core/error/app_failure.dart';
import 'package:git_manager/core/error/result.dart';
import 'package:git_manager/features/accounts/data/datasources/account_local_data_source.dart';
import 'package:git_manager/features/accounts/data/datasources/git_config_data_source.dart';
import 'package:git_manager/features/accounts/data/datasources/git_credentials_data_source.dart';
import 'package:git_manager/features/accounts/data/datasources/github_remote_data_source.dart';
import 'package:git_manager/features/accounts/data/models/git_account_model.dart';
import 'package:git_manager/features/accounts/data/models/github_user_dto.dart';
import 'package:git_manager/features/accounts/data/repositories/account_repository_impl.dart';

class _MockRemote extends Mock implements GitHubRemoteDataSource {}

class _MockLocal extends Mock implements AccountLocalDataSource {}

class _MockGitConfig extends Mock implements GitConfigDataSource {}

class _MockGitCredentials extends Mock implements GitCredentialsDataSource {}

GitAccountModel _model({
  String id = '1',
  String login = 'octocat',
  String displayName = 'The Octocat',
  String email = 'octocat@example.com',
  String token = 'tok_123',
  bool isActive = false,
}) {
  return GitAccountModel(
    id: id,
    login: login,
    displayName: displayName,
    email: email,
    avatarUrl: 'https://avatars.example/$login',
    profileUrl: 'https://github.com/$login',
    token: token,
    isActive: isActive,
  );
}

void main() {
  late _MockRemote remote;
  late _MockLocal local;
  late _MockGitConfig gitConfig;
  late _MockGitCredentials gitCredentials;
  late AccountRepositoryImpl repository;

  setUp(() {
    remote = _MockRemote();
    local = _MockLocal();
    gitConfig = _MockGitConfig();
    gitCredentials = _MockGitCredentials();
    repository = AccountRepositoryImpl(
      remote: remote,
      local: local,
      gitConfig: gitConfig,
      gitCredentials: gitCredentials,
    );

    registerFallbackValue(<GitAccountModel>[]);
    when(() => local.writeAccounts(any())).thenAnswer((_) async {});
    when(() => gitConfig.setGlobalIdentity(name: any(named: 'name'), email: any(named: 'email')))
        .thenAnswer((_) async {});
    when(() => gitCredentials.setActiveCredential(
          login: any(named: 'login'),
          token: any(named: 'token'),
        )).thenAnswer((_) async {});
    when(() => gitCredentials.clearActiveCredential()).thenAnswer((_) async {});
  });

  group('getAccounts', () {
    test('devuelve las cuentas mapeadas a entidad', () async {
      when(() => local.readAccounts()).thenAnswer((_) async => [_model()]);

      final result = await repository.getAccounts();

      expect(result, isA<Success<List<dynamic>>>());
      final accounts = (result as Success).value as List;
      expect(accounts, hasLength(1));
      expect(accounts.first.login, 'octocat');
    });

    test('traduce errores de almacenamiento a StorageFailure', () async {
      when(() => local.readAccounts()).thenThrow(const StorageException('boom'));

      final result = await repository.getAccounts();

      expect(result, isA<Failure<List<dynamic>>>());
      expect((result as Failure).failure, isA<StorageFailure>());
    });
  });

  group('addAccount', () {
    test('valida el token y persiste la nueva cuenta', () async {
      when(() => remote.fetchAuthenticatedUser('tok_123')).thenAnswer(
        (_) async => const GitHubUserDto(
          id: '1',
          login: 'octocat',
          name: 'The Octocat',
          email: 'octocat@example.com',
          avatarUrl: 'https://avatars.example/octocat',
          profileUrl: 'https://github.com/octocat',
        ),
      );
      when(() => local.readAccounts()).thenAnswer((_) async => []);

      final result = await repository.addAccount('tok_123');

      expect(result, isA<Success<dynamic>>());
      final captured = verify(() => local.writeAccounts(captureAny())).captured.single
          as List<GitAccountModel>;
      expect(captured, hasLength(1));
      expect(captured.single.token, 'tok_123');
      expect(captured.single.isActive, isFalse);
    });

    test('rechaza un token inválido', () async {
      when(() => remote.fetchAuthenticatedUser(any())).thenThrow(const InvalidTokenException());

      final result = await repository.addAccount('bad');

      expect(result, isA<Failure<dynamic>>());
      expect((result as Failure).failure, isA<InvalidTokenFailure>());
      verifyNever(() => local.writeAccounts(any()));
    });

    test('rechaza una cuenta ya añadida', () async {
      when(() => remote.fetchAuthenticatedUser(any())).thenAnswer(
        (_) async => const GitHubUserDto(
          id: '1',
          login: 'octocat',
          name: 'The Octocat',
          email: 'octocat@example.com',
          avatarUrl: '',
          profileUrl: '',
        ),
      );
      when(() => local.readAccounts()).thenAnswer((_) async => [_model()]);

      final result = await repository.addAccount('tok_123');

      expect(result, isA<Failure<dynamic>>());
      expect((result as Failure).failure, isA<AccountAlreadyExistsFailure>());
      verifyNever(() => local.writeAccounts(any()));
    });
  });

  group('connectAccount', () {
    test('falla si la cuenta no existe', () async {
      when(() => local.readAccounts()).thenAnswer((_) async => [_model(id: '1')]);

      final result = await repository.connectAccount('otro-id');

      expect(result, isA<Failure<dynamic>>());
      expect((result as Failure).failure, isA<AccountNotFoundFailure>());
      verifyNever(() => gitConfig.setGlobalIdentity(
            name: any(named: 'name'),
            email: any(named: 'email'),
          ));
    });

    test('actualiza identidad, credenciales HTTPS y marca solo esa cuenta activa', () async {
      when(() => local.readAccounts()).thenAnswer(
        (_) async => [
          _model(id: '1', login: 'personal', isActive: true),
          _model(id: '2', login: 'empresa', displayName: '', token: 'tok_empresa'),
        ],
      );

      final result = await repository.connectAccount('2');

      expect(result, isA<Success<dynamic>>());
      verify(() => gitConfig.setGlobalIdentity(name: 'empresa', email: 'octocat@example.com'))
          .called(1);
      verify(() => gitCredentials.setActiveCredential(login: 'empresa', token: 'tok_empresa'))
          .called(1);

      final captured = verify(() => local.writeAccounts(captureAny())).captured.single
          as List<GitAccountModel>;
      expect(captured.firstWhere((a) => a.id == '1').isActive, isFalse);
      expect(captured.firstWhere((a) => a.id == '2').isActive, isTrue);
    });
  });

  group('removeAccount', () {
    test('limpia la credencial HTTPS si la cuenta eliminada era la activa', () async {
      when(() => local.readAccounts()).thenAnswer(
        (_) async => [_model(id: '1', isActive: true)],
      );

      await repository.removeAccount('1');

      verify(() => gitCredentials.clearActiveCredential()).called(1);
    });

    test('no toca las credenciales si la cuenta eliminada no era la activa', () async {
      when(() => local.readAccounts()).thenAnswer(
        (_) async => [_model(id: '1', isActive: false)],
      );

      await repository.removeAccount('1');

      verifyNever(() => gitCredentials.clearActiveCredential());
    });
  });

  group('testConnection', () {
    test('refresca el perfil de una cuenta existente', () async {
      when(() => local.readAccounts()).thenAnswer((_) async => [_model(id: '1')]);
      when(() => remote.fetchAuthenticatedUser('tok_123')).thenAnswer(
        (_) async => const GitHubUserDto(
          id: '1',
          login: 'octocat',
          name: 'Nuevo Nombre',
          email: 'octocat@example.com',
          avatarUrl: 'https://avatars.example/nuevo',
          profileUrl: 'https://github.com/octocat',
        ),
      );

      final result = await repository.testConnection('1');

      expect(result, isA<Success<dynamic>>());
      final account = (result as Success).value;
      expect(account.displayName, 'Nuevo Nombre');
      expect(account.avatarUrl, 'https://avatars.example/nuevo');
    });

    test('falla si la cuenta no existe', () async {
      when(() => local.readAccounts()).thenAnswer((_) async => []);

      final result = await repository.testConnection('no-existe');

      expect(result, isA<Failure<dynamic>>());
      expect((result as Failure).failure, isA<AccountNotFoundFailure>());
    });
  });
}
