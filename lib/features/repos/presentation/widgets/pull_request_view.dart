import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/error/result.dart';
import '../../data/parsers/git_parsers.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/entities/pull_request.dart';
import '../../domain/entities/pull_request_detail.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'diff_viewer.dart';
import 'ui_helpers.dart';

const _green = Color(0xFF3FB950);
const _red = Color(0xFFF85149);
const _purple = Color(0xFFA371F7);
const _amber = Color(0xFFD29922);

/// Una Pull Request de GitHub dentro de la app: conversación, commits,
/// ficheros, checks y acciones (merge, review, comentar, cerrar…).
class PullRequestView extends ConsumerWidget {
  final RepoHandle repo;
  final int number;

  const PullRequestView({super.key, required this.repo, required this.number});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (repo: repo, number: number);
    final bundle = ref.watch(pullRequestBundleProvider(key));
    final notifier = ref.read(repoNotifierProvider(repo).notifier);
    final theme = Theme.of(context);

    if (!bundle.hasValue) {
      return Column(
        children: [
          _TopBar(
            title: '#$number',
            onRefresh: () => ref.invalidate(pullRequestBundleProvider(key)),
            onClose: notifier.closePullRequest,
          ),
          Expanded(
            child: bundle.hasError
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: SelectableText(
                        bundle.error.toString(),
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
        ],
      );
    }

    final data = bundle.requireValue;
    return LayoutBuilder(
      builder: (context, constraints) => DefaultTabController(
        length: 4,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // En ventanas bajas la cabecera no se come las pestañas: como
            // mucho el 40 % del alto, con scroll propio.
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.4),
              child: SingleChildScrollView(
                child: _Header(repo: repo, bundle: data, refreshing: bundle.isLoading),
              ),
            ),
            Builder(
              builder: (context) {
                // Estrecho: solo icono + número (con tooltip), para que se vean todas.
                final compact = constraints.maxWidth < 620;
                Widget tab(String label, IconData icon, int count, {Widget? leading}) => Tooltip(
                  message: label,
                  child: Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        leading ?? Icon(icon, size: 16),
                        const SizedBox(width: 6),
                        Text(compact ? '$count' : '$label ($count)'),
                      ],
                    ),
                  ),
                );
                return TabBar(
                  isScrollable: !compact,
                  tabAlignment: compact ? TabAlignment.fill : TabAlignment.start,
                  tabs: [
                    tab('Conversation', Icons.forum_outlined, data.timeline.length),
                    tab('Commits', Icons.commit, data.commits.length),
                    tab('Files changed', Icons.difference_outlined, data.files.length),
                    tab('Checks', Icons.checklist, data.checks.length, leading: _CiIcon(data.ci, size: 15)),
                  ],
                );
              },
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                children: [
                  _ConversationTab(repo: repo, bundle: data),
                  _CommitsTab(repo: repo, commits: data.commits),
                  _FilesTab(files: data.files),
                  _ChecksTab(checks: data.checks),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ejecuta una operación sobre la PR y refresca. true si fue bien.
Future<bool> _runOp(
  BuildContext context,
  WidgetRef ref,
  RepoHandle repo,
  int number,
  PullRequestOp op, {
  required String success,
}) async {
  final result = await ref.read(gitRepositoryProvider).pullRequestAction(repo, number, op);
  if (!context.mounted) return false;
  switch (result) {
    case Failure(:final failure):
      await showGitError(context, failure);
      return false;
    case Success():
      ref.invalidate(pullRequestBundleProvider((repo: repo, number: number)));
      ref.invalidate(pullRequestsProvider(repo));
      showToast(context, success);
      return true;
  }
}

class _TopBar extends StatelessWidget {
  final String title;
  final VoidCallback onRefresh;
  final VoidCallback onClose;
  final List<Widget> extra;

  const _TopBar({required this.title, required this.onRefresh, required this.onClose, this.extra = const []});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          Icon(Icons.merge_type, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
          ),
          ...extra,
          IconButton(tooltip: 'Reload', onPressed: onRefresh, icon: const Icon(Icons.refresh, size: 20)),
          IconButton(tooltip: 'Close pull request (Esc)', onPressed: onClose, icon: const Icon(Icons.close)),
        ],
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  final PullRequestState state;

  const _StateChip(this.state);

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (state) {
      PullRequestState.open => ('Open', _green, Icons.merge_type),
      PullRequestState.draft => ('Draft', const Color(0xFF8D96A0), Icons.edit_outlined),
      PullRequestState.merged => ('Merged', _purple, Icons.merge),
      PullRequestState.closed => ('Closed', _red, Icons.do_not_disturb_on_outlined),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _CiIcon extends StatelessWidget {
  final CiStatus status;
  final double size;

  const _CiIcon(this.status, {this.size = 16});

  @override
  Widget build(BuildContext context) => switch (status) {
    CiStatus.success => Icon(Icons.check_circle, size: size, color: _green),
    CiStatus.failure => Icon(Icons.cancel, size: size, color: _red),
    CiStatus.pending => Icon(Icons.pending, size: size, color: _amber),
    CiStatus.none => Icon(Icons.remove_circle_outline, size: size, color: Theme.of(context).colorScheme.outline),
  };
}

class _Header extends ConsumerWidget {
  final RepoHandle repo;
  final PullRequestBundle bundle;
  final bool refreshing;

  const _Header({required this.repo, required this.bundle, required this.refreshing});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final pr = bundle.detail;
    final notifier = ref.read(repoNotifierProvider(repo).notifier);
    final key = (repo: repo, number: pr.number);
    final merge = pr.mergeability;
    final faded = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    final verb = switch (pr.state) {
      PullRequestState.merged => 'merged',
      PullRequestState.closed => 'wanted to merge',
      _ => 'wants to merge',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TopBar(
          title: '#${pr.number}  ${pr.title}',
          onRefresh: () => ref.invalidate(pullRequestBundleProvider(key)),
          onClose: notifier.closePullRequest,
          extra: [
            if (refreshing)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            IconButton(
              tooltip: 'Open on GitHub',
              onPressed: () => launchUrl(Uri.parse(pr.url)),
              icon: const Icon(Icons.open_in_new, size: 20),
            ),
          ],
        ),
        LayoutBuilder(
          builder: (context, c) {
            final compact = c.maxWidth < 620;
            // Botón secundario: con texto o, si no cabe, icono con tooltip.
            Widget secondary(String label, IconData icon, VoidCallback onPressed) => compact
                ? IconButton.outlined(tooltip: label, onPressed: onPressed, icon: Icon(icon, size: 18))
                : OutlinedButton.icon(onPressed: onPressed, icon: Icon(icon, size: 16), label: Text(label));

            final actions = Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                secondary(
                  'Checkout',
                  Icons.login,
                  () => runGitAction(
                    context,
                    ref,
                    repo,
                    CheckoutPullRequestAction(number: pr.number, headRef: pr.headRef, sameRepo: !pr.isFromFork),
                    successMessage: 'Checked out PR #${pr.number}',
                  ),
                ),
                if (pr.state != PullRequestState.merged) ...[
                  secondary('Edit', Icons.edit_outlined, () => _edit(context, ref, pr)),
                  secondary(
                    pr.isOpen ? 'Close' : 'Reopen',
                    pr.isOpen ? Icons.do_not_disturb_on_outlined : Icons.restart_alt,
                    () => _toggleOpen(context, ref, pr),
                  ),
                ],
                if (pr.isOpen) ...[
                  FilledButton.tonalIcon(
                    onPressed: () => _review(context, ref, pr),
                    icon: const Icon(Icons.rate_review_outlined, size: 16),
                    label: const Text('Review'),
                  ),
                  Tooltip(
                    message: merge.canMerge ? 'Merge this pull request on GitHub' : merge.text,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: _green, foregroundColor: Colors.white),
                      onPressed: merge.canMerge ? () => _merge(context, ref, pr) : null,
                      icon: const Icon(Icons.merge, size: 16),
                      label: const Text('Merge'),
                    ),
                  ),
                ],
              ],
            );

            return Container(
              color: theme.colorScheme.surfaceContainerLow,
              padding: const EdgeInsets.fromLTRB(14, 0, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Acciones primero: siempre visibles aunque la cabecera haga scroll.
                  actions,
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _StateChip(pr.state),
                      Text.rich(
                        TextSpan(
                          style: faded,
                          children: [
                            TextSpan(
                              text: pr.author,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            TextSpan(text: ' $verb ${pr.commitCount} commit${pr.commitCount == 1 ? '' : 's'} into '),
                            TextSpan(text: pr.baseRef, style: monoStyle(context, size: 12)),
                            const TextSpan(text: ' from '),
                            TextSpan(
                              text: pr.isFromFork ? '${pr.headRepoFullName}:${pr.headRef}' : pr.headRef,
                              style: monoStyle(context, size: 12),
                            ),
                          ],
                        ),
                      ),
                      Text('+${pr.additions}', style: faded?.copyWith(color: _green)),
                      Text('−${pr.deletions}', style: faded?.copyWith(color: _red)),
                    ],
                  ),
                  if (pr.isOpen) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          merge.canMerge ? Icons.check_circle_outline : Icons.error_outline,
                          size: 16,
                          color: merge.canMerge ? _green : _amber,
                        ),
                        const SizedBox(width: 6),
                        Expanded(child: Text(merge.text, style: theme.textTheme.bodySmall)),
                      ],
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _toggleOpen(BuildContext context, WidgetRef ref, PullRequestDetail pr) async {
    final closing = pr.isOpen;
    if (closing &&
        !await confirmDialog(
          context,
          title: 'Close pull request #${pr.number}',
          message: 'Close "${pr.title}" without merging? You can reopen it later.',
          confirmLabel: 'Close',
          destructive: true,
        )) {
      return;
    }
    if (!context.mounted) return;
    await _runOp(
      context,
      ref,
      repo,
      pr.number,
      SetPullRequestOpen(!closing),
      success: closing ? 'Pull request closed' : 'Pull request reopened',
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, PullRequestDetail pr) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _EditDialog(title: pr.title, body: pr.body),
    );
    if (result == null || !context.mounted) return;
    await _runOp(context, ref, repo, pr.number, EditPullRequest(result.$1, result.$2), success: 'Pull request updated');
  }

  Future<void> _review(BuildContext context, WidgetRef ref, PullRequestDetail pr) async {
    final review = await showDialog<ReviewPullRequest>(context: context, builder: (_) => const _ReviewDialog());
    if (review == null || !context.mounted) return;
    await _runOp(
      context,
      ref,
      repo,
      pr.number,
      review,
      success: switch (review.event) {
        ReviewEvent.approve => 'Approved',
        ReviewEvent.requestChanges => 'Changes requested',
        ReviewEvent.comment => 'Review submitted',
      },
    );
  }

  Future<void> _merge(BuildContext context, WidgetRef ref, PullRequestDetail pr) async {
    final op = await showDialog<MergePullRequest>(
      context: context,
      builder: (_) => _MergeDialog(pr: pr),
    );
    if (op == null || !context.mounted) return;
    final ok = await _runOp(context, ref, repo, pr.number, op, success: 'Pull request #${pr.number} merged');
    // Traer el resultado del merge a las ramas remotas locales.
    if (ok && context.mounted) await runGitAction(context, ref, repo, const FetchAction());
  }
}

// ------------------------------------------------------------- pestañas

class _ConversationTab extends ConsumerStatefulWidget {
  final RepoHandle repo;
  final PullRequestBundle bundle;

  const _ConversationTab({required this.repo, required this.bundle});

  @override
  ConsumerState<_ConversationTab> createState() => _ConversationTabState();
}

class _ConversationTabState extends ConsumerState<_ConversationTab> {
  final _comment = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _comment.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    final ok = await _runOp(
      context,
      ref,
      widget.repo,
      widget.bundle.detail.number,
      CommentOnPullRequest(text),
      success: 'Comment posted',
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) _comment.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pr = widget.bundle.detail;
    return Column(
      children: [
        Expanded(
          child: SelectionArea(
            child: ListView(
              key: const ValueKey('pr-conversation'),
              padding: const EdgeInsets.all(12),
              children: [
                _EventCard(
                  event: PullRequestEvent(
                    author: pr.author,
                    body: pr.body.trim().isEmpty ? '' : pr.body,
                    date: pr.createdAt,
                  ),
                  emptyText: 'No description provided.',
                  highlight: true,
                ),
                for (final e in widget.bundle.timeline) _EventCard(event: e),
                if (pr.state == PullRequestState.merged)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.merge, color: _purple, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Merged${pr.mergedBy != null ? ' by ${pr.mergedBy}' : ''}',
                          style: theme.textTheme.bodyMedium?.copyWith(color: _purple),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _send},
                  child: TextField(
                    controller: _comment,
                    minLines: 1,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      hintText: 'Leave a comment (Markdown) · Ctrl+Enter to send',
                      hintMaxLines: 1,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _sending ? null : _send,
                child: _sending
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Comment'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EventCard extends StatelessWidget {
  final PullRequestEvent event;
  final String emptyText;
  final bool highlight;

  const _EventCard({required this.event, this.emptyText = '', this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final review = event.review;
    final (reviewText, reviewColor, reviewIcon) = switch (review) {
      ReviewState.approved => ('approved these changes', _green, Icons.check_circle),
      ReviewState.changesRequested => ('requested changes', _red, Icons.do_not_disturb_on_outlined),
      ReviewState.dismissed => ('review dismissed', const Color(0xFF8D96A0), Icons.remove_circle_outline),
      ReviewState.commented || ReviewState.pending => ('reviewed', _amber, Icons.rate_review_outlined),
      null => (highlight ? 'opened this pull request' : 'commented', theme.colorScheme.onSurfaceVariant, null),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: review == null ? theme.colorScheme.outlineVariant : reviewColor.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            decoration: BoxDecoration(
              color: highlight ? theme.colorScheme.primary.withValues(alpha: 0.08) : theme.colorScheme.surfaceContainer,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              children: [
                InitialsAvatar(event.author, size: 20),
                const SizedBox(width: 8),
                if (reviewIcon != null) ...[Icon(reviewIcon, size: 15, color: reviewColor), const SizedBox(width: 4)],
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: event.author,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(
                          text: ' $reviewText',
                          style: TextStyle(color: reviewColor),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (event.date != null)
                  Text(
                    formatDate(event.date!.toLocal()),
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          if (event.body.trim().isNotEmpty || emptyText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(10),
              child: event.body.trim().isEmpty
                  ? Text(
                      emptyText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  : _MarkdownText(event.body),
            ),
        ],
      ),
    );
  }
}

/// Markdown mínimo: títulos, listas, citas y bloques de código. Suficiente
/// para leer descripciones y comentarios sin dependencias.
class _MarkdownText extends StatelessWidget {
  final String text;

  const _MarkdownText(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final widgets = <Widget>[];
    final code = <String>[];
    var inCode = false;

    void flushCode() {
      widgets.add(
        Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(code.join('\n'), style: monoStyle(context, size: 12)),
        ),
      );
      code.clear();
    }

    for (final raw in text.replaceAll('\r', '').split('\n')) {
      if (raw.trimLeft().startsWith('```')) {
        if (inCode) flushCode();
        inCode = !inCode;
        continue;
      }
      if (inCode) {
        code.add(raw);
        continue;
      }
      final line = raw.trimRight();
      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
      if (heading != null) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text(
              heading.group(2)!,
              style: heading.group(1)!.length <= 2 ? theme.textTheme.titleMedium : theme.textTheme.titleSmall,
            ),
          ),
        );
      } else if (RegExp(r'^\s*([-*+]|\d+\.)\s+').hasMatch(line)) {
        final item = line.replaceFirst(RegExp(r'^\s*([-*+]|\d+\.)\s+'), '');
        final checkbox = RegExp(r'^\[( |x|X)\]\s*').firstMatch(item);
        widgets.add(
          Padding(
            padding: EdgeInsets.only(left: 8 + (line.length - line.trimLeft().length) * 6.0, bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (checkbox == null)
              const Text('•  ')
            else
              Padding(
                padding: const EdgeInsets.only(right: 6, top: 2),
                child: Icon(
                  checkbox.group(1) == ' ' ? Icons.check_box_outline_blank : Icons.check_box,
                  size: 16,
                  color: checkbox.group(1) == ' ' ? theme.colorScheme.outline : _green,
                ),
              ),
                Expanded(child: Text(checkbox == null ? item : item.substring(checkbox.end))),
              ],
            ),
          ),
        );
      } else if (line.startsWith('>')) {
        widgets.add(
          Container(
            padding: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: theme.colorScheme.outline, width: 3)),
            ),
            child: Text(
              line.replaceFirst(RegExp(r'^>\s?'), ''),
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        );
      } else if (line.isEmpty) {
        widgets.add(const SizedBox(height: 6));
      } else {
        widgets.add(Text(line.replaceAll('**', '').replaceAll('`', '')));
      }
    }
    if (code.isNotEmpty) flushCode();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widgets);
  }
}

class _CommitsTab extends ConsumerWidget {
  final RepoHandle repo;
  final List<PullRequestCommit> commits;

  const _CommitsTab({required this.repo, required this.commits});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (commits.isEmpty) return const Center(child: Text('No commits.'));
    return ListView.separated(
      itemCount: commits.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final c = commits[i];
        return ListTile(
          dense: true,
          leading: InitialsAvatar(c.author, size: 24),
          title: Text(c.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${c.author}${c.date != null ? ' · ${formatDate(c.date!.toLocal())}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            c.sha.length > 7 ? c.sha.substring(0, 7) : c.sha,
            style: monoStyle(context, size: 12, color: theme.colorScheme.onSurfaceVariant),
          ),
          onTap: () {
            final state = ref.read(repoNotifierProvider(repo));
            if (state.commits.any((x) => x.sha == c.sha)) {
              final notifier = ref.read(repoNotifierProvider(repo).notifier);
              notifier.closePullRequest();
              notifier.selectCommit(c.sha);
            } else {
              showToast(context, 'This commit is not in your local history yet — use Fetch or Checkout.');
            }
          },
        );
      },
    );
  }
}

class _FilesTab extends StatefulWidget {
  final List<PullRequestFile> files;

  const _FilesTab({required this.files});

  @override
  State<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<_FilesTab> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final files = widget.files;
    if (files.isEmpty) return const Center(child: Text('No files changed.'));
    final index = _selected.clamp(0, files.length - 1);
    final file = files[index];
    final diff = file.patch == null
        ? parseUnifiedDiff(file.path, '')
        : parseUnifiedDiff(file.path, 'diff --git a/${file.path} b/${file.path}\n${file.patch}\n');

    final list = ListView.builder(
      itemCount: files.length,
      itemBuilder: (context, i) {
        final f = files[i];
        return Material(
          color: i == index ? theme.colorScheme.primary.withValues(alpha: 0.16) : Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _selected = i),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
              child: Row(
                children: [
                  ChangeBadge(f.type),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Tooltip(
                      message: f.oldPath != null ? '${f.oldPath} → ${f.path}' : f.path,
                      waitDuration: const Duration(milliseconds: 600),
                      child: Text(
                        f.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                  Text('+${f.additions}', style: theme.textTheme.labelSmall?.copyWith(color: _green)),
                  const SizedBox(width: 4),
                  Text('−${f.deletions}', style: theme.textTheme.labelSmall?.copyWith(color: _red)),
                ],
              ),
            ),
          ),
        );
      },
    );
    final patch = file.patch == null
        ? Center(
            child: Text(
              'GitHub does not provide a text diff for this file (binary or too large).',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          )
        : PatchView(key: ValueKey(file.path), diff: diff, path: file.path);

    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 760) {
          return Column(
            children: [
              SizedBox(height: c.maxHeight * 0.32, child: list),
              const Divider(height: 1),
              Expanded(child: patch),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: (c.maxWidth * 0.32).clamp(240.0, 380.0), child: list),
            const VerticalDivider(width: 1),
            Expanded(child: patch),
          ],
        );
      },
    );
  }
}

class _ChecksTab extends StatelessWidget {
  final List<PullRequestCheck> checks;

  const _ChecksTab({required this.checks});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (checks.isEmpty) {
      return Center(
        child: Text(
          'No checks reported for the latest commit.',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: checks.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final c = checks[i];
        return ListTile(
          dense: true,
          leading: _CiIcon(c.status, size: 20),
          title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(c.detail, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: c.url == null
              ? null
              : IconButton(
                  tooltip: 'Open details',
                  onPressed: () => launchUrl(Uri.parse(c.url!)),
                  icon: const Icon(Icons.open_in_new, size: 18),
                ),
        );
      },
    );
  }
}

// ------------------------------------------------------------- diálogos

class _MergeDialog extends StatefulWidget {
  final PullRequestDetail pr;

  const _MergeDialog({required this.pr});

  @override
  State<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends State<_MergeDialog> {
  MergeMethod _method = MergeMethod.merge;
  late final _title = TextEditingController(text: _defaultTitle(MergeMethod.merge));
  late bool _deleteBranch = !widget.pr.isFromFork;

  String _defaultTitle(MergeMethod m) => switch (m) {
    MergeMethod.merge => 'Merge pull request #${widget.pr.number} from ${widget.pr.headRef}',
    MergeMethod.squash => '${widget.pr.title} (#${widget.pr.number})',
    MergeMethod.rebase => '',
  };

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pr = widget.pr;
    return AlertDialog(
      title: Text('Merge pull request #${pr.number}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RadioGroup<MergeMethod>(
                groupValue: _method,
                onChanged: (m) => setState(() {
                  _method = m!;
                  _title.text = _defaultTitle(m);
                }),
                child: Column(
                  children: [
                    for (final (m, title, help) in [
                      (
                        MergeMethod.merge,
                        'Create a merge commit',
                        'All ${pr.commitCount} commits are added to ${pr.baseRef} with a merge commit.',
                      ),
                      (
                        MergeMethod.squash,
                        'Squash and merge',
                        'The ${pr.commitCount} commits are combined into one commit on ${pr.baseRef}.',
                      ),
                      (
                        MergeMethod.rebase,
                        'Rebase and merge',
                        'The commits are replayed onto ${pr.baseRef} — no merge commit.',
                      ),
                    ])
                      RadioListTile<MergeMethod>(
                        value: m,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(title),
                        subtitle: Text(help),
                      ),
                  ],
                ),
              ),
              if (_method != MergeMethod.rebase) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _title,
                  decoration: const InputDecoration(labelText: 'Commit title'),
                ),
              ],
              if (!pr.isFromFork)
                CheckboxListTile(
                  value: _deleteBranch,
                  onChanged: (v) => setState(() => _deleteBranch = v ?? false),
                  title: Text('Delete the branch "${pr.headRef}" on GitHub after merging'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              Text(
                'The merge happens on GitHub; your local branches are updated with a fetch afterwards.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: _green, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(
            context,
            MergePullRequest(
              _method,
              title: _method == MergeMethod.rebase ? null : _title.text,
              deleteBranch: _deleteBranch,
            ),
          ),
          icon: const Icon(Icons.merge, size: 18),
          label: Text(switch (_method) {
            MergeMethod.merge => 'Confirm merge',
            MergeMethod.squash => 'Confirm squash and merge',
            MergeMethod.rebase => 'Confirm rebase and merge',
          }),
        ),
      ],
    );
  }
}

class _ReviewDialog extends StatefulWidget {
  const _ReviewDialog();

  @override
  State<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<_ReviewDialog> {
  ReviewEvent _event = ReviewEvent.approve;
  final _body = TextEditingController();

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  /// GitHub exige texto para "request changes" y "comment".
  bool get _valid => _event == ReviewEvent.approve || _body.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Submit review'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<ReviewEvent>(
              segments: const [
                ButtonSegment(
                  value: ReviewEvent.approve,
                  label: Text('Approve'),
                  icon: Icon(Icons.check_circle_outline),
                ),
                ButtonSegment(
                  value: ReviewEvent.requestChanges,
                  label: Text('Request changes'),
                  icon: Icon(Icons.do_not_disturb_on_outlined),
                ),
                ButtonSegment(
                  value: ReviewEvent.comment,
                  label: Text('Comment'),
                  icon: Icon(Icons.chat_bubble_outline),
                ),
              ],
              selected: {_event},
              onSelectionChanged: (s) => setState(() => _event = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _body,
              minLines: 3,
              maxLines: 8,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: _event == ReviewEvent.approve ? 'Comment (optional)' : 'Comment (required)',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _valid ? () => Navigator.pop(context, ReviewPullRequest(_event, _body.text)) : null,
          child: const Text('Submit review'),
        ),
      ],
    );
  }
}

class _EditDialog extends StatefulWidget {
  final String title;
  final String body;

  const _EditDialog({required this.title, required this.body});

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final _title = TextEditingController(text: widget.title);
  late final _body = TextEditingController(text: widget.body);

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit pull request'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Title'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              minLines: 5,
              maxLines: 12,
              decoration: const InputDecoration(labelText: 'Description (Markdown)', alignLabelWithHint: true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _title.text.trim().isEmpty ? null : () => Navigator.pop(context, (_title.text.trim(), _body.text)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
