import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/file_change.dart';
import '../../domain/entities/file_diff.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/entities/repo_snapshot.dart';
import '../../domain/repositories/git_repository.dart';
import '../../domain/entities/repo_extras.dart';
import '../state/repo_notifier.dart';
import 'signing_dialog.dart';
import 'ui_helpers.dart';

/// Panel derecho cuando está seleccionado "WIP": stage/unstage y commit.
class StagingPanel extends ConsumerStatefulWidget {
  final RepoHandle repo;

  const StagingPanel({super.key, required this.repo});

  @override
  ConsumerState<StagingPanel> createState() => _StagingPanelState();
}

class _StagingPanelState extends ConsumerState<StagingPanel> {
  final _summary = TextEditingController();
  final _description = TextEditingController();
  final _scope = TextEditingController();
  bool _amend = false;

  /// Tipo de Conventional Commit (feat, fix…); null = sin prefijo.
  String? _type;
  bool _breaking = false;

  /// Firmar este commit; null = lo que diga la configuración del repo.
  bool? _sign;
  String? _template;

  @override
  void initState() {
    super.initState();
    _summary.addListener(() => setState(() {}));
    _scope.addListener(() => setState(() {}));
    // Plantilla de `commit.template`: rellena la descripción si está vacía.
    ref.listenManual(commitTemplateProvider(widget.repo), (_, next) {
      final template = next.value;
      if (template != null && _template == null && _description.text.isEmpty) {
        _description.text = template;
      }
      _template = template;
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _summary.dispose();
    _description.dispose();
    _scope.dispose();
    super.dispose();
  }

  String get _composedSummary => _summary.text.trim().isEmpty
      ? ''
      : composeConventionalSummary(type: _type, scope: _scope.text, breaking: _breaking, summary: _summary.text);

  Future<void> _commit(RepoSnapshot snapshot) async {
    final summary = _composedSummary;
    var description = _description.text.trim();
    if (description == _template) description = ''; // plantilla sin rellenar
    final message = description.isEmpty ? summary : '$summary\n\n$description';
    final config = ref.read(signingConfigProvider(widget.repo)).value;
    final sign = _sign == null || _sign == (config?.signByDefault ?? false) ? null : _sign;
    final ok = await runGitAction(
      context,
      ref,
      widget.repo,
      CommitAction(message, amend: _amend, sign: sign),
      successMessage: _amend ? 'Commit amended' : 'Committed',
    );
    if (ok && mounted) {
      _summary.clear();
      _scope.clear();
      _description.text = _template ?? '';
      setState(() {
        _amend = false;
        _type = null;
        _breaking = false;
        _sign = null;
      });
    }
  }

  /// Rebase, cherry-pick y revert se terminan con "Continue", no con commit.
  bool _continuesInstead(RepoSnapshot s) =>
      s.pendingOperation == PendingOperation.rebase ||
      s.pendingOperation == PendingOperation.cherryPick ||
      s.pendingOperation == PendingOperation.revert;

  bool _canCommit(RepoSnapshot s) {
    if (s.hasConflicts || _continuesInstead(s)) return false;
    final hasMessage = _summary.text.trim().isNotEmpty;
    if (_amend) return true; // sin mensaje → conserva el anterior
    if (s.pendingOperation == PendingOperation.merge) return true; // usa MERGE_MSG
    return hasMessage && s.staged.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(repoNotifierProvider(widget.repo));
    final snapshot = state.snapshot;
    if (snapshot == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final busy = state.isBusy;
    final open = state.openFile;

    void stageAll() => runGitAction(context, ref, widget.repo, const StageAllAction());
    void unstageAll() => runGitAction(context, ref, widget.repo, const UnstageAllAction());

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxCommitHeight = constraints.maxHeight * 0.55;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (snapshot.pendingOperation != PendingOperation.none)
              _PendingBanner(repo: widget.repo, snapshot: snapshot),
            _ListHeader(
              title: 'Unstaged Files',
              count: snapshot.unstaged.length,
              actionLabel: 'Stage all',
              actionTooltip: 'Stage all changes',
              actionIcon: Icons.add_task,
              onAction: snapshot.unstaged.isEmpty || busy ? null : stageAll,
            ),
            Expanded(
              child: _FileList(
                onMenu: (c, pos) => showFileMenu(context, ref, widget.repo, c.path, pos),
                changes: snapshot.unstaged,
                empty: 'No unstaged changes',
                isSelected: (c) => open?.source == DiffSource.unstaged && open?.path == c.path,
                onOpen: (c) => ref
                    .read(repoNotifierProvider(widget.repo).notifier)
                    .openFile(
                      DiffTarget(
                        source: DiffSource.unstaged,
                        path: c.path,
                        untracked: c.type == ChangeType.untracked,
                        conflicted: c.type == ChangeType.conflicted,
                        deleted: c.type == ChangeType.deleted,
                      ),
                    ),
                actions: (c) => [
                  _MiniAction(
                    icon: Icons.delete_outline,
                    tooltip: 'Discard changes',
                    onPressed: busy
                        ? null
                        : () async {
                            final ok = await confirmDialog(
                              context,
                              title: 'Discard changes',
                              message: c.type == ChangeType.untracked
                                  ? 'Delete the untracked file "${c.path}"? This cannot be undone.'
                                  : 'Discard your changes to "${c.path}"? This cannot be undone.',
                              confirmLabel: 'Discard',
                              destructive: true,
                            );
                            if (ok && context.mounted) {
                              await runGitAction(context, ref, widget.repo, DiscardAction([c]));
                            }
                          },
                  ),
                  _MiniAction(
                    icon: Icons.add,
                    tooltip: 'Stage file',
                    onPressed: busy ? null : () => runGitAction(context, ref, widget.repo, StageAction([c.path])),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            _ListHeader(
              title: 'Staged Files',
              count: snapshot.staged.length,
              actionLabel: 'Unstage all',
              actionTooltip: 'Unstage all changes',
              actionIcon: Icons.remove_done,
              onAction: snapshot.staged.isEmpty || busy ? null : unstageAll,
            ),
            Expanded(
              child: _FileList(
                onMenu: (c, pos) => showFileMenu(context, ref, widget.repo, c.path, pos),
                changes: snapshot.staged,
                empty: 'Stage files to include them in the commit',
                isSelected: (c) => open?.source == DiffSource.staged && open?.path == c.path,
                onOpen: (c) => ref
                    .read(repoNotifierProvider(widget.repo).notifier)
                    .openFile(
                      DiffTarget(
                        source: DiffSource.staged,
                        path: c.path,
                        oldPath: c.oldPath,
                        deleted: c.type == ChangeType.deleted,
                      ),
                    ),
                actions: (c) => [
                  _MiniAction(
                    icon: Icons.remove,
                    tooltip: 'Unstage file',
                    onPressed: busy
                        ? null
                        : () => runGitAction(
                            context,
                            ref,
                            widget.repo,
                            UnstageAction([if (c.oldPath != null) c.oldPath!, c.path]),
                          ),
                  ),
                ],
              ),
            ),
            if (!_continuesInstead(snapshot)) ...[
              const Divider(height: 1),
              ConstrainedBox(
                // En ventanas bajas la caja de commit no se come las listas de
                // ficheros: como mucho la mitad del alto, con scroll propio.
                constraints: BoxConstraints(maxHeight: maxCommitHeight),
                child: SingleChildScrollView(
                  child: Container(
                    color: theme.colorScheme.surfaceContainerLow,
                    padding: const EdgeInsets.all(12),
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
                          if (_canCommit(snapshot) && !busy) _commit(snapshot);
                        },
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _CommitOptions(
                            repo: widget.repo,
                            amend: _amend,
                            sign: _sign,
                            canAmend: snapshot.headSha != null,
                            onAmend: (v) => setState(() => _amend = v),
                            onSign: (v) => setState(() => _sign = v),
                          ),
                          const SizedBox(height: 6),
                          _ConventionalRow(
                            type: _type,
                            scope: _scope,
                            breaking: _breaking,
                            onType: (t) => setState(() => _type = t),
                            onBreaking: (b) => setState(() => _breaking = b),
                          ),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _summary,
                            maxLength: 72,
                            decoration: InputDecoration(
                              isDense: true,
                              border: const OutlineInputBorder(),
                              hintText: _amend
                                  ? 'Leave empty to keep the previous message'
                                  : snapshot.pendingOperation == PendingOperation.merge
                                  ? 'Leave empty to use the merge message'
                                  : 'Summary (required)',
                            ),
                          ),
                          if (_type != null && _summary.text.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                _composedSummary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: monoStyle(context, size: 12, color: theme.colorScheme.primary),
                              ),
                            ),
                          TextField(
                            controller: _description,
                            minLines: 2,
                            maxLines: 5,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                              hintText: 'Description',
                            ),
                          ),
                          const SizedBox(height: 10),
                          FilledButton.icon(
                            onPressed: _canCommit(snapshot) && !busy ? () => _commit(snapshot) : null,
                            icon: const Icon(Icons.check),
                            label: Text(
                              _amend
                                  ? 'Amend previous commit'
                                  : snapshot.staged.isEmpty
                                  ? 'Stage files to commit'
                                  : 'Commit ${snapshot.staged.length} file${snapshot.staged.length == 1 ? '' : 's'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Ctrl+Enter to commit',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _PendingBanner extends ConsumerWidget {
  final RepoHandle repo;
  final RepoSnapshot snapshot;

  const _PendingBanner({required this.repo, required this.snapshot});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final op = snapshot.pendingOperation;
    final what = switch (op) {
      PendingOperation.merge => 'Merge',
      PendingOperation.cherryPick => 'Cherry-pick',
      PendingOperation.revert => 'Revert',
      PendingOperation.rebase => 'Rebase',
      PendingOperation.none => '',
    };
    final rebase = snapshot.rebase;
    final title = op == PendingOperation.rebase && rebase != null
        ? 'Rebasing ${rebase.branch ?? 'HEAD'}${rebase.onto != null ? ' onto ${rebase.onto}' : ''}'
              '${rebase.total > 0 ? ' — step ${rebase.step}/${rebase.total}' : ''}'
        : '$what in progress';
    final conflicts = snapshot.hasConflicts;
    final hint = conflicts
        ? 'Resolve the conflicted files (marked !), stage them, then continue.'
        : op == PendingOperation.merge
        ? 'All conflicts resolved — commit to finish the merge.'
        : 'All conflicts resolved — continue to the next step.';
    final fg = theme.colorScheme.onTertiaryContainer;
    final busy = ref.watch(repoNotifierProvider(repo).select((s) => s.isBusy));

    Future<void> abort() async {
      if (await confirmDialog(
            context,
            title: 'Abort ${what.toLowerCase()}',
            message:
                'Go back to the state before the ${what.toLowerCase()} started? '
                'Conflict resolutions made so far will be lost.',
            confirmLabel: 'Abort',
            destructive: true,
          ) &&
          context.mounted) {
        await runGitAction(context, ref, repo, const AbortOperationAction());
      }
    }

    return Container(
      color: theme.colorScheme.tertiaryContainer,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(conflicts ? Icons.warning_amber : Icons.info_outline, color: fg, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(color: fg),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: fg)),
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              TextButton(
                onPressed: busy ? null : abort,
                style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                child: const Text('Abort'),
              ),
              if (op != PendingOperation.merge)
                Tooltip(
                  message: 'Drop the current commit and move on',
                  child: TextButton(
                    onPressed: busy ? null : () => runGitAction(context, ref, repo, const SkipOperationAction()),
                    child: const Text('Skip'),
                  ),
                ),
              FilledButton(
                onPressed: busy || conflicts
                    ? null
                    : () => runGitAction(
                        context,
                        ref,
                        repo,
                        const ContinueOperationAction(),
                        successMessage: op == PendingOperation.merge ? 'Merge committed' : null,
                      ),
                child: Text(op == PendingOperation.merge ? 'Commit merge' : 'Continue'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ListHeader extends StatelessWidget {
  final String title;
  final int count;
  final String actionLabel;
  final String actionTooltip;
  final IconData actionIcon;
  final VoidCallback? onAction;

  const _ListHeader({
    required this.title,
    required this.count,
    required this.actionLabel,
    required this.actionTooltip,
    required this.actionIcon,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 2),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('$count', style: theme.textTheme.labelSmall),
                ),
              ],
            ),
          ),
          Tooltip(
            message: actionTooltip,
            child: TextButton.icon(
              onPressed: onAction,
              icon: Icon(actionIcon, size: 16),
              label: Text(actionLabel),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _MiniAction({required this.icon, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: 17),
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
  );
}

/// Lista de ficheros cambiados reutilizada en staging y en el detalle.
class FileChangeTile extends StatelessWidget {
  final FileChange change;
  final bool selected;
  final VoidCallback onTap;
  final GestureTapDownCallback? onSecondaryTapDown;
  final List<Widget> actions;

  const FileChangeTile({
    super.key,
    required this.change,
    required this.selected,
    required this.onTap,
    this.onSecondaryTapDown,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected ? theme.colorScheme.primary.withValues(alpha: 0.14) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onSecondaryTapDown: onSecondaryTapDown,
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: SizedBox(
            height: 30,
            child: Row(
              children: [
                ChangeBadge(change.type),
                const SizedBox(width: 8),
                Expanded(
                  child: Tooltip(
                    message: change.oldPath != null ? '${change.oldPath} → ${change.path}' : change.path,
                    waitDuration: const Duration(milliseconds: 700),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: change.fileName, style: theme.textTheme.bodyMedium),
                          if (change.directory.isNotEmpty)
                            TextSpan(
                              text: '  ${change.directory}',
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                ...actions,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FileList extends StatelessWidget {
  final List<FileChange> changes;
  final String empty;
  final bool Function(FileChange) isSelected;
  final void Function(FileChange) onOpen;
  final List<Widget> Function(FileChange) actions;
  final void Function(FileChange change, Offset position)? onMenu;

  const _FileList({
    required this.changes,
    required this.empty,
    required this.isSelected,
    required this.onOpen,
    required this.actions,
    this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    if (changes.isEmpty) {
      return Center(
        child: Text(
          empty,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      itemCount: changes.length,
      itemBuilder: (context, i) {
        final c = changes[i];
        return FileChangeTile(
          change: c,
          selected: isSelected(c),
          onTap: () => onOpen(c),
          onSecondaryTapDown: onMenu == null ? null : (d) => onMenu!(c, d.globalPosition),
          actions: actions(c),
        );
      },
    );
  }
}

/// Fila "Commit" con los interruptores de firma y amend.
class _CommitOptions extends ConsumerWidget {
  final RepoHandle repo;
  final bool amend;
  final bool? sign;
  final bool canAmend;
  final ValueChanged<bool> onAmend;
  final ValueChanged<bool> onSign;

  const _CommitOptions({
    required this.repo,
    required this.amend,
    required this.sign,
    required this.canAmend,
    required this.onAmend,
    required this.onSign,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final config = ref.watch(signingConfigProvider(repo)).value ?? const SigningConfig();
    final signing = sign ?? config.signByDefault;
    final kind = config.format == SigningFormat.ssh ? 'SSH' : 'GPG';

    return Row(
      children: [
        Text('Commit', style: theme.textTheme.titleSmall),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              Tooltip(
                message: config.hasKey
                    ? (signing ? 'This commit will be signed ($kind)' : 'Sign this commit with your $kind key')
                    : 'Set up commit signing first',
                child: FilterChip(
                  avatar: Icon(signing ? Icons.verified_user : Icons.verified_user_outlined, size: 16),
                  label: const Text('Sign'),
                  selected: signing && config.hasKey,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  onSelected: config.hasKey ? onSign : (_) => showSigningDialog(context, ref, repo),
                ),
              ),
              IconButton(
                tooltip: 'Signing settings…',
                onPressed: () => showSigningDialog(context, ref, repo),
                icon: const Icon(Icons.tune, size: 18),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
              Tooltip(
                message: 'Replace the last commit instead of creating a new one',
                child: FilterChip(
                  avatar: const Icon(Icons.edit_note, size: 16),
                  label: const Text('Amend'),
                  selected: amend,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  onSelected: canAmend ? onAmend : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Tipo / scope / breaking de Conventional Commits.
class _ConventionalRow extends StatelessWidget {
  final String? type;
  final TextEditingController scope;
  final bool breaking;
  final ValueChanged<String?> onType;
  final ValueChanged<bool> onBreaking;

  const _ConventionalRow({
    required this.type,
    required this.scope,
    required this.breaking,
    required this.onType,
    required this.onBreaking,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 104,
          child: DropdownButtonFormField<String?>(
            initialValue: type,
            isDense: true,
            isExpanded: true,
            decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
            hint: const Text('type'),
            // Cerrado: "type" en gris si no hay tipo; abierto: "— none" + tipos.
            selectedItemBuilder: (context) => [
              Text('type', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
              for (final t in conventionalTypes.keys) Text(t, style: monoStyle(context, size: 13)),
            ],
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('— none')),
              for (final e in conventionalTypes.entries)
                DropdownMenuItem<String?>(
                  value: e.key,
                  child: Tooltip(
                    message: e.value,
                    child: Text(e.key, style: monoStyle(context, size: 13)),
                  ),
                ),
            ],
            onChanged: onType,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: TextField(
            controller: scope,
            enabled: type != null,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'scope (optional)',
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: 'Breaking change (adds "!")',
          child: FilterChip(
            label: Text(
              '!',
              style: TextStyle(fontWeight: FontWeight.w800, color: breaking ? theme.colorScheme.error : null),
            ),
            selected: breaking,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: type == null ? null : onBreaking,
          ),
        ),
      ],
    );
  }
}
