import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../domain/entities/git_action.dart';
import '../../domain/entities/repo_snapshot.dart';
import '../../domain/repositories/git_repository.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/settings/app_settings.dart';
import '../state/repo_notifier.dart';
import 'pull_request_dialog.dart';
import 'ui_helpers.dart';

/// Barra de acciones principal: rama actual, pull, push, fetch, stash…
/// Se compacta (solo iconos) cuando no hay sitio.
class RepoToolbar extends ConsumerWidget {
  final RepoHandle repo;
  final bool sidebarVisible;
  final VoidCallback onToggleSidebar;

  const RepoToolbar({
    super.key,
    required this.repo,
    required this.sidebarVisible,
    required this.onToggleSidebar,
  });

  Future<void> _undo(BuildContext context, WidgetRef ref) async {
    final label = ref.read(repoNotifierProvider(repo)).undoPlan?.label;
    final failure = await ref.read(repoNotifierProvider(repo).notifier).undo();
    if (!context.mounted) return;
    if (failure != null) {
      await showGitError(context, failure);
    } else if (label != null) {
      showToast(context, label.replaceFirst('Undo', 'Undone:'));
    }
  }

  Future<void> _redo(BuildContext context, WidgetRef ref) async {
    final failure = await ref.read(repoNotifierProvider(repo).notifier).redo();
    if (!context.mounted) return;
    if (failure != null) await showGitError(context, failure);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(repoNotifierProvider(repo));
    final snapshot = state.snapshot;
    final current = snapshot?.currentRef;
    final busy = state.isBusy;
    final hasRemote = snapshot?.remotes.isNotEmpty ?? false;

    void run(GitAction action, [String? ok]) => runGitAction(context, ref, repo, action, successMessage: ok);

    Future<void> newBranch() async {
      final selected = state.selectedSha;
      final name = await promptDialog(
        context,
        title: 'Create branch',
        label: 'Branch name',
        helper: selected != null ? 'Starts at selected commit ${selected.substring(0, 7)}' : 'Starts at HEAD',
        confirmLabel: 'Create and checkout',
      );
      if (name != null && context.mounted) run(CreateBranchAction(name, startPoint: selected));
    }

    Future<void> stash() async {
      final message = await promptDialog(context,
          title: 'Stash changes', label: 'Message (optional)', initial: 'WIP', confirmLabel: 'Stash');
      if (message != null && context.mounted) run(StashAction(message: message), 'Changes stashed');
    }

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final compact = width < 1200; // solo iconos
      final showRepo = width >= 720;

      return Container(
        color: theme.colorScheme.surfaceContainer,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: compact ? 46 : 56,
              child: Row(
                children: [
                  // Izquierda y derecha tienen el mismo flex: los botones
                  // quedan siempre centrados en la barra.
                  Expanded(
                    child: Row(
                      children: [
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: sidebarVisible ? 'Hide sidebar' : 'Show sidebar',
                          onPressed: onToggleSidebar,
                          icon: Icon(sidebarVisible ? Icons.view_sidebar : Icons.view_sidebar_outlined, size: 20),
                        ),
                        if (showRepo)
                          Flexible(
                            child: _RepoAndBranch(repo: repo, snapshot: snapshot, busy: busy, onNewBranch: newBranch),
                          ),
                      ],
                    ),
                  ),
                  _ToolButton(
                    key: const ValueKey('toolbar-first'),
                    icon: Icons.undo,
                    label: 'Undo',
                    tooltip: state.undoPlan?.label ?? 'Nothing to undo',
                    compact: compact,
                    onPressed: busy || state.undoPlan == null ? null : () => _undo(context, ref),
                  ),
                  _ToolButton(
                    icon: Icons.redo,
                    label: 'Redo',
                    tooltip: state.redoStack.isEmpty ? 'Nothing to redo' : state.redoStack.last.label,
                    compact: compact,
                    onPressed: busy || state.redoStack.isEmpty ? null : () => _redo(context, ref),
                  ),
                  const _Separator(),
                  _ToolButton(
                    icon: Icons.cloud_download_outlined,
                    label: 'Pull',
                    tooltip: 'Pull (fast-forward or merge)',
                    compact: compact,
                    badge: (current?.behind ?? 0) > 0 ? '${current!.behind}' : null,
                    onPressed: busy || !hasRemote ? null : () => run(const PullAction(), 'Pulled'),
                  ),
                  _MenuArrow(
                    tooltip: 'Pull options',
                    enabled: !busy && hasRemote,
                    items: [
                      menuItem('merge', Icons.merge, 'Pull — fast-forward or merge'),
                      menuItem('rebase', Icons.low_priority, 'Pull — rebase local commits on top'),
                    ],
                    onSelected: (v) => v == 'rebase'
                        ? run(const PullAction(rebase: true), 'Pulled (rebase)')
                        : run(const PullAction(), 'Pulled'),
                  ),
                  _ToolButton(
                    icon: Icons.cloud_upload_outlined,
                    label: 'Push',
                    compact: compact,
                    badge: (current?.ahead ?? 0) > 0 ? '${current!.ahead}' : null,
                    onPressed: busy || !hasRemote || snapshot?.currentBranch == null
                        ? null
                        : () => run(const PushAction(), 'Pushed ${snapshot!.currentBranch}'),
                  ),
                  _ToolButton(
                    icon: Icons.sync,
                    label: 'Fetch',
                    tooltip: 'Fetch all remotes',
                    compact: compact,
                    onPressed: busy || !hasRemote ? null : () => run(const FetchAction(), 'Fetched all remotes'),
                  ),
                  const _Separator(),
                  _ToolButton(
                    icon: Icons.call_split,
                    label: 'Branch',
                    tooltip: 'Create branch',
                    compact: compact,
                    onPressed: busy || snapshot?.headSha == null ? null : newBranch,
                  ),
                  _ToolButton(
                    icon: Icons.merge_type,
                    label: 'PR',
                    tooltip: 'Create pull request',
                    compact: compact,
                    onPressed: busy || !hasRemote || snapshot?.currentBranch == null
                        ? null
                        : () => showCreatePullRequestDialog(context, ref, repo),
                  ),
                  _ToolButton(
                    icon: Icons.archive_outlined,
                    label: 'Stash',
                    tooltip: 'Stash changes',
                    compact: compact,
                    onPressed: busy || !(snapshot?.hasChanges ?? false) ? null : stash,
                  ),
                  _ToolButton(
                    icon: Icons.unarchive_outlined,
                    label: 'Pop',
                    tooltip: 'Pop latest stash',
                    compact: compact,
                    badge: (snapshot?.stashes.length ?? 0) > 0 ? '${snapshot!.stashes.length}' : null,
                    onPressed: busy || (snapshot?.stashes.isEmpty ?? true) ? null : () => run(const StashPopAction()),
                  ),
                  const _Separator(),
                  _ToolButton(
                    icon: Icons.refresh,
                    label: 'Refresh',
                    tooltip: 'Refresh (F5)',
                    compact: compact,
                    onPressed:
                        busy ? null : () => ref.read(repoNotifierProvider(repo).notifier).refresh(forceHistory: true),
                  ),
                  _ToolButton(
                    icon: Icons.folder_open_outlined,
                    label: 'Folder',
                    tooltip: 'Open folder',
                    compact: compact,
                    onPressed: () => launchUrl(Uri.file(repo.path)),
                  ),
                  _ToolButton(
                    icon: Icons.terminal,
                    label: 'Terminal',
                    tooltip: 'Open a terminal here',
                    compact: compact,
                    onPressed: () async {
                      final ok = await ref.read(systemLauncherProvider).openTerminal(repo.path);
                      if (!ok && context.mounted) showToast(context, 'No terminal emulator found');
                    },
                  ),
                  _ToolButton(
                    key: const ValueKey('toolbar-last'),
                    icon: Icons.code,
                    label: 'VS Code',
                    tooltip: 'Open the repository in VS Code',
                    compact: compact,
                    onPressed: () async {
                      final ok = await ref.read(systemLauncherProvider).openFolderInEditor(repo.path);
                      if (!ok && context.mounted) {
                        showToast(context, 'VS Code not found (install it and make sure "code" is on your PATH)');
                      }
                    },
                  ),
                  Expanded(
                    child: busy && !compact
                        ? Padding(
                            padding: const EdgeInsets.only(left: 12, right: 12),
                            child: Text(
                              state.busyLabel!,
                              textAlign: TextAlign.end,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
                            ),
                          )
                        : Align(
                            alignment: Alignment.centerRight,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 10),
                              child: _RemoteStatus(repo: repo, compact: compact),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 2,
              child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
            ),
          ],
        ),
      );
    });
  }
}

/// Nombre del repo + rama actual (clic → cambiar de rama).
class _RepoAndBranch extends ConsumerWidget {
  final RepoHandle repo;
  final RepoSnapshot? snapshot;
  final bool busy;
  final VoidCallback onNewBranch;

  const _RepoAndBranch({required this.repo, required this.snapshot, required this.busy, required this.onNewBranch});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final snap = snapshot;
    final branchLabel = snap == null
        ? '…'
        : snap.pendingOperation == PendingOperation.rebase
            ? 'rebasing ${snap.rebase?.branch ?? ''}'.trim()
            : snap.isDetached
                ? 'detached @ ${snap.headSha!.substring(0, 7)}'
                : snap.currentBranch ?? 'no commits yet';
    final locals = snap?.localBranches ?? const <GitRef>[];

    return PopupMenuButton<String>(
      tooltip: 'Switch branch',
      enabled: !busy && snap != null,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 360, maxHeight: 420),
      onSelected: (value) {
        if (value == '__new__') {
          onNewBranch();
        } else {
          runGitAction(context, ref, repo, CheckoutAction(value));
        }
      },
      itemBuilder: (context) => [
        for (final b in locals)
          PopupMenuItem(
            value: b.name,
            enabled: b.name != snap?.currentBranch,
            height: 34,
            child: Row(
              children: [
                Icon(b.name == snap?.currentBranch ? Icons.check : Icons.call_split, size: 16),
                const SizedBox(width: 10),
                Expanded(child: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (b.ahead > 0) Text(' ↑${b.ahead}', style: theme.textTheme.labelSmall),
                if (b.behind > 0) Text(' ↓${b.behind}', style: theme.textTheme.labelSmall),
              ],
            ),
          ),
        const PopupMenuDivider(),
        menuItem('__new__', Icons.add, 'New branch…'),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(p.basename(repo.path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            Row(
              children: [
                Icon(snap?.isDetached ?? false ? Icons.my_location : Icons.call_split,
                    size: 13, color: theme.colorScheme.primary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    branchLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
                Icon(Icons.arrow_drop_down, size: 18, color: theme.colorScheme.primary),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Estado del remoto: "Fetched 2 min ago", comprobando, o error del
/// auto-fetch. Clic = mirar ahora.
class _RemoteStatus extends ConsumerStatefulWidget {
  final RepoHandle repo;
  final bool compact;

  const _RemoteStatus({required this.repo, required this.compact});

  @override
  ConsumerState<_RemoteStatus> createState() => _RemoteStatusState();
}

class _RemoteStatusState extends ConsumerState<_RemoteStatus> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Para que "hace N min" se mantenga al día.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static String ago(Duration d) {
    if (d.inSeconds < 45) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes < 1 ? 1 : d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(repoNotifierProvider(widget.repo));
    final minutes = ref.watch(appSettingsProvider.select((s) => s.autoFetchMinutes));
    if (state.snapshot?.remotes.isEmpty ?? true) return const SizedBox.shrink();

    final faded = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final auto = minutes > 0 ? 'Auto-fetch every $minutes min' : 'Auto-fetch is off (Settings)';
    final (Widget icon, String text, String tooltip) = switch (state) {
      RepoState(autoFetching: true) => (
          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6)),
          'Checking remote…',
          auto,
        ),
      RepoState(:final fetchError?) => (
          Icon(Icons.cloud_off_outlined, size: 15, color: theme.colorScheme.error),
          'Fetch failed',
          '$fetchError\n\nClick to fetch now and see the full error.',
        ),
      RepoState(:final lastFetchAt?) => (
          Icon(Icons.cloud_done_outlined, size: 15, color: theme.colorScheme.onSurfaceVariant),
          'Fetched ${ago(clock.now().difference(lastFetchAt))}',
          '$auto · click to fetch now',
        ),
      _ => (
          Icon(Icons.cloud_queue, size: 15, color: theme.colorScheme.onSurfaceVariant),
          'Not fetched yet',
          '$auto · click to fetch now',
        ),
    };

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: state.autoFetching
            ? null
            : state.fetchError != null
                ? () => runGitAction(context, ref, widget.repo, const FetchAction(), successMessage: 'Fetched')
                : ref.read(repoNotifierProvider(widget.repo).notifier).backgroundFetch,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              if (!widget.compact) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: state.fetchError != null ? faded?.copyWith(color: theme.colorScheme.error) : faded,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 28,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: Theme.of(context).dividerColor,
      );
}

class _MenuArrow extends StatelessWidget {
  final String tooltip;
  final bool enabled;
  final List<PopupMenuEntry<String>> items;
  final ValueChanged<String> onSelected;

  const _MenuArrow({required this.tooltip, required this.enabled, required this.items, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: tooltip,
      enabled: enabled,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 440),
      padding: EdgeInsets.zero,
      onSelected: onSelected,
      itemBuilder: (_) => items,
      child: SizedBox(
        width: 16,
        height: 36,
        child: Icon(Icons.arrow_drop_down,
            size: 18, color: enabled ? Theme.of(context).colorScheme.onSurface : Theme.of(context).disabledColor),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? tooltip;
  final String? badge;
  final bool compact;
  final VoidCallback? onPressed;

  const _ToolButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.compact,
    this.tooltip,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = onPressed == null ? theme.disabledColor : theme.colorScheme.onSurface;
    final iconWidget = Badge(
      isLabelVisible: badge != null,
      label: Text(badge ?? ''),
      child: Icon(icon, size: 21, color: color),
    );
    return Tooltip(
      message: tooltip ?? label,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Container(
          width: compact ? 40 : 56,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: compact
              ? Center(child: iconWidget)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    iconWidget,
                    const SizedBox(height: 3),
                    Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: theme.textTheme.labelSmall?.copyWith(color: color),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
