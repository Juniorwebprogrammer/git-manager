import 'dart:io';

import 'package:path/path.dart' as p;

import '../../features/repos/domain/entities/git_action.dart';
import '../git/git_runner.dart';

/// Claves que se pueden usar para firmar commits en este equipo.
class SigningKeys {
  final GitRunner git;

  const SigningKeys(this.git);

  Future<List<({String key, String label})>> available(SigningFormat format) async {
    switch (format) {
      case SigningFormat.ssh:
        final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
        final dir = Directory(p.join(home, '.ssh'));
        if (!await dir.exists()) return const [];
        final keys = <({String key, String label})>[];
        await for (final f in dir.list()) {
          if (f is File && f.path.endsWith('.pub')) keys.add((key: f.path, label: p.basename(f.path)));
        }
        keys.sort((a, b) => a.label.compareTo(b.label));
        return keys;
      case SigningFormat.gpg:
        try {
          final out = await Process.run('gpg', ['--list-secret-keys', '--keyid-format=long', '--with-colons']);
          if (out.exitCode != 0) return const [];
          final keys = <({String key, String label})>[];
          String? id;
          for (final line in (out.stdout as String).split('\n')) {
            final f = line.split(':');
            if (f.first == 'sec' && f.length > 4) {
              id = f[4];
            } else if (f.first == 'uid' && id != null && f.length > 9) {
              keys.add((key: id, label: '${f[9]} ($id)'));
              id = null;
            }
          }
          return keys;
        } catch (_) {
          return const [];
        }
    }
  }

  /// La config GLOBAL tiene `gpg.format` vacío (algunas herramientas lo
  /// dejan así) y git rechaza firmar mientras siga así.
  Future<bool> globalConfigBroken() async {
    final out = await git.tryRun(['config', '--global', '--get-all', 'gpg.format']);
    if (!out.ok) return false; // no está definido: correcto
    var text = out.stdout;
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    return text.split('\n').any((v) => v.trim().isEmpty);
  }

  /// Quita de la config global los `gpg.format` / `user.signingkey` vacíos.
  Future<void> fixGlobalConfig() async {
    await git.tryRun(['config', '--global', '--unset-all', 'gpg.format', r'^$']);
    final key = await git.tryRun(['config', '--global', '--get', 'user.signingkey']);
    if (key.ok && key.stdout.trim().isEmpty) {
      await git.tryRun(['config', '--global', '--unset-all', 'user.signingkey', r'^$']);
    }
  }
}
