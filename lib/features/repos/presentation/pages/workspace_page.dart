import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../accounts/presentation/pages/account_detail_page.dart';
import '../../../accounts/presentation/state/accounts_notifier.dart';
import '../../../accounts/presentation/widgets/account_avatar.dart';
import '../state/repo_notifier.dart';
import '../state/workspace_notifier.dart';
import '../widgets/command_palette.dart';
import '../widgets/open_repo_dialog.dart';
import '../widgets/settings_dialog.dart';
import '../widgets/ui_helpers.dart';
import 'repo_view.dart';

/// Pantalla principal de una cuenta: sus proyectos en pestañas.
class WorkspacePage extends ConsumerWidget {
  final String accountId;

  const WorkspacePage({super.key, required this.accountId});

  Future<void> _openRepo(BuildContext context, WidgetRef ref) async {
    final path = await showOpenRepoDialog(context, accountId);
    if (path == null || !context.mounted) return;
    final failure = await ref.read(workspaceNotifierProvider(accountId).notifier).open(path);
    if (failure != null && context.mounted) await showGitError(context, failure);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(
      accountsNotifierProvider.select((s) => s.accounts.where((a) => a.id == accountId).firstOrNull),
    );
    final workspace = ref.watch(workspaceNotifierProvider(accountId));
    final notifier = ref.read(workspaceNotifierProvider(accountId).notifier);
    final theme = Theme.of(context);

    if (account == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This account no longer exists.')),
      );
    }

    Future<void> palette() => showCommandPalette(
          context,
          buildPaletteCommands(
            context,
            ref,
            repo: workspace.activePath == null ? null : (accountId: accountId, path: workspace.activePath!),
            tabs: workspace.tabs,
            switchTab: notifier.activate,
            openRepository: () => _openRepo(context, ref),
          ),
        );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true): palette,
        const SingleActivator(LogicalKeyboardKey.keyT, control: true): () => _openRepo(context, ref),
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () {
          if (workspace.tabs.isNotEmpty) notifier.close(workspace.activeIndex);
        },
        const SingleActivator(LogicalKeyboardKey.tab, control: true): () {
          if (workspace.tabs.length > 1) notifier.activate((workspace.activeIndex + 1) % workspace.tabs.length);
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              // Barra superior: cuenta + pestañas de proyectos.
              Container(
                height: 46,
                color: theme.colorScheme.surfaceContainerLowest,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back to accounts',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back),
                    ),
                    Tooltip(
                      message: '${account.nameOrLogin} (@${account.login})\nCommits and pushes use this account',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => Navigator.of(
                          context,
                        ).push(MaterialPageRoute(builder: (_) => AccountDetailPage(accountId: accountId))),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          child: Row(
                            children: [
                              AccountAvatar(account: account, radius: 13),
                              const SizedBox(width: 8),
                              Text('@${account.login}', style: theme.textTheme.labelLarge),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(width: 1, height: 24, color: theme.dividerColor),
                    Expanded(
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(left: 6, top: 6),
                        children: [
                          for (var i = 0; i < workspace.tabs.length; i++)
                            _RepoTab(
                              accountId: accountId,
                              path: workspace.tabs[i],
                              active: i == workspace.activeIndex,
                              onTap: () => notifier.activate(i),
                              onClose: () => notifier.close(i),
                            ),
                          IconButton(
                            tooltip: 'Open or clone a repository (Ctrl+T)',
                            onPressed: () => _openRepo(context, ref),
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Command palette (Ctrl+Shift+P)',
                      onPressed: palette,
                      icon: const Icon(Icons.search),
                    ),
                    IconButton(
                      tooltip: 'Settings',
                      onPressed: () => showSettingsDialog(context),
                      icon: const Icon(Icons.settings_outlined),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
              Expanded(
                child: workspace.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : workspace.tabs.isEmpty
                    ? _EmptyWorkspace(onOpen: () => _openRepo(context, ref))
                    : IndexedStack(
                        index: workspace.activeIndex,
                        children: [
                          for (var i = 0; i < workspace.tabs.length; i++)
                            RepoView(
                              key: ValueKey(workspace.tabs[i]),
                              repo: (accountId: accountId, path: workspace.tabs[i]),
                              active: i == workspace.activeIndex,
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RepoTab extends ConsumerWidget {
  final String accountId;
  final String path;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _RepoTab({
    required this.accountId,
    required this.path,
    required this.active,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final repo = (accountId: accountId, path: path);
    final branch = ref.watch(repoNotifierProvider(repo).select((s) => s.snapshot?.currentBranch));
    final dirty = ref.watch(repoNotifierProvider(repo).select((s) => s.snapshot?.hasChanges ?? false));

    return Tooltip(
      message: path,
      waitDuration: const Duration(milliseconds: 700),
      child: Padding(
        padding: const EdgeInsets.only(right: 2),
        child: Material(
          color: active ? theme.colorScheme.surfaceContainer : Colors.transparent,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: GestureDetector(
              onTertiaryTapUp: (_) => onClose(),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 260),
                padding: const EdgeInsets.only(left: 12, right: 2),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: active ? theme.colorScheme.primary : Colors.transparent, width: 2),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.source_outlined, size: 16, color: active ? theme.colorScheme.primary : null),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: p.basename(path),
                              style: TextStyle(fontWeight: active ? FontWeight.w600 : FontWeight.normal),
                            ),
                            if (branch != null)
                              TextSpan(
                                text: '  $branch',
                                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (dirty)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Icon(Icons.circle, size: 7, color: theme.colorScheme.tertiary),
                      ),
                    IconButton(
                      tooltip: 'Close tab (Ctrl+W)',
                      onPressed: onClose,
                      icon: const Icon(Icons.close, size: 15),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyWorkspace extends StatelessWidget {
  final VoidCallback onOpen;

  const _EmptyWorkspace({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_tree_outlined, size: 72, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('No projects open', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Open a local repository or clone one of your GitHub\nrepositories. Each project gets its own tab.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.add),
            label: const Text('Open or clone a repository'),
          ),
        ],
      ),
    );
  }
}
