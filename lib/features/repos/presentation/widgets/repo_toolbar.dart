import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../domain/entities/git_action.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'ui_helpers.dart';

/// Barra de acciones principal: pull, push, fetch, rama, stash…
class RepoToolbar extends ConsumerWidget {
  final RepoHandle repo;

  const RepoToolbar({super.key, required this.repo});

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

    return Container(
      height: 60,
      color: theme.colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // Repo + rama actual.
          SizedBox(
            width: 220,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.basename(repo.path),
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis),
                Row(
                  children: [
                    Icon(snapshot?.isDetached ?? false ? Icons.my_location : Icons.call_split,
                        size: 13, color: theme.colorScheme.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        snapshot == null
                            ? '…'
                            : snapshot.isDetached
                                ? 'detached @ ${snapshot.headSha!.substring(0, 7)}'
                                : snapshot.currentBranch ?? 'no commits yet',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Spacer(),
          _ToolButton(
            icon: Icons.cloud_download_outlined,
            label: 'Pull',
            badge: (current?.behind ?? 0) > 0 ? '${current!.behind}' : null,
            onPressed: busy || !hasRemote ? null : () => run(const PullAction(), 'Pulled'),
          ),
          _ToolButton(
            icon: Icons.cloud_upload_outlined,
            label: 'Push',
            badge: (current?.ahead ?? 0) > 0 ? '${current!.ahead}' : null,
            onPressed: busy || !hasRemote || snapshot?.currentBranch == null
                ? null
                : () => run(const PushAction(), 'Pushed ${snapshot!.currentBranch}'),
          ),
          _ToolButton(
            icon: Icons.sync,
            label: 'Fetch',
            onPressed: busy || !hasRemote ? null : () => run(const FetchAction(), 'Fetched all remotes'),
          ),
          const _Separator(),
          _ToolButton(icon: Icons.call_split, label: 'Branch', onPressed: busy || snapshot?.headSha == null ? null : newBranch),
          _ToolButton(
            icon: Icons.archive_outlined,
            label: 'Stash',
            onPressed: busy || !(snapshot?.hasChanges ?? false) ? null : stash,
          ),
          _ToolButton(
            icon: Icons.unarchive_outlined,
            label: 'Pop',
            badge: (snapshot?.stashes.length ?? 0) > 0 ? '${snapshot!.stashes.length}' : null,
            onPressed: busy || (snapshot?.stashes.isEmpty ?? true) ? null : () => run(const StashPopAction()),
          ),
          const _Separator(),
          _ToolButton(
            icon: Icons.refresh,
            label: 'Refresh',
            onPressed: busy ? null : () => ref.read(repoNotifierProvider(repo).notifier).refresh(forceHistory: true),
          ),
          _ToolButton(
            icon: Icons.folder_open_outlined,
            label: 'Folder',
            onPressed: () => launchUrl(Uri.file(repo.path)),
          ),
          const Spacer(),
          SizedBox(
            width: 160,
            child: busy
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 8),
                      Flexible(child: Text(state.busyLabel!, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis)),
                    ],
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 32,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        color: Theme.of(context).dividerColor,
      );
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? badge;
  final VoidCallback? onPressed;

  const _ToolButton({required this.icon, required this.label, required this.onPressed, this.badge});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = onPressed == null ? theme.disabledColor : theme.colorScheme.onSurface;
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 800),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Container(
          width: 58,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Badge(
                isLabelVisible: badge != null,
                label: Text(badge ?? ''),
                child: Icon(icon, size: 22, color: color),
              ),
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
