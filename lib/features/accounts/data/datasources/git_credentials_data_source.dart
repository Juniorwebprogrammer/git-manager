import 'dart:io';

import '../../../../core/error/app_exception.dart';

/// Gestiona las credenciales HTTPS de git (`~/.git-credentials`) para que
/// `clone`/`push`/`pull` usen automáticamente el token de la cuenta activa,
/// vía el credential helper `store` estándar de git.
class GitCredentialsDataSource {
  /// Permite fijar el entorno (típicamente `HOME`) con el que se invoca
  /// `git` y se localiza `~/.git-credentials`, para poder testear esta
  /// clase sin tocar los archivos reales del sistema.
  final Map<String, String>? environmentOverride;

  const GitCredentialsDataSource({this.environmentOverride});

  static const _host = 'github.com';

  Future<void> setActiveCredential({
    required String login,
    required String token,
  }) async {
    await _run(['config', '--global', 'credential.helper', 'store']);

    final file = _credentialsFile();
    final lines = await _readLines(file);
    final filtered = lines.where((line) => !_matchesHost(line, _host)).toList();

    filtered.add(
      'https://${Uri.encodeComponent(login)}:${Uri.encodeComponent(token)}@$_host',
    );

    await _writeLines(file, filtered);
  }

  /// Quita la credencial de github.com guardada, si la hay.
  Future<void> clearActiveCredential() async {
    final file = _credentialsFile();
    final lines = await _readLines(file);
    final filtered = lines.where((line) => !_matchesHost(line, _host)).toList();

    if (filtered.isEmpty) {
      if (await file.exists()) await file.delete();
    } else {
      await _writeLines(file, filtered);
    }
  }

  File _credentialsFile() {
    final home = environmentOverride?['HOME'] ?? Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw const GitConfigException('Could not determine the HOME directory.');
    }
    return File('$home/.git-credentials');
  }

  Future<List<String>> _readLines(File file) async {
    try {
      if (!await file.exists()) return [];
      return await file.readAsLines();
    } catch (e) {
      throw GitConfigException('Could not read ~/.git-credentials: $e');
    }
  }

  Future<void> _writeLines(File file, List<String> lines) async {
    try {
      await file.writeAsString('${lines.join('\n')}\n');
      if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('chmod', ['600', file.path]);
      }
    } catch (e) {
      throw GitConfigException('Could not write ~/.git-credentials: $e');
    }
  }

  bool _matchesHost(String line, String host) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return false;
    return Uri.tryParse(trimmed)?.host == host;
  }

  Future<void> _run(List<String> arguments) async {
    final ProcessResult result;
    try {
      result = await Process.run('git', arguments, environment: environmentOverride);
    } catch (e) {
      throw GitConfigException('Could not run git: $e');
    }
    if (result.exitCode != 0) {
      throw GitConfigException(
        'git ${arguments.join(' ')} failed: ${result.stderr}',
      );
    }
  }
}
