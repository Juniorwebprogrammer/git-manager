import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/entities/git_action.dart';
import '../../domain/entities/pull_request.dart';
import '../../domain/entities/repo_snapshot.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'interactive_rebase_dialog.dart';
import 'pull_request_dialog.dart';
import 'ui_helpers.dart';

/// Barra lateral: ramas locales, remotas, tags y stashes.
class RefSidebar extends ConsumerStatefulWidget {
  final RepoHandle repo;

  const RefSidebar({super.key, required this.repo});

  @override
  ConsumerState<RefSidebar> createState() => _RefSidebarState();
}

class _RefSidebarState extends ConsumerState<RefSidebar> {
  String _filter = '';
  final _collapsed = <String>{};

  bool _matches(String name) => _filter.isEmpty || name.toLowerCase().contains(_filter.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(repoNotifierProvider(widget.repo).select((s) => s.snapshot));
    if (snapshot == null) return const SizedBox.shrink();

    final locals = snapshot.localBranches.where((r) => _matches(r.name)).toList();
    final remotesByName = <String, List<GitRef>>{};
    for (final r in snapshot.remoteBranches.where((r) => _matches(r.name))) {
      remotesByName.putIfAbsent(r.remoteName!, () => []).add(r);
    }
    final tags = snapshot.tags.where((r) => _matches(r.name)).toList();
    final stashes = snapshot.stashes.where((s) => _matches(s.message)).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.filter_list, size: 18),
              hintText: 'Filter branches',
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 13),
            onChanged: (v) => setState(() => _filter = v),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              _section('LOCAL', Icons.laptop, locals.length, [
                for (final r in locals) _RefTile(repo: widget.repo, gitRef: r, label: r.name),
              ]),
              _section('REMOTE', Icons.cloud_outlined, snapshot.remoteBranches.length, [
                for (final entry in remotesByName.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 6, 8, 2),
                    child: Row(
                      children: [
                        const Icon(Icons.dns_outlined, size: 14),
                        const SizedBox(width: 6),
                        Text(entry.key, style: Theme.of(context).textTheme.labelMedium),
                      ],
                    ),
                  ),
                  for (final r in entry.value)
                    _RefTile(repo: widget.repo, gitRef: r, label: r.nameWithoutRemote, indent: 40),
                ],
              ]),
              if (snapshot.remotes.isNotEmpty) _pullRequests(context),
              _section('TAGS', Icons.sell_outlined, tags.length, [
                for (final r in tags) _RefTile(repo: widget.repo, gitRef: r, label: r.name),
              ]),
              _section('STASHES', Icons.inventory_2_outlined, stashes.length, [
                for (final s in stashes) _StashTile(repo: widget.repo, stash: s),
              ]),
            ],
          ),
        ),
      ],
    );
  }

  /// Sección de Pull Requests de GitHub (se cargan con el token de la cuenta).
  Widget _pullRequests(BuildContext context) {
    final theme = Theme.of(context);
    final pulls = ref.watch(pullRequestsProvider(widget.repo));
    final list = pulls.value ?? const <PullRequest>[];
    final visible = list.where((p) => _matches('#${p.number} ${p.title} ${p.headRef}')).toList();

    Widget small(IconData icon, String tooltip, VoidCallback onPressed) => IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, size: 16),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
        );

    return _section(
      'PULL REQUESTS',
      Icons.merge_type,
      pulls.hasValue ? list.length : null,
      [
        if (pulls.isLoading && !pulls.hasValue)
          const Padding(
            padding: EdgeInsets.all(10),
            child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
          )
        else if (pulls.hasError && !pulls.hasValue)
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 2, 10, 6),
            child: Text(
              pulls.error.toString(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          )
        else if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 2, 10, 6),
            child: Text('No open pull requests',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          )
        else
          for (final pr in visible) _PullRequestTile(repo: widget.repo, pr: pr),
      ],
      actions: [
        small(Icons.refresh, 'Reload pull requests', () => ref.invalidate(pullRequestsProvider(widget.repo))),
        small(Icons.add, 'Create pull request', () => showCreatePullRequestDialog(context, ref, widget.repo)),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _section(String title, IconData icon, int? count, List<Widget> children, {List<Widget> actions = const []}) {
    final theme = Theme.of(context);
    final collapsed = _collapsed.contains(title);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => collapsed ? _collapsed.remove(title) : _collapsed.add(title)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 12, 6),
            child: Row(
              children: [
                Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 18),
                const SizedBox(width: 2),
                Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                    style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.8),
                  ),
                ),
                ...actions,
                if (count != null)
                  Text('$count', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
        if (!collapsed) ...children,
      ],
    );
  }
}

class _RefTile extends ConsumerWidget {
  final RepoHandle repo;
  final GitRef gitRef;
  final String label;
  final double indent;

  const _RefTile({required this.repo, required this.gitRef, required this.label, this.indent = 30});

  GitAction? _checkoutAction() => switch (gitRef.kind) {
    RefKind.local => CheckoutAction(gitRef.name),
    RefKind.remote => CheckoutRemoteAction(gitRef.name, gitRef.nameWithoutRemote),
    RefKind.tag => CheckoutDetachedAction(gitRef.name),
  };

  Future<void> _menu(BuildContext context, WidgetRef ref, Offset position) async {
    final snapshot = ref.read(repoNotifierProvider(repo)).snapshot;
    final current = snapshot?.currentBranch;
    final isCurrent = gitRef.kind == RefKind.local && gitRef.name == current;
    final error = Theme.of(context).colorScheme.error;

    final value = await showContextMenu<String>(context, position, [
      if (!isCurrent) menuItem('checkout', Icons.login, 'Checkout ${gitRef.name}'),
      if (gitRef.kind != RefKind.tag && !isCurrent && current != null) ...[
        menuItem('merge', Icons.merge, 'Merge ${gitRef.name} into $current'),
        menuItem('mergenoff', Icons.call_merge, 'Merge ${gitRef.name} into $current (create merge commit)'),
        menuItem('squash', Icons.compress, 'Squash ${gitRef.name} into $current…'),
      ],
      if (!isCurrent && current != null) ...[
        menuItem('rebasecurrent', Icons.low_priority, 'Rebase $current onto ${gitRef.name}'),
        menuItem('irebase', Icons.reorder, 'Interactive rebase $current onto ${gitRef.name}…'),
      ],
      if (gitRef.kind == RefKind.local && !isCurrent && current != null)
        menuItem('rebasethis', Icons.low_priority, 'Rebase ${gitRef.name} onto $current'),
      menuItem('branch', Icons.add, 'Create branch from here…'),
      if (gitRef.kind == RefKind.local && (snapshot?.remotes.isNotEmpty ?? false))
        menuItem('pr', Icons.merge_type, 'Create pull request from ${gitRef.name}…'),
      if (gitRef.kind == RefKind.local) ...[
        menuItem('push', Icons.cloud_upload_outlined, 'Push ${gitRef.name}'),
        menuItem('forcepush', Icons.cloud_upload, 'Force push ${gitRef.name} (with lease)', color: error),
        if (!isCurrent) menuItem('delete', Icons.delete_outline, 'Delete ${gitRef.name}', color: error),
      ],
      if (gitRef.kind == RefKind.remote)
        menuItem('deleteremote', Icons.delete_outline, 'Delete ${gitRef.name} from remote', color: error),
      if (gitRef.kind == RefKind.tag) ...[
        menuItem('pushtag', Icons.cloud_upload_outlined, 'Push tag ${gitRef.name}'),
        menuItem('deletetag', Icons.delete_outline, 'Delete tag ${gitRef.name}', color: error),
      ],
      const PopupMenuDivider(),
      menuItem('copy', Icons.copy, 'Copy name'),
    ]);
    if (value == null || !context.mounted) return;

    switch (value) {
      case 'checkout':
        await runGitAction(context, ref, repo, _checkoutAction()!);
      case 'merge':
        await runGitAction(context, ref, repo, MergeAction(gitRef.name), successMessage: 'Merged ${gitRef.name}');
      case 'mergenoff':
        await runGitAction(context, ref, repo, MergeAction(gitRef.name, mode: MergeMode.noFastForward),
            successMessage: 'Merged ${gitRef.name}');
      case 'squash':
        await squashMergeInto(context, ref, repo, gitRef.name, current!);
      case 'irebase':
        await showInteractiveRebaseDialog(context, ref, repo,
            base: gitRef.name, baseLabel: gitRef.name, branchLabel: current!);
      case 'pr':
        await showCreatePullRequestDialog(context, ref, repo, head: gitRef.name);
      case 'rebasecurrent':
        await confirmAndRebase(context, ref, repo, onto: gitRef.name, branchLabel: current!);
      case 'rebasethis':
        await confirmAndRebase(context, ref, repo, onto: current!, branch: gitRef.name, branchLabel: gitRef.name);
      case 'branch':
        final name = await promptDialog(
          context,
          title: 'Create branch',
          label: 'Branch name',
          helper: 'Starts at ${gitRef.name}',
          confirmLabel: 'Create',
        );
        if (name != null && context.mounted) {
          await runGitAction(context, ref, repo, CreateBranchAction(name, startPoint: gitRef.name));
        }
      case 'push':
        await runGitAction(
          context,
          ref,
          repo,
          PushAction(branch: gitRef.name),
          successMessage: 'Pushed ${gitRef.name}',
        );
      case 'forcepush':
        if (await confirmDialog(
              context,
              title: 'Force push',
              message:
                  'Overwrite the remote "${gitRef.name}" with your local branch? '
                  'Commits only on the remote will be lost (unless someone else pushed since your last fetch).',
              confirmLabel: 'Force push',
              destructive: true,
            ) &&
            context.mounted) {
          await runGitAction(
            context,
            ref,
            repo,
            PushAction(branch: gitRef.name, force: true),
            successMessage: 'Force pushed ${gitRef.name}',
          );
        }
      case 'delete':
        if (await confirmDialog(
              context,
              title: 'Delete branch',
              message: 'Delete the local branch "${gitRef.name}"?',
              confirmLabel: 'Delete',
              destructive: true,
            ) &&
            context.mounted) {
          final failure = await ref.read(repoNotifierProvider(repo).notifier).run(DeleteBranchAction(gitRef.name));
          if (failure == null || !context.mounted) return;
          if (!failure.message.contains('not fully merged')) {
            await showGitError(context, failure);
            return;
          }
          if (await confirmDialog(
                context,
                title: 'Branch not fully merged',
                message: '"${gitRef.name}" has commits that are not merged anywhere else. Delete it anyway?',
                confirmLabel: 'Force delete',
                destructive: true,
              ) &&
              context.mounted) {
            await runGitAction(context, ref, repo, DeleteBranchAction(gitRef.name, force: true));
          }
        }
      case 'deleteremote':
        if (await confirmDialog(
              context,
              title: 'Delete remote branch',
              message: 'Delete "${gitRef.nameWithoutRemote}" from ${gitRef.remoteName}? This affects everyone.',
              confirmLabel: 'Delete',
              destructive: true,
            ) &&
            context.mounted) {
          await runGitAction(
            context,
            ref,
            repo,
            DeleteRemoteBranchAction(gitRef.remoteName!, gitRef.nameWithoutRemote),
          );
        }
      case 'pushtag':
        await runGitAction(context, ref, repo, PushTagAction(gitRef.name), successMessage: 'Pushed tag ${gitRef.name}');
      case 'deletetag':
        await runGitAction(context, ref, repo, DeleteTagAction(gitRef.name));
      case 'copy':
        await Clipboard.setData(ClipboardData(text: gitRef.name));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final currentBranch = ref.watch(repoNotifierProvider(repo).select((s) => s.snapshot?.currentBranch));
    final isCurrent = gitRef.kind == RefKind.local && gitRef.name == currentBranch;

    final Widget base = InkWell(
      onTap: () => ref.read(repoNotifierProvider(repo).notifier).selectCommit(gitRef.sha),
      onDoubleTap: isCurrent ? null : () => runGitAction(context, ref, repo, _checkoutAction()!),
      onSecondaryTapDown: (d) => _menu(context, ref, d.globalPosition),
      child: Container(
        height: 28,
        padding: EdgeInsets.only(left: indent, right: 10),
        color: isCurrent ? theme.colorScheme.primary.withValues(alpha: 0.12) : null,
        child: Row(
          children: [
            if (isCurrent)
              Icon(Icons.check, size: 15, color: theme.colorScheme.primary)
            else
              Icon(
                gitRef.kind == RefKind.tag ? Icons.sell_outlined : Icons.call_split,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: gitRef.upstream == null ? gitRef.name : '${gitRef.name} → ${gitRef.upstream}',
                waitDuration: const Duration(milliseconds: 600),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: isCurrent ? FontWeight.w700 : null),
                ),
              ),
            ),
            if (gitRef.upstreamGone)
              Tooltip(
                message: 'Upstream deleted',
                child: Icon(Icons.link_off, size: 14, color: theme.colorScheme.error),
              ),
            if (gitRef.ahead > 0) _CountBadge('↑${gitRef.ahead}'),
            if (gitRef.behind > 0) _CountBadge('↓${gitRef.behind}'),
          ],
        ),
      ),
    );

    // Arrastrar una rama sobre otra (local) → merge / rebase.
    final Widget draggable = gitRef.kind == RefKind.tag
        ? base
        : Draggable<GitRef>(
            data: gitRef,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: _DragChip(label: gitRef.name),
            childWhenDragging: Opacity(opacity: 0.4, child: base),
            child: base,
          );
    if (gitRef.kind != RefKind.local) return draggable;
    return DragTarget<GitRef>(
      onWillAcceptWithDetails: (d) => d.data.fullName != gitRef.fullName,
      onAcceptWithDetails: (d) => _onDrop(context, ref, d.data, d.offset),
      builder: (context, candidates, _) => candidates.isEmpty
          ? draggable
          : DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                border: Border.all(color: theme.colorScheme.primary, width: 1.5),
                borderRadius: BorderRadius.circular(4),
              ),
              child: draggable,
            ),
    );
  }

  Future<void> _onDrop(BuildContext context, WidgetRef ref, GitRef source, Offset position) async {
    final current = ref.read(repoNotifierProvider(repo)).snapshot?.currentBranch;
    final target = gitRef.name;
    final src = source.name;
    final value = await showContextMenu<String>(context, position, [
      menuItem(
        'merge',
        Icons.merge,
        target == current ? 'Merge $src into $target' : 'Checkout $target and merge $src into it',
      ),
      menuItem(
        'mergenoff',
        Icons.call_merge,
        target == current
            ? 'Merge $src into $target (create merge commit)'
            : 'Checkout $target and merge $src (create merge commit)',
      ),
      menuItem('squash', Icons.compress, target == current ? 'Squash $src into $target…' : 'Checkout $target and squash $src…'),
      if (source.kind == RefKind.local) menuItem('rebase', Icons.low_priority, 'Rebase $src onto $target'),
      menuItem('rebasetarget', Icons.low_priority, 'Rebase $target onto $src'),
    ]);
    if (value == null || !context.mounted) return;
    if (value.startsWith('merge') || value == 'squash') {
      if (target != current && !await runGitAction(context, ref, repo, CheckoutAction(target))) return;
      if (!context.mounted) return;
    }
    switch (value) {
      case 'merge':
        await runGitAction(context, ref, repo, MergeAction(src), successMessage: 'Merged $src into $target');
      case 'mergenoff':
        await runGitAction(context, ref, repo, MergeAction(src, mode: MergeMode.noFastForward),
            successMessage: 'Merged $src into $target');
      case 'squash':
        await squashMergeInto(context, ref, repo, src, target);
      case 'rebase':
        await confirmAndRebase(context, ref, repo, onto: target, branch: src, branchLabel: src);
      case 'rebasetarget':
        await confirmAndRebase(context, ref, repo, onto: src, branch: target, branchLabel: target);
    }
  }
}

class _DragChip extends StatelessWidget {
  final String label;

  const _DragChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primary,
      elevation: 6,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.call_split, size: 14, color: theme.colorScheme.onPrimary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(color: theme.colorScheme.onPrimary, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  final String text;

  const _CountBadge(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
    );
  }
}

class _StashTile extends ConsumerWidget {
  final RepoHandle repo;
  final GitStash stash;

  const _StashTile({required this.repo, required this.stash});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return InkWell(
      onSecondaryTapDown: (d) async {
        final value = await showContextMenu<String>(context, d.globalPosition, [
          menuItem('pop', Icons.unarchive_outlined, 'Pop stash'),
          menuItem('apply', Icons.content_paste, 'Apply stash'),
          menuItem('drop', Icons.delete_outline, 'Drop stash', color: theme.colorScheme.error),
        ]);
        if (!context.mounted) return;
        switch (value) {
          case 'pop':
            await runGitAction(context, ref, repo, StashPopAction(stash.ref));
          case 'apply':
            await runGitAction(context, ref, repo, StashApplyAction(stash.ref));
          case 'drop':
            if (await confirmDialog(
                  context,
                  title: 'Drop stash',
                  message: 'Delete "${stash.message}"?',
                  confirmLabel: 'Drop',
                  destructive: true,
                ) &&
                context.mounted) {
              await runGitAction(context, ref, repo, StashDropAction(stash.ref));
            }
        }
      },
      onDoubleTap: () => runGitAction(context, ref, repo, StashApplyAction(stash.ref)),
      child: Container(
        height: 28,
        padding: const EdgeInsets.only(left: 30, right: 10),
        child: Row(
          children: [
            Icon(Icons.inventory_2_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: '${stash.ref}\nRight-click for actions',
                child: Text(
                  stash.message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PullRequestTile extends ConsumerWidget {
  final RepoHandle repo;
  final PullRequest pr;

  const _PullRequestTile({required this.repo, required this.pr});

  Future<void> _checkout(BuildContext context, WidgetRef ref) => runGitAction(
        context,
        ref,
        repo,
        CheckoutPullRequestAction(number: pr.number, headRef: pr.headRef, sameRepo: !pr.isFromFork),
        successMessage: 'Checked out PR #${pr.number}',
      );

  Future<void> _menu(BuildContext context, WidgetRef ref, Offset position) async {
    final value = await showContextMenu<String>(context, position, [
      menuItem('checkout', Icons.login, 'Checkout PR #${pr.number}'),
      menuItem('open', Icons.open_in_new, 'Open on GitHub'),
      menuItem('copy', Icons.link, 'Copy link'),
    ]);
    if (value == null || !context.mounted) return;
    switch (value) {
      case 'checkout':
        await _checkout(context, ref);
      case 'open':
        await launchUrl(Uri.parse(pr.url));
      case 'copy':
        await Clipboard.setData(ClipboardData(text: pr.url));
        if (context.mounted) showToast(context, 'Link copied');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final (ciIcon, ciColor, ciText) = switch (pr.ci) {
      CiStatus.success => (Icons.check_circle, const Color(0xFF3FB950), 'Checks passed'),
      CiStatus.failure => (Icons.cancel, const Color(0xFFF85149), 'Checks failed'),
      CiStatus.pending => (Icons.pending, const Color(0xFFD29922), 'Checks running'),
      CiStatus.none => (Icons.merge_type, theme.colorScheme.onSurfaceVariant, 'No checks'),
    };

    return InkWell(
      onTap: () => _menu(context, ref, (context.findRenderObject()! as RenderBox).localToGlobal(const Offset(40, 26))),
      onDoubleTap: () => _checkout(context, ref),
      onSecondaryTapDown: (d) => _menu(context, ref, d.globalPosition),
      child: Tooltip(
        message: '#${pr.number} ${pr.title}\n${pr.headRef} → ${pr.baseRef} · by ${pr.author}'
            '${pr.draft ? ' · draft' : ''}${pr.isFromFork ? ' · from ${pr.headRepoFullName}' : ''}\n$ciText',
        waitDuration: const Duration(milliseconds: 600),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(30, 4, 10, 4),
          child: Row(
            children: [
              Icon(ciIcon, size: 15, color: ciColor),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: '#${pr.number} ',
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                        ),
                        TextSpan(text: pr.title),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: pr.draft ? theme.colorScheme.onSurfaceVariant : null,
                      ),
                    ),
                    Text(
                      '${pr.headRef} → ${pr.baseRef}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (pr.draft)
                Container(
                  margin: const EdgeInsets.only(left: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outline),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('draft', style: theme.textTheme.labelSmall),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
