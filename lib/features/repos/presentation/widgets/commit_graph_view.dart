import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/git_action.dart';
import '../../domain/entities/git_commit.dart';
import '../../domain/graph/commit_graph.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'interactive_rebase_dialog.dart';
import 'ui_helpers.dart';

const _rowHeight = 30.0;
const _laneWidth = 16.0;
const _maxVisibleLanes = 14;

/// Qué columnas caben y con qué ancho, según el espacio disponible.
class _Columns {
  final double refs;
  final double graph;
  final double author; // 0 = oculta; < 60 = solo avatar
  final double date;
  final double sha;

  const _Columns({
    required this.refs,
    required this.graph,
    required this.author,
    required this.date,
    required this.sha,
  });

  factory _Columns.forWidth(double width, int lanes) {
    final graph = math.max(lanes * _laneWidth + 12, 40.0);
    final refs = (width * 0.18).clamp(84.0, 200.0);
    // Espacio mínimo que reservamos para el mensaje del commit.
    var free = width - refs - graph - 180;
    double take(double wanted) {
      if (free >= wanted) {
        free -= wanted;
        return wanted;
      }
      return 0;
    }

    final sha = take(72);
    final date = take(126);
    var author = take(150);
    if (author == 0) author = take(34);
    return _Columns(refs: refs, graph: graph, author: author, date: date, sha: sha);
  }
}

/// Historial de commits con el grafo de ramas (estilo GitKraken).
class CommitGraphView extends ConsumerStatefulWidget {
  final RepoHandle repo;

  const CommitGraphView({super.key, required this.repo});

  @override
  ConsumerState<CommitGraphView> createState() => _CommitGraphViewState();
}

class _CommitGraphViewState extends ConsumerState<CommitGraphView> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  String _query = '';
  int _matchCursor = -1;

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  bool _showWip(RepoState s) {
    final snap = s.snapshot;
    return snap != null && (snap.hasChanges || snap.pendingOperation.index != 0);
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

  bool _matches(GitCommit c) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return c.subject.toLowerCase().contains(q) ||
        c.authorName.toLowerCase().contains(q) ||
        c.sha.startsWith(q) ||
        c.refs.any((r) => r.name.toLowerCase().contains(q));
  }

  /// Enter en el buscador: salta al siguiente commit que coincide.
  void _nextMatch() {
    final commits = ref.read(repoNotifierProvider(widget.repo)).commits;
    if (_query.isEmpty || commits.isEmpty) return;
    for (var step = 1; step <= commits.length; step++) {
      final i = (_matchCursor + step) % commits.length;
      if (_matches(commits[i])) {
        _matchCursor = i;
        ref.read(repoNotifierProvider(widget.repo).notifier).selectCommit(commits[i].sha);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = repoNotifierProvider(widget.repo);
    final state = ref.watch(provider);
    final snapshot = state.snapshot;
    final showWip = _showWip(state);
    final offset = showWip ? 1 : 0;

    // Seleccionar desde la barra lateral o el buscador desplaza la lista.
    ref.listen(provider.select((s) => s.selectedSha), (_, sha) {
      if (sha == null) return;
      final current = ref.read(provider);
      final index = current.commits.indexWhere((c) => c.sha == sha);
      if (index != -1) _ensureVisible(index + (_showWip(current) ? 1 : 0));
    });

    if (state.isLoading && state.commits.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.loadError != null && snapshot == null) {
      return Center(child: Text(state.loadError!.message));
    }

    final lanes = math.min(state.maxLanes, _maxVisibleLanes);
    final headLane = () {
      final i = state.commits.indexWhere((c) => c.sha == snapshot?.headSha);
      return i == -1 ? 0 : state.graph[i].lane;
    }();
    final matchCount = _query.isEmpty ? 0 : state.commits.where(_matches).length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = _Columns.forWidth(constraints.maxWidth, lanes);
        final itemCount = offset + state.commits.length + (state.hasMoreHistory ? 1 : 0);

        return Column(
          children: [
            _SearchBar(
              controller: _search,
              matchCount: matchCount,
              hasQuery: _query.isNotEmpty,
              onChanged: (v) => setState(() {
                _query = v.trim();
                _matchCursor = -1;
              }),
              onSubmitted: _nextMatch,
            ),
            _HeaderRow(cols: cols),
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
                            cols: cols,
                            lane: headLane,
                            selected: state.selectedSha == null,
                          );
                        }
                        final index = i - offset;
                        if (index >= state.commits.length) {
                          return Center(
                            child: TextButton.icon(
                              onPressed: ref.read(provider.notifier).loadMore,
                              icon: const Icon(Icons.expand_more, size: 18),
                              label: const Text('Load more commits'),
                            ),
                          );
                        }
                        final commit = state.commits[index];
                        return Opacity(
                          opacity: _matches(commit) ? 1 : 0.3,
                          child: _CommitRow(
                            repo: widget.repo,
                            commit: commit,
                            row: state.graph[index],
                            cols: cols,
                            isHead: commit.sha == snapshot?.headSha,
                            selected: state.selectedSha == commit.sha,
                            currentBranch: snapshot?.currentBranch,
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final int matchCount;
  final bool hasQuery;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;

  const _SearchBar({
    required this.controller,
    required this.matchCount,
    required this.hasQuery,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: SizedBox(
        height: 32,
        child: TextField(
          controller: controller,
          onChanged: onChanged,
          onSubmitted: (_) => onSubmitted(),
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            prefixIcon: const Icon(Icons.search, size: 18),
            hintText: 'Search commits: message, author, SHA, branch… (Enter = next)',
            suffixIcon: hasQuery
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$matchCount', style: theme.textTheme.labelSmall),
                      IconButton(
                        tooltip: 'Clear search',
                        iconSize: 16,
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  final _Columns cols;

  const _HeaderRow({required this.cols});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 0.8);
    Widget cell(double width, String text, {EdgeInsets padding = EdgeInsets.zero}) => SizedBox(
      width: width,
      child: Padding(
        padding: padding,
        child: Text(text, style: style, maxLines: 1, overflow: TextOverflow.clip, softWrap: false),
      ),
    );

    return SizedBox(
      height: 26,
      child: Row(
        children: [
          cell(cols.refs, cols.refs >= 120 ? 'BRANCH / TAG' : 'REFS', padding: const EdgeInsets.only(left: 12)),
          cell(cols.graph, 'GRAPH'),
          Expanded(
            child: Text('COMMIT MESSAGE', style: style, maxLines: 1, overflow: TextOverflow.clip),
          ),
          if (cols.author > 0) cell(cols.author, cols.author > 60 ? 'AUTHOR' : ''),
          if (cols.date > 0) cell(cols.date, 'DATE'),
          if (cols.sha > 0) cell(cols.sha, 'SHA'),
        ],
      ),
    );
  }
}

class _WipRow extends ConsumerWidget {
  final RepoHandle repo;
  final _Columns cols;
  final int lane;
  final bool selected;

  const _WipRow({required this.repo, required this.cols, required this.lane, required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final snapshot = ref.watch(repoNotifierProvider(repo).select((s) => s.snapshot));
    final count = (snapshot?.staged.length ?? 0) + (snapshot?.unstaged.length ?? 0);

    return Material(
      color: selected ? theme.colorScheme.primary.withValues(alpha: 0.16) : Colors.transparent,
      child: InkWell(
        onTap: ref.read(repoNotifierProvider(repo).notifier).selectWip,
        child: Row(
          children: [
            SizedBox(width: cols.refs),
            SizedBox(
              width: cols.graph,
              height: _rowHeight,
              child: ClipRect(child: CustomPaint(painter: _WipPainter(lane, theme.colorScheme.primary))),
            ),
            Icon(Icons.edit_note, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              '// WIP',
              style: monoStyle(context, color: theme.colorScheme.primary).copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                '$count changed file${count == 1 ? '' : 's'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
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
  final _Columns cols;
  final bool isHead;
  final bool selected;
  final String? currentBranch;

  const _CommitRow({
    required this.repo,
    required this.commit,
    required this.row,
    required this.cols,
    required this.isHead,
    required this.selected,
    required this.currentBranch,
  });

  Future<void> _menu(BuildContext context, WidgetRef ref, Offset position) async {
    final error = Theme.of(context).colorScheme.error;
    final value = await showContextMenu<String>(context, position, [
      menuItem('checkout', Icons.call_split, 'Checkout this commit (detached)'),
      menuItem('branch', Icons.add, 'Create branch here…'),
      menuItem('tag', Icons.sell_outlined, 'Create tag here…'),
      const PopupMenuDivider(),
      if (currentBranch != null && !isHead) ...[
        menuItem('merge', Icons.merge, 'Merge this commit into $currentBranch'),
        menuItem('rebase', Icons.low_priority, 'Rebase $currentBranch onto this commit'),
        menuItem('irebase', Icons.reorder, 'Interactive rebase $currentBranch from here…'),
      ],
      menuItem('cherry', Icons.colorize_outlined, 'Cherry-pick commit'),
      menuItem('revert', Icons.undo, 'Revert commit'),
      const PopupMenuDivider(),
      menuItem('soft', Icons.restore, 'Reset current branch here — soft'),
      menuItem('mixed', Icons.restore, 'Reset current branch here — mixed'),
      menuItem('hard', Icons.warning_amber, 'Reset current branch here — hard', color: error),
      const PopupMenuDivider(),
      menuItem('copy', Icons.copy, 'Copy commit SHA'),
      menuItem('copymsg', Icons.short_text, 'Copy commit message'),
    ]);
    if (value == null || !context.mounted) return;

    final sha = commit.sha;
    switch (value) {
      case 'checkout':
        await runGitAction(context, ref, repo, CheckoutDetachedAction(sha));
      case 'branch':
        final name = await promptDialog(
          context,
          title: 'Create branch',
          label: 'Branch name',
          helper: 'Starts at ${commit.shortSha}',
          confirmLabel: 'Create',
        );
        if (name != null && context.mounted) {
          await runGitAction(context, ref, repo, CreateBranchAction(name, startPoint: sha));
        }
      case 'tag':
        final name = await promptDialog(context, title: 'Create tag', label: 'Tag name', confirmLabel: 'Create');
        if (name != null && context.mounted) await runGitAction(context, ref, repo, CreateTagAction(name, sha));
      case 'merge':
        await runGitAction(context, ref, repo, MergeAction(sha), successMessage: 'Merged ${commit.shortSha}');
      case 'rebase':
        await confirmAndRebase(context, ref, repo, onto: sha, ontoLabel: commit.shortSha, branchLabel: currentBranch!);
      case 'irebase':
        await showInteractiveRebaseDialog(context, ref, repo,
            base: sha, baseLabel: commit.shortSha, branchLabel: currentBranch!);
      case 'cherry':
        await runGitAction(
          context,
          ref,
          repo,
          CherryPickAction(sha),
          successMessage: 'Cherry-picked ${commit.shortSha}',
        );
      case 'revert':
        await runGitAction(context, ref, repo, RevertAction(sha), successMessage: 'Reverted ${commit.shortSha}');
      case 'soft' || 'mixed' || 'hard':
        final mode = ResetMode.values.byName(value);
        final ok =
            mode != ResetMode.hard ||
            await confirmDialog(
              context,
              title: 'Hard reset',
              message:
                  'The current branch will point to ${commit.shortSha} and ALL uncommitted '
                  'changes will be lost. This cannot be undone.',
              confirmLabel: 'Reset hard',
              destructive: true,
            );
        if (ok && context.mounted) await runGitAction(context, ref, repo, ResetAction(sha, mode));
      case 'copy':
        await Clipboard.setData(ClipboardData(text: sha));
        if (context.mounted) showToast(context, 'Copied ${commit.shortSha}');
      case 'copymsg':
        await Clipboard.setData(ClipboardData(text: commit.subject));
        if (context.mounted) showToast(context, 'Copied commit message');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final faded = theme.colorScheme.onSurfaceVariant;
    final color = laneColor(row.color);

    return Material(
      color: selected ? theme.colorScheme.primary.withValues(alpha: 0.16) : Colors.transparent,
      child: InkWell(
        onTap: () => ref.read(repoNotifierProvider(repo).notifier).selectCommit(commit.sha),
        onSecondaryTapDown: (d) => _menu(context, ref, d.globalPosition),
        child: Row(
          children: [
            SizedBox(
              width: cols.refs,
              child: _RefChips(repo: repo, refs: commit.refs, color: color),
            ),
            SizedBox(
              width: cols.graph,
              height: _rowHeight,
              child: ClipRect(
                child: CustomPaint(
                  painter: _GraphPainter(
                    row,
                    isHead: isHead,
                    isMerge: commit.isMerge,
                    surface: theme.colorScheme.surface,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Tooltip(
                message: commit.subject,
                waitDuration: const Duration(milliseconds: 900),
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
            ),
            if (cols.author > 0)
              SizedBox(
                width: cols.author,
                child: Tooltip(
                  message: '${commit.authorName} <${commit.authorEmail}>',
                  child: Row(
                    children: [
                      const SizedBox(width: 8),
                      InitialsAvatar(commit.authorName, size: 18),
                      if (cols.author > 60) ...[
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            commit.authorName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (cols.date > 0)
              SizedBox(
                width: cols.date,
                child: Text(
                  formatDate(commit.date),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: faded),
                ),
              ),
            if (cols.sha > 0)
              SizedBox(
                width: cols.sha,
                child: Text(commit.shortSha, style: monoStyle(context, size: 12, color: faded)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Acción de checkout adecuada para una etiqueta del grafo.
GitAction? _checkoutFor(RefLabel l) => switch (l.kind) {
  RefLabelKind.local => CheckoutAction(l.name),
  RefLabelKind.remote => CheckoutRemoteAction(l.name, l.name.substring(l.name.indexOf('/') + 1)),
  RefLabelKind.tag => CheckoutDetachedAction(l.name),
  RefLabelKind.head => null,
};

IconData _refIcon(RefLabelKind kind) => switch (kind) {
  RefLabelKind.local => Icons.laptop,
  RefLabelKind.remote => Icons.cloud_outlined,
  RefLabelKind.tag => Icons.sell_outlined,
  RefLabelKind.head => Icons.my_location,
};

/// Etiquetas de rama/tag. Une `main` y `origin/main` en una sola chip.
/// Si hay varias ("+N"), al pasar el ratón se despliega la lista completa
/// y se puede hacer checkout de cualquiera con un clic.
class _RefChips extends ConsumerStatefulWidget {
  final RepoHandle repo;
  final List<RefLabel> refs;
  final Color color;

  const _RefChips({required this.repo, required this.refs, required this.color});

  @override
  ConsumerState<_RefChips> createState() => _RefChipsState();
}

class _RefChipsState extends ConsumerState<_RefChips> {
  static const _openDelay = Duration(milliseconds: 250);
  static const _closeDelay = Duration(milliseconds: 300);

  final _menu = MenuController();
  Timer? _openTimer;
  Timer? _closeTimer;

  @override
  void dispose() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    super.dispose();
  }

  void _hoverIn() {
    _closeTimer?.cancel();
    if (_menu.isOpen) return;
    _openTimer?.cancel();
    _openTimer = Timer(_openDelay, () {
      if (mounted) _menu.open();
    });
  }

  /// Se cierra con un pequeño margen para poder llevar el ratón al panel.
  void _hoverOut() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _closeTimer = Timer(_closeDelay, () {
      if (mounted && _menu.isOpen) _menu.close();
    });
  }

  void _checkout(RefLabel label) {
    _menu.close();
    final action = _checkoutFor(label);
    if (action != null) runGitAction(context, ref, widget.repo, action);
  }

  @override
  Widget build(BuildContext context) {
    final refs = widget.refs;
    final color = widget.color;
    if (refs.isEmpty) return const SizedBox.shrink();

    final locals = refs.where((r) => r.kind == RefLabelKind.local).map((r) => r.name).toSet();
    final chips = <({String name, RefLabel label, bool alsoRemote})>[];
    for (final r in refs) {
      if (r.kind == RefLabelKind.remote) {
        final short = r.name.contains('/') ? r.name.substring(r.name.indexOf('/') + 1) : r.name;
        if (locals.contains(short)) continue;
      }
      final alsoRemote =
          r.kind == RefLabelKind.local &&
          refs.any((o) => o.kind == RefLabelKind.remote && o.name.endsWith('/${r.name}'));
      chips.add((name: r.name, label: r, alsoRemote: alsoRemote));
    }
    if (chips.isEmpty) return const SizedBox.shrink();

    final first = chips.first;
    final rest = chips.length - 1;
    final theme = Theme.of(context);
    final current = first.label.isCurrent;
    final fg = current ? Colors.white : theme.colorScheme.onSurface;
    // Todas las refs (también las remotas que la chip agrupa), salvo HEAD.
    final listed = refs.where((r) => r.kind != RefLabelKind.head).toList();
    final hasList = listed.length > 1;

    final chip = GestureDetector(
      onDoubleTap: () => _checkout(first.label),
      child: LayoutBuilder(
        builder: (context, c) {
          // Con poco sitio, primero sobran los iconos.
          final roomy = c.maxWidth >= 72;
          return Container(
            height: 20,
            padding: EdgeInsets.symmetric(horizontal: roomy ? 6 : 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: current ? 0.9 : 0.22),
              border: Border.all(color: color),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (roomy) ...[
                  if (current) Icon(Icons.check, size: 13, color: fg),
                  Icon(_refIcon(first.label.kind), size: 12, color: fg),
                  if (first.alsoRemote) Icon(Icons.cloud_outlined, size: 12, color: fg),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    first.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    final chipsRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: hasList ? chip : Tooltip(message: '${first.name}\n\nDouble-click to check out', child: chip),
        ),
        if (rest > 0)
          Container(
            margin: const EdgeInsets.only(left: 3),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('+$rest', style: theme.textTheme.labelSmall?.copyWith(color: color)),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 4),
      child: Row(
        children: [
          // La chip se queda con casi todo el ancho; la línea, con el resto.
          Flexible(
            flex: 8,
            child: !hasList
                ? chipsRow
                : MenuAnchor(
                    controller: _menu,
                    alignmentOffset: const Offset(0, 2),
                    style: MenuStyle(
                      backgroundColor: WidgetStatePropertyAll(theme.colorScheme.surfaceContainerHigh),
                      side: WidgetStatePropertyAll(BorderSide(color: theme.colorScheme.outlineVariant)),
                      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                      maximumSize: const WidgetStatePropertyAll(Size(380, 420)),
                    ),
                    menuChildren: [
                      MouseRegion(
                        onEnter: (_) => _closeTimer?.cancel(),
                        onExit: (_) => _hoverOut(),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                              child: Text(
                                '${listed.length} refs on this commit · click to check out',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            for (final r in listed)
                              MenuItemButton(
                                leadingIcon: Icon(_refIcon(r.kind), size: 16, color: color),
                                trailingIcon: r.isCurrent
                                    ? Icon(Icons.check, size: 16, color: theme.colorScheme.primary)
                                    : null,
                                onPressed: r.isCurrent ? null : () => _checkout(r),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 260),
                                  child: Text(
                                    r.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontWeight: r.isCurrent ? FontWeight.w700 : null),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                    child: MouseRegion(
                      onEnter: (_) => _hoverIn(),
                      onExit: (_) => _hoverOut(),
                      child: chipsRow,
                    ),
                  ),
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
  bool shouldRepaint(_GraphPainter old) => old.row != row || old.isHead != isHead || old.surface != surface;
}

class _WipPainter extends CustomPainter {
  final int lane;
  final Color color;

  _WipPainter(this.lane, this.color);

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
