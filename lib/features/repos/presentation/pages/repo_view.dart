import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import '../widgets/blame_view.dart';
import '../widgets/commit_detail_panel.dart';
import '../widgets/commit_graph_view.dart';
import '../widgets/compare_panel.dart';
import '../widgets/diff_viewer.dart';
import '../widgets/file_history_view.dart';
import '../widgets/pull_request_view.dart';
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
  final _focus = FocusNode(debugLabel: 'repo-view');
  double _sidebarWidth = 240;
  double _panelWidth = 380;
  bool _sidebarVisible = true;

  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reclaimFocus());
    _syncTimer();
    // Al volver a la ventana: mirar si hay novedades en el remoto.
    _lifecycle = AppLifecycleListener(onResume: () {
      if (mounted && widget.active) {
        ref.read(repoNotifierProvider(widget.repo).notifier).maybeAutoFetch(onFocus: true);
      }
    });
  }

  @override
  void didUpdateWidget(RepoView old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reclaimFocus());
      final notifier = ref.read(repoNotifierProvider(widget.repo).notifier);
      notifier.refresh().then((_) => notifier.maybeAutoFetch(onFocus: true));
    }
    _syncTimer();
  }

  void _syncTimer() {
    if (widget.active) {
      _timer ??= Timer.periodic(_pollInterval, (_) {
        final state = ref.read(repoNotifierProvider(widget.repo));
        if (state.isBusy) return;
        final notifier = ref.read(repoNotifierProvider(widget.repo).notifier);
        // Estado local cada pocos segundos; fetch del remoto según el ajuste.
        notifier.refresh().then((_) => notifier.maybeAutoFetch());
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Los atajos de la pestaña solo llegan si el foco está dentro de ella.
  /// Se recupera cuando se ha quedado "por encima" (la pantalla de
  /// workspace, un ámbito vacío), nunca quitándoselo a un diálogo o campo.
  void _reclaimFocus() {
    if (!mounted || !widget.active) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary is FocusScopeNode || _focus.ancestors.contains(primary)) {
      _focus.requestFocus();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _focus.dispose();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = repoNotifierProvider(widget.repo);
    final hasOpenFile = ref.watch(provider.select((s) => s.openFile != null));
    final wipSelected = ref.watch(provider.select((s) => s.selectedSha == null));
    final historyPath = ref.watch(provider.select((s) => s.historyPath));
    final blame = ref.watch(provider.select((s) => s.blame));
    final comparing = ref.watch(provider.select((s) => s.compare != null));
    final pullRequest = ref.watch(provider.select((s) => s.pullRequestNumber));

    // Novedades del remoto (un compañero hizo push): aviso con "Show".
    ref.listen(provider.select((s) => s.remoteUpdatesVersion), (_, _) {
      final updates = ref.read(provider).remoteUpdates;
      if (!widget.active || updates.isEmpty) return;
      final first = updates.firstWhere((u) => u.sha.isNotEmpty, orElse: () => updates.first);
      final more = updates.length > 2 ? ' · +${updates.length - 2} more' : '';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 6),
          content: Row(children: [
            const Icon(Icons.cloud_download_outlined, size: 18, color: Colors.white70),
            const SizedBox(width: 10),
            Expanded(child: Text(updates.take(2).map((u) => u.summary).join(' · ') + more)),
          ]),
          action: first.sha.isEmpty
              ? null
              : SnackBarAction(
                  label: 'Show',
                  onPressed: () {
                    final notifier = ref.read(provider.notifier);
                    notifier.closeTopmost();
                    notifier.markRefSeen(first.ref);
                    notifier.selectCommit(first.sha);
                  },
                ),
        ));
    });

    // Al cerrar un diff/historial, el widget con el foco desaparece y el
    // foco queda en el ámbito superior, fuera de los atajos (Esc, F5) de
    // esta pestaña. Se lo devolvemos.
    ref.listen(provider.select((s) => (s.openFile, s.historyPath, s.blame, s.compare, s.pullRequestNumber)), (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.active) return;
        _reclaimFocus();
      });
    });
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
        const SingleActivator(LogicalKeyboardKey.escape): () => ref.read(provider.notifier).closeTopmost(),
        const SingleActivator(LogicalKeyboardKey.f5): () => ref.read(provider.notifier).refresh(forceHistory: true),
      },
      child: Focus(
        focusNode: _focus,
        autofocus: widget.active,
        child: Column(
          children: [
            RepoToolbar(
              repo: widget.repo,
              sidebarVisible: _sidebarVisible,
              onToggleSidebar: () => setState(() => _sidebarVisible = !_sidebarVisible),
            ),
            const Divider(height: 1),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Los paneles laterales nunca se comen el centro: cada uno
                  // tiene un máximo proporcional al ancho de la ventana.
                  final width = constraints.maxWidth;
                  final sidebar = _sidebarWidth.clamp(150.0, (width * 0.24).clamp(150.0, 480.0));
                  final panel = _panelWidth.clamp(260.0, (width * 0.32).clamp(260.0, 640.0));
                  return Row(
                    children: [
                      if (_sidebarVisible) ...[
                        SizedBox(
                          width: sidebar,
                          child: RefSidebar(repo: widget.repo),
                        ),
                        _DragHandle(onDrag: (dx) => setState(() => _sidebarWidth = sidebar + dx)),
                      ],
                      Expanded(
                        child: blame != null
                            ? BlameView(repo: widget.repo, path: blame.path, revision: blame.revision)
                            : historyPath != null
                            ? FileHistoryView(repo: widget.repo, path: historyPath)
                            : pullRequest != null && !hasOpenFile
                            ? PullRequestView(key: ValueKey(pullRequest), repo: widget.repo, number: pullRequest)
                            : hasOpenFile
                            ? DiffViewer(repo: widget.repo)
                            : CommitGraphView(repo: widget.repo),
                      ),
                      _DragHandle(onDrag: (dx) => setState(() => _panelWidth = panel - dx)),
                      SizedBox(
                        width: panel,
                        child: comparing
                            ? ComparePanel(repo: widget.repo)
                            : wipSelected
                            ? StagingPanel(repo: widget.repo)
                            : CommitDetailPanel(repo: widget.repo),
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
