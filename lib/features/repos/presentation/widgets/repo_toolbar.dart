import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../domain/entities/git_action.dart';
import '../../domain/entities/repo_snapshot.dart';
import '../../domain/repositories/git_repository.dart';
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
      final compact = width < 1060; // solo iconos
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
                        : const SizedBox.shrink(),
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
