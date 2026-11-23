import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/di/providers.dart';
import '../../../../core/hosting/git_provider.dart';
import '../../../../core/settings/app_settings.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/error/result.dart';
import '../../domain/entities/file_change.dart';
import '../../domain/entities/file_diff.dart';
import '../../domain/entities/pull_request.dart';
import '../../domain/entities/pull_request_detail.dart';
import '../../domain/entities/repo_extras.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/entities/git_commit.dart';
import '../../domain/entities/repo_snapshot.dart';
import '../../domain/graph/commit_graph.dart';
import '../../domain/repositories/git_repository.dart';

const _unset = Object();

/// Dos revisiones (SHA o nombre de rama) a comparar y sus ficheros.
class CompareSelection {
  final String base;
  final String target;
  final String baseLabel;
  final String targetLabel;
  final List<FileChange>? changes;
  final AppFailure? error;

  const CompareSelection({
    required this.base,
    required this.target,
    required this.baseLabel,
    required this.targetLabel,
    this.changes,
    this.error,
  });

  CompareSelection withResult({List<FileChange>? changes, AppFailure? error}) => CompareSelection(
        base: base,
        target: target,
        baseLabel: baseLabel,
        targetLabel: targetLabel,
        changes: changes,
        error: error,
      );
}

class RepoState {
  final RepoSnapshot? snapshot;
  final List<GitCommit> commits;
  final List<GraphRow> graph;
  final int historyLimit;
  final bool isLoading;
  final AppFailure? loadError;

  /// Texto de la operación en curso (Pushing…, Pulling…); null si no hay.
  final String? busyLabel;

  /// Commit seleccionado; null = cambios locales (WIP).
  final String? selectedSha;
  final GitCommitDetail? detail;
  final bool detailLoading;

  /// Fichero abierto en el visor de diffs.
  final DiffTarget? openFile;
  final FileDiff? diff;
  final FileContent? fileContent;
  final bool diffLoading;
  final AppFailure? diffError;

  /// Qué haría "Undo" ahora, y lo deshecho que se puede rehacer.
  final UndoPlan? undoPlan;
  final List<({String label, GitAction action})> redoStack;

  /// Vista de historial / blame de un fichero (ocupan el panel central).
  final String? historyPath;
  final ({String path, String? revision})? blame;

  /// Comparación entre dos commits/ramas cualesquiera.
  final CompareSelection? compare;

  /// Pull Request abierta en el panel central.
  final int? pullRequestNumber;

  /// Último fetch (manual o automático) y su error, si falló.
  final DateTime? lastFetchAt;
  final String? fetchError;

  /// Hay un auto-fetch en curso (no bloquea la toolbar).
  final bool autoFetching;

  /// Lo que trajo el último fetch; [remoteUpdatesVersion] cambia en cada
  /// fetch con novedades para que la UI muestre el aviso una sola vez.
  final List<RemoteUpdate> remoteUpdates;
  final int remoteUpdatesVersion;

  /// Ramas remotas con novedades sin mirar (ref → commits nuevos; 0 = rama nueva).
  final Map<String, int> freshRefs;

  const RepoState({
    this.snapshot,
    this.commits = const [],
    this.graph = const [],
    this.historyLimit = 600,
    this.isLoading = false,
    this.loadError,
    this.busyLabel,
    this.selectedSha,
    this.detail,
    this.detailLoading = false,
    this.openFile,
    this.diff,
    this.fileContent,
    this.diffLoading = false,
    this.diffError,
    this.undoPlan,
    this.redoStack = const [],
    this.historyPath,
    this.blame,
    this.compare,
    this.pullRequestNumber,
    this.lastFetchAt,
    this.fetchError,
    this.autoFetching = false,
    this.remoteUpdates = const [],
    this.remoteUpdatesVersion = 0,
    this.freshRefs = const {},
  });

  bool get isBusy => busyLabel != null;
  bool get hasMoreHistory => commits.length >= historyLimit;

  int get maxLanes => graph.fold(1, (m, r) => r.width > m ? r.width : m);

  RepoState copyWith({
    Object? snapshot = _unset,
    List<GitCommit>? commits,
    List<GraphRow>? graph,
    int? historyLimit,
    bool? isLoading,
    Object? loadError = _unset,
    Object? busyLabel = _unset,
    Object? selectedSha = _unset,
    Object? detail = _unset,
    bool? detailLoading,
    Object? openFile = _unset,
    Object? diff = _unset,
    Object? fileContent = _unset,
    bool? diffLoading,
    Object? diffError = _unset,
    Object? undoPlan = _unset,
    List<({String label, GitAction action})>? redoStack,
    Object? historyPath = _unset,
    Object? blame = _unset,
    Object? compare = _unset,
    Object? pullRequestNumber = _unset,
    Object? lastFetchAt = _unset,
    Object? fetchError = _unset,
    bool? autoFetching,
    List<RemoteUpdate>? remoteUpdates,
    int? remoteUpdatesVersion,
    Map<String, int>? freshRefs,
  }) {
    T pick<T>(Object? value, T current) => identical(value, _unset) ? current : value as T;
    return RepoState(
      snapshot: pick(snapshot, this.snapshot),
      commits: commits ?? this.commits,
      graph: graph ?? this.graph,
      historyLimit: historyLimit ?? this.historyLimit,
      isLoading: isLoading ?? this.isLoading,
      loadError: pick(loadError, this.loadError),
      busyLabel: pick(busyLabel, this.busyLabel),
      selectedSha: pick(selectedSha, this.selectedSha),
      detail: pick(detail, this.detail),
      detailLoading: detailLoading ?? this.detailLoading,
      openFile: pick(openFile, this.openFile),
      diff: pick(diff, this.diff),
      fileContent: pick(fileContent, this.fileContent),
      diffLoading: diffLoading ?? this.diffLoading,
      diffError: pick(diffError, this.diffError),
      undoPlan: pick(undoPlan, this.undoPlan),
      redoStack: redoStack ?? this.redoStack,
      historyPath: pick(historyPath, this.historyPath),
      blame: pick(blame, this.blame),
      compare: pick(compare, this.compare),
      pullRequestNumber: pick(pullRequestNumber, this.pullRequestNumber),
      lastFetchAt: pick(lastFetchAt, this.lastFetchAt),
      fetchError: pick(fetchError, this.fetchError),
      autoFetching: autoFetching ?? this.autoFetching,
      remoteUpdates: remoteUpdates ?? this.remoteUpdates,
      remoteUpdatesVersion: remoteUpdatesVersion ?? this.remoteUpdatesVersion,
      freshRefs: freshRefs ?? this.freshRefs,
    );
  }
}

/// Estado de una pestaña: un repo abierto por una cuenta.
final repoNotifierProvider =
    NotifierProvider.family<RepoNotifier, RepoState, RepoHandle>(RepoNotifier.new);

class RepoNotifier extends Notifier<RepoState> {
  final RepoHandle repo;

  RepoNotifier(this.repo);

  GitRepository get _git => ref.read(gitRepositoryProvider);

  String? _refsSignature;
  int _detailRequest = 0;
  int _diffRequest = 0;
  bool _refreshing = false;
  bool? _queuedRefresh;

  @override
  RepoState build() {
    // Al activar/desactivar "ignorar espacios", recargar el diff abierto.
    ref.listen(appSettingsProvider.select((s) => s.ignoreWhitespace), (_, _) {
      final open = state.openFile;
      if (open != null) _loadDiff(open, keepContent: true, silent: true);
    });
    Future.microtask(() => refresh(forceHistory: true));
    return const RepoState(isLoading: true);
  }

  /// Recarga el estado. El historial solo se vuelve a pedir si las refs
  /// cambiaron (o si se fuerza), así el sondeo periódico es barato.
  Future<void> refresh({bool forceHistory = false}) async {
    if (_refreshing) {
      _queuedRefresh = (_queuedRefresh ?? false) || forceHistory;
      return;
    }
    _refreshing = true;
    try {
      final snapResult = await _git.loadSnapshot(repo);
      if (!ref.mounted) return;
      final snapshot = switch (snapResult) {
        Success(:final value) => value,
        Failure(:final failure) => () {
            state = state.copyWith(isLoading: false, loadError: failure);
            return null;
          }(),
      };
      if (snapshot == null) return;

      // Se recogen los resultados y se aplican al final sobre el estado
      // VIGENTE: durante los await pueden haber cambiado otras cosas (un
      // fichero abierto, las novedades de un auto-fetch…) que no hay que pisar.
      List<GitCommit>? commits;
      final signature = snapshot.refsSignature;
      if (forceHistory || signature != _refsSignature) {
        final history = await _git.loadHistory(repo, limit: state.historyLimit);
        if (!ref.mounted) return;
        if (history case Success(:final value)) {
          _refsSignature = signature;
          commits = value;
        }
      }
      final undo = await _git.loadUndoPlan(repo);
      if (!ref.mounted) return;

      var next = state.copyWith(
        snapshot: snapshot,
        isLoading: false,
        loadError: null,
        undoPlan: switch (undo) {
          Success(:final value) => value,
          Failure() => null,
        },
      );
      if (commits != null) {
        next = next.copyWith(commits: commits, graph: buildCommitGraph(commits));
        final selected = next.selectedSha;
        if (selected != null && !commits.any((c) => c.sha == selected)) {
          next = next.copyWith(selectedSha: null, detail: null);
        }
      }
      state = next;

      // Si el diff abierto es de cambios locales, puede haber cambiado... o
      // haber desaparecido de la lista (p. ej. al hacer stage de todo).
      final open = state.openFile;
      if (open != null && open.source != DiffSource.commit) {
        final list = open.source == DiffSource.staged ? snapshot.staged : snapshot.unstaged;
        final change = list.where((c) => c.path == open.path).firstOrNull;
        if (change == null) {
          closeFile();
        } else {
          final conflicted = change.type == ChangeType.conflicted;
          final target = conflicted == open.conflicted
              ? open
              : DiffTarget(source: open.source, path: open.path, oldPath: open.oldPath, conflicted: conflicted);
          await _loadDiff(target, keepContent: true, silent: true);
        }
      }
    } finally {
      _refreshing = false;
    }
    final queued = _queuedRefresh;
    if (queued != null && ref.mounted) {
      _queuedRefresh = null;
      await refresh(forceHistory: queued);
    }
  }

  Future<void> loadMore() async {
    state = state.copyWith(historyLimit: state.historyLimit + 600);
    await refresh(forceHistory: true);
  }

  void selectWip() {
    state = state.copyWith(selectedSha: null, detail: null, detailLoading: false);
  }

  Future<void> selectCommit(String sha) async {
    if (state.selectedSha == sha && state.detail != null) return;
    final request = ++_detailRequest;
    state = state.copyWith(selectedSha: sha, detailLoading: true);
    final result = await _git.loadCommitDetail(repo, sha);
    if (!ref.mounted || request != _detailRequest) return;
    state = switch (result) {
      Success(:final value) => state.copyWith(detail: value, detailLoading: false),
      Failure() => state.copyWith(detail: null, detailLoading: false),
    };
  }

  Future<void> openFile(DiffTarget target) => _loadDiff(target, keepContent: false);

  Future<void> _loadDiff(DiffTarget target, {required bool keepContent, bool silent = false}) async {
    final request = ++_diffRequest;
    final sameFile = state.openFile == target;
    state = state.copyWith(
      openFile: target,
      diffLoading: !silent,
      diffError: null,
      diff: sameFile ? state.diff : null,
      fileContent: keepContent && sameFile ? state.fileContent : null,
    );
    final hadContent = state.fileContent != null;
    final result = await _git.loadDiff(repo, target, ignoreWhitespace: ref.read(appSettingsProvider).ignoreWhitespace);
    if (!ref.mounted || request != _diffRequest) return;
    state = switch (result) {
      Success(:final value) => state.copyWith(diff: value, diffLoading: false),
      Failure(:final failure) => state.copyWith(diffError: failure, diffLoading: false),
    };
    // En un refresco silencioso, el contenido completo se actualiza sin
    // vaciarlo antes (evita parpadeos en la vista "File" y en conflictos).
    if (silent && keepContent && hadContent) {
      final content = await _git.loadFileContent(repo, target);
      if (!ref.mounted || request != _diffRequest) return;
      if (content case Success(:final value)) state = state.copyWith(fileContent: value);
    }
  }

  /// Carga el fichero completo (pestaña "File" del visor).
  Future<void> loadFileContent() async {
    final target = state.openFile;
    if (target == null || state.fileContent != null) return;
    final request = _diffRequest;
    final result = await _git.loadFileContent(repo, target);
    if (!ref.mounted || request != _diffRequest) return;
    state = switch (result) {
      Success(:final value) => state.copyWith(fileContent: value),
      Failure(:final failure) => state.copyWith(diffError: failure),
    };
  }

  void closeFile() {
    _diffRequest++;
    state = state.copyWith(openFile: null, diff: null, fileContent: null, diffError: null, diffLoading: false);
  }

  /// Ejecuta una acción git. Devuelve el fallo, o null si fue bien.
  /// Deshace la última operación (según el reflog) y la deja para "Redo".
  Future<AppFailure?> undo() async {
    final plan = state.undoPlan;
    if (plan == null || state.isBusy) return null;
    final failure = await run(plan.undo, keepRedo: true);
    if (failure == null && ref.mounted) {
      state = state.copyWith(redoStack: [...state.redoStack, (label: plan.redoLabel, action: plan.redo)]);
    }
    return failure;
  }

  Future<AppFailure?> redo() async {
    if (state.redoStack.isEmpty || state.isBusy) return null;
    final item = state.redoStack.last;
    final failure = await run(item.action, keepRedo: true);
    if (failure == null && ref.mounted) {
      state = state.copyWith(redoStack: state.redoStack.sublist(0, state.redoStack.length - 1));
    }
    return failure;
  }

  void openHistory(String path) {
    closeFile();
    state = state.copyWith(historyPath: path, blame: null, pullRequestNumber: null);
  }

  void openBlame(String path, {String? revision}) {
    closeFile();
    state = state.copyWith(blame: (path: path, revision: revision), historyPath: null, pullRequestNumber: null);
  }

  void closeHistoryAndBlame() {
    closeFile();
    state = state.copyWith(historyPath: null, blame: null);
  }

  void openPullRequest(int number) {
    closeFile();
    state = state.copyWith(pullRequestNumber: number, historyPath: null, blame: null);
  }

  void closePullRequest() => state = state.copyWith(pullRequestNumber: null);

  /// Esc: cierra lo que esté más "encima" en el panel central.
  void closeTopmost() {
    if (state.openFile != null) {
      closeFile();
    } else if (state.historyPath != null || state.blame != null) {
      closeHistoryAndBlame();
    } else if (state.pullRequestNumber != null) {
      closePullRequest();
    } else if (state.compare != null) {
      closeCompare();
    }
  }

  Future<void> compareRevisions(String base, String target, {String? baseLabel, String? targetLabel}) async {
    closeFile();
    final selection = CompareSelection(
      base: base,
      target: target,
      baseLabel: baseLabel ?? _short(base),
      targetLabel: targetLabel ?? _short(target),
    );
    state = state.copyWith(compare: selection, historyPath: null, blame: null);
    final result = await _git.loadComparison(repo, base, target);
    if (!ref.mounted || state.compare != selection) return;
    state = state.copyWith(compare: switch (result) {
      Success(:final value) => selection.withResult(changes: value),
      Failure(:final failure) => selection.withResult(error: failure),
    });
  }

  void closeCompare() {
    if (state.openFile?.source == DiffSource.commit && state.compare != null) closeFile();
    state = state.copyWith(compare: null);
  }

  static String _short(String rev) => RegExp(r'^[0-9a-f]{40}$').hasMatch(rev) ? rev.substring(0, 7) : rev;

  /// Notificación del sistema al terminar una operación de red larga (o si
  /// la ventana no está en primer plano).
  Future<void> _maybeNotify(GitAction action, AppFailure? failure, Duration took) async {
    if (!action.isNetwork || !ref.read(appSettingsProvider).notifications) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final background = lifecycle != null && lifecycle != AppLifecycleState.resumed;
    if (took < ref.read(notificationThresholdProvider) && !background) return;
    final what = switch (action) {
      PushAction(force: true) => 'Force push',
      PushAction() => 'Push',
      PullAction() => 'Pull',
      FetchAction() => 'Fetch',
      CheckoutPullRequestAction(:final number) => 'Checkout of PR #$number',
      DeleteRemoteBranchAction() => 'Remote branch deletion',
      PushTagAction() => 'Tag push',
      _ => 'Git operation',
    };
    final where = '${p.basename(repo.path)}${state.snapshot?.currentBranch != null ? ' (${state.snapshot!.currentBranch})' : ''}';
    await ref.read(systemLauncherProvider).notify(
          failure == null ? '$what finished' : '$what failed',
          failure == null ? where : '$where — ${failure.message.split('\n').first}',
        );
  }

  static Map<String, String> _remoteShas(RepoSnapshot? snapshot) => {
        for (final r in snapshot?.remoteBranches ?? const <GitRef>[]) r.name: r.sha,
      };

  bool _autoFetchRunning = false;

  /// Llamado periódicamente (y al volver a la ventana): hace fetch en
  /// segundo plano si toca según el ajuste "Auto-fetch".
  Future<void> maybeAutoFetch({bool onFocus = false}) async {
    final minutes = ref.read(appSettingsProvider).autoFetchMinutes;
    final snapshot = state.snapshot;
    if (minutes <= 0 || snapshot == null || snapshot.remotes.isEmpty) return;
    if (state.isBusy || _autoFetchRunning || snapshot.pendingOperation != PendingOperation.none) return;
    var interval = Duration(minutes: minutes);
    // Al volver a la app, basta con que haya pasado un minuto.
    if (onFocus && interval > const Duration(minutes: 1)) interval = const Duration(minutes: 1);
    final last = state.lastFetchAt;
    if (last != null && clock.now().difference(last) < interval) return;
    await backgroundFetch();
  }

  /// Fetch silencioso: no bloquea la toolbar ni muestra errores en un
  /// diálogo (quedan en [RepoState.fetchError]).
  Future<void> backgroundFetch() async {
    if (_autoFetchRunning || state.isBusy) return;
    _autoFetchRunning = true;
    final before = _remoteShas(state.snapshot);
    state = state.copyWith(autoFetching: true);
    try {
      final result = await _git.run(repo, const FetchAction(background: true));
      if (!ref.mounted) return;
      switch (result) {
        case Failure(:final failure):
          state = state.copyWith(
            autoFetching: false,
            lastFetchAt: clock.now(),
            fetchError: failure.message.split('\n').first,
          );
        case Success():
          state = state.copyWith(autoFetching: false, lastFetchAt: clock.now(), fetchError: null);
          await _reportRemoteUpdates(before, notify: true);
          await refresh(forceHistory: true);
      }
    } finally {
      _autoFetchRunning = false;
      if (ref.mounted && state.autoFetching) state = state.copyWith(autoFetching: false);
    }
  }

  /// Compara las ramas remotas con [before] y publica lo que cambió.
  Future<void> _reportRemoteUpdates(Map<String, String> before, {required bool notify}) async {
    final snap = await _git.loadSnapshot(repo);
    if (!ref.mounted || snap is! Success<RepoSnapshot>) return;
    final after = _remoteShas(snap.value);
    final updates = <RemoteUpdate>[];
    for (final e in after.entries) {
      final old = before[e.key];
      if (old == e.value) continue;
      final info = await _git.loadRefUpdate(repo, old, e.value);
      final (commits, author) = switch (info) {
        Success(:final value) => (value.commits, value.author),
        Failure() => (0, ''),
      };
      updates.add(RemoteUpdate(
        ref: e.key,
        kind: old == null ? RemoteUpdateKind.newBranch : RemoteUpdateKind.updated,
        commits: commits,
        author: author,
        sha: e.value,
      ));
    }
    for (final gone in before.keys.where((k) => !after.containsKey(k))) {
      updates.add(RemoteUpdate(ref: gone, kind: RemoteUpdateKind.deleted));
    }
    if (!ref.mounted || updates.isEmpty) return;

    final fresh = {...state.freshRefs};
    for (final u in updates) {
      if (u.kind == RemoteUpdateKind.deleted) {
        fresh.remove(u.ref);
      } else {
        fresh[u.ref] = u.kind == RemoteUpdateKind.newBranch ? 0 : (fresh[u.ref] ?? 0) + u.commits;
      }
    }
    state = state.copyWith(
      remoteUpdates: updates,
      remoteUpdatesVersion: state.remoteUpdatesVersion + 1,
      freshRefs: fresh,
    );

    // Con la ventana en segundo plano, también notificación del sistema.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final background = lifecycle != null && lifecycle != AppLifecycleState.resumed;
    if (notify && background && ref.read(appSettingsProvider).notifications) {
      await ref.read(systemLauncherProvider).notify(
            'New changes in ${p.basename(repo.path)}',
            updates.take(3).map((u) => u.summary).join('\n'),
          );
    }
  }

  /// El usuario ya ha visto las novedades de [refName].
  void markRefSeen(String refName) {
    if (!state.freshRefs.containsKey(refName)) return;
    state = state.copyWith(freshRefs: {...state.freshRefs}..remove(refName));
  }

  Future<AppFailure?> run(GitAction action, {bool keepRedo = false}) async {
    if (state.isBusy) return null;
    state = state.copyWith(busyLabel: action.label, redoStack: keepRedo ? null : const []);
    final watch = Stopwatch()..start();
    final fetches = action is FetchAction || action is PullAction;
    final before = fetches ? _remoteShas(state.snapshot) : null;
    final result = await _git.run(repo, action);
    if (fetches && ref.mounted) {
      state = switch (result) {
        Success() => state.copyWith(lastFetchAt: clock.now(), fetchError: null),
        Failure() => state,
      };
      if (result is Success && before != null) await _reportRemoteUpdates(before, notify: false);
    }
    if (ref.mounted) {
      await _maybeNotify(action, switch (result) {
        Failure(:final failure) => failure,
        Success() => null,
      }, watch.elapsed);
    }
    if (!ref.mounted) return null;
    state = state.copyWith(busyLabel: null);

    // Los ficheros abiertos pueden haber dejado de existir/cambiar.
    if (action is CommitAction || action is StashAction || action is DiscardAction ||
        action is ResetAction || action is CheckoutAction || action is CheckoutRemoteAction ||
        action is CheckoutDetachedAction || action is AbortOperationAction || action is RebaseAction ||
        action is ContinueOperationAction || action is SkipOperationAction || action is PullAction) {
      if (state.openFile?.source != DiffSource.commit) closeFile();
    }
    await refresh(forceHistory: true);
    return switch (result) {
      Failure(:final failure) => failure,
      Success() => null,
    };
  }
}

/// Pull Requests abiertas del repo (en GitHub). `ref.invalidate` para
/// recargarlas.
final pullRequestsProvider = FutureProvider.family<List<PullRequest>, RepoHandle>((ref, repo) async {
  final result = await ref.read(gitRepositoryProvider).listPullRequests(repo);
  return switch (result) {
    Success(:final value) => value,
    Failure(:final failure) => throw PullRequestsException(failure.message),
  };
});

class PullRequestsException implements Exception {
  final String message;
  const PullRequestsException(this.message);
  @override
  String toString() => message;
}

/// Configuración de firma (GPG/SSH) del repo; `ref.invalidate` al cambiarla.
final signingConfigProvider = FutureProvider.family<SigningConfig, RepoHandle>((ref, repo) async {
  final result = await ref.read(gitRepositoryProvider).loadSigningConfig(repo);
  return switch (result) {
    Success(:final value) => value,
    Failure() => const SigningConfig(),
  };
});

/// Plantilla de mensaje (`commit.template`), si hay.
final commitTemplateProvider = FutureProvider.family<String?, RepoHandle>((ref, repo) async {
  final result = await ref.read(gitRepositoryProvider).loadCommitTemplate(repo);
  return switch (result) {
    Success(:final value) => value,
    Failure() => null,
  };
});

/// Todo lo de una PR (detalle, conversación, commits, ficheros, checks).
final pullRequestBundleProvider =
    FutureProvider.family<PullRequestBundle, ({RepoHandle repo, int number})>((ref, key) async {
  final result = await ref.read(gitRepositoryProvider).loadPullRequest(key.repo, key.number);
  return switch (result) {
    Success(:final value) => value,
    Failure(:final failure) => throw PullRequestsException(failure.message),
  };
});

/// Cuánto tiene que tardar una operación de red para avisar al terminar.
final notificationThresholdProvider = Provider<Duration>((ref) => const Duration(seconds: 5));

/// A qué servicio (GitHub, Azure DevOps) apunta el remoto del repo.
final hostedRemoteProvider = FutureProvider.family<HostedRemote?, RepoHandle>((ref, repo) async {
  final result = await ref.read(gitRepositoryProvider).loadHostedRemote(repo);
  return switch (result) {
    Success(:final value) => value,
    Failure() => null,
  };
});

