import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/error/result.dart';
import '../../domain/entities/file_diff.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/entities/git_commit.dart';
import '../../domain/entities/repo_snapshot.dart';
import '../../domain/graph/commit_graph.dart';
import '../../domain/repositories/git_repository.dart';

const _unset = Object();

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

      var next = state.copyWith(snapshot: snapshot, isLoading: false, loadError: null);
      final signature = snapshot.refsSignature;
      if (forceHistory || signature != _refsSignature) {
        final history = await _git.loadHistory(repo, limit: state.historyLimit);
        if (!ref.mounted) return;
        if (history case Success(:final value)) {
          _refsSignature = signature;
          next = next.copyWith(commits: value, graph: buildCommitGraph(value));
          final selected = next.selectedSha;
          if (selected != null && !value.any((c) => c.sha == selected)) {
            next = next.copyWith(selectedSha: null, detail: null);
          }
        }
      }
      state = next;

      // Si el diff abierto es de cambios locales, puede haber cambiado.
      final open = state.openFile;
      if (open != null && open.source != DiffSource.commit) {
        await _loadDiff(open, keepContent: false, silent: true);
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
    final result = await _git.loadDiff(repo, target);
    if (!ref.mounted || request != _diffRequest) return;
    state = switch (result) {
      Success(:final value) => state.copyWith(diff: value, diffLoading: false),
      Failure(:final failure) => state.copyWith(diffError: failure, diffLoading: false),
    };
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
  Future<AppFailure?> run(GitAction action) async {
    if (state.isBusy) return null;
    state = state.copyWith(busyLabel: action.label);
    final result = await _git.run(repo, action);
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
