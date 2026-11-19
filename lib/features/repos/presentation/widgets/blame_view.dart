import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/error/result.dart';
import '../../domain/entities/repo_extras.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'code_highlighter.dart';
import 'code_view_style.dart';
import 'ui_helpers.dart';

const _lineHeight = 20.0;

/// Blame: quién cambió por última vez cada línea, y en qué commit.
class BlameView extends ConsumerStatefulWidget {
  final RepoHandle repo;
  final String path;

  /// Versión a anotar; null = la del directorio de trabajo.
  final String? revision;

  const BlameView({super.key, required this.repo, required this.path, this.revision});

  @override
  ConsumerState<BlameView> createState() => _BlameViewState();
}

class _BlameViewState extends ConsumerState<BlameView> {
  late Future<Result<List<BlameLine>>> _future = _load();

  Future<Result<List<BlameLine>>> _load() =>
      ref.read(gitRepositoryProvider).loadBlame(widget.repo, widget.path, revision: widget.revision);

  @override
  void didUpdateWidget(BlameView old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.revision != widget.revision) _future = _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notifier = ref.read(repoNotifierProvider(widget.repo).notifier);

    final header = Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Icon(Icons.person_search_outlined, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.revision == null ? 'Blame · working tree' : 'Blame · at ${shortRev(widget.revision!)}',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                Text(widget.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
              ],
            ),
          ),
          IconButton(
            tooltip: 'File history',
            onPressed: () => notifier.openHistory(widget.path),
            icon: const Icon(Icons.history, size: 20),
          ),
          IconButton(
            tooltip: 'Reload',
            onPressed: () => setState(() => _future = _load()),
            icon: const Icon(Icons.refresh, size: 20),
          ),
          IconButton(
            tooltip: 'Open in editor',
            onPressed: () => openFileInEditor(context, ref, widget.repo, widget.path),
            icon: const Icon(Icons.code, size: 20),
          ),
          IconButton(tooltip: 'Close blame', onPressed: notifier.closeHistoryAndBlame, icon: const Icon(Icons.close)),
        ],
      ),
    );

    return CodeViewStyleScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder(
              future: _future,
              builder: (context, snap) {
                final result = snap.data;
                if (result == null) return const Center(child: CircularProgressIndicator());
                if (result case Failure(:final failure)) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        failure.message.contains('no such path')
                            ? 'This file is not committed yet, so there is nothing to blame.'
                            : failure.message,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                final lines = (result as Success<List<BlameLine>>).value;
                return LayoutBuilder(
                  builder: (context, c) => _BlameList(
                    repo: widget.repo,
                    lines: lines,
                    annotationWidth: (c.maxWidth * 0.34).clamp(150.0, 300.0),
                    highlighter: CodeHighlighter.forPath(widget.path, theme.brightness),
                    onEdit: (line) => openFileInEditor(context, ref, widget.repo, widget.path, line: line),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BlameList extends ConsumerWidget {
  final RepoHandle repo;
  final List<BlameLine> lines;
  final double annotationWidth;
  final CodeHighlighter highlighter;
  final ValueChanged<int> onEdit;

  const _BlameList({
    required this.repo,
    required this.lines,
    required this.annotationWidth,
    required this.highlighter,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (lines.isEmpty) return const Center(child: Text('Empty file.'));

    // Banda de color según la antigüedad: más reciente = más intensa.
    final dates = lines.where((l) => !l.isUncommitted).map((l) => l.date.millisecondsSinceEpoch).toList();
    final oldest = dates.isEmpty ? 0 : dates.reduce((a, b) => a < b ? a : b);
    final newest = dates.isEmpty ? 1 : dates.reduce((a, b) => a > b ? a : b);
    double age(BlameLine l) => l.isUncommitted
        ? 1
        : newest == oldest
        ? 1
        : (l.date.millisecondsSinceEpoch - oldest) / (newest - oldest);

    // Índice de bloque (grupo de líneas seguidas del mismo commit) por
    // línea, para alternar el sombreado. Se calcula una vez.
    final blocks = List<int>.filled(lines.length, 0);
    for (var j = 1; j < lines.length; j++) {
      blocks[j] = blocks[j - 1] + (lines[j].sha != lines[j - 1].sha ? 1 : 0);
    }

    final fontSize = CodeViewStyle.of(context).fontSize;
    final base = monoStyle(context, size: fontSize);
    final gutter = monoStyle(
      context,
      size: fontSize - 1,
      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
    );
    final faded = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return SelectionArea(
      child: ListView.builder(
        itemExtent: _lineHeight * fontSize / 12.5,
        itemCount: lines.length,
        itemBuilder: (context, i) {
          final line = lines[i];
          final firstOfBlock = i == 0 || lines[i - 1].sha != line.sha;
          final stripe = theme.colorScheme.primary.withValues(alpha: 0.15 + 0.75 * age(line));
          final shaded = blocks[i].isOdd;

          final annotation = !firstOfBlock
              ? const SizedBox.shrink()
              : Tooltip(
                  message: line.isUncommitted
                      ? 'Not committed yet'
                      : '${line.summary}\n${line.author} · ${formatDate(line.date)} · ${line.shortSha}\n\nClick to show the commit',
                  waitDuration: const Duration(milliseconds: 500),
                  child: InkWell(
                    onTap: line.isUncommitted
                        ? null
                        : () {
                            final notifier = ref.read(repoNotifierProvider(repo).notifier);
                            notifier.closeHistoryAndBlame();
                            notifier.selectCommit(line.sha);
                          },
                    child: Row(
                      children: [
                        if (!line.isUncommitted) InitialsAvatar(line.author, size: 14),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            line.isUncommitted ? 'Not committed yet' : '${line.summary} · ${line.author}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: faded?.copyWith(
                              color: line.isUncommitted ? theme.colorScheme.tertiary : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        if (!line.isUncommitted && annotationWidth > 200)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(_shortDate(line.date), style: faded),
                          ),
                      ],
                    ),
                  ),
                );

          return Container(
            color: shaded ? theme.colorScheme.surfaceContainerLow : null,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: stripe),
                Container(
                  width: annotationWidth,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.centerLeft,
                  child: annotation,
                ),
                GestureDetector(
                  onDoubleTap: () => onEdit(line.number),
                  child: Container(
                    width: 48,
                    padding: const EdgeInsets.only(right: 8),
                    alignment: Alignment.centerRight,
                    child: Text('${line.number}', style: gutter),
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text.rich(
                      highlighter.highlight(line.text.replaceAll('\r', ''), base),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _shortDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
