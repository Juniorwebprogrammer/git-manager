@TestOn('linux || mac-os || windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:git_manager/features/accounts/data/datasources/git_credentials_data_source.dart';

/// Igual que git_config_data_source_test.dart: usa `git` real contra un
/// `HOME` temporal para no tocar el `~/.git-credentials` real.
void main() {
  late Directory tempHome;
  late GitCredentialsDataSource dataSource;

  setUp(() async {
    tempHome = await Directory.systemTemp.createTemp('git_manager_credentials_test_');
    dataSource = GitCredentialsDataSource(environmentOverride: {'HOME': tempHome.path});
  });

  tearDown(() async {
    if (await tempHome.exists()) await tempHome.delete(recursive: true);
  });

  test('configura credential.helper=store y escribe la línea de github.com', () async {
    await dataSource.setActiveCredential(login: 'personal-user', token: 'tok_personal');

    final helperResult = await Process.run(
      'git',
      ['config', '--global', 'credential.helper'],
      environment: {'HOME': tempHome.path},
    );
    expect(helperResult.stdout.toString().trim(), 'store');

    final credentialsFile = File('${tempHome.path}/.git-credentials');
    final content = await credentialsFile.readAsString();
    expect(content, contains('https://personal-user:tok_personal@github.com'));
  });

  test('al cambiar de cuenta sustituye la línea anterior de github.com, no la duplica', () async {
    await dataSource.setActiveCredential(login: 'personal-user', token: 'tok_personal');
    await dataSource.setActiveCredential(login: 'empresa-user', token: 'tok_empresa');

    final credentialsFile = File('${tempHome.path}/.git-credentials');
    final lines = await credentialsFile.readAsLines();

    expect(lines.where((l) => l.contains('github.com')), hasLength(1));
    expect(lines.single, contains('empresa-user:tok_empresa'));
  });

  test('conserva credenciales de otros hosts al cambiar la de github.com', () async {
    final credentialsFile = File('${tempHome.path}/.git-credentials');
    await credentialsFile.writeAsString('https://otro-user:otro-token@gitlab.com\n');

    await dataSource.setActiveCredential(login: 'personal-user', token: 'tok_personal');

    final lines = await credentialsFile.readAsLines();
    expect(lines, containsAll(<String>[
      'https://otro-user:otro-token@gitlab.com',
      'https://personal-user:tok_personal@github.com',
    ]));
  });

  test('clearActiveCredential quita solo la línea de github.com', () async {
    await dataSource.setActiveCredential(login: 'personal-user', token: 'tok_personal');
    final credentialsFile = File('${tempHome.path}/.git-credentials');
    await credentialsFile.writeAsString(
      '${await credentialsFile.readAsString()}https://otro-user:otro-token@gitlab.com\n',
    );

    await dataSource.clearActiveCredential();

    final lines = await credentialsFile.readAsLines();
    expect(lines.any((l) => l.contains('github.com')), isFalse);
    expect(lines, contains('https://otro-user:otro-token@gitlab.com'));
  });

  test('clearActiveCredential borra el archivo si no queda ninguna credencial', () async {
    await dataSource.setActiveCredential(login: 'personal-user', token: 'tok_personal');

    await dataSource.clearActiveCredential();

    final credentialsFile = File('${tempHome.path}/.git-credentials');
    expect(await credentialsFile.exists(), isFalse);
  });
}
