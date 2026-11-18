import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/git_action.dart';
import '../../domain/entities/git_commit.dart';
import '../../domain/graph/commit_graph.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'ui_helpers.dart';

const _rowHeight = 30.0;
const _laneWidth = 16.0;
const _maxVisibleLanes = 14;
const _refsWidth = 190.0;

/// Historial de commits con el grafo de ramas (estilo GitKraken).
class CommitGraphView extends ConsumerStatefulWidget {
  final RepoHandle repo;

  const CommitGraphView({super.key, required this.repo});

  @override
  ConsumerState<CommitGraphView> createState() => _CommitGraphViewState();
}

class _CommitGraphViewState extends ConsumerState<CommitGraphView> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _ensureVisible(int index) {
    if (!_scroll.hasClients) return;
    final top = index * _rowHeight;
    final viewport = _scroll.position.viewportDimension;
    if (top < _scroll.offset || top + _rowHeight > _scroll.offset + viewport) {
      _scroll.animateTo(
        (top - viewport / 3).clamp(0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = repoNotifierProvider(widget.repo);
    final state = ref.watch(provider);
    final snapshot = state.snapshot;
    final showWip = snapshot != null && (snapshot.hasChanges || snapshot.pendingOperation.index != 0);
    final offset = showWip ? 1 : 0;

    // Seleccionar desde la barra lateral desplaza la lista hasta el commit.
    ref.listen(provider.select((s) => s.selectedSha), (_, sha) {
      if (sha == null) return;
      final current = ref.read(provider);
      final snap = current.snapshot;
      final wip = snap != null && (snap.hasChanges || snap.pendingOperation.index != 0);
      final index = current.commits.indexWhere((c) => c.sha == sha);
      if (index != -1) _ensureVisible(index + (wip ? 1 : 0));
    });

    if (state.isLoading && state.commits.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.loadError != null && snapshot == null) {
      return Center(child: Text(state.loadError!.message));
    }

    final lanes = math.min(state.maxLanes, _maxVisibleLanes);
    final graphWidth = math.max(lanes * _laneWidth + 12, 64.0);
    final headLane = () {
      final i = state.commits.indexWhere((c) => c.sha == snapshot?.headSha);
      return i == -1 ? 0 : state.graph[i].lane;
    }();
    final itemCount = offset + state.commits.length + (state.hasMoreHistory ? 1 : 0);

    return Column(
      children: [
        _HeaderRow(graphWidth: graphWidth),
        const Divider(height: 1),
        Expanded(
          child: state.commits.isEmpty && !showWip
              ? const Center(child: Text('No commits yet.'))
              : ListView.builder(
                  controller: _scroll,
                  itemExtent: _rowHeight,
                  itemCount: itemCount,
                  itemBuilder: (context, i) {
                    if (showWip && i == 0) {
                      return _WipRow(
                        repo: widget.repo,
                        graphWidth: graphWidth,
                        lane: headLane,
                        selected: state.selectedSha == null,
                      );
                    }
                    final index = i - offset;
                    if (index >= state.commits.length) {
                      return Center(
                        child: TextButton(
                          onPressed: ref.read(provider.notifier).loadMore,
                          child: const Text('Load more commits'),
                        ),
                      );
                    }
                    final commit = state.commits[index];
                    return _CommitRow(
                      repo: widget.repo,
                      commit: commit,
                      row: state.graph[index],
                      graphWidth: graphWidth,
                      isHead: commit.sha == snapshot?.headSha,
                      selected: state.selectedSha == commit.sha,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _HeaderRow extends StatelessWidget {
  final double graphWidth;

  const _HeaderRow({required this.graphWidth});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          letterSpacing: 0.8,
        );
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          SizedBox(width: _refsWidth, child: Padding(padding: const EdgeInsets.only(left: 12), child: Text('BRANCH / TAG', style: style))),
          SizedBox(width: graphWidth, child: Text('GRAPH', style: style)),
          Expanded(child: Text('COMMIT MESSAGE', style: style)),
          SizedBox(width: 150, child: Text('AUTHOR', style: style)),
          SizedBox(width: 130, child: Text('DATE', style: style)),
          SizedBox(width: 72, child: Text('SHA', style: style)),
        ],
      ),
    );
  }
}

class _WipRow extends ConsumerWidget {
  final RepoHandle repo;
  final double graphWidth;
  final int lane;
  final bool selected;

  const _WipRow({required this.repo, required this.graphWidth, required this.lane, required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final snapshot = ref.watch(repoNotifierProvider(repo).select((s) => s.snapshot));
    final count = (snapshot?.staged.length ?? 0) + (snapshot?.unstaged.length ?? 0);

    return Material(
      color: selected ? theme.colorScheme.primary.withValues(alpha: 0.14) : Colors.transparent,
      child: InkWell(
        onTap: ref.read(repoNotifierProvider(repo).notifier).selectWip,
        child: Row(
          children: [
            const SizedBox(width: _refsWidth),
            SizedBox(
              width: graphWidth,
              height: _rowHeight,
              child: CustomPaint(painter: _WipPainter(lane, laneColor(0), theme.colorScheme.surface)),
            ),
            Icon(Icons.edit_note, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text('// WIP', style: monoStyle(context, color: theme.colorScheme.primary).copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            Text('$count changed file${count == 1 ? '' : 's'}', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _CommitRow extends ConsumerWidget {
  final RepoHandle repo;
  final GitCommit commit;
  final GraphRow row;
  final double graphWidth;
  final bool isHead;
  final bool selected;

  const _CommitRow({
    required this.repo,
    required this.commit,
    required this.row,
    required this.graphWidth,
    required this.isHead,
    required this.selected,
  });

  Future<void> _menu(BuildContext context, WidgetRef ref, Offset position) async {
    final value = await showContextMenu<String>(context, position, [
      menuItem('checkout', Icons.call_split, 'Checkout this commit (detached)'),
      menuItem('branch', Icons.add, 'Create branch here…'),
      menuItem('tag', Icons.sell_outlined, 'Create tag here…'),
      const PopupMenuDivider(),
      menuItem('cherry', Icons.colorize_outlined, 'Cherry-pick commit'),
      menuItem('revert', Icons.undo, 'Revert commit'),
      const PopupMenuDivider(),
      menuItem('soft', Icons.restore, 'Reset current branch here — soft'),
      menuItem('mixed', Icons.restore, 'Reset current branch here — mixed'),
      menuItem('hard', Icons.warning_amber, 'Reset current branch here — hard',
          color: Theme.of(context).colorScheme.error),
      const PopupMenuDivider(),
      menuItem('copy', Icons.copy, 'Copy commit SHA'),
    ]);
    if (value == null || !context.mounted) return;

    final sha = commit.sha;
    switch (value) {
      case 'checkout':
        await runGitAction(context, ref, repo, CheckoutDetachedAction(sha));
      case 'branch':
        final name = await promptDialog(context,
            title: 'Create branch', label: 'Branch name', helper: 'Starts at ${commit.shortSha}', confirmLabel: 'Create');
        if (name != null && context.mounted) {
          await runGitAction(context, ref, repo, CreateBranchAction(name, startPoint: sha));
        }
      case 'tag':
        final name = await promptDialog(context, title: 'Create tag', label: 'Tag name', confirmLabel: 'Create');
        if (name != null && context.mounted) await runGitAction(context, ref, repo, CreateTagAction(name, sha));
      case 'cherry':
        await runGitAction(context, ref, repo, CherryPickAction(sha), successMessage: 'Cherry-picked ${commit.shortSha}');
      case 'revert':
        await runGitAction(context, ref, repo, RevertAction(sha), successMessage: 'Reverted ${commit.shortSha}');
      case 'soft' || 'mixed' || 'hard':
        final mode = ResetMode.values.byName(value);
        final ok = mode != ResetMode.hard ||
            await confirmDialog(context,
                title: 'Hard reset',
                message: 'The current branch will point to ${commit.shortSha} and ALL uncommitted '
                    'changes will be lost. This cannot be undone.',
                confirmLabel: 'Reset hard',
                destructive: true);
        if (ok && context.mounted) await runGitAction(context, ref, repo, ResetAction(sha, mode));
      case 'copy':
        await Clipboard.setData(ClipboardData(text: sha));
        if (context.mounted) showToast(context, 'Copied ${commit.shortSha}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final faded = theme.colorScheme.onSurfaceVariant;
    final color = laneColor(row.color);

    return Material(
      color: selected ? theme.colorScheme.primary.withValues(alpha: 0.14) : Colors.transparent,
      child: InkWell(
        onTap: () => ref.read(repoNotifierProvider(repo).notifier).selectCommit(commit.sha),
        onSecondaryTapDown: (d) => _menu(context, ref, d.globalPosition),
        child: Row(
          children: [
            SizedBox(width: _refsWidth, child: _RefChips(repo: repo, refs: commit.refs, color: color)),
            SizedBox(
              width: graphWidth,
              height: _rowHeight,
              child: ClipRect(
                child: CustomPaint(
                  painter: _GraphPainter(row, isHead: isHead, isMerge: commit.isMerge, surface: theme.colorScheme.surface),
                ),
              ),
            ),
            Expanded(
              child: Text(
                commit.subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: isHead ? FontWeight.w600 : null,
                  color: commit.isMerge ? faded : null,
                ),
              ),
            ),
            SizedBox(
              width: 150,
              child: Row(
                children: [
                  InitialsAvatar(commit.authorName, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(commit.authorName,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 130,
              child: Text(formatDate(commit.date), style: theme.textTheme.bodySmall?.copyWith(color: faded)),
            ),
            SizedBox(width: 72, child: Text(commit.shortSha, style: monoStyle(context, size: 12, color: faded))),
          ],
        ),
      ),
    );
  }
}

/// Etiquetas de rama/tag. Une `main` y `origin/main` en una sola chip.
class _RefChips extends ConsumerWidget {
  final RepoHandle repo;
  final List<RefLabel> refs;
  final Color color;

  const _RefChips({required this.repo, required this.refs, required this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (refs.isEmpty) return const SizedBox.shrink();

    final locals = refs.where((r) => r.kind == RefLabelKind.local).map((r) => r.name).toSet();
    final chips = <({String name, RefLabel label, bool alsoRemote})>[];
    for (final r in refs) {
      if (r.kind == RefLabelKind.remote) {
        final short = r.name.contains('/') ? r.name.substring(r.name.indexOf('/') + 1) : r.name;
        if (locals.contains(short)) continue;
      }
      final alsoRemote = r.kind == RefLabelKind.local &&
          refs.any((o) => o.kind == RefLabelKind.remote && o.name.endsWith('/${r.name}'));
      chips.add((name: r.name, label: r, alsoRemote: alsoRemote));
    }
    if (chips.isEmpty) return const SizedBox.shrink();

    final first = chips.first;
    final rest = chips.length - 1;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 4),
      child: Row(
        children: [
          Flexible(
            child: GestureDetector(
              onDoubleTap: () {
                final l = first.label;
                final action = switch (l.kind) {
                  RefLabelKind.local => CheckoutAction(l.name),
                  RefLabelKind.remote => CheckoutRemoteAction(l.name, l.name.substring(l.name.indexOf('/') + 1)),
                  _ => null,
                };
                if (action != null) runGitAction(context, ref, repo, action);
              },
              child: Tooltip(
                message: chips.map((c) => c.name).join('\n'),
                child: Container(
                  height: 20,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: first.label.isCurrent ? 0.9 : 0.22),
                    border: Border.all(color: color),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (first.label.isCurrent) const Icon(Icons.check, size: 13, color: Colors.white),
                      Icon(
                        switch (first.label.kind) {
                          RefLabelKind.local => Icons.laptop,
                          RefLabelKind.remote => Icons.cloud_outlined,
                          RefLabelKind.tag => Icons.sell_outlined,
                          RefLabelKind.head => Icons.my_location,
                        },
                        size: 12,
                        color: first.label.isCurrent ? Colors.white : theme.colorScheme.onSurface,
                      ),
                      if (first.alsoRemote)
                        Icon(Icons.cloud_outlined,
                            size: 12, color: first.label.isCurrent ? Colors.white : theme.colorScheme.onSurface),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          first.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: first.label.isCurrent ? Colors.white : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (rest > 0)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text('+$rest', style: theme.textTheme.labelSmall?.copyWith(color: color)),
            ),
          // Línea que une la chip con el nodo, como en GitKraken.
          Expanded(child: Container(height: 1, color: color.withValues(alpha: 0.6))),
        ],
      ),
    );
  }
}

double _laneX(int lane) => lane * _laneWidth + _laneWidth / 2 + 6;

class _GraphPainter extends CustomPainter {
  final GraphRow row;
  final bool isHead;
  final bool isMerge;
  final Color surface;

  _GraphPainter(this.row, {required this.isHead, required this.isMerge, required this.surface});

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    for (final line in row.lines) {
      paint.color = laneColor(line.color);
      final (x1, y1, x2, y2) = switch (line.segment) {
        GraphSegment.top => (_laneX(line.fromLane), 0.0, _laneX(line.toLane), mid),
        GraphSegment.bottom => (_laneX(line.fromLane), mid, _laneX(line.toLane), size.height),
        GraphSegment.through => (_laneX(line.fromLane), 0.0, _laneX(line.fromLane), size.height),
      };
      if (x1 == x2) {
        canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);
      } else {
        final path = Path()
          ..moveTo(x1, y1)
          ..cubicTo(x1, (y1 + y2) / 2, x2, (y1 + y2) / 2, x2, y2);
        canvas.drawPath(path, paint);
      }
    }

    final center = Offset(_laneX(row.lane), mid);
    final color = laneColor(row.color);
    final radius = isMerge ? 4.0 : 6.0;
    if (isHead) {
      canvas.drawCircle(center, radius + 3.5, Paint()..color = color.withValues(alpha: 0.35));
    }
    canvas.drawCircle(center, radius + 1.5, Paint()..color = surface);
    canvas.drawCircle(center, radius, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_GraphPainter old) =>
      old.row != row || old.isHead != isHead || old.surface != surface;
}

class _WipPainter extends CustomPainter {
  final int lane;
  final Color color;
  final Color surface;

  _WipPainter(this.lane, this.color, this.surface);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(_laneX(lane), size.height / 2);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    // Línea discontinua hacia HEAD.
    for (var y = center.dy + 8; y < size.height; y += 5) {
      canvas.drawLine(Offset(center.dx, y), Offset(center.dx, math.min(y + 2.5, size.height)), paint);
    }
    canvas.drawCircle(center, 6, paint);
  }

  @override
  bool shouldRepaint(_WipPainter old) => old.lane != lane || old.color != color;
}
