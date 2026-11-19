import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/error/app_failure.dart';
import '../../domain/entities/file_change.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';

const laneColors = [
  Color(0xFF29B6F6),
  Color(0xFFAB47BC),
  Color(0xFF66BB6A),
  Color(0xFFFFA726),
  Color(0xFFEC407A),
  Color(0xFF26A69A),
  Color(0xFFFFCA28),
  Color(0xFF7E57C2),
  Color(0xFFEF5350),
  Color(0xFF5C6BC0),
];

Color laneColor(int index) => laneColors[index % laneColors.length];

const monoFamily = 'monospace';
const monoFallback = ['DejaVu Sans Mono', 'Ubuntu Mono', 'Consolas', 'Menlo', 'Courier New'];

TextStyle monoStyle(BuildContext context, {double size = 12.5, Color? color}) => TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: size,
      height: 1.45,
      color: color ?? Theme.of(context).colorScheme.onSurface,
    );

String _two(int n) => n.toString().padLeft(2, '0');

String formatDate(DateTime d) {
  final now = DateTime.now();
  final time = '${_two(d.hour)}:${_two(d.minute)}';
  if (d.year == now.year && d.month == now.month && d.day == now.day) return 'Today $time';
  return '${d.year}-${_two(d.month)}-${_two(d.day)} $time';
}

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

Color colorForName(String name) => laneColor(name.codeUnits.fold(0, (a, b) => a + b));

class InitialsAvatar extends StatelessWidget {
  final String name;
  final double size;

  const InitialsAvatar(this.name, {super.key, this.size = 20});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colorForName(name), shape: BoxShape.circle),
      child: Text(
        initialsOf(name),
        style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w700, color: Colors.white),
      ),
    );
  }
}

Color changeColor(ChangeType type) => switch (type) {
      ChangeType.added || ChangeType.untracked => const Color(0xFF43A047),
      ChangeType.deleted => const Color(0xFFE53935),
      ChangeType.renamed || ChangeType.copied => const Color(0xFF1E88E5),
      ChangeType.conflicted => const Color(0xFFFF6F00),
      _ => const Color(0xFFF9A825),
    };

class ChangeBadge extends StatelessWidget {
  final ChangeType type;

  const ChangeBadge(this.type, {super.key});

  @override
  Widget build(BuildContext context) {
    final color = changeColor(type);
    final letter = FileChange(path: '', type: type).letter;
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.7)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(letter, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: color)),
    );
  }
}

// ------------------------------------------------------------- diálogos

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: Text(message)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<String?> promptDialog(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String confirmLabel = 'OK',
  String? helper,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) {
      void submit() {
        final value = controller.text.trim();
        if (value.isNotEmpty) Navigator.pop(context, value);
      }

      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: label, helperText: helper),
            onSubmitted: (_) => submit(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: Text(confirmLabel)),
        ],
      );
    },
  );
}

Future<void> showGitError(BuildContext context, AppFailure failure) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
      title: const Text('Git reported an error'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 360),
        child: SingleChildScrollView(child: SelectableText(failure.message, style: monoStyle(context, size: 12))),
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: failure.message)),
          child: const Text('Copy'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    ),
  );
}

void showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
}

/// Ejecuta [action] en el repo y muestra el error (si lo hay).
/// Devuelve true si fue bien.
Future<bool> runGitAction(
  BuildContext context,
  WidgetRef ref,
  RepoHandle repo,
  GitAction action, {
  String? successMessage,
}) async {
  final failure = await ref.read(repoNotifierProvider(repo).notifier).run(action);
  if (!context.mounted) return failure == null;
  if (failure != null) {
    // Push rechazado por no ser fast-forward: ofrecer force push.
    if (action is PushAction && !action.force &&
        RegExp(r'rejected|non-fast-forward|fetch first', caseSensitive: false).hasMatch(failure.message)) {
      final force = await confirmDialog(
        context,
        title: 'Push rejected',
        message: 'The remote has commits you do not have locally.\n\n'
            'Pull first to integrate them, or force push (with lease) to overwrite the remote branch.\n\n'
            '${failure.message}',
        confirmLabel: 'Force push',
        destructive: true,
      );
      if (force && context.mounted) {
        return runGitAction(context, ref, repo, PushAction(branch: action.branch, force: true),
            successMessage: successMessage);
      }
      return false;
    }
    await showGitError(context, failure);
    return false;
  }
  if (successMessage != null) showToast(context, successMessage);
  return true;
}

/// Menú contextual en la posición del ratón.
Future<T?> showContextMenu<T>(
  BuildContext context,
  Offset position,
  List<PopupMenuEntry<T>> items,
) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
    // Por defecto el menú no pasa de 280 px y cortaba textos como
    // "Rebase feature/x onto origin/main".
    constraints: const BoxConstraints(minWidth: 200, maxWidth: 440),
    items: items,
  );
}

PopupMenuItem<String> menuItem(String value, IconData icon, String label, {bool enabled = true, Color? color}) {
  return PopupMenuItem<String>(
    value: value,
    enabled: enabled,
    height: 36,
    child: Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 12),
        Flexible(
          child: Tooltip(
            message: label,
            waitDuration: const Duration(seconds: 1),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color)),
          ),
        ),
      ],
    ),
  );
}

/// Confirma y lanza un rebase de [branch] (null = rama actual) sobre [onto].
Future<void> confirmAndRebase(
  BuildContext context,
  WidgetRef ref,
  RepoHandle repo, {
  required String onto,
  required String branchLabel,
  String? branch,
  String? ontoLabel,
}) async {
  final ok = await confirmDialog(
    context,
    title: 'Rebase $branchLabel onto ${ontoLabel ?? onto}',
    message: 'The commits of "$branchLabel" will be replayed on top of "${ontoLabel ?? onto}", '
        'rewriting their history into a straight line.\n\n'
        '• Uncommitted changes are stashed and restored automatically.\n'
        '• If there are conflicts you can resolve them, then Continue, Skip or Abort.\n'
        '• If "$branchLabel" was already pushed, you will need to force push afterwards.',
    confirmLabel: 'Rebase',
  );
  if (!ok || !context.mounted) return;
  await runGitAction(context, ref, repo, RebaseAction(onto, branch: branch),
      successMessage: 'Rebased $branchLabel onto ${ontoLabel ?? onto}');
}

/// Pide el mensaje y hace `merge --squash` de [source] en la rama actual.
Future<void> squashMergeInto(BuildContext context, WidgetRef ref, RepoHandle repo, String source, String into) async {
  final message = await promptDialog(
    context,
    title: 'Squash $source into $into',
    label: 'Commit message',
    initial: 'Squash merge $source',
    helper: 'All changes from $source become a single new commit on $into.',
    confirmLabel: 'Squash',
  );
  if (message == null || !context.mounted) return;
  await runGitAction(context, ref, repo, SquashMergeAction(source, message), successMessage: 'Squashed $source into $into');
}
