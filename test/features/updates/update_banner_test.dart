import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_manager/core/di/providers.dart';
import 'package:git_manager/core/error/result.dart';
import 'package:git_manager/core/settings/app_settings.dart';
import 'package:git_manager/core/system/system_launcher.dart';
import 'package:git_manager/features/accounts/domain/repositories/account_repository.dart';
import 'package:git_manager/features/updates/data/update_service.dart';
import 'package:git_manager/features/updates/domain/app_release.dart';
import 'package:git_manager/features/updates/presentation/update_notifier.dart';
import 'package:git_manager/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';

class _MockAccounts extends Mock implements AccountRepository {}

class _MemoryStore implements SettingsStore {
  Map<String, Object?> values = {};
  @override
  Future<Map<String, Object?>> load() async => values;
  @override
  Future<void> save(Map<String, Object> v) async => values = {...v};
}

final deb = utf8.encode('deb' * 5000);

final client = MockClient((req) async {
  switch (req.url.toString()) {
    case 'https://api.github.com/repos/Juniorwebprogrammer/git-manager/releases/latest':
      return http.Response(
        jsonEncode({
          'tag_name': 'v2.3.0',
          'name': 'Git Manager 2.3.0',
          'body': '## Highlights\n- Azure DevOps accounts and pull requests',
          'html_url': 'https://github.com/Juniorwebprogrammer/git-manager/releases/tag/v2.3.0',
          'assets': [
            {'name': 'git-manager_2.3.0_amd64.deb', 'browser_download_url': 'https://dl/deb', 'size': deb.length},
            {'name': 'git-manager_2.3.0_amd64.deb.sha256', 'browser_download_url': 'https://dl/sha'},
          ],
        }),
        200,
      );
    case 'https://dl/deb':
      return http.Response.bytes(deb, 200);
    case 'https://dl/sha':
      return http.Response('${sha256.convert(deb)}  git-manager_2.3.0_amd64.deb', 200);
  }
  return http.Response('', 404);
});

void main() {
  late List<String> commands;
  late List<String> notifications;
  late int exits;
  late _MemoryStore store;

  setUp(() {
    commands = [];
    notifications = [];
    exits = 0;
    store = _MemoryStore();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
    String executable = '/opt/git-manager/git_manager',
    String current = '2.2.0',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final accounts = _MockAccounts();
    when(() => accounts.getAccounts()).thenAnswer((_) async => const Success([]));
    final tmp = Directory.systemTemp.createTempSync('gm_banner_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountRepositoryProvider.overrideWithValue(accounts),
        settingsStoreProvider.overrideWithValue(store),
        currentAppVersionProvider.overrideWithValue(AppVersion.parse(current)),
        updateScheduleProvider.overrideWithValue((first: const Duration(seconds: 1), every: const Duration(hours: 6))),
        appExitProvider.overrideWithValue(() => exits++),
        systemLauncherProvider.overrideWithValue(SystemLauncher(
          exists: (_) async => true,
          operatingSystem: 'linux',
          start: (c) async => notifications.add(c.arguments.skip(2).join(' | ')),
        )),
        updateServiceProvider.overrideWithValue(UpdateService(
          client: client,
          operatingSystem: 'linux',
          executable: executable,
          tempDir: () async => tmp,
          run: (exe, args) async {
            commands.add([exe, ...args].join(' '));
            return exe == 'dpkg-deb'
                ? ProcessResult(0, 0, 'Package: git-manager\nVersion: 2.3.0', '')
                : ProcessResult(0, 0, '', '');
          },
          start: (exe, args) async => commands.add('start $exe'),
        )),
      ],
      child: const GitManagerApp(),
    ));
    await settle(tester);
    // Primera comprobación automática, al segundo de arrancar.
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byType(GitManagerApp)));
  }

  testWidgets('a new release shows a notice, its notes, installs and restarts', (tester) async {
    await pumpApp(tester);
    expect(find.text('Git Manager 2.3.0 is available — you have 2.2.0.'), findsOneWidget);
    expect(notifications, ['Git Manager 2.3.0 is available | Open Git Manager and click Update to install it.']);
    // La pantalla de cuentas sigue debajo.
    expect(find.text("You haven't added any accounts yet"), findsOneWidget);

    await tester.tap(find.text("What's new"));
    await settle(tester);
    expect(find.text("What's new in Git Manager 2.3.0"), findsOneWidget);
    expect(find.textContaining('Azure DevOps accounts and pull requests'), findsOneWidget);
    await tester.tap(find.text('Update now'));
    await settle(tester);

    expect(find.text('Git Manager 2.3.0 is installed. Restart to use it.'), findsOneWidget);
    expect(commands.where((c) => c.startsWith('pkexec')).single, startsWith('pkexec apt-get install -y '));
    await tester.tap(find.text('Restart now'));
    await settle(tester);
    expect(commands.last, 'start /usr/bin/git-manager');
    expect(exits, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"Skip this version" hides it until a manual check', (tester) async {
    final container = await pumpApp(tester);
    await tester.tap(find.text('Skip this version'));
    await settle(tester);
    expect(find.byKey(const ValueKey('update-banner')), findsNothing);
    expect(store.values['skippedVersion'], '2.3.0');

    // La comprobación periódica no vuelve a avisar…
    await tester.pump(const Duration(hours: 6));
    await settle(tester);
    expect(find.byKey(const ValueKey('update-banner')), findsNothing);
    expect(notifications, hasLength(1));

    // …pero "Check now" sí la muestra.
    await tester.runAsync(() => container.read(updateNotifierProvider.notifier).check(manual: true));
    await settle(tester);
    expect(find.byKey(const ValueKey('update-banner')), findsOneWidget);
  });

  testWidgets('not installed from the .deb: offers the download page instead', (tester) async {
    await pumpApp(tester, executable: '/home/me/git-manager/build/linux/x64/release/bundle/git_manager');
    expect(find.widgetWithText(FilledButton, 'Download'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Update'), findsNothing);
  });

  testWidgets('already on the latest version: no notice', (tester) async {
    final container = await pumpApp(tester, current: '2.3.0');
    expect(find.byKey(const ValueKey('update-banner')), findsNothing);
    expect(notifications, isEmpty);
    expect(container.read(updateNotifierProvider).phase, UpdatePhase.upToDate);
  });

  testWidgets('fits a small window', (tester) async {
    await pumpApp(tester, size: const Size(640, 520));
    expect(find.byKey(const ValueKey('update-banner')), findsOneWidget);
    expect(find.text('Skip this version'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
