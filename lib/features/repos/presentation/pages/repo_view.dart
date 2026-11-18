import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import '../widgets/commit_detail_panel.dart';
import '../widgets/commit_graph_view.dart';
import '../widgets/diff_viewer.dart';
import '../widgets/ref_sidebar.dart';
import '../widgets/repo_toolbar.dart';
import '../widgets/staging_panel.dart';

/// Contenido de una pestaña: un repositorio.
///
/// ┌──────────────── toolbar ────────────────┐
/// │ refs │ grafo de commits / diff │ panel   │
/// └─────────────────────────────────────────┘
class RepoView extends ConsumerStatefulWidget {
  final RepoHandle repo;

  /// Solo la pestaña visible sondea cambios en disco.
  final bool active;

  const RepoView({super.key, required this.repo, required this.active});

  @override
  ConsumerState<RepoView> createState() => _RepoViewState();
}

class _RepoViewState extends ConsumerState<RepoView> {
  static const _pollInterval = Duration(seconds: 5);
  Timer? _timer;
  double _sidebarWidth = 240;
  double _panelWidth = 380;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(RepoView old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      ref.read(repoNotifierProvider(widget.repo).notifier).refresh();
    }
    _syncTimer();
  }

  void _syncTimer() {
    if (widget.active) {
      _timer ??= Timer.periodic(_pollInterval, (_) {
        final state = ref.read(repoNotifierProvider(widget.repo));
        if (!state.isBusy) ref.read(repoNotifierProvider(widget.repo).notifier).refresh();
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = repoNotifierProvider(widget.repo);
    final hasOpenFile = ref.watch(provider.select((s) => s.openFile != null));
    final wipSelected = ref.watch(provider.select((s) => s.selectedSha == null));
    final loadError = ref.watch(provider.select((s) => s.snapshot == null ? s.loadError : null));

    if (loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(loadError.message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => ref.read(provider.notifier).refresh(forceHistory: true),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => ref.read(provider.notifier).closeFile(),
        const SingleActivator(LogicalKeyboardKey.f5): () => ref.read(provider.notifier).refresh(forceHistory: true),
      },
      child: Focus(
        autofocus: widget.active,
        child: Column(
          children: [
            RepoToolbar(repo: widget.repo),
            const Divider(height: 1),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Que los paneles laterales nunca se coman el centro.
                  final maxSide = (constraints.maxWidth - 360) / 2;
                  final sidebar = _sidebarWidth.clamp(160.0, maxSide.clamp(160.0, 480.0));
                  final panel = _panelWidth.clamp(280.0, maxSide.clamp(280.0, 640.0));
                  return Row(
                    children: [
                      SizedBox(
                        width: sidebar,
                        child: RefSidebar(repo: widget.repo),
                      ),
                      _DragHandle(onDrag: (dx) => setState(() => _sidebarWidth = sidebar + dx)),
                      Expanded(
                        child: hasOpenFile ? DiffViewer(repo: widget.repo) : CommitGraphView(repo: widget.repo),
                      ),
                      _DragHandle(onDrag: (dx) => setState(() => _panelWidth = panel - dx)),
                      SizedBox(
                        width: panel,
                        child: wipSelected ? StagingPanel(repo: widget.repo) : CommitDetailPanel(repo: widget.repo),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Separador vertical arrastrable para redimensionar paneles.
class _DragHandle extends StatelessWidget {
  final ValueChanged<double> onDrag;

  const _DragHandle({required this.onDrag});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: SizedBox(
          width: 5,
          child: Center(child: Container(width: 1, color: Theme.of(context).dividerColor)),
        ),
      ),
    );
  }
}
