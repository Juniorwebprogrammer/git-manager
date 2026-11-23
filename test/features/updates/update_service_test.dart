import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_manager/features/updates/data/update_service.dart';
import 'package:git_manager/features/updates/domain/app_release.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final debBytes = utf8.encode('fake deb contents ' * 1000);

Map<String, dynamic> releaseJson({String tag = 'v2.3.0', bool prerelease = false, bool withDeb = true}) => {
      'tag_name': tag,
      'name': 'Git Manager ${tag.substring(1)}',
      'body': '## New\n- Azure DevOps',
      'html_url': 'https://github.com/Juniorwebprogrammer/git-manager/releases/tag/$tag',
      'published_at': '2026-11-24T10:00:00Z',
      'draft': false,
      'prerelease': prerelease,
      'assets': [
        if (withDeb) ...[
          {
            'name': 'git-manager_${tag.substring(1)}_amd64.deb',
            'browser_download_url': 'https://dl/git-manager.deb',
            'size': debBytes.length,
          },
          {
            'name': 'git-manager_${tag.substring(1)}_amd64.deb.sha256',
            'browser_download_url': 'https://dl/git-manager.deb.sha256',
            'size': 90,
          },
        ],
        {'name': 'notes.txt', 'browser_download_url': 'https://dl/notes.txt'},
      ],
    };

/// GitHub simulado: API de releases y descarga de adjuntos.
MockClient github({Map<String, dynamic>? release, int status = 200, String? checksum}) => MockClient((req) async {
      final url = req.url.toString();
      if (url == 'https://api.github.com/repos/Juniorwebprogrammer/git-manager/releases/latest') {
        expect(req.headers['user-agent'], 'git-manager-updater');
        return http.Response(jsonEncode(release ?? releaseJson()), status);
      }
      if (url == 'https://dl/git-manager.deb') {
        return http.Response.bytes(debBytes, 200, headers: {'content-length': '${debBytes.length}'});
      }
      if (url == 'https://dl/git-manager.deb.sha256') {
        return http.Response('${checksum ?? sha256.convert(debBytes)}  git-manager_2.3.0_amd64.deb\n', 200);
      }
      return http.Response('', 404);
    });

void main() {
  test('versions: parse and compare', () {
    expect(AppVersion.parse('v2.10.1'), const AppVersion(2, 10, 1));
    expect(AppVersion.parse('2.2.0+7'), const AppVersion(2, 2, 0));
    expect(AppVersion.parse('3.1'), const AppVersion(3, 1, 0));
    expect(AppVersion.parse('Live'), isNull);
    expect(const AppVersion(2, 10, 0) > const AppVersion(2, 9, 9), isTrue);
    expect(const AppVersion(2, 2, 0) > const AppVersion(2, 2, 0), isFalse);
  });

  group('latest release', () {
    test('reads version, notes and the .deb with its checksum', () async {
      final r = (await UpdateService(client: github()).latestRelease())!;
      expect((r.version, r.tag, r.name), (const AppVersion(2, 3, 0), 'v2.3.0', 'Git Manager 2.3.0'));
      expect(r.notes, contains('Azure DevOps'));
      expect((r.deb?.name, r.debChecksum?.name), ('git-manager_2.3.0_amd64.deb', 'git-manager_2.3.0_amd64.deb.sha256'));
    });

    test('ignores pre-releases and odd tags; no releases is not an error', () async {
      expect(await UpdateService(client: github(release: releaseJson(prerelease: true))).latestRelease(), isNull);
      expect(await UpdateService(client: github(release: releaseJson(tag: 'Live'))).latestRelease(), isNull);
      expect(await UpdateService(client: github(status: 404)).latestRelease(), isNull);
    });

    test('rate limiting is explained', () async {
      await expectLater(
        UpdateService(client: github(status: 403)).latestRelease(),
        throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('limiting requests'))),
      );
    });
  });

  group('installing', () {
    late Directory tmp;
    late List<List<String>> commands;
    late Map<String, ProcessResult> results;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('gm_update_');
      commands = [];
      results = {};
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    UpdateService service({MockClient? client, String executable = '/opt/git-manager/git_manager', String os = 'linux'}) =>
        UpdateService(
          client: client ?? github(),
          operatingSystem: os,
          executable: executable,
          tempDir: () async => tmp,
          run: (exe, args) async {
            commands.add([exe, ...args]);
            return results[exe] ??
                (exe == 'dpkg-deb'
                    ? ProcessResult(0, 0, 'Package: git-manager\nVersion: 2.3.0\n', '')
                    : ProcessResult(0, 0, '', ''));
          },
        );

    test('only when installed from the .deb on Linux with pkexec and apt', () async {
      expect(await service().canInstall(), isTrue);
      expect(await service(executable: '/home/me/git-manager/build/linux/x64/debug/bundle/git_manager').canInstall(), isFalse);
      expect(await service(os: 'windows', executable: r'C:\Program Files\Git Manager\git_manager.exe').canInstall(), isFalse);
      results['which'] = ProcessResult(0, 1, '', '');
      expect(await service().canInstall(), isFalse);
    });

    test('downloads with progress, verifies checksum and package, installs with pkexec', () async {
      final s = service();
      final release = (await s.latestRelease())!;
      final progress = <double>[];
      final file = await s.download(release, onProgress: progress.add);
      expect(await file.readAsBytes(), debBytes);
      expect(progress.last, 1.0);
      expect(commands.last, ['dpkg-deb', '-f', file.path, 'Package', 'Version']);

      await s.install(file);
      expect(commands.last, ['pkexec', 'apt-get', 'install', '-y', file.path]);
      expect(await tmp.exists(), isFalse, reason: 'the downloaded package is cleaned up');
    });

    test('a corrupted download or a different package is rejected', () async {
      var s = service(client: github(checksum: 'deadbeef'));
      await expectLater(s.download((await s.latestRelease())!),
          throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('checksum'))));

      s = service();
      results['dpkg-deb'] = ProcessResult(0, 0, 'Package: evil\nVersion: 2.3.0\n', '');
      await expectLater(s.download((await s.latestRelease())!),
          throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('not the expected'))));
      results['dpkg-deb'] = ProcessResult(0, 0, 'Package: git-manager\nVersion: 2.2.0\n', '');
      await expectLater(s.download((await s.latestRelease())!), throwsA(isA<UpdateException>()));
    });

    test('cancelled password and apt errors are explained', () async {
      final s = service();
      final file = File('${tmp.path}/x.deb')..writeAsStringSync('x');
      results['pkexec'] = ProcessResult(0, 126, '', '');
      await expectLater(s.install(file),
          throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('Update cancelled'))));
      results['pkexec'] = ProcessResult(0, 100, '', 'W: something\nE: Could not get lock /var/lib/dpkg/lock-frontend\n');
      await expectLater(
          s.install(file),
          throwsA(isA<UpdateException>()
              .having((e) => e.message, 'message', allOf(contains('could not be installed'), contains('Could not get lock')))));
    });

    test('a release without a .deb cannot be installed', () async {
      final s = service(client: github(release: releaseJson(withDeb: false)));
      await expectLater(s.download((await s.latestRelease())!),
          throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('no Linux package'))));
    });
  });
}
