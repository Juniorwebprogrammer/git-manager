import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/error/result.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/repositories/git_repository.dart';
import 'ui_helpers.dart';

/// Abre el editor de rebase interactivo para los commits de `base..HEAD`
/// y, si se confirma, lanza el rebase.
Future<void> showInteractiveRebaseDialog(
  BuildContext context,
  WidgetRef ref,
  RepoHandle repo, {
  required String base,
  required String baseLabel,
  required String branchLabel,
}) async {
  final result = await ref.read(gitRepositoryProvider).loadCommitsForRebase(repo, base);
  if (!context.mounted) return;
  final commits = switch (result) {
    Success(:final value) => value,
    Failure(:final failure) => () {
        showGitError(context, failure);
        return null;
      }(),
  };
  if (commits == null) return;
  if (commits.isEmpty) {
    showToast(context, 'Nothing to rebase: $branchLabel has no commits after $baseLabel.');
    return;
  }

  final steps = await showDialog<List<RebaseStep>>(
    context: context,
    builder: (_) => _InteractiveRebaseDialog(
      branchLabel: branchLabel,
      baseLabel: baseLabel,
      initial: [for (final c in commits) RebaseStep(sha: c.sha, subject: c.subject)],
    ),
  );
  if (steps == null || !context.mounted) return;
  await runGitAction(context, ref, repo, InteractiveRebaseAction(base, steps),
      successMessage: 'Interactive rebase of $branchLabel finished');
}

class _InteractiveRebaseDialog extends StatefulWidget {
  final String branchLabel;
  final String baseLabel;
  final List<RebaseStep> initial;

  const _InteractiveRebaseDialog({required this.branchLabel, required this.baseLabel, required this.initial});

  @override
  State<_InteractiveRebaseDialog> createState() => _InteractiveRebaseDialogState();
}

class _InteractiveRebaseDialogState extends State<_InteractiveRebaseDialog> {
  late final List<RebaseStep> _steps = [...widget.initial];
  final Map<String, TextEditingController> _messages = {};

  @override
  void dispose() {
    for (final c in _messages.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _messageFor(RebaseStep step) =>
      _messages.putIfAbsent(step.sha, () => TextEditingController(text: step.message ?? step.subject));

  bool get _changed {
    if (_steps.length != widget.initial.length) return true;
    for (var i = 0; i < _steps.length; i++) {
      final s = _steps[i];
      if (s.sha != widget.initial[i].sha || s.action != RebaseStepAction.pick) return true;
    }
    return false;
  }

  String? get _problem {
    final kept = _steps.where((s) => s.action != RebaseStepAction.drop).toList();
    if (kept.isEmpty) return 'Keep at least one commit.';
    if (kept.first.action == RebaseStepAction.squash || kept.first.action == RebaseStepAction.fixup) {
      return 'The first kept commit cannot be squashed or fixed up: there is nothing before it to join.';
    }
    if (_steps.any((s) => s.action == RebaseStepAction.reword && _messageFor(s).text.trim().isEmpty)) {
      return 'A reworded commit needs a message.';
    }
    return null;
  }

  void _setAction(int index, RebaseStepAction action) => setState(() => _steps[index] = _steps[index].copyWith(action: action));

  void _start() {
    final result = [
      for (final s in _steps)
        s.action == RebaseStepAction.reword ? s.copyWith(message: _messageFor(s).text.trim()) : s,
    ];
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = _problem;

    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 760,
        height: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Interactive rebase', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.branchLabel} onto ${widget.baseLabel} · oldest commit at the top · drag the handle to reorder',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                itemCount: _steps.length,
                // onReorderItem ya da el índice destino ajustado tras quitar el elemento.
                onReorderItem: (from, to) => setState(() => _steps.insert(to, _steps.removeAt(from))),
                itemBuilder: (context, i) {
                  final step = _steps[i];
                  return _StepRow(
                    key: ValueKey(step.sha),
                    index: i,
                    step: step,
                    message: _messageFor(step),
                    onAction: (a) => _setAction(i, a),
                    onMessageChanged: () => setState(() {}),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    problem ??
                        'Rewrites the history of ${widget.branchLabel}. If it was already pushed you will need to '
                            'force push. Local changes are stashed and restored automatically.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: problem != null ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      for (final a in RebaseStepAction.values)
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          _ActionDot(a),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(_actionHelp(a),
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall),
                          ),
                        ]),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: problem == null && _changed ? _start : null,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start rebase'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _actionHelp(RebaseStepAction a) => switch (a) {
      RebaseStepAction.pick => 'pick: keep',
      RebaseStepAction.reword => 'reword: new message',
      RebaseStepAction.squash => 'squash: join previous, keep both messages',
      RebaseStepAction.fixup => 'fixup: join previous, drop message',
      RebaseStepAction.drop => 'drop: remove',
    };

Color _actionColor(RebaseStepAction a) => switch (a) {
      RebaseStepAction.pick => const Color(0xFF3FB950),
      RebaseStepAction.reword => const Color(0xFF388BFD),
      RebaseStepAction.squash => const Color(0xFFA371F7),
      RebaseStepAction.fixup => const Color(0xFFD29922),
      RebaseStepAction.drop => const Color(0xFFF85149),
    };

class _ActionDot extends StatelessWidget {
  final RebaseStepAction action;

  const _ActionDot(this.action);

  @override
  Widget build(BuildContext context) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: _actionColor(action), shape: BoxShape.circle),
      );
}

class _StepRow extends StatelessWidget {
  final int index;
  final RebaseStep step;
  final TextEditingController message;
  final ValueChanged<RebaseStepAction> onAction;
  final VoidCallback onMessageChanged;

  const _StepRow({
    super.key,
    required this.index,
    required this.step,
    required this.message,
    required this.onAction,
    required this.onMessageChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dropped = step.action == RebaseStepAction.drop;
    final joins = step.action == RebaseStepAction.squash || step.action == RebaseStepAction.fixup;
    final color = _actionColor(step.action);

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: EdgeInsets.fromLTRB(joins ? 28 : 8, 4, 12, 4),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5))),
        ),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: const MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Padding(padding: EdgeInsets.all(6), child: Icon(Icons.drag_indicator, size: 18)),
              ),
            ),
            if (joins) Icon(Icons.subdirectory_arrow_right, size: 16, color: color),
            const SizedBox(width: 4),
            SizedBox(
              width: 104,
              child: DropdownButtonHideUnderline(
                child: DropdownButton<RebaseStepAction>(
                  value: step.action,
                  isDense: true,
                  isExpanded: true,
                  borderRadius: BorderRadius.circular(8),
                  items: [
                    for (final a in RebaseStepAction.values)
                      DropdownMenuItem(
                        value: a,
                        child: Row(children: [
                          _ActionDot(a),
                          const SizedBox(width: 6),
                          Text(a.name, style: TextStyle(color: _actionColor(a), fontWeight: FontWeight.w600)),
                        ]),
                      ),
                  ],
                  onChanged: (a) {
                    if (a != null) onAction(a);
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(step.sha.substring(0, 7),
                style: monoStyle(context, size: 12, color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(width: 10),
            Expanded(
              child: step.action == RebaseStepAction.reword
                  ? TextField(
                      controller: message,
                      autofocus: true,
                      onChanged: (_) => onMessageChanged(),
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                    )
                  : Text(
                      step.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        decoration: dropped ? TextDecoration.lineThrough : null,
                        color: dropped ? theme.colorScheme.outline : null,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
