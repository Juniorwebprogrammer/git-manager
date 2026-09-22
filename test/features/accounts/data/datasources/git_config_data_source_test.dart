@TestOn('linux || mac-os || windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:git_manager/features/accounts/data/datasources/git_config_data_source.dart';

/// Estos tests invocan al binario `git` real, pero contra un `HOME`
/// temporal, para no tocar jamás el `~/.gitconfig` de quien ejecuta los
/// tests.
void main() {
  late Directory tempHome;
  late GitConfigDataSource dataSource;

  setUp(() async {
    tempHome = await Directory.systemTemp.createTemp('git_manager_gitconfig_test_');
    dataSource = GitConfigDataSource(environmentOverride: {'HOME': tempHome.path});
  });

  tearDown(() async {
    if (await tempHome.exists()) await tempHome.delete(recursive: true);
  });

  test('escribe user.name y user.email en el HOME indicado', () async {
    await dataSource.setGlobalIdentity(name: 'Junior García', email: 'junior@empresa.com');

    final gitconfig = File('${tempHome.path}/.gitconfig');
    expect(await gitconfig.exists(), isTrue);
    final content = await gitconfig.readAsString();
    expect(content, contains('Junior García'));
    expect(content, contains('junior@empresa.com'));
  });

  test('sobrescribe la identidad si se llama de nuevo con otra cuenta', () async {
    await dataSource.setGlobalIdentity(name: 'Cuenta Personal', email: 'personal@example.com');
    await dataSource.setGlobalIdentity(name: 'Cuenta Empresa', email: 'empresa@example.com');

    final result = await Process.run(
      'git',
      ['config', '--global', 'user.email'],
      environment: {'HOME': tempHome.path},
    );

    expect(result.stdout.toString().trim(), 'empresa@example.com');
  });
}
