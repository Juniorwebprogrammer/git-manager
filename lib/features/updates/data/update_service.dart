import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../domain/app_release.dart';

typedef RunProcess = Future<ProcessResult> Function(String executable, List<String> arguments);
typedef StartDetached = Future<void> Function(String executable, List<String> arguments);

/// Error del actualizador con un mensaje para el usuario.
class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);

  @override
  String toString() => message;
}

/// Busca, descarga e instala versiones nuevas publicadas como releases de
/// GitHub. Solo se instala dentro de la app si se instaló desde el .deb.
class UpdateService {
  final http.Client client;
  final RunProcess _run;
  final StartDetached _start;
  final String repository;
  final String operatingSystem;

  /// Ejecutable en marcha (el del .deb está en /opt/git-manager).
  final String executable;
  final Future<Directory> Function() _tempDir;

  static const installDir = '/opt/git-manager/';
  static const launcher = '/usr/bin/git-manager';
  static const packageName = 'git-manager';

  UpdateService({
    required this.client,
    RunProcess? run,
    StartDetached? start,
    this.repository = 'Juniorwebprogrammer/git-manager',
    String? operatingSystem,
    String? executable,
    Future<Directory> Function()? tempDir,
  })  : _run = run ?? ((e, a) => Process.run(e, a)),
        _start = start ?? ((e, a) => Process.start(e, a, mode: ProcessStartMode.detached)),
        operatingSystem = operatingSystem ?? Platform.operatingSystem,
        executable = executable ?? Platform.resolvedExecutable,
        _tempDir = tempDir ?? (() => Directory.systemTemp.createTemp('git-manager-update-'));

  String get releasesPage => 'https://github.com/$repository/releases';

  /// Última release publicada (sin borradores ni pre-releases); null si no
  /// hay ninguna con versión reconocible.
  Future<AppRelease?> latestRelease() async {
    final http.Response response;
    try {
      response = await client.get(
        Uri.parse('https://api.github.com/repos/$repository/releases/latest'),
        headers: const {'Accept': 'application/vnd.github+json', 'User-Agent': 'git-manager-updater'},
      ).timeout(const Duration(seconds: 20));
    } on SocketException {
      throw const UpdateException('No internet connection.');
    } on HttpException {
      throw const UpdateException('Could not reach GitHub.');
    }
    if (response.statusCode == 404) return null;
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const UpdateException('GitHub is limiting requests right now. Try again later.');
    }
    if (response.statusCode != 200) {
      throw UpdateException('GitHub responded with status code ${response.statusCode}.');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final tag = json['tag_name'] as String? ?? '';
    final version = AppVersion.parse(tag);
    if (version == null || json['draft'] == true || json['prerelease'] == true) return null;

    final assets = [
      for (final a in (json['assets'] as List<dynamic>? ?? const []))
        ReleaseAsset(
          name: (a as Map<String, dynamic>)['name'] as String? ?? '',
          url: a['browser_download_url'] as String? ?? '',
          size: (a['size'] as num?)?.toInt() ?? 0,
        ),
    ];
    final deb = assets.where((a) => a.name.startsWith('${packageName}_') && a.name.endsWith('_amd64.deb')).firstOrNull;
    return AppRelease(
      version: version,
      tag: tag,
      name: (json['name'] as String?)?.trim().isNotEmpty == true ? json['name'] as String : 'Git Manager $version',
      notes: json['body'] as String? ?? '',
      pageUrl: json['html_url'] as String? ?? releasesPage,
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
      deb: deb,
      debChecksum: deb == null ? null : assets.where((a) => a.name == '${deb.name}.sha256').firstOrNull,
    );
  }

  /// Si la app puede actualizarse sola: Linux, instalada desde el .deb y con
  /// pkexec + apt-get para instalar con la contraseña del sistema.
  Future<bool> canInstall() async {
    if (operatingSystem != 'linux' || !executable.startsWith(installDir)) return false;
    for (final tool in ['pkexec', 'apt-get', 'dpkg-deb']) {
      try {
        if ((await _run('which', [tool])).exitCode != 0) return false;
      } on ProcessException {
        return false;
      }
    }
    return true;
  }

  /// Descarga el .deb de [release] y comprueba que es íntegro y que es la
  /// versión esperada de Git Manager.
  Future<File> download(AppRelease release, {void Function(double progress)? onProgress}) async {
    final asset = release.deb;
    if (asset == null) throw const UpdateException('This release has no Linux package (.deb).');
    final dir = await _tempDir();
    final file = File(p.join(dir.path, p.basename(asset.name)));

    try {
      final response = await client.send(http.Request('GET', Uri.parse(asset.url)));
      if (response.statusCode != 200) {
        throw UpdateException('Download failed (status code ${response.statusCode}).');
      }
      final total = response.contentLength ?? asset.size;
      final sink = file.openWrite();
      var received = 0;
      final digest = await sha256.bind(response.stream.map((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call((received / total).clamp(0, 1));
        return chunk;
      })).first;
      await sink.close();

      final checksum = release.debChecksum;
      if (checksum != null) {
        final expected = await client.get(Uri.parse(checksum.url));
        final hash = expected.body.trim().split(RegExp(r'\s+')).first.toLowerCase();
        if (expected.statusCode != 200 || hash != digest.toString()) {
          throw const UpdateException('The downloaded package is corrupted (checksum mismatch). Try again.');
        }
      }
    } on SocketException {
      throw const UpdateException('The download was interrupted. Check your connection and try again.');
    } on http.ClientException {
      throw const UpdateException('The download was interrupted. Check your connection and try again.');
    }

    // Que sea de verdad nuestro paquete y la versión anunciada.
    final info = await _run('dpkg-deb', ['-f', file.path, 'Package', 'Version']);
    final fields = {
      for (final line in (info.stdout as String).split('\n'))
        if (line.contains(':')) line.substring(0, line.indexOf(':')).trim(): line.substring(line.indexOf(':') + 1).trim(),
    };
    if (info.exitCode != 0 || fields['Package'] != packageName || AppVersion.parse(fields['Version'] ?? '') != release.version) {
      throw const UpdateException('The downloaded file is not the expected Git Manager package.');
    }
    return file;
  }

  /// Instala el .deb (pkexec pide la contraseña en una ventana del sistema).
  Future<void> install(File deb) async {
    final result = await _run('pkexec', ['apt-get', 'install', '-y', deb.absolute.path]);
    switch (result.exitCode) {
      case 0:
        try {
          await deb.parent.delete(recursive: true);
        } on FileSystemException {
          // Es una carpeta temporal: no importa.
        }
      case 126 || 127:
        throw const UpdateException('Update cancelled: the administrator password was not confirmed.');
      default:
        final err = '${result.stderr}'.trim().split('\n').where((l) => l.startsWith('E:')).join('\n');
        throw UpdateException('The update could not be installed.${err.isEmpty ? '' : '\n\n$err'}');
    }
  }

  /// Abre la versión recién instalada. Quien llama cierra esta después.
  Future<void> launchInstalled() => _start(launcher, const []);
}
