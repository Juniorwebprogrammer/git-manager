import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_manager/core/error/app_exception.dart';
import 'package:git_manager/core/error/app_failure.dart';
import 'package:git_manager/core/error/result.dart';
import 'package:git_manager/core/git/git_runner.dart';
import 'package:git_manager/core/hosting/git_provider.dart';
import 'package:git_manager/features/accounts/data/datasources/account_local_data_source.dart';
import 'package:git_manager/features/accounts/data/datasources/azure_devops_remote_data_source.dart';
import 'package:git_manager/features/accounts/data/datasources/git_config_data_source.dart';
import 'package:git_manager/features/accounts/data/datasources/git_credentials_data_source.dart';
import 'package:git_manager/features/accounts/data/datasources/github_remote_data_source.dart';
import 'package:git_manager/features/accounts/data/models/git_account_model.dart';
import 'package:git_manager/features/accounts/data/repositories/account_repository_impl.dart';
import 'package:git_manager/features/repos/data/datasources/git_cli_data_source.dart';
import 'package:git_manager/features/repos/data/repositories/git_repository_impl.dart';
import 'package:git_manager/features/repos/domain/entities/git_action.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';

class _MockLocal extends Mock implements AccountLocalDataSource {}

class _MockGitConfig extends Mock implements GitConfigDataSource {}

class _MockGitCredentials extends Mock implements GitCredentialsDataSource {}

class _MockGitHub extends Mock implements GitHubRemoteDataSource {}

/// Azure DevOps simulado: perfil, organizaciones y repos.
MockClient azureServer({bool orgScopedToken = false, bool invalid = false, List<String>? calls}) =>
    MockClient((req) async {
      calls?.add('${req.method} ${req.url}');
      expect(req.headers['authorization'], 'Basic ${base64.encode(utf8.encode(':pat123'))}');
      if (invalid) {
        return http.Response('<html><body>Sign in</body></html>', 203, headers: {'content-type': 'text/html'});
      }
      final u = req.url;
      if (u.host == 'app.vssps.visualstudio.com' && u.path.endsWith('/profiles/me')) {
        return http.Response(
            jsonEncode({'id': 'guid-ana', 'displayName': 'Ana Pérez', 'emailAddress': 'ana@contoso.com'}), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      if (u.host == 'app.vssps.visualstudio.com' && u.path.endsWith('/accounts')) {
        if (orgScopedToken) return http.Response('', 401);
        return http.Response(
            jsonEncode({
              'value': [
                {'accountName': 'fabrikam'},
                {'accountName': 'contoso'},
              ],
            }),
            200);
      }
      if (u.host == 'dev.azure.com' && u.path.endsWith('/_apis/projects')) {
        return u.pathSegments.first == 'contoso' ? http.Response('{"value":[]}', 200) : http.Response('', 404);
      }
      if (u.host == 'dev.azure.com' && u.path.endsWith('/_apis/git/repositories')) {
        return http.Response(
            jsonEncode({
              'value': [
                {
                  'name': 'Web App',
                  'remoteUrl': 'https://contoso@dev.azure.com/contoso/Store/_git/Web%20App',
                  'project': {'name': 'Store'},
                },
                {'name': 'old', 'isDisabled': true, 'project': {'name': 'Store'}},
              ],
            }),
            200);
      }
      return http.Response('', 500);
    });

void main() {
  group('remote URLs', () {
    final cases = <String, HostedRemote?>{
      'https://github.com/octo/app.git': const HostedRemote(provider: GitProvider.github, owner: 'octo', name: 'app'),
      'git@github.com:octo/app.git': const HostedRemote(provider: GitProvider.github, owner: 'octo', name: 'app'),
      'https://dev.azure.com/contoso/Store/_git/Web': const HostedRemote(
          provider: GitProvider.azure, owner: 'contoso', project: 'Store', name: 'Web'),
      'https://contoso@dev.azure.com/contoso/My%20Project/_git/Web%20App': const HostedRemote(
          provider: GitProvider.azure, owner: 'contoso', project: 'My Project', name: 'Web App'),
      'https://contoso.visualstudio.com/DefaultCollection/Store/_git/Web': const HostedRemote(
          provider: GitProvider.azure, owner: 'contoso', project: 'Store', name: 'Web'),
      'https://contoso.visualstudio.com/Store/_git/Web': const HostedRemote(
          provider: GitProvider.azure, owner: 'contoso', project: 'Store', name: 'Web'),
      'git@ssh.dev.azure.com:v3/contoso/Store/Web': const HostedRemote(
          provider: GitProvider.azure, owner: 'contoso', project: 'Store', name: 'Web'),
      'contoso@vs-ssh.visualstudio.com:v3/contoso/Store/Web': const HostedRemote(
          provider: GitProvider.azure, owner: 'contoso', project: 'Store', name: 'Web'),
      'https://gitlab.com/octo/app.git': null,
    };
    for (final e in cases.entries) {
      test(e.key, () => expect(parseHostedRemote(e.key), e.value));
    }
  });

  group('git authentication per host', () {
    test('GitHub keeps login:token on github.com only', () {
      const id = GitIdentity(login: 'octo', token: 'ghp', name: 'Octo', email: 'o@x.com');
      final env = id.toEnvironment();
      expect(env['GIT_CONFIG_COUNT'], '2');
      expect(env['GIT_CONFIG_KEY_1'], 'http.https://github.com/.extraheader');
      expect(env['GIT_CONFIG_VALUE_1'], 'Authorization: Basic ${base64.encode(utf8.encode('octo:ghp'))}');
    });

    test('Azure sends ":PAT" to dev.azure.com and each {org}.visualstudio.com', () async {
      const id = GitIdentity(
        login: 'ana@contoso.com',
        token: 'pat123',
        name: 'Ana',
        email: 'ana@contoso.com',
        provider: GitProvider.azure,
        organizations: ['contoso'],
      );
      final env = id.toEnvironment();
      final header = 'Authorization: Basic ${base64.encode(utf8.encode(':pat123'))}';
      expect(env['GIT_CONFIG_COUNT'], '4');
      expect(env['GIT_CONFIG_KEY_1'], 'http.https://dev.azure.com/.extraheader');
      expect(env['GIT_CONFIG_VALUE_1'], header);
      expect(env['GIT_CONFIG_KEY_3'], 'http.https://contoso.visualstudio.com/.extraheader');
      expect(env.values, isNot(contains(contains('github.com'))));

      // git lee de verdad esa configuración del entorno.
      final out = await const GitRunner()
          .run(['config', '--get', 'http.https://dev.azure.com/.extraheader'], identity: id);
      expect(out.trim(), header);
    });
  });

  test('accounts saved before Azure support load as GitHub', () {
    final old = GitAccountModel.fromJson(const {'id': '1', 'login': 'octo', 'token': 't'});
    expect(old.provider, GitProvider.github);
    expect(old.organizations, isEmpty);

    const azure = GitAccountModel(
      id: 'g',
      login: 'ana@contoso.com',
      displayName: 'Ana',
      email: 'ana@contoso.com',
      avatarUrl: '',
      profileUrl: '',
      token: 't',
      provider: GitProvider.azure,
      organizations: ['contoso', 'fabrikam'],
    );
    final back = GitAccountModel.fromJson(jsonDecode(jsonEncode(azure.toJson())) as Map<String, dynamic>);
    expect(back.provider, GitProvider.azure);
    expect(back.organizations, ['contoso', 'fabrikam']);
    expect(back.toEntity().handle, 'ana@contoso.com · contoso, fabrikam');
  });

  test('~/.git-credentials keeps GitHub and Azure side by side', () async {
    final home = await Directory.systemTemp.createTemp('gm_cred_');
    addTearDown(() => home.delete(recursive: true));
    final creds = GitCredentialsDataSource(environmentOverride: {'HOME': home.path});

    await creds.setActiveCredential(login: 'octo', token: 'ghp');
    await creds.setAzureCredentials(token: 'pat123', organizations: ['contoso']);
    var lines = await File('${home.path}/.git-credentials').readAsLines();
    expect(lines, [
      'https://octo:ghp@github.com',
      'https://contoso:pat123@dev.azure.com',
      'https://contoso:pat123@contoso.visualstudio.com',
      'https://pat:pat123@dev.azure.com',
    ]);

    await creds.clearActiveCredential(hosts: GitProvider.azure.httpsHosts(['contoso']));
    lines = await File('${home.path}/.git-credentials').readAsLines();
    expect(lines, ['https://octo:ghp@github.com']);
  });

  group('Azure DevOps API', () {
    test('profile, organizations and repositories', () async {
      final api = AzureDevOpsRemoteDataSource(azureServer());
      final profile = await api.fetchProfile('pat123');
      expect((profile.id, profile.displayName, profile.email), ('guid-ana', 'Ana Pérez', 'ana@contoso.com'));
      expect(await api.fetchOrganizations('pat123', profile.id), ['contoso', 'fabrikam']);
      final repos = await api.fetchRepositories('pat123', 'contoso');
      expect(repos.single.fullName, 'contoso/Store/Web App');
      expect(repos.single.cloneUrl, 'https://contoso@dev.azure.com/contoso/Store/_git/Web%20App');
    });

    test('an invalid PAT (203 + HTML sign-in page) is an invalid token', () async {
      final api = AzureDevOpsRemoteDataSource(azureServer(invalid: true));
      await expectLater(api.fetchProfile('pat123'), throwsA(isA<InvalidTokenException>()));
    });

    test('unknown organization and missing permissions are explained', () async {
      final api = AzureDevOpsRemoteDataSource(azureServer());
      await expectLater(
        api.checkOrganization('pat123', 'nope'),
        throwsA(isA<ServerException>().having((e) => e.message, 'm', contains('Organization "nope" not found'))),
      );
      final forbidden = AzureDevOpsRemoteDataSource(MockClient((_) async => http.Response('{}', 403)));
      await expectLater(
        forbidden.fetchRepositories('pat123', 'contoso'),
        throwsA(isA<ServerException>().having((e) => e.message, 'm', contains('Code: Read & write'))),
      );
    });
  });

  group('Azure accounts', () {
    late _MockLocal local;
    late _MockGitCredentials creds;
    late List<GitAccountModel> saved;

    AccountRepositoryImpl repo(MockClient azure) => AccountRepositoryImpl(
          remote: _MockGitHub(),
          local: local,
          gitConfig: _MockGitConfig(),
          gitCredentials: creds,
          azure: AzureDevOpsRemoteDataSource(azure),
        );

    setUp(() {
      local = _MockLocal();
      creds = _MockGitCredentials();
      saved = [];
      registerFallbackValue(<GitAccountModel>[]);
      when(() => local.readAccounts()).thenAnswer((_) async => saved);
      when(() => local.writeAccounts(any())).thenAnswer((i) async {
        saved = i.positionalArguments.first as List<GitAccountModel>;
      });
    });

    test('a PAT for all organizations lists them all', () async {
      final result = await repo(azureServer()).addAzureAccount('pat123');
      final account = (result as Success).value;
      expect(account.provider, GitProvider.azure);
      expect(account.login, 'ana@contoso.com');
      expect(account.organizations, ['contoso', 'fabrikam']);
      expect(saved.single.token, 'pat123');
    });

    test('a PAT limited to one organization asks for it, then accepts it', () async {
      final noOrg = await repo(azureServer(orgScopedToken: true)).addAzureAccount('pat123');
      expect((noOrg as Failure).failure, isA<AccountSetupFailure>());

      final withOrg = await repo(azureServer(orgScopedToken: true)).addAzureAccount('pat123', organization: 'contoso');
      expect((withOrg as Success).value.organizations, ['contoso']);
    });

    test('Connect keeps one active account per provider', () async {
      saved = [
        const GitAccountModel(
            id: 'gh', login: 'octo', displayName: 'Octo', email: 'o@x.com', avatarUrl: '', profileUrl: '',
            token: 'ghp', isActive: true),
        const GitAccountModel(
            id: 'az', login: 'ana@contoso.com', displayName: 'Ana', email: 'ana@contoso.com', avatarUrl: '',
            profileUrl: '', token: 'pat123', provider: GitProvider.azure, organizations: ['contoso']),
      ];
      final gitConfig = _MockGitConfig();
      when(() => gitConfig.setGlobalIdentity(name: any(named: 'name'), email: any(named: 'email')))
          .thenAnswer((_) async {});
      when(() => creds.setAzureCredentials(token: any(named: 'token'), organizations: any(named: 'organizations')))
          .thenAnswer((_) async {});
      final repository = AccountRepositoryImpl(
        remote: _MockGitHub(),
        local: local,
        gitConfig: gitConfig,
        gitCredentials: creds,
        azure: AzureDevOpsRemoteDataSource(azureServer()),
      );

      await repository.connectAccount('az');
      expect(saved.map((a) => (a.id, a.isActive)), [('gh', true), ('az', true)]);
      verify(() => creds.setAzureCredentials(token: 'pat123', organizations: ['contoso'])).called(1);
    });
  });

  test('pushing an Azure repo from a GitHub tab explains the mismatch', () async {
    final tmp = await Directory.systemTemp.createTemp('gm_mismatch_');
    addTearDown(() => tmp.delete(recursive: true));
    const runner = GitRunner();
    final repoPath = (await Directory('${tmp.path}/r').create()).path;
    await runner.run(['init', '-q', '-b', 'main'], workingDirectory: repoPath);
    await runner.run(['remote', 'add', 'origin', 'https://dev.azure.com/contoso/Store/_git/Web'],
        workingDirectory: repoPath);
    // Sin red en el test: la URL "de Azure" apunta a una carpeta que no existe.
    await runner.run(['config', 'url.${tmp.path}/missing.git.insteadOf', 'https://dev.azure.com/contoso/Store/_git/Web'],
        workingDirectory: repoPath);

    final local = _MockLocal();
    when(() => local.readAccounts()).thenAnswer((_) async => const [
          GitAccountModel(
              id: 'gh', login: 'octo', displayName: 'Octo', email: 'o@x.com', avatarUrl: '', profileUrl: '', token: 't'),
        ]);
    final git = GitRepositoryImpl(cli: const GitCliDataSource(runner), accounts: local, github: _MockGitHub());

    final result = await git.run((accountId: 'gh', path: repoPath), const FetchAction());
    expect((result as Failure).failure.message,
        allOf(contains('This repository is on Azure DevOps'), contains('GitHub account "octo"')));
    expect((await git.loadHostedRemote((accountId: 'gh', path: repoPath)) as Success).value?.provider,
        GitProvider.azure);
  });
}
