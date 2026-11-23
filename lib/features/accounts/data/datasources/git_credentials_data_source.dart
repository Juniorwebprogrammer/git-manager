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

  /// Guarda la credencial de [hosts] (por defecto github.com) sustituyendo
  /// la que hubiera para esos hosts; las de otros hosts no se tocan, así
  /// pueden convivir una cuenta de GitHub y otra de Azure DevOps.
  Future<void> setActiveCredential({
    required String login,
    required String token,
    List<String> hosts = const [_host],
  }) async {
    await _run(['config', '--global', 'credential.helper', 'store']);

    final file = _credentialsFile();
    final lines = await _readLines(file);
    final filtered = lines.where((line) => !hosts.any((h) => _matchesHost(line, h))).toList();

    for (final host in hosts) {
      filtered.add('https://${Uri.encodeComponent(login)}:${Uri.encodeComponent(token)}@$host');
    }

    await _writeLines(file, filtered);
  }

  /// Credenciales de una cuenta de Azure DevOps. Las URL de clonado de
  /// Azure llevan la organización como usuario (`https://org@dev.azure.com/…`)
  /// y git solo usa entradas con ese mismo usuario, así que se guarda una
  /// línea por organización (y una genérica para URL sin usuario).
  Future<void> setAzureCredentials({required String token, required List<String> organizations}) async {
    await _run(['config', '--global', 'credential.helper', 'store']);
    final hosts = ['dev.azure.com', for (final o in organizations) '$o.visualstudio.com'];
    final file = _credentialsFile();
    final lines = await _readLines(file);
    final filtered = lines.where((line) => !hosts.any((h) => _matchesHost(line, h))).toList();
    final secret = Uri.encodeComponent(token);
    for (final org in organizations) {
      final user = Uri.encodeComponent(org);
      filtered.add('https://$user:$secret@dev.azure.com');
      filtered.add('https://$user:$secret@$org.visualstudio.com');
    }
    filtered.add('https://pat:$secret@dev.azure.com');
    await _writeLines(file, filtered);
  }

  /// Quita la credencial guardada de [hosts] (por defecto github.com).
  Future<void> clearActiveCredential({List<String> hosts = const [_host]}) async {
    final file = _credentialsFile();
    final lines = await _readLines(file);
    final filtered = lines.where((line) => !hosts.any((h) => _matchesHost(line, h))).toList();

    if (filtered.isEmpty) {
      if (await file.exists()) await file.delete();
    } else {
      await _writeLines(file, filtered);
    }
  }

  File _credentialsFile() {
    final env = environmentOverride ?? Platform.environment;
    // Mirrors git's own lookup order: HOME first (respected on Windows too
    // when set, e.g. by Git Bash), then USERPROFILE, which is what a plain
    // Windows process has instead of HOME.
    final home = _firstNonEmpty(env, const ['HOME', 'USERPROFILE']);
    if (home == null) {
      throw const GitConfigException('Could not determine the HOME directory.');
    }
    return File('$home/.git-credentials');
  }

  String? _firstNonEmpty(Map<String, String> env, List<String> keys) {
    for (final key in keys) {
      final value = env[key];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
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
