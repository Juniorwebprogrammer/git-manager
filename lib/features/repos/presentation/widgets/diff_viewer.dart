import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/file_diff.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'code_highlighter.dart';
import 'ui_helpers.dart';

enum _ViewMode { unified, split, file }

/// Visor de diffs (unificado / lado a lado) y de fichero completo.
class DiffViewer extends ConsumerStatefulWidget {
  final RepoHandle repo;

  const DiffViewer({super.key, required this.repo});

  @override
  ConsumerState<DiffViewer> createState() => _DiffViewerState();
}

class _DiffViewerState extends ConsumerState<DiffViewer> {
  _ViewMode _mode = _ViewMode.unified;

  void _setMode(_ViewMode mode) {
    setState(() => _mode = mode);
    if (mode == _ViewMode.file) ref.read(repoNotifierProvider(widget.repo).notifier).loadFileContent();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(repoNotifierProvider(widget.repo));
    final target = state.openFile;
    if (target == null) return const SizedBox.shrink();

    // Al cambiar de fichero en modo "File" hay que pedir el contenido nuevo.
    if (_mode == _ViewMode.file && state.fileContent == null && state.diffError == null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => ref.read(repoNotifierProvider(widget.repo).notifier).loadFileContent(),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(repo: widget.repo, target: target, diff: state.diff, mode: _mode, onMode: _setMode),
        const Divider(height: 1),
        Expanded(child: _body(context, state, target)),
      ],
    );
  }

  Widget _body(BuildContext context, RepoState state, DiffTarget target) {
    if (state.diffError != null) {
      return Center(child: Text(state.diffError!.message, textAlign: TextAlign.center));
    }
    final highlighter = CodeHighlighter.forPath(target.path, Theme.of(context).brightness);

    if (_mode == _ViewMode.file) {
      final content = state.fileContent;
      if (content == null) return const Center(child: CircularProgressIndicator());
      if (content.isBinary) return const _Notice('Binary file — preview not available.');
      return _FileView(content: content, highlighter: highlighter);
    }

    final diff = state.diff;
    if (diff == null) return const Center(child: CircularProgressIndicator());
    if (diff.isBinary) return const _Notice('Binary file changed — no text diff to show.');
    if (diff.hunks.isEmpty) return const _Notice('No textual changes (mode or whitespace-only change).');
    return _mode == _ViewMode.split
        ? _SplitDiff(diff: diff, highlighter: highlighter)
        : _UnifiedDiff(diff: diff, highlighter: highlighter);
  }
}

class _Notice extends StatelessWidget {
  final String text;

  const _Notice(this.text);

  @override
  Widget build(BuildContext context) => Center(
    child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
  );
}

class _Header extends ConsumerWidget {
  final RepoHandle repo;
  final DiffTarget target;
  final FileDiff? diff;
  final _ViewMode mode;
  final ValueChanged<_ViewMode> onMode;

  const _Header({
    required this.repo,
    required this.target,
    required this.diff,
    required this.mode,
    required this.onMode,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(repoNotifierProvider(repo).notifier);
    final paths = [if (target.oldPath != null) target.oldPath!, target.path];

    Future<void> stageOrUnstage(GitAction action) async {
      final ok = await runGitAction(context, ref, repo, action);
      if (ok) notifier.closeFile();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Por debajo de este ancho, los botones pasan a ser solo iconos.
        final compact = constraints.maxWidth < 700;

        ButtonSegment<_ViewMode> segment(_ViewMode value, String label, String tooltip, IconData icon) => ButtonSegment(
          value: value,
          tooltip: tooltip,
          icon: Icon(icon, size: 16),
          label: compact ? null : Text(label),
        );

        final faded = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: target.oldPath != null ? '${target.oldPath} → ${target.path}' : target.path,
              child: Text(
                target.oldPath != null ? '${target.oldPath}  →  ${target.path}' : target.path,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: switch (target.source) {
                      DiffSource.unstaged => 'Unstaged changes',
                      DiffSource.staged => 'Staged changes',
                      DiffSource.commit => 'Commit ${target.commitSha!.substring(0, 7)}',
                    },
                    style: faded,
                  ),
                  if (diff != null && !diff!.isBinary) ...[
                    TextSpan(
                      text: '   +${diff!.additions}',
                      style: faded?.copyWith(color: const Color(0xFF3FB950)),
                    ),
                    TextSpan(
                      text: '  −${diff!.deletions}',
                      style: faded?.copyWith(color: const Color(0xFFF85149)),
                    ),
                  ],
                  if (diff?.truncated ?? false) TextSpan(text: '  (truncated)', style: faded),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        );
        final actions = <Widget>[
          if (target.source != DiffSource.commit)
            _HeaderAction(
              compact: compact,
              staged: target.source == DiffSource.staged,
              onPressed: () =>
                  stageOrUnstage(target.source == DiffSource.staged ? UnstageAction(paths) : StageAction(paths)),
            ),
          const SizedBox(width: 6),
          SegmentedButton<_ViewMode>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              segment(_ViewMode.unified, 'Unified', 'Unified diff', Icons.view_agenda_outlined),
              segment(_ViewMode.split, 'Split', 'Side-by-side diff', Icons.vertical_split_outlined),
              segment(_ViewMode.file, 'File', 'Whole file', Icons.code),
            ],
            selected: {mode},
            onSelectionChanged: (s) => onMode(s.first),
          ),
          IconButton(tooltip: 'Close (Esc)', onPressed: notifier.closeFile, icon: const Icon(Icons.close)),
        ];
        final fileIcon = Icon(Icons.description_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant);

        return Container(
          color: theme.colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          // Estrecho: fichero arriba y acciones debajo, para que el nombre se lea.
          child: constraints.maxWidth < 560
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        fileIcon,
                        const SizedBox(width: 8),
                        Expanded(child: info),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
                  ],
                )
              : Row(
                  children: [
                    fileIcon,
                    const SizedBox(width: 8),
                    Expanded(child: info),
                    ...actions,
                  ],
                ),
        );
      },
    );
  }
}

class _HeaderAction extends StatelessWidget {
  final bool compact;
  final bool staged;
  final VoidCallback onPressed;

  const _HeaderAction({required this.compact, required this.staged, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final label = staged ? 'Unstage file' : 'Stage file';
    final icon = Icon(staged ? Icons.remove : Icons.add, size: 18);
    return Tooltip(
      message: label,
      child: compact
          ? IconButton(onPressed: onPressed, icon: icon)
          : TextButton.icon(onPressed: onPressed, icon: icon, label: Text(label)),
    );
  }
}

// ------------------------------------------------------------- renderizado

class _DiffColors {
  final Color addBg, delBg, addGutter, delGutter, hunkBg, gutterText;

  _DiffColors(ThemeData theme)
    : addBg = const Color(0xFF2EA043).withValues(alpha: theme.brightness == Brightness.dark ? 0.16 : 0.12),
      delBg = const Color(0xFFF85149).withValues(alpha: theme.brightness == Brightness.dark ? 0.16 : 0.12),
      addGutter = const Color(0xFF2EA043).withValues(alpha: 0.28),
      delGutter = const Color(0xFFF85149).withValues(alpha: 0.28),
      hunkBg = theme.colorScheme.primary.withValues(alpha: 0.08),
      gutterText = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7);
}

class _Gutter extends StatelessWidget {
  final int? number;
  final Color? color;
  final TextStyle style;

  const _Gutter(this.number, this.style, {this.color});

  @override
  Widget build(BuildContext context) => Container(
    width: 52,
    color: color,
    padding: const EdgeInsets.only(right: 8),
    alignment: Alignment.topRight,
    child: Text(number?.toString() ?? '', style: style),
  );
}

class _HunkHeader extends StatelessWidget {
  final String text;
  final _DiffColors colors;

  const _HunkHeader(this.text, this.colors);

  @override
  Widget build(BuildContext context) => Container(
    color: colors.hunkBg,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Text(text, style: monoStyle(context, size: 12, color: Theme.of(context).colorScheme.primary)),
  );
}

class _UnifiedDiff extends StatelessWidget {
  final FileDiff diff;
  final CodeHighlighter highlighter;

  const _UnifiedDiff({required this.diff, required this.highlighter});

  @override
  Widget build(BuildContext context) {
    final colors = _DiffColors(Theme.of(context));
    final rows = <Object>[
      for (final h in diff.hunks) ...[h.header, ...h.lines],
    ];
    final base = monoStyle(context);
    final gutter = monoStyle(context, size: 11.5, color: colors.gutterText);

    return SelectionArea(
      child: ListView.builder(
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final row = rows[i];
          if (row is String) return _HunkHeader(row, colors);
          final line = row as DiffLine;
          final (bg, gut, sign) = switch (line.type) {
            DiffLineType.added => (colors.addBg, colors.addGutter, '+'),
            DiffLineType.removed => (colors.delBg, colors.delGutter, '−'),
            _ => (null, null, ' '),
          };
          return Container(
            color: bg,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Gutter(line.oldNumber, gutter, color: gut),
                  _Gutter(line.newNumber, gutter, color: gut),
                  SizedBox(
                    width: 18,
                    child: Text(sign, textAlign: TextAlign.center, style: base),
                  ),
                  Expanded(
                    child: line.type == DiffLineType.meta
                        ? Text(
                            line.text,
                            style: base.copyWith(fontStyle: FontStyle.italic, color: colors.gutterText),
                          )
                        : Text.rich(highlighter.highlight(line.text, base)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SplitDiff extends StatelessWidget {
  final FileDiff diff;
  final CodeHighlighter highlighter;

  const _SplitDiff({required this.diff, required this.highlighter});

  /// Empareja bloques de líneas borradas/añadidas para verlas lado a lado.
  List<Object> _pairs() {
    final rows = <Object>[];
    for (final hunk in diff.hunks) {
      rows.add(hunk.header);
      final removed = <DiffLine>[];
      final added = <DiffLine>[];
      void flush() {
        final n = removed.length > added.length ? removed.length : added.length;
        for (var i = 0; i < n; i++) {
          rows.add((i < removed.length ? removed[i] : null, i < added.length ? added[i] : null));
        }
        removed.clear();
        added.clear();
      }

      for (final line in hunk.lines) {
        switch (line.type) {
          case DiffLineType.removed:
            if (added.isNotEmpty) flush();
            removed.add(line);
          case DiffLineType.added:
            added.add(line);
          case DiffLineType.context:
            flush();
            rows.add((line, line));
          case DiffLineType.meta:
            break;
        }
      }
      flush();
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = _DiffColors(theme);
    final rows = _pairs();
    final base = monoStyle(context);
    final gutter = monoStyle(context, size: 11.5, color: colors.gutterText);

    Widget side(DiffLine? line, bool left) {
      final number = line == null ? null : (left ? line.oldNumber : line.newNumber);
      final changed = line != null && line.type != DiffLineType.context;
      final bg = !changed ? null : (left ? colors.delBg : colors.addBg);
      final gut = !changed ? null : (left ? colors.delGutter : colors.addGutter);
      return Expanded(
        child: Container(
          color: line == null ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35) : bg,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Gutter(number, gutter, color: gut),
              const SizedBox(width: 8),
              Expanded(child: line == null ? const SizedBox() : Text.rich(highlighter.highlight(line.text, base))),
            ],
          ),
        ),
      );
    }

    return SelectionArea(
      child: ListView.builder(
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final row = rows[i];
          if (row is String) return _HunkHeader(row, colors);
          final (left, right) = row as (DiffLine?, DiffLine?);
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                side(left, true),
                VerticalDivider(width: 1, color: theme.dividerColor),
                side(right, false),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _FileView extends StatelessWidget {
  final FileContent content;
  final CodeHighlighter highlighter;

  const _FileView({required this.content, required this.highlighter});

  @override
  Widget build(BuildContext context) {
    final lines = content.text.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final colors = _DiffColors(Theme.of(context));
    final base = monoStyle(context);
    final gutter = monoStyle(context, size: 11.5, color: colors.gutterText);

    return SelectionArea(
      child: ListView.builder(
        itemCount: lines.length + (content.truncated ? 1 : 0),
        itemBuilder: (context, i) {
          if (i == lines.length) return const _Notice('File truncated (too large to show entirely).');
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Gutter(i + 1, gutter),
              const SizedBox(width: 12),
              Expanded(child: Text.rich(highlighter.highlight(lines[i], base))),
            ],
          );
        },
      ),
    );
  }
}
