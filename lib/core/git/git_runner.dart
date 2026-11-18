import 'dart:convert';
import 'dart:io';

import '../error/app_exception.dart';

/// Identidad con la que se ejecuta git para una cuenta concreta, **sin**
/// tocar la configuración global del sistema: el token viaja como cabecera
/// HTTP (vía variables de entorno `GIT_CONFIG_*`, que no aparecen en la
/// lista de procesos) y el autor/committer vía `GIT_AUTHOR_*`.
class GitIdentity {
  final String login;
  final String token;
  final String name;
  final String email;

  const GitIdentity({
    required this.login,
    required this.token,
    required this.name,
    required this.email,
  });

  Map<String, String> toEnvironment() {
    final basic = base64.encode(utf8.encode('$login:$token'));
    return {
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_AUTHOR_NAME': name,
      'GIT_AUTHOR_EMAIL': email,
      'GIT_COMMITTER_NAME': name,
      'GIT_COMMITTER_EMAIL': email,
      'GIT_CONFIG_COUNT': '2',
      // Vacía la lista de credential helpers para github.com, así no se
      // cuela el token de otra cuenta guardado en ~/.git-credentials.
      'GIT_CONFIG_KEY_0': 'credential.https://github.com.helper',
      'GIT_CONFIG_VALUE_0': '',
      'GIT_CONFIG_KEY_1': 'http.https://github.com/.extraheader',
      'GIT_CONFIG_VALUE_1': 'Authorization: Basic $basic',
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

  const GitRunner({this.executable = 'git'});

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
          ...?identity?.toEnvironment(),
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
  }) async {
    final out = await tryRun(args, workingDirectory: workingDirectory, identity: identity);
    if (!out.ok) {
      final msg = out.message;
      throw GitCommandException(
        msg.isEmpty ? 'git ${args.first} failed (exit code ${out.exitCode}).' : msg,
      );
    }
    return out.stdout;
  }
}
