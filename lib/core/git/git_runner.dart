import 'dart:convert';
import 'dart:io';

import '../error/app_exception.dart';
import '../hosting/git_provider.dart';

/// Identidad con la que se ejecuta git para una cuenta concreta, **sin**
/// tocar la configuración global del sistema: el token viaja como cabecera
/// HTTP (vía variables de entorno `GIT_CONFIG_*`, que no aparecen en la
/// lista de procesos) y el autor/committer vía `GIT_AUTHOR_*`.
class GitIdentity {
  final String login;
  final String token;
  final String name;
  final String email;

  /// Servicio de la cuenta: decide a qué hosts se manda el token.
  final GitProvider provider;

  /// Organizaciones de Azure DevOps (para las URL `{org}.visualstudio.com`).
  final List<String> organizations;

  const GitIdentity({
    required this.login,
    required this.token,
    required this.name,
    required this.email,
    this.provider = GitProvider.github,
    this.organizations = const [],
  });

  Map<String, String> toEnvironment() {
    // Azure DevOps acepta cualquier usuario con el PAT como contraseña;
    // el habitual es vacío (":PAT").
    final user = provider == GitProvider.azure ? '' : login;
    final basic = base64.encode(utf8.encode('$user:$token'));
    final config = <(String, String)>[];
    for (final host in provider.httpsHosts(organizations)) {
      // Vacía la lista de credential helpers de ese host, así no se cuela el
      // token de otra cuenta guardado en ~/.git-credentials…
      config.add(('credential.https://$host.helper', ''));
      // …y manda el de esta cuenta como cabecera.
      config.add(('http.https://$host/.extraheader', 'Authorization: Basic $basic'));
    }
    return {
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_AUTHOR_NAME': name,
      'GIT_AUTHOR_EMAIL': email,
      'GIT_COMMITTER_NAME': name,
      'GIT_COMMITTER_EMAIL': email,
      'GIT_CONFIG_COUNT': '${config.length}',
      for (var i = 0; i < config.length; i++) ...{
        'GIT_CONFIG_KEY_$i': config[i].$1,
        'GIT_CONFIG_VALUE_$i': config[i].$2,
      },
    };
  }
}

class GitOutput {
  final int exitCode;
  final String stdout;
  final String stderr;

  const GitOutput(this.exitCode, this.stdout, this.stderr);

  bool get ok => exitCode == 0;

  String get message =>
      [stderr.trim(), stdout.trim()].where((s) => s.isNotEmpty).join('\n');
}

/// Lanza el binario `git` real. Toda la app pasa por aquí.
class GitRunner {
  final String executable;

  /// Variables extra para todos los comandos (p. ej. aislar la config
  /// global en tests con GIT_CONFIG_GLOBAL).
  final Map<String, String> environment;

  const GitRunner({this.executable = 'git', this.environment = const {}});

  static const _codec = Utf8Codec(allowMalformed: true);

  static const _baseArgs = [
    '-c', 'core.quotepath=off',
    '-c', 'color.ui=false',
    '-c', 'advice.detachedHead=false',
  ];

  /// Ejecuta git y devuelve la salida sin lanzar aunque falle.
  Future<GitOutput> tryRun(
    List<String> args, {
    String? workingDirectory,
    GitIdentity? identity,
    Map<String, String>? extraEnvironment,
  }) async {
    try {
      final result = await Process.run(
        executable,
        [..._baseArgs, ...args],
        workingDirectory: workingDirectory,
        environment: {
          // Sin terminal: nunca preguntar ni abrir un editor (se colgaría).
          'GIT_TERMINAL_PROMPT': '0',
          'GIT_EDITOR': 'true',
          'GIT_MERGE_AUTOEDIT': 'no',
          // Mensajes de git en inglés, como la interfaz (y reconocibles en
          // friendlyGitError), sin tocar la codificación.
          'LANGUAGE': 'C',
          ...environment,
          ...?identity?.toEnvironment(),
          ...?extraEnvironment,
        },
        stdoutEncoding: _codec,
        stderrEncoding: _codec,
      );
      return GitOutput(result.exitCode, result.stdout as String, result.stderr as String);
    } on ProcessException catch (e) {
      throw GitCommandException('Could not run git (is it installed and on PATH?): ${e.message}');
    }
  }

  /// Ejecuta git y lanza [GitCommandException] si el código de salida no
  /// es 0. Devuelve stdout.
  Future<String> run(
    List<String> args, {
    String? workingDirectory,
    GitIdentity? identity,
    Map<String, String>? extraEnvironment,
  }) async {
    final out = await tryRun(
      args,
      workingDirectory: workingDirectory,
      identity: identity,
      extraEnvironment: extraEnvironment,
    );
    if (!out.ok) {
      final msg = friendlyGitError(out.message);
      throw GitCommandException(
        msg.isEmpty ? 'git ${args.first} failed (exit code ${out.exitCode}).' : msg,
      );
    }
    return out.stdout;
  }
}

/// Traduce errores de git crípticos a algo accionable. Si no reconoce el
/// error, lo devuelve tal cual.
String friendlyGitError(String message) {
  final worktree = RegExp(r"'([^']+)' is already (?:used by worktree|checked out) at '([^']+)'").firstMatch(message);
  if (worktree != null) {
    final branch = worktree.group(1)!;
    final folder = worktree.group(2)!;
    return 'The branch "$branch" is already open in another folder (a git worktree):\n'
        '$folder\n\n'
        'Git does not allow the same branch to be checked out in two places at once. '
        'Open that folder instead, or remove the worktree if you no longer need it '
        '(right-click the branch → "Remove worktree").\n\n'
        'Git said: $message';
  }
  final badConfig = RegExp(r"bad config variable '([^']+)' in file '([^']+)' at line (\d+)").firstMatch(message);
  if (badConfig != null) {
    final key = badConfig.group(1)!;
    final hint = key == 'gpg.format'
        ? 'It must be "openpgp", "ssh" or "x509" — or delete the line if you do not sign commits.'
        : 'Fix or delete that line.';
    return 'Your git configuration has an invalid value for "$key" in\n'
        '${badConfig.group(2)} (line ${badConfig.group(3)}).\n\n$hint\n\nGit said: $message';
  }
  return message;
}
