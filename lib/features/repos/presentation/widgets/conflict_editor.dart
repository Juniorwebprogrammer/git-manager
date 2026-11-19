import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/conflicts/conflict_parser.dart';
import '../../domain/entities/file_diff.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/entities/repo_snapshot.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'code_highlighter.dart';
import 'ui_helpers.dart';

const _oursColor = Color(0xFF388BFD);
const _theirsColor = Color(0xFFA371F7);
const _resolvedColor = Color(0xFF3FB950);

/// Resolución de conflictos de merge/rebase bloque a bloque, sin salir de
/// la app: "Current" (ours) frente a "Incoming" (theirs).
class ConflictEditor extends ConsumerStatefulWidget {
  final RepoHandle repo;
  final DiffTarget target;

  const ConflictEditor({super.key, required this.repo, required this.target});

  @override
  ConsumerState<ConflictEditor> createState() => _ConflictEditorState();
}

class _ConflictEditorState extends ConsumerState<ConflictEditor> {
  String? _parsedText;
  ParsedConflictFile? _parsed;
  List<ConflictChoice?> _choices = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(repoNotifierProvider(widget.repo).notifier).loadFileContent();
    });
  }

  /// Vuelve a trocear solo si el fichero cambió en disco; así no se pierden
  /// las elecciones con cada refresco periódico.
  void _syncWith(String text) {
    if (text == _parsedText) return;
    _parsedText = text;
    _parsed = parseConflicts(text);
    _choices = List.filled(_parsed!.conflicts.length, null);
  }

  Future<void> _markResolved() async {
    final parsed = _parsed;
    final content = parsed == null || parsed.conflicts.isEmpty ? null : parsed.render(_choices);
    await runGitAction(
      context,
      ref,
      widget.repo,
      ResolveConflictAction(widget.target.path, content),
      successMessage: '${widget.target.path} marked as resolved',
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(repoNotifierProvider(widget.repo));
    final theme = Theme.of(context);
    final content = state.fileContent;
    if (content == null || content.path != widget.target.path) {
      return Column(
        children: [
          _bar(context, null, state.snapshot),
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }
    if (content.isBinary) {
      return Column(
        children: [
          _bar(context, null, state.snapshot),
          Expanded(
            child: _Message(
              'Binary file in conflict: keep the version you want on disk, then mark it as resolved.',
              onResolve: _markResolved,
            ),
          ),
        ],
      );
    }

    _syncWith(content.text);
    final parsed = _parsed!;
    final highlighter = CodeHighlighter.forPath(widget.target.path, theme.brightness);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _bar(context, parsed, state.snapshot),
        const Divider(height: 1),
        Expanded(
          child: parsed.conflicts.isEmpty
              ? _Message(
                  'No conflict markers left in this file (or it was deleted on one side). '
                  'If its content is what you want, mark it as resolved.',
                  onResolve: _markResolved,
                )
              : LayoutBuilder(builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 720;
                  var conflictIndex = 0;
                  final children = <Widget>[];
                  for (final segment in parsed.segments) {
                    switch (segment) {
                      case TextSegment(:final lines):
                        children.add(_ContextLines(lines: lines, highlighter: highlighter));
                      case ConflictBlock():
                        final i = conflictIndex++;
                        children.add(_ConflictCard(
                          index: i,
                          total: parsed.conflicts.length,
                          block: segment,
                          choice: _choices[i],
                          wide: wide,
                          highlighter: highlighter,
                          onChoose: (c) => setState(() => _choices[i] = c),
                        ));
                    }
                  }
                  return SelectionArea(
                    child: ListView(padding: const EdgeInsets.only(bottom: 24), children: children),
                  );
                }),
        ),
      ],
    );
  }

  Widget _bar(BuildContext context, ParsedConflictFile? parsed, RepoSnapshot? snapshot) {
    final theme = Theme.of(context);
    final total = parsed?.conflicts.length ?? 0;
    final done = _choices.where((c) => c != null).length;
    final allDone = parsed != null && done == total;
    final busy = ref.watch(repoNotifierProvider(widget.repo).select((s) => s.isBusy));
    final rebasing = snapshot?.pendingOperation == PendingOperation.rebase;

    void chooseAll(ConflictChoice c) => setState(() => _choices = List.filled(total, c));

    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.call_merge, size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.target.path,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                    Text(
                      parsed == null ? 'Loading…' : '$done of $total conflict${total == 1 ? '' : 's'} resolved',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: allDone ? _resolvedColor : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Close (Esc)',
                onPressed: ref.read(repoNotifierProvider(widget.repo).notifier).closeFile,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (rebasing)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(
                'Rebasing: "Current" is the branch you are rebasing onto; "Incoming" is your commit being replayed.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          if (parsed != null && total > 0)
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 4,
              children: [
                OutlinedButton(
                  onPressed: busy ? null : () => chooseAll(ConflictChoice.ours),
                  child: const Text('All current'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : () => chooseAll(ConflictChoice.theirs),
                  child: const Text('All incoming'),
                ),
                FilledButton.icon(
                  onPressed: busy || !allDone ? null : _markResolved,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Mark resolved'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  final VoidCallback onResolve;

  const _Message(this.text, {required this.onResolve});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onResolve,
                icon: const Icon(Icons.check),
                label: const Text('Mark as resolved'),
              ),
            ],
          ),
        ),
      );
}

/// Código sin conflicto entre bloques; si es largo se resume.
class _ContextLines extends StatelessWidget {
  final List<String> lines;
  final CodeHighlighter highlighter;

  const _ContextLines({required this.lines, required this.highlighter});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = monoStyle(context, color: theme.colorScheme.onSurfaceVariant);
    final shown = lines.length <= 8 ? lines : [...lines.take(3), null, ...lines.skip(lines.length - 3)];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in shown)
            line == null
                ? Text('⋯ ${lines.length - 6} unchanged lines ⋯',
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline))
                : Text.rich(highlighter.highlight(line.replaceAll('\r', ''), base)),
        ],
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  final int index;
  final int total;
  final ConflictBlock block;
  final ConflictChoice? choice;
  final bool wide;
  final CodeHighlighter highlighter;
  final ValueChanged<ConflictChoice?> onChoose;

  const _ConflictCard({
    required this.index,
    required this.total,
    required this.block,
    required this.choice,
    required this.wide,
    required this.highlighter,
    required this.onChoose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolved = choice != null;

    final header = Row(
      children: [
        Icon(resolved ? Icons.check_circle : Icons.warning_amber,
            size: 18, color: resolved ? _resolvedColor : theme.colorScheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            resolved
                ? 'Conflict ${index + 1} of $total — ${_choiceLabel(choice!)}'
                : 'Conflict ${index + 1} of $total',
            style: theme.textTheme.titleSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (resolved) TextButton(onPressed: () => onChoose(null), child: const Text('Change')),
      ],
    );

    Widget body;
    if (resolved) {
      final lines = switch (choice!) {
        ConflictChoice.ours => block.ours,
        ConflictChoice.theirs => block.theirs,
        ConflictChoice.oursThenTheirs => [...block.ours, ...block.theirs],
        ConflictChoice.theirsThenOurs => [...block.theirs, ...block.ours],
      };
      body = _Side(title: 'Result', color: _resolvedColor, lines: lines, highlighter: highlighter);
    } else {
      final ours = _Side(
        title: 'Current${block.oursLabel.isEmpty ? '' : ' · ${block.oursLabel}'}',
        color: _oursColor,
        lines: block.ours,
        highlighter: highlighter,
        action: FilledButton.tonal(
          onPressed: () => onChoose(ConflictChoice.ours),
          child: const Text('Use current'),
        ),
      );
      final theirs = _Side(
        title: 'Incoming${block.theirsLabel.isEmpty ? '' : ' · ${block.theirsLabel}'}',
        color: _theirsColor,
        lines: block.theirs,
        highlighter: highlighter,
        action: FilledButton.tonal(
          onPressed: () => onChoose(ConflictChoice.theirs),
          child: const Text('Use incoming'),
        ),
      );
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [Expanded(child: ours), const SizedBox(width: 8), Expanded(child: theirs)],
              ),
            )
          else ...[ours, const SizedBox(height: 8), theirs],
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 6,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: () => onChoose(ConflictChoice.oursThenTheirs),
                child: const Text('Both (current first)'),
              ),
              TextButton(
                onPressed: () => onChoose(ConflictChoice.theirsThenOurs),
                child: const Text('Both (incoming first)'),
              ),
            ],
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: resolved ? _resolvedColor.withValues(alpha: 0.6) : theme.colorScheme.error),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [header, const SizedBox(height: 6), body],
      ),
    );
  }

  String _choiceLabel(ConflictChoice c) => switch (c) {
        ConflictChoice.ours => 'using current',
        ConflictChoice.theirs => 'using incoming',
        ConflictChoice.oursThenTheirs => 'using both (current first)',
        ConflictChoice.theirsThenOurs => 'using both (incoming first)',
      };
}

class _Side extends StatelessWidget {
  final String title;
  final Color color;
  final List<String> lines;
  final CodeHighlighter highlighter;
  final Widget? action;

  const _Side({required this.title, required this.color, required this.lines, required this.highlighter, this.action});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = monoStyle(context);
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w700)),
              ),
              ?action,
            ],
          ),
          const SizedBox(height: 4),
          if (lines.isEmpty)
            Text('(empty)', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline))
          else
            for (final line in lines) Text.rich(highlighter.highlight(line.replaceAll('\r', ''), base)),
        ],
      ),
    );
  }
}
