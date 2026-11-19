import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

/// Comando a lanzar (para poder testear qué se ejecutaría).
class LaunchCommand {
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  const LaunchCommand(this.executable, this.arguments, {this.workingDirectory});

  @override
  String toString() => '$executable ${arguments.join(' ')}';
}

typedef ExecutableExists = Future<bool> Function(String executable);
typedef CommandStarter = Future<void> Function(LaunchCommand command);

/// Abre ficheros en el editor y terminales en una carpeta.
class SystemLauncher {
  final ExecutableExists _exists;
  final CommandStarter _start;
  final String _os;
  final Map<String, String> _env;
  final Future<String> Function(String path) _resolveLink;

  SystemLauncher({
    ExecutableExists? exists,
    CommandStarter? start,
    String? operatingSystem,
    Map<String, String>? environment,
    Future<String> Function(String path)? resolveLink,
  })  : _exists = exists ?? _defaultExists,
        _start = start ?? _defaultStart,
        _os = operatingSystem ?? Platform.operatingSystem,
        _env = environment ?? Platform.environment,
        _resolveLink = resolveLink ?? ((path) => File(path).resolveSymbolicLinks());

  static const editors = ['code', 'codium', 'code-insiders'];

  static Future<bool> _defaultExists(String executable) async {
    try {
      final result = await Process.run(Platform.isWindows ? 'where' : 'which', [executable]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _defaultStart(LaunchCommand c) async {
    await Process.start(
      c.executable,
      c.arguments,
      workingDirectory: c.workingDirectory,
      mode: ProcessStartMode.detached,
      // En Windows `code` es un .cmd: necesita el shell.
      runInShell: Platform.isWindows,
    );
  }

  /// Editor de código disponible (VS Code y derivados), o null.
  Future<String?> findEditor() async {
    for (final e in editors) {
      if (await _exists(e)) return e;
    }
    return null;
  }

  /// Abre [file] en VS Code (en [line] si se indica). Sin VS Code, lo abre
  /// con la aplicación por defecto del sistema. Devuelve el nombre de lo
  /// que se usó, para mostrarlo.
  Future<String> openInEditor(String file, {int? line}) async {
    final editor = await findEditor();
    if (editor != null) {
      await _start(LaunchCommand(editor, ['-g', line != null && line > 0 ? '$file:$line' : file]));
      return 'VS Code';
    }
    await launchUrl(Uri.file(file));
    return 'the default app';
  }

  /// Abre la carpeta [directory] (un repo) en VS Code.
  Future<bool> openFolderInEditor(String directory) async {
    final editor = await findEditor();
    if (editor == null) return false;
    await _start(LaunchCommand(editor, [directory]));
    return true;
  }

  /// Argumentos para abrir cada terminal conocida en [dir].
  static List<String> terminalArguments(String terminal, String dir) => switch (terminal) {
        'ptyxis' => ['--new-window', '-d', dir],
        'gnome-terminal' || 'kgx' || 'xfce4-terminal' || 'foot' => ['--working-directory=$dir'],
        'konsole' => ['--workdir', dir],
        'tilix' => ['-w', dir],
        'kitty' => ['--directory', dir],
        'alacritty' => ['--working-directory', dir],
        'wezterm' => ['start', '--cwd', dir],
        _ => const [],
      };

  static const _linuxTerminals = [
    'x-terminal-emulator',
    'ptyxis',
    'gnome-terminal',
    'kgx',
    'konsole',
    'xfce4-terminal',
    'tilix',
    'kitty',
    'alacritty',
    'wezterm',
    'foot',
    'xterm',
  ];

  /// Qué se ejecutaría para abrir una terminal en [dir] (null = ninguna).
  Future<LaunchCommand?> terminalCommand(String dir) async {
    switch (_os) {
      case 'windows':
        if (await _exists('wt')) return LaunchCommand('wt', ['-d', dir], workingDirectory: dir);
        return LaunchCommand('cmd.exe', ['/c', 'start', 'cmd.exe'], workingDirectory: dir);
      case 'macos':
        return LaunchCommand('open', ['-a', 'Terminal', dir]);
      default:
        final preferred = _env['TERMINAL'];
        for (final t in [?preferred, ..._linuxTerminals]) {
          if (!await _exists(t)) continue;
          var name = t;
          if (t == 'x-terminal-emulator') {
            // Es un enlace (alternatives) a la terminal real: usar sus argumentos.
            try {
              name = p.basename(await _resolveLink('/usr/bin/x-terminal-emulator'));
            } catch (_) {}
          }
          return LaunchCommand(t, terminalArguments(name, dir), workingDirectory: dir);
        }
        return null;
    }
  }

  /// Comando para mostrar una notificación del sistema (null = no hay forma).
  Future<LaunchCommand?> notificationCommand(String title, String body) async {
    switch (_os) {
      case 'linux':
        if (!await _exists('notify-send')) return null;
        return LaunchCommand('notify-send', ['--app-name=Git Manager', '--icon=git', title, body]);
      case 'macos':
        String q(String s) => s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
        return LaunchCommand('osascript', ['-e', 'display notification "${q(body)}" with title "${q(title)}"']);
      case 'windows':
        String q(String s) => s.replaceAll("'", "''");
        return LaunchCommand('powershell', [
          '-NoProfile',
          '-WindowStyle',
          'Hidden',
          '-Command',
          'Add-Type -AssemblyName System.Windows.Forms; '
              r'$n = New-Object System.Windows.Forms.NotifyIcon; '
              r'$n.Icon = [System.Drawing.SystemIcons]::Information; $n.Visible = $true; '
              "\$n.ShowBalloonTip(5000, '${q(title)}', '${q(body)}', [System.Windows.Forms.ToolTipIcon]::Info); "
              r'Start-Sleep -Seconds 6; $n.Dispose()',
        ]);
      default:
        return null;
    }
  }

  /// Muestra una notificación del sistema. false si no se pudo.
  Future<bool> notify(String title, String body) async {
    final command = await notificationCommand(title, body);
    if (command == null) return false;
    await _start(command);
    return true;
  }

  /// Abre una terminal en [dir]. false si no se encontró ninguna.
  Future<bool> openTerminal(String dir) async {
    final command = await terminalCommand(dir);
    if (command == null) return false;
    await _start(command);
    return true;
  }
}
