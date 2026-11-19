import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/error/result.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/entities/pull_request.dart';
import '../../domain/entities/repo_snapshot.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'ui_helpers.dart';

/// Crea una Pull Request en GitHub desde [head] (por defecto, la rama actual).
Future<void> showCreatePullRequestDialog(BuildContext context, WidgetRef ref, RepoHandle repo, {String? head}) async {
  final created = await showDialog<PullRequest>(
    context: context,
    builder: (_) => _CreatePullRequestDialog(repo: repo, initialHead: head),
  );
  if (created == null || !context.mounted) return;
  ref.invalidate(pullRequestsProvider(repo));
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('Pull request #${created.number} created'),
    action: SnackBarAction(
      label: 'View',
      onPressed: () => ref.read(repoNotifierProvider(repo).notifier).openPullRequest(created.number),
    ),
  ));
}

class _CreatePullRequestDialog extends ConsumerStatefulWidget {
  final RepoHandle repo;
  final String? initialHead;

  const _CreatePullRequestDialog({required this.repo, this.initialHead});

  @override
  ConsumerState<_CreatePullRequestDialog> createState() => _CreatePullRequestDialogState();
}

class _CreatePullRequestDialogState extends ConsumerState<_CreatePullRequestDialog> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  GitHubRepoInfo? _info;
  String? _loadError;
  String? _head;
  String? _base;
  bool _draft = false;
  bool _pushFirst = true;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    final snapshot = ref.read(repoNotifierProvider(widget.repo)).snapshot;
    _head = widget.initialHead ?? snapshot?.currentBranch;
    _title.text = _suggestTitle(_head);
    _loadInfo();
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _loadInfo() async {
    final result = await ref.read(gitRepositoryProvider).githubRepoInfo(widget.repo);
    if (!mounted) return;
    setState(() {
      switch (result) {
        case Success(:final value):
          _info = value;
          _base ??= value.defaultBranch;
        case Failure(:final failure):
          _loadError = failure.message;
      }
    });
  }

  /// Título sugerido: el último commit de la rama o su nombre "humanizado".
  String _suggestTitle(String? branch) {
    if (branch == null) return '';
    final state = ref.read(repoNotifierProvider(widget.repo));
    final sha = state.snapshot?.localBranches.where((b) => b.name == branch).firstOrNull?.sha;
    final commit = state.commits.where((c) => c.sha == sha).firstOrNull;
    if (commit != null) return commit.subject;
    final name = branch.split('/').last.replaceAll(RegExp(r'[-_]+'), ' ').trim();
    return name.isEmpty ? branch : name[0].toUpperCase() + name.substring(1);
  }

  Future<void> _create(GitRef? headRef) async {
    final head = _head;
    final base = _base;
    if (head == null || base == null || _title.text.trim().isEmpty) return;
    setState(() => _working = true);

    final needsPush = headRef == null || headRef.upstream == null || headRef.ahead > 0;
    if (needsPush && _pushFirst) {
      final pushed = await runGitAction(context, ref, widget.repo, PushAction(branch: head));
      if (!pushed || !mounted) {
        if (mounted) setState(() => _working = false);
        return;
      }
    }

    final result = await ref.read(gitRepositoryProvider).createPullRequest(
          widget.repo,
          title: _title.text.trim(),
          body: _body.text.trim(),
          head: head,
          base: base,
          draft: _draft,
        );
    if (!mounted) return;
    setState(() => _working = false);
    switch (result) {
      case Success(:final value):
        Navigator.pop(context, value);
      case Failure(:final failure):
        await showGitError(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = ref.watch(repoNotifierProvider(widget.repo).select((s) => s.snapshot));
    final locals = snapshot?.localBranches ?? const <GitRef>[];
    final headRef = locals.where((b) => b.name == _head).firstOrNull;
    final remote = snapshot?.remotes.contains('origin') ?? false ? 'origin' : snapshot?.remotes.firstOrNull;
    final bases = <String>{
      if (_info != null) _info!.defaultBranch,
      for (final r in snapshot?.remoteBranches ?? const <GitRef>[])
        if (r.remoteName == remote) r.nameWithoutRemote,
    }.where((b) => b != _head).toList()
      ..sort();
    final needsPush = headRef == null || headRef.upstream == null || headRef.ahead > 0;

    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.merge_type),
        const SizedBox(width: 10),
        const Expanded(child: Text('Create pull request')),
        if (_info != null)
          Flexible(
            child: Text(_info!.fullName,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          ),
      ]),
      content: SizedBox(
        width: 560,
        child: _loadError != null
            ? Text(_loadError!, style: TextStyle(color: theme.colorScheme.error))
            : _info == null
                ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                initialValue: _base != null && bases.contains(_base) ? _base : null,
                                isExpanded: true,
                                decoration: const InputDecoration(labelText: 'Base (merge into)'),
                                hint: Text(bases.isEmpty ? 'No other branch on GitHub' : 'Choose a branch'),
                                items: [for (final b in bases) DropdownMenuItem(value: b, child: Text(b))],
                                onChanged: (v) => setState(() => _base = v),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 10),
                              child: Icon(Icons.arrow_back, size: 18),
                            ),
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                initialValue: locals.any((b) => b.name == _head) ? _head : null,
                                isExpanded: true,
                                decoration: const InputDecoration(labelText: 'Compare (your branch)'),
                                items: [for (final b in locals) DropdownMenuItem(value: b.name, child: Text(b.name))],
                                onChanged: (v) => setState(() {
                                  _head = v;
                                  _title.text = _suggestTitle(v);
                                }),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _title,
                          autofocus: true,
                          decoration: const InputDecoration(labelText: 'Title'),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _body,
                          minLines: 4,
                          maxLines: 10,
                          decoration: const InputDecoration(labelText: 'Description (Markdown)', alignLabelWithHint: true),
                        ),
                        const SizedBox(height: 6),
                        CheckboxListTile(
                          value: _draft,
                          onChanged: (v) => setState(() => _draft = v ?? false),
                          title: const Text('Create as draft'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        if (needsPush)
                          CheckboxListTile(
                            value: _pushFirst,
                            onChanged: (v) => setState(() => _pushFirst = v ?? true),
                            title: Text(headRef?.upstream == null
                                ? '"$_head" is not on GitHub yet — push it first'
                                : 'Push ${headRef!.ahead} new commit${headRef.ahead == 1 ? '' : 's'} first'),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                          ),
                      ],
                    ),
                  ),
      ),
      actions: [
        TextButton(onPressed: _working ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: _working || _info == null || _head == null || _base == null || _title.text.trim().isEmpty
              ? null
              : () => _create(headRef),
          icon: _working
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.send, size: 18),
          label: Text(_working ? 'Creating…' : 'Create pull request'),
        ),
      ],
    );
  }
}
