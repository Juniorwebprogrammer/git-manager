import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../repos/presentation/widgets/pull_request_view.dart' show MarkdownText;
import '../domain/app_release.dart';
import 'update_notifier.dart';

/// Barra sobre todas las pantallas cuando hay una versión nueva: novedades,
/// actualizar (descarga + instalación), más tarde u omitir la versión.
class UpdateBanner extends ConsumerWidget {
  /// Navigator de la app: la barra está por encima y lo necesita para abrir
  /// el diálogo de novedades.
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const UpdateBanner({super.key, required this.navigatorKey, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateNotifierProvider);
    return Column(
      children: [
        if (state.showBanner) _Bar(state: state, navigatorKey: navigatorKey),
        Expanded(child: child),
      ],
    );
  }
}

Future<void> showReleaseNotes(BuildContext context, WidgetRef ref, AppRelease release) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final state = ref.read(updateNotifierProvider);
      return AlertDialog(
        title: Text("What's new in ${release.name}"),
        content: SizedBox(
          width: 560,
          height: 380,
          child: SingleChildScrollView(
            child: release.notes.trim().isEmpty
                ? const Text('No release notes.')
                : MarkdownText(release.notes),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => launchUrl(Uri.parse(release.pageUrl)),
            child: const Text('Open on GitHub'),
          ),
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
          if (state.phase == UpdatePhase.available)
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _update(ref, release, state.canInstall);
              },
              child: Text(state.canInstall ? 'Update now' : 'Download'),
            ),
        ],
      );
    },
  );
}

void _update(WidgetRef ref, AppRelease release, bool canInstall) {
  if (canInstall) {
    ref.read(updateNotifierProvider.notifier).install();
  } else {
    launchUrl(Uri.parse(release.pageUrl));
  }
}

class _Bar extends ConsumerWidget {
  final UpdateState state;
  final GlobalKey<NavigatorState> navigatorKey;

  const _Bar({required this.state, required this.navigatorKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final notifier = ref.read(updateNotifierProvider.notifier);
    final release = state.release!;
    final failed = state.phase == UpdatePhase.failed;
    final foreground = failed ? scheme.onErrorContainer : scheme.onPrimaryContainer;

    final (IconData icon, String text) = switch (state.phase) {
      UpdatePhase.downloading => (
          Icons.downloading,
          'Downloading Git Manager ${release.version}… ${(state.progress * 100).round()}%'
        ),
      UpdatePhase.installing => (
          Icons.install_desktop,
          'Installing Git Manager ${release.version}… confirm with your password in the system window.'
        ),
      UpdatePhase.installed => (
          Icons.check_circle_outline,
          'Git Manager ${release.version} is installed. Restart to use it.'
        ),
      UpdatePhase.failed => (Icons.error_outline, state.error ?? 'The update failed.'),
      _ => (
          Icons.system_update_alt,
          'Git Manager ${release.version} is available'
              '${state.current == null ? '' : ' — you have ${state.current}'}.'
        ),
    };

    Widget button(String label, VoidCallback onPressed, {bool primary = false}) => primary
        ? FilledButton(onPressed: onPressed, child: Text(label))
        : TextButton(
            style: TextButton.styleFrom(foregroundColor: foreground),
            onPressed: onPressed,
            child: Text(label),
          );

    final whatsNew = button("What's new", () {
      final context = navigatorKey.currentContext;
      if (context != null) showReleaseNotes(context, ref, release);
    });

    final actions = <Widget>[
      ...switch (state.phase) {
        UpdatePhase.available => [
            whatsNew,
            button('Skip this version', notifier.skip),
            button('Later', notifier.later),
            button(state.canInstall ? 'Update' : 'Download', () => _update(ref, release, state.canInstall), primary: true),
          ],
        UpdatePhase.installed => [
            button('Later', notifier.later),
            button('Restart now', notifier.restart, primary: true),
          ],
        UpdatePhase.failed => [
            button('Download from GitHub', () => launchUrl(Uri.parse(release.pageUrl))),
            button('Dismiss', notifier.later),
            button('Try again', notifier.install, primary: true),
          ],
        _ => const <Widget>[],
      },
    ];

    final message = Row(
      children: [
        Icon(icon, size: 20, color: foreground),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(color: foreground, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );

    return Material(
      key: const ValueKey('update-banner'),
      color: failed ? scheme.errorContainer : scheme.primaryContainer,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
              child: LayoutBuilder(
                builder: (context, c) {
                  final buttons = Wrap(spacing: 4, runSpacing: 4, alignment: WrapAlignment.end, children: actions);
                  // Estrecho: texto arriba y botones debajo.
                  if (c.maxWidth < 720 && actions.isNotEmpty) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [message, const SizedBox(height: 4), Align(alignment: Alignment.centerRight, child: buttons)],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: message),
                      if (actions.isNotEmpty) ...[const SizedBox(width: 12), buttons],
                    ],
                  );
                },
              ),
            ),
            if (state.isBusy)
              LinearProgressIndicator(
                value: state.phase == UpdatePhase.downloading && state.progress > 0 ? state.progress : null,
                minHeight: 3,
              ),
          ],
        ),
      ),
    );
  }
}
