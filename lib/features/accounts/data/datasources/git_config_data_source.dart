import 'dart:io';

import '../../../../core/error/app_exception.dart';

/// Escribe la identidad global de git (`~/.gitconfig`) del sistema,
/// que es lo que determina con qué nombre/email queda atribuido cada
/// commit que se haga desde la línea de comandos.
class GitConfigDataSource {
  /// Permite fijar el entorno (típicamente `HOME`) con el que se invoca
  /// `git`, para poder testear esta clase sin tocar el `~/.gitconfig`
  /// real del sistema.
  final Map<String, String>? environmentOverride;

  const GitConfigDataSource({this.environmentOverride});

  Future<void> setGlobalIdentity({
    required String name,
    required String email,
  }) async {
    await _run(['config', '--global', 'user.name', name]);
    await _run(['config', '--global', 'user.email', email]);
  }

  Future<void> _run(List<String> arguments) async {
    final ProcessResult result;
    try {
      result = await Process.run('git', arguments, environment: environmentOverride);
    } catch (e) {
      throw GitConfigException('No se pudo ejecutar git: $e');
    }
    if (result.exitCode != 0) {
      throw GitConfigException(
        'git ${arguments.join(' ')} falló: ${result.stderr}',
      );
    }
  }
}
